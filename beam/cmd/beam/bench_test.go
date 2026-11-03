package main

import (
	"bytes"
	"encoding/csv"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"beam/internal/link"
	"beam/internal/proto"
	"beam/internal/secure"
	"beam/internal/session"
)

// TestMSCellNilIsEmpty 未执行阶段必须留空，不能写 0——
// 0 会被下游当成「耗时极短」，污染分位数统计。
func TestMSCellNilIsEmpty(t *testing.T) {
	if got := msCell(nil); got != "" {
		t.Fatalf("未执行阶段应输出空串，实际 %q", got)
	}

	value := 12.5
	if got := msCell(&value); got != "12.5" {
		t.Fatalf("应输出 12.5，实际 %q", got)
	}
}

// TestThroughputFromPayloadBytes 吞吐只由 payload_bytes 与传输段耗时推导。
func TestThroughputFromPayloadBytes(t *testing.T) {
	transfer := 1000.0
	row := trial{PayloadBytes: 1024 * 1024, TransferMS: &transfer}

	if got := throughputMiB(row); got < 0.999 || got > 1.001 {
		t.Fatalf("1 MiB / 1 s 应为 1.0 MiB/s，实际 %.4f", got)
	}

	if got := throughputMbit(row); got < 8.38 || got > 8.40 {
		t.Fatalf("1 MiB/s 应为 8.388608 Mbit/s，实际 %.4f", got)
	}
}

func TestThroughputZeroWithoutTransfer(t *testing.T) {
	if got := throughputMiB(trial{PayloadBytes: 1024}); got != 0 {
		t.Fatalf("无传输耗时应为 0，实际 %v", got)
	}
}

// TestBuildConditionIDUsesExactBytes 1 字节与 1000 字节不能被截断成同一个条件。
func TestBuildConditionIDUsesExactBytes(t *testing.T) {
	base := conditionMeta{mode: "to", label: "x", upgrade: false, direction: "mac->win", topology: "lan", startState: "connected"}

	one := buildConditionID(withBytes(base, 1))
	thousand := buildConditionID(withBytes(base, 1000))

	if one == thousand {
		t.Fatalf("不同字节数必须区分：%q", one)
	}

	if !strings.Contains(one, "-1B-") || !strings.Contains(thousand, "-1000B-") {
		t.Fatalf("条件 ID 应包含精确字节数：%q / %q", one, thousand)
	}
}

func withBytes(meta conditionMeta, bytes int64) conditionMeta {
	meta.payloadBytes = bytes
	return meta
}

// TestBuildConditionIDSeparatesMetadata 方向/拓扑/起始状态变化都必须产生新条件。
func TestBuildConditionIDSeparatesMetadata(t *testing.T) {
	base := conditionMeta{mode: "to", label: "x", payloadBytes: 1024, direction: "mac->win", topology: "lan", startState: "connected"}
	reference := buildConditionID(base)

	variants := []conditionMeta{
		{mode: base.mode, label: base.label, payloadBytes: base.payloadBytes, direction: "win->mac", topology: base.topology, startState: base.startState},
		{mode: base.mode, label: base.label, payloadBytes: base.payloadBytes, direction: base.direction, topology: "campus", startState: base.startState},
		{mode: base.mode, label: base.label, payloadBytes: base.payloadBytes, direction: base.direction, topology: base.topology, startState: "cold"},
		{mode: base.mode, label: base.label, payloadBytes: base.payloadBytes, upgrade: true, direction: base.direction, topology: base.topology, startState: base.startState},
	}

	for _, meta := range variants {
		if buildConditionID(meta) == reference {
			t.Fatalf("元数据变化后条件 ID 仍相同: %+v", meta)
		}
	}
}

// TestTrialIDUniqueAcrossBatches 同一条件跑两次不能产生相同 trial_id。
func TestTrialIDUniqueAcrossBatches(t *testing.T) {
	condition := "to-x-1024B-noup-mac_win-lan-connected"

	first := makeTrialID(condition, "20260101T000000", 1)
	second := makeTrialID(condition, "20260101T000001", 1)

	if first == second {
		t.Fatalf("跨批次 trial_id 重复：%q", first)
	}

	if makeTrialID(condition, "b", 1) == makeTrialID(condition, "b", 2) {
		t.Fatal("同批次不同 run 的 trial_id 重复")
	}
}

// TestValidateBenchTargets 明确拒绝组合候选，避免「bench 通过=产品路径通过」的误读。
func TestValidateBenchTargets(t *testing.T) {
	if err := validateBenchTargets("", "", ""); err == nil {
		t.Fatal("没有任何目标应报错")
	}

	if err := validateBenchTargets("1.2.3.4:9001", "", ""); err != nil {
		t.Fatalf("单候不应报错: %v", err)
	}

	if err := validateBenchTargets("1.2.3.4:9001", "peer", ""); err == nil {
		t.Fatal("组合候选应被明确拒绝")
	}
}

