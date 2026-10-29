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
        sync_min = 15, -- 時鐘畫面每 N 分鐘向 Mac 拿一次天氣 / 下一個行程；0 = 不同步
    },
    idle = { controller_timeout_sec = 60 },
    transport = {
        preferred = "mock", -- "mock" = 假資料；"wifi" = 連 mac-companion
        connect_timeout_sec = 10,
        wifi = {
            host = "", -- Mac 的區網 IP，companion 啟動時會印出來
            port = 8765,
            token = "", -- mac-companion/token.txt 的內容
            request_timeout_sec = 3, -- 每個指令最多卡住畫面幾秒
        },
        mock_connect_delay_sec = 0.5,
        mock_fail_connect = false, -- 設為 true 可測 OFFLINE 畫面（T-05）
        mock_agent_count = 4, -- 假 Claude Code session 數量，用來測分頁
    },
    agents = {
        poll_sec = 5, -- Agents 頁開著時每幾秒問一次 Mac
        stay_open = true, -- Agents 頁不因閒置跳回時鐘（當成桌面狀態板）
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
    if cfg.transport.preferred ~= "mock" and cfg.transport.preferred ~= "wifi" then
        cfg.transport.preferred = "mock"
    end
    cfg.transport.wifi.port = clamp(math.floor(cfg.transport.wifi.port), 1, 65535)
    cfg.transport.wifi.request_timeout_sec = clamp(cfg.transport.wifi.request_timeout_sec, 1, 10)
    cfg.transport.mock_agent_count = clamp(math.floor(cfg.transport.mock_agent_count), 0, 12)
    cfg.agents.poll_sec = clamp(cfg.agents.poll_sec, 2, 300)
    cfg.clock.full_refresh_min = clamp(cfg.clock.full_refresh_min, 0, 24 * 60)
    cfg.clock.sync_min = clamp(math.floor(cfg.clock.sync_min), 0, 24 * 60)
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
