// Package proto 定义传输协议：长度前缀的帧，控制消息用 JSON，文件内容用原始字节。
//
// 一次会话可以携带多个文件：
//
//	发送方 → Plan（文件清单 + 总字节数）
//	接收方 → Decide（整批接受或拒绝，只问一次）
//	每个文件：FileStart → Data... → End(sha256)
//	接收方 → Result(ok, sha256)
//	最后 → Complete
//
// 边传边算 SHA-256，接收端写完再比对，对不上就删掉临时文件。
package proto

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	typeMeta      byte = 1
	typeDecide    byte = 2
	typeFileStart byte = 3
	typeData      byte = 4
	typeEnd       byte = 5
	typeResult    byte = 6
	typeComplete  byte = 7

	chunkSize  = 256 * 1024
	maxControl = 4 << 20
)

// Meta 描述一个待传文件。
type Meta struct {
	Name  string `json:"name"`
	Size  int64  `json:"size"`
	Mode  uint32 `json:"mode"`
	MTime int64  `json:"mtime"`
}

// Caps 是能力声明：我是谁、我在哪个端口、我有哪些地址、我支持哪些链路。
//
// 之所以挂进现有的 Plan 而不是新增帧类型：JSON 解码会忽略未知字段，
// 因此旧版本接收端看到 caps 只会当没看见，不会报协议错乱——向前兼容。
type Caps struct {
	Name  string   `json:"name,omitempty"`
	Port  int      `json:"port,omitempty"`
	Addrs []string `json:"addrs,omitempty"`
	Kinds []string `json:"kinds,omitempty"`
}

// Plan 是一次传输的清单。
//
// Files 为空且 Caps 非空时，这个 Plan 是一次「能力交换 hello」，
// 接收方只回自己的 Caps，不进入传输流程。
type Plan struct {
	Files []Meta `json:"files"`
	Total int64  `json:"total"`
	Caps  *Caps  `json:"caps,omitempty"`
}

type decide struct {
	Accept bool   `json:"accept"`
	Reason string `json:"reason,omitempty"`
	Caps   *Caps  `json:"caps,omitempty"`
}

type fileStart struct {
	Name string `json:"name"`
}

type end struct {
	SHA256 string `json:"sha256"`
}

type result struct {
	OK     bool   `json:"ok"`
	SHA256 string `json:"sha256"`
	Reason string `json:"reason,omitempty"`
}

type complete struct{}

// Progress 汇报整体进度（按字节）。
type Progress func(sent, total int64)

// Send 发送一批文件。progress 可为 nil。返回值是对端在 decide 里附带的能力声明（可能为 nil）。
func Send(rw io.ReadWriter, files []string, caps *Caps, progress Progress) (*Caps, error) {
	if len(files) == 0 {
		return nil, errors.New("没有要发送的文件")
	}

	plan := Plan{}
	sources := make([]source, 0, len(files))

	for _, path := range files {
		collected, err := collectSource(path)
		if err != nil {
			return nil, err
		}

		for _, item := range collected {
			sources = append(sources, item)
			plan.Files = append(plan.Files, item.Meta)
			plan.Total += item.Meta.Size
		}
	}

	if len(sources) == 0 {
		return nil, errors.New("没有可发送的文件")
	}

	plan.Caps = caps

	if err := writeJSON(rw, typeMeta, plan); err != nil {
		return nil, err
	}

	var answer decide
	if err := readJSON(rw, typeDecide, &answer); err != nil {
		return nil, err
	}

	if !answer.Accept {
		reason := answer.Reason
		if reason == "" {
			reason = "对方拒绝接收"
		}

		return answer.Caps, errors.New(reason)
	}

	var sent int64

	for index, meta := range plan.Files {
		if err := sendOne(rw, sources[index].AbsPath, meta, &sent, plan.Total, progress); err != nil {
			return answer.Caps, err
		}
	}

	return answer.Caps, writeJSON(rw, typeComplete, complete{})
}

// source 是一条待发送记录：磁盘上的绝对路径 + 对端看到的相对名字。
type source struct {
	AbsPath string
	Meta    Meta
}

// maxFiles 是一次传输的文件数量上限，防止误传整个家目录。
const maxFiles = 10000

// collectSource 把命令行给的一个路径展开成待发送列表。
//
// 文件 → 一条，名字取 basename；目录 → 递归展开，名字保留相对路径
// （如 photos/2026/a.jpg），接收端据此还原目录结构。
func collectSource(path string) ([]source, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("读取 %s 失败: %w", path, err)
	}

	if !info.IsDir() {
		return []source{{
			AbsPath: path,
			Meta: Meta{
				Name:  filepath.Base(path),
				Size:  info.Size(),
				Mode:  uint32(info.Mode().Perm()),
				MTime: info.ModTime().Unix(),
			},
		}}, nil
	}

	root := filepath.Base(filepath.Clean(path))
	items := make([]source, 0, 16)

	err = filepath.Walk(path, func(current string, entry os.FileInfo, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}

		if entry.IsDir() {
			return nil
		}

		// 跳过上次中断留下的临时文件，否则会把半截数据也传过去。
		if strings.HasSuffix(entry.Name(), ".beam-part") {
			return nil
		}

		if !entry.Mode().IsRegular() {
			return nil
		}

		rel, err := filepath.Rel(path, current)
		if err != nil {
			return err
		}

		if len(items) >= maxFiles {
			return fmt.Errorf("文件数量超过上限 %d，请分批发", maxFiles)
		}

		items = append(items, source{
			AbsPath: current,
			Meta: Meta{
				Name:  filepath.ToSlash(filepath.Join(root, rel)),
				Size:  entry.Size(),
				Mode:  uint32(entry.Mode().Perm()),
				MTime: entry.ModTime().Unix(),
			},
		})

		return nil
	})
	if err != nil {
		return nil, err
	}

	return items, nil
}

