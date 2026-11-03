#!/bin/bash
# 把 SwiftPM 产物包成可双击的 .app。
# 用法：./build.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
VERSION="${DUOCAST_VERSION:-0.1.0}"
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
    <key>CFBundleShortVersionString</key><string>__VERSION__</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.2</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# heredoc 是 quote 的（不展开变量），版本号在这里补进去。
/usr/bin/sed -i '' "s/__VERSION__/${VERSION}/" "$APP/Contents/Info.plist"

# 本地自签名，避免 Gatekeeper 对未签名二进制的额外拦截。
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "built: $(pwd)/$APP (v$VERSION)"
