package relay

import (
	"net"
	"testing"
	"time"
)

// silentRelay 接受连接、读掉 JOIN 行，然后什么都不做（房间永不配对）。
// closed 在检测到客户端断开（读返回错误）时关闭。
func silentRelay(t *testing.T) (net.Listener, <-chan struct{}) {
	t.Helper()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("监听失败: %v", err)
	}

	t.Cleanup(func() { listener.Close() })

	closed := make(chan struct{})

	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()

		buffer := make([]byte, 128)
		if _, err := conn.Read(buffer); err != nil {
			return
		}

		// 一直读：客户端关闭时这里会返回错误。
		for {
			if _, err := conn.Read(buffer); err != nil {
				close(closed)
				return
			}
		}
	}()

	return listener, closed
}

// TestPairWithinRespectsDeadline：总预算 100ms 时，配对必须及时放弃并关闭连接。
func TestPairWithinRespectsDeadline(t *testing.T) {
	listener, closed := silentRelay(t)

	started := time.Now()
	conn, err := PairWithin(listener.Addr().String(), "ROOM1", "send", time.Now().Add(100*time.Millisecond))
	elapsed := time.Since(started)

	if err == nil {
		conn.Close()
		t.Fatal("没有对端时应失败")
	}

	if elapsed > 600*time.Millisecond {
		t.Fatalf("未遵守外部预算，耗时 %v", elapsed)
	}

	select {
	case <-closed:
	case <-time.After(500 * time.Millisecond):
		t.Fatal("超时后客户端连接未关闭：服务端仍能读，说明连接被留在后台")
	}
}

// TestPairWithoutBudgetWaits 记录改造前的行为：Pair 内部固定等 waitTimeout，
// 外部无法施加更短预算。这个用例用于说明「为什么需要 PairWithin」。
func TestPairWithoutBudgetWaits(t *testing.T) {
	listener, _ := silentRelay(t)

	done := make(chan struct{})

	go func() {
		conn, err := Pair(listener.Addr().String(), "ROOM2", "send")
		if err == nil && conn != nil {
			conn.Close()
		}
		close(done)
	}()

	select {
	case <-done:
		t.Fatal("Pair 不接外部预算，不应在 600ms 内返回")
	case <-time.After(600 * time.Millisecond):
		// 仍在等待，证明内部超时（waitTimeout）与调用方预算无关。
	}
}
