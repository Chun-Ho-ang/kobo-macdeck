-- 統一 transport 介面：每個 transport 物件提供
--   connect(on_done(ok, err))、send(action, args, on_ack(ack))、disconnect()
-- Phase 1 只有 mock：所有命令直接回 ok ACK
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

--- opts: ui_manager, connect_delay_sec, fail_connect
function M.mock(opts)
    return setmetatable({
        ui = opts.ui_manager,
        delay = opts.connect_delay_sec or 0,
        fail_connect = opts.fail_connect,
        connected = false,
    }, Mock)
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
        on_ack({ protocol = M.PROTOCOL, id = msg.id, type = "ack", status = "ok", detail = action .. " (mock)" })
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
