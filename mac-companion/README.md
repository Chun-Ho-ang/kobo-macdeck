# MacDeck Companion (Mac 端)

Phase 1–3 走 Wi-Fi 本地 HTTP，只用 Python 標準庫。之後再加 `rumps`（選單列）和 `bless`（BLE）。

```bash
cp config.example.json config.json   # 依需求修改 apps / workflows
python3 -m macdeck_companion --host 127.0.0.1 --port 8765
```

- 開發時預設只綁 `127.0.0.1`；要讓 Kobo 連進來，改用 Mac 的區網 IP（例如 `--host 192.168.1.20`），**不要開公網埠**。
- 預設 `--dry-run`：只記錄不執行。確認白名單後再加 `--live`。
