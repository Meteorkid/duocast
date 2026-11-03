package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/csv"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"beam/internal/discover"
	"beam/internal/link"
	"beam/internal/proto"
	"beam/internal/relay"
	"beam/internal/session"
)

// 基准工具：把一次传输拆成「发现 / TCP / 握手 / 协商升级 / 传输确认」五段计时。
//
// 度量约定（对应实验方案第 6 节）：
//   - payload_bytes 是唯一数据量基准，MiB/s 与 Mbit/s 由它推导；
//   - 未执行阶段留空、discovery_status=not_run，不写 0；
//   - 全部阶段共享 t0 起算的**同一个绝对截止时间**，不按段重置；
//   - 每个试次立即落盘；
//   - 建链走 internal/session，与 beam send 同一条代码路径。
//
// 能力边界：本工具一次只测**单条候选**（--to 或 --peer 或 --relay）。
// 组合候选与自动回退属于 `beam send` 的能力，这里明确拒绝，避免「bench 通过
// 就代表产品路径通过」的误读。bench 也不测离线冷启动、AP 建立或 BLE 会合。

const benchSchemaVersion = "2"

type trial struct {
	ExperimentID string
	BatchID      string
	ConditionID  string
	TrialID      string
	DeviceID     string
	Timestamp    string
	Label        string
	Note         string
	Mode         string
	Direction    string
	Topology     string
	StartState   string
	Upgrade      bool

	PayloadBytes int64
	Target       string
	LocalAddr    string
	RemoteAddr   string

	DiscoveryStatus string
	DiscoveryMS     *float64
	TCPMS           *float64
	HandshakeMS     *float64
	NegotiateMS     *float64
	TransferMS      *float64
	TotalMS         *float64

	DeadlineMS   int64
	FailureStage string
	OK           bool
	Error        string

	Attempts        []link.Attempt
	UpgradeAttempts []link.Attempt
	PeerCapsCount   int
	PeerPort        int
	FinalLink       string
	Upgraded        bool

	SoftwareHash string
}

type trialInput struct {
	mode         string
	target       string
	peerName     string
	relayAddr    string
	room         string
	file         string
	payloadBytes int64
	label        string
	note         string
	experimentID string
	batchID      string
	conditionID  string
	deviceID     string
	direction    string
	topology     string
	startState   string
	run          int
	deadline     time.Duration
	discoveryMax time.Duration
	useCaps      bool
	softwareHash string
}

