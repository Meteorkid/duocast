#!/bin/bash
# E0 / G1a：Mac 侧加入 Legacy AP → 验证无上游 → 测 TCP → 传一个文件。
#
# 为什么做成脚本：加入测试 AP 后 Mac 会失去互联网，远程协助会中断。
# 跑完脚本、切回正常网络，再把日志发回来即可。
#
# 用法（先让 Windows 起好 AP）：
#   bash scripts/e0-mac.sh "beam-e0" "beamtest2026"
#
# 产物：/tmp/e0-mac-<时间戳>.log（同时实时打印）
set -u

SSID="${1:-beam-e0}"
PASS="${2:-beamtest2026}"
# 第三个参数已废弃（曾用于自动切回），现在接收但忽略，避免旧命令静默改变行为
_IGNORED="${3:-}"
IFACE="en0"
BEAM="/Users/meteor/github/duocast/beam/release/macos/beam"
LOG="/tmp/e0-mac-$(date +%Y%m%dT%H%M%S).log"
PAYLOAD_MB="${PAYLOAD_MB:-1}"

# 所有输出同时进日志
exec > >(tee -a "$LOG") 2>&1

# 退出时**不主动切换任何网络**。
#
# 早期版本会在退出时自动连回「原网络」，并在探测失败时按 keychain 猜一个。
# 那等于替使用者改网络：猜错就是把人连到他没要求的网络上。
# 现在只报告状态，切不切由使用者决定。
report_network_state() {
    local addr
    addr=$(ipconfig getifaddr "$IFACE" 2>/dev/null || true)

    echo
    echo "--- 退出时的网络状态 ---"
    if [ -n "$addr" ]; then
        echo "${IFACE} 地址: ${addr}"
    else
        echo "${IFACE} 无地址（可能仍停留在测试 AP 上）"
    fi

    if [ "${KEEP_AP_CONNECTION:-0}" != "1" ]; then
        echo "如需切回自己的网络，请手动在 Wi-Fi 菜单选择；本脚本不会替你切换。"
    fi
}

trap report_network_state EXIT

echo "=== E0 Mac 侧 ==="
echo "时间: $(date -Iseconds)"
echo "日志: $LOG"
echo

echo "--- 1. 切换前状态（用于证明过程中没有别的活动连接）---"
PREV_ADDR=$(ipconfig getifaddr "$IFACE" 2>/dev/null || true)
echo "切换前 ${IFACE} 地址: ${PREV_ADDR:-无}"
ifconfig | grep "inet " | grep -v 127.0.0.1
echo "默认路由:"
netstat -rn -f inet | grep "^default" || echo "  （无默认路由）"
echo

echo "--- 2. 加入测试 AP：${SSID} ---"
JOIN_OUT=$(networksetup -setairportnetwork "$IFACE" "$SSID" "$PASS" 2>&1)
join_rc=$?
echo "networksetup 输出: ${JOIN_OUT:-（空）}"
echo "networksetup 退出码: ${join_rc}（注意：找不到网络时它也可能返回 0）"

case "$JOIN_OUT" in
    *"Could not find"*)
        echo "❌ 系统扫描里没有 ${SSID}：AP 没有广播到这台 Mac，或信道/频段不兼容"
        echo "   排查：Windows 侧 AP 状态是否 Started（不是 Aborted）；"
        echo "         Mac 的 Wi-Fi 是否开着；两者距离/信道是否可用"
        exit 3
        ;;
esac

echo "--- 3. 等待地址分配（最多 20 秒）---"
ADDR=""
for i in $(seq 1 20); do
    sleep 1
    ADDR=$(ipconfig getifaddr "$IFACE" 2>/dev/null || true)
    if [ -n "$ADDR" ]; then
        echo "第 ${i}s 拿到地址: ${ADDR}"
        break
    fi
done

if [ -z "$ADDR" ]; then
    echo "❌ 20 秒内没有拿到地址：关联可能失败"
    echo "   请检查：Windows 侧 AP 状态是否为 Started；Mac Wi-Fi 是否开启"
    exit 1
fi

