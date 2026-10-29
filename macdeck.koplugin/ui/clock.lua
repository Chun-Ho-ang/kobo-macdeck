-- Idle 時鐘與資訊顯示（規格 5.1）
-- 點擊畫面任一處（Exit 以外）進入 Controller
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Timezone = require("core/timezone")
local W = require("ui/widgets")

local ClockScreen = W.ScreenBase:extend{
    name = "macdeck_clock",
    cfg = nil,
    on_control = nil,
    on_exit = nil,
}

local font_size_cache = {}

-- 找出能塞進 w×h 的最大時間字級（以最寬的 "88:88" 量測）
local function timeFontSize(w, h)
    local key = w .. "x" .. h
    if font_size_cache[key] then return font_size_cache[key] end
    local size = TextWidget:getFontSizeToFitHeight("cfont", h, 0)
    while size > 10 do
        local probe = TextWidget:new{ text = "88:88", face = Font:getFace("cfont", size), bold = true, padding = 0 }
        local fits = probe:getSize().w <= w
        probe:free()
        if fits then break end
        size = size - 4
    end
    font_size_cache[key] = size
    return size
end

function ClockScreen:formatTime()
    if self.cfg.clock.twelve_hour then
        return (os.date("%I:%M"):gsub("^0", ""))
    end
    return os.date("%H:%M")
end

function ClockScreen:formatDate()
    return os.date("%a %d %b"):upper()
end

--- 第二行：「地點 · 時區」，沒設地點就只顯示時區
function ClockScreen:formatZone()
    local location = self.cfg.clock.location_label
    local zone = Timezone.label(self.cfg)
    return location ~= "" and (location .. " · " .. zone) or zone
end

function ClockScreen:init()
    local m = W.metrics()
    local body_h = m.inner_h - m.header_h - m.footer_h - 2 * m.gap
    local left_w = math.floor((m.inner_w - m.gap) * 0.55)
    local right_w = m.inner_w - m.gap - left_w
    local text_w = left_w - 2 * m.pad - 2 * m.border

    self._last_date = self:formatDate()
    local header
    header, self.date_text = W.header(self._last_date, "KOBO MACDECK · CLOCK", m.inner_w)

    local time_h = math.floor(body_h * 0.5)
    self.time_text = TextWidget:new{
        text = self:formatTime(),
        face = Font:getFace("cfont", timeFontSize(text_w, time_h)),
        bold = true,
        padding = 0,
    }
    self.time_region = W.Region:new{
        LeftContainer:new{ dimen = Geom:new{ w = text_w, h = time_h }, self.time_text },
    }

    self._last_zone = self:formatZone()
    self.zone_text = W.text(self._last_zone, 18, false, text_w)
    local left_content = VerticalGroup:new{
        align = "left",
        self.time_region,
        self.zone_text,
        VerticalSpan:new{ width = m.gap * 2 },
        W.text("Tap to enter Mac Control →", 14, false, text_w),
    }

    local tile_h = math.floor((body_h - m.gap) / 2)
    local info_w = right_w - 2 * m.pad - 2 * m.border
    local function infoTile(title, value, h)
        return W.tile(right_w, h, VerticalGroup:new{
            align = "left",
            W.text(title, 14, true, info_w),
            VerticalSpan:new{ width = math.floor(m.gap / 2) },
            W.text(value, 18, false, info_w),
        })
    end

    local body = HorizontalGroup:new{
        align = "top",
        W.tile(left_w, body_h, left_content),
        HorizontalSpan:new{ width = m.gap },
        VerticalGroup:new{
            infoTile("WEATHER", "—° · Synced —", tile_h), -- TODO(Phase 4): services/weather
            VerticalSpan:new{ width = m.gap },
            infoTile("NEXT EVENT", "No event data", body_h - m.gap - tile_h), -- TODO(Phase 4): services/calendar
        },
    }

    local exit_w = math.floor(m.inner_w * 0.32)
    local footer = HorizontalGroup:new{
        LeftContainer:new{
            dimen = Geom:new{ w = m.inner_w - exit_w - m.gap, h = m.footer_h },
            W.text("Data: not synced", 14, false, m.inner_w - exit_w - m.gap),
        },
        HorizontalSpan:new{ width = m.gap },
        W.buttonRow({ { text = "Exit → KOReader", callback = self.on_exit } },
            exit_w, m.footer_h, self, self.cfg.ui.feedback_ms),
    }

    self:setContent(VerticalGroup:new{
        align = "left",
        header,
        VerticalSpan:new{ width = m.gap },
        body,
        VerticalSpan:new{ width = m.gap },
        footer,
    })

    self.ges_events = {
        TapClock = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function ClockScreen:onTapClock()
    if self.on_control then self.on_control() end
    return true
end

--- 每分鐘呼叫；full = true 時全刷消殘影
function ClockScreen:updateTime(full)
    self.time_text:setText(self:formatTime())
    local date = self:formatDate()
    local zone = self:formatZone()
    if full or date ~= self._last_date or zone ~= self._last_zone then
        -- 跨日、時區 / 夏令時間變動、或定期全刷：整頁重畫
        self._last_date = date
        self._last_zone = zone
        self.date_text:setText(date)
        self.zone_text:setText(zone)
        UIManager:setDirty(self, full and "full" or "ui")
    else
        UIManager:setDirty(self, function() return "ui", self.time_region.dimen end)
    end
end

return ClockScreen
