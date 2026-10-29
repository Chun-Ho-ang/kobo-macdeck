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
| `display.list` | — | 回傳 `{displays: [{id, name, brightness}]}` |
| `display.brightness.set` | `display_id`、`level` 0–100 | 內建：`brightness`；外接：`m1ddc`（DDC/CI） |

螢幕亮度需要另外安裝工具（只有 `--live` 才會用到）：

```bash
brew install brightness m1ddc
```

外接螢幕要支援 DDC/CI 才能調亮度；部分 HDMI 轉接器、Intel Mac 或 DisplayLink 擴充座不支援 `m1ddc`。
