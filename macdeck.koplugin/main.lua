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
local W = require("ui/widgets")
local WifiTransport = require("transport/wifi")

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

-- 診斷紀錄：debug 等級，平常不寫進 crash.log；要查問題時到
-- KOReader 選單 → 工具 → 更多工具 → 開發者選項 開啟 debug logging，最後一行就是 MacDeck 最後在做的事
local function trace(...) logger.dbg("MacDeck:", ...) end

function MacDeck:start()
    if self.session then return end
    trace("start")
    local cfg = Settings.load()
    local s = {
        cfg = cfg,
        saved = { rotation = Screen:getRotationMode() },
        minutes = 0,
        page = "home",
        media = nil,
        now_playing = nil, -- Media 頁最上面那一行（Mac 回報的正在播放）
        info = nil, -- 時鐘右側的天氣 / 行程（Mac 同步來的）
        last_sync = nil, -- 上次嘗試同步的時間（Scheduler.now）
        syncing = false,
        agents = nil,
        agent_index = 1,
        agent_id = nil, -- 以 id 記住選的 session，清單重新排序也不會選錯
        agent_page = 1,
        agent_filter = nil, -- nil = 全部；否則只看這個來源（"Claude Code"、"Codex"…）
    }
    self.session = s

    s.transport = self:createTransport(cfg.transport)
    s.ticker = Scheduler.minuteTicker{ ui_manager = UIManager, on_tick = function() self:tickMinute(s) end }
    s.idle = Scheduler.timeout(UIManager, cfg.idle.controller_timeout_sec, function()
        if s.page == "agents" and cfg.agents.stay_open and s.machine.state == S.CONTROL then
            return s.idle:reset() -- Agents 頁當狀態板用，不跳回時鐘
        end
        self:fire(s, "idle_timeout")
    end)
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

function MacDeck:createTransport(t)
    if t.preferred == "wifi" then
        return WifiTransport.new{
            ui_manager = UIManager,
            host = t.wifi.host,
            port = t.wifi.port,
            token = t.wifi.token,
            timeout_sec = t.wifi.request_timeout_sec,
        }
    end
    return Transport.mock{
        ui_manager = UIManager,
        connect_delay_sec = t.mock_connect_delay_sec,
        fail_connect = t.mock_fail_connect,
        agent_count = t.mock_agent_count,
    }
end

-- 系統要睡眠：停掉所有計時器與網路（輪詢、同步、逾時），不要在 Wi-Fi 關閉途中還去連 Mac
-- 喚醒時會收到 resume 事件，回到 Clock 重新開始
-- 注意：外掛上名字是 on + 大寫開頭的方法，KOReader 會當成事件處理器直接呼叫（不會帶 s），
-- 所以這裡和 tickMinute / screenClosed 都刻意不用 on 開頭；只有 onCloseWidget 是真的要接事件
function MacDeck:suspendSession(s)
    if self.session ~= s then return end
    trace("suspend: stopping timers and network")
    self:stopPolling(s)
    s.idle:cancel()
    s.connect_timeout:cancel()
    s.ticker:stop()
    s.syncing = false
    pcall(function() s.transport:disconnect() end)
end

-- 只接受目前 session 的事件，避免舊的 callback 打到新 session
function MacDeck:fire(s, event, detail)
    if self.session ~= s then return end
    s.last_detail = detail
    s.machine:fire(event)
end

-- 安全網：同一秒內切換狀態太多次一定是迴圈，直接退出，不讓整台機器卡死
local MAX_ENTERS_PER_SEC = 50

function MacDeck:enter(s, state)
    trace("state", state)
    local now = Scheduler.now()
    if s.burst_at ~= now then s.burst_at, s.burst = now, 0 end
    s.burst = s.burst + 1
    if s.burst > MAX_ENTERS_PER_SEC and state ~= S.EXITED then
        logger.err("MacDeck: state loop detected, exiting to KOReader")
        return self:teardown(s)
    end
    self:stopPolling(s)
    s.syncing = false -- 同步做到一半被換狀態：那次結果會被 transport 丟掉
    s.idle:cancel()
    s.connect_timeout:cancel()
    s.ticker:stop()

    if state == S.EXITED then
        self:teardown(s)
    elseif state == S.CLOCK then
        s.transport:disconnect() -- 回到時鐘就降載控制傳輸
        self:showClock(s)
        s.minutes = 0
        s.ticker:start()
        if self:syncDue(s) then
            s.sync_tick = function() s.sync_tick = nil; self:syncInfo(s) end
            UIManager:nextTick(s.sync_tick)
        end
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

