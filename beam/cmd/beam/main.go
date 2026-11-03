// Command beam 在 Mac 与 Windows 之间传文件。
//
// 三种模式：
//
//	beam relay --listen :9000                在一台公网可达的机器上跑中转
//	beam send  <文件...> --relay host:9000   发送（房间码会自动生成并打印）
//	beam recv  --relay host:9000 --room CODE 接收
//
// 同一局域网也可以跳过中转，直接点对点：
//
//	beam recv --listen :9001
//	beam send file.bin --to 192.168.1.8:9001
package main

import (
	"crypto/rand"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"strings"
	"time"

	"beam/internal/discover"
	"beam/internal/link"
	"beam/internal/proto"
	"beam/internal/relay"
	"beam/internal/secure"
	"beam/internal/session"
	"beam/internal/webui"
)

const version = "0.1.0"

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	switch os.Args[1] {
	case "relay":
		runRelay(os.Args[2:])
	case "send":
		runSend(os.Args[2:])
	case "recv":
		runRecv(os.Args[2:])
	case "ui":
		runUI(os.Args[2:])
	case "peers":
		runPeers(os.Args[2:])
	case "bench":
		runBench(os.Args[2:])
	case "version", "-v", "--version":
		fmt.Printf("beam %s\n", version)
	case "help", "-h", "--help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "未知子命令: %s\n\n", os.Args[1])
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Print(`beam — 跨平台快速传文件（Mac ⇄ Windows）

用法:
  beam relay --listen :9000
        在一台双方都能连上的机器上启动中转（公网 VPS 或家里常开的机器）。

  beam send <文件...> --relay host:9000 [--room CODE]
        发送。省略 --room 会自动生成房间码并打印，把它告诉对方。

  beam recv --relay host:9000 --room CODE [--out 目录]
        接收。会先列出文件清单，确认后才开始。

  beam ui --relay host:9000 --room CODE [--listen 127.0.0.1:8080]
  beam ui --tcp-listen :9001 [--listen 127.0.0.1:8080]
        本地网页界面：浏览器里接受/拒绝、看进度、按路径发送。
        省略 --relay/--room 即为离线直连模式。

  beam send <文件...> --to 192.168.1.8:9001
  beam recv --listen :9001 [--out 目录]
        同一局域网直连，不经过中转。

  beam peers
        广播查找同一网段内正在等待接收的设备（网线直连时用这个）。

  beam bench --to <地址>|--peer <名字> [--size 100] [--runs 3] [--label wifi5g]
        基准测试：把一次传输拆成「发现 / 建链 / 传输」三段计时，结果追加到 CSV。
        接收端用 beam recv --yes 即可，不需要额外服务。

  beam send <文件...> --peer MacBook
        按设备名发送，不必知道对方 IP。

参数:
  --yes    接收时不询问，直接接受（脚本用）
  --once   接收一次后退出（脚本用）

安全:
  两端之间用 X25519 协商密钥、AES-256-GCM 加密，中转只转发密文。
  连上后两端各显示一个验证码，两边一致说明没有中间人。
`)
}

func runRelay(args []string) {
	fs := flag.NewFlagSet("relay", flag.ExitOnError)
	listen := fs.String("listen", ":9000", "监听地址")
	fs.Parse(args)

	logf := func(format string, values ...any) {
		fmt.Printf(format+"\n", values...)
	}

	if err := relay.Serve(*listen, logf); err != nil {
		fatal(err)
	}
}

