package link

import (
	"errors"
	"net"
	"testing"
	"time"
)

// dummyConn 满足 net.Conn，用来在没有真实网络的情况下测试协商逻辑。
type dummyConn struct{ name string }

func (d dummyConn) Read([]byte) (int, error)         { return 0, errors.New("not implemented") }
func (d dummyConn) Write([]byte) (int, error)        { return 0, errors.New("not implemented") }
func (d dummyConn) Close() error                     { return nil }
func (d dummyConn) LocalAddr() net.Addr              { return nil }
func (d dummyConn) RemoteAddr() net.Addr             { return nil }
func (d dummyConn) SetDeadline(time.Time) error      { return nil }
func (d dummyConn) SetReadDeadline(time.Time) error  { return nil }
func (d dummyConn) SetWriteDeadline(time.Time) error { return nil }

func candidate(kind Kind, label string, cost int, ok bool, order *[]string) Candidate {
	return Candidate{
		Kind:  kind,
		Label: label,
		Cost:  cost,
		Dial: func() (net.Conn, error) {
			*order = append(*order, label)
			if ok {
				return dummyConn{name: label}, nil
			}

			return nil, errors.New("dial failed")
		},
	}
}

func TestDialAllPrefersLowestCost(t *testing.T) {
	var order []string

	// 故意把 relay 放在前面传入，验证排序而不是依赖入参顺序。
	candidates := []Candidate{
		candidate(KindRelay, "relay", 90, true, &order),
		candidate(KindDirect, "direct", 20, true, &order),
		candidate(KindDiscovered, "discovered", 10, true, &order),
	}

	conn, result, err := DialAll(candidates, time.Second, nil, nil)
	if err != nil {
		t.Fatalf("不应失败: %v", err)
	}
	if conn == nil {
		t.Fatal("成功时应返回连接")
	}
	if len(order) != 1 || order[0] != "discovered" {
		t.Fatalf("应先尝试成本最低的候选，实际顺序: %v", order)
	}
	if result.Chosen == nil || result.Chosen.Label != "discovered" {
		t.Fatalf("Chosen 记录不对: %+v", result.Chosen)
	}
	if len(result.Attempts) != 1 {
		t.Fatalf("只应尝试一次，实际 %d 次", len(result.Attempts))
	}
}

func TestDialAllFallsBackOnFailure(t *testing.T) {
	var order []string

	candidates := []Candidate{
		candidate(KindDiscovered, "discovered", 10, false, &order),
		candidate(KindDirect, "direct", 20, true, &order),
	}

	_, result, err := DialAll(candidates, time.Second, nil, nil)
	if err != nil {
		t.Fatalf("不应失败: %v", err)
	}
	if len(order) != 2 || order[0] != "discovered" || order[1] != "direct" {
		t.Fatalf("应按成本顺序回退，实际: %v", order)
	}
	if result.Chosen == nil || result.Chosen.Label != "direct" {
		t.Fatalf("应选中 direct，实际: %+v", result.Chosen)
	}
	if result.Attempts[0].OK || result.Attempts[0].Error == "" {
		t.Fatalf("第一次尝试应记录为失败并带错误信息: %+v", result.Attempts[0])
	}
}

func TestDialAllAllFail(t *testing.T) {
	var order []string

	candidates := []Candidate{
		candidate(KindDiscovered, "a", 10, false, &order),
		candidate(KindDirect, "b", 20, false, &order),
		candidate(KindRelay, "c", 90, false, &order),
	}

	conn, result, err := DialAll(candidates, time.Second, nil, nil)
	if err == nil {
		t.Fatal("全部失败时应返回错误")
	}
	if conn != nil {
		t.Fatal("失败时不应返回连接")
	}
	if len(result.Attempts) != 3 {
		t.Fatalf("应记录 3 次尝试，实际 %d", len(result.Attempts))
	}
	if result.Chosen != nil {
		t.Fatal("失败时不应有 Chosen")
	}
}

func TestDialAllTimesOutBlockingDial(t *testing.T) {
	candidates := []Candidate{{
		Kind:    KindRelay,
		Label:   "blocking",
		Cost:    90,
		Timeout: 30 * time.Millisecond,
		Dial: func() (net.Conn, error) {
			time.Sleep(500 * time.Millisecond)
			return dummyConn{}, nil
		},
	}}

	started := time.Now()
	_, result, err := DialAll(candidates, time.Second, nil, nil)
	elapsed := time.Since(started)

	if err == nil {
		t.Fatal("应超时失败")
	}
	if elapsed > 300*time.Millisecond {
		t.Fatalf("超时未生效，耗时 %v", elapsed)
	}
	if len(result.Attempts) != 1 || result.Attempts[0].Error != "超时" {
		t.Fatalf("应记录超时: %+v", result.Attempts)
	}
}

