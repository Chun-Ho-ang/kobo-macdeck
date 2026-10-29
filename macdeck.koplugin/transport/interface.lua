-- 統一 transport 介面：每個 transport 物件提供
--   connect(on_done(ok, err))、send(action, args, on_ack(ack))、disconnect()
-- ACK 可帶 data（例如 volume.get、display.list 的結果）
-- Phase 1 只有 mock：模擬 Mac 端的音量與螢幕狀態
local M = {}

M.PROTOCOL = "macdeck/1"

local seq = 0
function M.nextId()
    seq = seq + 1
    return string.format("cmd-%06d", seq)
end

function M.envelope(action, args)
    return {
        protocol = M.PROTOCOL,
        id = M.nextId(),
        timestamp_ms = os.time() * 1000,
        type = "command",
        action = action,
        args = args or {},
    }
end

local Mock = {}
Mock.__index = Mock

local function mockDisplays(count)
    local list = {}
    for i = 1, count do
        if i == 1 then
            list[i] = { id = "builtin", name = "Built-in display", brightness = 70 }
        else
            list[i] = { id = tostring(i - 1), name = "External display " .. (i - 1), brightness = 50 }
        end
    end
    return list
end

--- opts: ui_manager, connect_delay_sec, fail_connect, display_count
function M.mock(opts)
    return setmetatable({
        ui = opts.ui_manager,
        delay = opts.connect_delay_sec or 0,
        fail_connect = opts.fail_connect,
        connected = false,
        state = {
            volume = 50,
            muted = false,
            displays = mockDisplays(opts.display_count or 2),
        },
    }, Mock)
end

local function clampLevel(v)
    if type(v) ~= "number" then return nil end
    return math.max(0, math.min(100, math.floor(v + 0.5)))
end

-- 回傳 status, detail, data；行為對應 mac-companion 的 dry-run
function Mock:handle(action, args)
    local st = self.state
    if action == "media.previous" or action == "media.toggle" or action == "media.next" then
        return "ok", action .. " (mock)"
    elseif action == "volume.get" then
        return "ok", "volume", { level = st.volume, muted = st.muted }
    elseif action == "volume.set" then
        local level = clampLevel(args.level)
        if not level then return "error", "invalid level" end
        st.volume, st.muted = level, false
        return "ok", "volume " .. level, { level = st.volume, muted = st.muted }
    elseif action == "audio.mute" then
        st.muted = not st.muted
        return "ok", st.muted and "muted" or "unmuted", { level = st.volume, muted = st.muted }
    elseif action == "display.list" then
        local list = {}
        for i, d in ipairs(st.displays) do list[i] = { id = d.id, name = d.name, brightness = d.brightness } end
        return "ok", #list .. " displays", { displays = list }
    elseif action == "display.brightness.set" then
        local level = clampLevel(args.level)
        for _, d in ipairs(st.displays) do
            if d.id == args.display_id and level then
                d.brightness = level
                return "ok", d.name .. " " .. level, { display_id = d.id, brightness = level }
            end
        end
        return "error", "unknown display or level"
    end
    return "error", "action not allowed: " .. tostring(action)
end

function Mock:connect(on_done)
    self:_cancelPending()
    self._pending = function()
        self._pending = nil
        if self.fail_connect then
            on_done(false, "mock: connect failed")
        else
            self.connected = true
            on_done(true)
        end
    end
    self.ui:scheduleIn(self.delay, self._pending)
end

function Mock:send(action, args, on_ack)
    local msg = M.envelope(action, args)
    self.ui:nextTick(function()
        if not self.connected then
            on_ack({ protocol = M.PROTOCOL, id = msg.id, type = "ack", status = "error", detail = "not connected" })
            return
        end
        local status, detail, data = self:handle(action, msg.args)
        on_ack({ protocol = M.PROTOCOL, id = msg.id, type = "ack", status = status, detail = detail, data = data })
    end)
end

function Mock:_cancelPending()
    if self._pending then
        self.ui:unschedule(self._pending)
        self._pending = nil
    end
end

function Mock:disconnect()
    self:_cancelPending()
    self.connected = false
end

return M