function MacDeck:showClock(s)
    self:showScreen(s, ClockScreen:new(self:screenCallbacks(s, {
        info = s.info,
        on_control = function() self:fire(s, "control") end,
    })))
end

-- ── Clock info sync ──────────────────────────────────────
-- 時鐘畫面平常不連線；每 clock.sync_min 分鐘短暫連一次 Mac 拿天氣 / 下一個行程，拿完就斷

function MacDeck:syncDue(s)
    local every = s.cfg.clock.sync_min
    if every <= 0 or s.syncing then return false end
    return s.last_sync == nil or Scheduler.now() - s.last_sync >= every * 60
end

function MacDeck:syncInfo(s)
    if self.session ~= s or s.machine.state ~= S.CLOCK or not self:syncDue(s) then return end
    trace("clock sync")
    s.syncing, s.last_sync = true, Scheduler.now()
    local function finish(info)
        if self.session ~= s or s.machine.state ~= S.CLOCK or not s.syncing then return end
        s.syncing = false
        s.transport:disconnect()
        s.info = info
        self:showClock(s)
    end
    s.transport:connect(function(ok, err)
        if not ok then
            -- 保留上次的資料，只在底部說明這次為什麼沒同步到
            local info = {}
            for k, v in pairs(s.info or {}) do info[k] = v end
            info.error = err or "not synced"
            return finish(info)
        end
        s.transport:send("info.get", {}, function(ack)
            if ack.status == "ok" and type(ack.data) == "table" then
                finish(ack.data)
            else
                local info = {}
                for k, v in pairs(s.info or {}) do info[k] = v end
                info.error = ack.detail or "sync failed"
                finish(info)
            end
        end)
    end)
end

function MacDeck:screenCallbacks(s, extra)
    local o = {
        cfg = s.cfg,
        on_exit = function() self:fire(s, "exit") end,
        on_clock = function() self:fire(s, "clock") end,
        on_closed = function(screen) self:screenClosed(s, screen) end,
        on_suspend = function(screen)
            if s.screen == screen then self:suspendSession(s) end
        end,
        -- KOReader 廣播 Resume 時，途中新 show 的畫面也會收到同一個事件；
        -- 直接在這裡換畫面會讓新畫面再收到 Resume → 無限迴圈卡死整台機器。
        -- 所以只讓目前的畫面處理，而且延到廣播結束後、同一次喚醒只處理一次
        on_resume = function(screen)
            if s.screen ~= screen or s.resume_tick then return end
            s.resume_tick = function()
                s.resume_tick = nil
                self:fire(s, "resume")
            end
            UIManager:nextTick(s.resume_tick)
        end,
    }
    for k, v in pairs(extra or {}) do o[k] = v end
    return o
end

function MacDeck:controller(s, mode)
    return ControllerScreen:new(self:screenCallbacks(s, {
        mode = mode,
        page = s.page,
        media = s.media,
        now_playing = s.now_playing,
        agents = s.agents and self:visibleAgents(s),
        agent_index = s.agent_index,
        agent_page = s.agent_page,
        agent_sources = s.agents and self:agentSources(s),
        agent_filter = s.agent_filter,
        dictating = s.dictating,
        message = mode == "OFFLINE" and s.last_detail or nil,
        on_activity = function()
            if s.machine.state == S.CONTROL or s.machine.state == S.OFFLINE then s.idle:reset() end
        end,
        on_retry = function() self:fire(s, "retry") end,
        on_page = function(page) self:openPage(s, page) end,
        on_command = function(action, args, label) self:sendCommand(s, action, args, label, function(data)
            if data and data.level ~= nil then self:applyVolume(s, data) end
            if action:match("^media%.") then self:pollMedia(s, 1) end -- 換歌要一點時間，1 秒後再讀
        end) end,
        on_volume = function(level) self:setVolume(s, level) end,
        on_select_agent = function(i)
            local a = s.agents and self:visibleAgents(s)[i]
            if not a then return end
            s.agent_index, s.agent_id = i, a.id
            self:showScreen(s, self:controller(s, S.CONTROL))
        end,
        on_list_page = function(delta)
            s.agent_page = s.agent_page + delta
            self:showScreen(s, self:controller(s, S.CONTROL))
        end,
        on_agent_key = function(key) self:agentKey(s, key) end,
        on_agent_filter = function(source)
            s.agent_filter = source
            self:selectAgent(s)
            self:showScreen(s, self:controller(s, S.CONTROL))
        end,
    }))
end

