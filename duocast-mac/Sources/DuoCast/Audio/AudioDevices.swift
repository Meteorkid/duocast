import AudioToolbox
import CoreAudio
import Foundation

/// 一个音频输出端点。
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    /// HAL 的持久 UID。`AudioDeviceID` 在插拔后会变，UID 不会——按设备记忆参数只能用它做键。
    let uid: String
    let name: String
    let isDefault: Bool
    let channels: Int
    let sampleRate: Double
    let isBluetooth: Bool
    let transport: UInt32

    /// 下拉菜单里显示的名字（默认设备带标记）
    var displayName: String { isDefault ? "\(name)（默认）" : name }
}

/// CoreAudio HAL 端点枚举。只返回当前有输出通道的设备。
enum AudioDevices {

    static func outputDevices() -> [AudioDevice] {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var address = propertyAddress(kAudioHardwarePropertyDevices)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }

        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }

        let defaultID = defaultOutputDevice()

        return ids.compactMap { id -> AudioDevice? in
            let channels = outputChannelCount(id)
            guard channels > 0 else { return nil }

            // 排除系统虚拟端点（macOS 14+ 的 Background Music / Audiojingle 等）。
            // 它们有输出通道，但并不是真正的播放设备：把 AUHAL 绑上去会卡死在
            // AudioUnitSetProperty 上（本机实测），因此不进下拉列表。
            let transport = transportType(id)
            guard transport != kAudioDeviceTransportTypeVirtual else { return nil }

            return AudioDevice(
                id: id,
                uid: deviceUID(id) ?? "id:\(id)",
                name: deviceName(id) ?? "设备 \(id)",
                isDefault: id == defaultID,
                channels: channels,
                sampleRate: nominalSampleRate(id),
                isBluetooth: isBluetooth(id),
                transport: transport
            )
        }
    }

    /// 设备的持久 UID（`kAudioDevicePropertyDeviceUID`）。跨插拔、跨重启稳定。
    static func deviceUID(_ id: AudioDeviceID) -> String? {
        var address = propertyAddress(kAudioDevicePropertyDeviceUID)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var unmanaged: Unmanaged<CFString>?

        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &unmanaged)
        guard status == noErr, let unmanaged else { return nil }

        return unmanaged.takeRetainedValue() as String
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    /// 设备的输出通道数；0 表示这是纯输入设备。
    static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0

        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }

        // 按系统报告的确切字节数分配，再把内存当作 AudioBufferList 交给 HAL 填写。
        // 不用 AudioBufferList.allocate(maximumBuffers:)：那个辅助方法会自己反推缓冲区数量，
        // 与 HAL 实际写入的结构对不上时会在运行时断言失败（本机实测如此）。
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        let listPointer = raw.assumingMemoryBound(to: AudioBufferList.self)

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, listPointer) == noErr else {
            return 0
        }

        let buffers = UnsafeMutableAudioBufferListPointer(listPointer)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var address = propertyAddress(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr, rate > 0 else {
            return 48_000
        }

        return rate
    }

    static func deviceName(_ id: AudioDeviceID) -> String? {
        var address = propertyAddress(kAudioObjectPropertyName)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var unmanaged: Unmanaged<CFString>?

        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &unmanaged)
        guard status == noErr, let unmanaged else { return nil }

        return unmanaged.takeRetainedValue() as String
    }

    static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = propertyAddress(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else {
            return 0
        }

        return transport
    }

    static func transportName(_ transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "builtin"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "bluetooth-le"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypePCI: return "pci"
        case kAudioDeviceTransportTypeFireWire: return "firewire"
        case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
        default: return "other(\(transport))"
        }
    }

    /// 传输类型为蓝牙时返回 true。用系统属性的真实值，不靠名字猜——
    /// 这一点比 Windows 版强，那边只能按端点名做启发式判断。
    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        let transport = transportType(id)
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