// TestOpenCSVWriterRejectsForeignHeader v1 文件必须被拒绝，且逐字节不变。
func TestOpenCSVWriterRejectsForeignHeader(t *testing.T) {
	path := filepath.Join(t.TempDir(), "legacy.csv")
	legacy := "time,label,note,run,size_mb,target_mode,target,local_addr,remote_addr,discovery_ms,connect_ms,transfer_ms,total_ms,throughput_mbs,throughput_mbps,ok,error\n"
	if err := os.WriteFile(path, []byte(legacy), 0o644); err != nil {
		t.Fatal(err)
	}

	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	if _, _, err := openCSVWriter(path); err == nil {
		t.Fatal("表头不一致时必须拒绝追加")
	}

	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	if string(before) != string(after) {
		t.Fatal("被拒绝时原文件不能有任何改动")
	}
}

// TestOpenCSVWriterWritesHeaderAndAppendsColumns 新文件写表头，追加行列数与表头一致。
func TestOpenCSVWriterWritesHeaderAndAppendsColumns(t *testing.T) {
	path := filepath.Join(t.TempDir(), "v2.csv")

	writer, closer, err := openCSVWriter(path)
	if err != nil {
		t.Fatalf("新建文件失败: %v", err)
	}

	row := trial{
		ExperimentID: "e", BatchID: "b", ConditionID: "c", TrialID: "t", DeviceID: "d",
		PayloadBytes: 1024,
	}

	if err := writeTrial(writer, row); err != nil {
		t.Fatalf("写入失败: %v", err)
	}
	closer()

	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()

	records, err := csv.NewReader(file).ReadAll()
	if err != nil {
		t.Fatal(err)
	}

	if len(records) != 2 {
		t.Fatalf("应有表头 + 1 行，实际 %d 行", len(records))
	}

	if len(records[0]) != len(benchHeader()) {
		t.Fatalf("表头列数 %d，期望 %d", len(records[0]), len(benchHeader()))
	}

	if len(records[1]) != len(records[0]) {
		t.Fatalf("数据行列数 %d 与表头 %d 不一致", len(records[1]), len(records[0]))
	}
}

// TestWriteTrialPropagatesError 写入失败必须返回错误，调用方据此不能报告「已保存」。
func TestWriteTrialPropagatesError(t *testing.T) {
	path := filepath.Join(t.TempDir(), "closed.csv")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}

	writer := csv.NewWriter(file)
	file.Close()

	if err := writeTrial(writer, trial{PayloadBytes: 1}); err == nil {
		t.Fatal("底层文件关闭后写入应报错")
	}
}

// TestClassifyLinkFailure 区分「连不上」与「连上了但不是本程序」。
func TestClassifyLinkFailure(t *testing.T) {
	dialFail := session.Result{Link: link.Result{Attempts: []link.Attempt{
		{OK: false, Error: "connect: connection refused"},
	}}}
	if got := classifyLinkFailure(dialFail); got != "tcp" {
		t.Fatalf("应为 tcp，实际 %q", got)
	}

	handshakeFail := session.Result{Link: link.Result{Attempts: []link.Attempt{
		{OK: false, HandshakeMS: 12, Error: "握手失败: EOF"},
	}}}
	if got := classifyLinkFailure(handshakeFail); got != "handshake" {
		t.Fatalf("应为 handshake，实际 %q", got)
	}
}

// TestRunTrialFailsOnDeadlineWhenPeerStalls 对端握手后不读数据，
// 传输阶段必须在 deadline 内结束，且不能记为成功。
func TestRunTrialFailsOnDeadlineWhenPeerStalls(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()

		if _, err := secure.Handshake(conn); err != nil {
			return
		}

		// 握手后既不读也不写，模拟「接收端卡住、Result 永远不来」。
		time.Sleep(3 * time.Second)
	}()

	payloadBytes := int64(8 << 20)
	file, err := createBenchFile(payloadBytes)
	if err != nil {
		t.Fatal(err)
	}

	started := time.Now()
	row := runTrial(trialInput{
		mode:         "to",
		target:       listener.Addr().String(),
		file:         file,
		payloadBytes: payloadBytes,
		conditionID:  "deadline-test",
		batchID:      "b1",
		deadline:     300 * time.Millisecond,
	})
	elapsed := time.Since(started)

	if row.OK {
		t.Fatal("对端不响应时不能记为成功")
	}

	if row.FailureStage != "deadline" {
		t.Fatalf("失败阶段应为 deadline，实际 %q（错误：%s）", row.FailureStage, row.Error)
	}

	if elapsed > time.Second {
		t.Fatalf("未被 deadline 打断，耗时 %v", elapsed)
	}

	if row.TotalMS == nil {
		t.Fatal("总耗时应被记录")
	}
}