func runBench(args []string) {
	fs := flag.NewFlagSet("bench", flag.ExitOnError)

	target := fs.String("to", "", "直连目标 host:port")
	peerName := fs.String("peer", "", "自动发现的设备名")
	relayAddr := fs.String("relay", "", "中转地址 host:port")
	room := fs.String("room", "", "中转房间码（至少 4 位）")

	sizeMiB := fs.Float64("size", 100, "测试数据量（MiB，1024² 字节）")
	exactBytes := fs.Int64("bytes", 0, "精确字节数；给出时优先于 --size")
	runs := fs.Int("runs", 3, "重复次数")

	label := fs.String("label", "", "链路标签，写进 CSV")
	note := fs.String("note", "", "环境备注，写进 CSV")
	experimentID := fs.String("experiment", "adhoc", "experiment_id")
	conditionID := fs.String("condition", "", "condition_id；留空则自动生成")
	deviceID := fs.String("device", "", "device_id；留空取主机名")
	direction := fs.String("direction", "unspecified", "传输方向，如 mac->win")
	topology := fs.String("topology", "unspecified", "拓扑描述，如 campus-cross-subnet")
	startState := fs.String("state", "unspecified", "起始状态，如 connected-ap")
	csvPath := fs.String("csv", "bench.csv", "CSV 输出路径（追加写入）")
	deadlineSec := fs.Float64("deadline", 180, "单试次总截止时间（秒）")
	useCaps := fs.Bool("caps", false, "建链后执行能力交换并尝试升级（与 send --caps 同路径）")
	discoveryTimeout := fs.Duration("discovery-timeout", 2*time.Second, "每轮发现超时（计入总预算）")
	keepFile := fs.Bool("keep", false, "保留生成的测试文件")

	flagArgs, _ := splitFlags(args, fs)
	fs.Parse(flagArgs)

	if *room != "" {
		*room = strings.ToUpper(*room)
	}

	if err := validateBenchTargets(*target, *peerName, *relayAddr); err != nil {
		fatal(err)
	}

	if *runs <= 0 {
		fatal(errors.New("--runs 必须为正数"))
	}

	payloadBytes := *exactBytes
	if payloadBytes <= 0 {
		payloadBytes = int64(*sizeMiB * 1024 * 1024)
	}

	if payloadBytes <= 0 {
		fatal(errors.New("--size 与 --bytes 至少要给出一个正数"))
	}

	if *label == "" {
		*label = "default"
	}

	if *deviceID == "" {
		*deviceID = discover.LocalName()
	}

	mode := "to"
	switch {
	case *peerName != "":
		mode = "peer"
	case *relayAddr != "":
		mode = "relay"
	}

	testFile, err := createBenchFile(payloadBytes)
	if err != nil {
		fatal(err)
	}

	if !*keepFile {
		defer os.Remove(testFile)
	} else {
		fmt.Printf("测试文件保留在 %s\n", testFile)
	}

	// batch 让每次调用有独立标识：同一条件下多次运行的 trial_id 不会重复。
	batchID := newBatchID()

	if *conditionID == "" {
		*conditionID = buildConditionID(conditionMeta{
			mode:         mode,
			label:        *label,
			payloadBytes: payloadBytes,
			upgrade:      *useCaps,
			direction:    *direction,
			topology:     *topology,
			startState:   *startState,
		})
	}

	writer, closeWriter, err := openCSVWriter(*csvPath)
	if err != nil {
		fatal(err)
	}

	fmt.Printf("实验 %s / 批次 %s / 条件 %s\n", *experimentID, batchID, *conditionID)
	fmt.Printf("%s，%.2f MiB（%d bytes）× %d 次，截止 %.0fs，能力交换=%v\n\n",
		describeTarget(mode, *target, *peerName, *relayAddr),
		float64(payloadBytes)/1024/1024, payloadBytes, *runs, *deadlineSec, *useCaps)

	software := executableHash()
	deadline := time.Duration(*deadlineSec * float64(time.Second))

	inputs := make([]trialInput, 0, *runs)

	for run := 1; run <= *runs; run++ {
		inputs = append(inputs, trialInput{
			mode: mode, target: *target, peerName: *peerName, relayAddr: *relayAddr, room: *room,
			file: testFile, payloadBytes: payloadBytes, label: *label, note: *note,
			experimentID: *experimentID, batchID: batchID, conditionID: *conditionID, deviceID: *deviceID,
			direction: *direction, topology: *topology, startState: *startState,
			run: run, deadline: deadline, discoveryMax: *discoveryTimeout,
			useCaps: *useCaps, softwareHash: software,
		})
	}

	saved, runErr := runTrials(writer, inputs, os.Stdout)
	if runErr != nil {
		fmt.Fprintf(os.Stderr, "\n已保存 %d/%d 次，随后失败: %v\n", saved, len(inputs), runErr)
		os.Exit(1)
	}

	if closeErr := closeWriter(); closeErr != nil {
		fmt.Fprintf(os.Stderr, "\n关闭 CSV 失败（已完成 %d 次，数据可能未落盘）: %v\n", saved, closeErr)
		os.Exit(1)
	}

	fmt.Printf("\n已完成 %d 次，写入 %s\n", saved, *csvPath)
}

// runTrials 顺序执行试次并立即落盘。
//
// 任何写入失败都必须立刻停止：继续跑会让后续试次的数据同样丢失，
// 而且最终还会打印「已完成 N 次」，与事实不符。
func runTrials(writer *csv.Writer, inputs []trialInput, out io.Writer) (int, error) {
	saved := 0

	for _, input := range inputs {
		row := runTrial(input)
		printTrialTo(out, row)

		if err := writeTrial(writer, row); err != nil {
			return saved, fmt.Errorf("第 %d 个试次写入失败: %w", input.run, err)
		}

		saved++
	}

	return saved, nil
}

