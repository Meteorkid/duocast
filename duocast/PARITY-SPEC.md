# Windows 版功能对齐规格（对齐 macOS v0.1.1）

> 目标：Windows 版在**用户可见行为**上与 macOS v0.1.1 一致。平台内部实现允许不同，验收以行为为准。
> 基准版本：macOS `v0.1.1`（tag，提交 `5d9fd2e`）。mac 侧细节见 `duocast-mac/README.md`。

---

## 1. 范围

### 1.1 本规格覆盖

| 编号 | 能力 | 优先级 |
| --- | --- | --- |
| F1 | 多路输出（1–3 路，默认 2） | P0 |
| F2 | 每路独立参数：音量 / 静音 / 延迟 / 10 段 EQ | P0 |
| F3 | 输入源：系统声音 / 本地文件 | P0 |
| F4 | 参数持久化 | P0 |
| F5 | 设备热插拔自动接管 | P1 |
| F6 | 按 App 采集 | P1 |
| F7 | 托盘常驻 + 全局快捷键 + 锁屏自动停止 | P1 |
| F8 | 每路「是否真的在出声」诊断 + CLI 自检 | P1 |

### 1.2 明确不做

- **两副蓝牙耳机同时出声**：macOS 与 Windows 都做不到（系统只维持一路 A2DP 链路）。与 mac 版保持一致：两路都选蓝牙时给提示，不假装成功。
- **按 App 调音量**：macOS 端尚未发布，不在本次对齐范围。
- **虚拟声卡驱动**：本产品不提供，也不要求用户安装（见 5.1 的取舍）。

---

## 2. 现状盘点（`duocast/` C# 工程）

工程现状：.NET 8 / WPF / NAudio 2.2.1，共 3591 行。结构与 mac 版已同构，**不需要推倒重来**。

| 能力 | 现状 | 差距 |
| --- | --- | --- |
| 通道模型 | `AudioEngine.ChannelA` / `ChannelB` 写死 | 改为 `List<ChannelOutput>`，全链路去掉 A/B 假设 |
| 每路参数 | 已有 `Volume` / `Muted` / `OffsetMs` / `DriftCompensation` / `BufferMs` | 语义已对齐，见 3.2 |
| 输入源 | 回环（默认设备）/ 采集设备 / 文件 | 缺按 App 采集；缺「系统声音且不重复播放」 |
| EQ | `TenBandEqualizer`（10 段 RBJ peaking） | 已与 mac 同参数（31 Hz–16 kHz，Q=1.41），无需改 |
| 持久化 | `AppSettings` + `SettingsStore`（JSON） | A/B 平铺，需改为按设备 ID 存 |
| 热插拔 | 无 | 需 `IMMNotificationClient` |
| 常驻/快捷键 | 无 | 需托盘图标 + `RegisterHotKey` |
| 诊断/CLI | 无 | 需渲染帧计数 + 命令行参数 |

**结论**：M1（多路 + 设置模型）是结构性改造，M2 之后是增量功能。

---

## 3. 行为契约（验收以此为准）

### 3.1 通道模型

| 项 | 规格 |
| --- | --- |
| 通道数 | 1–3，默认 2；可增删，**上限 3** |
| 增删的副作用 | 停止分发（引擎通道数组要重建），界面提示「请重新开始」 |
| 通道命名 | A / B / C |
| 通道与设备 | 一通道绑定一端点；设备数少于通道数时**多余通道留空**，不重复绑定同一设备 |
| 顺序 | 顺序即界面顺序，与设备优先级无关 |

### 3.2 每路参数

| 参数 | 范围 | 步进 | 默认 | 持久化 |
| --- | --- | --- | --- | --- |
| 音量 | 0–120 %（>100 % 为数字增益，允许削波，界面显示 dB） | 1 % | A=78 %，其余 52 % | 是（按设备） |
| 静音 | 开/关 | — | 关 | **否** |
| 延迟 | 0–300 ms | 5 ms | 0 | 是（按设备） |
| 10 段 EQ | 每段 ±12 dB，频点 31/62/125/250/500/1k/2k/4k/8k/16k | 0.5 dB | 全 0 | 是（按设备） |
| EQ 总开关 | 开/关 | — | 开 | 是（全局） |