# 新 AP 与旧热点可能同属一个 /24（都是 192.168.137.x）。若地址没变，
# 说明拿到的是旧租约，路由会指向旧网关，后面所有连通性结论都不可信。
if [ -n "${PREV_ADDR:-}" ] && [ "$ADDR" = "$PREV_ADDR" ]; then
    echo "⚠️ 地址与切换前相同（${ADDR}）：很可能仍是旧租约，不是新 AP 分配的"
    echo "   建议先忽略该网络再重连："
    echo "   networksetup -removepreferredwirelessnetwork $IFACE \"$SSID\" ; 重新执行本脚本"
    echo "   继续执行会导致后续连通性结论不可信，已中止。"
    exit 2
fi

echo
echo "--- 4. 关联后的网络状态 ---"
ifconfig "$IFACE" | grep -E "inet |status"
echo "默认路由:"
netstat -rn -f inet | grep "^default" || echo "  （无默认路由）"
echo "说明：Wi-Fi Direct 的 GO 通常会给客户端下发默认路由，指向它自己。"
echo "      有默认路由 ≠ 有互联网；要证明「无上游」得看宿主是否有上行连接。"
echo

# 网关必须取自实际配置，不能按 "x.y.z.1" 推算——
# 实测这台 Windows 的 Legacy AP 地址是 192.168.137.5，推算出的 .1 并不存在。
GW="${GW_OVERRIDE:-}"

if [ -z "$GW" ]; then
    # 优先用 DHCP 下发的 router 选项
    GW=$(ipconfig getpacket "$IFACE" 2>/dev/null | awk -F': ' '/router \(ip_mult\)/ {print $2}' | tr -d '{}' | awk '{print $1}')
fi

if [ -z "$GW" ]; then
    # 退回默认路由的网关
    GW=$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2}')
fi

if [ -z "$GW" ]; then
    echo "❌ 无法确定网关地址。请用 Windows 侧实际地址重跑："
    echo "   GW_OVERRIDE=192.168.137.5 bash scripts/e0-mac.sh \"$SSID\" \"$PASS\""
    exit 1
fi

echo "网关（来自 DHCP/路由表）: ${GW}"
echo

echo "--- 5. TCP 可达性（不用 ping 代替）---"
if nc -z -G 3 "$GW" 9001; then
    echo "✅ TCP $GW:9001 可达"
else
    echo "❌ TCP $GW:9001 不可达"
    echo "   检查：Windows 接收端是否已启动；防火墙规则是否仍匹配当前 beam.exe 路径"
    exit 1
fi
echo

echo "--- 6. 发送一个文件并核对 ---"
head -c $((PAYLOAD_MB * 1024 * 1024)) /dev/urandom > /tmp/e0.bin
echo "源文件 SHA-256:"
shasum -a 256 /tmp/e0.bin
echo

"$BEAM" send /tmp/e0.bin --to "$GW:9001"
send_rc=$?
echo "beam send 退出码: $send_rc"
echo

if [ $send_rc -eq 0 ]; then
    echo "✅ 正向传输完成（接收端已回 Result，说明校验通过）"
else
    echo "❌ 正向传输失败，见上方错误"
fi

echo
echo "--- 7. 反向准备：Mac 起接收端 120 秒 ---"
echo "下一步在 Windows 上执行："
echo "  C:\\beam\\beam.exe send C:\\beam\\beam.exe --to ${ADDR}:9001"
echo "（Mac 地址：$ADDR）"
echo

mkdir -p /tmp/e0-recv
"$BEAM" recv --listen :9001 --out /tmp/e0-recv --yes --once &
RECV_PID=$!

for i in $(seq 1 24); do
    if ! kill -0 $RECV_PID 2>/dev/null; then
        break
    fi
    sleep 5
done

kill $RECV_PID 2>/dev/null
wait $RECV_PID 2>/dev/null

echo
echo "--- 8. 反向结果 ---"
ls -l /tmp/e0-recv 2>/dev/null || echo "（接收目录为空）"

echo
echo "=== E0 结束 ==="
echo "请把本日志内容发回：${LOG}"
echo "如需切回自己的网络，请在 Wi-Fi 菜单手动选择（脚本不会代劳）。"
