import AppKit
import Foundation

/// 一台设备自己的参数。
///
/// 为什么要按设备存：蓝牙耳机和内置扬声器的响度、固有延迟差着 100–200 ms，
/// 每换一副耳机都要重调一遍延迟，是把「自动接管」的好处又还回去。
/// 键用 HAL 的 `kAudioDevicePropertyDeviceUID`——`AudioDeviceID` 插拔后会变，UID 不会。
struct DeviceSettings: Codable, Equatable {
    var volume: Double
    var delay: Double
    var eq: [Double]

    init(volume: Double, delay: Double, eq: [Double]) {
        self.volume = volume
        self.delay = delay
        self.eq = eq
    }
}

/// 参数持久化：`~/Library/Application Support/DuoCast/settings.json`。
///
/// 存了三种东西，都从一个文件读：每台设备自己的参数、通道数、均衡器总开关。
///
/// 不存静音状态：静音是临时动作，下次启动突然没声音会让人以为坏了。
/// 音量、延迟、EQ 都是「这台设备本来该怎么响」的属性，才值得记住。
final class DeviceSettingsStore {

    private struct Document: Codable {
        var version: Int
        var channelCount: Int?
        var eqEnabled: Bool?
        var tapScope: String?
        var tapBundleIDs: [String]?
        var hotKeyCode: Int?
        var hotKeyModifiers: Int?
        var hotKeyLabel: String?
        var stopOnLock: Bool?
        var devices: [String: DeviceSettings]
    }

    private(set) var channelCount: Int?
    private(set) var eqEnabled: Bool?
    private(set) var tapScope: String?
    private(set) var tapBundleIDs: [String]?
    private(set) var hotKeyCode: Int?
    private(set) var hotKeyModifiers: Int?
    private(set) var hotKeyLabel: String?
    private(set) var stopOnLock: Bool?

    private var devices: [String: DeviceSettings] = [:]
    private var saveWork: DispatchWorkItem?
    private let fileURL: URL

    /// 写盘去抖：拖一次音量滑杆会产生几十次变更，没必要每次都落盘。
    private let saveDelay: TimeInterval = 0.6

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")

        fileURL = support.appendingPathComponent("DuoCast/settings.json")
        load()
    }

    // MARK: - 读

    func settings(for uid: String) -> DeviceSettings? {
        devices[uid]
    }

    // MARK: - 写

    func setSettings(_ settings: DeviceSettings, for uid: String) {
        guard devices[uid] != settings else { return }
        devices[uid] = settings
        scheduleSave()
    }

    func setChannelCount(_ count: Int) {
        guard channelCount != count else { return }
        channelCount = count
        scheduleSave()
    }

    func setEQEnabled(_ enabled: Bool) {
        guard eqEnabled != enabled else { return }
        eqEnabled = enabled
        scheduleSave()
    }

    func setTapSelection(scope: String, bundleIDs: [String]) {
        guard tapScope != scope || tapBundleIDs != bundleIDs else { return }
        tapScope = scope
        tapBundleIDs = bundleIDs
        scheduleSave()
    }

    func setHotKey(code: Int, modifiers: Int, label: String) {
        guard hotKeyCode != code || hotKeyModifiers != modifiers || hotKeyLabel != label else { return }
        hotKeyCode = code
        hotKeyModifiers = modifiers
        hotKeyLabel = label
        scheduleSave()
    }

    func setStopOnLock(_ enabled: Bool) {
        guard stopOnLock != enabled else { return }
        stopOnLock = enabled
        scheduleSave()
    }

    /// 立即落盘。退出前调用，避免最后一秒内的改动丢掉。
    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        write()
    }

    /// 在 Finder 里定位存档文件。设置改坏了让用户能直接看一眼，比猜有用。
    func revealInFinder() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            return
        }

        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    // MARK: - 内部

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            dcLog("settings: no file at \(fileURL.path)")
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let document = try JSONDecoder().decode(Document.self, from: data)
            devices = document.devices
            channelCount = document.channelCount
            eqEnabled = document.eqEnabled
            tapScope = document.tapScope
            tapBundleIDs = document.tapBundleIDs
            hotKeyCode = document.hotKeyCode
            hotKeyModifiers = document.hotKeyModifiers
            hotKeyLabel = document.hotKeyLabel
            stopOnLock = document.stopOnLock
            dcLog("settings: loaded \(devices.count) device(s) from \(fileURL.path)")
        } catch {
            // 文件坏了不该让应用起不来：退回到默认值，下一次写盘会覆盖它。
            dcLog("settings: load failed (\(error.localizedDescription)), starting from defaults")
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()

        let work = DispatchWorkItem { [weak self] in
            self?.write()
        }

        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    private func write() {
        let document = Document(
            version: 1,
            channelCount: channelCount,
            eqEnabled: eqEnabled,
            tapScope: tapScope,
            tapBundleIDs: tapBundleIDs,
            hotKeyCode: hotKeyCode,
            hotKeyModifiers: hotKeyModifiers,
            hotKeyLabel: hotKeyLabel,
            stopOnLock: stopOnLock,
            devices: devices
        )

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            try data.write(to: fileURL, options: .atomic)
            dcLog("settings: saved \(devices.count) device(s) to \(fileURL.path)")
        } catch {
            dcLog("settings: save failed (\(error.localizedDescription))")
        }
    }
}