// ErrCapsRejected 表示对端明确拒绝了能力交换（通常是不支持该扩展的旧版本）。
// 这种失败不破坏连接，调用方可以继续用它传文件；而超时/协议错误则必须终止。
var ErrCapsRejected = errors.New("对端未接受能力交换")

// Hello 在正式传输前交换一次能力声明。
//
// 发一个「不含文件、只带 caps」的 Plan，对方回 decide（带自己的 caps）。
// 对端若是不支持该扩展的旧版本，会把它当空传输拒绝——调用方应容忍这种失败，
// 退回纯本地候选逻辑即可。
func Hello(rw io.ReadWriter, caps *Caps) (*Caps, error) {
	if err := writeJSON(rw, typeMeta, Plan{Caps: caps}); err != nil {
		return nil, err
	}

	var answer decide
	if err := readJSON(rw, typeDecide, &answer); err != nil {
		return nil, err
	}

	if !answer.Accept {
		return nil, ErrCapsRejected
	}

	return answer.Caps, nil
}

// Receive 接收一批文件到 dir。accept 返回 false 时整批拒绝。
func Receive(rw io.ReadWriter, dir string, caps *Caps, accept func(Plan) bool, progress Progress) (bool, error) {
	var plan Plan
	if err := readJSON(rw, typeMeta, &plan); err != nil {
		return false, err
	}

	// 空清单 = 能力交换 hello：回自己的 caps 后**继续等真正的 Plan**。
	// 早期版本在这里直接 return，导致发送方紧接着在同一个连接上发文件时报 EOF。
	for len(plan.Files) == 0 {
		if plan.Caps == nil {
			return false, errors.New("对方没有发送任何文件")
		}

		if err := writeJSON(rw, typeDecide, decide{Accept: true, Caps: caps}); err != nil {
			return false, err
		}

		next, err := readNextPlan(rw)
		if err != nil {
			// hello 之后对端直接断开，说明它只是来探测可达性的，不是要传文件。
			// 这属于正常结束，不能记成错误（否则每次探测都会在接收端留下一条假告警）。
			return false, nil
		}

		plan = next
	}

	if !accept(plan) {
		_ = writeJSON(rw, typeDecide, decide{Accept: false, Reason: "已拒绝", Caps: caps})
		return false, errors.New("已拒绝本次传输")
	}

	if err := writeJSON(rw, typeDecide, decide{Accept: true, Caps: caps}); err != nil {
		return false, err
	}

	var received int64

	for _, meta := range plan.Files {
		var start fileStart
		if err := readJSON(rw, typeFileStart, &start); err != nil {
			return false, err
		}

		if err := receiveOne(rw, dir, meta, &received, plan.Total, progress); err != nil {
			return false, err
		}
	}

	var done complete
	if err := readJSON(rw, typeComplete, &done); err != nil {
		return false, err
	}

	return true, nil
}

func sendOne(rw io.ReadWriter, path string, meta Meta, sent *int64, total int64, progress Progress) error {
	file, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("打开 %s 失败: %w", path, err)
	}
	defer file.Close()

	if err := writeJSON(rw, typeFileStart, fileStart{Name: meta.Name}); err != nil {
		return err
	}

	hash := sha256.New()
	buffer := make([]byte, chunkSize)

	for {
		n, readErr := file.Read(buffer)
		if n > 0 {
			if err := writeFrame(rw, typeData, buffer[:n]); err != nil {
				return err
			}

			hash.Write(buffer[:n])
			*sent += int64(n)

			if progress != nil {
				progress(*sent, total)
			}
		}

		if readErr == io.EOF {
			break
		}

		if readErr != nil {
			return fmt.Errorf("读取 %s 失败: %w", path, readErr)
		}
	}

	if err := writeJSON(rw, typeEnd, end{SHA256: hex.EncodeToString(hash.Sum(nil))}); err != nil {
		return err
	}

	var answer result
	if err := readJSON(rw, typeResult, &answer); err != nil {
		return err
	}

	if !answer.OK {
		reason := answer.Reason
		if reason == "" {
			reason = "校验失败"
		}

		return fmt.Errorf("%s 传输失败: %s", meta.Name, reason)
	}

	return nil
}

