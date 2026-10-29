-- 插件生命週期 / 註冊
-- 注意：插件內模組要在檔案頂層 require（KOReader 只在載入 main.lua 時把插件資料夾放在 package.path 最前面）
local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local ClockScreen = require("ui/clock")
local ControllerScreen = require("ui/controller")
local Scheduler = require("core/scheduler")
local Settings = require("core/settings")
local StateMachine = require("core/state_machine")
local Transport = require("transport/interface")

local Screen = Device.screen
local S = StateMachine.STATES

local MacDeck = WidgetContainer:extend{
    name = "macdeck",
    is_doc_only = false,
}

function MacDeck:init()
    self.ui.menu:registerToMainMenu(self)
end

function MacDeck:addToMainMenu(menu_items)
    menu_items.macdeck = {
        text = _("MacDeck"),
        sorting_hint = "tools",
        callback = function() self:start() end,
    }
end

-- ── Session ──────────────────────────────────────────────

function MacDeck:start()
    if self.session then return end
    local cfg = Settings.load()
    local s = {
        cfg = cfg,
        saved = { rotation = Screen:getRotationMode() },
        minutes = 0,
        page = "home",
        media = nil,
        displays = nil,
        display_index = 1,
        display_id = nil, -- 以 id 記住選的螢幕，插拔後清單順序變了也不會選錯
        display_page = 1,
    }
    self.session = s

    s.transport = Transport.mock{
        ui_manager = UIManager,
        connect_delay_sec = cfg.transport.mock_connect_delay_sec,
        fail_connect = cfg.transport.mock_fail_connect,
        display_count = cfg.transport.mock_display_count,
    }
    s.ticker = Scheduler.minuteTicker{ ui_manager = UIManager, on_tick = function() self:onMinute(s) end }
    s.idle = Scheduler.timeout(UIManager, cfg.idle.controller_timeout_sec, function() self:fire(s, "idle_timeout") end)
    s.connect_timeout = Scheduler.timeout(UIManager, cfg.transport.connect_timeout_sec, function()
        self:fire(s, "failed", "Connection timed out")
    end)
    s.machine = StateMachine.new{
        initial = S.INIT,
        transitions = StateMachine.MACDECK_TRANSITIONS,
        on_enter = function(to) self:enter(s, to) end,
        on_error = function(err)
            logger.err("MacDeck: state handler failed:", err)
            self:teardown(s) -- 出錯一律退回 KOReader，確保不卡死
        end,
    }

    if cfg.ui.orientation == "landscape" and not self:isLandscape(s.saved.rotation) then
        self:setRotation(cfg.ui.landscape_rotation)
    end
    s.machine:fire("open")
end

-- 只接受目前 session 的事件，避免舊的 callback 打到新 session
function MacDeck:fire(s, event, detail)
    if self.session ~= s then return end
    s.last_detail = detail
    s.machine:fire(event)
end

function MacDeck:enter(s, state)
    s.idle:cancel()
    s.connect_timeout:cancel()
    s.ticker:stop()

    if state == S.EXITED then
        self:teardown(s)
    elseif state == S.CLOCK then
        s.transport:disconnect() -- 回到時鐘就降載控制傳輸
        self:showScreen(s, ClockScreen:new(self:screenCallbacks(s, {
            on_control = function() self:fire(s, "control") end,
        })))
        s.minutes = 0
        s.ticker:start()
    elseif state == S.CONNECTING then
        self:showScreen(s, self:controller(s, "CONNECTING"))
        s.connect_timeout:reset()
        s.transport:connect(function(ok, err)
            if s.machine.state ~= S.CONNECTING then return end
            if ok then
                self:fire(s, "connected")
            else
                self:fire(s, "failed", err)
            end
        end)
    elseif state == S.CONTROL or state == S.OFFLINE then
        s.page = "home" -- 每次連上都從 Controller 首頁開始
        self:showScreen(s, self:controller(s, state))
        s.idle:reset()
    end
end

function MacDeck:screenCallbacks(s, extra)
    local o = {
        cfg = s.cfg,
        on_exit = function() self:fire(s, "exit") end,
        on_clock = function() self:fire(s, "clock") end,
        on_closed = function(screen) self:onScreenClosed(s, screen) end,
        on_suspend = function() s.ticker:stop() end,
        on_resume = function() self:fire(s, "resume") end,
    }
    for k, v in pairs(extra or {}) do o[k] = v end
    return o
end

function MacDeck:controller(s, mode)
    return ControllerScreen:new(self:screenCallbacks(s, {
        mode = mode,
        page = s.page,
        media = s.media,
        displays = s.displays,
        display_index = s.display_index,
        display_page = s.display_page,
        message = mode == "OFFLINE" and s.last_detail or nil,
        on_activity = function()
            if s.machine.state == S.CONTROL or s.machine.state == S.OFFLINE then s.idle:reset() end
        end,
        on_retry = function() self:fire(s, "retry") end,
        on_page = function(page) self:openPage(s, page) end,
        on_command = function(action, args, label) self:sendCommand(s, action, args, label, function(data)
            if data and data.level ~= nil then self:applyVolume(s, data) end
        end) end,
        on_volume = function(level) self:setVolume(s, level) end,
        on_select_display = function(i)
            local d = s.displays and s.displays[i]
            if not d then return end
            s.display_index, s.display_id = i, d.id
            self:showScreen(s, self:controller(s, S.CONTROL))
        end,
        on_list_page = function(delta)
            s.display_page = s.display_page + delta
            self:showScreen(s, self:controller(s, S.CONTROL))
        end,
        on_refresh = function() self:openPage(s, "monitor") end,
        on_brightness = function(level) self:setBrightness(s, level) end,
    }))