// validateBenchTargets 限制 bench 一次只能声明一条候选。
//
// 组合候选与自动回退是 beam send 的能力；bench 若静默只取其一，
// 会让「bench 通过」被误读成「产品路径通过」。
func validateBenchTargets(target, peerName, relayAddr string) error {
	specified := 0
	for _, value := range []string{target, peerName, relayAddr} {
		if value != "" {
			specified++
		}
	}

	if specified == 0 {
		return errors.New("需要 --to、--peer 或 --relay 之一")
	}

	if specified > 1 {
		return errors.New("bench 一次只测单条候选；组合候选与自动回退请用 beam send，两者的测量口径不同")
	}

	return nil
}

// runTrial 执行一个试次。t0 起算的绝对截止时间贯穿所有阶段。
func runTrial(in trialInput) trial {
	started := time.Now()
	deadlineAt := started.Add(in.deadline)

	row := trial{
		ExperimentID: in.experimentID,
		BatchID:      in.batchID,
		ConditionID:  in.conditionID,
		TrialID:      makeTrialID(in.conditionID, in.batchID, in.run),
		DeviceID:     in.deviceID,
		Timestamp:    started.Format(time.RFC3339),
		Label:        in.label,
		Note:         in.note,
		Mode:         in.mode,
		Direction:    in.direction,
		Topology:     in.topology,
		StartState:   in.startState,
		Upgrade:      in.useCaps,
		PayloadBytes: in.payloadBytes,
		DeadlineMS:   in.deadline.Milliseconds(),
		SoftwareHash: in.softwareHash,
	}

	total := func() float64 { return elapsedMS(started) }
	expired := func() bool { return !time.Now().Before(deadlineAt) }

	candidates := make([]link.Candidate, 0, 4)

	switch in.mode {
	case "peer":
		// 发现阶段也只能用剩余预算，不能额外给一份超时。
		discoveryBudget := in.discoveryMax
		if remaining := time.Until(deadlineAt); remaining < discoveryBudget {
			discoveryBudget = remaining
		}

		discoveryStart := time.Now()
		found, ok := discoverPeer(in.peerName, discoveryBudget)
		discoveryMS := elapsedMS(discoveryStart)

		row.DiscoveryMS = &discoveryMS
		row.DiscoveryStatus = "error"

		if !ok {
			row.Error = "未发现设备 " + in.peerName
			row.FailureStage = "discovery"
			row.TotalMS = ptr(total())
			return row
		}

		row.DiscoveryStatus = "success"
		row.Target = found.Name

		for _, addr := range found.Addrs {
			candidates = append(candidates, link.NewTCPCandidate(link.KindDiscovered, addr))
		}

	case "relay":
		row.DiscoveryStatus = "not_run"
		row.Target = in.relayAddr + "/" + in.room
		candidates = append(candidates, link.NewRelayCandidate(in.relayAddr, in.room, func(a, r string, deadline time.Time) (net.Conn, error) {
			return relay.PairWithin(a, r, "send", deadline)
		}))

	default:
		row.DiscoveryStatus = "not_run"
		row.Target = in.target
		candidates = append(candidates, link.NewTCPCandidate(link.KindDirect, in.target))
	}

	if expired() {
		row.FailureStage = "deadline"
		row.Error = "发现阶段耗尽截止时间"
		row.TotalMS = ptr(total())
		return row
	}

	var caps *proto.Caps
	if in.useCaps {
		caps = &proto.Caps{
			Name:  discover.LocalName(),
			Addrs: discover.LocalIPv4(),
			Kinds: []string{string(link.KindDirect), string(link.KindRelay)},
		}
	}

	established, err := session.Establish(candidates, session.Options{
		Caps:         caps,
		AllowUpgrade: in.useCaps,
		Deadline:     deadlineAt,
	})

	row.Attempts = established.Link.Attempts
	row.UpgradeAttempts = established.UpgradeAttempts
	row.Upgraded = established.Upgraded
	row.FinalLink = string(established.FinalKind)

	if chosen := established.Link.Chosen; chosen != nil {
		if chosen.DialMS > 0 {
			dialMS := chosen.DialMS
			row.TCPMS = &dialMS
		}

		if chosen.HandshakeMS > 0 {
			handshakeMS := chosen.HandshakeMS
			row.HandshakeMS = &handshakeMS
		}
	}

	if established.NegotiateMS > 0 {
		negotiateMS := established.NegotiateMS
		row.NegotiateMS = &negotiateMS
	}

	if established.PeerCaps != nil {
		row.PeerCapsCount = len(established.PeerCaps.Addrs)
		row.PeerPort = established.PeerCaps.Port
	}

	if err != nil {
		if expired() {
			row.FailureStage = "deadline"
			row.Error = "建链阶段耗尽截止时间"
		} else {
			row.FailureStage = classifyLinkFailure(established)
			row.Error = err.Error()
		}

		row.TotalMS = ptr(total())
		return row
	}

	conn := established.Conn
	defer conn.Close()

	row.LocalAddr = conn.LocalAddr().String()
	row.RemoteAddr = conn.RemoteAddr().String()

	if expired() {
		row.FailureStage = "deadline"
		row.Error = "建链后已超出截止时间"
		row.TotalMS = ptr(total())
		return row
	}

	// 传输与「等待接收端 Result」也要受同一份预算约束。
	_ = conn.SetDeadline(deadlineAt)

	transferStart := time.Now()
	_, sendErr := proto.Send(conn, []string{in.file}, caps, nil)
	transferMS := elapsedMS(transferStart)

	_ = conn.SetDeadline(time.Time{})

	row.TransferMS = &transferMS
	row.TotalMS = ptr(total())

	if sendErr != nil {
		if expired() {
			row.FailureStage = "deadline"
		} else {
			row.FailureStage = "transfer"
		}

		row.Error = sendErr.Error()
		return row
	}

	// 传输成功但已越过截止时间：记为超时，不能算成功。
	if expired() {
		row.FailureStage = "deadline"
		row.Error = "传输在截止时间之后才完成"
		return row
	}

	// 成功终点：sendOne 已等到接收端逐文件 Result（关闭 + SHA-256 + 重命名之后）。
	row.OK = true
	return row
}

