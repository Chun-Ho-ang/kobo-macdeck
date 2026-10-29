-- 共用元件：全螢幕畫面底座、大按鈕、可局部刷新的區塊、版面尺寸
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = Device.screen

local W = {}

-- 版面尺寸一律從目前螢幕動態計算（規格 5.3：不硬編座標）
function W.metrics()
    local m = {
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        margin = Screen:scaleBySize(14),
        gap = Screen:scaleBySize(10),
        border = Screen:scaleBySize(2),
        pad = Screen:scaleBySize(14),
        header_h = Screen:scaleBySize(34),
        footer_h = Screen:scaleBySize(64),
        line_h = Screen:scaleBySize(2),
    }
    m.inner_w = m.width - 2 * m.margin
    m.inner_h = m.height - 2 * m.margin
    return m
end

function W.text(text, size, bold, max_width)
    return TextWidget:new{
        text = text,
        face = Font:getFace("cfont", size),
        bold = bold,
        max_width = max_width,
    }
end

-- 記錄自己實際被畫在哪裡，供 setDirty 局部刷新使用
W.Region = WidgetContainer:extend{}

function W.Region:paintTo(bb, x, y)
    local size = self[1]:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }
    self[1]:paintTo(bb, x, y)
end

--- 固定尺寸的外框區塊；content 置左或置中
function W.tile(width, height, content, opts)
    opts = opts or {}
    local m = W.metrics()
    local b = opts.bordersize or m.border
    local inner = Geom:new{ w = width - 2 * b, h = height - 2 * b }
    local body
    if opts.center then
        body = CenterContainer:new{ dimen = inner, content }
    else
        body = LeftContainer:new{
            dimen = inner,
            HorizontalGroup:new{ HorizontalSpan:new{ width = m.pad }, content },
        }
    end
    return FrameContainer:new{
        bordersize = b,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        body,
    }
end

--- 頁首：左右兩段文字 + 底線；回傳 widget 與左右兩個 TextWidget（可 setText 更新）
function W.header(left, right, width)
    local m = W.metrics()
    local half = math.floor(width / 2)
    local left_text = W.text(left, 14, true, half)
    local right_text = W.text(right, 14, true, half)
    local row = HorizontalGroup:new{
        LeftContainer:new{ dimen = Geom:new{ w = half, h = m.header_h - m.line_h }, left_text },
        RightContainer:new{ dimen = Geom:new{ w = width - half, h = m.header_h - m.line_h }, right_text },
    }
    local group = VerticalGroup:new{
        row,
        LineWidget:new{ dimen = Geom:new{ w = width, h = m.line_h }, background = Blitbuffer.COLOR_BLACK },
    }
    return group, left_text, right_text
end

-- 大按鈕：點擊後局部反白 feedback_ms，再執行 callback
W.BigButton = InputContainer:extend{
    text = "",
    width = nil,
    height = nil,
    font_size = 20,
    callback = nil, -- nil = 停用
    selected = false, -- 選取中：黑底白字（例如目前選的螢幕）
    feedback_ms = 250,
    show_parent = nil,
}

