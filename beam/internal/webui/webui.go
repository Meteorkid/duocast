// Package webui 提供一个本地网页界面：浏览器里接受/拒绝接收、看进度、按路径发送。
//
// 定位是「命令行内核 + 网页外壳」：所有传输仍然走同一套 relay + secure + proto，
// 网页只是把 accept 回调换成「等用户点按钮」，把发送动作换成「HTTP 触发」。
package webui

import (
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	"beam/internal/discover"
	"beam/internal/proto"
	"beam/internal/relay"
	"beam/internal/secure"
)

//go:embed index.html
var assets embed.FS

// Options 是网页模式的运行参数。
type Options struct {
	Listen    string // 网页监听地址
	Relay     string // 中转地址；留空则为离线直连模式
	Room      string // 中转房间码
	TCPListen string // 离线模式的 TCP 监听地址，如 :9001
	OutputDir string
}

type progress struct {
	Label  string `json:"label"`
	Done   int64  `json:"done"`
	Total  int64  `json:"total"`
	Active bool   `json:"active"`
}

type historyItem struct {
	Text string `json:"text"`
	OK   bool   `json:"ok"`
}

type state struct {
	Status   string        `json:"status"`
	SAS      string        `json:"sas"`
	Offer    *proto.Plan   `json:"offer"`
	Progress progress      `json:"progress"`
	History  []historyItem `json:"history"`
	Room     string        `json:"room"`
}

type engine struct {
	options Options

	transferMu sync.Mutex // 同一时刻只处理一路传输，避免两个 offer 互相覆盖

	mu       sync.Mutex
	status   string
	sas      string
	offer    *proto.Plan
	answer   chan bool
	progress progress
	history  []historyItem
	sending  bool
}