-- Controller 內換頁（仍在 CONTROL 狀態）；進頁時向 Mac 讀目前狀態
function MacDeck:openPage(s, page)
    if self.session ~= s or s.machine.state ~= S.CONTROL then return end
    trace("page", page)
    self:stopPolling(s)
    s.page = page
    self:showScreen(s, self:controller(s, S.CONTROL))
    if page == "media" then
        self:sendCommand(s, "volume.get", {}, nil, function(data) self:applyVolume(s, data) end)
        self:pollMedia(s)
    elseif page == "agents" then
        self:pollAgents(s)
    end
end

-- ── Media：正在播放 ──────────────────────────────────────

--- delay 秒後讀一次（nil = 現在），之後每 media.poll_sec 秒；只在 Media 頁
function MacDeck:pollMedia(s, delay)
    if s.media_poll then UIManager:unschedule(s.media_poll); s.media_poll = nil end
    if self.session ~= s or s.page ~= "media" or s.machine.state ~= S.CONTROL then return end
    s.media_poll = function()
        s.media_poll = nil
        if self.session ~= s or s.page ~= "media" or s.machine.state ~= S.CONTROL then return end
        self:sendCommand(s, "media.now", {}, nil, function(data)
            if type(data) ~= "table" or s.page ~= "media" then return end
            s.now_playing = data
            if s.screen then s.screen:setNowPlaying(data) end
        end)
        self:pollMedia(s, s.cfg.media.poll_sec)
    end
    UIManager:scheduleIn(delay or 0, s.media_poll)
end

-- ── Agents ───────────────────────────────────────────────

-- Agents 頁開著時定期問 Mac；資料沒變就不重畫（E-Ink 少閃）
function MacDeck:pollAgents(s)
    if s.poll then UIManager:unschedule(s.poll); s.poll = nil end -- 只換掉下一次輪詢；排著的重畫要保留
    if self.session ~= s or s.page ~= "agents" or s.machine.state ~= S.CONTROL then return end
    self:sendCommand(s, "agents.list", {}, nil, function(data)
        self:applyAgents(s, data and data.sessions or {})
    end)
    s.poll = function()
        s.poll = nil
        self:pollAgents(s)
    end
    UIManager:scheduleIn(s.cfg.agents.poll_sec, s.poll)
end

function MacDeck:stopPolling(s)
    if s.media_poll then
        UIManager:unschedule(s.media_poll)
        s.media_poll = nil
    end
    if s.resume_tick then
        UIManager:unschedule(s.resume_tick)
        s.resume_tick = nil
    end
    if s.sync_tick then
        UIManager:unschedule(s.sync_tick)
        s.sync_tick = nil
    end
    if s.poll then
        UIManager:unschedule(s.poll)
        s.poll = nil
    end
    if s.redraw then
        UIManager:unschedule(s.redraw)
        s.redraw = nil
    end
end

local function signature(agents)
    local parts = {}
    for _, a in ipairs(agents) do
        local tasks = {}
        for _, t in ipairs(a.tasks or {}) do tasks[#tasks + 1] = tostring(t.status) .. ":" .. tostring(t.text) end
        parts[#parts + 1] = table.concat({ tostring(a.id), tostring(a.state), tostring(a.label), tostring(a.summary),
            tostring(a.progress), tostring(a.prompt), tostring(a.step), table.concat(tasks, ",") }, "|")
    end
    return table.concat(parts, "\n")
end

--- session 數量由 Mac 回報、不固定；保留原本選的那個（找不到就選第一個）
function MacDeck:applyAgents(s, agents)
    if s.page ~= "agents" then return end
    local sig = signature(agents)
    if s.agents and sig == s.agents_sig then return end -- elapsed 每次都會變，不算
    s.agents, s.agents_sig = agents, sig
    self:selectAgent(s)
    self:redrawWhenIdle(s)
end

