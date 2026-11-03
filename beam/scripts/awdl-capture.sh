#!/bin/bash
# 抓 awdl0 上的流量，用来判断 macOS 到底向用户态暴露了多少 AWDL 信息。
#
# 注意能力边界：
#   awdl0 是 macOS 建的虚拟接口（以太网样式），暴露的是 **AWDL 之上的 IPv6 流量**
#   （例如 AirDrop 的 mDNS 查询）。真正的 AWDL beacon / action frame 是 802.11
#   管理帧，只能通过物理网卡的 monitor 模式看到，而 macOS 不向应用开放该能力。
#
#   所以这个脚本回答的是「macOS 暴露了多少」，不是「Windows 能否被动发现」。
#   后者必须在 Windows + Npcap 上验证，见 docs/windows-awdl-check.md。
#
# 用法（必须 root）：
#   sudo bash scripts/awdl-capture.sh
#   COUNT=50 DUR=30 sudo bash scripts/awdl-capture.sh
set -u

COUNT="${COUNT:-20}"
DUR="${DUR:-30}"
OUT="${OUT:-/tmp/awdl.pcap}"

if [ "$(id -u)" -ne 0 ]; then
    echo "需要 root：sudo bash $0" >&2
    exit 1
fi

echo "=== 抓包前 ==="
netstat -I awdl0 -b 2>/dev/null | sed -n '2p'

echo
echo "抓 $COUNT 个包（最多等 ${DUR}s）→ $OUT"
echo "抓包期间：用 iPhone 打开 AirDrop（对所有人），靠近本机、保持屏幕点亮。"
echo

tcpdump -i awdl0 -c "$COUNT" -w "$OUT" 2>/dev/null &
TPID=$!

( sleep "$DUR"; kill -INT "$TPID" 2>/dev/null ) &
KPID=$!

wait "$TPID" 2>/dev/null
kill "$KPID" 2>/dev/null
wait "$KPID" 2>/dev/null

echo
echo "=== 抓包后 ==="
netstat -I awdl0 -b 2>/dev/null | sed -n '2p'

echo
if [ -s "$OUT" ]; then
    ls -l "$OUT"
    echo
    echo "=== 前 2 个包（判断是 IPv6/mDNS 还是别的）==="
    tcpdump -r "$OUT" -c 2 -nn 2>&1 | head -10
else
    echo "没有抓到任何包。说明在当前状态下 awdl0 不向用户态暴露流量。"
fi

echo
echo "结论提示："
echo "  抓到 IPv6/mDNS → macOS 暴露了 AWDL 之上的 IP 流量，但看不到 802.11 管理帧"
echo "  一个包都没有    → 该接口对用户态基本封闭，跨生态嗅探更不可能靠它"
