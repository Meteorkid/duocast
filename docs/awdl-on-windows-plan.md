# 让 Windows 具备 AWDL：可行性、前置条件与实施蓝图

## 结论

**技术上可以实现，但不是「写协议」，而是在用户态重做一套 Linux 内核子系统的等价物。**
可行性完全取决于三个前提是否同时成立，其中第一个（网卡）决定了后面两个有没有意义。

---

## 一、三个前提

### 1. 网卡必须支持「主动 monitor 模式 + 帧注入」

AWDL 的帧是 802.11 厂商自定义 action frame，普通 socket 拿不到。需要网卡驱动允许：
- 进入 monitor 模式（不是「混杂模式」，是真正的 monitor）；
- 注入任意 802.11 帧；
- 收到帧时不因缺少 ACK 而反复重传。

OWL 官方推荐的是 Atheros AR9280（802.11n）。多数笔记本内置的 Intel/MediaTek/Realtek 网卡**不支持**，或只在特定驱动版本下支持。

> 这一条不成立，后面的工作全部作废。所以先做自检（见第二节）。

### 2. 需要一个能抓发原始帧的驱动层

Windows 上唯一成熟的选择是 **Npcap**（WinPcap 后继，Wireshark 用的就是它）：

- 安装时必须勾选 **"Support raw 802.11 traffic (and monitor mode) for wireless adapters"**；
- 免费版**限 5 台设备、不允许随软件再分发**；要绑定进产品必须买 OEM 授权；
- 需要管理员权限安装内核驱动——这与「绿色单文件工具」的定位冲突。

### 3. 需要一块虚拟 L2 网卡把 AWDL 变成「普通网络接口」

AWDL 跑通后，上层（Bonjour、HTTPS）需要一个 IP 接口才能工作。Linux 上 OWL 用 TUN/TAP；Windows 上对应的是 **TAP-Windows**（OpenVPN 那个 L2 驱动）或自写 NDIS LWF。Wintun 是 L3，不满足要求。

---

## 二、五分钟自检：你的 Windows 网卡到底行不行

在目标 Windows 机器上：

1. 装 Npcap（勾选 raw 802.11 支持），装完在 `C:\Windows\System32\Npcap\` 下有 `WlanHelper.exe`。
2. 查当前模式：

```powershell
WlanHelper.exe "Wi-Fi" mode
```

3. 尝试切到 monitor：

```powershell
WlanHelper.exe "Wi-Fi" mode monitor
```

4. 判断：
   - 返回 `monitor` 或成功切换 → **有戏**，继续第 3 节；
   - 报 `Error: ... not supported` / 切了但抓不到帧 → **这台机器的网卡不行**，要么换 USB 无线网卡（找 AR9271/AR9280 这类明确支持注入的），要么放弃这条路。

5. 切回正常模式（重要，否则断网）：

```powershell
WlanHelper.exe "Wi-Fi" mode managed
```

---

## 三、实施蓝图（如果自检通过）

```
┌──────────────────────────────────────────────┐
│ AirDrop 上层（HTTP /Ask、TLS、Bonjour _airdrop._tcp）│  ← 可参考 OpenDrop（GPL-3.0，注意传染性）
├──────────────────────────────────────────────┤
│ AWDL 核心（帧格式、peer 表、election、时间同步）      │  ← 可参考 OWL 的 src/（C，平台无关部分）
├──────────────────────────────────────────────┤
│ 信道调度（availability window、在社交信道与 AP 信道间切换）│  ← Windows 无对等 API，最硬的一层
├──────────────────────────────────────────────┤
│ 帧收发（monitor + 注入）                             │  ← Npcap
├──────────────────────────────────────────────┤
│ 虚拟 L2 接口（awdl0 等价物）                          │  ← TAP-Windows
└──────────────────────────────────────────────┘
```

### 各层的移植难度

| 层 | 来源 | 工作量 | 风险 |
| --- | --- | --- | --- |
| 帧收发 | Npcap SDK（C）→ cgo 或独立 helper 进程 | 中 | 依赖网卡能力 |
| 虚拟 L2 接口 | TAP-Windows | 中 | 需另装驱动 |
| AWDL 核心 | OWL `src/`（平台无关的 C） | 大：编译 + 时间基准 + 定时器抽象 | 许可证待核对 |
| 信道调度 | 无现成实现 | **最大** | 见下 |
| AirDrop 上层 | OpenDrop（Python） | 中：改写为 Go 或打包 Python | GPL-3.0 传染 |

### 最大的坑：信道调度

AWDL 要求设备在「社交信道」（6 / 44 / 149）与「当前 AP 信道」之间按 availability window 周期性切换，否则既断网又收不到 peer。

- Linux：OWL 用 `nl80211` 的 channel switch 实现；
- macOS：驱动与固件自己做；
- **Windows：NDIS 不暴露这个能力。**

**唯一的绕法**：用**第二块无线网卡**专跑 AWDL，不关联任何 AP，也就不需要跳频。这意味着用户要插两块无线网卡——而绝大多数笔记本只有一块内置的。

---

## 四、这条路买到的是什么

| 目标 | AWDL 移植能否解决 | 有没有更便宜的办法 |
| --- | --- | --- |
| Mac ↔ Windows 传文件 | 不需要，已有网线/热点，速度更快 | `beam` 现有三条链路 |
| **iPhone → Windows 原生投送**（不在手机上装任何 App） | ✅ 这是唯一价值 | 手机上装 LocalSend / 浏览器开 PairDrop |

换句话说：如果你只是想在 Mac 和 Windows 之间传文件，这条路的投入产出比极差；只有当「不接受在 iPhone 上装 App」时，它才值得。

---

## 五、已有的失败先例（务必先读）

- **AirDrop Anywhere**（bakedbean.org.uk，2021 系列文章）：作者目标就是「Windows 上跑 AirDrop」，走 Npcap + SharpPcap 同一路线，第一部分结尾自述这条路 *eventually turned out to be a dead end*。
- **OpenDrop 官方兼容性表**：macOS ✅ / Linux ✅（需 OWL）/ **Windows ❌ No AWDL support**。
- **OWL README**：要求 active monitor mode with frame injection，不支持虚拟机与 WSL。

---

## 六、建议的决策顺序

1. 先跑第二节的自检。**十分钟内就能知道这台 Windows 行不行**，避免投入后才失败。
2. 自检不通过 → 换 USB 无线网卡（成本几十元），或放弃。
3. 自检通过 → 先用 Npcap 写一个最小验证：能否抓到附近 iPhone 的 AWDL action frame（AirDrop 界面打开时会有）。**抓得到再说移植。**
4. 第 3 步成功，再评估是否值得投入 1–3 个月做完整移植。

**不要跳过第 1、3 步直接写代码**——这正是 AirDrop Anywhere 走过的弯路。
