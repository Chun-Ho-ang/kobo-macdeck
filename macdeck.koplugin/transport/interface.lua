-- 統一 transport 介面：每個 transport 物件提供
--   connect(on_done(ok, err))、send(action, args, on_ack(ack))、disconnect()
-- ACK 可帶 data（例如 volume.get、agents.list 的結果）
-- mock：模擬 Mac 端的音量與 Claude Code session 狀態
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

local MOCK_AGENTS = {
    { project = "kobo-macdeck", state = "working", label = "Working", summary = "Edit wifi.lua", progress = "2/5",
      elapsed = "4m 12s", prompt = "Add Wi-Fi transport", step = "Edit transport/wifi.lua",
      tasks = {
          { text = "Read transport and server", status = "completed" },
          { text = "Add pairing token", status = "completed" },
          { text = "Implement Wi-Fi transport", status = "in_progress" },
          { text = "Add tests", status = "pending" },
          { text = "Update README", status = "pending" },
      } },
    { project = "api-server", state = "waiting", label = "Needs you", summary = "Allow Run: npm test?", progress = "",
      elapsed = "1m 03s", prompt = "Fix the failing login test", step = "Run: npm test", tasks = {} },
    { project = "blog", state = "done", label = "Done", summary = "12 min ago", progress = "3/3",
      elapsed = "6m 40s", prompt = "Write the October post", step = "", tasks = {} },
    { project = "infra", state = "error", label = "Error", summary = "rate_limit", progress = "",
      elapsed = "0m 20s", prompt = "Bump Terraform providers", step = "", tasks = {} },
}

local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end

local function mockAgents(count)
    local list = {}
    for i = 1, count do
        local a = copy(MOCK_AGENTS[i] or { project = "project-" .. i, state = "done", label = "Done",
            summary = "1 h ago", progress = "", elapsed = "2m 00s", prompt = "", step = "", tasks = {} })
        a.id = "mock-" .. i
        list[i] = a
    end
    return list
end

--- opts: ui_manager, connect_delay_sec, fail_connect, agent_count
function M.mock(opts)
    return setmetatable({
        ui = opts.ui_manager,
        delay = opts.connect_delay_sec or 0,
        fail_connect = opts.fail_connect,
        connected = false,
        state = {
            volume = 50,
            muted = false,
            agents = mockAgents(opts.agent_count or 4),
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
    elseif action == "info.get" then
        return "ok", "info", {
            weather = { temp = 17, text = "Overcast", high = 23, low = 9, unit = "C", location = "Ann Arbor" },
            event = { title = "Design review", when = "Today 14:00–15:00", location = "Room 3" },
            synced = os.date("%H:%M"),
        }
    elseif action == "agents.list" then
        return "ok", #st.agents .. " sessions", { sessions = copy(st.agents) }
    elseif action == "agent.key" or action == "agent.open" then
        for _, a in ipairs(st.agents) do
            if a.id == args.session_id then
                if action == "agent.key" and args.key == "approve" and a.state == "waiting" then
                    a.state, a.label, a.summary = "working", "Working", a.step
                end
                return "ok", (args.key or "opened") .. " (mock)"
            end
        end
        return "error", "unknown session"
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
