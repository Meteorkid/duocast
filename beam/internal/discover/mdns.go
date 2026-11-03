package discover

import (
	"context"
	"io"
	"net"
	"strconv"
	"time"

	"github.com/grandcat/zeroconf"
)

// mDNS（Bonjour）发现：与 UDP 广播互补。
//
// 为什么两条都要有：
//   - 广播是最简单的，但企业/酒店 WiFi 常把 255.255.255.255 过滤掉；
//   - mDNS 走 224.0.0.251 组播，过滤策略不同，而且它是 Bonjour/AirDrop/
//     LocalSend 的标准服务发现方式，macOS 自带、Windows 10+ 也支持；
//   - 两条都失败时还有 --to 手动指定地址兜底。
const (
	serviceType   = "_beam._tcp"
	serviceDomain = "local."
)

// RegisterMDNS 把本机注册为 _beam._tcp 服务，供同网段的 beam 浏览到。
func RegisterMDNS(name string, port int) (io.Closer, error) {
	server, err := zeroconf.Register(name, serviceType, serviceDomain, port, []string{"v=1"}, nil)
	if err != nil {
		return nil, err
	}

	return closerFunc(func() error {
		server.Shutdown()
		return nil
	}), nil
}

// BrowseMDNS 在 timeout 内浏览同网段的 beam 服务。
func BrowseMDNS(timeout time.Duration) ([]Peer, error) {
	resolver, err := zeroconf.NewResolver(nil)
	if err != nil {
		return nil, err
	}

	entries := make(chan *zeroconf.ServiceEntry, 16)

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	go func() {
		// 浏览在超时后返回错误属于正常路径，忽略即可。
		_ = resolver.Browse(ctx, serviceType, serviceDomain, entries)
	}()

	found := make(map[string]Peer)

	for {
		select {
		case entry, ok := <-entries:
			if !ok {
				entries = nil
				continue
			}

			if entry == nil {
				continue
			}

			addrs := addressesOf(entry)
			if len(addrs) == 0 {
				continue
			}

			found[entry.Instance] = Peer{
				Name:   entry.Instance,
				Addrs:  addrs,
				Source: SourceMDNS,
			}

		case <-ctx.Done():
			peers := make([]Peer, 0, len(found))
			for _, peer := range found {
				peers = append(peers, peer)
			}

			return peers, nil
		}
	}
}

// addressesOf 返回该服务的全部候选地址（多个网卡会各报一个）。
// 具体连哪个交给拨号阶段逐个尝试，这里只负责别漏。
func addressesOf(entry *zeroconf.ServiceEntry) []string {
	port := strconv.Itoa(entry.Port)

	addrs := make([]string, 0, len(entry.AddrIPv4)+len(entry.AddrIPv6))

	for _, ip := range entry.AddrIPv4 {
		if ip != nil {
			addrs = append(addrs, net.JoinHostPort(ip.String(), port))
		}
	}

	for _, ip := range entry.AddrIPv6 {
		if ip != nil && !ip.IsLoopback() {
			addrs = append(addrs, net.JoinHostPort(ip.String(), port))
		}
	}

	return sortAddrs(usableAddrs(addrs))
}

type closerFunc func() error

func (f closerFunc) Close() error { return f() }
