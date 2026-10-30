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

## 選單列 App（建議）

不想每次開終端機的話，用選單列 App 啟動 / 停止 Companion：

```bash
cd mac-companion/app && ./build.sh --install   # 裝到 ~/Applications/MacDeck.app
open ~/Applications/MacDeck.app
```

右上角選單列會出現 MacDeck 圖示（實線 = 執行中，虛線 = 停止）：

- **Start / Stop Companion**：等同 `python3 -m macdeck_companion --lan`
- **Live mode**：打勾等同加 `--live`；執行中切換會自動重啟
- **Copy Kobo settings**：把含 host 與 token 的 `macdeck.lua` 內容複製到剪貼簿
- **Open log**：`~/Library/Logs/MacDeck/companion.log`
- 關掉 App 時 Companion 一起停；下次開 App 會照上次的狀態（開著就自動啟動）
- 由 App 啟動時，「控制 Music / System Events」「輔助使用」這些權限會算在 MacDeck 身上，第一次會再問一次
- 重新 build 之後 macOS 可能會再問一次權限（未簽署開發者憑證的 App 每次 build 都算新版本）
- 不要同時在終端機也跑一份，會搶同一個埠（App 會顯示「port 8765 in use」）

## 白名單動作

| Action | 參數 | Mac 端實作 |
|---|---|---|
| `media.previous` / `media.toggle` / `media.next` | — | AppleScript 控制 `media_player`（Music / Spotify） |
| `media.now` | — | 正在播放 `{player, state, title, artist, album, position, duration}`；唯讀，播放器沒開時不會打開它 |
| `volume.get` | — | 回傳 `{level, muted}` |
| `volume.set` | `level` 0–100 | `set volume output volume` |
| `audio.mute` | — | 切換靜音，回傳 `{level, muted}` |
| `info.get` | — | 時鐘用：`{weather, event, event_error, synced}`（只讀，見下方） |
| `agents.list` | — | 回傳 `{sessions: [...]}` |
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

- 由 `helpers/next_event.swift` 透過 EventKit 讀取，第一次使用時自動編譯成 `helpers/.build/MacDeck Calendar.app`（需要 Xcode Command Line Tools）
- 以獨立的 App 啟動，權限算在「MacDeck Calendar」身上；不管 Companion 從 Terminal、VS Code 或其他地方啟動都能正常詢問（從 VS Code 終端機直接讀行事曆，macOS 會靜默拒絕、不跳視窗）
- 第一次會跳出「MacDeck Calendar 想要取用你的行事曆」，要按允許；之後可在 系統設定 → 隱私權與安全性 → 行事曆 調整
- 在背景讀取：Kobo 不會等編譯或等你按允許，期間顯示「Reading calendar…」，下一次同步就有資料
- 顯示 7 天內最近一個行程；全天行程、已取消、你已婉拒的會議不算
- 標題、時間、地點只傳給 Kobo，不寫 log

## Agents（狀態板）

Kobo 的 Agents 頁顯示 Mac 上各個 agent 在做什麼。每格第二行標出來源：

| 來源 | 資料怎麼來 | Kobo 上看得到 |
|---|---|---|
| **Claude Code**（CLI、Claude 桌面版的 Code 分頁） | Claude Code hooks（下面安裝） | 狀態、任務清單、目前動作、等你核准 |
| **Codex**（ChatGPT App 裡的 Codex） | 讀 `~/.codex/sessions/` 裡 Codex 自己寫的 session 檔，**不改 Codex 設定** | 狀態、目前動作（指令 / 改檔 / 工具）、等你回覆、錯誤原因（例如用量上限）；Codex 沒有任務清單 |
| **ChatGPT / Claude App 一般聊天** | `lsappinfo` 看 App 是否開著；再由 `helpers/.build/MacDeck Windows.app` 透過輔助使用讀視窗（只讀） | 對話名稱、是否正在回答（畫面上有 Stop 鈕）、Open / In front；看不到對話內容和進度 |

- ChatGPT / Claude 要讀到對話名稱和「正在回答」，需要在 系統設定 → 隱私權與安全性 → 輔助使用 打開 **MacDeck Windows**（第一次會自動跳出詢問）。沒開時格子仍在，第三行會提示。這部分靠讀 App 畫面結構，App 改版後可能要調整；工具改版重新編譯後也要再開一次權限
- Codex 只看 12 小時內有動靜的 session；Codex 和 ChatGPT 是同一個 App（`com.openai.codex`），Open / 按鍵都送到 ChatGPT.app
- 不想要某個來源：`config.json` 加 `"sources": {"codex": false}` 或 `{"apps": false}`
- prompt、指令內容只在記憶體、只傳給 Kobo，不寫 log

### Claude Code hooks

資料由 Claude Code 的 hooks 推給 Companion：

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
| Dictate | 第一下：點 App「編輯」選單的「開始聽寫…」；第二下（60 秒內）：Esc 停止 |

- 按鍵送到該 session 所在的 App（終端機或 Claude 桌面版）的**最前面視窗**；同一個 App 開了好幾個 session 時，請確認前景視窗是對的
- 第一次送按鍵時 macOS 會要求「輔助使用」權限（系統設定 → 隱私權與安全性 → 輔助使用），允許執行 Companion 的終端機
- `--live` 才會真的送；dry-run 只回 OK
- **Dictate**：Kobo 沒有麥克風，用 Mac 的聽寫，不用改鍵盤設定
  - 第一下點前景 App「編輯 → 開始聽寫…」（macOS 聽寫中這個選單不會變成「停止」）
  - 第二下送 Esc 停止；只在 MacDeck 60 秒內開的聽寫才送，而且那個 session 正在工作時不送（避免 Esc 中斷 Claude 的回答，Kobo 會提示到 Mac 上停）
  - 想改用自己的聽寫快速鍵：`config.json` 加 `"dictation_key": {"key": "d", "modifiers": ["control", "option"]}`（要先在 系統設定 → 鍵盤 → 聽寫 設同一組）
