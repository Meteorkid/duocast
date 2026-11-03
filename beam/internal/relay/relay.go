// Package relay 实现中转配对：双方都只主动出站连接中转服务器，
// 服务器按房间码把两条连接配成一对，然后原样转发字节。
//
// 这样两端都不需要公网 IP、不需要端口映射，穿 NAT 与防火墙。
// 服务器看不到明文——加密在两端完成。
package relay

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"sync"
	"time"
)

const (
	magic       = "BEAM1"
	waitTimeout = 2 * time.Minute
)

type waiter struct {
	conn net.Conn
	done chan struct{}
}

var (
	mu    sync.Mutex
	rooms = make(map[string]map[string]*waiter)
)

// Serve 启动中转服务器，阻塞直到监听失败。
func Serve(addr string, logf func(string, ...any)) error {
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("监听 %s 失败: %w", addr, err)
	}

	if logf != nil {
		logf("中转已启动，监听 %s", listener.Addr())
	}

	for {
		conn, err := listener.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return nil
			}

			return err
		}

		go handle(conn, logf)
	}
}

func handle(conn net.Conn, logf func(string, ...any)) {
	room, role, err := greet(conn)
	if err != nil {
		conn.Close()
		return
	}

	me := &waiter{conn: conn, done: make(chan struct{})}
	opposite := "recv"
	if role == "recv" {
		opposite = "send"
	}

	mu.Lock()
	pending := rooms[room]
	if pending == nil {
		pending = make(map[string]*waiter)
		rooms[room] = pending
	}

	if peer := pending[opposite]; peer != nil {
		delete(pending, opposite)
		if len(pending) == 0 {
			delete(rooms, room)
		}
		mu.Unlock()

		if logf != nil {
			logf("房间 %s 配对成功", room)
		}

		// 由先到的一侧出现配对，也只由它负责转发。
		// 早期版本两边各自启动一份 io.Copy，结果每条连接被复制两遍、
		// PAIRED 也写了两行，握手直接错位。
		pipe(me.conn, peer.conn)

		close(peer.done)
		return
	}

	pending[role] = me
	mu.Unlock()

	select {
	case <-me.done:
		// 对端已接手，连接由 pipe 负责关闭。

	case <-time.After(waitTimeout):
		mu.Lock()
		if current := rooms[room]; current != nil && current[role] == me {
			delete(current, role)
			if len(current) == 0 {
				delete(rooms, room)
			}
		}
		mu.Unlock()

		fmt.Fprintf(conn, "ERR timeout\n")
		conn.Close()
	}
}

// pipe 通知双方配对成功（每条连接只写一次），再双向转发直到结束。
func pipe(a, b net.Conn) {
	a.Write([]byte("PAIRED\n"))
	b.Write([]byte("PAIRED\n"))

	done := make(chan struct{}, 2)

	go func() {
		io.Copy(a, b)
		done <- struct{}{}
	}()

	go func() {
		io.Copy(b, a)
		done <- struct{}{}
	}()

	// 一个方向结束后做半关闭，让另一个方向把剩余数据排完，避免截断尾部。
	<-done
	closeWrite(a)
	closeWrite(b)
	<-done

	a.Close()
	b.Close()
}

func closeWrite(conn net.Conn) {
	if tcp, ok := conn.(*net.TCPConn); ok {
		_ = tcp.CloseWrite()
		return
	}

	_ = conn.Close()
}

func greet(conn net.Conn) (room, role string, err error) {
	_ = conn.SetReadDeadline(time.Now().Add(10 * time.Second))

	reader := bufio.NewReader(conn)
	line, readErr := reader.ReadString('\n')
	if readErr != nil {
		return "", "", readErr
	}

	_ = conn.SetReadDeadline(time.Time{})

	fields := strings.Fields(strings.TrimSpace(line))
	if len(fields) != 3 || fields[0] != magic {
		conn.Write([]byte("ERR bad-handshake\n"))
		return "", "", errors.New("握手格式错误")
	}

	role = fields[1]
	room = NormalizeRoom(fields[2])

	if role != "send" && role != "recv" {
		conn.Write([]byte("ERR bad-role\n"))
		return "", "", errors.New("角色非法")
	}

	if len(room) < 4 {
		conn.Write([]byte("ERR bad-room\n"))
		return "", "", errors.New("房间码过短")
	}

	return room, role, nil
}

// NormalizeRoom 统一房间码格式：去连字符、转大写。
func NormalizeRoom(code string) string {
	code = strings.ToUpper(strings.TrimSpace(code))
	code = strings.ReplaceAll(code, "-", "")
	code = strings.ReplaceAll(code, " ", "")
	return code
}

// Pair 以指定角色连上中转并等待配对，返回一条已经连通的对端隧道。
func Pair(addr, room, role string) (net.Conn, error) {
	return PairWithin(addr, room, role, time.Now().Add(waitTimeout))
}

// PairWithin 在给定的绝对截止时间内部配对。
//
// 单独提供这个入口，是因为中转的「等对方出现」默认可以等 2 分钟：
// 如果调用方的总预算只有 100ms，内部再按 2 分钟等，就会让整条链路
// 的截止时间失效。超时后连接会被关闭，不会留在后台继续等。
func PairWithin(addr, room, role string, deadline time.Time) (net.Conn, error) {
	room = NormalizeRoom(room)
	if room == "" {
		return nil, errors.New("房间码不能为空")
	}

	dialTimeout := 10 * time.Second
	if remaining := time.Until(deadline); remaining < dialTimeout {
		dialTimeout = remaining
	}

	if dialTimeout <= 0 {
		return nil, errors.New("预算已耗尽，未尝试连接中转")
	}

	dialer := net.Dialer{Timeout: dialTimeout}

	conn, err := dialer.Dial("tcp", addr)
	if err != nil {
		return nil, fmt.Errorf("连接中转 %s 失败: %w", addr, err)
	}

	if _, err := fmt.Fprintf(conn, "%s %s %s\n", magic, role, room); err != nil {
		conn.Close()
		return nil, err
	}

	readDeadline := time.Now().Add(waitTimeout)
	if deadline.Before(readDeadline) {
		readDeadline = deadline
	}

	_ = conn.SetReadDeadline(readDeadline)

	reader := bufio.NewReader(conn)
	line, err := reader.ReadString('\n')
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("等待对方超时: %w", err)
	}

	_ = conn.SetReadDeadline(time.Time{})

	text := strings.TrimSpace(line)
	if text != "PAIRED" {
		conn.Close()
		return nil, fmt.Errorf("中转返回: %s", text)
	}

	// 配对成功后，对端可能已经开始发握手公钥，bufio 可能已把它读进缓冲区，
	// 必须把这部分字节接回连接前面，否则握手会读到半截数据。
	if buffered := reader.Buffered(); buffered > 0 {
		peeked, _ := reader.Peek(buffered)
		return &prefixedConn{
			Conn:   conn,
			reader: io.MultiReader(bytes.NewReader(append([]byte(nil), peeked...)), conn),
		}, nil
	}

	return conn, nil
}

type prefixedConn struct {
	net.Conn
	reader io.Reader
}

func (c *prefixedConn) Read(p []byte) (int, error) { return c.reader.Read(p) }