func runSend(args []string) {
	fs := flag.NewFlagSet("send", flag.ExitOnError)
	relayAddr := fs.String("relay", "", "中转地址 host:port")
	target := fs.String("to", "", "直连目标 host:port")
	peerName := fs.String("peer", "", "自动发现的设备名（同一广播域，无需知道 IP）")
	room := fs.String("room", "", "房间码（经中转时使用）")
	tracePath := fs.String("trace", "", "把本轮链路协商记录写成 JSON（供分析用）")
	useCaps := fs.Bool("caps", false, "传输前与对端交换能力声明（要求两端均为新版本）")

	flagArgs, files := splitFlags(args, fs)
	fs.Parse(flagArgs)

	if len(files) == 0 {
		fatal(errors.New("用法: beam send <文件...> --relay host:9000 或 --to host:9001"))
	}

	candidates := buildCandidates(*target, *peerName, *relayAddr, *room)

	if len(candidates) == 0 {
		fatal(errors.New("需要 --peer（自动发现）、--to（直连地址）或 --relay（跨网络）"))
	}

	fmt.Printf("候选链路 %d 条，按成本依次尝试：\n", len(candidates))

	myCaps := &proto.Caps{
		Name:  discover.LocalName(),
		Addrs: discover.LocalIPv4(),
		Kinds: []string{string(link.KindDirect), string(link.KindRelay)},
	}

	options := session.Options{
		AllowUpgrade: *useCaps,
		Timeout:      4 * time.Second,
		Logf: func(attempt link.Attempt) {
			if attempt.OK {
				fmt.Printf("  ✓ %-10s %-24s %6.0f ms\n", attempt.Kind, attempt.Label, attempt.MS)
				return
			}

			fmt.Printf("  ✗ %-10s %-24s %6.0f ms  %s\n", attempt.Kind, attempt.Label, attempt.MS, attempt.Error)
		},
	}

	if *useCaps {
		options.Caps = myCaps
	}

	result, err := session.Establish(candidates, options)

	if *tracePath != "" {
		if traceErr := writeTrace(*tracePath, result); traceErr != nil {
			fmt.Fprintf(os.Stderr, "写入协商记录失败: %v\n", traceErr)
		}
	}

	if err != nil {
		fatal(err)
	}

	conn := result.Conn
	defer conn.Close()

	if result.FinalKind == link.KindRelay && !result.Upgraded {
		fmt.Println("  注意：当前走中转，非直连。")
	}

	// 建链返回的已经是加密连接，这里只取验证码用于人工核对。
	if secured, ok := conn.(*secure.Conn); ok {
		fmt.Printf("已连接对端，验证码 %s（应与对方显示一致）\n", secured.SAS())
	}

	if result.CapsErr != "" {
		fmt.Fprintf(os.Stderr, "能力交换失败（对端可能不支持该扩展），已跳过: %s\n", result.CapsErr)
	}

	if result.PeerCaps != nil {
		reportPeerCaps(result.PeerCaps, result, myCaps)
	}

	if result.Upgraded {
		fmt.Printf("已升级到直连 %s，关闭中转连接\n", result.FinalLabel)
	}

	progress := newProgress()
	if _, err := proto.Send(conn, files, myCaps, progress.update); err != nil {
		fmt.Fprintln(os.Stderr)
		fatal(err)
	}

	progress.finish()
	fmt.Println("传输完成，对端已校验通过。")
}

// reportPeerCaps 汇总对端声明，并探测其中哪些地址当前真的可达。
//
// 这一步是「候选列表由双方共同得出」的雏形：本地看到的地址是猜测，
// 对端自报的地址是事实，再叠加一次真实拨号验证才算数。
// 升级逻辑已移到 internal/session，这里只负责展示与验证。
// reportPeerCaps 只展示对端声明的能力，**不做任何网络探测**。
//
// 早期版本在这里逐个地址联网验证可达性，导致「显示」函数偷偷改变了网络时序，
// 也让 bench 与 send 的行为不一致。可达性由 session 在升级阶段统一验证，
// 这里不再重复。
func reportPeerCaps(peer *proto.Caps, established session.Result, myCaps *proto.Caps) {
	if peer == nil {
		fmt.Println("对端未返回能力声明")
		return
	}

	fmt.Printf("对端能力：%s（%d 个地址，端口 %d）\n", strings.Join(peer.Kinds, "/"), len(peer.Addrs), peer.Port)

	switch {
	case established.Upgraded:
		// 升级成功时最终链路已通过实际连接验证。
	case established.UpgradeError != "":
		fmt.Printf("  未升级：%s\n", established.UpgradeError)
	case established.FinalKind == link.KindRelay:
		fmt.Println("  当前走中转；对端声明了直连地址，但本轮未尝试升级")
	}
}

