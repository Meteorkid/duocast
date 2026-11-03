#!/bin/bash
# 把 SwiftPM 产物包成可双击的 .app。
# 用法：./build.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG" --disable-sandbox

BIN=".build/$CONFIG/DuoCast"
APP="build/DuoCast.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DuoCast"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DuoCast</string>
    <key>CFBundleDisplayName</key><string>DuoCast</string>
    <key>CFBundleIdentifier</key><string>com.duocast.app</string>
    <key>CFBundleExecutable</key><string>DuoCast</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.2</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# 本地自签名，避免 Gatekeeper 对未签名二进制的额外拦截。
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "built: $(pwd)/$APP"