**静音不持久化**：静音是临时动作，下次启动突然没声音，用户第一反应是「软件坏了」。mac 版如此，Windows 版照做。

**延迟的语义**：给**这一路**额外增加的延迟。蓝牙比有线慢 100–200 ms，所以延迟加在有线/内置扬声器那几路上，不是加在蓝牙上。界面提示文案必须写对方向。

### 3.3 输入源

| 模式 | 行为 |
| --- | --- |
| 系统声音 | 采集系统正在播放的混合音频；切换输入源会停止分发 |
| 本地文件 | 支持 NAudio 可解码格式；单声道自动转立体声；>2 声道拒绝并提示；可选循环 |

文件播完且未开循环：停止分发，状态栏显示「播放结束」。

### 3.4 采集范围（F6）

| 项 | 规格 |
| --- | --- |
| 全部 App | 整机混音（默认） |
| 指定 App | 只采选中进程树的音频；可多选 |
| 列表内容 | 当前有音频会话的进程；**正在出声的排在前面**并标注 |
| 选定 App 无会话 | 启动直接报错「选定的 App 当前没有音频活动」，**不得静默输出静音** |
| 范围变更 | 停止分发，需重新开始 |
| 自身进程 | 必须排除（否则自激，见 6.2） |

### 3.5 设备热插拔（F5）

| 事件 | 期望行为 |
| --- | --- |
| 新设备接入 | 有空槽则自动绑定，并**在运行中直接接入**，不打断其他通道 |
| 某路设备被拔掉 | 只断开该路，其他继续；该路显示「等待设备接入」 |
| 先后顺序 | 同一轮里既有新增又有移除时，按「先断后接」处理 |
| 去抖 | 300–400 ms（一次插拔会连发多条通知） |
| 无变化的通知 | 忽略，不得刷状态栏 |
| 空槽 + 无空闲设备 | 什么都不做 |

排序：系统默认设备优先。新接入的蓝牙耳机通常被系统设为默认输出，于是优先被空槽接住。

### 3.6 参数记忆（F4）

- 键 = 端点的**稳定 ID**（`MMDevice.ID`，形如 `{0.0.0.00000000}.{guid}`），不是序号、不是友好名。
- 首次见到的设备：以该槽当前参数为初值写入，保证「先调后记」与「先记后调」收敛到同一状态。
- 只有槽位绑定到**不同设备**时才重新加载参数；否则 20 Hz 的指标刷新会把用户正在拖的滑杆拽回去。
- 全局项单独存：通道数、EQ 总开关、采集范围、快捷键、锁屏行为。

### 3.7 常驻与快捷键（F7）

| 项 | 规格 |
| --- | --- |
| 托盘图标 | 常驻；运行中与待机图标要区分；菜单含状态摘要、开始/停止、显示主窗口、退出 |
| 关窗口 | **不退出进程**；点托盘或任务栏图标可恢复窗口 |
| 全局快捷键 | 默认 `Ctrl+Alt+Shift+D`（mac 是 `⌃⌥⌘D`；`Ctrl+Alt+D` 易与输入法/浏览器冲突）；可改，冲突时保持原组合并提示 |
| 锁屏/休眠 | 自动停止；**唤醒后不自动恢复** |

### 3.8 诊断（F8）

每路要有「**设备是否真在拉数据**」的判据，而不是「流是否启动成功」。mac 上蓝牙链路被挂起时 `AudioOutputUnitStart` 照样成功、回调却一次不来；Windows 同样存在「渲染流正常但设备无输出」。

- 实现：渲染线程累加**已渲染帧数**；启动 1 秒后若为 0，判定「无数据流」，卡片转警示色并在状态栏说明。
- 指标：每路电平、欠载毫秒、漂移修正 ppm，20 Hz 刷新。

---

## 4. 平台映射（mac API → Windows API）