// newBatchID 生成进程内唯一的批次标识。
//
// 只用秒级时间戳时，同一秒内跑两次会产生相同 batch_id，进而让 trial_id 冲突、
// 汇总时无法区分两批数据。这里加 4 字节随机后缀，并用计数器兜底。
func newBatchID() string {
	buffer := make([]byte, 4)
	if _, err := rand.Read(buffer); err != nil {
		return fmt.Sprintf("%s-%06d", time.Now().Format("20060102T150405"), atomic.AddUint32(&batchCounter, 1))
	}

	return time.Now().Format("20060102T150405") + "-" + hex.EncodeToString(buffer)
}

var batchCounter uint32

// makeTrialID 把批次写进 ID：同一条件跨多次调用运行也不会出现重复 trial_id。
func makeTrialID(conditionID, batchID string, run int) string {
	return fmt.Sprintf("%s@%s-%03d", conditionID, batchID, run)
}

// classifyLinkFailure 区分「连不上」与「连上了但不是本程序」。
func classifyLinkFailure(established session.Result) string {
	lastDialFailed := false

	for _, attempt := range established.Link.Attempts {
		if attempt.OK {
			continue
		}

		if attempt.HandshakeMS > 0 || strings.Contains(attempt.Error, "握手失败") {
			return "handshake"
		}

		lastDialFailed = true
	}

	if lastDialFailed {
		return "tcp"
	}

	return "tcp"
}

func printTrial(row trial) {
	printTrialTo(os.Stdout, row)
}

func printTrialTo(out io.Writer, row trial) {
	status := "OK  "
	if !row.OK {
		status = "FAIL"
	}

	discovery := "not_run"
	if row.DiscoveryStatus != "not_run" {
		discovery = msText(row.DiscoveryMS)
	}

	fmt.Fprintf(out, "  %s %s  发现 %8s  TCP %8s  握手 %8s  协商 %8s  传输 %9s  合计 %9s  尝试 %d/%d",
		status, row.TrialID, discovery, msText(row.TCPMS), msText(row.HandshakeMS),
		msText(row.NegotiateMS), msText(row.TransferMS), msText(row.TotalMS),
		failedAttempts(row.Attempts), len(row.Attempts))

	if row.OK {
		fmt.Fprintf(out, "  %6.2f MiB/s (%6.1f Mbit/s)", throughputMiB(row), throughputMbit(row))
	} else {
		fmt.Fprintf(out, "  失败于 %s: %s", row.FailureStage, row.Error)
	}

	fmt.Fprintln(out)
}

func failedAttempts(attempts []link.Attempt) int {
	count := 0
	for _, attempt := range attempts {
		if !attempt.OK {
			count++
		}
	}

	return count
}