function W.BigButton:init()
    local m = W.metrics()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    local label = W.text(self.text, self.font_size, self.callback ~= nil, self.width - 2 * m.pad)
    if not self.callback then
        label.fgcolor = Blitbuffer.COLOR_DARK_GRAY
    elseif self.selected then
        label.fgcolor = Blitbuffer.COLOR_WHITE
    end
    self.label = label
    self.frame = FrameContainer:new{
        bordersize = m.border,
        padding = 0,
        margin = 0,
        background = self.selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width - 2 * m.border, h = self.height - 2 * m.border },
            label,
        },
    }
    self[1] = self.frame
    self.ges_events = {
        TapBigButton = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function W.BigButton:onTapBigButton()
    if not self.callback or self._pending then
        return true -- 停用或回饋中：吃掉事件，避免連點
    end
    local parent = self.show_parent
    self.frame.invert = true
    UIManager:setDirty(parent, "fast", self.dimen)
    self._pending = function()
        self._pending = nil
        self.frame.invert = false
        UIManager:setDirty(parent, "ui", self.dimen)
        self.callback()
    end
    UIManager:scheduleIn(self.feedback_ms / 1000, self._pending)
    return true
end

function W.BigButton:setText(text)
    self.text = text
    self.label:setText(text)
    UIManager:setDirty(self.show_parent, "ui", self.dimen)
end

function W.BigButton:onCloseWidget()
    if self._pending then
        UIManager:unschedule(self._pending)
        self._pending = nil
    end
end

-- 分段滑軌：E-Ink 不適合拖曳，改成點哪一格就設到哪一格（1..segments）
-- vertical = true 時第 1 格在最下面
W.SegmentBar = InputContainer:extend{
    width = nil,
    height = nil,
    segments = 10,
    value = 0,
    vertical = false,
    on_change = nil, -- function(index)
    show_parent = nil,
}

function W.SegmentBar:init()
    local m = W.metrics()
    local n = self.segments
    local sgap = math.max(2, math.floor(m.gap / 3))
    local along = self.vertical and self.height or self.width
    local seg = math.floor((along - (n - 1) * sgap) / n)
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.frames = {}
    local group = self.vertical and VerticalGroup:new{} or HorizontalGroup:new{}
    local Span = self.vertical and VerticalSpan or HorizontalSpan
    for k = 1, n do
        local i = self.vertical and (n - k + 1) or k
        local size = self.vertical and Geom:new{ w = self.width - 2 * m.border, h = seg - 2 * m.border }
            or Geom:new{ w = seg - 2 * m.border, h = self.height - 2 * m.border }
        local frame = FrameContainer:new{
            bordersize = m.border,
            padding = 0,
            margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            WidgetContainer:new{ dimen = size },
        }
        self.frames[i] = frame
        if k > 1 then table.insert(group, Span:new{ width = sgap }) end
        table.insert(group, frame)
    end
    self[1] = group
    self:paintValue()
    self.ges_events = {
        TapSegmentBar = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function W.SegmentBar:paintValue()
    for i, frame in ipairs(self.frames) do
        frame.background = (i <= self.value) and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    end
end

function W.SegmentBar:indexAt(pos)
    local n = self.segments
    local idx
    if self.vertical then
        idx = n - math.floor((pos.y - self.dimen.y) * n / self.dimen.h)
    else
        idx = math.floor((pos.x - self.dimen.x) * n / self.dimen.w) + 1
    end
    return math.max(1, math.min(n, idx))
end

function W.SegmentBar:onTapSegmentBar(_, ges)
    local idx = self:indexAt(ges.pos)
    self:setValue(idx)
    if self.on_change then self.on_change(idx) end
    return true
end

function W.SegmentBar:setValue(v)
    self.value = math.max(0, math.min(self.segments, v))
    self:paintValue()
    UIManager:setDirty(self.show_parent, "ui", self.dimen)
end

-- 全螢幕畫面底座：白底、覆蓋整個畫面，並轉發 Close / Suspend / Resume 給擁有者
W.ScreenBase = InputContainer:extend{
    covers_fullscreen = true,
    on_closed = nil,
    on_suspend = nil,
    on_resume = nil,
}

function W.ScreenBase:setContent(content)
    local m = W.metrics()
    self.dimen = Geom:new{ x = 0, y = 0, w = m.width, h = m.height }
    self[1] = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{ dimen = Geom:new{ w = m.width, h = m.height }, content },
    }
end

function W.ScreenBase:onCloseWidget()
    if self.on_closed then self.on_closed(self) end
end

function W.ScreenBase:onSuspend()
    if self.on_suspend then self.on_suspend(self) end
end

function W.ScreenBase:onResume()
    if self.on_resume then self.on_resume(self) end
end

--- Clock / Exit 等底列按鈕：等寬排一列
function W.buttonRow(specs, width, height, show_parent, feedback_ms)
    local m = W.metrics()
    local n = #specs
    local w = math.floor((width - (n - 1) * m.gap) / n)
    local row = HorizontalGroup:new{}
    for i, s in ipairs(specs) do
        if i > 1 then table.insert(row, HorizontalSpan:new{ width = m.gap }) end
        table.insert(row, W.BigButton:new{
            text = s.text,
            width = (i == n) and (width - (n - 1) * (w + m.gap)) or w,
            height = height,
            font_size = s.font_size or 18,
            callback = s.callback,
            selected = s.selected,
            show_parent = show_parent,
            feedback_ms = feedback_ms,
        })
    end
    return row
end

return W
