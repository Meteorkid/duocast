package session

import (
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"beam/internal/link"
	"beam/internal/proto"
	"beam/internal/secure"
)

// TestEstablishConnectsAndTransfers 覆盖产品实际走的那条路径：
// DialAll → 握手 → （无 caps）→ proto.Send。
func TestEstablishConnectsAndTransfers(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("监听失败: %v", err)
	}
	defer listener.Close()

	dir := t.TempDir()
	done := make(chan error, 1)

	go func() {
		conn, err := listener.Accept()
		if err != nil {
			done <- err
			return
		}
		defer conn.Close()

		secured, err := secure.Handshake(conn)
		if err != nil {
			done <- err
			return
		}

		_, err = proto.Receive(secured, dir, nil, func(proto.Plan) bool { return true }, nil)
		done <- err
	}()

	candidate := link.NewTCPCandidate(link.KindDirect, listener.Addr().String())

	result, err := Establish([]link.Candidate{candidate}, Options{Timeout: 3 * time.Second})
	if err != nil {
		t.Fatalf("建链失败: %v", err)
	}
	defer result.Conn.Close()

	if result.FinalKind != link.KindDirect {
		t.Fatalf("最终链路应为 direct，实际 %q", result.FinalKind)
	}

	chosen := result.Link.Chosen
	if chosen == nil {
		t.Fatal("应记录命中的候选")
	}

	if chosen.DialMS <= 0 || chosen.HandshakeMS <= 0 {
		t.Fatalf("应分别记录连接与握手耗时: %+v", chosen)
	}

	source := filepath.Join(t.TempDir(), "单文件.txt")
	if err := os.WriteFile(source, []byte("session test"), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := proto.Send(result.Conn, []string{source}, nil, nil); err != nil {
		t.Fatalf("发送失败: %v", err)
	}

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("接收端报错: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("接收端未结束")
	}

	if _, err := os.Stat(filepath.Join(dir, "单文件.txt")); err != nil {
		t.Fatalf("文件未落盘: %v", err)
	}
}

// TestEstablishFailsWithoutReachableCandidate 确认「没有候选可用」会返回错误并留下记录。
func TestEstablishFailsWithoutReachableCandidate(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("监听失败: %v", err)
	}

	addr := listener.Addr().String()
	listener.Close() // 关掉，制造 connection refused

	candidate := link.NewTCPCandidate(link.KindDirect, addr)

	result, err := Establish([]link.Candidate{candidate}, Options{Timeout: 500 * time.Millisecond})
	if err == nil {
		t.Fatal("不可达时应返回错误")
	}

	if result.Conn != nil {
		t.Fatal("失败时不应返回连接")
	}

	if len(result.Link.Attempts) != 1 || result.Link.Attempts[0].OK {
		t.Fatalf("应记录一次失败尝试: %+v", result.Link.Attempts)
	}
}

// TestEstablishStopsAtDeadlineWhenHelloIgnored 覆盖「握手成功但对端不回 Hello」。
// 早期版本 Hello 没有 deadline，会永久阻塞。
func TestEstablishStopsAtDeadlineWhenHelloIgnored(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("监听失败: %v", err)
	}
	defer listener.Close()

	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()

		if _, err := secure.Handshake(conn); err != nil {
			return
		}

		// 故意不回 hello，把连接挂住。
		time.Sleep(2 * time.Second)
	}()

	candidate := link.NewTCPCandidate(link.KindDirect, listener.Addr().String())
	deadline := time.Now().Add(300 * time.Millisecond)

	started := time.Now()
	result, err := Establish([]link.Candidate{candidate}, Options{
		Caps:     &proto.Caps{Name: "tester"},
		Deadline: deadline,
	})
	elapsed := time.Since(started)

	// Hello 超时意味着会话已不可用：必须返回错误并终止，
	// 不能吞掉错误、把连接交给调用方继续无期限传输。
	if err == nil {
		if result.Conn != nil {
			result.Conn.Close()
		}

		t.Fatal("Hello 超时后必须返回错误")
	}

	if elapsed > 800*time.Millisecond {
		t.Fatalf("Hello 未被 deadline 打断，耗时 %v", elapsed)
	}

	if result.Conn != nil {
		t.Fatal("会话已损坏，不应把连接交给调用方")
	}

	if result.Conn != nil {
		result.Conn.Close()
	}
}

// TestUpgradeFailureKeepsRelayConn 覆盖「升级失败但仍可用中转继续传输」。
// 同时确认升级阶段的尝试明细被保留，而不是被丢弃。
func TestUpgradeFailureKeepsRelayConn(t *testing.T) {
	// 找一个必然拒绝的端口：开一个监听再立刻关掉。
	tmp, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	deadPort := tmp.Addr().(*net.TCPAddr).Port
	tmp.Close()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	dir := t.TempDir()
	peerCaps := &proto.Caps{Name: "peer", Port: deadPort, Addrs: []string{"127.0.0.1"}}

	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()

		secured, err := secure.Handshake(conn)
		if err != nil {
			return
		}

		_, _ = proto.Receive(secured, dir, peerCaps, func(proto.Plan) bool { return true }, nil)
	}()

	addr := listener.Addr().String()
	candidate := link.Candidate{
		Kind:  link.KindRelay,
		Label: "fake-relay",
		Cost:  90,
		Dial: func() (net.Conn, error) {
			return net.DialTimeout("tcp", addr, time.Second)
		},
	}

	result, err := Establish([]link.Candidate{candidate}, Options{
		Caps:         &proto.Caps{Name: "tester"},
		AllowUpgrade: true,
		Deadline:     time.Now().Add(5 * time.Second),
	})
	if err != nil {
		t.Fatalf("中转建链应成功: %v", err)
	}
	defer result.Conn.Close()

	if result.Upgraded {
		t.Fatal("对端地址不可达时不应升级成功")
	}

	if result.FinalKind != link.KindRelay {
		t.Fatalf("应保留中转链路，实际 %q", result.FinalKind)
	}

	if result.UpgradeError == "" {
		t.Fatal("应记录升级失败原因")
	}

	if len(result.UpgradeAttempts) == 0 {
		t.Fatal("升级尝试明细不能被丢弃")
	}

	// 中转连接仍可用：继续传文件应成功。
	source := filepath.Join(t.TempDir(), "after-failed-upgrade.txt")
	if err := os.WriteFile(source, []byte("still works"), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := proto.Send(result.Conn, []string{source}, nil, nil); err != nil {
		t.Fatalf("升级失败后中转连接应仍可传输: %v", err)
	}

	if _, err := os.Stat(filepath.Join(dir, "after-failed-upgrade.txt")); err != nil {
		t.Fatalf("文件未落盘: %v", err)
	}
}
