// Package discover 在同一广播域内自动发现其他 beam 实例。
//
// 两条通道并行：
//   - UDP 广播查询/应答（端口 9100）—— 最简单，但部分 WiFi 会过滤广播；
//   - mDNS/Bonjour（_beam._tcp）—— 过滤策略不同，也是 AirDrop/LocalSend 的标准做法。
//
// 一台设备往往有多个地址（以太网、Wi-Fi、VPN 隧道、回环），其中只有一部分
// 对端真的连得上。所以这里不在发现阶段「猜」一个地址，而是把候选地址全部收下来，
// 交给拨号方依次尝试。
package discover

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	// Magic 是广播查询串。
	Magic = "BEAM_DISCOVER"

	// Port 是发现用的 UDP 端口。
	Port = 9100

	protoVersion = 1
)

// 发现来源，用于显示「靠哪条通道找到的」。
const (
	SourceBroadcast = "broadcast"
	SourceMDNS      = "mdns"
	SourceBoth      = "both"
)

type reply struct {
	Beam int    `json:"beam"`
	Name string `json:"name"`
	TCP  int    `json:"tcp"`
}

// Peer 是一个被发现的设备。
type Peer struct {
	Name string

	// Addrs 是按优先级排好的候选地址，逐个尝试直到连上。
	Addrs []string

	// Source 记录发现通道，便于排障。
	Source string
}

// Addr 返回首选地址，仅用于显示。
func (p Peer) Addr() string {
	if len(p.Addrs) == 0 {
		return ""
	}

	return p.Addrs[0]
}

// Dial 依次尝试候选地址，返回第一个连上的连接与实际使用的地址。
//
// 为什么要逐个试：一台机器上同时有 en0（局域网）、utun（VPN）、lo0，
// 发现阶段无法可靠判断哪条对端可达。按优先级试一遍比「猜一个」稳得多。
func (p Peer) Dial(timeout time.Duration) (net.Conn, string, error) {
	if len(p.Addrs) == 0 {
		return nil, "", fmt.Errorf("设备 %s 没有可用地址", p.Name)
	}

	var lastErr error

	// 总预算：候选地址可能有十几个（多网卡 + 双通道），逐个等满 timeout 会太久。
	deadline := time.Now().Add(12 * time.Second)

	for _, addr := range p.Addrs {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			break
		}

		attempt := timeout
		if remaining < attempt {
			attempt = remaining
		}

		conn, err := net.DialTimeout("tcp", addr, attempt)
		if err == nil {
			return conn, addr, nil
		}

		lastErr = err
	}

	return nil, "", fmt.Errorf("所有候选地址都连不上（%s）: %w", strings.Join(p.Addrs, ", "), lastErr)
}

// LocalName 返回本机名。
func LocalName() string {
	name, err := os.Hostname()
	if err != nil || strings.TrimSpace(name) == "" {
		return "beam-device"
	}

	if dot := strings.IndexByte(name, '.'); dot > 0 {
		name = name[:dot]
	}

	return name
}

// Serve 启动 UDP 应答器：收到查询就单播回复自己的设备名与 TCP 端口。
func Serve(name string, tcpPort int, logf func(string, ...any)) (io.Closer, error) {
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{Port: Port})
	if err != nil {
		return nil, fmt.Errorf("监听发现端口 %d 失败: %w", Port, err)
	}

	if logf != nil {
		logf("已开启广播发现：%s（UDP %d）", name, Port)
	}

	go func() {
		buffer := make([]byte, 256)

		for {
			n, from, err := conn.ReadFromUDP(buffer)
			if err != nil {
				return
			}

			if !strings.HasPrefix(string(buffer[:n]), Magic) {
				continue
			}

			payload, err := json.Marshal(reply{Beam: protoVersion, Name: name, TCP: tcpPort})
			if err != nil {
				continue
			}

			conn.WriteToUDP(payload, from)
		}
	}()

	return conn, nil
}

