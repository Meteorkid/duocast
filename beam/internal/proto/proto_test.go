package proto

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestHelloExchange 验证「空 Plan = 能力交换」这条路径：
// 发送方拿到对端 caps，接收方把 hello 当正常结束而不报「没有发送任何文件」。
func TestHelloExchange(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	mine := &Caps{Name: "sender", Port: 0, Addrs: []string{"10.0.0.1"}, Kinds: []string{"direct"}}
	theirs := &Caps{Name: "receiver", Port: 9001, Addrs: []string{"10.0.0.2"}, Kinds: []string{"discovered", "direct"}}

	dir := t.TempDir()
	done := make(chan error, 1)

	go func() {
		_, err := Receive(server, dir, theirs, func(Plan) bool { return true }, nil)
		done <- err
	}()

	got, err := Hello(client, mine)
	if err != nil {
		t.Fatalf("能力交换失败: %v", err)
	}

	if got == nil || got.Name != "receiver" || got.Port != 9001 {
		t.Fatalf("对端能力不对: %+v", got)
	}

	if len(got.Addrs) != 1 || got.Addrs[0] != "10.0.0.2" {
		t.Fatalf("对端地址不对: %v", got.Addrs)
	}

	// hello 之后必须在同一个连接上继续传文件——这正是之前踩过的坑。
	source := filepath.Join(t.TempDir(), "hello.txt")
	if err := os.WriteFile(source, []byte("after hello"), 0o644); err != nil {
		t.Fatal(err)
	}

	sentCaps, err := Send(client, []string{source}, mine, nil)
	if err != nil {
		t.Fatalf("hello 之后继续传输失败: %v", err)
	}

	if sentCaps == nil || sentCaps.Name != "receiver" {
		t.Fatalf("正式传输的 decide 也应带 caps: %+v", sentCaps)
	}

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("接收端应正常结束: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("接收端未结束")
	}

	if _, err := os.Stat(filepath.Join(dir, "hello.txt")); err != nil {
		t.Fatalf("文件未落盘: %v", err)
	}
}

// TestHelloRejectsEmptyPlanWithoutCaps 保证「空清单且无 caps」仍然被当作错误，
// 不会被误认为合法的 hello。
func TestHelloRejectsEmptyPlanWithoutCaps(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	done := make(chan error, 1)

	go func() {
		_, err := Receive(server, t.TempDir(), nil, func(Plan) bool { return true }, nil)
		done <- err
	}()

	if err := writeJSON(client, typeMeta, Plan{}); err != nil {
		t.Fatalf("写入失败: %v", err)
	}

	select {
	case err := <-done:
		if err == nil {
			t.Fatal("空清单且无 caps 应报错")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("接收端未退出")
	}
}

// TestSafeRelPath 覆盖目录穿越的各种写法。
func TestSafeRelPath(t *testing.T) {
	good := map[string]string{
		"a.txt":                "a.txt",
		"photos/2026/a.jpg":    "photos/2026/a.jpg",
		"dir/sub/../other.txt": "dir/other.txt", // Clean 后不含 ..，允许
	}

	for input, want := range good {
		got, err := safeRelPath(input)
		if err != nil {
			t.Fatalf("%q 应被接受，实际报错: %v", input, err)
		}

		if got != want {
			t.Fatalf("%q 期望 %q，实际 %q", input, want, got)
		}
	}

	bad := []string{"", ".", "../etc/passwd", "a/../../b", "/etc/passwd", ".."}

	for _, input := range bad {
		if _, err := safeRelPath(input); err == nil {
			t.Fatalf("%q 应被拒绝", input)
		}
	}
}

// TestDirectoryTransfer 验证目录递归发送后，接收端能还原同样的结构。
func TestDirectoryTransfer(t *testing.T) {
	srcRoot := t.TempDir()
	files := map[string]string{
		"sub/a.txt":      "alpha",
		"sub/deep/b.txt": "bravo",
		"top.txt":        "charlie",
	}

	for rel, content := range files {
		full := filepath.Join(srcRoot, rel)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	dstRoot := t.TempDir()
	done := make(chan error, 1)

	go func() {
		_, err := Receive(server, dstRoot, nil, func(Plan) bool { return true }, nil)
		done <- err
	}()

	if _, err := Send(client, []string{srcRoot}, nil, nil); err != nil {
		t.Fatalf("发送目录失败: %v", err)
	}

	if err := <-done; err != nil {
		t.Fatalf("接收失败: %v", err)
	}

	// 目录名取自源目录的 basename，结构应整体还原。
	base := filepath.Base(srcRoot)

	for rel, want := range files {
		path := filepath.Join(dstRoot, base, rel)
		got, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("缺少文件 %s: %v", path, err)
		}

		if string(got) != want {
			t.Fatalf("%s 内容不符：%q != %q", path, got, want)
		}
	}
}

// TestHelloReturnsRejectedSentinel 明确拒绝与「超时/协议错误」必须可区分：
// 前者连接仍可用，后者必须终止会话。
func TestHelloReturnsRejectedSentinel(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	go func() {
		var plan Plan
		_ = readJSON(server, typeMeta, &plan)
		_ = writeJSON(server, typeDecide, decide{Accept: false, Reason: "not supported"})
	}()

	_, err := Hello(client, &Caps{Name: "tester"})
	if !errors.Is(err, ErrCapsRejected) {
		t.Fatalf("应返回 ErrCapsRejected，实际 %v", err)
	}
}
