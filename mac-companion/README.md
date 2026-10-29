# MacDeck Companion (Mac 端)

Phase 1–3 走 Wi-Fi 本地 HTTP，只用 Python 標準庫。之後再加 `rumps`（選單列）和 `bless`（BLE）。

```bash
cp config.example.json config.json   # media_player: "Music" 或 "Spotify"
python3 -m macdeck_companion --lan   # 讓 Kobo 從 Wi-Fi 連進來
```

- `--lan` 自動抓這台 Mac 的區網 IP，啟動時會印出 Kobo 要填的 `host` / `port`。只接受區網或 `127.0.0.1`，拒絕 `0.0.0.0` 和公網 IP。
- **配對 token**：第一次啟動會產生 `token.txt`（權限 600），內容填到 Kobo 設定的 `token`。每個請求都要帶 `Authorization: Bearer <token>`，不對就回 401。不會寫進 log。換 token：刪掉 `token.txt` 再啟動。
- 預設 dry-run：回假資料、不動 Mac。確認沒問題後再加 `--live`。
- 第一次連線時 macOS 可能問「是否允許 Python 接受傳入連線」，要按允許。

自己測（不經過 Kobo）：

```bash
curl -s -X POST http://127.0.0.1:8765/command -H "Authorization: Bearer $(cat token.txt)" -d '{"protocol":"macdeck/1","id":"t1","type":"ping"}'
```
（用 `--lan` 啟動時，把 `127.0.0.1` 換成印出來的 IP。）

## 白名單動作

| Action | 參數 | Mac 端實作 |
|---|---|---|
| `media.previous` / `media.toggle` / `media.next` | — | AppleScript 控制 `media_player`（Music / Spotify） |
| `volume.get` | — | 回傳 `{level, muted}` |
| `volume.set` | `level` 0–100 | `set volume output volume` |
| `audio.mute` | — | 切換靜音，回傳 `{level, muted}` |
| `info.get` | — | 時鐘用：`{weather, event, event_error, synced}`（只讀，見下方） |
| `agents.list` | — | 回傳 `{sessions: [...]}`，資料來自 Claude Code hooks |
| `agent.key` | `session_id`、`key`：`approve` / `stop` / `send` / `auto` / `dictate` | 先把該 session 的 App 叫到前景，再送固定按鍵 |
| `agent.open` | `session_id` | 把該 session 的 App 叫到前景 |

## 時鐘的天氣與行程

Kobo 的時鐘畫面每 15 分鐘向 Companion 拿一次 `info.get`。兩者都是唯讀，dry-run 也會拿真的資料。

**天氣**（[Open-Meteo](https://open-meteo.com)，不用 API key，快取 15 分鐘）。先設定位置：

```bash
python3 -m macdeck_companion.set_location "Ann Arbor"
python3 -m macdeck_companion.set_location "Taipei" --unit celsius   # 或 --unit fahrenheit
```

會寫進 `config.json` 的 `weather`（名稱、經緯度、單位），然後重啟 Companion。查天氣時只送經緯度給 Open-Meteo。

**下一個行程**（macOS 行事曆，含 iCloud / Google 等已加進「行事曆」App 的帳號，快取 2 分鐘）：

- 由 `helpers/next_event.swift` 透過 EventKit 讀取，第一次使用時自動用 `swiftc` 編譯到 `helpers/.build/`（需要 Xcode Command Line Tools）
- 第一次會跳出「終端機想要取用你的行事曆」，要按允許；之後可在 系統設定 → 隱私權與安全性 → 行事曆 調整
- 顯示 7 天內最近一個行程；全天行程、已取消、你已婉拒的會議不算
- 標題、時間、地點只傳給 Kobo，不寫 log

## Agents（Claude Code 狀態板）

Kobo 的 Agents 頁顯示 Mac 上每個 Claude Code session 在做什麼。資料由 Claude Code 的 hooks 推給 Companion：

1. 先啟動 Companion 一次（會產生 `token.txt` 和 `hook-auth.txt`）
2. 安裝 hooks（先看會改什麼，再寫入；會備份成 `settings.json.bak`）：

   ```bash
   python3 -m macdeck_companion.install_hooks
   python3 -m macdeck_companion.install_hooks --apply
   ```

   移除：`python3 -m macdeck_companion.install_hooks --remove`
3. 重新開 Claude Code session（已開著的不會讀到新 hooks）

細節：

- hooks 以 `async` 執行，Companion 沒開時 Claude Code 完全不受影響
- `/hook` 只在 `127.0.0.1` 上接受，區網（Kobo）那個 listener 不收；一樣要 token（從 `hook-auth.txt` 讀，不會出現在 `ps`）
- 顯示：專案名稱、狀態（Working / Needs you / Done / Error）、目前動作（例如「Edit wifi.lua」）、任務清單（`TaskCreate` / `TodoWrite`）、你下的指令（截短）
- prompt 和指令內容只在記憶體裡、只傳給 Kobo，不寫 log；12 小時沒動靜的 session 自動移除

### 按鍵

| Kobo 按鍵 | Mac 上送出 |
|---|---|
| Approve / Send | Return |
| Stop | Escape |
| Auto | Shift+Tab（切換權限模式） |
| Open | 只把 App 叫到前景 |
| Dictate | `config.json` 的 `dictation_key` |

- 按鍵送到該 session 所在的 App（終端機或 Claude 桌面版）的**最前面視窗**；同一個 App 開了好幾個 session 時，請確認前景視窗是對的
- 第一次送按鍵時 macOS 會要求「輔助使用」權限（系統設定 → 隱私權與安全性 → 輔助使用），允許執行 Companion 的終端機
- `--live` 才會真的送；dry-run 只回 OK
- **Dictate**：Kobo 沒有麥克風，用 Mac 的聽寫。到 系統設定 → 鍵盤 → 聽寫 → 快速鍵 → 自訂，設一組按鍵（例如 ⌃⌥D），再寫進 `config.json`：

  ```json
  { "dictation_key": { "key": "d", "modifiers": ["control", "option"] } }
  ```
