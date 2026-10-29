#!/bin/sh
# Claude Code hook → MacDeck Companion（只收 127.0.0.1）
# 用 async 執行；Companion 沒開或出錯都不影響 Claude Code。token 從檔案讀，不出現在 ps。
AUTH="${MACDECK_AUTH:-$(cd "$(dirname "$0")/.." && pwd)/hook-auth.txt}"
[ -r "$AUTH" ] || exit 0
curl -s -m 2 -o /dev/null -X POST "http://127.0.0.1:${MACDECK_PORT:-8765}/hook" \
    -H "@$AUTH" -H "Content-Type: application/json" \
    -H "X-MacDeck-App: ${__CFBundleIdentifier:-}" -H "X-MacDeck-Term: ${TERM_PROGRAM:-}" \
    --data-binary @- 2>/dev/null
exit 0
