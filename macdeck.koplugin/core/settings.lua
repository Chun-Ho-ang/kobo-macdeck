-- 設定讀寫、預設值驗證
-- 使用者設定檔：<KOReader settings>/macdeck.lua，內容為 { config = { ... } }，只需寫要覆蓋的欄位
local M = {}

M.SCHEMA = 1

M.DEFAULTS = {
    schema = M.SCHEMA,
    ui = {
        -- "landscape" 進入時轉橫向，退出時還原；"keep" 不動方向
        orientation = "landscape",
        landscape_rotation = 1, -- 1 = 順時針, 3 = 逆時針
        feedback_ms = 250,
    },
    clock = {
        twelve_hour = false,
        location_label = "",
        -- 空字串 = 自動（例如 "EDT · UTC−04:00"）；Kobo 系統時區不可靠時可手動填，例如 "Detroit time"
        timezone_label = "",
        full_refresh_min = 30, -- 每 N 分鐘做一次全刷消殘影；0 = 關閉
    },
    idle = { controller_timeout_sec = 60 },
    transport = {
        preferred = "mock",
        connect_timeout_sec = 10,
        mock_connect_delay_sec = 0.5,
        mock_fail_connect = false, -- 設為 true 可測 OFFLINE 畫面（T-05）
        mock_display_count = 2, -- 假螢幕數量（含內建），用來測多螢幕分頁
    },
}

local function isArray(t)
    return type(t) == "table" and t[1] ~= nil
end

local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end

-- 深層合併；陣列整個取代，型別不符的欄位忽略
function M.merge(defaults, user)
    local out = copy(defaults)
    if type(user) ~= "table" then return out end
    for k, v in pairs(user) do
        local d = defaults[k]
        if d == nil then
            -- 未知欄位忽略
        elseif type(d) == "table" and not isArray(d) then
            out[k] = M.merge(d, v)
        elseif type(v) == type(d) then
            out[k] = copy(v)
        end
    end
    return out
end

local function clamp(x, lo, hi)
    return math.max(lo, math.min(hi, x))
end

function M.validate(cfg)
    cfg.idle.controller_timeout_sec = clamp(cfg.idle.controller_timeout_sec, 10, 3600)
    cfg.transport.connect_timeout_sec = clamp(cfg.transport.connect_timeout_sec, 1, 60)
    cfg.ui.feedback_ms = clamp(cfg.ui.feedback_ms, 0, 1000)
    cfg.transport.mock_display_count = clamp(math.floor(cfg.transport.mock_display_count), 0, 16)
    cfg.clock.full_refresh_min = clamp(cfg.clock.full_refresh_min, 0, 24 * 60)
    if cfg.ui.landscape_rotation ~= 1 and cfg.ui.landscape_rotation ~= 3 then
        cfg.ui.landscape_rotation = 1
    end
    return cfg
end

function M.settingsPath()
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir() .. "/macdeck.lua"
end

function M.load()
    local ok, user = pcall(function()
        local LuaSettings = require("luasettings")
        return LuaSettings:open(M.settingsPath()):readSetting("config")
    end)
    return M.validate(M.merge(M.DEFAULTS, ok and user or nil))
end

return M