end

-- Controller 內換頁（仍在 CONTROL 狀態）；進頁時向 Mac 讀目前狀態
function MacDeck:openPage(s, page)
    if self.session ~= s or s.machine.state ~= S.CONTROL then return end
    s.page = page
    if page == "monitor" then s.displays = nil end
    self:showScreen(s, self:controller(s, S.CONTROL))
    if page == "media" then
        self:sendCommand(s, "volume.get", {}, nil, function(data) self:applyVolume(s, data) end)
    elseif page == "monitor" then
        self:sendCommand(s, "display.list", {}, nil, function(data)
            if s.page ~= "monitor" then return end
            self:applyDisplays(s, data and data.displays or {})
            self:showScreen(s, self:controller(s, S.CONTROL))
        end)
    end
end

-- 螢幕數量由 Mac 回報、不固定；保留原本選的那台（找不到就選第一台）
function MacDeck:applyDisplays(s, displays)
    s.displays = displays
    s.display_index = 1
    for i, d in ipairs(displays) do
        if d.id == s.display_id then s.display_index = i end
    end
    s.display_id = displays[s.display_index] and displays[s.display_index].id or nil
    s.display_page = math.floor((s.display_index - 1) / ControllerScreen.DISPLAYS_PER_PAGE) + 1
end

function MacDeck:applyVolume(s, data)
    if type(data) ~= "table" then return end
    s.media = { level = data.level, muted = data.muted }
    if s.page == "media" and s.screen then s.screen:setVolume(data.level, data.muted) end
end

function MacDeck:setVolume(s, level)
    -- 先在畫面上更新（E-Ink 回饋要快），再以 Mac 回傳值為準
    if s.screen then s.screen:setVolume(level, false) end
    self:sendCommand(s, "volume.set", { level = level }, string.format("Volume %d%%", level), function(data)
        self:applyVolume(s, data)
    end)
end

function MacDeck:setBrightness(s, level)
    local d = s.displays and s.displays[s.display_index]
    if not d then return end
    if s.screen then s.screen:setBrightness(level) end
    self:sendCommand(s, "display.brightness.set", { display_id = d.id, level = level },
        string.format("%s %d%%", d.name, level))
end

--- label = nil 時不顯示在狀態列（背景讀取用）；on_ok(data) 只在 ACK ok 時呼叫
function MacDeck:sendCommand(s, action, args, label, on_ok)
    if self.session ~= s or s.machine.state ~= S.CONTROL then return end
    local screen = s.screen
    if label then screen:setResult(label .. " …") end
    s.transport:send(action, args, function(ack)
        if self.session ~= s or s.screen ~= screen then return end
        if ack.status == "ok" then
            if label then screen:setResult(string.format("%s → OK (%s)", label, ack.id)) end
            if on_ok then on_ok(ack.data) end
        else
            screen:setResult(string.format("%s → Error: %s", label or action, ack.detail or "unknown"))
        end
    end)
end

function MacDeck:onMinute(s)
    if self.session ~= s or s.machine.state ~= S.CLOCK then return end
    s.minutes = s.minutes + 1
    local every = s.cfg.clock.full_refresh_min
    local full = every > 0 and s.minutes % every == 0
    s.screen:updateTime(full)
end

-- ── Screens ──────────────────────────────────────────────

-- 先 show 新畫面再 close 舊的，中間不會露出 KOReader
function MacDeck:showScreen(s, screen)
    local old = s.screen
    s.screen = screen
    UIManager:show(screen, "ui")
    if old then
        old._replaced = true
        UIManager:close(old)
    end
end

-- 畫面被別的方式關掉（不是我們換頁或退出）時，也要完整清理
function MacDeck:onScreenClosed(s, screen)
    if screen._replaced or self.session ~= s then return end
    if s.screen == screen then s.screen = nil end
    self:teardown(s)
end

-- 可重複呼叫；任何路徑退出都走這裡（T-09）
function MacDeck:teardown(s)
    if self.session ~= s then return end
    self.session = nil
    s.idle:cancel()
    s.connect_timeout:cancel()
    s.ticker:stop()
    pcall(function() s.transport:disconnect() end)
    if s.screen then
        s.screen._replaced = true
        UIManager:close(s.screen, "full")
        s.screen = nil
    end
    self:setRotation(s.saved.rotation)
end

-- ── Rotation ─────────────────────────────────────────────

function MacDeck:isLandscape(mode)
    return mode == Screen.DEVICE_ROTATED_CLOCKWISE or mode == Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE
end

-- 透過事件讓 FileManager / ReaderView 自己重新排版
function MacDeck:setRotation(mode)
    if mode ~= nil and mode ~= Screen:getRotationMode() then
        UIManager:broadcastEvent(Event:new("SetRotationMode", mode))
    end
end

-- KOReader 正在關閉這個 UI（例如從檔案管理器切到閱讀器）
function MacDeck:onCloseWidget()
    if self.session then self:teardown(self.session) end
end

return MacDeck
