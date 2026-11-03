# 同类开源项目调研

目的：找出「一路音频送多个输出设备 / 每设备独立音量与 EQ」这个问题的既有实现，验证我们的技术选型，并给下一步（macOS 系统音频采集、Windows 免虚拟声卡）找现成路径。

调研时间：2026-11。星标与许可证以仓库当时页面为准。

---

## 一、目标相同的项目

| 项目 | 平台 | 技术栈 | 许可证 | 与我们的关系 |
| --- | --- | --- | --- | --- |
| [App Audio Router](https://github.com/Eververdants/AppAudioRouter) | Windows 10/11 | Tauri + Rust | MIT | 目标完全一致：一个程序的声音送到多个设备，**带每设备音量与延迟补偿**，且**不装虚拟声卡** |
| [Audio Router](https://github.com/emperorzimm/audio-router) | Windows 7+ | C# / WPF | GPL-3.0 | 把指定程序路由到指定设备，含「复制到多个设备」；社区维护版 |
| [JuanJFarina/audio-router](https://github.com/JuanJFarina/audio-router) | Windows 10+ | .NET 10 + WPF + NAudio | 未标注（需确认） | **架构与我们 Windows 版几乎相同**：WASAPI 捕获 → 共享环形缓冲 fan-out → 每输出矩阵/8 段参数 EQ/延迟/漂移校正 |
| [lcsFloriani/audio-router](https://github.com/lcsFloriani/audio-router) | Windows 10/11 | .NET + WPF + NAudio | MIT | 多源多目标混音，**多消费者环形缓冲**，配置按 profile 存 JSON |
| [Background Music](https://github.com/kyleneideck/BackgroundMusic) | macOS 10.13+ | C++ / 用户态音频驱动 | GPL-2.0（19.3k★） | 每应用独立音量 + 系统音频录制；**必须装虚拟驱动**，与本机设备列表里那两个 virtual 端点同源 |
| [eqMac](https://github.com/bitgapp/eqMac) | macOS | Swift + 用户态驱动 + Angular UI | Apache-2.0（公开仓为 v1.3.2） | 系统级 10 段 EQ + 音量增强；同样走虚拟驱动，**每应用音量是其 Pro 功能** |
| [AudioCap](https://github.com/insidegui/AudioCap) | macOS 14.4+ | Swift | BSD-2-Clause | **不是产品，是 CoreAudio Process Tap 的权威样例**，Apple 新 API 没文档，这份代码就是文档 |
| [macos-audio-tap](https://github.com/firedanceio/macos-audio-tap) | macOS 14.4+ | Swift Package | Apache-2.0 | Process Tap 的工程化封装（含权限、私有聚合设备、实时电平），可直接依赖或照抄结构 |

---

## 二、macOS 系统音频：Process Tap 的正确姿势

AudioCap 把 macOS 14.4 新增的接口拆成了可执行步骤，这是我们 macOS 版下一步最该照抄的部分：

1. 拿到目标进程 PID；用 `kAudioHardwarePropertyTranslatePIDToProcessObject` 换成 `AudioObjectID`。
2. 建 `CATapDescription`，拿到它的 `uuid`。
3. `AudioHardwareCreateProcessTap` 创建 tap（本身也是个 AudioObject）。
4. 组装聚合设备字典：`kAudioAggregateDeviceTapListKey` 里放 `[kAudioSubTapUIDKey: uuid]`，并设 `kAudioAggregateDeviceIsPrivateKey = true`，避免它出现在系统设备列表里。
5. `AudioHardwareCreateAggregateDevice` 创建私有聚合设备。
6. 读 `kAudioTapPropertyFormat` 拿 `AudioStreamBasicDescription`，据此建 `AVAudioFormat`。
7. `AudioDeviceCreateIOProcIDWithBlock` 挂 IO 回调，回调里 `AudioDeviceStart` 之前先 `AudioDeviceStart`（原文顺序：先建 IOProc 再 Start）。

`macos-audio-tap` 补充的三条实战经验更关键：

- **全系统捕获**：`CATapDescription` 用空进程列表 + `isExclusive = true` 即为「所有进程」。
- **聚合设备必须一次性建好**：sub-device 列表为空、或创建后再把 tap 加进去，某些机器会在 `AudioDeviceStart` 直接失败（返回 `'nope'`）。
- **权限失败不会报错，只会给静音**：缺「系统音频录制」权限时，`prepare` 照样成功、tap 照样启动，但数据全是 −∞。权限绑定在代码签名上——换签名身份（比如临时 ad-hoc 重签）会重置授权。
- Info.plist 要手动加 `NSAudioCaptureUsageDescription`，这个 key 不在 Xcode 的下拉列表里。

---

## 三、为什么老项目都装驱动

Background Music 和 eqMac 都用一个用户态 AudioServerPlugIn（伪装成一块声卡）来截系统音频。这不是设计偏好，而是**时代限制**：在 macOS 14.4 之前，第三方应用没有任何公开方式拿到系统混音。

今天这条路可以不走：Process Tap 直接在应用内拿到其他进程的音频，不需要装驱动、不需要重启 `coreaudiod`、不需要麦克风权限（要的是「系统音频录制」权限）。我们 macOS 版的价值就在这里。

顺带解释了一个现象：本机设备枚举里出现 `Background Music`、`Audiojingle` 这类 `transport == virtual` 的端点，就是这类驱动装出来的。它们**不能**当作普通输出设备绑定 AUHAL，绑上去会永久卡死——我们已在 `AudioDevices` 里按传输类型过滤。

---

## 四、Windows：两条技术路线

**路线 A：虚拟声卡 + 捕获（我们现在的做法）**

- 播放器输出指向虚拟线（VB-CABLE / VoiceMeeter），我们从虚拟线的录音端捕获，再分发到两个真实设备。
- 优点：任何播放器都适用，实现简单，延迟可控。
- 缺点：用户必须装驱动；WASAPI 回环模式则会「原声再放一遍」。

**路线 B：per-session 路由（App Audio Router / Audio Router 的做法）**

- 直接用 Core Audio 把**某个进程的音频会话**改派到指定端点，不需要驱动。
- App Audio Router 的说明写得很清楚：路由作用于**正在运行**的音频会话，不需要重启程序；停止路由后要把「该程序固定输出设备」这个状态复位，否则程序会一直锁定旧设备（他们在 2.1.1 修的就是这个）。
- 也说明了它的边界：用 ASIO 或 WASAPI 独占模式的程序不会出现在列表里。
- 这条路线上「一源多设备」不是原生能力——Windows 的会话只能指向一个端点，所以他们的做法是「第一个设备由系统原生驱动，其余镜像路径各自单独调」；镜像仍然要靠捕获。

结论：路线 B 不是替换 A，而是**改善用户体验**——可以让用户不用装 VB-CABLE，但镜像分发这一环我们仍然需要自己的缓冲与漂移处理。

---

## 五、对我们代码的对照

| 我们的设计 | 同类项目里的对应 | 判断 |
| --- | --- | --- |
| 共享环形缓冲 fan-out 到多路 | lcsFloriani「Multi-Consumer Ring Buffer」、JuanJFarina「Shared circular source buffer」 | 方向正确，被独立验证 |
| ASRC 漂移校正（改读取速率，不改音高） | JuanJFarina「gentle resample-ratio corrections」 | 方向正确；他们把自动同步**默认关闭**以求稳定，值得借鉴成开关 |
| 每路独立增益 + 10 段 EQ | JuanJFarina 8 段参数 EQ、eqMac 10 段 | 我们的段数与实现均属常规 |
| JSON 配置持久化 | JuanJFarina `%AppData%\AudioRouter\router-config.json`、lcsFloriani profile | 我们 Windows 侧 `AppSettings.cs` 已写未接线；macOS 侧尚未做 |
| 蓝牙延迟补偿 | App Audio Router 的 per-device delay（正向延迟给快的那一路） | 我们只有 Windows 侧的「延迟偏移」，macOS 侧还没有 |
| macOS 虚拟端点过滤 | 无同类项目提及（它们本身就是虚拟端点） | 我们的实测结论，值得写进文档 |

---

## 六、许可证注意

- **GPL-2.0 / GPL-3.0**（Background Music、Audio Router 原版）：可以读思路、读架构，**不要直接复制代码**。一旦复制进本仓库，整个项目就要按 GPL 分发。
- **Apache-2.0**（eqMac 公开部分、macos-audio-tap）：可商用可修改，需保留版权与许可声明；修改过的文件要标注。
- **MIT / BSD-2**（App Audio Router、lcsFloriani、AudioCap）：最宽松，保留声明即可。
- 本仓库目前**没有 LICENSE 文件**，在决定开源前先把这件事定下来，否则后续引入任何第三方代码都会变成隐患。

---

## 七、下一步可以直接落地的三件事

1. **macOS 接 Process Tap**：按 AudioCap 的七步 + `macos-audio-tap` 的三条经验实现「系统音频」输入源；Info.plist 补 `NSAudioCaptureUsageDescription`；权限被拒时必须在界面上明确提示「你现在听到的是静音，不是程序坏了」——这是该 API 最坑的地方。
2. **macOS 启动自检**：如果系统默认输出设备是 `transport == virtual`（即装了 Background Music / eqMac / Loopback），提示用户「默认输出被虚拟设备接管，本程序捕获到的将是它的输出」。
3. **Windows 补完持久化**：`AppSettings.cs` 已写好未接线，接上即可；顺便参考 JuanJFarina 把「自动漂移同步」做成可关闭项。
