import Foundation

/// 输入源类型。
enum InputSourceKind {
    case file
    case system
}

/// 音频引擎：一路输入 → N 路独立输出通道。
///
/// 两种输入共用同一条分发路径：
///   本地文件（FileSource）  ┐
///                          ├─▶ 交错立体声 float32 ─▶ 每一路自己的环形缓冲
///   系统音频（SystemTapSource）┘
/// 输入之间的差别只在「谁按什么节奏把数据推过来」，下游的漂移补偿、均衡、增益完全一致。
///
/// 通道数量由界面决定（当前上限 3）。通道与槽位一一对应：槽位没有设备时该通道不启动，
/// 其余通道照常出声——这样插拔单副耳机不会打断别人。
final class AudioEngine {

    private(set) var channels: [OutputChannel] = []
    private(set) var isRunning = false
    private(set) var sourceDescription = "未启动"
    private(set) var sourceRate: Double = 48_000
    private(set) var sourceKind: InputSourceKind?
    private(set) var systemHasReceivedAudio = false

    /// 最近一次启动时哪几路没能起来（索引 → 原因）。部分失败不阻止其余通道工作。
    private(set) var channelFailures: [Int: String] = [:]

    var onLog: ((String) -> Void)?
    var onStopped: (() -> Void)?

    private var fileSource: FileSource?
    private var systemSource: SystemTapSource?

    /// 通道名用 A / B / C …，与界面上的标记一致。
    static func channelLabel(_ index: Int) -> String {
        guard index >= 0, index < 26 else { return "\(index + 1)" }
        return String(Character(UnicodeScalar(UInt8(65 + index))))
    }

    /// 调整通道数量。数量不变时不动现有单元（避免无谓地重建 AUHAL）。
    func configure(channelCount: Int) {
        let count = max(1, channelCount)
        guard count != channels.count else { return }

        stop()
        channels = (0..<count).map { OutputChannel(label: Self.channelLabel($0)) }
    }

    func channel(at index: Int) -> OutputChannel? {
        channels.indices.contains(index) ? channels[index] : nil
    }

    // MARK: - 本地文件

    func start(fileURL: URL, devices: [AudioDevice?], loop: Bool) throws {
        stop()
        try ensureChannelCount(devices.count)

        let source = try FileSource(url: fileURL)
        source.loop = loop

        startChannels(sourceRate: source.sampleRate, devices: devices)

        if channels.filter({ $0.isRunning }).isEmpty {
            let reason = channelFailures.values.first ?? "没有可用的输出端点"
            throw AudioError.setupFailed(reason)
        }

        source.onBuffer = { [weak self] samples, frames in
            guard let self else { return }
            for channel in self.channels {
                channel.push(samples, frames: frames)
            }
        }

        source.onFinished = { [weak self] in
            guard let self, self.isRunning else { return }
            self.stop()
            self.onStopped?()
        }

        fileSource = source
        sourceKind = .file
        isRunning = true
        sourceDescription = fileURL.lastPathComponent

        source.start()

        onLog?("已开始分发文件：\(sourceDescription) · \(Int(sourceRate)) Hz → \(channels.count) 路")
    }

    // MARK: - 系统音频

    func startSystemAudio(devices: [AudioDevice?], scope: SystemTapSource.Scope = .allApps) throws {
        stop()
        try ensureChannelCount(devices.count)

        let tap = SystemTapSource()
        // 先 prepare 再起输出通道：采集端的采样率决定环形缓冲的读步长。
        try tap.prepare(scope: scope)

        startChannels(sourceRate: tap.sampleRate, devices: devices)

        // 一个通道都没起来就没什么可跑的了，把 tap 收掉并如实报错。
        if channels.filter({ $0.isRunning }).isEmpty {
            tap.stop()
            let reason = channelFailures.values.first ?? "没有可用的输出端点"
            throw AudioError.setupFailed(reason)
        }

        tap.onBuffer = { [weak self] samples, frames in
            guard let self else { return }
            for channel in self.channels {
                channel.push(samples, frames: frames)
            }
        }

        do {
            try tap.start()
        } catch {
            for channel in channels { channel.stop() }
            throw error
        }

        systemSource = tap
        sourceKind = .system
        isRunning = true
        sourceDescription = "系统声音（所有 App）"

        onLog?("已开始分发系统声音（\(tap.scopeDescription)）· \(Int(sourceRate)) Hz / \(tap.channelCount) ch → \(channels.count) 路")
    }

    // MARK: - 运行中接管

    /// 运行中给某一路接上新设备（热插拔自动接管）。其他通道不受影响。
    func attach(device: AudioDevice, at index: Int) throws {
        guard channels.indices.contains(index) else { return }

        let channel = channels[index]
        guard !channel.isRunning else { return }

        try channel.start(device: device, sourceRate: sourceRate)
        dcLog("channel \(Self.channelLabel(index)) attached to \(device.name)")
    }

    /// 运行中断开某一路（设备被拔掉）。只停这一路，别的不动。
    func detach(at index: Int) {
        guard channels.indices.contains(index) else { return }
        channels[index].stop()
        channelFailures.removeValue(forKey: index)
        dcLog("channel \(Self.channelLabel(index)) detached")
    }

    // MARK: - 公共

    func stop() {
        let wasRunning = isRunning

        // 先断源头再关输出：反过来的话，采集端会在输出单元销毁期间继续往环形缓冲里灌数据。
        fileSource?.stop()
        fileSource = nil

        systemSource?.stop()
        systemSource = nil

        for channel in channels { channel.stop() }

        isRunning = false
        sourceKind = nil
        sourceDescription = "未启动"
        channelFailures = [:]

        if wasRunning {
            onLog?("已停止分发。")
        }
    }

    /// 刷新「系统音频是否真的采到了声音」，供界面判定权限/静音状态。
    func refreshSystemAudioFlag() {
        systemHasReceivedAudio = systemSource?.hasReceivedAudio ?? false
    }

    // MARK: - 内部

    private func ensureChannelCount(_ count: Int) throws {
        if channels.count != count {
            configure(channelCount: count)
        }

        guard channels.count == count else {
            throw AudioError.setupFailed("通道数（\(channels.count)）与槽位数（\(count)）不一致")
        }
    }

    /// 逐个启动有设备的通道。单个端点失败只记进 channelFailures，不影响其他通道——
    /// 一副蓝牙耳机没连上，不该让整台机器的分发都停掉。
    private func startChannels(sourceRate rate: Double, devices: [AudioDevice?]) {
        let usableRate = rate > 0 ? rate : 48_000
        sourceRate = usableRate
        channelFailures = [:]

        for (index, device) in devices.enumerated() {
            guard let device, channels.indices.contains(index) else { continue }

            do {
                try channels[index].start(device: device, sourceRate: usableRate)
            } catch {
                channelFailures[index] = error.localizedDescription
                dcLog("channel \(Self.channelLabel(index)) start failed: \(error.localizedDescription)")
            }
        }
    }
}