--- 依來源篩選後的清單（選單選「全部」時就是整份）
function MacDeck:visibleAgents(s)
    if not s.agent_filter then return s.agents or {} end
    local out = {}
    for _, a in ipairs(s.agents or {}) do
        if a.source == s.agent_filter then out[#out + 1] = a end
    end
    return out
end

--- 目前有哪些來源、各幾個，照第一次出現的順序（Mac 端已經把需要你處理的排前面）
function MacDeck:agentSources(s)
    local list, index = {}, {}
    for _, a in ipairs(s.agents or {}) do
        local name = a.source or "Other"
        if not index[name] then
            list[#list + 1] = { name = name, count = 0 }
            index[name] = list[#list]
        end
        index[name].count = index[name].count + 1
    end
    return list
end

--- 在目前看得到的清單裡找回原本選的那個（找不到就選第一個），並翻到它所在的頁
function MacDeck:selectAgent(s)
    if s.agent_filter and #self:visibleAgents(s) == 0 then
        s.agent_filter = nil -- 那個來源已經沒有 session 了，回到全部
    end
    local visible = self:visibleAgents(s)
    s.agent_index = 1
    for i, a in ipairs(visible) do
        if a.id == s.agent_id then s.agent_index = i end
    end
    s.agent_id = visible[s.agent_index] and visible[s.agent_index].id or nil
    s.agent_page = math.floor((s.agent_index - 1) / ControllerScreen.AGENTS_PER_PAGE) + 1
end

-- 有按鈕正在回饋時先不換畫面，不然那次點擊會被丟掉
function MacDeck:redrawWhenIdle(s)
    if s.redraw then UIManager:unschedule(s.redraw) end
    s.redraw = function()
        s.redraw = nil
        if self.session ~= s or s.page ~= "agents" or s.machine.state ~= S.CONTROL then return end
        if W.pending_taps > 0 then return self:redrawWhenIdle(s) end
        self:showScreen(s, self:controller(s, S.CONTROL))
    end
    UIManager:scheduleIn(W.pending_taps > 0 and 0.5 or 0, s.redraw)
end

local KEY_LABELS = { approve = "Approve", stop = "Stop", send = "Send", auto = "Auto", dictate = "Dictate", open = "Open" }

function MacDeck:agentKey(s, key)
    local a = s.agents and self:visibleAgents(s)[s.agent_index]
    if not a then return end
    local label = string.format("%s → %s", KEY_LABELS[key] or key, a.project or "session")
    local action, args = "agent.key", { session_id = a.id, key = key }
    if key == "open" then action, args = "agent.open", { session_id = a.id } end
    self:sendCommand(s, action, args, label, function(data)
        if key == "dictate" and type(data) == "table" and data.dictating ~= nil then
            -- 聽寫是開 / 關切換：按鍵上的字跟著 Mac 實際的狀態變
            s.dictating = data.dictating
            self:redrawWhenIdle(s)
        end
        if key ~= "open" then self:pollAgents(s) end -- 按完馬上更新狀態
    end)
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
        elseif ack.offline then
            self:fire(s, "disconnected", ack.detail) -- 連不到 Mac：進 OFFLINE，可 Retry
        else
            screen:setResult(string.format("%s → Error: %s", label or action, ack.detail or "unknown"))
        end
    end)
end

function MacDeck:tickMinute(s)
    if self.session ~= s or s.machine.state ~= S.CLOCK then return end
    s.minutes = s.minutes + 1
    local every = s.cfg.clock.full_refresh_min
    local full = every > 0 and s.minutes % every == 0
    s.screen:updateTime(full)
    if self:syncDue(s) then self:syncInfo(s) end
end

-- ── Screens ──────────────────────────────────────────────

-- 先 show 新畫面再 close 舊的，中間不會露出 KOReader
function MacDeck:showScreen(s, screen)
    trace("show", screen.name, screen.page or "")
    local old = s.screen
    s.screen = screen
    UIManager:show(screen, "ui")
    if old then
        old._replaced = true
        UIManager:close(old)
    end
end

-- 畫面被別的方式關掉（不是我們換頁或退出）時，也要完整清理
function MacDeck:screenClosed(s, screen)
    if screen._replaced or self.session ~= s then return end
    if s.screen == screen then s.screen = nil end
    self:teardown(s)
end

-- 可重複呼叫；任何路徑退出都走這裡（T-09）
-- closing = true：KOReader 自己正在關閉這個 UI，不要再廣播事件給正在拆掉的閱讀器
function MacDeck:teardown(s, closing)
    if self.session ~= s then return end
    trace("teardown", closing and "(KOReader closing)" or "")
    self.session = nil
    self:stopPolling(s)
    s.idle:cancel()
    s.connect_timeout:cancel()
    s.ticker:stop()
    pcall(function() s.transport:disconnect() end)
    if s.screen then
        s.screen._replaced = true
        UIManager:close(s.screen, closing and "ui" or "full")
        s.screen = nil
    end
    if closing then
        -- 直接把方向設回去，不廣播 SetRotationMode（閱讀器的 document 可能已經不在了）
        local mode = s.saved.rotation
        if mode ~= nil and mode ~= Screen:getRotationMode() then pcall(Screen.setRotationMode, Screen, mode) end
    else
        self:setRotation(s.saved.rotation)
    end
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
    if self.session then self:teardown(self.session, true) end
end

return MacDeck