func msText(value *float64) string {
	if value == nil {
		return "-"
	}

	return fmt.Sprintf("%.0fms", *value)
}

func throughputMiB(row trial) float64 {
	if row.TransferMS == nil || *row.TransferMS <= 0 {
		return 0
	}

	seconds := *row.TransferMS / 1000
	return float64(row.PayloadBytes) / 1024 / 1024 / seconds
}

func throughputMbit(row trial) float64 {
	return throughputMiB(row) * 8.388608
}

type conditionMeta struct {
	mode         string
	label        string
	payloadBytes int64
	upgrade      bool
	direction    string
	topology     string
	startState   string
}

// buildConditionID 用精确字节数构造条件，避免 1 字节与 1000 字节被截断成同一组。
func buildConditionID(meta conditionMeta) string {
	upgradeTag := "noup"
	if meta.upgrade {
		upgradeTag = "up"
	}

	return fmt.Sprintf("%s-%s-%dB-%s-%s-%s-%s",
		meta.mode, meta.label, meta.payloadBytes, upgradeTag,
		sanitizeID(meta.direction), sanitizeID(meta.topology), sanitizeID(meta.startState))
}

func sanitizeID(value string) string {
	if value == "" {
		return "na"
	}

	replacer := strings.NewReplacer(" ", "_", "/", "-", ">", "_", ",", "_", "|", "_", ";", "_")
	return replacer.Replace(value)
}

func describeTarget(mode, target, peer, relay string) string {
	switch mode {
	case "peer":
		return "自动发现 " + peer
	case "relay":
		return "经中转 " + relay
	default:
		return "直连 " + target
	}
}

// openCSVWriter 打开输出文件，并严格核验表头。
//
// 只在文件为空时写表头；文件已有内容时必须与当前 schema 完全一致，
// 否则拒绝追加——把 v2 列写进 v1 表头会产生无法解析的混合数据。
func openCSVWriter(path string) (*csv.Writer, func() error, error) {
	header := benchHeader()

	if info, err := os.Stat(path); err == nil && info.Size() > 0 {
		existing, readErr := readHeader(path)
		if readErr != nil {
			return nil, nil, fmt.Errorf("读取已有文件表头失败（%s）：%w", path, readErr)
		}

		if !equalHeader(existing, header) {
			return nil, nil, fmt.Errorf(
				"已有文件 %s 的表头与当前 schema(v%s) 不一致（可能是 v1 或旧列序）。\n"+
					"原文件不会被修改。请换一个新路径，例如 --csv bench-results/<name>-v2.csv",
				path, benchSchemaVersion)
		}
	}

	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, nil, err
	}

	writer := csv.NewWriter(file)

	if info, statErr := file.Stat(); statErr == nil && info.Size() == 0 {
		if err := writer.Write(header); err != nil {
			file.Close()
			return nil, nil, err
		}

		writer.Flush()

		if err := writer.Error(); err != nil {
			file.Close()
			return nil, nil, fmt.Errorf("写入表头失败: %w", err)
		}
	}

	closer := func() error {
		writer.Flush()
		flushErr := writer.Error()
		closeErr := file.Close()

		if flushErr != nil {
			return flushErr
		}

		return closeErr
	}

	return writer, closer, nil
}

func readHeader(path string) ([]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	reader := csv.NewReader(file)
	return reader.Read()
}

func equalHeader(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}

	for i := range left {
		if left[i] != right[i] {
			return false
		}
	}

	return true
}

func benchHeader() []string {
	return []string{
		"schema_version", "experiment_id", "batch_id", "condition_id", "trial_id", "device_id",
		"timestamp", "label", "note", "mode", "direction", "topology", "start_state", "upgrade",
		"payload_bytes", "size_mib", "target", "local_addr", "remote_addr",
		"discovery_status", "discovery_ms", "tcp_ms", "handshake_ms", "negotiate_ms", "transfer_ms", "total_ms",
		"deadline_ms", "failure_stage", "ok", "error",
		"attempts", "upgrade_attempts", "peer_caps_count", "peer_port", "final_link", "upgraded",
		"throughput_mib_s", "throughput_mbit_s", "software_sha256",
	}
}

