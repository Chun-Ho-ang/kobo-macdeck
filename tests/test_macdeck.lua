-- 用法：tests/run_lua_tests.py（或任何 Lua 5.1+：lua tests/test_macdeck.lua）
local here = (debug.getinfo(1, "S").source:match("^@(.*)/") or ".")
package.path = here .. "/../macdeck.koplugin/?.lua;" .. here .. "/?.lua;" .. package.path

local Stubs = require("koreader_stubs")
Stubs.install()
local U = Stubs.UIManager

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local Scheduler = require("core/scheduler")
local function reset()
    U.now, U.tasks, U.stack = 0, {}, {}
    Scheduler.now = function() return 1000 + math.floor(U.now) end
    Stubs.Screen.rotation = 0
    Stubs.user_config = nil
    Stubs.errors = 0
end

-- ── core ──
local SM = require("core/state_machine")
local Settings = require("core/settings")

test("secondsToNextMinute", function()
    eq(Scheduler.secondsToNextMinute(120), 60)
    eq(Scheduler.secondsToNextMinute(179), 1)
    eq(Scheduler.secondsToNextMinute(121), 59)
end)

test("minute ticker ignores early fire", function()
    reset()
    local clock, ticks = 59, 0
    local t = Scheduler.minuteTicker{ ui_manager = U, now = function() return clock end, on_tick = function() ticks = ticks + 1 end }
    t:start(); U:advance(1) -- 計時到了但牆上時間沒動
    eq(ticks, 0); clock = 60; U:advance(1); eq(ticks, 1)
    t:stop()
end)

test("minute ticker aligns and re-arms", function()
    reset()
    local clock, ticks = 30, 0
    local t = Scheduler.minuteTicker{ ui_manager = U, now = function() return clock + U.now end, on_tick = function() ticks = ticks + 1 end }
    t:start()
    U:advance(29); eq(ticks, 0)
    U:advance(1); eq(ticks, 1, "first tick on boundary")
    U:advance(60 * 15); eq(ticks, 16, "15 more minutes")
    t:stop(); U:advance(600); eq(ticks, 16, "stopped")
end)

test("timeout reset / cancel", function()
    reset()
    local fired = 0
    local t = Scheduler.timeout(U, 60, function() fired = fired + 1 end)
    t:reset(); U:advance(59); t:reset(); U:advance(59); eq(fired, 0)
    U:advance(1); eq(fired, 1)
    t:reset(); t:cancel(); U:advance(100); eq(fired, 1)
end)

test("state machine transitions + terminal", function()
    local seen = {}
    local m = SM.new{ initial = "INIT", transitions = SM.MACDECK_TRANSITIONS, on_enter = function(to) table.insert(seen, to) end }
    m:fire("open"); m:fire("control"); m:fire("failed"); m:fire("retry"); m:fire("connected")
    eq(table.concat(seen, ","), "CLOCK,CONNECTING,OFFLINE,CONNECTING,CONTROL")
    m:fire("bogus"); eq(m.state, "CONTROL")
    m:fire("exit"); eq(m.state, "EXITED")
    m:fire("resume"); eq(m.state, "EXITED", "terminal")
end)

test("state machine survives handler error", function()
    local errs = 0
    local m = SM.new{ initial = "INIT", transitions = SM.MACDECK_TRANSITIONS,
        on_enter = function(to) if to == "CLOCK" then error("boom") end end,
        on_error = function() errs = errs + 1 end }
    m:fire("open"); eq(errs, 1); m:fire("exit"); eq(m.state, "EXITED")
end)

