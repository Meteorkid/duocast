// Package session 把「选链路 → 建连 → 能力交换 → 可能的升级」封装成一次建链过程。
//
// 为什么单独抽出来：`send` 与 `bench` 必须走同一条代码路径。早期 bench 自己
// 用 net.DialTimeout + 单独握手 + proto.Send(nil caps) 实现，测到的并不是
// 实际发送时执行的机制（没有能力交换、没有升级）。
//
// 时间预算：所有阶段共享**同一个绝对截止时间**。早期版本每个阶段各给一份超时，
// 结果是「3 条候选 × 4 秒 + Hello + 升级 2 秒」，总耗时远超任务截止时间，
// 而且超时之后仍可能返回成功。
package session

import (
	"errors"
	"fmt"
	"net"
	"strconv"
	"time"

	"beam/internal/link"
	"beam/internal/proto"
	"beam/internal/secure"
)

// Handshake 是默认的加密握手，供 link 作为连接验证步骤使用。
func Handshake(raw net.Conn) (net.Conn, error) {
	secured, err := secure.Handshake(raw)
	if err != nil {
		return nil, err
	}

	return secured, nil
}

// Result 是一次建链的完整结果。
type Result struct {
	Conn net.Conn

	// Link 是候选链路的协商记录（每次尝试的类型、耗时、错误），包含全部尝试。
	Link link.Result

	// PeerCaps 是对端声明的能力，可能为 nil（未启用或不支持）。
	PeerCaps *proto.Caps

	// CapsErr 记录能力交换失败原因；失败不致命，只是失去升级机会。
	CapsErr string

	// NegotiateMS 是能力交换 + 升级探测的总耗时（单调时钟）。
	NegotiateMS float64

	// Upgraded 表示是否从中转切换到了直连。
	Upgraded bool

	// UpgradeAttempts 保存升级阶段的每次尝试，即使升级失败也要保留。
	UpgradeAttempts []link.Attempt

	// UpgradeError 记录升级失败原因（保留原连接，不视为任务失败）。
	UpgradeError string

	// FinalKind / FinalLabel 是最终承载数据的链路。
	FinalKind  link.Kind
	FinalLabel string
}

// Options 控制建链过程中的可选阶段。
type Options struct {
	// Caps 为 nil 时跳过能力交换（兼容旧版本对端）。
	Caps *proto.Caps

	// AllowUpgrade 允许在中转连上后尝试切换到对端声明的直连地址。
	AllowUpgrade bool

	// Deadline 是任务级绝对截止时间，所有阶段共享。零值时回退到 Timeout。
	Deadline time.Time

	// Timeout 仅在 Deadline 为零时使用。
	Timeout time.Duration

	// Logf 可为 nil；非 nil 时逐条回报候选尝试。
	Logf func(link.Attempt)
}

// Establish 在给定时限内依次尝试候选链路，成功后按需做能力交换与升级。
//
// 返回的 error 只代表「没有任何候选可用」；能力交换失败、升级失败都不算错误，
// 因为它们不影响已建立的连接继续传输。
func Establish(candidates []link.Candidate, options Options) (Result, error) {
	result := Result{}

	deadline := options.Deadline
	if deadline.IsZero() {
		timeout := options.Timeout
		if timeout <= 0 {
			timeout = 4 * time.Second
		}

		deadline = time.Now().Add(timeout)
	}

	conn, negotiation, err := link.DialWithin(candidates, deadline, options.Timeout, Handshake, options.Logf)
	result.Link = negotiation

	if err != nil {
		return result, err
	}

	result.Conn = conn

	if negotiation.Chosen != nil {
		result.FinalKind = negotiation.Chosen.Kind
		result.FinalLabel = negotiation.Chosen.Label
	}

	if options.Caps == nil {
		return result, nil
	}

	// Hello 必须在同一份预算内：对端连上却不回 hello 时，
	// 没有 deadline 会永久阻塞。
	started := time.Now()

	_ = conn.SetDeadline(deadline)
	peerCaps, helloErr := proto.Hello(conn, options.Caps)
	_ = conn.SetDeadline(time.Time{})

	result.NegotiateMS = elapsedMS(started)

	if helloErr != nil {
		// 明确拒绝（旧版本对端）只意味着拿不到能力声明，连接仍然可用；
		// 但超时、帧错误、EOF 说明会话已经不可用，必须终止——
		// 否则调用方会拿着一条半死的连接去传文件，然后永远等不到 Result。
		if errors.Is(helloErr, proto.ErrCapsRejected) {
			result.CapsErr = helloErr.Error()
			return result, nil
		}

		conn.Close()
		result.Conn = nil

		return result, fmt.Errorf("能力交换失败，会话终止: %w", helloErr)
	}

	result.PeerCaps = peerCaps

	if !options.AllowUpgrade || result.FinalKind != link.KindRelay {
		return result, nil
	}

	if time.Now().After(deadline) {
		result.UpgradeError = "预算已耗尽，跳过升级"
		return result, nil
	}

	upgradeStart := time.Now()
	newConn, label, attempts, upgradeErr := upgrade(peerCaps, deadline)
	result.NegotiateMS += elapsedMS(upgradeStart)
	result.UpgradeAttempts = attempts

	if upgradeErr != nil {
		result.UpgradeError = upgradeErr.Error()
		return result, nil
	}

	// 升级成功：关闭中转连接，改用直连。接收端那侧的旧会话会结束，属预期行为。
	conn.Close()
	result.Conn = newConn
	result.Upgraded = true
	result.FinalKind = link.KindDiscovered
	result.FinalLabel = label

	return result, nil
}

// upgrade 用对端声明的地址尝试直连，返回新连接、命中的地址与全部尝试记录。
func upgrade(peer *proto.Caps, deadline time.Time) (net.Conn, string, []link.Attempt, error) {
	if peer == nil || peer.Port <= 0 || len(peer.Addrs) == 0 {
		return nil, "", nil, errNoUpgradeTarget
	}

	candidates := make([]link.Candidate, 0, len(peer.Addrs))
	for _, addr := range peer.Addrs {
		candidates = append(candidates, link.NewTCPCandidate(link.KindDiscovered, net.JoinHostPort(addr, strconv.Itoa(peer.Port))))
	}

	conn, result, err := link.DialWithin(candidates, deadline, 0, Handshake, nil)
	if err != nil || result.Chosen == nil {
		if err == nil {
			err = errNoUpgradeTarget
		}

		return nil, "", result.Attempts, err
	}

	return conn, result.Chosen.Label, result.Attempts, nil
}

type upgradeError string

func (e upgradeError) Error() string { return string(e) }

const errNoUpgradeTarget = upgradeError("对端未声明可直连地址")

func elapsedMS(started time.Time) float64 {
	return float64(time.Since(started).Microseconds()) / 1000
}