func runPeers(args []string) {
	fs := flag.NewFlagSet("peers", flag.ExitOnError)
	timeout := fs.Duration("timeout", 2*time.Second, "查找时长")

	flagArgs, _ := splitFlags(args, fs)
	fs.Parse(flagArgs)

	fmt.Println("正在查找（UDP 广播 + mDNS）…")

	peers := discover.DiscoverAll(*timeout)

	if len(peers) == 0 {
		fmt.Println("没有发现设备。")
	} else {
		fmt.Printf("发现 %d 台设备：\n", len(peers))
		for _, peer := range peers {
			fmt.Printf("  %-24s %-22s %s（%d 个候选地址）\n", peer.Name, peer.Addr(), sourceLabel(peer.Source), len(peer.Addrs))
		}
	}

	fmt.Println("\n本机地址：")
	for _, addr := range discover.LocalAddresses() {
		fmt.Println("  " + addr)
	}

	if len(peers) == 0 {
		fmt.Println("\n排查顺序：")
		fmt.Println("  1. 对方是否已运行 beam recv --listen :9001")
		fmt.Println("  2. 网线直连时，两端是否各自拿到了 169.254.x.x 地址")
		fmt.Println("  3. Windows 首次运行是否在防火墙提示里允许了访问")
	}
}

func sourceLabel(source string) string {
	switch source {
	case discover.SourceBoth:
		return "广播+mDNS"
	case discover.SourceMDNS:
		return "mDNS"
	case discover.SourceBroadcast:
		return "广播"
	default:
		return source
	}
}

func runUI(args []string) {
	fs := flag.NewFlagSet("ui", flag.ExitOnError)
	listen := fs.String("listen", "127.0.0.1:8080", "网页监听地址")
	relayAddr := fs.String("relay", "", "中转地址 host:port")
	room := fs.String("room", "", "本机接收房间码（中转模式）")
	tcpListen := fs.String("tcp-listen", ":9001", "离线直连模式的 TCP 监听地址")
	out := fs.String("out", ".", "保存目录")

	flagArgs, _ := splitFlags(args, fs)
	fs.Parse(flagArgs)

	options := webui.Options{
		Listen:    *listen,
		Relay:     *relayAddr,
		Room:      *room,
		TCPListen: *tcpListen,
		OutputDir: *out,
	}

	if err := webui.Run(options); err != nil {
		fatal(err)
	}
}

// buildCandidates 把命令行给的三种目标形式，统一成本次可尝试的候选链路。
//
// 顺序不重要（DialAll 会按成本重排），但「有没有候选」很重要：
// 如果一个都构造不出来，说明参数不足，应该直接报错而不是空跑。
func buildCandidates(target, peerName, relayAddr, room string) []link.Candidate {
	var candidates []link.Candidate

	if peerName != "" {
		peers := discover.DiscoverAll(2 * time.Second)

		if found, ok := discover.Match(peers, peerName); ok {
			fmt.Printf("发现 %s（%d 个候选地址）\n", found.Name, len(found.Addrs))
			for _, addr := range found.Addrs {
				candidates = append(candidates, link.NewTCPCandidate(link.KindDiscovered, addr))
			}
		} else {
			fmt.Fprintf(os.Stderr, "未发现设备 %s，继续尝试其他链路\n", peerName)
		}
	}

	if target != "" {
		candidates = append(candidates, link.NewTCPCandidate(link.KindDirect, target))
	}

	if relayAddr != "" {
		code := room

		if code == "" {
			// 只有「仅给了中转」时才自动生成房间码并打印邀请；
			// 否则会让用户困惑——明明有直连地址，却提示一个房间码。
			if len(candidates) == 0 {
				code = randomRoom()
				fmt.Printf("房间码：%s\n", code)
				fmt.Printf("让对方执行：beam recv --relay %s --room %s\n\n", relayAddr, code)
			} else {
				fmt.Fprintln(os.Stderr, "提示：未指定 --room，跳过中转候选")
			}
		}

		if code != "" {
			candidates = append(candidates, link.NewRelayCandidate(relayAddr, code, func(address, roomCode string, deadline time.Time) (net.Conn, error) {
				return relay.PairWithin(address, roomCode, "send", deadline)
			}))
		}
	}

	return candidates
}

