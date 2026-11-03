# WorkBuddy 研究推进与独立验收记录

> 日期：2026-11-02（Asia/Shanghai）
> 执行方式：Codex 通过 WorkBuddy 原生界面，在 duocast 的「开始进行开发工作」既有任务中下达指令、读取交付、返工并验收。
> 本记录说明本轮研究基础工具的进展，不代表 12 周研究计划或双机离线实验已经完成。

## 1. 本轮范围

执行入口为 [研究计划](research-plan-2026-11-02.md) 与 [实验方案](experiment-protocol-2026-11-02.md)。原来的校园网、热点及 relay→direct 实验保留为历史探索材料。

WorkBuddy 完成了三个代码批次：初始改造、第一次验收返工、针对具体失败用例的第二次返工；随后单独收尾报告解释。Codex 和协作代理只读审阅实现，Codex 另外运行了最终验证。

最终文档核查后，Codex 对 `2026-11-02-experiments.md` 和 `stage1-report.md` 做了局部文字修正：删除由跨条件吞吐差推断瓶颈位置的残留说法，并将配对摘要统一为 3 正 2 负、中位差 +0.17 MiB/s。程序代码和原始数据未因此修改。

本轮没有更改系统网络、VPN、防火墙、网卡驱动或系统权限，没有提交或发布论文，没有启动正式 E1–E4 采集。WorkBuddy 报告清理了其新建的本机测试接收端，原有任务未纳入清理范围。

## 2. 完成的工具改造

- `send` 与 `bench` 复用会话建立实现；展示对端能力的函数不再额外执行隐式联网探测。
- 统一使用精确 `payload_bytes`，区分 MiB/s 与十进制 Mbit/s；未执行发现记为空耗时和 `not_run`。
- 增加试次/批次/条件标识和方向、拓扑、起始状态、版本等元数据；批次 ID 不再只精确到秒。
- 为基准试次建立绝对截止时间，约束发现、连接、握手、能力交换、升级及传输确认；内置 relay 配对接受外部预算。
- 修复快速连接结果误丢弃与超时后晚到连接清理；能力交换超时/协议错误不再被吞掉后继续使用失效会话。
- CSV 追加前核验表头；写入、Flush 或关闭失败会停止并返回失败，保留已经成功写入的数量。
- 记录候选/升级尝试与最终路径；汇总先拒绝重复试次和条件冲突，再生成结果，并单列失败尝试计数。
- `send --trace` 保存完整会话记录，包含初始候选、升级候选、最终路径与能力交换错误。

主要实现文件：

- [bench.go](../beam/cmd/beam/bench.go)
- [main.go](../beam/cmd/beam/main.go)
- [session.go](../beam/internal/session/session.go)
- [link.go](../beam/internal/link/link.go)
- [relay.go](../beam/internal/relay/relay.go)
- [bench-summary.py](../beam/scripts/bench-summary.py)

## 3. 验收过程中发现并修复的问题

初始版本即使已有测试通过，仍存在总期限被候选预算覆盖、Hello/Result 阻塞无界、旧 CSV 表头被新列追加、同秒试次 ID 冲突、冲突数据先合并后告警、失败尝试未进入汇总等问题。

Codex 使用临时合成 CSV 独立复现：两个记录共享 trial/condition、但字节数分别为 1 和 1000 时，旧汇总仍输出主表且 exit 0。修复后的 Python CLI 回归要求非零退出、报告冲突、不生成混合主表。

WorkBuddy 在第三个代码批次中展示了两个确定性失败：100 ms 预算被候选超时覆盖到约 1 s；快速成功连接因无缓冲通道的 `select default` 被关闭。最终代码和回归分别修复有效预算传播与结果交接。relay 的旧行为采用特征化测试，未实际等待旧版完整两分钟超时。

## 4. Codex 独立执行的最终验证

以下命令在 WorkBuddy 第三个代码批次完成、代码冻结后，由 Codex 执行。随后 WorkBuddy 只收尾文档。

| 检查 | 结果 | 适用范围 |
| --- | --- | --- |
| `go test -race -count=1 ./...` | exit 0 | macOS 本机单元/集成回归，含本机 socket 场景 |
| `go vet ./...` | exit 0 | Go 静态检查 |
| `go build ./...` | exit 0 | 当前 macOS 构建 |
| `python3 scripts/test_bench_summary.py` | 4 项通过 | 汇总 CLI 的正常、冲突、重复及失败尝试场景 |
| `GOOS=windows GOARCH=amd64 go build … ./cmd/beam` | exit 0 | Windows x64 交叉编译；未在 Windows 启动运行 |

Go 测试输出：

```text
ok  beam/cmd/beam          1.963s
?   beam/internal/discover [no test files]
ok  beam/internal/link     2.475s
ok  beam/internal/proto    1.813s
ok  beam/internal/relay    2.898s
?   beam/internal/secure   [no test files]
ok  beam/internal/session  2.284s
?   beam/internal/webui    [no test files]
```

交叉编译的临时 Windows x64 文件 SHA-256 为 `3b00f2ca74b60355e0acb8a87eb164d930bb45632367d3a8aa84d08406803f57`。该临时文件已随验证临时目录清理，本轮没有作为发行包交付。

### 原始 CSV 完整性

第 2 轮返工前保存的哈希基准与最终文件逐项一致，三份文件共 28 条数据，表头/记录均为历史 17 列格式。

| 文件 | 数据行数 | SHA-256 |
| --- | ---: | --- |
| `campus.csv` | 7 | `4ae3cb6dc21aadd6c6a1069edc40356104863c8d0db260dbd7c37a8a0a61aeb4` |
| `hotspot.csv` | 6 | `6936c4f1302723bc7ba8d86b8279f7b084e90a7e5d05f56e7037d7c83a065d85` |
| `loopback.csv` | 15 | `18a46bf19a9c4bf31299bbb27b5bfee7dd2825c4b19bf2937c3a3862b36a686c` |

## 5. 研究解释的修订

- [paper-plan.md](paper-plan.md) 已明确为历史探索评估，执行入口回到两份 12 周计划。
- [实验记录](2026-11-02-experiments.md) 和[配对记录](../beam/bench-results/paired-upgrade.md) 不再把 5 对传输吞吐当作升级零成本或等价的证明；协商启动成本需另测。
- 热点样本改为 Mac 客户端到 Windows 热点宿主的跨设备传输，实际转发路径和反向超时根因保持待验证。
- 去掉将回环差异直接归因为软件组件开销、将不同文件规模的吞吐变化直接归因为时间漂移的解释。
- [G1 证据与操作说明](g1-evidence-2026-11-02.md) 区分当前观察、未验证能力与后续步骤；能力失败不会自动转化为可发表测量稿。

## 6. 下一步与未完成范围

1. Windows 执行 G1 文档第 5 节的只读能力采集，补原始输出、接口/路由和蓝牙适配器信息。
2. 根据实际支持情况验证 G1a：无外部上游网络条件下建立临时链路，完成两方向文件传输并记录全过程。
3. 分别验证 G1b 的控制消息、重连以及与 AP 建立过程共存；G1a 成功不能代替 G1b。
4. 在两机真实链路验收新的测量口径。当前 `bench` 明确只支持单一目标模式，组合目标会被拒绝；组合回退的正式基准仍需后续工作。
5. 新增 trial ID 目前用于本地测量记录，不等于已经实现协议传递的两端事件关联。正式实验前仍需按实验协议完成接收侧事件关联与起始状态验收。

当前研究状态：测量基础工具经过本地回归，G1a/G1b 尚未通过，正式实验尚未开始。代码和报告均未作为已验证研究成果发布。