func TestDialAllNoCandidate(t *testing.T) {
	_, _, err := DialAll(nil, time.Second, nil, nil)
	if !errors.Is(err, ErrNoCandidate) {
		t.Fatalf("空候选应返回 ErrNoCandidate，实际: %v", err)
	}
}

func TestDialAllRetriesAfterHandshakeFailure(t *testing.T) {
	var order []string

	candidates := []Candidate{
		candidate(KindDiscovered, "fake", 10, true, &order),
		candidate(KindDiscovered, "real", 11, true, &order),
	}

	handshake := func(conn net.Conn) (net.Conn, error) {
		if conn.(dummyConn).name == "fake" {
			return nil, errors.New("EOF")
		}

		return conn, nil
	}

	conn, result, err := DialAll(candidates, time.Second, handshake, nil)
	if err != nil {
		t.Fatalf("第二条候选应成功: %v", err)
	}
	if len(order) != 2 {
		t.Fatalf("握手失败后应继续尝试，实际只试了 %d 次", len(order))
	}
	if result.Chosen == nil || result.Chosen.Label != "real" {
		t.Fatalf("应选中 real: %+v", result.Chosen)
	}
	if result.Attempts[0].OK || result.Attempts[0].Error == "" {
		t.Fatalf("第一条应记成握手失败: %+v", result.Attempts[0])
	}
	if conn == nil {
		t.Fatal("应返回连接")
	}
}

// TestDialAllHandshakeRespectsTimeout 覆盖「端口开着但不说话」的对端：
// 早期版本的超时只包住 Dial，握手会永久阻塞。
func TestDialAllHandshakeRespectsTimeout(t *testing.T) {
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
		time.Sleep(2 * time.Second)
	}()

	candidate := Candidate{
		Kind:    KindDirect,
		Label:   "silent",
		Cost:    20,
		Timeout: 200 * time.Millisecond,
		Dial: func() (net.Conn, error) {
			return net.DialTimeout("tcp", listener.Addr().String(), time.Second)
		},
	}

	handshake := func(conn net.Conn) (net.Conn, error) {
		buffer := make([]byte, 1)
		if _, err := conn.Read(buffer); err != nil {
			return nil, err
		}

		return conn, nil
	}

	started := time.Now()
	_, result, err := DialAll([]Candidate{candidate}, time.Second, handshake, nil)
	elapsed := time.Since(started)

	if err == nil {
		t.Fatal("对端不响应时应失败")
	}

	if elapsed > time.Second {
		t.Fatalf("握手未被超时打断，耗时 %v", elapsed)
	}

	if len(result.Attempts) != 1 || result.Attempts[0].OK {
		t.Fatalf("应记录一次握手失败: %+v", result.Attempts)
	}

	if result.Attempts[0].HandshakeMS <= 0 {
		t.Fatalf("应记录握手耗时: %+v", result.Attempts[0])
	}
}

// TestDialWithinSharesBudgetAcrossCandidates 多条候选共享同一份预算。
// 若每条候选各给一份超时，3 条 × 300ms 会拖到 900ms 以上。
func TestDialWithinSharesBudgetAcrossCandidates(t *testing.T) {
	listeners := make([]net.Listener, 0, 3)

	for i := 0; i < 3; i++ {
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatalf("监听失败: %v", err)
		}

		listeners = append(listeners, listener)

		// 接受连接后保持沉默，让握手一直等到 deadline。
		go func(l net.Listener) {
			conn, err := l.Accept()
			if err != nil {
				return
			}
			defer conn.Close()
			time.Sleep(2 * time.Second)
		}(listener)
	}

	defer func() {
		for _, listener := range listeners {
			listener.Close()
		}
	}()

	candidates := make([]Candidate, 0, len(listeners))
	for _, listener := range listeners {
		address := listener.Addr().String()
		candidates = append(candidates, Candidate{
			Kind:  KindDirect,
			Label: address,
			Cost:  20,
			Dial: func() (net.Conn, error) {
				return net.DialTimeout("tcp", address, time.Second)
			},
		})
	}

	handshake := func(conn net.Conn) (net.Conn, error) {
		buffer := make([]byte, 1)
		if _, err := conn.Read(buffer); err != nil {
			return nil, err
		}

		return conn, nil
	}

	started := time.Now()
	_, result, err := DialWithin(candidates, time.Now().Add(300*time.Millisecond), 300*time.Millisecond, handshake, nil)
	elapsed := time.Since(started)

	if err == nil {
		t.Fatal("全部候选都不响应时应失败")
	}

	// 断言用「结构性指标」而不是精确墙钟：-race 与并行包会让墙钟抖动，
	// 真正要证明的是「预算被第一条吃光，后面的候选没机会跑」。
	if len(result.Attempts) >= len(candidates) {
		t.Fatalf("预算未共享：%d 条候选全部被尝试", len(result.Attempts))
	}

	if elapsed > 900*time.Millisecond {
		t.Fatalf("耗时远超单份预算，疑似每候选各给一份超时: %v", elapsed)
	}
}