// sessionTrace 是一次建链的完整可序列化记录。
//
// 早期只写 link.Result，缺最终路径、升级明细和能力交换错误，
// 事后无法判断「到底走成了哪条链路、升级失败在哪一步」。
type sessionTrace struct {
	LinkTotalMS     float64        `json:"link_total_ms"`
	NegotiateMS     float64        `json:"negotiate_ms"`
	CapsError       string         `json:"caps_error,omitempty"`
	Upgraded        bool           `json:"upgraded"`
	UpgradeError    string         `json:"upgrade_error,omitempty"`
	FinalKind       string         `json:"final_kind"`
	FinalLabel      string         `json:"final_label"`
	PeerCaps        *proto.Caps    `json:"peer_caps,omitempty"`
	Attempts        []link.Attempt `json:"attempts"`
	UpgradeAttempts []link.Attempt `json:"upgrade_attempts,omitempty"`
}

// writeTrace 把建链过程落盘，供测量分析（哪条链路先成功、失败与升级各在哪一步）。
func writeTrace(path string, result session.Result) error {
	trace := sessionTrace{
		LinkTotalMS:     result.Link.TotalMS,
		NegotiateMS:     result.NegotiateMS,
		CapsError:       result.CapsErr,
		Upgraded:        result.Upgraded,
		UpgradeError:    result.UpgradeError,
		FinalKind:       string(result.FinalKind),
		FinalLabel:      result.FinalLabel,
		PeerCaps:        result.PeerCaps,
		Attempts:        result.Link.Attempts,
		UpgradeAttempts: result.UpgradeAttempts,
	}

	payload, err := json.MarshalIndent(trace, "", "  ")
	if err != nil {
		return err
	}

	return os.WriteFile(path, payload, 0o644)
}