// Discover 广播查询并收集应答。同一设备可能从多个网卡各回一次，地址全部保留。
func Discover(timeout time.Duration) ([]Peer, error) {
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
	if err != nil {
		return nil, fmt.Errorf("创建发现套接字失败: %w", err)
	}
	defer conn.Close()

	for _, target := range broadcastTargets() {
		conn.WriteToUDP([]byte(Magic), target)
	}

	_ = conn.SetReadDeadline(time.Now().Add(timeout))

	collected := make(map[string]map[string]bool)
	buffer := make([]byte, 512)

	for {
		n, from, err := conn.ReadFromUDP(buffer)
		if err != nil {
			break // 超时
		}

		var answer reply
		if json.Unmarshal(buffer[:n], &answer) != nil || answer.TCP <= 0 {
			continue
		}

		addr := net.JoinHostPort(from.IP.String(), strconv.Itoa(answer.TCP))
		if collected[answer.Name] == nil {
			collected[answer.Name] = make(map[string]bool)
		}

		collected[answer.Name][addr] = true
	}

	return buildPeers(collected, SourceBroadcast), nil
}

// DiscoverAll 同时跑两条通道，合并结果。总耗时仍然是一个 timeout。
func DiscoverAll(timeout time.Duration) []Peer {
	broadcastCh := make(chan []Peer, 1)
	mdnsCh := make(chan []Peer, 1)

	go func() {
		peers, _ := Discover(timeout)
		broadcastCh <- peers
	}()

	go func() {
		peers, _ := BrowseMDNS(timeout)
		mdnsCh <- peers
	}()

	broadcast := <-broadcastCh
	mdns := <-mdnsCh

	merged := make(map[string]*Peer)

	addAll := func(peers []Peer) {
		for _, peer := range peers {
			existing, ok := merged[peer.Name]
			if !ok {
				copyPeer := peer
				merged[peer.Name] = &copyPeer
				continue
			}

			existing.Source = SourceBoth
			existing.Addrs = unionAddrs(existing.Addrs, peer.Addrs)
		}
	}

	addAll(broadcast)
	addAll(mdns)

	result := make([]Peer, 0, len(merged))
	for _, peer := range merged {
		peer.Addrs = sortAddrs(usableAddrs(peer.Addrs))
		result = append(result, *peer)
	}

	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })

	return result
}

// Match 按设备名查找，支持前缀匹配（大小写不敏感）。
func Match(peers []Peer, name string) (Peer, bool) {
	name = strings.ToLower(strings.TrimSpace(name))

	for _, peer := range peers {
		if strings.ToLower(peer.Name) == name {
			return peer, true
		}
	}

	for _, peer := range peers {
		if strings.HasPrefix(strings.ToLower(peer.Name), name) {
			return peer, true
		}
	}

	return Peer{}, false
}

// usableAddrs 只保留 IPv4；没有 IPv4 时才回退到 IPv6。
//
// 实测教训：mDNS 会带回大量 fe80::（链路本地，拨号缺 scope id 必然失败）
// 与隧道地址（fd7a::、fd00::），一次协商出现 13 条候选、12 条不可能通，
// 白白浪费 4 秒。候选不是越多越好，不可用的候选是负资产。
func usableAddrs(addrs []string) []string {
	var v4, v6 []string

	for _, addr := range addrs {
		host, _, err := net.SplitHostPort(addr)
		if err != nil {
			continue
		}

		ip := net.ParseIP(host)
		if ip == nil {
			continue
		}

		if ip.To4() != nil {
			v4 = append(v4, addr)
		} else {
			v6 = append(v6, addr)
		}
	}

	if len(v4) > 0 {
		return v4
	}

	return v6
}

func buildPeers(collected map[string]map[string]bool, source string) []Peer {
	peers := make([]Peer, 0, len(collected))

	for name, set := range collected {
		addrs := make([]string, 0, len(set))
		for addr := range set {
			addrs = append(addrs, addr)
		}

		peers = append(peers, Peer{Name: name, Addrs: sortAddrs(addrs), Source: source})
	}

	sort.Slice(peers, func(i, j int) bool { return peers[i].Name < peers[j].Name })
	return peers
}

func unionAddrs(existing, incoming []string) []string {
	seen := make(map[string]bool, len(existing)+len(incoming))
	result := make([]string, 0, len(existing)+len(incoming))

	for _, addr := range append(append([]string{}, existing...), incoming...) {
		if addr == "" || seen[addr] {
			continue
		}

		seen[addr] = true
		result = append(result, addr)
	}

	return sortAddrs(result)
}