func writeTrial(writer *csv.Writer, row trial) error {
	record := []string{
		benchSchemaVersion, row.ExperimentID, row.BatchID, row.ConditionID, row.TrialID, row.DeviceID,
		row.Timestamp, row.Label, row.Note, row.Mode, row.Direction, row.Topology, row.StartState,
		strconv.FormatBool(row.Upgrade),
		strconv.FormatInt(row.PayloadBytes, 10), fmt.Sprintf("%.2f", float64(row.PayloadBytes)/1024/1024),
		row.Target, row.LocalAddr, row.RemoteAddr,
		row.DiscoveryStatus, msCell(row.DiscoveryMS), msCell(row.TCPMS), msCell(row.HandshakeMS),
		msCell(row.NegotiateMS), msCell(row.TransferMS), msCell(row.TotalMS),
		strconv.FormatInt(row.DeadlineMS, 10), row.FailureStage, strconv.FormatBool(row.OK), row.Error,
		formatAttempts(row.Attempts), formatAttempts(row.UpgradeAttempts),
		strconv.Itoa(row.PeerCapsCount), strconv.Itoa(row.PeerPort), row.FinalLink,
		strconv.FormatBool(row.Upgraded),
		fmt.Sprintf("%.3f", throughputMiB(row)), fmt.Sprintf("%.2f", throughputMbit(row)), row.SoftwareHash,
	}

	if err := writer.Write(record); err != nil {
		return err
	}

	writer.Flush()
	return writer.Error()
}

// formatAttempts 把每次尝试压成一行，失败尝试的耗时不能被「只保留成功项」抹掉。
// 形如 discovered@10.0.0.5:9001:12/13:ok;direct@1.2.3.4:9001:8/0:refused
func formatAttempts(attempts []link.Attempt) string {
	if len(attempts) == 0 {
		return ""
	}

	parts := make([]string, 0, len(attempts))

	for _, attempt := range attempts {
		status := "ok"
		if !attempt.OK {
			status = sanitizeID(attempt.Error)
		}

		parts = append(parts, fmt.Sprintf("%s|%s|%.0f|%.0f|%s",
			attempt.Kind, attempt.Label, attempt.DialMS, attempt.HandshakeMS, status))
	}

	return strings.Join(parts, ";")
}

// msCell 未执行/未发生的时间字段写成空串，而不是 0。
func msCell(value *float64) string {
	if value == nil {
		return ""
	}

	return strconv.FormatFloat(*value, 'f', 1, 64)
}

func ptr(value float64) *float64 { return &value }

func createBenchFile(payloadBytes int64) (string, error) {
	path := filepath.Join(os.TempDir(), fmt.Sprintf("beam-bench-%d.bin", payloadBytes))

	if info, err := os.Stat(path); err == nil && info.Size() == payloadBytes {
		return path, nil
	}

	file, err := os.Create(path)
	if err != nil {
		return "", err
	}
	defer file.Close()

	pattern := make([]byte, 1<<20)
	for i := range pattern {
		pattern[i] = byte(i % 251)
	}

	remaining := payloadBytes
	for remaining > 0 {
		chunk := int64(len(pattern))
		if remaining < chunk {
			chunk = remaining
		}

		if _, err := file.Write(pattern[:chunk]); err != nil {
			return "", err
		}

		remaining -= chunk
	}

	return path, nil
}

func executableHash() string {
	path, err := os.Executable()
	if err != nil {
		return "unknown"
	}

	file, err := os.Open(path)
	if err != nil {
		return "unknown"
	}
	defer file.Close()

	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "unknown"
	}

	return hex.EncodeToString(hash.Sum(nil))[:16]
}

// discoverPeer 在给定预算内反复短窗口扫描，返回首次看到的设备。
func discoverPeer(name string, budget time.Duration) (discover.Peer, bool) {
	const window = 100 * time.Millisecond

	deadline := time.Now().Add(budget)

	for time.Now().Before(deadline) {
		attemptWindow := window
		if remaining := time.Until(deadline); remaining < attemptWindow {
			attemptWindow = remaining
		}

		peers := discover.DiscoverAll(attemptWindow)

		if found, ok := discover.Match(peers, name); ok {
			return found, true
		}
	}

	return discover.Peer{}, false
}

func elapsedMS(started time.Time) float64 {
	return float64(time.Since(started).Microseconds()) / 1000
}
