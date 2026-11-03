import AudioToolbox
import CoreAudio
import Foundation

enum AudioError: LocalizedError {
    case componentNotFound
    case setupFailed(String)

    var errorDescription: String? {
        switch self {
        case .componentNotFound:
            return "找不到可用的音频输出组件（AUHAL）"
        case .setupFailed(let message):
            return message
        }
    }
}

/// 单个输出通道：一个绑定到指定设备的 AUHAL 输出单元 + 环形缓冲 + 独立增益 + 10 段均衡。
///
/// 与 Windows 版的对应关系：
///   WasapiOut        → AUHAL（kAudioUnitSubType_HALOutput）
///   缓冲区 + 预灌    → bufferMs / primed
///   ASRC 漂移补偿    → readStep = (源率 / 设备率) × (1 + 修正)
final class OutputChannel {

    let label: String
    let ring = StereoRing(capacityFrames: 96_000)
    let eq = TenBandEQ()

    private(set) var deviceID: AudioDeviceID = 0
    private(set) var deviceName = "(未选择)"
    private(set) var sampleRate: Double = 48_000
    private(set) var channelCount: Int = 2
    private(set) var isRunning = false

    /// 软件增益，1.0 = 0 dB。范围 0 – 1.2（对应界面 0 – 120%）。
    var volume: Float = 1.0
    var muted = false

    /// 通道间延迟补偿（毫秒）。正值 = 该通道更晚出声。
    var offsetMs: Double = 0

    /// 渲染缓冲目标（毫秒）。
    /// 文件播放没有监听延迟需求，默认给 50 ms：泵按 11.6 ms 一块喂数据，
    /// 目标只有 10 ms 时任何一次睡眠抖动都会把缓冲抽干，产生边界欠载。
    var bufferMs: Double = 50

    /// ASRC 漂移补偿开关。
    var driftCompensation = true

    /// 源采样率（文件解码率）。与设备采样率不同时靠读步长完成重采样。
    var sourceRate: Double = 48_000

    private var unit: AudioUnit?
    private var readPosition: Double = 0
    private var primed = false
    private var peak: Float = 0
    private var underrunFrames: Int64 = 0
    private var correctionPPM: Double = 0
    private var levelEMA: Double = 0

    /// 渲染回调被调用的次数与累计帧数。
    /// 「`AudioOutputUnitStart` 返回成功」不等于「设备真的在放」：蓝牙链路被系统挂起时，
    /// 单元照样能启动，但 HAL 不会来拉数据。这两个计数是判断「这一路是否真的活着」的唯一依据。
    private(set) var renderCallbacks: Int64 = 0
    private(set) var renderedFrames: Int64 = 0

    private let scratchFrames = 4_096
    private let scratch: UnsafeMutablePointer<Float>

    private static let renderProc: AURenderCallback = { reference, _, _, _, frameCount, ioData in
        let channel = Unmanaged<OutputChannel>.fromOpaque(reference).takeUnretainedValue()
        return channel.render(frameCount: Int(frameCount), ioData: ioData)
    }