// Run 启动网页服务，并在后台维持「等待接收」的循环。
func Run(options Options) error {
	if options.OutputDir == "" {
		options.OutputDir = "."
	}

	relayMode := options.Relay != "" && options.Room != ""

	if !relayMode && options.TCPListen == "" {
		return errors.New("需要 --relay 与 --room（经中转），或 --tcp-listen（离线直连）")
	}

	engine := &engine{
		options: options,
		status:  "启动中…",
	}

	if relayMode {
		go engine.receiveLoopRelay()
	} else {
		go engine.receiveLoopDirect()
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", engine.handleIndex)
	mux.HandleFunc("/api/state", engine.handleState)
	mux.HandleFunc("/api/answer", engine.handleAnswer)
	mux.HandleFunc("/api/send", engine.handleSend)
	mux.HandleFunc("/api/peers", engine.handlePeers)
	mux.HandleFunc("/api/upload", engine.handleUpload)

	listener, err := net.Listen("tcp", options.Listen)
	if err != nil {
		return fmt.Errorf("监听 %s 失败: %w", options.Listen, err)
	}

	fmt.Printf("网页界面: http://%s\n", listener.Addr())

	if relayMode {
		fmt.Printf("接收房间: %s   保存到: %s\n", relay.NormalizeRoom(options.Room), options.OutputDir)
	} else {
		fmt.Printf("离线直连: 监听 %s   设备名 %s   保存到: %s\n",
			options.TCPListen, discover.LocalName(), options.OutputDir)
	}

	server := &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	return server.Serve(listener)
}

func (e *engine) receiveLoopRelay() {
	for {
		e.setStatus("等待对方连接…")

		conn, err := relay.Pair(e.options.Relay, e.options.Room, "recv")
		if err != nil {
			e.setStatus("配对失败: " + err.Error())
			time.Sleep(2 * time.Second)
			continue
		}

		// 握手与收流的公共逻辑都在 handleConn 里，这里只负责拿到配对好的连接。
		e.handleConn(conn)
	}
}

// receiveLoopDirect 是离线模式：直接监听 TCP，并广播自己的设备名，
// 对方执行 beam peers 或在本页的「附近设备」里就能看到。
func (e *engine) receiveLoopDirect() {
	e.setStatus("启动离线监听…")

	listener, err := net.Listen("tcp", e.options.TCPListen)
	if err != nil {
		e.setStatus("监听失败: " + err.Error())
		return
	}

	name := discover.LocalName()

	if tcpAddr, ok := listener.Addr().(*net.TCPAddr); ok {
		closer, err := discover.Serve(name, tcpAddr.Port, nil)
		if err != nil {
			e.setStatus("等待对方连接（UDP 广播不可用：端口 9100 可能被另一个 beam 实例占用；mDNS 仍在工作）")
		} else {
			defer closer.Close()
			e.setStatus(fmt.Sprintf("等待对方连接 · 设备名 %s · 端口 %d", name, tcpAddr.Port))
		}

		if mdnsCloser, mdnsErr := discover.RegisterMDNS(name, tcpAddr.Port); mdnsErr == nil {
			defer mdnsCloser.Close()
		}
	}

	for {
		conn, err := listener.Accept()
		if err != nil {
			e.setStatus("监听中断: " + err.Error())
			return
		}

		go e.handleConn(conn)
	}
}

func (e *engine) handleConn(conn net.Conn) {
	defer conn.Close()

	// 一次只处理一个连接：ask() 是单一状态，允许多路会互相覆盖 offer。
	e.transferMu.Lock()
	defer e.transferMu.Unlock()

	secured, err := secure.Handshake(conn)
	if err != nil {
		e.setStatus("加密握手失败: " + err.Error())
		return
	}

	e.setSAS(secured.SAS())
	e.setStatus("已连接，等待对方发来清单")

	transferred, err := proto.Receive(secured, e.options.OutputDir, nil, e.ask, e.updateProgress)
	e.finishProgress()

	if err != nil {
		e.pushHistory("接收失败: "+err.Error(), false)
		e.setStatus("接收失败: " + err.Error())
		return
	}

	// 能力探测也会走到这里，但它没传文件，不该记成一次接收。
	if !transferred {
		e.setStatus("完成一次能力探测，继续等待…")
		return
	}

	e.pushHistory("接收完成，已保存到 "+e.options.OutputDir, true)
	e.setStatus("接收完成，继续等待…")
}

// ask 是 proto.Receive 的接受回调：把清单挂到网页上，等用户点按钮。
func (e *engine) ask(plan proto.Plan) bool {
	answer := make(chan bool, 1)

	e.mu.Lock()
	e.offer = &plan
	e.answer = answer
	e.status = "收到传输请求，等待确认"
	e.mu.Unlock()

	defer func() {
		e.mu.Lock()
		e.offer = nil
		e.answer = nil
		e.mu.Unlock()
	}()

	select {
	case accept := <-answer:
		return accept
	case <-time.After(10 * time.Minute):
		e.pushHistory("等待确认超时，已拒绝", false)
		return false
	}
}

func (e *engine) updateProgress(done, total int64) {
	e.mu.Lock()
	defer e.mu.Unlock()

	e.progress.Done = done
	e.progress.Total = total
	e.progress.Active = true
	e.progress.Label = "接收中"
}

func (e *engine) finishProgress() {
	e.mu.Lock()
	defer e.mu.Unlock()

	e.progress.Active = false
	e.progress.Done = 0
	e.progress.Total = 0
	e.progress.Label = ""
}

func (e *engine) setStatus(text string) {
	e.mu.Lock()
	e.status = text
	e.mu.Unlock()
}

func (e *engine) setSAS(code string) {
	e.mu.Lock()
	e.sas = code
	e.mu.Unlock()
}

func (e *engine) pushHistory(text string, ok bool) {
	e.mu.Lock()
	defer e.mu.Unlock()

	e.history = append([]historyItem{{Text: text, OK: ok}}, e.history...)
	if len(e.history) > 20 {
		e.history = e.history[:20]
	}
}

func (e *engine) handleIndex(w http.ResponseWriter, r *http.Request) {
	page, err := assets.ReadFile("index.html")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(page)
}

func (e *engine) handleState(w http.ResponseWriter, r *http.Request) {
	e.mu.Lock()
	current := state{
		Status:   e.status,
		SAS:      e.sas,
		Offer:    e.offer,
		Progress: e.progress,
		History:  append([]historyItem(nil), e.history...),
		Room:     relay.NormalizeRoom(e.options.Room),
	}
	e.mu.Unlock()

	if current.History == nil {
		current.History = []historyItem{}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(current)
}

func (e *engine) handleAnswer(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var body struct {
		Accept bool `json:"accept"`
	}

	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}

	e.mu.Lock()
	answer := e.answer
	e.mu.Unlock()

	if answer == nil {
		http.Error(w, "当前没有待确认的传输", http.StatusConflict)
		return
	}

	select {
	case answer <- body.Accept:
	default:
	}

	w.WriteHeader(http.StatusNoContent)
}

func (e *engine) handlePeers(w http.ResponseWriter, r *http.Request) {
	peers := discover.DiscoverAll(1500 * time.Millisecond)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(peers)
}

// handleUpload 接收浏览器拖拽上传的文件，落到临时目录后再走正常发送流程。
//
// 为什么不直接把请求体当数据流发出去：那样必须同步阻塞在 HTTP 处理器里，
// 而且浏览器侧一旦重试就会和协议状态机打架。落一次临时文件换来的是
// 「上传与发送解耦」，代价是大文件会多一次磁盘往返——所以界面上保留了
// 按路径发送的入口，大文件走那条。
func (e *engine) handleUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	if err := r.ParseMultipartForm(8 << 20); err != nil {
		http.Error(w, "上传解析失败: "+err.Error(), http.StatusBadRequest)
		return
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		http.Error(w, "缺少文件", http.StatusBadRequest)
		return
	}
	defer file.Close()

	room := r.FormValue("room")
	peerName := r.FormValue("peer")
	addr := r.FormValue("addr")

	if room == "" && peerName == "" && addr == "" {
		http.Error(w, "需要目标设备或对方房间码", http.StatusBadRequest)
		return
	}

	e.mu.Lock()
	busy := e.sending
	e.mu.Unlock()

	if busy {
		http.Error(w, "已有发送任务在进行", http.StatusConflict)
		return
	}

	temp, err := os.CreateTemp("", "beam-upload-*")
	if err != nil {
		http.Error(w, "创建临时文件失败: "+err.Error(), http.StatusInternalServerError)
		return
	}

	tempPath := temp.Name()

	written, copyErr := io.Copy(temp, file)
	closeErr := temp.Close()

	if copyErr != nil || closeErr != nil {
		os.Remove(tempPath)
		http.Error(w, "写入临时文件失败", http.StatusInternalServerError)
		return
	}

	// 用浏览器给的原文件名，proto 会把 basename 作为对端看到的名字。
	// 手工拼路径有穿越风险，这里先取 basename 再 Join。
	name := filepath.Base(header.Filename)
	finalPath := filepath.Join(filepath.Dir(tempPath), name)
	if err := os.Rename(tempPath, finalPath); err != nil {
		os.Remove(tempPath)
		http.Error(w, "重命名临时文件失败", http.StatusInternalServerError)
		return
	}

	e.mu.Lock()
	e.sending = true
	e.mu.Unlock()

	go func() {
		defer os.Remove(finalPath)
		e.send(finalPath, room, peerName, addr)
	}()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"name": name, "size": written})
}

