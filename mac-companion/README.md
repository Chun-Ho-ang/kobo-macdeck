# MacDeck Companion (Mac 端)

Phase 1–3 走 Wi-Fi 本地 HTTP，只用 Python 標準庫。之後再加 `rumps`（選單列）和 `bless`（BLE）。

```bash
cp config.example.json config.json   # media_player: "Music" 或 "Spotify"
python3 -m macdeck_companion --host 127.0.0.1 --port 8765
```

- 開發時預設只綁 `127.0.0.1`；要讓 Kobo 連進來，改用 Mac 的區網 IP（例如 `--host 192.168.1.20`），**不要開公網埠**。
- 預設 `--dry-run`：只記錄不執行。確認白名單後再加 `--live`。

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
