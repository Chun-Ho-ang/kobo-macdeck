# Kobo MacDeck

把 Kobo Clara BW 變成 E-Ink 桌面時鐘 + Mac 觸控遙控器。

## 專案結構

```
kobo-macdeck/
├── macdeck.koplugin/     # Kobo 端 KOReader 插件 (Lua)
├── mac-companion/        # Mac 端接收程式 (Python, Wi-Fi 路線優先)
├── docs/                 # 規格、Phase 0 調查報告、測試紀錄
├── scripts/              # 部署 / 開發輔助腳本
└── tests/                # 在電腦上跑的 Lua 測試（假 KOReader 環境）
```

## 開發順序

1. **Phase 0** — 填寫 `docs/phase0-device-capability-report.md`（唯讀調查）
2. **Phase 1** — UI MVP：Clock / Controller / Exit，先用假指令（`transport/interface.lua` 的 mock）
3. **Phase 2** — 傳輸 Gate：先接 Wi-Fi（`transport/wifi.lua` ↔ `mac-companion`），BLE 待驗證
4. **Phase 3+** — 白名單動作、配對、天氣 / 行事曆
5. **Future** — 見 `docs/future-plan.md`（F-01：Touch Bar 風格的 App / 分頁切換器）

## Phase 1 現況（UI MVP，mock transport）

- KOReader 主選單 → 工具 → **MacDeck** 啟動
- 啟動後轉橫向、顯示 Clock；每分鐘對齊整分刷新時間區塊，每 30 分鐘全刷一次
- 點 Clock 任一處 → Connecting（mock 0.5 秒）→ Controller 首頁：**Media control** / **Monitor control**
  - Media：上一首 / 播放暫停 / 下一首；音量條（點哪格設到哪，10 格 = 10%）+ 小聲 / 大聲 / 靜音
  - Monitor：左邊選螢幕，右邊亮度條 + 亮 / 暗。螢幕數量由 Mac 回報、不固定：超過 4 台自動分頁（‹ / ›），插拔螢幕後按 Refresh 重新讀取，原本選的那台會保留（以 id 辨識）
  - 點按鈕會反白並在底部顯示 ACK；子頁底列有 ← Back / ← Clock / Exit
- Controller 60 秒沒觸控 → 回 Clock；Clock / Controller / Connecting / Offline 都有 Exit
- Exit、畫面被系統關閉、或內部出錯時，都會清掉計時器並還原螢幕方向
- 系統休眠喚醒後回到 Clock 並重新對齊時間

### 自動休眠

插件不改 KOReader 的自動休眠設定。要讓時鐘長時間顯示，請直接在 KOReader 的自動休眠（Autosuspend）設定裡調長時間或關閉。這是全域設定，平常閱讀時也會套用；用完記得調回來。

### 設定（可選）

在 Kobo 上建立 `.adds/koreader/settings/macdeck.lua`，只寫想覆蓋的欄位（完整預設值見 `core/settings.lua`）：

```lua
return {
    config = {
        idle = { controller_timeout_sec = 30 },
        clock = { location_label = "Ann Arbor" }, -- Clock 顯示「Ann Arbor · EDT · UTC−04:00」
        -- clock = { timezone_label = "Detroit time" }, -- 自動時區不對時才需要手動填
        transport = { mock_fail_connect = true }, -- 測 Offline 畫面
        -- transport = { mock_display_count = 6 }, -- 測多螢幕分頁
    },
}
```

### 實機待驗證（Phase 1 驗收）

- [ ] T-01 開關插件 30 次
- [ ] T-02 Clock 連續 15 分鐘，分鐘跳動正確
- [ ] T-03 點觸進 Controller（不用電源鍵）
- [ ] T-04 Controller 60 秒逾時回 Clock
- [ ] T-09 每個畫面 Exit 都能回 KOReader 且方向還原
- [ ] 橫向版面、字級、觸控區大小、殘影情況

## 測試

```bash
pip install lupa
python3 tests/run_lua_tests.py          # Kobo 插件
python3 -m unittest discover -s tests   # Mac Companion
```

測試用 `tests/koreader_stubs.lua` 模擬 UIManager、計時器與螢幕旋轉，只驗證狀態流程與清理，**不驗證畫面排版**，排版要在實機上看。

## 快速開始

Mac Companion（只用 Python 標準庫）：

```bash
cd mac-companion
python3 -m macdeck_companion --host 127.0.0.1 --port 8765
curl -s -X POST localhost:8765/command -d '{"protocol":"macdeck/1","id":"cmd-1","type":"ping"}'
```

部署插件到 Kobo（USB 掛載後）：

```bash
./scripts/deploy_plugin.sh
```

## 注意

- 插件內模組請在檔案頂層 `require`：KOReader 只在載入 `main.lua` 時把插件資料夾放在 `package.path` 最前面，之後改放到最後。
- 子資料夾名稱要避免和 KOReader 內建模組撞名（例如不要建立 `ui/widget/`、`ui/font.lua`）。
- 安全不變條件：任何頁面都要能 Exit，不攔截實體電源鍵，Mac 端只執行白名單動作。
