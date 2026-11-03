import AudioToolbox
import CoreAudio
import Foundation

enum TapError: LocalizedError {
    case createTap(OSStatus)
    case readFormat(OSStatus)
    case createAggregate(OSStatus)
    case createIOProc(OSStatus)
    case startDevice(OSStatus)
    case notPrepared
    case noMatchingApp([String])

    var errorDescription: String? {
        switch self {
        case .createTap(let status):
            return "无法创建系统音频采集（\(Self.describe(status))）。请到「系统设置 › 隐私与安全性 › 录屏与系统录音」中允许 DuoCast，然后重启应用。"
        case .readFormat(let status):
            return "读取采集格式失败（\(Self.describe(status))）"
        case .createAggregate(let status):
            return "创建采集聚合设备失败（\(Self.describe(status))）"
        case .createIOProc(let status):
            return "安装采集回调失败（\(Self.describe(status))）"
        case .startDevice(let status):
            return "启动系统音频采集失败（\(Self.describe(status))）"
        case .notPrepared:
            return "采集器尚未准备"
        case .noMatchingApp(let bundleIDs):
            let names = bundleIDs.joined(separator: "、")
            return "选定的 App（\(names)）当前没有音频活动，采不到声音。请先让它播放，或把采集范围改回「全部 App」。"
        }
    }

    /// 把 OSStatus 转成「数字 + 四字符码」，排查时比裸数字有用得多。
    static func describe(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
        guard printable else { return "\(status)" }
        let code = String(bytes.map { Character(UnicodeScalar($0)) })
        return "\(status) \(code)"
    }
}

/// 系统音频输入源：CoreAudio Process Tap（macOS 14.2+）。
///
/// 为什么需要它：DuoCast 的产品形态是「任意 App 播放的声音同时送到两副耳机」，
/// 只支持本地文件等于要用户先把歌下载下来，不成立。
///
/// 为什么不用虚拟声卡（BlackHole / Loopback）：那要求用户安装内核扩展式的驱动，
/// 还得手工把系统输出切过去，任何一个环节错了都是「没声音 + 不知道怎么修」。
/// Process Tap 是系统 API，采集点在进程混音之后、硬件输出之前，不需要驱动。
///
/// 关键设计：
/// 1. 采集点选「全局混音，但排除自己」——否则 DuoCast 输出到两路设备的声音会被自己再采一遍，
///    形成自激。排除自己的依据是进程的 AudioObjectID，不是 PID。
/// 2. `muteBehavior = .mutedWhenTapped`：被采集的进程不再向硬件出声，避免
///    「系统默认设备原声 + DuoCast 两路」三重播放；一旦我们停止读取（退出、崩溃、停止分发），
///    系统自动恢复原状，不会把整机声音卡死在一个失效的 tap 上。
/// 3. 采集端不复制数据，直接把 IOProc 的缓冲指针交给环形缓冲写入，中间不留分配。
final class SystemTapSource {

    /// 采集范围。
    enum Scope {
        case allApps
        case apps([String])   // bundle ID
    }

    private(set) var sampleRate: Double = 48_000
    private(set) var channelCount: Int = 2
    private(set) var isRunning = false
    private(set) var scopeDescription = "所有 App"

    /// 是否采到过非静音数据。用来区分「用户还没开始播放」和「权限没给、拿到的全是零」。
    private(set) var hasReceivedAudio = false

    /// 非交错（每声道一个 buffer）时用来交织的暂存区，按需扩容，不在回调里分配。
    private var interleave: [Float] = []

    private var descriptor: CATapDescription?
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?

    var onBuffer: ((UnsafePointer<Float>, Int) -> Void)?

    deinit {
        stop()
        destroyObjects()
    }

    // MARK: - 生命周期

