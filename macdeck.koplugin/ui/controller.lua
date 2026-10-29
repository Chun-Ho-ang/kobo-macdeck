-- 觸控快捷鍵（規格 5.2）：3x3 大按鈕 + Clock / Exit 底列
-- mode = CONNECTING / CONTROL / OFFLINE，三種畫面都保留 Clock 與 Exit
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local W = require("ui/widgets")

local ControllerScreen = W.ScreenBase:extend{
    name = "macdeck_controller",
    cfg = nil,
    mode = "CONTROL",
    status = "",
    message = nil, -- OFFLINE 時的錯誤說明
    on_command = nil, -- function(button_spec)
    on_activity = nil, -- 任何觸控都呼叫，用來重設閒置逾時
    on_retry = nil,
    on_clock = nil,
    on_exit = nil,
}

local STATUS = {
    CONNECTING = "Mac: Connecting…",
    CONTROL = "Mac: Connected (mock)",
    OFFLINE = "Mac: Offline",
}

function ControllerScreen:activity()
    if self.on_activity then self.on_activity() end
end

function ControllerScreen:buildGrid(width, height)
    local m = W.metrics()
    local buttons = self.cfg.buttons
    local rows = math.max(1, math.ceil(#buttons / 3))
    local cell_w = math.floor((width - 2 * m.gap) / 3)
    local cell_h = math.floor((height - (rows - 1) * m.gap) / rows)
    local grid = VerticalGroup:new{ align = "left" }
    for r = 1, rows do
        if r > 1 then table.insert(grid, VerticalSpan:new{ width = m.gap }) end
        local row = HorizontalGroup:new{}
        for c = 1, 3 do
            local spec = buttons[(r - 1) * 3 + c]
            if spec then
                if c > 1 then table.insert(row, HorizontalSpan:new{ width = m.gap }) end
                table.insert(row, W.BigButton:new{
                    text = spec.label,
                    width = cell_w,
                    height = cell_h,
                    font_size = 22,
                    show_parent = self,
                    feedback_ms = self.cfg.ui.feedback_ms,
                    callback = spec.action and function()
                        self:activity()
                        if self.on_command then self.on_command(spec) end
                    end or nil,
                })
            end
        end
        table.insert(grid, row)
    end
    return grid
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
            { text = "Retry", callback = function()
                self:activity()
                if self.on_retry then self.on_retry() end
            end },
        }, math.floor(width / 3), m.footer_h, self, self.cfg.ui.feedback_ms))
    end
    return W.tile(width, height, group, { center = true })
end

function ControllerScreen:init()
    local m = W.metrics()
    local status_h = m.header_h
    local body_h = m.inner_h - m.header_h - status_h - m.footer_h - 3 * m.gap

    local header, _, status_text = W.header("MAC CONTROL", STATUS[self.mode] or "", m.inner_w)
    self.status_text = status_text

    local body
    if self.mode == "CONTROL" then
        body = self:buildGrid(m.inner_w, body_h)
    else
        body = self:buildMessage(m.inner_w, body_h)
    end

    self.result_text = W.text(self.status ~= "" and self.status or " ", 16, false, m.inner_w)
    self.result_region = W.Region:new{
        LeftContainer:new{ dimen = Geom:new{ w = m.inner_w, h = status_h }, self.result_text },
    }

    local footer = W.buttonRow({
        { text = "← Clock", callback = self.on_clock },
        { text = "Exit → KOReader", callback = self.on_exit },
    }, m.inner_w, m.footer_h, self, self.cfg.ui.feedback_ms)

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

return ControllerScreen
