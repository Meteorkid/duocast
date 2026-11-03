# Windows 侧 AWDL 可行性检查（可直接照做 / 可直接粘贴给助手）

目标：判断这台 Windows 的无线网卡**能否在 monitor 模式下抓到 802.11 管理帧**。
这是「跨生态发现」整条路线唯一的决定性前提——不成立就没必要往下做。

耗时：约 10 分钟。判定结果只有两种，见最后一节。

---

## 一、安装 Npcap（关键选项必须勾）

下载：https://npcap.com/#download （选最新稳定版）

安装时，**必须勾选**这一项：

```
[√] Support raw 802.11 traffic (and monitor mode) for wireless adapters
```

不勾这一项，装完也能抓普通以太网流量，但**抓不到 802.11 帧**，等于白装。

装完确认目录存在：`C:\Windows\System32\Npcap\WlanHelper.exe`

---

## 二、判断网卡是否支持 monitor（这一步决定成败）

以**管理员身份**打开 PowerShell：

```powershell
cd C:\Windows\System32\Npcap
.\WlanHelper.exe "Wi-Fi" modes
```

**判据**：

- 输出里包含 `monitor` → 有戏，继续第三步；
- 只有 `managed` / `auto` → **这台机器的网卡不支持**，这条路到此为止（可换 USB 无线网卡，找 Atheros AR9271/AR9280 这类明确支持注入的型号）。

> 网卡名不一定是 `Wi-Fi`，先用 `netsh wlan show interfaces` 或
> `Get-NetAdapter | Where-Object PhysicalMediaType -eq "Native 802.11"` 确认真实名称。

---

## 三、切到 monitor 模式并抓包

```powershell
# 1. 切 monitor（会短暂断网，正常）
.\WlanHelper.exe "Wi-Fi" mode monitor

# 2. 确认已切换
.\WlanHelper.exe "Wi-Fi" mode
```

然后用 **Wireshark**（同样依赖上面装的 Npcap）：

1. 选无线网卡，双击开始抓包；
2. 抓包选项里确认「Monitor mode」已启用，信道设为 **44**（或 6 / 149，AWDL 的三个社交信道）；
3. 让一台 iPhone 打开 AirDrop（控制中心长按网络卡片 → AirDrop → 对所有人），屏幕点亮，靠近这台电脑；
4. 抓 30 秒，停止，保存为 `C:\awdl.pcap`。

如果没装 Wireshark，也可以用命令行：

```powershell
cd C:\Windows\System32\Npcap
.\dumpcap.exe -i "Wi-Fi" -a duration:30 -w C:\awdl.pcap
```

---

## 四、抓完必须切回正常模式

```powershell
.\WlanHelper.exe "Wi-Fi" mode managed
```

不切回来会一直断网。

---

## 五、怎么判断「抓到了」

在 Wireshark 里打开 `C:\awdl.pcap`，应用显示过滤器：

```
wlan.fc.type_subtype == 0x0d
```

这是 **Action 帧**（AWDL 的发现帧就是 action frame）。再叠加 Apple 的 OUI：

```
wlan.fixed.category_code == 127 || wlan.oui == 0x002500
```

**判据**：

| 现象 | 含义 |
| --- | --- |
| 有 action 帧，且能看到 `00:25:00` 开头的 MAC 或 vendor 字段为 Apple | ✅ 决定性成功，阶段二成立 |
| 有 802.11 帧但全是 Beacon/Probe（来自路由器） | ⚠️ monitor 模式可用，但没抓到 AWDL——检查信道是否为 6/44/149、iPhone 是否真的开了 AirDrop |
| 完全没有 802.11 帧，只有以太网帧 | ❌ monitor 模式未生效，或有另一块网卡在承载流量 |

**需要回传的内容**（三条就够）：

1. `WlanHelper.exe "Wi-Fi" modes` 的完整输出；
2. 抓包文件里 `wlan.fc.type_subtype == 0x0d` 的**帧数**；
3. 若有，贴一条 action 帧的 MAC 层摘要（Wireshark 里右键 → Copy → Summary as Text）。

---

## 六、给 Windows 上的助手用的提示词（可直接粘贴）

```
我在一台 Windows 11 笔记本上做无线抓包验证，目标设备是一台开着 AirDrop 的 iPhone。

请按顺序帮我完成，每步执行后把原始输出贴给我：

1. 检查是否已安装 Npcap，以及 WlanHelper.exe 是否存在：
   dir C:\Windows\System32\Npcap\WlanHelper.exe

2. 列出所有无线网卡的真实名称：
   Get-NetAdapter | Where-Object PhysicalMediaType -eq "Native 802.11" | Format-Table Name,InterfaceDescription,Status

3. 用上一步得到的网卡名，查询它支持的 monitor 能力：
   cd C:\Windows\System32\Npcap
   .\WlanHelper.exe "<网卡名>" modes

   如果输出里没有 monitor，请立刻停止，并告诉我这台机器的网卡不支持。

4. 如果支持，切到 monitor 模式并确认：
   .\WlanHelper.exe "<网卡名>" mode monitor
   .\WlanHelper.exe "<网卡名>" mode

5. 用 dumpcap 抓 30 秒包并保存：
   .\dumpcap.exe -i "<网卡名>" -a duration:30 -w C:\awdl.pcap

6. 抓完后无论如何都执行（恢复上网）：
   .\WlanHelper.exe "<网卡名>" mode managed

7. 统计抓到的 action 帧数量（有 Wireshark 就用图形界面过滤 wlan.fc.type_subtype == 0x0d；
   没有就用 tshark）：
   tshark -r C:\awdl.pcap -Y "wlan.fc.type_subtype == 0x0d" | measure-object -line

请特别注意：
- 第 3 步的结果决定要不要继续，没 monitor 就直接结束。
- 第 6 步必须执行，否则电脑会一直断网。
- 抓包期间我会让 iPhone 打开 AirDrop 并靠近电脑。
```

---

## 七、如果这一步失败

不要尝试在这台机器上继续。可行的替代只有两条：

1. **换一块支持 monitor + 帧注入的 USB 无线网卡**（AR9271/AR9280 系，几十元），重跑第二节；
2. **放弃「Windows 直接看见 AWDL」这条线**，转做链路协商层（阶段三），或退回「两台装同一个 App」的应用层方案。

记录下失败原因（哪一步、什么输出），这个负结果本身对论文的「可行性边界」一节是有价值的。