    init(label: String) {
        self.label = label
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrames * 2)
        scratch.initialize(repeating: 0, count: scratchFrames * 2)
    }

    deinit {
        stop()
        scratch.deinitialize(count: scratchFrames * 2)
        scratch.deallocate()
    }

    // MARK: - 对外指标

    var peakLevel: Float { peak }

    /// 累计欠载时长。欠载是以「输出帧」为单位统计的（每缺一个输出帧就是 1/设备采样率 秒），
    /// 所以这里必须除以设备采样率；除以源采样率会把 96k 设备上的缺口放大四倍。
    var underrunMs: Double {
        sampleRate > 0 ? Double(underrunFrames) / sampleRate * 1_000 : 0
    }

    var bufferedMs: Double {
        sourceRate > 0 ? (Double(ring.totalWritten) - readPosition) / sourceRate * 1_000 : 0
    }

    var correctionPPMValue: Double { correctionPPM }

    // MARK: - 生命周期

    func start(device: AudioDevice, sourceRate: Double) throws {
        guard device.transport != kAudioDeviceTransportTypeVirtual else {
            throw AudioError.setupFailed("该端点不是可播放设备（系统虚拟端点）")
        }

        stop()

        self.deviceID = device.id
        self.deviceName = device.name
        self.sourceRate = sourceRate > 0 ? sourceRate : 48_000

        ring.reset()
        readPosition = 0
        levelEMA = 0
        primed = false
        peak = 0
        underrunFrames = 0
        correctionPPM = 0
        renderCallbacks = 0
        renderedFrames = 0

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioError.componentNotFound
        }

        var instance: AudioUnit?
        var status = AudioComponentInstanceNew(component, &instance)
        guard status == noErr, let unit = instance else {
            throw AudioError.setupFailed("创建输出单元失败（\(status)）")
        }

        dcLog("[\(label)] unit created, setting device \(device.id) (\(device.name))")

        var deviceValue = device.id
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceValue,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AudioError.setupFailed("绑定输出设备失败（\(status)）")
        }

        dcLog("[\(label)] current device set (status \(status))")

        // 设备侧格式：AUHAL 不做采样率转换，客户端格式必须与设备一致。
        var deviceFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &deviceFormat,
            &formatSize
        )

        // 用 HAL 报告的标称采样率，而不是 AU 的默认格式：
        // 未初始化时 AUHAL 可能返回一个与硬件无关的默认值（本机实测 44.1k vs 48k），
        // 按默认值设置客户端格式会让硬件以错误速率播放，音高整体偏移。
        sampleRate = device.sampleRate > 0 ? device.sampleRate : deviceFormat.mSampleRate
        if sampleRate <= 0 { sampleRate = 48_000 }

        channelCount = max(1, Int(deviceFormat.mChannelsPerFrame))
        if channelCount == 0 { channelCount = 2 }
        dcLog("[\(label)] device format: \(sampleRate) Hz / \(channelCount) ch / flags \(deviceFormat.mFormatFlags)")

        // 按本次实际采样率重建滤波系数，与 Windows 版一致。
        eq.prepare(sampleRate: sampleRate)

        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channelCount * 4),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channelCount * 4),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &clientFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )

        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AudioError.setupFailed("设置输出格式失败（\(status)）")
        }

        var acceptedFormat = AudioStreamBasicDescription()
        var acceptedSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &acceptedFormat, &acceptedSize) == noErr {
            dcLog("[\(label)] client format accepted: \(acceptedFormat.mSampleRate) Hz / \(acceptedFormat.mChannelsPerFrame) ch")
            if Int(acceptedFormat.mSampleRate) != Int(sampleRate) {
                dcLog("[\(label)] WARNING: 采样率与设备不匹配，硬件可能变速播放")
            }
        }

        var maximumFrames = UInt32(scratchFrames)
        AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maximumFrames,
            UInt32(MemoryLayout<UInt32>.size)
        )

        var callback = AURenderCallbackStruct(
            inputProc: Self.renderProc,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )

        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AudioError.setupFailed("安装渲染回调失败（\(status)）")
        }

        dcLog("[\(label)] callback installed, initializing")
        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AudioError.setupFailed("初始化输出单元失败（\(status)）")
        }

        self.unit = unit
        isRunning = true

        dcLog("[\(label)] initialized, starting IO")
        status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            isRunning = false
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            self.unit = nil
            throw AudioError.setupFailed("启动输出失败（\(status)）")
        }
    }

    func stop() {
        dcLog("[\(label)] stop")
        isRunning = false
        primed = false
        peak = 0

        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    /// 写入一路交错立体声数据（源采样率）。
    func push(_ samples: UnsafePointer<Float>, frames: Int) {
        ring.write(samples, frames: frames)
    }

    func push(_ samples: [Float], frames: Int) {
        ring.write(samples, frames: frames)
    }

    // MARK: - 渲染

    private func render(frameCount: Int, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData, frameCount > 0, frameCount <= scratchFrames else {
            return noErr
        }

        renderCallbacks += 1
        renderedFrames += Int64(frameCount)

        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        guard !buffers.isEmpty else { return noErr }

        pull(into: scratch, frames: frameCount)

        if buffers.count == 1 {
            guard let raw = buffers[0].mData else { return noErr }
            let output = raw.assumingMemoryBound(to: Float.self)

            if channelCount == 2 {
                for index in 0..<(frameCount * 2) {
                    output[index] = scratch[index]
                }
            } else {
                for frame in 0..<frameCount {
                    let base = frame * channelCount
                    output[base] = scratch[frame * 2]
                    if channelCount > 1 {
                        output[base + 1] = scratch[frame * 2 + 1]
                    }
                    if channelCount > 2 {
                        for channel in 2..<channelCount {
                            output[base + channel] = 0
                        }
                    }
                }
            }
        } else {
            // 非交错布局：每个声道一个 buffer，取前两个声道，其余补零。
            for (channelIndex, buffer) in buffers.enumerated() {
                guard let raw = buffer.mData else { continue }
                let output = raw.assumingMemoryBound(to: Float.self)

                if channelIndex < 2 {
                    for frame in 0..<frameCount {
                        output[frame] = scratch[frame * 2 + channelIndex]
                    }
                } else {
                    for frame in 0..<frameCount {
                        output[frame] = 0
                    }
                }
            }
        }

        return noErr
    }

    private func pull(into destination: UnsafeMutablePointer<Float>, frames: Int) {
        guard isRunning else {
            fillSilence(destination, frames: frames)
            return
        }

        var target = (bufferMs + max(0, offsetMs)) / 1_000 * sourceRate
        if target < sourceRate * 0.005 {
            target = sourceRate * 0.005
        }

        let available = Double(ring.totalWritten) - readPosition

        if !primed {
            if available < target {
                fillSilence(destination, frames: frames)
                return
            }

            primed = true
        }

        // 控制律按「毫秒误差」而不是「帧数误差」定标：
        // 水位偏离目标 50 ms 时给出满量程 ±0.2%，2 ms 时只给 8 ppm，
        // 这样日常的块状喂数据（水位必然在目标附近上下摆动）不会把控制器顶到饱和。
        // EMA 用来滤掉每块写入造成的锯齿，只跟踪缓慢的时钟漂移。
        var correction = 0.0
        if driftCompensation {
            levelEMA = levelEMA <= 0 ? available : levelEMA + (available - levelEMA) * 0.05
            let errorMs = (levelEMA - target) / sourceRate * 1_000
            correction = min(max(errorMs / 50.0 * 0.002, -0.002), 0.002)
        } else {
            levelEMA = available
        }

        // 读步长同时承担重采样与漂移修正：设备 44.1k、源 48k 时步长约为 1.088。
        let step = (sourceRate / sampleRate) * (1.0 + correction)

        let result = ring.readInterpolated(start: readPosition, step: step, into: destination, frames: frames)
        readPosition = result.endPosition
        correctionPPM = correction * 1_000_000

        if result.underrunFrames > 0 {
            underrunFrames += Int64(result.underrunFrames)
        }

        eq.process(destination, frames: frames)

        let gain: Float = muted ? 0 : volume
        var framePeak: Float = 0

        for index in 0..<(frames * 2) {
            let value = destination[index] * gain
            destination[index] = value

            let magnitude = abs(value)
            if magnitude > framePeak {
                framePeak = magnitude
            }
        }

        peak = framePeak
    }

    private func fillSilence(_ destination: UnsafeMutablePointer<Float>, frames: Int) {
        for index in 0..<(frames * 2) {
            destination[index] = 0
        }
        peak = 0
    }
}
