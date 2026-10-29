-- 時間與資料更新排程
-- ui_manager 由外部注入（實機用 UIManager，測試用假物件）
local M = {}

M.now = os.time -- 測試時可替換

-- 對齊下一個整分鐘；每次觸發後重新計算，避免固定 60 秒造成漂移
function M.secondsToNextMinute(now)
    now = now or os.time()
    return 60 - (now % 60)
end

local MinuteTicker = {}
MinuteTicker.__index = MinuteTicker

--- opts: ui_manager, on_tick(), now (optional, for tests)
function M.minuteTicker(opts)
    return setmetatable({
        ui = opts.ui_manager,
        on_tick = opts.on_tick,
        now = opts.now or function() return M.now() end,
    }, MinuteTicker)
end

function MinuteTicker:start()
    self:stop()
    self._minute = math.floor(self.now() / 60)
    self:_arm()
end

function MinuteTicker:_arm()
    local fn
    fn = function()
        if self._fn ~= fn then return end
        self._fn = nil
        -- timer 比牆上時間早到（時鐘校正等）時不重複觸發，只重新對齊
        local minute = math.floor(self.now() / 60)
        if minute ~= self._minute then
            self._minute = minute
            self.on_tick()
        end
        if self._fn == nil and not self._stopped then
            self:_arm()
        end
    end
    self._stopped = false
    self._fn = fn
    self.ui:scheduleIn(M.secondsToNextMinute(self.now()), fn)
end

function MinuteTicker:stop()
    self._stopped = true
    if self._fn then
        self.ui:unschedule(self._fn)
        self._fn = nil
    end
end

local Timeout = {}
Timeout.__index = Timeout

--- 可重設的一次性計時器（Controller 閒置逾時、連線逾時）
function M.timeout(ui_manager, seconds, on_fire)
    return setmetatable({ ui = ui_manager, seconds = seconds, on_fire = on_fire }, Timeout)
end

function Timeout:reset()
    self:cancel()
    local fn
    fn = function()
        if self._fn ~= fn then return end
        self._fn = nil
        self.on_fire()
    end
    self._fn = fn
    self.ui:scheduleIn(self.seconds, fn)
end

function Timeout:cancel()
    if self._fn then
        self.ui:unschedule(self._fn)
        self._fn = nil
    end
end

return M