// safeRelPath 校验对端给出的相对路径，防止目录穿越。
//
// 允许 "photos/2026/a.jpg" 这样的相对子路径（目录传输需要），
// 但拒绝绝对路径、盘符、以及任何形式的 ".."。
func safeRelPath(raw string) (string, error) {
	cleaned := filepath.Clean(filepath.FromSlash(raw))

	if cleaned == "" || cleaned == "." {
		return "", errors.New("对方给出的文件名非法")
	}

	if filepath.IsAbs(cleaned) || filepath.VolumeName(cleaned) != "" {
		return "", errors.New("对方给出的路径是绝对路径，已拒绝")
	}

	for _, part := range strings.Split(cleaned, string(filepath.Separator)) {
		if part == ".." {
			return "", errors.New("对方给出的路径包含 ..，已拒绝")
		}
	}

	return cleaned, nil
}

func receiveOne(rw io.ReadWriter, dir string, meta Meta, received *int64, total int64, progress Progress) error {
	name, err := safeRelPath(meta.Name)
	if err != nil {
		return err
	}

	target := filepath.Join(dir, name)

	// 目录传输时目标可能在子目录里，必须先建好父目录。
	if parent := filepath.Dir(target); parent != "" {
		if err := os.MkdirAll(parent, 0o755); err != nil {
			return fmt.Errorf("创建目录失败: %w", err)
		}
	}
	partial := target + ".beam-part"

	file, err := os.OpenFile(partial, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, (os.FileMode(meta.Mode)&0o777)|0o600)
	if err != nil {
		return fmt.Errorf("创建 %s 失败: %w", partial, err)
	}

	hash := sha256.New()
	var written int64

	for written < meta.Size {
		kind, payload, err := readFrame(rw)
		if err != nil {
			file.Close()
			os.Remove(partial)
			return err
		}

		if kind != typeData {
			file.Close()
			os.Remove(partial)
			return fmt.Errorf("协议错乱：期望数据帧，收到类型 %d", kind)
		}

		if written+int64(len(payload)) > meta.Size {
			file.Close()
			os.Remove(partial)
			return errors.New("数据超出声明的大小")
		}

		if _, err := file.Write(payload); err != nil {
			file.Close()
			os.Remove(partial)
			return fmt.Errorf("写入失败: %w", err)
		}

		hash.Write(payload)
		written += int64(len(payload))
		*received += int64(len(payload))

		if progress != nil {
			progress(*received, total)
		}
	}

	var trailer end
	if err := readJSON(rw, typeEnd, &trailer); err != nil {
		file.Close()
		os.Remove(partial)
		return err
	}

	if err := file.Close(); err != nil {
		os.Remove(partial)
		return err
	}

	sum := hex.EncodeToString(hash.Sum(nil))
	if sum != trailer.SHA256 {
		os.Remove(partial)
		_ = writeJSON(rw, typeResult, result{OK: false, SHA256: sum, Reason: "SHA-256 不一致"})
		return fmt.Errorf("%s 校验失败：收到的内容与对方声明的不一致", name)
	}

	if err := os.Rename(partial, target); err != nil {
		os.Remove(partial)
		_ = writeJSON(rw, typeResult, result{OK: false, SHA256: sum, Reason: "落盘失败"})
		return fmt.Errorf("保存 %s 失败: %w", target, err)
	}

	if meta.MTime > 0 {
		when := time.Unix(meta.MTime, 0)
		_ = os.Chtimes(target, when, when)
	}

	return writeJSON(rw, typeResult, result{OK: true, SHA256: sum})
}

// readNextPlan 读取下一帧并断言它是 Plan，用于 hello 之后继续等正式清单。
func readNextPlan(r io.Reader) (Plan, error) {
	var plan Plan
	if err := readJSON(r, typeMeta, &plan); err != nil {
		return Plan{}, err
	}

	return plan, nil
}

func writeFrame(w io.Writer, kind byte, payload []byte) error {
	header := make([]byte, 5)
	header[0] = kind
	binary.BigEndian.PutUint32(header[1:], uint32(len(payload)))

	if _, err := w.Write(header); err != nil {
		return err
	}

	if len(payload) > 0 {
		if _, err := w.Write(payload); err != nil {
			return err
		}
	}

	return nil
}

func readFrame(r io.Reader) (byte, []byte, error) {
	var header [5]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return 0, nil, err
	}

	size := binary.BigEndian.Uint32(header[1:])
	if size > maxControl {
		return 0, nil, fmt.Errorf("帧过大: %d 字节", size)
	}

	payload := make([]byte, size)
	if size > 0 {
		if _, err := io.ReadFull(r, payload); err != nil {
			return 0, nil, err
		}
	}

	return header[0], payload, nil
}

func writeJSON(w io.Writer, kind byte, value any) error {
	payload, err := json.Marshal(value)
	if err != nil {
		return err
	}

	return writeFrame(w, kind, payload)
}

func readJSON(r io.Reader, kind byte, value any) error {
	got, payload, err := readFrame(r)
	if err != nil {
		return err
	}

	if got != kind {
		return fmt.Errorf("协议错乱：期望类型 %d，收到 %d", kind, got)
	}

	return json.Unmarshal(payload, value)
}