| macOS | Windows 对应 | 备注 |
| --- | --- | --- |
| `AudioHardwareCreateProcessTap` | `ActivateAudioInterfaceAsync` + `AUDIOCLIENT_ACTIVATION_PARAMS` | 见 5.2，有版本门槛 |
| `muteBehavior = .mutedWhenTapped` | 无直接等价 | 见 5.1，最大的行为差异 |
| `kAudioHardwarePropertyDevices` 监听 | `IMMNotificationClient` | `MMDeviceEnumerator.RegisterEndpointNotificationCallback` 可直接挂 |
| `kAudioDevicePropertyDeviceUID` | `MMDevice.ID` | 稳定 ID，用作参数键 |
| 每路独立 `AUHAL` | 每路独立 `WasapiOut`（共享模式） | 已有 `ChannelOutput` |
| 读步长重采样 + 漂移补偿 | 同上（现有 ASRC） | 共享模式下 WASAPI 也重采样，但每路仍需自己的缓冲与补偿 |
| `NSStatusItem` | 托盘 `NotifyIcon`（H.NotifyIcon.Wpf 或 WinForms 互操作） | WPF 无内置 |
| Carbon `RegisterEventHotKey` | `RegisterHotKey` + `WM_HOTKEY` | 无需额外权限 |
| `willSleep` / `screenIsLocked` | `SystemEvents.PowerModeChanged` / `SessionSwitch(SessionLock)` | |
| `NSWorkspace` 打开目录 | `Process.Start("explorer.exe", …)` | |

---

## 5. 四个必须先想清楚的差异

### 5.1 【硬点】原声会重复播放

mac 版采集系统音频时，被采集的进程在读取期间被静音（`mutedWhenTapped`），不会三重播放。

**Windows 回环采集没有这个语义**：`WasapiLoopbackCapture` 只是复制一份正在播放的音频，原声继续从原设备输出。不处理的话，用户会听到「主音箱 + 耳机 A + 耳机 B」三份声音。

| 方案 | 做法 | 代价 |
| --- | --- | --- |
| **A. 静音原输出会话** | 采集后把目标进程的音频会话 `ISimpleAudioVolume.SetMute(true)`，停止时恢复 | 无需驱动；但「全部 App」模式要枚举所有会话逐个静音，新会话要补挂；用户自己调过静音时可能改乱，需记录原状态 |
| **B. 引导指向虚拟设备** | 装 VB-CABLE，把系统默认输出指过去，采集该设备回环 | 行为干净、最接近 mac；但要求装驱动，与「零安装」不一致 |
| **C. 接受原声** | 不处理，界面说明 | 最简单，但语义退化，**不可接受** |

建议：**A 为主路径，B 作为高级选项保留**（现有代码已支持采集指定设备）。

### 5.2 【硬点】按 App 采集 = 进程回环，有版本门槛

- 官方要求：**Windows 10 Build 20348 及以上**（Windows 11 全系满足）。
- 设备路径是保留标识符 `VAD\Process_Loopback`，通过 `ActivateAudioInterfaceAsync` 激活，`PROPVARIANT` 里放 `AUDIOCLIENT_ACTIVATION_PARAMS`。
- 两种模式都要用：include（只采选定 App）、exclude（全部 App 但排除自己）。
- **NAudio 2.2.1 不封装该 API**，需自写 COM 互操作。两个已知坑：
  1. 完成回调对象必须**同时实现 `IAgileObject`**，否则返回 `E_ILLEGAL_METHOD_CALL` 且无任何提示。
  2. 采集格式可自行指定（`IAudioClient.Initialize` 传目标 `WAVEFORMATEX`），不必跟随设备混音格式。
- 降级：版本不足时把「指定 App」置灰并说明，**不要**悄悄退化成「全部 App」。

### 5.3 重采样与时钟

mac 上每路 AUHAL 独立时钟，读步长 `step = 源率/设备率 × (1+修正)` 同时做重采样与漂移补偿。

Windows 共享模式下 WASAPI 自己会重采样到设备混音格式，但**不能省掉每路缓冲**：三路各自独立时钟，同一份数据推给三个 `WasapiOut`，消费速度不同，仍需每路环形缓冲 + 漂移补偿（`ChannelOutput` 已具备）。

