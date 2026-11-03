import CoreAudio
import Foundation

/// 监听音频端点增减与系统默认输出变化。
///
/// 为什么需要它：三路配置里最容易卡住人的一步是「插上耳机但界面里看不到」。
/// 手动点「刷新设备」要求用户知道该点什么，而插拔本来就是系统事件，应该由程序接住。
///
/// 两个通知源缺一不可：
/// - `kAudioHardwarePropertyDevices`：端点增删（插拔 USB 声卡、蓝牙耳机连上/断开）；
/// - `kAudioHardwarePropertyDefaultOutputDevice`：系统默认输出切换。
///   蓝牙耳机连上时系统通常直接把它设成默认输出，即使端点列表没变，这也是一个明确信号。
///
/// 插一次耳机会连发多条通知（端点出现 → 默认切换 → 流格式就绪），
/// 所以统一做 350 ms 去抖，只把最后那次交给上层。
final class AudioDeviceWatcher {

    /// 触发原因，仅用于日志与状态文案。
    enum Reason: String {
        case devices
        case defaultOutput
    }

    var onChange: ((Reason) -> Void)?

    private var installed = false
    private var pending: DispatchWorkItem?

    private var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var devicesBlock: AudioObjectPropertyListenerBlock?
    private var defaultOutputBlock: AudioObjectPropertyListenerBlock?

    deinit {
        stop()
    }

    func start() {
        guard !installed else { return }
        installed = true

        let system = AudioObjectID(kAudioObjectSystemObject)
        let queue = DispatchQueue.main

        let deviceBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.schedule(.devices)
        }

        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.schedule(.defaultOutput)
        }

        devicesBlock = deviceBlock
        defaultOutputBlock = defaultBlock

        AudioObjectAddPropertyListenerBlock(system, &devicesAddress, queue, deviceBlock)
        AudioObjectAddPropertyListenerBlock(system, &defaultOutputAddress, queue, defaultBlock)

        dcLog("device watcher installed")
    }

    func stop() {
        guard installed else { return }
        installed = false

        pending?.cancel()
        pending = nil

        let system = AudioObjectID(kAudioObjectSystemObject)

        if let devicesBlock {
            AudioObjectRemovePropertyListenerBlock(system, &devicesAddress, DispatchQueue.main, devicesBlock)
        }

        if let defaultOutputBlock {
            AudioObjectRemovePropertyListenerBlock(system, &defaultOutputAddress, DispatchQueue.main, defaultOutputBlock)
        }

        devicesBlock = nil
        defaultOutputBlock = nil
    }

    private func schedule(_ reason: Reason) {
        pending?.cancel()

        let work = DispatchWorkItem { [weak self] in
            dcLog("device change: \(reason.rawValue)")
            self?.onChange?(reason)
        }

        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}
