-- Mac 控制畫面
-- mode = CONNECTING / CONTROL / OFFLINE；CONTROL 再分成 page = home / media / monitor
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
    displays = nil, -- nil = 讀取中；{ { id, name, brightness }, ... }
    display_index = 1, -- 在完整清單中的位置
    display_page = 1, -- 螢幕清單分頁（螢幕數量不固定）
    on_activity = nil, -- 任何觸控都呼叫，用來重設閒置逾時
    on_page = nil, -- function(page)
    on_command = nil, -- function(action, args, label)
    on_volume = nil, -- function(level)
    on_select_display = nil, -- function(index)
    on_brightness = nil, -- function(level)
    on_list_page = nil, -- function(delta)
    on_refresh = nil, -- 重新向 Mac 讀取螢幕清單（插拔螢幕後）
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
    monitor = "MONITOR CONTROL",
}

-- 每頁最多幾台螢幕；超過就分頁，按鈕維持夠大好點
ControllerScreen.DISPLAYS_PER_PAGE = 4

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
        self:button("Monitor control", width - m.gap - w, height, self:tap(self.on_page, "monitor"), { font_size = 26 }),
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

function ControllerScreen:displayLabel(d)
    if d.brightness == nil then return d.name end
    return string.format("%s · %d%%", d.name, d.brightness)
end

-- 左邊：螢幕選擇；右邊：所選螢幕的亮度條 + 亮 / 暗
function ControllerScreen:buildMonitor(width, height)
    local m = W.metrics()
    local displays = self.displays
    if displays == nil or #displays == 0 then
        local group = VerticalGroup:new{ align = "center" }
        table.insert(group, W.text(displays == nil and "Looking for displays…" or "No displays found",
            24, true, width - 4 * m.pad))
        if displays ~= nil then
            table.insert(group, VerticalSpan:new{ width = m.gap * 2 })
            table.insert(group, W.buttonRow({ { text = "Refresh", callback = self:tap(self.on_refresh) } },
                math.floor(width / 3), m.footer_h, self, self.cfg.ui.feedback_ms))
        end
        return W.tile(width, height, group, { center = true })
    end

    local list_w = math.floor((width - m.gap) * 0.6)
    local right_w = width - m.gap - list_w
    local per_page = ControllerScreen.DISPLAYS_PER_PAGE
    local pages = math.max(1, math.ceil(#displays / per_page))
    local page = math.max(1, math.min(self.display_page or 1, pages))
    local first = (page - 1) * per_page + 1
    local last = math.min(#displays, first + per_page - 1)
    -- 有分頁時每頁都用同樣的格高，翻頁時版面不跳動
    local slots = pages > 1 and per_page or (last - first + 1)
    local nav_h = m.footer_h
    local list_h = height - nav_h - m.gap
    local item_h = math.floor((list_h - (slots - 1) * m.gap) / slots)
    local list = VerticalGroup:new{ align = "left" }
    self.display_buttons = {}
    for i = first, last do
        if i > first then table.insert(list, VerticalSpan:new{ width = m.gap }) end
        local b = self:button(self:displayLabel(displays[i]), list_w, item_h,
            self:tap(self.on_select_display, i), { font_size = 20, selected = i == self.display_index })
        self.display_buttons[i] = b
        table.insert(list, b)
    end
    local used_h = (last - first + 1) * item_h + (last - first) * m.gap
    if used_h < list_h then table.insert(list, VerticalSpan:new{ width = list_h - used_h }) end

    local nav = { { text = "Refresh", callback = self:tap(self.on_refresh) } }
    if pages > 1 then
        table.insert(nav, { text = "‹", callback = page > 1 and self:tap(self.on_list_page, -1) or nil })
        table.insert(nav, { text = string.format("%d / %d", page, pages) })
        table.insert(nav, { text = "›", callback = page < pages and self:tap(self.on_list_page, 1) or nil })
    end
    table.insert(list, VerticalSpan:new{ width = m.gap })
    table.insert(list, W.buttonRow(nav, list_w, nav_h, self, self.cfg.ui.feedback_ms))

    local current = displays[self.display_index] or displays[1]
    local label_h = m.header_h
    local body_h = height - label_h - m.gap
    local bar_w = math.floor((right_w - m.gap) * 0.5)
    local key_w = right_w - m.gap - bar_w
    local key_h = math.floor((body_h - m.gap) / 2)
    self.brightness_text = W.text(current.brightness and string.format("Brightness: %d%%", current.brightness)
        or "Brightness: —", 18, true, right_w)
    self.brightness_label = W.Region:new{
        LeftContainer:new{ dimen = Geom:new{ w = right_w, h = label_h }, self.brightness_text },
    }
    self.brightness_bar = W.SegmentBar:new{
        width = bar_w,
        height = body_h,
        vertical = true,
        value = toSegments(current.brightness),
        show_parent = self,
        on_change = function(idx)
            self:activity()
            if self.on_brightness then self.on_brightness(idx * 10) end
        end,
    }
    local function step(delta)
        return function()
            self:activity()
            local level = math.max(10, math.min(100, (current.brightness or 50) + delta))
            if self.on_brightness then self.on_brightness(level) end
        end
    end

    return HorizontalGroup:new{
        align = "top",
        list,
        HorizontalSpan:new{ width = m.gap },
        VerticalGroup:new{
            align = "left",
            self.brightness_label,
            VerticalSpan:new{ width = m.gap },
            HorizontalGroup:new{
                align = "top",
                self.brightness_bar,
                HorizontalSpan:new{ width = m.gap },
                VerticalGroup:new{
                    self:button("Brighter", key_w, key_h, step(10), { font_size = 18 }),
                    VerticalSpan:new{ width = m.gap },
                    self:button("Dimmer", key_w, body_h - m.gap - key_h, step(-10), { font_size = 18 }),
                },
            },
        },
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
    elseif page == "monitor" then
        body = self:buildMonitor(m.inner_w, body_h)
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

--- Monitor 頁：更新目前螢幕的亮度
function ControllerScreen:setBrightness(level)
    local d = self.displays and self.displays[self.display_index]
    if not d or not self.brightness_bar then return end
    d.brightness = level
    self.brightness_bar:setValue(toSegments(level))
    self.brightness_text:setText(string.format("Brightness: %d%%", level))
    UIManager:setDirty(self, function() return "ui", self.brightness_label.dimen end)
    local b = self.display_buttons[self.display_index]
    if b then b:setText(self:displayLabel(d)) end
end

return ControllerScreen
