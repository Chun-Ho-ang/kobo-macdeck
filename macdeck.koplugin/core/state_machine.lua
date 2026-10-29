-- 狀態與轉換（規格書 04 章）
-- 純 Lua，不依賴 KOReader，可在電腦上直接測試
local M = {}

M.STATES = {
    INIT = "INIT",
    CLOCK = "CLOCK",
    CONNECTING = "CONNECTING",
    CONTROL = "CONTROL",
    OFFLINE = "OFFLINE",
    EXITED = "EXITED",
}

-- transitions[state][event] = next_state；"*" 對所有非終止狀態生效
M.MACDECK_TRANSITIONS = {
    INIT = { open = "CLOCK" },
    CLOCK = { control = "CONNECTING" },
    CONNECTING = { connected = "CONTROL", failed = "OFFLINE", clock = "CLOCK" },
    CONTROL = { clock = "CLOCK", idle_timeout = "CLOCK", disconnected = "OFFLINE" },
    OFFLINE = { retry = "CONNECTING", clock = "CLOCK", idle_timeout = "CLOCK" },
    ["*"] = { exit = "EXITED", resume = "CLOCK" },
}

local Machine = {}
Machine.__index = Machine

--- opts: initial, transitions, terminal (set), on_enter(to, from, event), on_error(err)
function M.new(opts)
    return setmetatable({
        state = opts.initial,
        transitions = opts.transitions,
        terminal = opts.terminal or { EXITED = true },
        on_enter = opts.on_enter,
        on_error = opts.on_error,
        _queue = {},
        _busy = false,
    }, Machine)
end

function Machine:lookup(event)
    if self.terminal[self.state] then
        return nil
    end
    local row = self.transitions[self.state]
    local nxt = row and row[event]
    if nxt == nil and self.transitions["*"] then
        nxt = self.transitions["*"][event]
    end
    return nxt
end

function Machine:can(event)
    return self:lookup(event) ~= nil
end

-- on_enter 內再 fire 的事件會排隊處理，避免重入
-- on_enter 出錯時呼叫 on_error，狀態機不會卡死（保證 Exit 永遠可用）
function Machine:fire(event)
    table.insert(self._queue, event)
    if self._busy then
        return
    end
    self._busy = true
    while #self._queue > 0 do
        local ev = table.remove(self._queue, 1)
        local nxt = self:lookup(ev)
        if nxt then
            local prev = self.state
            self.state = nxt
            if self.on_enter then
                local ok, err = pcall(self.on_enter, nxt, prev, ev)
                if not ok and self.on_error then
                    pcall(self.on_error, err)
                end
            end
        end
    end
    self._busy = false
end

return M