func (e *engine) handleSend(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var body struct {
		Path string `json:"path"`
		Room string `json:"room"`
		Peer string `json:"peer"`
		Addr string `json:"addr"`
	}

	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}

	if body.Path == "" {
		http.Error(w, "需要文件路径", http.StatusBadRequest)
		return
	}

	if body.Room == "" && body.Peer == "" && body.Addr == "" {
		http.Error(w, "需要目标设备（附近设备）或对方房间码", http.StatusBadRequest)
		return
	}

	info, err := os.Stat(body.Path)
	if err != nil || info.IsDir() {
		http.Error(w, "路径无效或不是文件", http.StatusBadRequest)
		return
	}

	e.mu.Lock()
	if e.sending {
		e.mu.Unlock()
		http.Error(w, "已有发送任务在进行", http.StatusConflict)
		return
	}
	e.sending = true
	e.mu.Unlock()

	go e.send(body.Path, body.Room, body.Peer, body.Addr)

	w.WriteHeader(http.StatusAccepted)
}

func (e *engine) send(path, room, peerName, addr string) {
	defer func() {
		e.mu.Lock()
		e.sending = false
		e.mu.Unlock()
	}()

	name := filepath.Base(path)

	var (
		conn net.Conn
		err  error
	)

	switch {
	case peerName != "":
		e.setStatus("正在查找设备 " + peerName + " …")

		peers := discover.DiscoverAll(1500 * time.Millisecond)

		found, ok := discover.Match(peers, peerName)
		if !ok {
			e.pushHistory("没有找到设备: "+peerName, false)
			e.setStatus("没有找到设备: " + peerName)
			return
		}

		e.setStatus("正在连接 " + found.Addr() + " …")
		conn, _, err = found.Dial(4 * time.Second)

	case addr != "":
		e.setStatus("正在连接 " + addr + " …")
		conn, err = net.DialTimeout("tcp", addr, 10*time.Second)

	default:
		e.setStatus("正在连接中转…")
		conn, err = relay.Pair(e.options.Relay, room, "send")
	}

	if err != nil {
		e.pushHistory("发送失败: "+err.Error(), false)
		e.setStatus("发送失败: " + err.Error())
		return
	}
	defer conn.Close()

	secured, err := secure.Handshake(conn)
	if err != nil {
		e.pushHistory("加密握手失败: "+err.Error(), false)
		e.setStatus("加密握手失败: " + err.Error())
		return
	}

	e.setSAS(secured.SAS())
	e.setStatus("已连接，等待对方确认")

	e.mu.Lock()
	e.progress = progress{Label: "发送 " + name, Active: true}
	e.mu.Unlock()

	_, err = proto.Send(secured, []string{path}, nil, func(done, total int64) {
		e.mu.Lock()
		e.progress.Done = done
		e.progress.Total = total
		e.progress.Active = true
		e.progress.Label = "发送 " + name
		e.mu.Unlock()
	})

	e.finishProgress()

	if err != nil {
		e.pushHistory("发送失败: "+err.Error(), false)
		e.setStatus("发送失败: " + err.Error())
		return
	}

	e.pushHistory("发送完成: "+name, true)
	e.setStatus("发送完成，继续等待…")
}
