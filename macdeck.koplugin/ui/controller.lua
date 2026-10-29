-- Mac 控制畫面
-- mode = CONNECTING / CONTROL / OFFLINE；CONTROL 再分成 page = home / media / agents
-- 每個畫面底列都保留 Clock 與 Exit
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local W = require("ui/widgets")

local unpack = table.unpack or unpack -- LuaJIT 只有全域 unpack

local ControllerScreen = W.ScreenBase:extend{
    name = "macdeck_controller",
    cfg = nil,
    mode = "CONTROL",
    page = "home",
    status = "",
    message = nil, -- OFFLINE 時的錯誤說明
    media = nil, -- { level = 0..100 或 nil, muted = bool }
    agents = nil, -- nil = 讀取中；{ { id, project, state, label, summary, progress, elapsed, prompt, step, tasks }, ... }
    agent_index = 1, -- 在完整清單中的位置
    agent_page = 1, -- session 數量不固定，超過一頁就分頁
    on_activity = nil, -- 任何觸控都呼叫，用來重設閒置逾時
    on_page = nil, -- function(page)
    on_command = nil, -- function(action, args, label)
    on_volume = nil, -- function(level)
    on_select_agent = nil, -- function(index)
    on_agent_key = nil, -- function(key)：approve / stop / send / auto / dictate / open
    on_list_page = nil, -- function(delta)
    on_retry = nil,
    on_clock = nil,
    on_exit = nil,
}

local STATUS = {
    CONNECTING = "Mac: Connecting…",
    CONTROL = "Mac: Connected",
    OFFLINE = "Mac: Offline",
}

local TITLES = {
    home = "MAC CONTROL",
    media = "MEDIA CONTROL",
    agents = "AGENTS",
}

-- 左邊 2×2 格；超過就分頁
ControllerScreen.AGENTS_PER_PAGE = 4

-- 任務清單符號（KOReader 的備援字型 FreeSans 有這幾個字）
local TASK_MARK = { completed = "✓", in_progress = "▶", pending = "○" }

local function toSegments(level)
    if level == nil then return 0 end
    return math.floor(level / 10 + 0.5)
end

function ControllerScreen:activity()
    if self.on_activity then self.on_activity() end
end

-- 包一層：先重設閒置計時，再呼叫實際動作
function ControllerScreen:tap(fn, ...)
    local args = { ... }
    return function()
        self:activity()
        if fn then fn(unpack(args)) end
    end
end

function ControllerScreen:button(text, width, height, callback, opts)
    opts = opts or {}
    return W.BigButton:new{
        text = text,
        width = width,
        height = height,
        font_size = opts.font_size or 22,
        selected = opts.selected,
        callback = callback,
        show_parent = self,
        feedback_ms = self.cfg.ui.feedback_ms,
    }
end

function ControllerScreen:buildHome(width, height)
    local m = W.metrics()
    local w = math.floor((width - m.gap) / 2)
    return HorizontalGroup:new{
        self:button("Media control", w, height, self:tap(self.on_page, "media"), { font_size = 26 }),
        HorizontalSpan:new{ width = m.gap },
        self:button("Agents", width - m.gap - w, height, self:tap(self.on_page, "agents"), { font_size = 26 }),
    }
end

function ControllerScreen:volumeLabel()
    local media = self.media or {}
    if media.muted then return "Volume: Muted" end
    if media.level == nil then return "Volume: —" end
    return string.format("Volume: %d%%", media.level)
end

