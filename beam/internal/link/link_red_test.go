package link

import (
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// silentListener 接受连接后保持沉默，用于制造握手阻塞。
func silentListener(t *testing.T) net.Listener {
	t.Helper()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("监听失败: %v", err)
	}

	t.Cleanup(func() { listener.Close() })

	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}

			go func(c net.Conn) {
				defer c.Close()
				time.Sleep(5 * time.Second)
			}(conn)
		}
	}()

	return listener
}

func blockingHandshake(conn net.Conn) (net.Conn, error) {
	buffer := make([]byte, 1)
	if _, err := conn.Read(buffer); err != nil {
		return nil, err
	}

	return conn, nil
}

// TestBudgetNotOverriddenByCandidateTimeout：候选自带 3s 超时，但总预算只有 100ms。
// 预算必须在 DialWithin 算一次，不能在下层被 candidate.Timeout 重新放大。
func TestBudgetNotOverriddenByCandidateTimeout(t *testing.T) {
	listener := silentListener(t)

	candidate := Candidate{
		Kind:    KindRelay,
		Label:   "relay-with-long-timeout",
		Cost:    90,
		Timeout: 3 * time.Second,
		// Dial 本身阻塞：只有这样才能暴露「tryOne 重新取 candidate.Timeout」。
		Dial: func() (net.Conn, error) {
			time.Sleep(1 * time.Second)
			return net.DialTimeout("tcp", listener.Addr().String(), time.Second)
		},
	}

	started := time.Now()
	_, _, err := DialWithin([]Candidate{candidate}, time.Now().Add(100*time.Millisecond), 100*time.Millisecond, blockingHandshake, nil)
	elapsed := time.Since(started)

	if err == nil {
		t.Fatal("对端不响应时应失败")
	}

	if elapsed > 600*time.Millisecond {
		t.Fatalf("预算被 candidate.Timeout 覆盖，耗时 %v", elapsed)
	}
}

type trackedConn struct {
	net.Conn
	closed atomic.Bool
}

func (c *trackedConn) Close() error {
	c.closed.Store(true)
	return c.Conn.Close()
}

// TestLateConnClosedAfterTimeout：超时之后才建立起来的连接必须被关闭。
func TestLateConnClosedAfterTimeout(t *testing.T) {
	listener := silentListener(t)

	var late trackedConn

	candidate := Candidate{
		Kind:  KindDirect,
		Label: "late",
		Cost:  20,
		Dial: func() (net.Conn, error) {
			time.Sleep(120 * time.Millisecond)

			raw, err := net.Dial("tcp", listener.Addr().String())
			if err != nil {
				return nil, err
			}

			late = trackedConn{Conn: raw}
			return &late, nil
		},
	}

	_, _, err := DialWithin([]Candidate{candidate}, time.Now().Add(30*time.Millisecond), 30*time.Millisecond, nil, nil)
	if err == nil {
		t.Fatal("应在连接建立前超时")
	}

	time.Sleep(300 * time.Millisecond)

	if !late.closed.Load() {
		t.Fatal("超时后晚到的连接未被关闭")
	}
}

// TestFastSuccessNotDropped：Dial 立即返回时，合法的结果不能被误判成超时。
//
// 用 tryOneHook 把「生产者先于消费者完成」的时序固定下来：
// 旧实现是无缓冲 channel + select default，此时会走 default 关闭连接，
// 主 goroutine 随后等满超时，得到伪超时。
func TestFastSuccessNotDropped(t *testing.T) {
	tryOneHook = func() {
		time.Sleep(2 * time.Millisecond)
	}
	t.Cleanup(func() { tryOneHook = nil })

	for i := 0; i < 50; i++ {
		candidate := Candidate{
			Kind:  KindDirect,
			Label: "fast",
			Cost:  20,
			Dial: func() (net.Conn, error) {
				client, server := net.Pipe()
				server.Close()
				return client, nil
			},
		}

		conn, _, err := DialWithin([]Candidate{candidate}, time.Now().Add(500*time.Millisecond), 500*time.Millisecond, nil, nil)
		if err != nil {
			t.Fatalf("第 %d 次快速成功被判为失败: %v", i, err)
		}

		conn.Close()
	}
}

// TestConcurrentFastSuccess：并发调用时也不能丢结果。
func TestConcurrentFastSuccess(t *testing.T) {
	var wg sync.WaitGroup
	failures := make(chan error, 32)

	for i := 0; i < 32; i++ {
		wg.Add(1)

		go func() {
			defer wg.Done()

			candidate := Candidate{
				Kind:  KindDirect,
				Label: "fast",
				Cost:  20,
				Dial: func() (net.Conn, error) {
					client, server := net.Pipe()
					server.Close()
					return client, nil
				},
			}

			conn, _, err := DialWithin([]Candidate{candidate}, time.Now().Add(5*time.Millisecond), 5*time.Millisecond, nil, nil)
			if err != nil {
				failures <- err
				return
			}

			conn.Close()
		}()
	}

	wg.Wait()
	close(failures)

	for err := range failures {
		t.Fatalf("并发下丢失成功结果: %v", err)
	}
}
