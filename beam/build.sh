#!/bin/bash
# 交叉编译出各平台单文件二进制。
# 纯标准库、无 cgo，所以不需要目标平台工具链。
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p dist

build() {
    local goos="$1" goarch="$2" out="$3"
    echo "→ dist/$out"
    GOOS="$goos" GOARCH="$goarch" CGO_ENABLED=0 \
        go build -trimpath -ldflags="-s -w" -o "dist/$out" ./cmd/beam
}

build darwin arm64 beam-macos-arm64
build darwin amd64 beam-macos-amd64
build windows amd64 beam-windows-amd64.exe
build windows arm64 beam-windows-arm64.exe

echo
ls -lh dist

# 构建完顺手打 Windows 包，避免 dist 与 release/ 里的副本不同步。
if [ "${SKIP_PACK:-0}" != "1" ]; then
    echo
    python3 scripts/pack-windows.py
fi