func runRecv(args []string) {
	fs := flag.NewFlagSet("recv", flag.ExitOnError)
	relayAddr := fs.String("relay", "", "中转地址 host:port")
	room := fs.String("room", "", "房间码")
	listen := fs.String("listen", "", "直连监听地址，如 :9001")
	out := fs.String("out", ".", "保存目录")
	autoYes := fs.Bool("yes", false, "不询问直接接收")
	once := fs.Bool("once", false, "接收一次后退出")
	noDiscover := fs.Bool("no-discover", false, "关闭自动发现")

	flagArgs, _ := splitFlags(args, fs)
	fs.Parse(flagArgs)

	// 监听端口要在闭包之前声明：闭包里要用它填能力声明。
	listenPort := 0

	accept := func(plan proto.Plan) bool {
		printPlan(plan)
		if *autoYes {
			return true
		}

		return askYesNo("接受？[y/N] ")
	}

	handle := func(conn net.Conn) (bool, error) {
		defer conn.Close()

		// 打印对端地址：跨 NAT 时这里能看到源地址被改写，是排查可达性问题的第一手证据。
		fmt.Printf("来自 %s 的连接\n", conn.RemoteAddr())

		secured, err := secure.Handshake(conn)
		if err != nil {
			return false, fmt.Errorf("加密握手失败: %w", err)
		}

		fmt.Printf("已连接对端，验证码 %s（应与对方显示一致）\n", secured.SAS())

		progress := newProgress()

		myCaps := &proto.Caps{
			Name:  discover.LocalName(),
			Port:  listenPort,
			Addrs: discover.LocalIPv4(),
			Kinds: []string{string(link.KindDiscovered), string(link.KindDirect)},
		}

		transferred, err := proto.Receive(secured, *out, myCaps, accept, progress.update)
		if err != nil {
			progress.abort()
			return false, err
		}

		if !transferred {
			return false, nil
		}

		progress.finish()
		return true, nil
	}

	if *listen != "" {
		listener, err := net.Listen("tcp", *listen)
		if err != nil {
			fatal(fmt.Errorf("监听失败: %w", err))
		}

		fmt.Printf("直连监听 %s，等待对方发起…\n", listener.Addr())

		// 能力声明里要报端口，对方才能拿着这个端口尝试直连。
		if tcpAddr, ok := listener.Addr().(*net.TCPAddr); ok {
			listenPort = tcpAddr.Port
		}

		// 把本机地址直接打出来：对方用 --to 时需要，省得再去系统设置里翻。
		if addresses := discover.LocalAddresses(); len(addresses) > 0 {
			fmt.Println("本机地址（对方可 --to 直接指定）：")
			for _, address := range addresses {
				fmt.Println("  " + address)
			}
		}

		if !*noDiscover {
			if tcpAddr, ok := listener.Addr().(*net.TCPAddr); ok {
				name := discover.LocalName()
				closer, err := discover.Serve(name, tcpAddr.Port, nil)
				mdnsCloser, mdnsErr := discover.RegisterMDNS(name, tcpAddr.Port)
				if mdnsErr == nil {
					defer mdnsCloser.Close()
				}

				if err != nil {
					fmt.Fprintf(os.Stderr, "UDP 广播发现不可用（仍可手动指定地址）: %v\n", err)
					fmt.Fprintln(os.Stderr, "  提示：端口 9100 被占用通常是因为本机已经跑着另一个 beam 实例。")
				} else {
					defer closer.Close()
					fmt.Printf("自动发现已开启（UDP 广播 + mDNS），设备名：%s\n", name)
				}
			}
		}

		total := 0

		serveDirect := func() {
			for {
				conn, err := listener.Accept()
				if err != nil {
					fatal(err)
				}

				// 每个连接独立处理：串行会让能力探测排在正在进行的会话后面，
				// 探测方拿不到握手响应，两边一起卡住。
				go func(conn net.Conn) {
					transferred, err := handle(conn)
					if err != nil {
						fmt.Fprintf(os.Stderr, "传输失败: %v\n", err)
						return
					}

					// 能力探测也会走到这里，但它没有传文件，不该报「传输完成」。
					if !transferred {
						return
					}

					fmt.Println("传输完成，已保存到", *out)
					total++

					if *once && total >= 1 {
						os.Exit(0)
					}

					fmt.Println("继续等待下一个连接…")
				}(conn)
			}
		}

		// 只有中转模式时才把直连监听放到后台：这样对端既能经中转见面，
		// 也能拿能力声明里的地址直接连过来（链路升级的前提）。
		if *relayAddr != "" && *room != "" {
			go serveDirect()
			fmt.Println("  同时保持直连监听，供对端升级链路")
		} else {
			serveDirect()
			return
		}
	}

	if *relayAddr == "" || *room == "" {
		fatal(errors.New("需要 --listen，或者同时给出 --relay 与 --room"))
	}

	// 中转侧常驻：对端升级到直连后会主动关闭中转连接，
	// 若这里按「一次会话」处理，进程会随之中断，把刚建立的直连也一起掐掉。
	go func() {
		for {
			conn, err := relay.Pair(*relayAddr, *room, "recv")
			if err != nil {
				fmt.Fprintf(os.Stderr, "中转配对失败: %v\n", err)
				time.Sleep(2 * time.Second)
				continue
			}

			transferred, err := handle(conn)
			if err != nil {
				fmt.Fprintf(os.Stderr, "中转会话结束: %v\n", err)
			} else if transferred {
				fmt.Println("传输完成，已保存到", *out)
			}

			if *once && transferred {
				os.Exit(0)
			}
		}
	}()

	// 只是中转模式（没给 --listen）时，也挂住主 goroutine：
	// 配对循环在后台常驻，进程不该在单次会话后退出。
	select {}
}

