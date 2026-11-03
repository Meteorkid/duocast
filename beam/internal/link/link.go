// Package link 把「怎么连上对端」从调用方剥离出来。
//
// 动机来自实测：同一个对端可能同时存在多条可达路径（同网段直连、NAT 后的地址、
// 经中转），而哪条能通取决于网络拓扑，调用方无法预先知道。传统做法是让用户
// 自己选（--to / --peer / --relay），选错就是超时。
//
// 这里改成：按成本排序候选链路，逐条尝试，记录每次尝试的结果。
// 失败不是异常，而是协商过程的一部分——每次尝试都留下结构化记录，
// 供排障和测量分析使用。
package link

import (
	"errors"
	"fmt"
	"net"
	"sort"
	"time"
)

// Kind 是链路的类型，用于排序与统计。
type Kind string

const (
	// KindDiscovered 是通过 UDP 广播 / mDNS 发现的同网段地址。
	KindDiscovered Kind = "discovered"
	// KindDirect 是用户显式指定的地址。
	KindDirect Kind = "direct"
	// KindRelay 是经中转服务器配对。
	KindRelay Kind = "relay"
)

// 成本常量：数值只用于排序，不代表绝对开销。
const (
	costDiscovered = 10
	costDirect     = 20
	costRelay      = 90
)

// Candidate 是一条候选链路。
type Candidate struct {
	Kind  Kind
	Label string // 显示与日志用，例如 "10.202.4.30:9001"
	Cost  int

	// Timeout 是该候选自己的超时；0 表示用默认值。
	// 中转配对可能要等对方上线，需要单独给更长的超时。
	Timeout time.Duration

	Dial func() (net.Conn, error)

	// DialDeadline 可选：需要感知预算的实现（例如中转配对，内部默认等 2 分钟）
	// 用它代替 Dial。收到的是本次尝试的绝对截止时间，实现方不得再自行放宽。
	DialDeadline func(deadline time.Time) (net.Conn, error)
}

// Attempt 是一次尝试的记录。
//
// MS 是这条候选的总耗时（连接 + 握手），DialMS / HandshakeMS 是拆分，
// 供测量时区分「网络不可达」与「对端不是我们」两类失败。
type Attempt struct {
	Kind        Kind    `json:"kind"`
	Label       string  `json:"label"`
	Cost        int     `json:"cost"`
	MS          float64 `json:"ms"`
	DialMS      float64 `json:"dial_ms"`
	HandshakeMS float64 `json:"handshake_ms,omitempty"`
	OK          bool    `json:"ok"`
	Error       string  `json:"error,omitempty"`
}

// Result 是一轮协商的完整记录。
type Result struct {
	Chosen   *Attempt  `json:"chosen,omitempty"`
	Attempts []Attempt `json:"attempts"`
	TotalMS  float64   `json:"total_ms"`
}

// ErrNoCandidate 表示没有可尝试的候选链路。
var ErrNoCandidate = errors.New("没有可用的候选链路")

// Handshake 是连接建立后的验证步骤（例如加密握手）。
//
// 放进协商里是必要的：实测遇到过「TCP 连上但对方立刻关闭」的假连接
// （隧道/VPN 会代理未监听的端口），如果握手留在协商之外，一次假连接
// 就会让整个流程失败，而实际上后面还有能用的候选。
type Handshake func(net.Conn) (net.Conn, error)

// DialAll 是 DialWithin 的便捷包装：从现在起算 timeout 作为总预算。
func DialAll(candidates []Candidate, timeout time.Duration, handshake Handshake, logf func(Attempt)) (net.Conn, Result, error) {
	return DialWithin(candidates, time.Now().Add(timeout), timeout, handshake, logf)
}

// DialWithin 在一个**绝对截止时间**内依次尝试候选链路。
//
// 与「每条候选各给一份超时」不同，这里所有候选共享同一份预算：
// 三条候选各 4 秒的超时会让总耗时变成 12 秒，超出任务截止时间，
// 而且每一段都在偷偷重置预算。调用方应传入任务级的绝对 deadline。
//
// handshake 可为 nil。logf 可为 nil。
func DialWithin(candidates []Candidate, deadline time.Time, defaultTimeout time.Duration, handshake Handshake, logf func(Attempt)) (net.Conn, Result, error) {
	result := Result{Attempts: make([]Attempt, 0, len(candidates))}

	if defaultTimeout <= 0 {
		defaultTimeout = 4 * time.Second
	}

	ordered := make([]Candidate, 0, len(candidates))
	for _, candidate := range candidates {
		if candidate.Dial != nil || candidate.DialDeadline != nil {
			ordered = append(ordered, candidate)
		}
	}

	if len(ordered) == 0 {
		return nil, result, ErrNoCandidate
	}

	// 稳定排序：同成本保持调用方给的顺序（发现阶段已按地址优先级排过）。
	sort.SliceStable(ordered, func(i, j int) bool { return ordered[i].Cost < ordered[j].Cost })

	started := time.Now()

	for index, candidate := range ordered {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			// 预算已耗尽：不再发起新候选，也不伪造 never-tried 的记录。
			break
		}

		// 单条候选的预算 = min(剩余总预算, 该候选自己的上限)。
		candidateTimeout := candidate.Timeout
		if candidateTimeout <= 0 || candidateTimeout > remaining {
			candidateTimeout = remaining
		}

		conn, attempt := tryOne(candidate, candidateTimeout)

		// 连接建立后再验证一次：能连上不等于对端是我们的接收端。
		if attempt.OK && handshake != nil {
			handshakeStart := time.Now()

			// 超时必须覆盖握手：只包住 Dial 的话，遇到「端口开着但不响应」的对端
			// 会永久阻塞。这里先把读写截止时间压上去，握手成功后再清空，
			// 避免后续传输被同一个 deadline 限制。
			handshakeDeadline := time.Now().Add(candidateTimeout)
			if handshakeDeadline.After(deadline) {
				handshakeDeadline = deadline
			}

			_ = conn.SetDeadline(handshakeDeadline)

			secured, err := handshake(conn)
			attempt.HandshakeMS = elapsedMS(handshakeStart)
			attempt.MS = attempt.DialMS + attempt.HandshakeMS

			if err != nil {
				conn.Close()
				attempt.OK = false
				attempt.Error = "握手失败: " + err.Error()
			} else {
				_ = secured.SetDeadline(time.Time{})
				conn = secured
			}
		}

		result.Attempts = append(result.Attempts, attempt)

		if logf != nil {
			logf(attempt)
		}

		if attempt.OK {
			result.Chosen = &result.Attempts[index]
			result.TotalMS = elapsedMS(started)
			return conn, result, nil
		}
	}

	result.TotalMS = elapsedMS(started)

	return nil, result, fmt.Errorf("全部 %d 条候选链路均失败", len(result.Attempts))
}

