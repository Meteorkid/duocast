# 在 Windows 上实现「隔空投送」：可行性边界

结论先行：**不是不可能，而是必须先解决 L2（链路层），不是协议层。**
AWDL 协议本身已被逆向并有参考实现（OWL / OpenDrop），瓶颈在于 Windows 没有等价于 Linux `nl80211` 的接口，拿不到「monitor 模式 + 任意帧注入 + 信道切换」这三项能力。

---

## 一、分层看，缺的到底是哪一层

| 层 | AirDrop 的做法 | macOS | Linux | Windows |
| --- | --- | --- | --- | --- |
| L2 链路 | AWDL：802.11 厂商自定义 action frame，设备在 6/44/149 与当前 AP 信道之间按 availability window 跳频 | 芯片与固件由 Apple 定制，驱动直接支持 | OWL 用 `libpcap` 抓发帧 + `nl80211` 切信道，用户态实现 | **没有对等物**。`NDIS` 不暴露信道调度与原始帧注入 |
| 服务发现 | Bonjour/mDNS，`_airdrop._tcp`，蓝牙 LE 广播唤醒 | 系统自带 | zeroconf 库 | 有 mDNS（Win10 1703+），但**没有 AWDL 接口可挂** |
| 传输 | HTTPS（自签证书 + 联系人证书校验）、`/Ask` 请求 | 系统实现 | OpenDrop（Python，GPL-3.0） | 无 |
| 身份 | Apple ID + 联系人证书 | 系统钥匙串 | 需从 Mac 导出凭据 | 无 |

**关键点：上面三层里，只有 L2 是硬墙。** 其余都能用现成组件拼出来。

---

## 二、Windows 上真的要硬做，需要什么

1. **拿到原始 802.11 帧**：唯一现成路径是 Npcap（WinPcap 后继），安装时必须勾选「Support raw 802.11 traffic (and monitor mode)」。它提供 `pcap_sendpacket` 注入与 monitor 捕获。
   - 代价一：免费版**限 5 台设备且不可再分发**，要随软件发布得买 OEM 授权。
   - 代价二：要装内核级驱动（管理员权限），与「绿色单文件工具」的定位冲突。
2. **网卡得支持主动 monitor 模式 + 帧注入**：OWL 官方推荐 Atheros AR9280，并明确说部分配置只能被动监听（收不到 ACK 会导致每帧重传最多 7 次，吞吐骤降）。
   - 这意味着**不是所有 Windows 机器都能跑**，用户得换网卡。
3. **信道调度**：AWDL 的核心是「在社交信道上短暂驻留、再跳回 AP 信道」，靠的是驱动级定时。Linux 有 `nl80211` 的 channel switch，Windows 没有。
   - 绕法：**用一块专用网卡**（不关联任何 AP）只跑 AWDL，就不需要跳频。代价是用户要插第二块网卡。
4. **上层协议**：可参考 OpenDrop（GPL-3.0，注意传染性）与 OWL（需核对许可证）。这两份代码能省掉逆向的工作量。

---

## 三、有人试过，并且卡住了

- **AirDrop Anywhere**（bakedbean.org.uk，2021 年系列文章）：作者的目标就是「在 Windows 上实现 AirDrop」，用 Npcap + SharpPcap 走同一路线，第一部分结尾自述这条路「eventually turned out to be a dead end」。
- **OpenDrop 官方兼容性表**：macOS ✅（原生 AWDL）、Linux ✅（需 OWL）、**Windows ❌「No AWDL support」**。
- **OWL README**：明确要求「active monitor mode with frame injection」，且不支持虚拟机与 WSL（必须直通物理无线网卡）。

所以「mac→Linux 有、Windows 没有」的真实原因不是没人想，而是 Linux 有 `nl80211` 这个口子，Windows 没有。

---

## 四、如果不碰驱动，怎么达到同样目的

目标拆开其实是两件事：

1. **两台机器不连同一个路由器也能传** → 已有三条链路：网线直连（169.254 链路本地，~110 MB/s）、同一 WiFi、热点（Mac 互联网共享 / Windows 移动热点）。beam 的自动发现 + 加密 + 校验在任意一条上都能跑。
2. **零配置、靠近即传** → 这是「发现」问题，不必依赖 AWDL。可用 **BLE 广播**做靠近发现（macOS CoreBluetooth、Windows WinRT 都有），发现后再通过热点或直连建立数据通道。这条路的工程量是「中等」，且不要求特定网卡。

---

## 五、三条可选路线（按投入排序）

| 路线 | 需要什么 | 结果 | 风险 |
| --- | --- | --- | --- |
| A. 保持现状 | 无 | 三种链路 + 自动发现 + 拖拽，已验证 | 无 |
| B. BLE 靠近发现 + 热点自动化 | 引入跨平台 BLE 库；Windows 侧调 WinRT 开热点 | 「掏出电脑就能看到对方」，接近 AirDrop 的发现体验 | 中等；BLE 库在 Windows 上的成熟度需验证 |
| C. 硬啃 AWDL on Windows | Npcap + 专用网卡 + 移植 OWL 的帧调度 | 真正的协议级互通，能与 iPhone/Mac 原生互传 | 高；依赖硬件、要装驱动、授权成本，且已有前车之鉴 |

**建议：B 是在不牺牲「人人可用」的前提下最接近 AirDrop 体验的方案；C 只在「必须与 iPhone 原生互传」这个需求下才值得。**

---

## 参考

- OWL（seemoo-lab/owl）：AWDL 的开源实现，Linux/macOS，需 monitior + 注入
- OpenDrop（seemoo-lab/opendrop）：AirDrop 上层协议，Python，GPL-3.0
- AirDrop Anywhere（bakedbean.org.uk/posts/2021-05-airdrop-anywhere-part-1）：Windows 上的失败尝试记录
- Npcap（npcap.com）：Windows 原始 802.11 抓发能力与授权条款
- DeepWiki: OpenDrop Limitations and Compatibility（平台支持表）
