# Phase 0 — Device Capability Report

> 只執行唯讀命令。先備份再調查。

## 1. 版本與環境

| 項目 | 值 |
|---|---|
| Kobo 韌體版本 | |
| KOReader 版本 | |
| NickelMenu 版本 | |
| KOReader 安裝路徑 | `/mnt/onboard/.adds/koreader` |
| 啟動方式 | |
| 存取方式 (SSH / Telnet) | |

## 1b. 時間與時區

MacDeck 的時間直接用 `os.date`（裝置本機時間），時區標籤由 `core/timezone.lua` 計算。Kobo 可能沒有設定系統時區（Nickel 直接把本機時間寫進系統時鐘），這時標籤會顯示 `UTC+00:00`，但時間本身仍是對的。

| 檢查 | 指令 | 結果 |
|---|---|---|
| 系統時間與時區 | `date; date -u` | |
| TZ 環境變數 | `echo $TZ` | |
| 時區檔 | `ls -l /etc/localtime; cat /etc/TZ` | |
| MacDeck 顯示的時區標籤 | （看 Clock 畫面） | |

若標籤不對，在設定檔填 `clock.timezone_label`（例如 `"Detroit time"`，不要寫死 `EDT`，否則換季會錯）。

## 2. 備份清單

- [ ] `.adds/koreader/settings.reader.lua`
- [ ] `.adds/koreader/settings/`
- [ ] `.adds/nm/` (NickelMenu 設定)

## 3. 藍牙調查

| 檢查 | 指令 | 結果 |
|---|---|---|
| 藍牙相關程序 | `ps \| grep -i bt` | |
| D-Bus 服務 | `dbus-send --system --print-reply --dest=org.freedesktop.DBus / org.freedesktop.DBus.ListNames` | |
| 核心模組 | `lsmod` | |
| 可用工具 | `ls /usr/bin /usr/sbin \| grep -i -E 'bt\|blue\|hci'` | |

## 4. 結論

| 角色 | 可行性 | 證據 |
|---|---|---|
| BLE GATT Client | 待驗證 | |
| BLE Peripheral | 待驗證 | |
| HID Device | 待驗證 | |

**Transport 決策：**