// TestRunTrialsStopsOnWriteFailure：任何写入失败都必须立刻停止，
// 并如实报告已保存数量，不能继续跑完再声称「全部写入」。
func TestRunTrialsStopsOnWriteFailure(t *testing.T) {
	path := filepath.Join(t.TempDir(), "closed-early.csv")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}

	writer := csv.NewWriter(file)
	file.Close() // 底层关闭：后续写入必然失败

	inputs := []trialInput{
		{run: 1, mode: "to", target: "127.0.0.1:1", payloadBytes: 16},
		{run: 2, mode: "to", target: "127.0.0.1:1", payloadBytes: 16},
		{run: 3, mode: "to", target: "127.0.0.1:1", payloadBytes: 16},
	}

	var out bytes.Buffer

	saved, runErr := runTrials(writer, inputs, &out)
	if runErr == nil {
		t.Fatal("写入失败时必须返回错误")
	}

	if saved != 0 {
		t.Fatalf("第一次写入就失败，已保存数应为 0，实际 %d", saved)
	}

	if strings.Contains(out.String(), "已完成") {
		t.Fatal("失败时不能输出「已完成」")
	}
}

// TestNewBatchIDUnique：批次 ID 必须唯一，同秒内多次调用也不能重复。
func TestNewBatchIDUnique(t *testing.T) {
	seen := make(map[string]bool, 2000)

	for i := 0; i < 2000; i++ {
		id := newBatchID()
		if seen[id] {
			t.Fatalf("批次 ID 重复: %q", id)
		}

		seen[id] = true
	}
}

// TestNewBatchIDUniqueConcurrent：并发生成同样不能重复。
func TestNewBatchIDUniqueConcurrent(t *testing.T) {
	const goroutines = 64
	const perGoroutine = 32

	results := make(chan string, goroutines*perGoroutine)
	var wg sync.WaitGroup

	for i := 0; i < goroutines; i++ {
		wg.Add(1)

		go func() {
			defer wg.Done()
			for j := 0; j < perGoroutine; j++ {
				results <- newBatchID()
			}
		}()
	}

	wg.Wait()
	close(results)

	seen := make(map[string]bool)
	for id := range results {
		if seen[id] {
			t.Fatalf("并发下批次 ID 重复: %q", id)
		}

		seen[id] = true
	}

	if len(seen) != goroutines*perGoroutine {
		t.Fatalf("生成数量不符: %d", len(seen))
	}
}

// TestWriteTraceIncludesUpgradeAndCaps：trace 必须包含最终路径、升级明细与能力交换错误。
func TestWriteTraceIncludesUpgradeAndCaps(t *testing.T) {
	path := filepath.Join(t.TempDir(), "trace.json")

	result := session.Result{
		Link: link.Result{
			TotalMS: 12.5,
			Attempts: []link.Attempt{
				{Kind: link.KindRelay, Label: "relay:9000/TEST1", Cost: 90, MS: 12.5, DialMS: 12.5, OK: true},
			},
		},
		NegotiateMS: 3.5,
		Upgraded:    true,
		FinalKind:   link.KindDiscovered,
		FinalLabel:  "10.0.0.1:9002",
		PeerCaps:    &proto.Caps{Name: "peer", Port: 9002, Addrs: []string{"10.0.0.1"}},
		UpgradeAttempts: []link.Attempt{
			{Kind: link.KindDiscovered, Label: "10.0.0.1:9002", Cost: 10, MS: 1.5, DialMS: 1.5, OK: true},
		},
	}

	if err := writeTrace(path, result); err != nil {
		t.Fatalf("写 trace 失败: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	var decoded map[string]any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("trace 不是合法 JSON: %v", err)
	}

	for _, key := range []string{"attempts", "upgrade_attempts", "final_kind", "final_label", "upgraded", "peer_caps", "negotiate_ms"} {
		if _, ok := decoded[key]; !ok {
			t.Fatalf("trace 缺少字段 %q", key)
		}
	}

	if decoded["upgraded"] != true {
		t.Fatalf("upgraded 应为 true，实际 %v", decoded["upgraded"])
	}

	if decoded["final_kind"] != "discovered" {
		t.Fatalf("final_kind 应为 discovered，实际 %v", decoded["final_kind"])
	}
}

// TestWriteTraceIncludesCapsError：能力交换失败也要留在 trace 里。
func TestWriteTraceIncludesCapsError(t *testing.T) {
	path := filepath.Join(t.TempDir(), "trace-caps.json")

	result := session.Result{
		Link:       link.Result{TotalMS: 5},
		CapsErr:    "对端未接受能力交换",
		FinalKind:  link.KindDirect,
		FinalLabel: "10.0.0.1:9001",
	}

	if err := writeTrace(path, result); err != nil {
		t.Fatal(err)
	}

	raw, _ := os.ReadFile(path)

	var decoded map[string]any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatal(err)
	}

	if decoded["caps_error"] != "对端未接受能力交换" {
		t.Fatalf("caps_error 未写入: %v", decoded["caps_error"])
	}
}
