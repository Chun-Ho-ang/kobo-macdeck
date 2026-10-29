# Future Plan

尚未排入 Phase 的功能。等 Phase 2（真實傳輸）穩定後再評估。

## F-01 App / 分頁切換器（Touch Bar 風格）

**目標**：在 Kobo 上看到 Mac 目前開著哪些 App、瀏覽器有哪些分頁，點一下就切過去。

### Kobo 端

- Home 加第三個入口「Apps」。
- **App 清單**：大按鈕網格（例如 2×3），每格顯示 App 名稱，最前景的 App 反白。沿用 Monitor 頁的做法：數量不固定、分頁 `‹ 1 / N ›`、Refresh、用 id 記住選取。
- **點 App** → Mac 把它切到前景。
- **瀏覽器 App 的「Tabs ›」**：進入分頁清單（只列標題，太長截斷），點一下切到那個分頁。
- 第一版只顯示文字。App 圖示要轉成 E-Ink 灰階，之後再評估。

### Mac Companion

| action | args | 說明 |
|---|---|---|
| `apps.list` | — | 一般 App（排除背景程序），回傳 `id`（bundle id）、`name`、`frontmost` |
| `app.activate` | `id` | 只能切換**已經在跑**的 App，不能啟動新的 |
| `tabs.list` | `app_id` | 目前只支援 Safari、Chrome；回傳 `window`、`index`、`title` |
| `tab.activate` | `app_id`, `window`, `index` | 切到指定分頁並把視窗帶到前景 |

- **實作方式**:
  - App 清單:用 `osascript` 問 System Events 裡 `background only is false` 的程序。
  - 分頁:用 Safari / Chrome 各自的 AppleScript 字典。
- **驗證**:`id` 必須符合 bundle id 格式,而且要在最近一次 `apps.list` 的結果裡。`window` 和 `index` 必須是整數。所有參數都以 argv 傳給 osascript,不拼進 script 字串。
- **macOS 權限**:第一次執行會跳 Automation 授權(System Events、Safari、Chrome),要讓使用者手動允許。

### 隱私 / 安全

- 分頁標題可能有敏感內容：不寫進 log，只在記憶體中傳給 Kobo。
- 不提供「開新 App / 開網址」，避免變成任意指令入口。
- 有需要的話，用 `config.json` 設定 `apps.hidden`，把不想出現在 Kobo 上的 App 排除。

### 待決定

- 要不要支援 Finder 視窗、其他瀏覽器（Arc、Firefox 的 AppleScript 支援有限）？
- 清單要手動 Refresh，還是 App 頁開著時定期更新？
- 能不能做到真正的 Touch Bar「依 App 換按鈕」（例如在 Music 前景時自動顯示播放控制）？這需要 Companion 主動推播前景 App 的變化，傳輸層要支援雙向通訊。
