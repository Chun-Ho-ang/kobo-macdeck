-- 最小 KOReader 假環境：只為了在電腦上跑插件邏輯，不負責畫面正確性
local Stubs = {}

local function class(base)
    local C = base and setmetatable({}, { __index = base }) or {}
    C.__index = C
    function C:extend(o)
        o = o or {}
        setmetatable(o, { __index = self })
        o.__index = o
        return o
    end
    function C:new(o)
        o = o or {}
        setmetatable(o, { __index = self })
        if o.init then o:init() end
        return o
    end
    return C
end

local Widget = class()
function Widget:getSize() return { w = 100, h = 20 } end
function Widget:paintTo() end
function Widget:free() end
function Widget:handleEvent(ev)
    local h = self["on" .. ev.name]
    if h then return h(self, table.unpack(ev.args or {})) end
end

local WidgetContainer = Widget:extend{}
function WidgetContainer:handleEvent(ev)
    for _, child in ipairs(self) do
        if type(child) == "table" and child.handleEvent and child:handleEvent(ev) then return true end
    end
    return Widget.handleEvent(self, ev)
end

local TextWidget = Widget:extend{}
function TextWidget:getSize() return { w = #self.text * 10, h = 20 } end
function TextWidget:setText(t) self.text = t end
function TextWidget:getFontSizeToFitHeight(_, h) return h end

Stubs.UIManager = {
    now = 0, tasks = {}, stack = {}, dirty = 0,
}
local U = Stubs.UIManager
function U:scheduleIn(sec, fn) table.insert(self.tasks, { at = self.now + sec, fn = fn }) end
function U:nextTick(fn) self:scheduleIn(0, fn) end
function U:unschedule(fn)
    for i = #self.tasks, 1, -1 do if self.tasks[i].fn == fn then table.remove(self.tasks, i) end end
end
function U:advance(sec)
    local target = self.now + sec
    while true do
        table.sort(self.tasks, function(a, b) return a.at < b.at end)
        local t = self.tasks[1]
        if not t or t.at > target then break end
        table.remove(self.tasks, 1)
        self.now = t.at
        t.fn()
    end
    self.now = target
end
function U:show(w) table.insert(self.stack, w) end
function U:close(w)
    for i, x in ipairs(self.stack) do
        if x == w then table.remove(self.stack, i); w:handleEvent({ name = "CloseWidget" }); return end
    end
end
function U:top() return self.stack[#self.stack] end
function U:setDirty() self.dirty = self.dirty + 1 end
function U:broadcastEvent(ev)
    if ev.name == "SetRotationMode" then Stubs.Screen.rotation = ev.args[1] end
    for _, w in ipairs(self.stack) do w:handleEvent(ev) end
end

Stubs.Screen = {
    rotation = 0,
    DEVICE_ROTATED_UPRIGHT = 0, DEVICE_ROTATED_CLOCKWISE = 1,
    DEVICE_ROTATED_UPSIDE_DOWN = 2, DEVICE_ROTATED_COUNTER_CLOCKWISE = 3,
}
function Stubs.Screen:getRotationMode() return self.rotation end
function Stubs.Screen:getWidth() return (self.rotation % 2 == 1) and 1448 or 1072 end
function Stubs.Screen:getHeight() return (self.rotation % 2 == 1) and 1072 or 1448 end
function Stubs.Screen:scaleBySize(n) return n * 2 end

local function geom(o) return o or {} end

function Stubs.install()
    local P = package.preload
    P["device"] = function() return { screen = Stubs.Screen } end
    P["ui/uimanager"] = function() return U end
    P["ui/event"] = function() return { new = function(_, name, ...) return { name = name, args = { ... } } end } end
    P["ui/geometry"] = function() return { new = function(_, o) return geom(o) end } end
    P["ui/gesturerange"] = function() return { new = function(_, o) return o end } end
    P["ui/font"] = function() return { getFace = function(_, n, s) return { name = n, size = s } end } end
    P["ffi/blitbuffer"] = function() return { COLOR_WHITE = 0, COLOR_BLACK = 1, COLOR_DARK_GRAY = 2, COLOR_LIGHT_GRAY = 3 } end
    P["ui/widget/textwidget"] = function() return TextWidget end
    for _, m in ipairs({
        "ui/widget/container/widgetcontainer", "ui/widget/container/inputcontainer",
        "ui/widget/container/framecontainer", "ui/widget/container/centercontainer",
        "ui/widget/container/leftcontainer", "ui/widget/container/rightcontainer",
        "ui/widget/horizontalgroup", "ui/widget/verticalgroup",
    }) do
        P[m] = function() return WidgetContainer:extend{} end
    end
    for _, m in ipairs({ "ui/widget/horizontalspan", "ui/widget/verticalspan", "ui/widget/linewidget" }) do
        P[m] = function() return Widget:extend{} end
    end
    P["logger"] = function() return { err = function(...) Stubs.errors = (Stubs.errors or 0) + 1; print("logger.err", ...) end, dbg = function() end, info = function() end } end
    P["gettext"] = function() return function(s) return s end end
    P["luasettings"] = function() return { open = function() return { readSetting = function() return Stubs.user_config end } end } end
    P["datastorage"] = function() return { getSettingsDir = function() return "/tmp" end } end
end

return Stubs