-- 上半部：上一首 / 播放暫停 / 下一首；下半部：音量條 + 小聲 / 大聲 / 靜音
function ControllerScreen:buildMedia(width, height)
    local m = W.metrics()
    local top_h = math.floor((height - m.gap) * 0.58)
    local label_h = m.header_h
    local bar_h = height - top_h - 2 * m.gap - label_h
    local bw = math.floor((width - 2 * m.gap) / 3)
    local function cmd(action, label)
        return self:tap(self.on_command, action, {}, label)
    end

    local top = HorizontalGroup:new{
        self:button("Previous", bw, top_h, cmd("media.previous", "Previous")),
        HorizontalSpan:new{ width = m.gap },
        self:button("Play / Pause", bw, top_h, cmd("media.toggle", "Play / Pause")),
        HorizontalSpan:new{ width = m.gap },
        self:button("Next", width - 2 * (bw + m.gap), top_h, cmd("media.next", "Next")),
    }

    local media = self.media or {}
    local key_w = math.floor(width * 0.13)
    local bar_w = width - 3 * key_w - 3 * m.gap
    self.volume_text = W.text(self:volumeLabel(), 18, true, width)
    self.volume_label = W.Region:new{
        LeftContainer:new{ dimen = Geom:new{ w = width, h = label_h }, self.volume_text },
    }
    self.volume_bar = W.SegmentBar:new{
        width = bar_w,
        height = bar_h,
        value = media.muted and 0 or toSegments(media.level),
        show_parent = self,
        on_change = function(idx)
            self:activity()
            if self.on_volume then self.on_volume(idx * 10) end
        end,
    }
    local function step(delta)
        return function()
            self:activity()
            local current = (self.media and self.media.level) or 50
            local level = math.max(0, math.min(100, current + delta))
            if self.on_volume then self.on_volume(level) end
        end
    end

    return VerticalGroup:new{
        align = "left",
        top,
        VerticalSpan:new{ width = m.gap },
        self.volume_label,
        VerticalSpan:new{ width = m.gap },
        HorizontalGroup:new{
            self:button("Vol −", key_w, bar_h, step(-10), { font_size = 18 }),
            HorizontalSpan:new{ width = m.gap },
            self.volume_bar,
            HorizontalSpan:new{ width = m.gap },
            self:button("Vol +", key_w, bar_h, step(10), { font_size = 18 }),
            HorizontalSpan:new{ width = m.gap },
            self:button("Mute", key_w, bar_h, cmd("audio.mute", "Mute"), { font_size = 18 }),
        },
    }
end

function ControllerScreen:agentCard(a, w, h, index)
    local state = a.label or a.state or ""
    if a.progress and a.progress ~= "" then state = state .. " · " .. a.progress end
    return W.Card:new{
        width = w,
        height = h,
        lines = { { a.project or "session", 16, true }, { state, 14, true }, { a.summary or "", 14 } },
        selected = index == self.agent_index,
        inverted = a.state == "waiting",
        shaded = a.state == "error",
        callback = self:tap(self.on_select_agent, index),
        show_parent = self,
        feedback_ms = self.cfg.ui.feedback_ms,
    }
end

