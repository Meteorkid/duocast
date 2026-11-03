#!/bin/bash
# 一个链路条件跑完整矩阵：10 MB / 100 MB / 1 GB，各 N 次。
#
# 用法：
#   ./scripts/bench-matrix.sh <标签> --to 192.168.1.8:9001
#   ./scripts/bench-matrix.sh <标签> --peer DESKTOP-4F2K
#   NOTE="5GHz ch44 1m" RUNS=5 ./scripts/bench-matrix.sh wifi5g --peer PC
#
# 前提：接收端已在一台机器上常驻
#   beam recv --listen :9001 --out ~/Downloads --yes
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="${1:?需要链路标签，例如 cable / wifi5g / hotspot}"
shift

TARGET_ARGS=("$@")
if [ ${#TARGET_ARGS[@]} -eq 0 ]; then
    echo "需要目标：--to <ip:port> 或 --peer <设备名>" >&2
    exit 2
fi

BIN="${BEAM_BIN:-./build/beam-macos-arm64}"
if [ ! -x "$BIN" ]; then
    BIN="$(command -v beam || true)"
fi
if [ -z "${BIN:-}" ] || [ ! -x "$BIN" ]; then
    echo "找不到 beam 可执行文件，先跑 ./build.sh，或用 BEAM_BIN=... 指定" >&2
    exit 2
fi

RUNS="${RUNS:-5}"
NOTE="${NOTE:-}"
SIZES="${SIZES:-10 100 1000}"
CSV="${CSV:-bench-results/${LABEL}.csv}"

mkdir -p "$(dirname "$CSV")"

echo "链路标签: $LABEL"
echo "目标:     ${TARGET_ARGS[*]}"
echo "规模:     ${SIZES} MB × ${RUNS} 次"
echo "输出:     $CSV"
[ -n "$NOTE" ] && echo "备注:     $NOTE"
echo

for size in $SIZES; do
    echo "── ${size} MB ──"
    "$BIN" bench "${TARGET_ARGS[@]}" \
        --size "$size" --runs "$RUNS" \
        --label "$LABEL" --note "$NOTE" \
        --csv "$CSV"
    echo
done

echo "完成。用 python3 scripts/bench-summary.py 汇总。"
