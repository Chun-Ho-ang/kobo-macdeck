#!/usr/bin/env bash
# 透過 USB 把插件複製到 Kobo。預設掛載點為 /Volumes/KOBOeReader。
set -euo pipefail
KOBO_MOUNT="${KOBO_MOUNT:-/Volumes/KOBOeReader}"
DEST="$KOBO_MOUNT/.adds/koreader/plugins/macdeck.koplugin"
SRC="$(cd "$(dirname "$0")/.." && pwd)/macdeck.koplugin"

if [ ! -d "$KOBO_MOUNT/.adds/koreader" ]; then
    echo "找不到 KOReader：$KOBO_MOUNT/.adds/koreader（Kobo 有用 USB 接上嗎？）" >&2
    exit 1
fi

rsync -av --delete --exclude '.DS_Store' "$SRC/" "$DEST/"
echo "已部署到 $DEST，請退出磁碟後重啟 KOReader。"