test("settings merge + validate", function()
    local cfg = Settings.validate(Settings.merge(Settings.DEFAULTS, {
        idle = { controller_timeout_sec = 1 }, ui = { orientation = 5 }, unknown = 1,
        buttons = { { label = "A", action = "audio.mute" } },
    }))
    eq(cfg.idle.controller_timeout_sec, 10, "clamped")
    eq(cfg.ui.orientation, "landscape", "type mismatch ignored")
    eq(#cfg.buttons, 1, "array replaced")
    eq(cfg.unknown, nil)
    eq(#Settings.DEFAULTS.buttons, 9, "defaults untouched")
end)

local Timezone = require("core/timezone")

test("timezone offset + label", function()
    eq(Timezone.formatOffset(-4 * 3600), "UTC−04:00")
    eq(Timezone.formatOffset(8 * 3600), "UTC+08:00")
    eq(Timezone.formatOffset(5.5 * 3600), "UTC+05:30")
    eq(Timezone.label({ clock = { timezone_label = "Detroit time" } }), "Detroit time")
    local expect = os.getenv("EXPECT_TZ_OFFSET")
    if expect then
        -- 1793223600 = 2026-10-28（夏令時間）；1798000000 = 2026-12-22（標準時間）
        local got = Timezone.formatOffset(Timezone.utcOffsetSeconds(1793223600)) .. "/" ..
            Timezone.formatOffset(Timezone.utcOffsetSeconds(1798000000))
        eq(got, expect, "TZ=" .. tostring(os.getenv("TZ")))
        print("  " .. tostring(os.getenv("TZ")) .. ": " .. Timezone.autoLabel(1793223600) .. " / " .. Timezone.autoLabel(1798000000))
    end
end)

-- ── plugin flow ──
local MacDeck = require("main")
local function newPlugin()
    return MacDeck:new{ ui = { menu = { registerToMainMenu = function() end } } }
end
local function tapButton(screen, label)
    local function find(w)
        if type(w) ~= "table" then return end
        if w.onTapBigButton and w.text == label then return w end
        for _, c in ipairs(w) do local r = find(c); if r then return r end end
    end
    local b = find(screen) or error("button not found: " .. label)
    b:onTapBigButton(); U:advance(1)
end

test("full flow: clock → control → command → idle → exit", function()
    reset()
    local p = newPlugin(); p:start()
    eq(p.session.machine.state, "CLOCK"); eq(Stubs.Screen.rotation, 1, "landscape")
    eq(#U.stack, 1); eq(U:top().name, "macdeck_clock")

    U:top():onTapClock()
    eq(p.session.machine.state, "CONNECTING"); eq(U:top().name, "macdeck_controller")
    U:advance(1)
    eq(p.session.machine.state, "CONTROL"); eq(#U.stack, 1, "old screen closed")

    tapButton(U:top(), "Mute")
    assert(U:top().result_text.text:find("OK"), "ack shown: " .. U:top().result_text.text)
    eq(p.session.machine.state, "CONTROL", "after mute"); tapButton(U:top(), "More…")
    eq(p.session.machine.state, "CONTROL", "disabled button ignored")

    U:advance(50); eq(p.session.machine.state, "CONTROL")
    U:top():onTapController(); U:advance(59); eq(p.session.machine.state, "CONTROL", "activity resets idle")
    U:advance(2); eq(p.session.machine.state, "CLOCK", "idle → clock")

    tapButton(U:top(), "Exit → KOReader")
    eq(p.session, nil); eq(#U.stack, 0); eq(Stubs.Screen.rotation, 0, "rotation restored")
    eq(#U.tasks, 0, "no timers left")
    eq(Stubs.errors, 0)
end)

test("exit while connecting + offline path", function()
    reset()
    Stubs.user_config = { transport = { mock_fail_connect = true, mock_connect_delay_sec = 3 } }
    local p = newPlugin(); p:start()
    U:top():onTapClock(); U:advance(3)
    eq(p.session.machine.state, "OFFLINE")
    tapButton(U:top(), "Retry"); eq(p.session.machine.state, "CONNECTING")
    tapButton(U:top(), "Exit → KOReader")
    eq(p.session, nil); eq(#U.stack, 0); eq(#U.tasks, 0, "no timers left")
end)

test("connect timeout → offline", function()
    reset()
    Stubs.user_config = { transport = { mock_connect_delay_sec = 30, connect_timeout_sec = 5 } }
    local p = newPlugin(); p:start()
    U:top():onTapClock(); U:advance(5)
    eq(p.session.machine.state, "OFFLINE")
    U:advance(60); eq(p.session.machine.state, "CLOCK", "offline idle → clock")
    p:teardown(p.session)
end)

test("resume returns to clock; external close tears down", function()
    reset()
    local p = newPlugin(); p:start()
    U:top():onTapClock(); U:advance(1)
    U:broadcastEvent({ name = "Resume" })
    eq(p.session.machine.state, "CLOCK")
    U:close(U:top())
    eq(p.session, nil); eq(Stubs.Screen.rotation, 0); eq(#U.tasks, 0)
end)

test("clock refreshes every minute and does periodic full refresh", function()
    reset()
    Stubs.user_config = { clock = { full_refresh_min = 2 } }
    local p = newPlugin(); p:start()
    local screen, calls, fulls = U:top(), 0, 0
    local orig = screen.updateTime
    screen.updateTime = function(self, full) calls = calls + 1; if full then fulls = fulls + 1 end; return orig(self, full) end
    U:advance(20 + 60 * 3 + 1) -- 1000 秒起算，20 秒後是第一個整分
    eq(calls, 4); eq(fulls, 2)
    p:teardown(p.session); eq(#U.tasks, 0)
end)

test("start twice / keep orientation", function()
    reset()
    Stubs.user_config = { ui = { orientation = "keep" } }
    local p = newPlugin(); p:start(); p:start()
    eq(#U.stack, 1); eq(Stubs.Screen.rotation, 0)
    p:onCloseWidget(); eq(#U.stack, 0)
end)

test("30 open/close cycles (T-01)", function()
    reset()
    local p = newPlugin()
    for _ = 1, 30 do
        p:start(); U:top():onTapClock(); U:advance(1)
        tapButton(U:top(), "Exit → KOReader")
    end
    eq(#U.stack, 0); eq(#U.tasks, 0); eq(Stubs.Screen.rotation, 0)
end)

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