func printPlan(plan proto.Plan) {
	fmt.Printf("\n对方要发送 %d 个文件，共 %s：\n", len(plan.Files), humanBytes(plan.Total))

	for _, file := range plan.Files {
		fmt.Printf("  %-40s %10s\n", truncate(file.Name, 40), humanBytes(file.Size))
	}
}

func askYesNo(prompt string) bool {
	fmt.Print(prompt)

	var answer string
	if _, err := fmt.Scanln(&answer); err != nil {
		return false
	}

	answer = strings.ToLower(strings.TrimSpace(answer))
	return answer == "y" || answer == "yes"
}

func randomRoom() string {
	const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

	buffer := make([]byte, 8)
	if _, err := rand.Read(buffer); err != nil {
		fatal(err)
	}

	code := make([]byte, 8)
	for i := range code {
		code[i] = alphabet[int(buffer[i])%len(alphabet)]
	}

	return string(code[:4]) + "-" + string(code[4:])
}

func fatal(err error) {
	fmt.Fprintf(os.Stderr, "错误: %v\n", err)
	os.Exit(1)
}

// splitFlags 把参数拆成「选项」与「位置参数」两部分。
//
// Go 标准库的 flag 遇到第一个非选项参数就停止解析，所以 `beam send 文件 --to host`
// 会把 --to 当成文件名。这里先做一次分离，让「选项写在前」和「选项写在后」都能用。
func splitFlags(args []string, fs *flag.FlagSet) (flags []string, positional []string) {
	for i := 0; i < len(args); i++ {
		arg := args[i]

		if arg == "--" {
			positional = append(positional, args[i+1:]...)
			break
		}

		if len(arg) > 1 && arg[0] == '-' {
			flags = append(flags, arg)

			name := strings.TrimLeft(arg, "-")
			if strings.ContainsRune(name, '=') {
				continue
			}

			if f := fs.Lookup(name); f != nil && !isBoolFlag(f) && i+1 < len(args) {
				flags = append(flags, args[i+1])
				i++
			}

			continue
		}

		positional = append(positional, arg)
	}

	return flags, positional
}

func isBoolFlag(f *flag.Flag) bool {
	type boolFlag interface {
		IsBoolFlag() bool
	}

	bf, ok := f.Value.(boolFlag)
	return ok && bf.IsBoolFlag()
}

func truncate(text string, limit int) string {
	runes := []rune(text)
	if len(runes) <= limit {
		return text
	}

	return string(runes[:limit-1]) + "…"
}

func humanBytes(n int64) string {
	if n < 1024 {
		return fmt.Sprintf("%d B", n)
	}

	units := []string{"KB", "MB", "GB", "TB"}
	value := float64(n) / 1024
	index := 0

	for value >= 1024 && index < len(units)-1 {
		value /= 1024
		index++
	}

	return fmt.Sprintf("%.1f %s", value, units[index])
}

type progressState struct {
	lastPrint time.Time
	lastBytes int64
	lastTime  time.Time
	printed   bool
}

func newProgress() *progressState {
	now := time.Now()
	return &progressState{lastTime: now}
}

func (p *progressState) update(done, total int64) {
	now := time.Now()
	if now.Sub(p.lastPrint) < 150*time.Millisecond && done < total {
		return
	}

	elapsed := now.Sub(p.lastTime).Seconds()
	rate := 0.0
	if elapsed > 0 {
		rate = float64(done-p.lastBytes) / elapsed
	}

	p.lastBytes = done
	p.lastTime = now
	p.lastPrint = now
	p.printed = true

	percent := 100.0
	if total > 0 {
		percent = float64(done) / float64(total) * 100
	}

	fmt.Fprintf(os.Stderr, "\r  %s / %s  %5.1f%%  %s/s      ",
		humanBytes(done), humanBytes(total), percent, humanBytes(int64(rate)))
}

func (p *progressState) finish() {
	if p.printed {
		fmt.Fprintln(os.Stderr)
		p.printed = false
	}
}

func (p *progressState) abort() {
	if p.printed {
		fmt.Fprintln(os.Stderr)
		p.printed = false
	}
}