// tryOneHook 仅供测试注入：在进入 select 之前执行，用来稳定复现
// 「生产者先于消费者完成」的时序，不参与生产逻辑。
var tryOneHook func()

// tryOne 尝试一条候选，返回连接与记录。失败时连接为 nil。
//
// 用 goroutine + 超时，是为了给「自带阻塞语义」的候选（比如中转配对）
// 套上统一的时间上限；网络层自己超时返回的错误会原样保留。
func tryOne(candidate Candidate, budget time.Duration) (net.Conn, Attempt) {
	// 预算由 DialWithin 统一算一次（已经和 remaining、candidate.Timeout 取过 min）。
	// 这里若再去读 candidate.Timeout，会把预算重新放大——relay 的 90 秒就是这样
	// 盖掉了 100ms 的总预算。
	if budget <= 0 {
		budget = time.Millisecond
	}

	started := time.Now()

	type outcome struct {
		conn net.Conn
		err  error
	}

	// 缓冲 1：生产者永远不会因为「消费者还没到」而阻塞，
	// 也就不会出现「合法结果被 select default 丢掉」的伪超时。
	done := make(chan outcome, 1)

	go func() {
		var (
			conn net.Conn
			err  error
		)

		if candidate.DialDeadline != nil {
			conn, err = candidate.DialDeadline(time.Now().Add(budget))
		} else if candidate.Dial != nil {
			conn, err = candidate.Dial()
		} else {
			err = errors.New("候选没有可用的拨号实现")
		}

		done <- outcome{conn: conn, err: err}
	}()

	if tryOneHook != nil {
		tryOneHook()
	}

	select {
	case result := <-done:
		elapsed := elapsedMS(started)

		if result.err != nil {
			if result.conn != nil {
				_ = result.conn.Close()
			}

			return nil, Attempt{Kind: candidate.Kind, Label: candidate.Label, Cost: candidate.Cost, MS: elapsed, DialMS: elapsed, Error: result.err.Error()}
		}

		return result.conn, Attempt{Kind: candidate.Kind, Label: candidate.Label, Cost: candidate.Cost, MS: elapsed, DialMS: elapsed, OK: true}

	case <-time.After(budget):
		elapsed := elapsedMS(started)

		// 真超时：晚到的连接必须关掉，不能留给后台。
		select {
		case result := <-done:
			if result.conn != nil {
				_ = result.conn.Close()
			}
		default:
			go func() {
				result := <-done
				if result.conn != nil {
					_ = result.conn.Close()
				}
			}()
		}

		return nil, Attempt{Kind: candidate.Kind, Label: candidate.Label, Cost: candidate.Cost, MS: elapsed, DialMS: elapsed, Error: "超时"}
	}
}

// NewTCPCandidate 构造一条普通的 TCP 直连候选。
func NewTCPCandidate(kind Kind, addr string) Candidate {
	cost := costDirect
	if kind == KindDiscovered {
		cost = costDiscovered
	}

	return Candidate{
		Kind:  kind,
		Label: addr,
		Cost:  cost,
		Dial: func() (net.Conn, error) {
			return net.DialTimeout("tcp", addr, 4*time.Second)
		},
	}
}

// NewRelayCandidate 构造一条中转候选。
//
// 中转配对要等对方也出现在同一个房间，所以单独给更长的超时；
// 这条候选成本最高，会被排到最后。
func NewRelayCandidate(relayAddr, room string, pairWithin func(string, string, time.Time) (net.Conn, error)) Candidate {
	return Candidate{
		Kind:    KindRelay,
		Label:   relayAddr + "/" + room,
		Cost:    costRelay,
		Timeout: 90 * time.Second,
		DialDeadline: func(deadline time.Time) (net.Conn, error) {
			return pairWithin(relayAddr, room, deadline)
		},
	}
}

func elapsedMS(started time.Time) float64 {
	return float64(time.Since(started).Microseconds()) / 1000
}
