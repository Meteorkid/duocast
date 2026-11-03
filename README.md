# DuoCast

把一路音频同时送到多个输出设备 —— 两个人各戴一副耳机，听同一首歌。

同一台机器上把系统声音（或本地文件）复制到 2–3 个输出端点，每一路有独立的音量、延迟补偿和 10 段均衡。macOS 版已可用；Windows 版是独立的 C# 实现，两边不共用 UI 框架。

## 这个仓库里有什么

| 目录 | 内容 | 状态 |
| --- | --- | --- |
| `duocast-mac/` | macOS 客户端（SwiftUI + CoreAudio） | 可用，当前主力 |
| `duocast/` | Windows 客户端（C# / .NET 8 / WPF / NAudio） | 早期实现 |
| `beam/` | 跨网络中转传文件的实验工具（Go），与本产品解耦 | 实验 |
| `docs/` | 研究笔记：双机链路测量、AWDL 可行性、实验协议 | 笔记 |

## macOS 版现在能做什么

- **输入**：系统声音（CoreAudio Process Tap，不装虚拟声卡）或本地音频文件
- **输出**：2–3 路，每路独立音量 / 10 段 EQ / 延迟补偿（对齐蓝牙的 100–200 ms）
- **按 App 采集**：只把某个播放器的声音分出去，微信提示音不会跟着跑
- **设备热插拔**：插上耳机自动接管，拔掉只断那一路，其他继续
- **参数按设备记忆**：每副耳机记住自己的音量、延迟、EQ
- **常驻控制**：菜单栏图标、Dock 右键菜单、全局快捷键（默认 ⌃⌥⌘D，可改）；锁屏/休眠自动停止

细节、实现取舍与实测数据都在 [duocast-mac/README.md](duocast-mac/README.md)。

## 构建（macOS）

需要 macOS 14.2+ 与 Xcode 命令行工具。

```bash
cd duocast-mac
./build.sh            # 产物在 build/DuoCast.app
open build/DuoCast.app
```

命令行自测入口（不需要点界面）：

```bash
./build/DuoCast.app/Contents/MacOS/DuoCast --channels 3 --system   # 三路 + 系统声音
./build/DuoCast.app/Contents/MacOS/DuoCast --tap-apps com.apple.Music --system  # 只采某个 App
./build/DuoCast.app/Contents/MacOS/DuoCast --probe-outputs         # 端点自检：谁真的在拉数据
```

## 一个必须说清的限制

**同一台 Mac 上两副蓝牙耳机不能同时出声。** macOS 的蓝牙栈只维持一路 A2DP 音频，连上第二副会把第一副踢掉；这不是本项目的实现问题，系统自带的「音频 MIDI 设置 › 多输出设备」也一样。

可行的组合：

- 一副有线 + 一副蓝牙 + 内置扬声器（三路，已实测）
- 一副有线 + 一副蓝牙（两路）
- 两副都要无线：给第二副配一个 USB 蓝牙音频发射器，它在系统里是普通 USB 声卡，不再受 A2DP 单路限制

## 许可证

暂未指定许可证，默认保留所有权利。如需复用请先联系作者。
