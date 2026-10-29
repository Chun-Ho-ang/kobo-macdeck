-- 時區顯示：時間本身一律來自 os.date（裝置本機時間），這裡只負責產生標籤
-- 純 Lua，不依賴 KOReader
local M = {}

--- 本機時間相對 UTC 的秒數（含夏令時間）
function M.utcOffsetSeconds(t)
    t = t or os.time()
    local lt = os.date("*t", t)
    local ut = os.date("!*t", t)
    ut.isdst = lt.isdst -- 讓 os.time 用和本機相同的 DST 假設解讀 UTC 欄位
    return os.difftime(t, os.time(ut))
end

function M.formatOffset(seconds)
    local sign = seconds < 0 and "−" or "+"
    local m = math.floor(math.abs(seconds) / 60 + 0.5)
    return string.format("UTC%s%02d:%02d", sign, math.floor(m / 60), m % 60)
end

--- 自動標籤，例如 "EDT · UTC−04:00"；系統沒有時區縮寫時只顯示偏移
function M.autoLabel(t)
    local offset = M.formatOffset(M.utcOffsetSeconds(t))
    local abbr = os.date("%Z", t)
    if abbr and abbr:match("^%a+$") and abbr ~= "UTC" and abbr ~= "GMT" then
        return abbr .. " · " .. offset
    end
    return offset
end

--- cfg.clock.timezone_label 非空就用使用者設定，否則自動
function M.label(cfg, t)
    local custom = cfg.clock.timezone_label
    if custom and custom ~= "" then return custom end
    return M.autoLabel(t)
end

return M