注意：共享模式实际延迟比 mac 大，`BufferMs` 默认值要在 Windows 上实测后重新定标，不要直接沿用 50。

### 5.4 设备 ID 的稳定性

`MMDevice.ID` 插拔同一物理端点后通常不变，但以下情况会变：卸载重装驱动、USB 声卡换口、蓝牙重新配对。以它为准即可，但要有兜底——ID 变化时按「首次见到的设备」处理，不要让程序崩。

---

## 6. 建议架构

### 6.1 数据流

```
WASAPI 采集（回环 / 进程回环）   本地文件（AudioFileReader）
        │                              │
        └──────────┬───────────────────┘
                   ▼
        统一转成 交错立体声 float32（复用 SampleConverter）
                   ▼
        ┌──────────┼──────────┐
        ▼          ▼          ▼
   通道 A 缓冲  通道 B 缓冲  通道 C 缓冲   ← 各自环形缓冲 + 读步长补偿
        ▼          ▼          ▼
     EQ→增益→延迟→WasapiOut(设备A/B/C)
```

### 6.2 线程模型

- 采集回调只做「转换 + 分发到各环形缓冲」，不做阻塞操作。
- 每路 `WasapiOut` 自己拉数据（NAudio 的 push 模型）。
- 自激防护：进程回环必须排除本进程（`PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE`）。mac 上忘记排除自身时峰值 4 秒内从 0.55 飙到 344；Windows 上同样会发生且更难察觉。

### 6.3 代码改动落点

| 文件 | 改动 |
| --- | --- |
| `Audio/AudioEngine.cs` | `ChannelA/ChannelB` → `List<ChannelOutput>`；`Start*` 接受设备数组（`null` 表示空槽）；新增 `Attach/Detach` |
| `Audio/ChannelOutput.cs` | 新增 `RenderedFrames` 计数（供 3.8 判活）；其余已就绪 |
| `Audio/Devices.cs` | `DeviceEntry` 补 `IsBluetooth` 与排序；新增 `EndpointWatcher` 实现 `IMMNotificationClient` |
| `AppSettings.cs` | A/B 平铺字段 → `List<ChannelState>` + `Dictionary<string, DeviceSettings>` |
| `MainWindow.xaml` / `.cs`（751 行） | 双通道写死 → `ItemsControl` 动态生成通道卡 |
| 新增 | `Audio/ProcessLoopbackCapture.cs`、`Tray/TrayIcon.cs`、`Platform/GlobalHotKey.cs`、`Platform/PowerWatcher.cs`、`Cli/Probe.cs` |

---

## 7. CLI 自检参数

| 参数 | 作用 |
| --- | --- |
| `--system` | 系统声音输入并自动开始 |
| `--play <file>` | 本地文件输入并自动开始 |
| `--channels <1-3>` | 指定通道数 |
| `--tap-apps <pid,pid>` | 只采这些进程（Windows 用 PID；mac 用 bundle ID） |
| `--probe-outputs` | 端点自检：逐个 / 同时打开所有输出端点，报告「是否真在拉数据」 |
| `--close-window <秒>` | 自测：N 秒后关窗口，验证「关窗不退出」 |

`DUOCAST_DEBUG=1` 时每秒向 stderr 输出一行指标，格式与 mac 一致：

```
metrics peak A 0.3196 B 0.1771 C 0.2130 | underrun A 0.0 B 0.0 C 0.0 ms | drift A +116 B +20 C +116 ppm
```

---

## 8. 分阶段计划与验收

### M1 · 结构改造（多路 + 设置模型）

- [ ] 通道数可增删（1–3），增删后提示重新开始
- [ ] `AppSettings` 迁移为按设备存储；旧版配置能平滑读取
- [ ] 界面按通道数动态生成卡片

**验收**：2 路、3 路都能同时出声；重启后参数与通道数保持。

### M2 · 采集能力（系统声音不重复 + 按 App）

- [ ] 系统声音模式下原输出不再重复出声（方案 A）
- [ ] 按 App 采集可用；选定 App 无会话时报错而非静音
- [ ] 低于 Build 20348 时置灰并说明