// sortAddrs 把更容易连通的地址排在前面：
// IPv4 链路本地 → IPv4 私网 → 其他 IPv4 → IPv6 → 回环。
//
// 两条经验：
//  1. 隧道地址（100.64/10 之类）排在私网之后——本机同时有 en7 与 utun 时，
//     对端往往只能连 en7。
//  2. IPv6 一律排在 IPv4 之后——链路本地 IPv6（fe80::）连接时需要 scope id，
//     裸地址基本必然失败，放在前面只会白白浪费一次超时。
func sortAddrs(addrs []string) []string {
	rank := func(addr string) int {
		host, _, err := net.SplitHostPort(addr)
		if err != nil {
			return 9
		}

		ip := net.ParseIP(host)
		if ip == nil {
			return 9
		}

		switch {
		case ip.IsLoopback():
			return 9
		case ip.To4() == nil:
			return 5
		case ip.IsLinkLocalUnicast():
			return 0
		case ip.IsPrivate():
			return 1
		default:
			return 2
		}
	}

	sorted := append([]string{}, addrs...)
	sort.SliceStable(sorted, func(i, j int) bool { return rank(sorted[i]) < rank(sorted[j]) })

	return sorted
}

// LocalIPv4 返回本机的 IPv4 地址字符串（不带掩码），用于能力声明。
//
// 只保留可被他人访问的地址：跳过回环，跳过链路本地以外的隧道由排序决定，
// 这里不做筛选——对方会自己探测哪个可达。
func LocalIPv4() []string {
	var result []string

	interfaces, err := net.Interfaces()
	if err != nil {
		return result
	}

	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}

		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}

		for _, addr := range addrs {
			ipnet, ok := addr.(*net.IPNet)
			if !ok {
				continue
			}

			ip4 := ipnet.IP.To4()
			if ip4 == nil {
				continue
			}

			result = append(result, ip4.String())
		}
	}

	return result
}

// LocalAddresses 列出本机 IPv4 地址，直连时用来人工确认。
func LocalAddresses() []string {
	var result []string

	interfaces, err := net.Interfaces()
	if err != nil {
		return result
	}

	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 {
			continue
		}

		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}

		for _, addr := range addrs {
			ipnet, ok := addr.(*net.IPNet)
			if !ok {
				continue
			}

			ip4 := ipnet.IP.To4()
			if ip4 == nil || ip4.IsLoopback() {
				continue
			}

			note := ""
			if ip4.IsLinkLocalUnicast() {
				note = "  ← 网线直连的链路本地地址"
			}

			result = append(result, fmt.Sprintf("%s/%d %s%s", ip4.String(), maskBits(ipnet.Mask), iface.Name, note))
		}
	}

	return result
}

// broadcastTargets 覆盖所有网卡的定向广播地址与回环。
//
// 直连网线时两端往往没有默认网关，255.255.255.255 在部分系统上会因为没有
// 路由而发不出去，所以必须逐个网卡算定向广播地址。
func broadcastTargets() []*net.UDPAddr {
	seen := map[string]bool{}
	var targets []*net.UDPAddr

	add := func(ip net.IP) {
		if ip == nil {
			return
		}

		key := ip.String()
		if seen[key] {
			return
		}

		seen[key] = true
		targets = append(targets, &net.UDPAddr{IP: ip, Port: Port})
	}

	add(net.IPv4bcast)

	interfaces, err := net.Interfaces()
	if err == nil {
		for _, iface := range interfaces {
			if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
				continue
			}

			addrs, err := iface.Addrs()
			if err != nil {
				continue
			}

			for _, addr := range addrs {
				ipnet, ok := addr.(*net.IPNet)
				if !ok {
					continue
				}

				ip4 := ipnet.IP.To4()
				if ip4 == nil {
					continue
				}

				mask := ipnet.Mask
				if len(mask) == net.IPv6len {
					mask = mask[12:]
				}

				if len(mask) != net.IPv4len {
					continue
				}

				broadcast := make(net.IP, net.IPv4len)
				for i := 0; i < net.IPv4len; i++ {
					broadcast[i] = ip4[i] | ^mask[i]
				}

				add(broadcast)
			}
		}
	}

	add(net.IPv4(127, 0, 0, 1))

	return targets
}

func maskBits(mask net.IPMask) int {
	ones, _ := mask.Size()
	return ones
}