--- 右邊：選中 session 的進度（任務清單會依高度裁切，保留目前在做的那項）
function ControllerScreen:agentDetail(a, w, h)
    local m = W.metrics()
    local text_w = w - 2 * m.border - 2 * m.pad
    local group = VerticalGroup:new{ align = "left" }
    local used = 0
    local function add(text, size, bold)
        local t = W.text(text, size, bold, text_w)
        table.insert(group, t)
        used = used + t:getSize().h
        return t
    end
    add(a.project or "session", 18, true)
    add(string.format("%s · %s", a.label or "", a.elapsed or ""), 14)
    if a.prompt and a.prompt ~= "" then add("“" .. a.prompt .. "”", 14) end
    table.insert(group, VerticalSpan:new{ width = m.gap })
    used = used + m.gap

    local tasks = a.tasks or {}
    local probe = W.text("Ag", 14)
    local line_h = probe:getSize().h
    probe:free()
    local footer_h = (a.step and a.step ~= "") and (line_h + m.gap) or 0
    local room = math.max(0, math.floor((h - 2 * m.border - 2 * m.pad - used - footer_h) / line_h))
    local first = 1
    if #tasks > room then
        local current = #tasks
        for i, t in ipairs(tasks) do
            if t.status ~= "completed" then current = i; break end
        end
        first = math.max(1, math.min(current - 1, #tasks - room + 1))
    end
    for i = first, math.min(#tasks, first + room - 1) do
        local t = tasks[i]
        add((TASK_MARK[t.status] or "○") .. "  " .. (t.text or ""), 14, t.status == "in_progress")
    end
    if #tasks == 0 then add("No task list", 14) end
    if footer_h > 0 then
        table.insert(group, VerticalSpan:new{ width = m.gap })
        add("Now: " .. a.step, 14)
    end
    return W.tile(w, h, group)
end

-- 左：session 格（2×2，可翻頁）；右：選中那格的進度；下：Codex Micro 風格的按鍵列
function ControllerScreen:buildAgents(width, height)
    local m = W.metrics()
    local agents = self.agents
    if agents == nil or #agents == 0 then
        local group = VerticalGroup:new{ align = "center" }
        table.insert(group, W.text(agents == nil and "Looking for Claude Code sessions…" or "No active sessions",
            22, true, width - 4 * m.pad))
        if agents ~= nil then
            table.insert(group, VerticalSpan:new{ width = m.gap })
            table.insert(group, W.text("Start Claude Code on the Mac with the MacDeck hooks installed", 14, false,
                width - 4 * m.pad))
        end
        return W.tile(width, height, group, { center = true })
    end

    local keys_h = m.footer_h
    local main_h = height - keys_h - m.gap
    local left_w = math.floor((width - m.gap) / 2)
    local right_w = width - m.gap - left_w

    local per_page = ControllerScreen.AGENTS_PER_PAGE
    local pages = math.max(1, math.ceil(#agents / per_page))
    local page = math.max(1, math.min(self.agent_page or 1, pages))
    local first = (page - 1) * per_page + 1
    local nav_h = pages > 1 and math.floor(m.footer_h * 0.7) or 0
    local grid_h = main_h - (pages > 1 and (nav_h + m.gap) or 0)
    local cell_w = math.floor((left_w - m.gap) / 2)
    local cell_h = math.floor((grid_h - m.gap) / 2)
    local grid = VerticalGroup:new{ align = "left" }
    self.agent_cards = {}
    for row = 0, 1 do
        if row > 0 then table.insert(grid, VerticalSpan:new{ width = m.gap }) end
        local line = HorizontalGroup:new{ align = "top" }
        for col = 0, 1 do
            local i = first + row * 2 + col
            local w = col == 0 and cell_w or (left_w - m.gap - cell_w)
            if col > 0 then table.insert(line, HorizontalSpan:new{ width = m.gap }) end
            if agents[i] then
                local card = self:agentCard(agents[i], w, cell_h, i)
                self.agent_cards[i] = card
                table.insert(line, card)
            else
                table.insert(line, HorizontalSpan:new{ width = w }) -- 空位不畫格子
            end
        end
        table.insert(grid, line)
    end
    if pages > 1 then
        table.insert(grid, VerticalSpan:new{ width = m.gap })
        table.insert(grid, W.buttonRow({
            { text = "‹", callback = page > 1 and self:tap(self.on_list_page, -1) or nil },
            { text = string.format("%d / %d", page, pages) },
            { text = "›", callback = page < pages and self:tap(self.on_list_page, 1) or nil },
        }, left_w, nav_h, self, self.cfg.ui.feedback_ms))
    end

    local current = agents[self.agent_index] or agents[1]
    local function key(text, name)
        return { text = text, font_size = 16, callback = self:tap(self.on_agent_key, name) }
    end
    -- Dictate 比較寬，和 Codex Micro 的長鍵一樣
    local unit = math.floor((width - 5 * m.gap) / 6.6)
    local small = {
        key("Auto", "auto"), key("Approve", "approve"), key("Stop", "stop"), key("Open", "open"),
    }
    local keys = HorizontalGroup:new{
        W.buttonRow(small, 4 * unit + 3 * m.gap, keys_h, self, self.cfg.ui.feedback_ms),
        HorizontalSpan:new{ width = m.gap },
        W.buttonRow({ key("Dictate", "dictate") }, math.floor(unit * 1.6), keys_h, self, self.cfg.ui.feedback_ms),
        HorizontalSpan:new{ width = m.gap },
        W.buttonRow({ key("Send", "send") }, width - 4 * unit - 5 * m.gap - math.floor(unit * 1.6), keys_h,
            self, self.cfg.ui.feedback_ms),
    }

    return VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            align = "top",
            grid,
            HorizontalSpan:new{ width = m.gap },
            self:agentDetail(current, right_w, main_h),
        },
        VerticalSpan:new{ width = m.gap },
        keys,
    }
end

function ControllerScreen:buildMessage(width, height)
    local m = W.metrics()
    local text_w = width - 4 * m.pad
    local group = VerticalGroup:new{ align = "center" }
    if self.mode == "CONNECTING" then
        table.insert(group, W.text("Connecting to Mac…", 26, true, text_w))
        table.insert(group, VerticalSpan:new{ width = m.gap })
        table.insert(group, W.text("Tap ← Clock to cancel", 16, false, text_w))
    else
        table.insert(group, W.text("Mac not connected", 26, true, text_w))
        table.insert(group, VerticalSpan:new{ width = m.gap })
        table.insert(group, W.text(self.message or "", 16, false, text_w))
        table.insert(group, VerticalSpan:new{ width = m.gap * 2 })
        -- TODO(Phase 2): Wi-Fi Fallback 按鈕
        table.insert(group, W.buttonRow({
            { text = "Retry", callback = self:tap(self.on_retry) },
        }, math.floor(width / 3), m.footer_h, self, self.cfg.ui.feedback_ms))
    end
    return W.tile(width, height, group, { center = true })
end

function ControllerScreen:init()
    local m = W.metrics()
    local status_h = m.header_h
    local body_h = m.inner_h - m.header_h - status_h - m.footer_h - 3 * m.gap
    local page = self.mode == "CONTROL" and self.page or "home"

    local header, _, status_text = W.header(TITLES[page], STATUS[self.mode] or "", m.inner_w)
    self.status_text = status_text

    local body
    if self.mode ~= "CONTROL" then
        body = self:buildMessage(m.inner_w, body_h)
    elseif page == "media" then
        body = self:buildMedia(m.inner_w, body_h)
    elseif page == "agents" then
        body = self:buildAgents(m.inner_w, body_h)
    else
        body = self:buildHome(m.inner_w, body_h)
    end

    self.result_text = W.text(self.status ~= "" and self.status or " ", 16, false, m.inner_w)
    self.result_region = W.Region:new{
        LeftContainer:new{ dimen = Geom:new{ w = m.inner_w, h = status_h }, self.result_text },
    }

    local buttons = {}
    if self.mode == "CONTROL" and page ~= "home" then
        table.insert(buttons, { text = "← Back", callback = self:tap(self.on_page, "home") })
    end
    table.insert(buttons, { text = "← Clock", callback = self.on_clock })
    table.insert(buttons, { text = "Exit → KOReader", callback = self.on_exit })
    local footer = W.buttonRow(buttons, m.inner_w, m.footer_h, self, self.cfg.ui.feedback_ms)

    self:setContent(VerticalGroup:new{
        align = "left",
        header,
        VerticalSpan:new{ width = m.gap },
        body,
        VerticalSpan:new{ width = m.gap },
        self.result_region,
        VerticalSpan:new{ width = m.gap },
        footer,
    })

    self.ges_events = {
        TapController = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

-- 點到按鈕以外的地方：只重設閒置計時
function ControllerScreen:onTapController()
    self:activity()
    return true
end

--- 底部狀態列：顯示最近一次命令與 ACK（局部刷新）
function ControllerScreen:setResult(text)
    self.result_text:setText(text)
    UIManager:setDirty(self, function() return "ui", self.result_region.dimen end)
end

--- Media 頁：更新音量條與文字（只刷新那兩塊）
function ControllerScreen:setVolume(level, muted)
    self.media = { level = level, muted = muted }
    if not self.volume_bar then return end
    self.volume_bar:setValue(muted and 0 or toSegments(level))
    self.volume_text:setText(self:volumeLabel())
    UIManager:setDirty(self, function() return "ui", self.volume_label.dimen end)
end

return ControllerScreen
