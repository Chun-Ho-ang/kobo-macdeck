#!/bin/sh
# 建置 MacDeck 選單列 App
#   ./build.sh            → app/build/MacDeck.app
#   ./build.sh --install  → 另外複製到 ~/Applications/MacDeck.app（可以從 Launchpad / Spotlight 開）
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
COMPANION=$(cd "$HERE/.." && pwd)
APP="$HERE/build/MacDeck.app"
MIN_MACOS=14.0

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.macdeck.app</string>
    <key>CFBundleName</key><string>MacDeck</string>
    <key>CFBundleExecutable</key><string>MacDeck</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>MacDeck controls music, volume and keystrokes when you press keys on the Kobo.</string>
    <key>MacDeckCompanionDir</key><string>$COMPANION</string>
</dict>
</plist>
PLIST
# 明確指定最低系統版本（swiftc 預設可能標成比這台 Mac 還新的版本，系統會拒絕啟動）
swiftc -O -parse-as-library -target "$(uname -m)-apple-macos$MIN_MACOS" "$HERE/MacDeck.swift" -o "$APP/Contents/MacOS/MacDeck"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/MacDeck.app"
    cp -R "$APP" "$HOME/Applications/MacDeck.app"
    echo "Installed $HOME/Applications/MacDeck.app"
fi