**验收**：只选 A 应用时，B 应用放歌采到的电平恒为 0；选 A 时电平正常。

### M3 · 设备与参数记忆

- [ ] 插拔自动接管，运行中不停分发
- [ ] 参数按设备记忆，换回来自动恢复

**验收**：播放中拔掉耳机 A → 只有 A 停、B 继续；插回 → A 自动恢复且参数是它自己的。

### M4 · 常驻与诊断

- [ ] 托盘 + 菜单 + 全局快捷键
- [ ] 关窗不退出；锁屏/休眠自动停止
- [ ] 每路「无数据流」告警 + `--probe-outputs`

**验收**：关窗后快捷键仍能启停；锁屏后分发停止。

---

## 9. 验收清单（可直接勾）

| # | 场景 | 通过标准 |
| --- | --- | --- |
| 1 | 两路同时播放 | 两路都出声，欠载 < 1 ms（连续 10 分钟） |
| 2 | 三路同时播放 | 同上，CPU 不随路数线性飙升 |
| 3 | 音量 0–120 % | 120 % 约 +1.6 dB，界面 dB 显示正确 |
| 4 | 延迟 0–300 ms | 步进 5 ms；加在有线路上能与蓝牙对齐 |
| 5 | EQ 十段 | 每段独立生效，总开关可旁通 |
| 6 | 系统声音 | 任意 App 播放都能分出去；原输出不重复出声 |
| 7 | 按 App 采集 | 未选中的 App 不计入；选中的正常 |
| 8 | 文件输入 | 单声道/立体声均可；播完停止；循环可用 |
| 9 | 热插拔 | 见 3.5 |
| 10 | 参数记忆 | 见 3.6 |
| 11 | 托盘/快捷键 | 见 3.7 |
| 12 | 锁屏 | 自动停止；唤醒不自动恢复 |
| 13 | 无数据流诊断 | 人为断开某路设备，1 秒内该路转告警 |
| 14 | 两路蓝牙 | 给出提示，不静默失败 |

---

## 10. 已知限制（与 mac 版一致，不要试图绕过）

1. 两副蓝牙耳机不能同时出声。
2. 通道上限 3。
3. 增删通道会停止分发。
4. 采集范围只认「当前有音频会话的进程」。
5. 环形缓冲用锁保护，实时线程里严格说不该有锁（后续可换无锁队列）。

---

## 11. 参考资料

- [AUDIOCLIENT_ACTIVATION_TYPE](https://learn.microsoft.com/en-us/windows/win32/api/audioclientactivationparams/ne-audioclientactivationparams-audioclient_activation_type) ——进程回环，最低 Build 20348
- [ActivateAudioInterfaceAsync](https://learn.microsoft.com/en-us/windows/win32/api/mmdeviceapi/nf-mmdeviceapi-activateaudiointerfaceasync)
- Application Loopback API Capture Sample（微软官方示例，含 `IAgileObject` 要求）
- [NAudio 2.2.1](https://github.com/naudio/NAudio)：`WasapiOut`、`WasapiLoopbackCapture`、`MMDeviceEnumerator.RegisterEndpointNotificationCallback`

---

## 12. Windows 侧开发环境

| 项 | 要求 | 检查命令 |
| --- | --- | --- |
| 系统 | Windows 10 Build 20348+ 或 Windows 11 | `winver` |
| SDK | .NET 8 SDK | `dotnet --list-sdks` |
| IDE | Visual Studio 2022（含「.NET 桌面开发」工作负载） | — |
| 运行时依赖 | NAudio 2.2.1（csproj 已声明） | `dotnet restore` |

```powershell
git clone https://github.com/Meteorkid/duocast.git
cd duocast\duocast
dotnet restore
dotnet run
```

跨平台对照时，mac 端的实测数字与踩坑记录在 `duocast-mac/README.md`，遇到「Windows 上行为和 mac 不一样」时先查那份，再看本文 §5。

### 建议的开发顺序

先做 M1 的结构改造（把 A/B 写死的假设去掉），再做 M2 的采集。反过来会返工——按 App 采集一旦引入，设备与通道的对应关系就不再是「两个固定位置」。
