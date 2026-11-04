#!/bin/bash
# 重新生成 AppIcon.icns。
#
# 图标是代码画出来的，不是图片文件：改设计只要动 make-icon.swift 里的坐标与配色，
# 然后跑这个脚本，1024 到 16 的十档尺寸会一次生成，省掉手改十个 PNG 的麻烦。
#
# 用法：./scripts/make-icon.sh
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/AppIcon.iconset"
swift scripts/make-icon.swift "$WORK/icon-1024.png"

sips -Z 16   "$WORK/icon-1024.png" --out "$WORK/AppIcon.iconset/icon_16x16.png"      >/dev/null
sips -Z 32   "$WORK/icon-1024.png" --out "$WORK/AppIcon.iconset/icon_16x16@2x.png"   >/dev/null
sips -Z 32   "$WORK/icon-1024.png" --out "$WORK/AppIcon.iconset/icon_32x32.png"      >/dev/null
sips -Z 64   "$WORK/icon-1024.png" --out "$WORK/AppIcon.iconset/icon_32x32@2x.png"   >/dev/null
sips -Z 128  "$WORK/icon-1024.png" --out "$WORK/AppIcon.iconset/icon_128x128.png"    >/dev/null
sips -Z 256  "$WORK/icon-1024.png" --out "$WORK/AppIcon.iconset/icon_128x128@2x.png" >/dev/null
sips -Z 256  "$WORK/icon-1024.png" --out "$WORK/AppIcon.iconset/icon_256x256.png"    >/dev/null
sips -Z 512  "$WORK/icon-1024.png" --out "$WORK/AppIcon.iconset/icon_256x256@2x.png" >/dev/null
sips -Z 512  "$WORK/icon-1024.png" --out "$WORK/AppIcon.iconset/icon_512x512.png"    >/dev/null
cp "$WORK/icon-1024.png" "$WORK/AppIcon.iconset/icon_512x512@2x.png"

iconutil -c icns "$WORK/AppIcon.iconset" -o AppIcon.icns
echo "wrote $(pwd)/AppIcon.icns"
