-- Wi-Fi 傳輸：POST JSON 到 mac-companion 的 /command
-- 和 mock 同介面：connect(on_done(ok, err))、send(action, args, on_ack(ack))、disconnect()
-- HTTP 是同步的（會擋住 UI 最多 request_timeout_sec），所以一律排到 nextTick，讓按鈕回饋先畫出來
local Interface = require("transport/interface")

local M = {}

local Wifi = {}
Wifi.__index = Wifi

--- 預設 HTTP：KOReader 內建的 LuaSocket；回傳 status_code, body 或 nil, err
function M.httpPost(url, headers, body, timeout_sec)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local chunks = {}
    socketutil:set_timeout(timeout_sec, timeout_sec + 2)
    local code = socket.skip(1, http.request{
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(body),
        sink = socketutil.table_sink(chunks),
    })
    socketutil:reset_timeout()
    if type(code) ~= "number" then
        return nil, socketutil.describe_error(code, timeout_sec, timeout_sec + 2) or tostring(code)
    end
    return code, table.concat(chunks)
end

--- opts: ui_manager, host, port, token, timeout_sec
---       可注入（測試用）：http_post, json, network（需有 isConnected()）
function M.new(opts)
    return setmetatable({
        ui = opts.ui_manager,
        host = opts.host or "",
        port = opts.port or 8765,
        token = opts.token or "",
        timeout_sec = opts.timeout_sec or 3,
        http_post = opts.http_post or M.httpPost,
        json = opts.json or M.json, -- nil = KOReader 的 require("json")
        network = opts.network,
        connected = false,
        gen = 0, -- disconnect 後，還在排隊的舊請求一律丟棄
    }, Wifi)
end

function Wifi:_json()
    if not self.json then self.json = require("json") end
    return self.json
end

function Wifi:_network()
    if self.network == nil then
        local ok, NetworkMgr = pcall(require, "ui/network/manager")
        self.network = ok and NetworkMgr or false
    end
    return self.network
end

-- KOReader 的 JSON.decode 把 null 解成 function；轉回 nil，避免畫面拿到怪值
local function stripNulls(v)
    if type(v) == "function" then return nil end
    if type(v) ~= "table" then return v end
    for k, x in pairs(v) do v[k] = stripNulls(x) end
    return v
end

local function errorAck(id, detail, offline)
    return { protocol = Interface.PROTOCOL, id = id, type = "ack", status = "error", detail = detail, offline = offline }
end

--- 同步送出一個 envelope；回傳 ack 表。offline = true 代表連不到 Mac（不是 Mac 拒絕指令）
function Wifi:_post(msg)
    local json = self:_json()
    local url = string.format("http://%s:%d/command", self.host, self.port)
    local payload = json.encode(msg)
    -- 一定要帶 Content-Length：沒帶的話 LuaSocket 會改用 chunked 傳送，companion 讀不到內容（HTTP 400）
    local ok, code, body = pcall(self.http_post, url, {
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#payload),
        ["Authorization"] = "Bearer " .. self.token,
    }, payload, self.timeout_sec)
    if not ok then return errorAck(msg.id, "request failed: " .. tostring(code), true) end
    if code == nil then return errorAck(msg.id, tostring(body), true) end
    if code == 401 then return errorAck(msg.id, "Mac rejected the token (check settings)", true) end
    if code ~= 200 then return errorAck(msg.id, "HTTP " .. tostring(code), true) end
    local decoded, ack = pcall(json.decode, body)
    if not decoded or type(ack) ~= "table" or ack.id ~= msg.id then
        return errorAck(msg.id, "bad reply from Mac", true)
    end
    return stripNulls(ack)
end

function Wifi:connect(on_done)
    self.gen = self.gen + 1
    local gen = self.gen
    self.ui:nextTick(function()
        if gen ~= self.gen then return end
        if self.host == "" or self.token == "" then
            return on_done(false, "Set Mac host and token in macdeck.lua")
        end
        local net = self:_network()
        if net and not net:isConnected() then
            return on_done(false, "Wi-Fi is off")
        end
        local msg = Interface.envelope(nil, nil)
        msg.type, msg.action, msg.args = "ping", nil, nil
        local ack = self:_post(msg)
        if gen ~= self.gen then return end
        if ack.status == "ok" then
            self.connected = true
            on_done(true)
        else
            on_done(false, ack.detail)
        end
    end)
end

function Wifi:send(action, args, on_ack)
    local msg = Interface.envelope(action, args)
    local gen = self.gen
    self.ui:nextTick(function()
        if gen ~= self.gen then return end
        if not self.connected then
            return on_ack(errorAck(msg.id, "not connected", true))
        end
        local ack = self:_post(msg)
        if gen ~= self.gen then return end
        if ack.offline then self.connected = false end
        on_ack(ack)
    end)
end

function Wifi:disconnect()
    self.gen = self.gen + 1
    self.connected = false
end

return M