    /// 建立 tap 与聚合设备，读出采集格式。此时还没有开始收数据。
    /// 分成 prepare / start 两步，是因为输出通道要用采集端的采样率来初始化。
    func prepare(scope: Scope = .allApps) throws {
        stop()
        destroyObjects()

        hasReceivedAudio = false

        let description: CATapDescription

        switch scope {
        case .allApps:
            // 全局混音，但排除自己，否则输出到各路的声音会被自己再采一遍形成自激。
            let excluded = Self.ownProcessObjectID().map { [$0] } ?? []
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
            scopeDescription = "所有 App"

        case .apps(let bundleIDs):
            // 只采选定 App：必须拿到 HAL 进程对象 ID。
            // 用 CATapDescription.bundleIDs 单独指定实测无效（见 AudioProcesses 的注释）。
            var objects = AudioProcesses.processObjects(for: bundleIDs)

            // 同样要排除自己。用户完全可能选中一个和自己同 bundle 的 App（或者选的就是
            // DuoCast 自己），不排除就会自激：本机实测峰值 4 秒内从 0.55 飙到 344。
            if let own = Self.ownProcessObjectID() {
                objects.removeAll { $0 == own }
            }

            guard !objects.isEmpty else {
                throw TapError.noMatchingApp(bundleIDs)
            }

            description = CATapDescription(stereoMixdownOfProcesses: objects)
            scopeDescription = "\(bundleIDs.count) 个 App / \(objects.count) 个进程"
            dcLog("tap scope apps: \(bundleIDs) -> objects \(objects)")
        }

        description.name = "DuoCast System Audio"
        description.isPrivate = true
        // 见类型注释第 2 点：读取期间静音被采集进程，不读取时自动恢复。
        description.muteBehavior = .mutedWhenTapped

        var tap = AudioObjectID(0)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != 0 else {
            throw TapError.createTap(tapStatus)
        }

        descriptor = description
        tapID = tap

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard formatStatus == noErr else {
            destroyObjects()
            throw TapError.readFormat(formatStatus)
        }

        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        channelCount = max(1, Int(format.mChannelsPerFrame))

        let composition: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "duocast-tap-\(UUID().uuidString)",
            kAudioAggregateDeviceNameKey: "DuoCast System Audio",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: 1
            ]]
        ]

        var aggregate = AudioDeviceID(0)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
        guard aggregateStatus == noErr, aggregate != 0 else {
            destroyObjects()
            throw TapError.createAggregate(aggregateStatus)
        }

        aggregateID = aggregate
        dcLog("system tap prepared: \(sampleRate) Hz / \(channelCount) ch, tap=\(tapID) aggregate=\(aggregateID)")
    }

    func start() throws {
        guard aggregateID != 0 else { throw TapError.notPrepared }
        guard !isRunning else { return }

        var proc: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, nil) { [weak self] _, input, _, _, _ in
            self?.consume(input)
        }

        guard createStatus == noErr, let proc else {
            throw TapError.createIOProc(createStatus)
        }

        let startStatus = AudioDeviceStart(aggregateID, proc)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, proc)
            throw TapError.startDevice(startStatus)
        }

        ioProcID = proc
        isRunning = true
        dcLog("system tap started")
    }

    func stop() {
        guard isRunning || ioProcID != nil else { return }

        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }

        ioProcID = nil
        isRunning = false
        dcLog("system tap stopped")
    }

    /// 销毁顺序必须是「先停设备、再销毁聚合、最后销毁 tap」，
    /// 反过来会让 HAL 在聚合设备还引用着已消失的 tap 时崩溃。
    private func destroyObjects() {
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }

        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }

        descriptor = nil
    }

    // MARK: - 数据

    private func consume(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard !list.isEmpty else { return }

        // 交错格式：一个 buffer 里装 2 个声道。
        if list.count == 1 {
            let buffer = list[0]
            guard let raw = buffer.mData else { return }

            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard sampleCount > 0 else { return }

            let pointer = raw.assumingMemoryBound(to: Float.self)

            if channelCount == 1 {
                // 单声道源：复制到左右两声道，否则环形缓冲会把采样当成「帧」读歪。
                let frames = sampleCount
                ensureScratch(frames: frames)
                interleave.withUnsafeMutableBufferPointer { destination in
                    guard let base = destination.baseAddress else { return }
                    for frame in 0..<frames {
                        let value = pointer[frame]
                        base[frame * 2] = value
                        base[frame * 2 + 1] = value
                    }

                    detectAudio(base, count: frames * 2)
                    onBuffer?(UnsafePointer(base), frames)
                }
                return
            }

            let frames = sampleCount / channelCount
            guard frames > 0 else { return }

            detectAudio(pointer, count: frames * 2)
            onBuffer?(UnsafePointer(pointer), frames)
            return
        }

        // 非交错格式：每声道一个 buffer，交织后再送。
        guard let first = list[0].mData else { return }
        let frames = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
        guard frames > 0 else { return }

        ensureScratch(frames: frames)

        interleave.withUnsafeMutableBufferPointer { destination in
            guard let base = destination.baseAddress else { return }

            let left = first.assumingMemoryBound(to: Float.self)
            let right = list.count > 1
                ? (list[1].mData?.assumingMemoryBound(to: Float.self) ?? left)
                : left

            for frame in 0..<frames {
                base[frame * 2] = left[frame]
                base[frame * 2 + 1] = right[frame]
            }

            detectAudio(base, count: frames * 2)
            onBuffer?(UnsafePointer(base), frames)
        }
    }

    private func ensureScratch(frames: Int) {
        let needed = frames * 2
        if interleave.count < needed {
            interleave = [Float](repeating: 0, count: needed)
        }
    }

    /// 找出「有信号」这一事实。阈值取 -120 dBFS 量级，只排除数字静音与极底噪。
    private func detectAudio(_ samples: UnsafePointer<Float>, count: Int) {
        guard !hasReceivedAudio else { return }

        for index in 0..<count where abs(samples[index]) > 1e-6 {
            hasReceivedAudio = true
            return
        }
    }

    // MARK: - 进程标识

    /// 当前进程在 HAL 里的 AudioObjectID。用它把 DuoCast 自己排除在采集之外。
    private static func ownProcessObjectID() -> AudioObjectID? {
        var pid = getpid()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var objectID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &objectID
        )

        guard status == noErr, objectID != 0 else {
            dcLog("own process object lookup failed: \(TapError.describe(status))")
            return nil
        }

        return objectID
    }
}
