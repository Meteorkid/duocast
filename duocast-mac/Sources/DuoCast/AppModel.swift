import AppKit
import Combine
import CoreAudio
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 输入源选择。产品的主路径是系统声音（任意 App 播放的歌都能分给多副耳机），
/// 本地文件保留为「没有播放器、只想验证链路」时的备用入口。
enum SourceMode: String, CaseIterable, Identifiable {
    case system
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "系统声音"
        case .file: return "音频文件"
        }
    }
}

/// 一路输出的完整状态。界面按索引绑定，引擎按同一索引持有 OutputChannel。
///
/// 用数组而不是 volumeA / volumeB 这样的并列属性：三路（有线 + 蓝牙 + 内置扬声器）
/// 是真实需求，写死两路会让每加一路都要复制一整套属性、绑定和视图。
struct OutputSlot: Identifiable {
    let id = UUID()

    var deviceID: AudioDeviceID?
    var volume: Double = 78
    var muted = false
    var delay: Double = 0
    var eq: [Double] = Array(repeating: 0, count: TenBandEQ.bandCount)

    /// 当前这份参数是从哪台设备读来的（设备 UID）。
    /// 设备变了才重新加载，否则用户正在拖的滑杆会被存货覆盖。
    var loadedUID: String?

    // 运行时指标，每秒刷新 20 次
    var peak: Double = 0
    var underrunMs: Double = 0
    var driftPPM: Double = 0
    var alive = true
}

/// 界面与引擎之间的桥：把引擎的实时指标抽上来，把界面操作下发下去。
final class AppModel: ObservableObject {

    /// 全局单例。菜单栏和窗口是两套入口，必须操作同一个模型；
    /// 用 `@StateObject` 各建一个会让菜单栏显示的状态和窗口里的对不上。
    static let shared = AppModel()

    /// 通道上限。每一路都是一个独立的实时 AUHAL 单元，三路已经覆盖
    /// 「有线 + 蓝牙 + 内置扬声器」，再加就要重新考虑 CPU 与窗口宽度。
    static let maxChannels = 3

    let engine = AudioEngine()
    private let store = DeviceSettingsStore()

    @Published private(set) var slots: [OutputSlot] = [OutputSlot(), OutputSlot(volume: 52)]

    @Published var devices: [AudioDevice] = []

    @Published var sourceMode: SourceMode = .system {
        didSet {
            refreshSourceName()

            if isRunning {
                stop()
                statusText = "输入源已切换，分发已停止。请重新开始。"
            }
        }
    }

    @Published var eqEnabled = true {
        didSet {
            for index in slots.indices {
                engine.channel(at: index)?.eq.enabled = eqEnabled
            }

            store.setEQEnabled(eqEnabled)
        }
    }

    @Published var isRunning = false
    @Published var statusText = "选择每路输出设备后点击「开始分发」；任意 App 播放的声音会同时送到所有通道。"
    @Published var sourceName = "系统声音（所有 App）"
    @Published var loopFile = true

    /// 采集范围：整机混音，或只挑几个 App。
    enum CaptureScope: String {
        case all
        case apps
    }

    @Published private(set) var captureScope: CaptureScope = .all
    @Published var selectableApps: [AudioApp] = []
    @Published private(set) var selectedApps: Set<String> = []

    // MARK: - 快捷与自动化

    @Published private(set) var hotKeyLabel = HotKeyDefaults.label
    private(set) var hotKeyCode = HotKeyDefaults.code
    private(set) var hotKeyModifiers = HotKeyDefaults.modifiers

    /// 锁屏 / 休眠时自动停止分发。默认开：人不在的时候没必要继续占着设备和 CPU。
    @Published var stopOnLock = true {
        didSet { store.setStopOnLock(stopOnLock) }
    }

    /// 由 AppDelegate 在安装菜单栏后注入，用来换快捷键。
    weak var menuBar: MenuBarController?

    /// 系统声音模式下采到的一直是数字静音时给出的提示（多半是权限没给）。
    @Published var permissionHint: String? = nil

    /// 某几路「单元启动成功但 HAL 从没来拉数据」的提示。
    /// 蓝牙链路被系统挂起时就是这个现象：界面看着在跑，耳机里没有声音。
    @Published var ioWarning: String? = nil

    private var fileURL: URL?
    private var meterTimer: Timer?
    private var peakStates: [Double] = [0, 0]
    private var silenceSince: Date?
    private var startedAt: Date?
    private var tickCount = 0
    private let watcher = AudioDeviceWatcher()
    private var isHandlingDeviceChange = false

    init() {
        engine.onLog = { [weak self] message in
            self?.statusText = message
        }

        engine.onStopped = { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.statusText = "播放结束。"
        }

        // 通道数与均衡开关先按上次的样子恢复，再枚举设备——设备分配依赖槽位已经建好。
        let restoredCount = min(max(1, store.channelCount ?? 2), Self.maxChannels)
        slots = (0..<restoredCount).map { OutputSlot(volume: $0 == 0 ? 78 : 52) }
        peakStates = Array(repeating: 0, count: restoredCount)

        if let storedEQ = store.eqEnabled {
            eqEnabled = storedEQ
        }

        if let storedScope = store.tapScope, let scope = CaptureScope(rawValue: storedScope) {
            captureScope = scope
        }
        selectedApps = Set(store.tapBundleIDs ?? [])

        if let code = store.hotKeyCode, let modifiers = store.hotKeyModifiers {
            hotKeyCode = UInt32(truncatingIfNeeded: code)
            hotKeyModifiers = UInt32(truncatingIfNeeded: modifiers)
        }
        if let label = store.hotKeyLabel, !label.isEmpty {
            hotKeyLabel = label
        }
        if let stored = store.stopOnLock {
            stopOnLock = stored
        }

        engine.configure(channelCount: slots.count)
        refreshDevices()
        syncSettingsFromStore()
        applySettings()

        watcher.onChange = { [weak self] reason in
            self?.handleDeviceChange(reason)
        }
        watcher.start()

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.store.saveNow()
        }

        observeSystemEvents()

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer

        handleLaunchArguments()
    }

    deinit {
        meterTimer?.invalidate()
        watcher.stop()
        store.saveNow()
    }

    /// 供自测用：`--play <文件>` 走文件输入，`--system` 走系统声音输入。两者都会自动开始分发，
    /// 省掉人工点选（也方便脚本化回归）。
    private func handleLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments

        // `--channels 3`：直接把通道数设成 3，用于自测三路（有线 + 蓝牙 + 内置扬声器）。
        if let index = arguments.firstIndex(of: "--channels"),
           index + 1 < arguments.count,
           let count = Int(arguments[index + 1]) {
            dcLog("launch arg --channels \(count)")
            setChannelCount(count)
        }

        // `--tap-apps com.apple.Music,com.spotify.client`：只采这些 App，便于脚本化验证。
        if let index = arguments.firstIndex(of: "--tap-apps"), index + 1 < arguments.count {
            let bundleIDs = arguments[index + 1]
                .split(separator: ",")
                .map(String.init)
                .filter { !$0.isEmpty }

            if !bundleIDs.isEmpty {
                dcLog("launch arg --tap-apps \(bundleIDs)")
                selectedApps = Set(bundleIDs)
                captureScope = .apps
                persistCaptureScope()
                refreshSourceName()
            }
        }

        if arguments.contains("--system") {
            dcLog("launch arg --system")
            sourceMode = .system

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.start()
            }
            return
        }

        guard let index = arguments.firstIndex(of: "--play"), index + 1 < arguments.count else {
            return
        }

        let path = arguments[index + 1]
        guard FileManager.default.fileExists(atPath: path) else {
            return
        }

        let url = URL(fileURLWithPath: path)
        dcLog("launch arg --play \(path)")
        fileURL = url
        sourceMode = .file
        sourceName = url.lastPathComponent

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.start()
        }
    }

    private func refreshSourceName() {
        switch sourceMode {
        case .system:
            switch captureScope {
            case .all:
                sourceName = "系统声音（所有 App）"
            case .apps:
                sourceName = selectedApps.isEmpty
                    ? "系统声音（未选择 App）"
                    : "系统声音（\(selectedApps.count) 个 App）"
            }
        case .file:
            sourceName = fileURL?.lastPathComponent ?? "未选择文件"
        }

        permissionHint = nil
    }

    // MARK: - 采集范围

    /// 重新枚举当前在用音频的 App。界面打开选择器时、以及以「选定 App」启动前各刷一次。
    func refreshSelectableApps() {
        let ownBundle = Bundle.main.bundleIdentifier ?? ""
        selectableApps = AudioProcesses.audioApps(excluding: [ownBundle])
    }

    func setCaptureScope(_ scope: CaptureScope) {
        guard captureScope != scope else { return }

        captureScope = scope
        persistCaptureScope()
        refreshSourceName()
        stopForConfigChange("采集范围已切换")
    }

    func toggleApp(_ bundleID: String) {
        if selectedApps.contains(bundleID) {
            selectedApps.remove(bundleID)
        } else {
            selectedApps.insert(bundleID)
        }

        if captureScope != .apps {
            captureScope = .apps
        }

        persistCaptureScope()
        refreshSourceName()
        stopForConfigChange("采集范围已更改")
    }

    func isSelected(_ bundleID: String) -> Bool {
        selectedApps.contains(bundleID)
    }

    private func persistCaptureScope() {
        store.setTapSelection(scope: captureScope.rawValue, bundleIDs: Array(selectedApps).sorted())
    }

    private func stopForConfigChange(_ reason: String) {
        guard isRunning else { return }
        stop()
        statusText = "\(reason)，分发已停止。请重新开始。"
    }

    // MARK: - 通道

    var canAddSlot: Bool { slots.count < Self.maxChannels }

    func channelLabel(_ index: Int) -> String {
        AudioEngine.channelLabel(index)
    }

    func device(for index: Int) -> AudioDevice? {
        guard slots.indices.contains(index), let id = slots[index].deviceID else { return nil }
        return devices.first { $0.id == id }
    }

    func addSlot() {
        guard canAddSlot else {
            statusText = "最多 \(Self.maxChannels) 路输出。"
            return
        }

        let wasRunning = isRunning
        setChannelCount(slots.count + 1)

        if wasRunning {
            statusText = "已增加一路输出，分发已停止。请重新开始。"
        }
    }

    func removeSlot(at index: Int) {
        guard slots.count > 1, slots.indices.contains(index) else { return }

        let wasRunning = isRunning
        setChannelCount(slots.count - 1, removing: index)

        if wasRunning {
            statusText = "已移除一路输出，分发已停止。请重新开始。"
        } else {
            statusText = "已移除一路输出。"
        }
    }

    /// 统一调整通道数。增删都要重建引擎通道、重新分配设备、把参数推下去，
    /// 分散在三处写迟早会漏掉某一步。
    private func setChannelCount(_ count: Int, removing index: Int? = nil) {
        let target = min(max(1, count), Self.maxChannels)
        guard target != slots.count else { return }

        if isRunning { stop() }

        if target > slots.count {
            while slots.count < target {
                slots.append(OutputSlot(volume: 52))
            }
        } else {
            if let index, slots.indices.contains(index) {
                slots.remove(at: index)
            }
            while slots.count > target {
                slots.removeLast()
            }
        }

        peakStates = Array(repeating: 0, count: slots.count)
        engine.configure(channelCount: target)
        assignDevices()
        syncSettingsFromStore()
        applySettings()
        store.setChannelCount(target)
        widenWindowIfNeeded()
    }

    /// SwiftUI 的 `.frame(minWidth:)` 只在窗口创建时生效，之后增删通道窗口不会跟着变。
    /// 三路时每列只有 ~400 pt 会把 EQ 挤扁，所以手动把窗口撑到够宽（只加不减，避免抖动）。
    private func widenWindowIfNeeded() {
        let needed = 1_040 + CGFloat(max(0, slots.count - 2)) * 380

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentViewController != nil }) else {
                return
            }

            guard window.frame.width < needed else { return }

            var frame = window.frame
            frame.size.width = needed
            window.setFrame(frame, display: true, animate: true)
        }
    }

    // MARK: - 参数记忆

    /// 把槽位当前的值写成「这台设备」的参数。
    private func persistSlot(_ index: Int) {
        guard slots.indices.contains(index), let device = device(for: index) else { return }

        store.setSettings(
            DeviceSettings(
                volume: slots[index].volume,
                delay: slots[index].delay,
                eq: slots[index].eq
            ),
            for: device.uid
        )
    }

    private func persistAllSlots() {
        for index in slots.indices { persistSlot(index) }
    }

    /// 槽位换了设备时，把参数换成那台设备自己的那份。
    ///
    /// 只有 loadedUID 变了才重新加载——否则每 50 ms 的指标刷新都会覆盖用户正在拖的滑杆。
    /// 第一次见到的设备没有存档，就以槽位当前值作初值写进去，保证「先调后记」和「先记后调」一致。
    private func syncSettingsFromStore() {
        for index in slots.indices {
            guard let device = device(for: index) else {
                slots[index].loadedUID = nil
                continue
            }

            guard slots[index].loadedUID != device.uid else { continue }
            slots[index].loadedUID = device.uid

            if let stored = store.settings(for: device.uid) {
                slots[index].volume = stored.volume
                slots[index].delay = stored.delay
                slots[index].eq = normalizedEQ(stored.eq)
                dcLog("settings restored: \(device.name) vol \(Int(stored.volume))% delay \(Int(stored.delay))ms")
            } else {
                persistSlot(index)
                dcLog("settings seeded: \(device.name)")
            }
        }
    }

    private func normalizedEQ(_ values: [Double]) -> [Double] {
        var result = Array(repeating: 0.0, count: TenBandEQ.bandCount)
        for band in 0..<min(values.count, result.count) {
            result[band] = values[band]
        }
        return result
    }

    // MARK: - 设备

    func refreshDevices() {
        devices = AudioDevices.outputDevices()

        for device in devices {
            dcLog("device \(device.id) \"\(device.name)\" transport=\(AudioDevices.transportName(device.transport)) ch=\(device.channels) rate=\(Int(device.sampleRate)) default=\(device.isDefault)")
        }

        if devices.isEmpty {
            statusText = "未检测到可用的音频输出设备。"
        }

        assignDevices()
        syncSettingsFromStore()
        attachIdleChannels()
    }

    /// 给空槽位分配设备：已分配且仍存在的保持不动，空的挑一个没被占用的。
    ///
    /// 设备比槽位少时宁可留空——把两路绑到同一个端点上只会让声音在同一副耳机里叠加，
    /// 没有意义，而留空的位置正好是热插拔自动接管的落点。
    private func assignDevices() {
        guard !devices.isEmpty else { return }

        for index in slots.indices {
            if let id = slots[index].deviceID, !devices.contains(where: { $0.id == id }) {
                slots[index].deviceID = nil
            }
        }

        // 默认设备优先：新连上的蓝牙耳机通常立刻被系统设为默认输出，排在最前面就能被空槽接住。
        let ordered = devices.filter { $0.isDefault } + devices.filter { !$0.isDefault }

        for index in slots.indices where slots[index].deviceID == nil {
            let used = Set(slots.compactMap { $0.deviceID })
            guard let candidate = ordered.first(where: { !used.contains($0.id) }) else { break }
            slots[index].deviceID = candidate.id
        }
    }

    /// 运行中把「有设备但通道还没起来」的槽位接进引擎。热插拔接管与手动刷新共用。
    private func attachIdleChannels() {
        guard isRunning else { return }

        for index in slots.indices {
            guard slots[index].deviceID != nil,
                  let device = device(for: index),
                  let channel = engine.channel(at: index),
                  !channel.isRunning else { continue }

            do {
                try engine.attach(device: device, at: index)
                applySettings()
                dcLog("channel \(channelLabel(index)) auto-attached to \(device.name)")
            } catch {
                dcLog("attach \(channelLabel(index)) failed: \(error.localizedDescription)")
            }
        }
    }

    /// 系统端点变化（插拔、蓝牙连断、默认输出切换）后的接管逻辑。
    ///
    /// 三条规则：
    /// 1. 掉线的那一路立刻断开，**其余通道不停**——拔掉一副耳机不该让别人也听不了；
    /// 2. 空槽位按 `assignDevices` 补设备，补上的那一路在运行中直接接进引擎，不打断分发；
    /// 3. 一轮通知里可能同时有掉线和新增（例如蓝牙从 A 耳机切到 B 耳机），按「先断后接」处理。
    private func handleDeviceChange(_ reason: AudioDeviceWatcher.Reason) {
        guard !isHandlingDeviceChange else { return }
        isHandlingDeviceChange = true
        defer { isHandlingDeviceChange = false }

        let before = devices
        let beforeIDs = Set(before.map { $0.id })

        devices = AudioDevices.outputDevices()
        let afterIDs = Set(devices.map { $0.id })

        let added = devices.filter { !beforeIDs.contains($0.id) }
        let removed = before.filter { !afterIDs.contains($0.id) }

        // 可见列表里还有没被任何槽位占用的设备吗？只有「有空槽 + 有空闲设备」才可能发生接管。
        let hasUnassignedDevice = devices.contains { device in
            !slots.contains { $0.deviceID == device.id }
        }

        // 我们自己的私有聚合设备（系统声音采集用的 tap）增删也会触发通知，
        // 但可见设备列表没有任何变化。这种情况直接忽略，否则状态栏会刷一条没有信息量的文案。
        guard !added.isEmpty || !removed.isEmpty || hasUnassignedDevice else { return }

        // 1. 掉线
        var detached: [String] = []
        var lostNames: [String] = []

        for index in slots.indices {
            guard let id = slots[index].deviceID, !afterIDs.contains(id) else { continue }

            if let name = before.first(where: { $0.id == id })?.name {
                lostNames.append(name)
            }

            if isRunning { engine.detach(at: index) }
            slots[index].deviceID = nil
            slots[index].peak = 0
            detached.append(channelLabel(index))
        }

        // 2. 补空槽
        let emptySlots = slots.indices.filter { slots[$0].deviceID == nil }
        assignDevices()
        syncSettingsFromStore()

        // 3. 运行中把新接上的路直接接进引擎
        var attached: [String] = []

        if isRunning {
            for index in emptySlots where slots[index].deviceID != nil {
                guard let device = device(for: index) else { continue }
                guard let channel = engine.channel(at: index), !channel.isRunning else { continue }

                do {
                    try engine.attach(device: device, at: index)
                    applySettings()
                    attached.append("\(channelLabel(index)) → \(device.name)")
                } catch {
                    dcLog("attach \(channelLabel(index)) failed: \(error.localizedDescription)")
                }
            }
        }

        // 4. 文案
        var parts: [String] = []

        if !detached.isEmpty {
            let names = lostNames.isEmpty ? "" : "（\(lostNames.joined(separator: "、"))）"
            parts.append("输出 \(detached.joined(separator: "、")) 已断开\(names)")
        }

        if !attached.isEmpty {
            parts.append("已自动接管 \(attached.joined(separator: "、"))")
        } else if !added.isEmpty && !isRunning {
            parts.append("新增设备 \(added.map { $0.name }.joined(separator: "、"))")
        }

        if parts.isEmpty {
            parts.append(reason == .defaultOutput ? "系统默认输出已变更" : "设备列表已更新")
        }

        statusText = parts.joined(separator: "；") + "。"

        dcLog("device change handled: \(statusText)")
    }

    func selectDevice(_ id: AudioDeviceID, slot index: Int) {
        guard slots.indices.contains(index) else { return }
        slots[index].deviceID = id
        syncSettingsFromStore()
        applySettings()

        if isRunning {
            stop()
            statusText = "输出设备已更改，分发已停止。请重新开始。"
        }
    }

    // MARK: - 输入源

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择要分发的音频文件"

        if panel.runModal() == .OK, let url = panel.url {
            fileURL = url
            sourceMode = .file
            sourceName = url.lastPathComponent
            statusText = "已选择：\(url.lastPathComponent)"
        }
    }

    // MARK: - 绑定

    func volumeBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { self.slots.indices.contains(index) ? self.slots[index].volume : 0 },
            set: { value in
                guard self.slots.indices.contains(index) else { return }
                self.slots[index].volume = value
                self.engine.channel(at: index)?.volume = Float(value / 100)
                self.persistSlot(index)
            }
        )
    }

    func mutedBinding(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { self.slots.indices.contains(index) ? self.slots[index].muted : false },
            set: { value in
                guard self.slots.indices.contains(index) else { return }
                self.slots[index].muted = value
                self.engine.channel(at: index)?.muted = value
            }
        )
    }

    func delayBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { self.slots.indices.contains(index) ? self.slots[index].delay : 0 },
            set: { value in
                guard self.slots.indices.contains(index) else { return }
                self.slots[index].delay = value
                self.engine.channel(at: index)?.offsetMs = value
                self.persistSlot(index)
            }
        )
    }

    func eqBinding(channel index: Int, band: Int) -> Binding<Double> {
        Binding(
            get: {
                guard self.slots.indices.contains(index), self.slots[index].eq.indices.contains(band) else { return 0 }
                return self.slots[index].eq[band]
            },
            set: { newValue in
                guard self.slots.indices.contains(index), self.slots[index].eq.indices.contains(band) else { return }
                let snapped = (newValue * 2).rounded() / 2
                self.slots[index].eq[band] = snapped
                self.engine.channel(at: index)?.eq.setGain(Float(snapped), at: band)
                self.persistSlot(index)
            }
        )
    }

    // MARK: - 快捷键与系统事件

    /// 换全局快捷键。注册失败（组合被别的程序占了）就保持原样并如实告知。
    func changeHotKey(code: UInt32, modifiers: UInt32, label: String) {
        guard let menuBar else {
            statusText = "菜单栏尚未就绪，稍后再试。"
            return
        }

        guard menuBar.applyHotKey(code: code, modifiers: modifiers) else {
            statusText = "\(label) 已被其他程序占用，快捷键保持不变。"
            return
        }

        hotKeyCode = code
        hotKeyModifiers = modifiers
        hotKeyLabel = label
        store.setHotKey(code: Int(code), modifiers: Int(modifiers), label: label)
        statusText = "全局快捷键已改为 \(label)。"
    }

    func revealSettingsFile() {
        store.revealInFinder()
    }

    private func observeSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stopForSystem("系统即将休眠")
        }

        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stopForSystem("显示器已休眠")
        }

        // 锁屏走的是分布式通知，不在 NSWorkspace 里。
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopForSystem("屏幕已锁定")
        }
    }

    /// 人不在的时候没必要继续占着设备和 CPU。醒来不自动恢复——突然出声更容易吓到人。
    private func stopForSystem(_ reason: String) {
        dcLog("system event: \(reason) (stopOnLock=\(stopOnLock), running=\(isRunning))")
        guard stopOnLock, isRunning else { return }
        stop()
        statusText = "\(reason)，分发已停止。"
        dcLog("auto stop: \(reason)")
    }

    // MARK: - 播放

    func togglePlay() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    private func start() {
        dcLog("AppModel.start() entered")

        let targets: [AudioDevice?] = slots.indices.map { device(for: $0) }

        guard targets.compactMap({ $0 }).count > 0 else {
            statusText = "还没有可用的输出设备。插上耳机或声卡后会自动接管。"
            return
        }

        if sourceMode == .file, fileURL == nil {
            statusText = "请先选择一个音频文件。"
            return
        }

        permissionHint = nil
        silenceSince = nil

        var tapScope = SystemTapSource.Scope.allApps

        if sourceMode == .system, captureScope == .apps {
            guard !selectedApps.isEmpty else {
                statusText = "采集范围是「选定 App」，但还没选。请点「采集」选好要采的 App，或改回「全部 App」。"
                return
            }

            // 进程对象随 App 启停而变，启动前重新解析一次。
            tapScope = .apps(Array(selectedApps))
        }

        do {
            let names = targets.compactMap { $0?.name }.joined(separator: " / ")
            dcLog("starting engine mode=\(sourceMode.rawValue) devices=\(names)")

            switch sourceMode {
            case .system:
                try engine.startSystemAudio(devices: targets, scope: tapScope)
            case .file:
                guard let url = fileURL else { return }
                try engine.start(fileURL: url, devices: targets, loop: loopFile)
            }

            dcLog("engine.start returned")

            applySettings()

            isRunning = true
            startedAt = Date()
            for index in slots.indices { slots[index].alive = true }
            ioWarning = nil
            statusText = runningSummary(targets: targets)

            if !engine.channelFailures.isEmpty {
                let detail = engine.channelFailures
                    .sorted { $0.key < $1.key }
                    .map { "\(channelLabel($0.key)) \($0.value)" }
                    .joined(separator: "；")
                statusText += " · 起步失败：\(detail)"
            }
        } catch {
            isRunning = false
            statusText = "启动失败：\(error.localizedDescription)"
            dcLog("start failed: \(error.localizedDescription)")
        }
    }

    private func runningSummary(targets: [AudioDevice?]) -> String {
        let devices = targets.compactMap { $0 }
        let idle = targets.count - devices.count

        var text = "引擎运行中 · \(Int(engine.sourceRate)) Hz / float32 · \(devices.count) 路"
        if idle > 0 { text += "（\(idle) 路等待设备）" }

        if Set(devices.map { $0.id }).count < devices.count {
            text += " · 有重复设备，声音会在同一端点叠加"
        } else if devices.filter({ $0.isBluetooth }).count >= 2 {
            text += " · 两路以上为蓝牙：系统一般只维持一路 A2DP，多半只有一路能出声"
        }

        return text
    }

    func stop() {
        engine.stop()
        isRunning = false

        for index in slots.indices {
            slots[index].peak = 0
            slots[index].alive = true
        }
        for index in peakStates.indices { peakStates[index] = 0 }

        silenceSince = nil
        startedAt = nil
        permissionHint = nil
        ioWarning = nil
        statusText = "已停止分发。"
    }

    private func applySettings() {
        for index in slots.indices {
            guard let channel = engine.channel(at: index) else { continue }

            channel.volume = Float(slots[index].volume / 100)
            channel.muted = slots[index].muted
            channel.offsetMs = slots[index].delay
            channel.eq.enabled = eqEnabled

            for band in 0..<TenBandEQ.bandCount where slots[index].eq.indices.contains(band) {
                channel.eq.setGain(Float(slots[index].eq[band]), at: band)
            }
        }
    }

    // MARK: - 均衡

    func applyPreset(_ values: [Double]) {
        for index in slots.indices { slots[index].eq = values }
        applySettings()
        persistAllSlots()
        statusText = "已应用预设。"
    }

    func resetEqualizers() {
        let zero = Array(repeating: 0.0, count: TenBandEQ.bandCount)
        for index in slots.indices { slots[index].eq = zero }
        applySettings()
        persistAllSlots()
        eqEnabled = true
        statusText = "均衡器已复位。"
    }

    // MARK: - 输出自检

    /// 在每一路上跑一次「设备到底会不会来拉数据」的检查。
    /// 用来回答「界面在跑、耳机没声」卡在哪一环：端点没被系统唤醒，还是源头没数据。
    func runOutputSelfCheck() {
        guard !isRunning else {
            statusText = "请先停止分发，再运行输出自检。"
            return
        }

        let targets = slots.indices.compactMap { device(for: $0) }
        guard !targets.isEmpty else {
            statusText = "请先为每一路选择输出设备。"
            return
        }

        statusText = "正在自检输出端点…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let measurements = targets.map { OutputProbe.measure($0, seconds: 0.8) }

            DispatchQueue.main.async {
                self?.presentSelfCheck(measurements)
            }
        }
    }

    private func presentSelfCheck(_ measurements: [OutputProbe.Measurement]) {
        var lines: [String] = []

        for (index, item) in measurements.enumerated() {
            let label = channelLabel(index)
            let state = item.works ? "✓ 有数据流" : "✗ 无数据流"
            lines.append("\(label)  \(item.device.name)")
            lines.append("    \(state) · \(item.callbacks) 次回调 / \(item.frames) 帧")
            if let error = item.error {
                lines.append("    错误：\(error)")
            }
        }

        let dead = measurements.filter { !$0.works }
        if !dead.isEmpty {
            lines.append("")
            if dead.contains(where: { $0.device.isBluetooth }) {
                lines.append("蓝牙端点没有数据流：macOS 通常只维持一路 A2DP 音频，第二副蓝牙耳机需要独立的蓝牙射频（USB 蓝牙音频发射器）。")
            } else {
                lines.append("端点没有数据流：检查线是否插好、是否被其他 App 独占、采样率是否被占用。")
            }
        }

        statusText = "输出自检完成。"

        let alert = NSAlert()
        alert.messageText = "输出自检"
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - 指标刷新

    private func tick() {
        for index in slots.indices {
            guard let channel = engine.channel(at: index) else { continue }

            while peakStates.count <= index { peakStates.append(0) }

            // 空槽位没有通道在跑，指标全部归零——否则会留着断开瞬间的残留值，
            // 界面上看起来像「断了还在响」。
            guard slots[index].deviceID != nil else {
                peakStates[index] = 0
                slots[index].peak = 0
                slots[index].underrunMs = 0
                slots[index].driftPPM = 0
                continue
            }

            let decayed = max(Double(channel.peakLevel), peakStates[index] * 0.86)
            peakStates[index] = decayed < 0.0005 ? 0 : decayed

            slots[index].peak = peakStates[index]
            slots[index].underrunMs = channel.underrunMs
            slots[index].driftPPM = channel.correctionPPMValue
        }

        updatePermissionHint()
        updateIOHealth()
        logMetrics()
    }

    /// 判断每一路是不是真的在被设备拉数据。
    /// 判据是渲染回调次数：`AudioOutputUnitStart` 成功只能说明单元配置对了，
    /// 蓝牙链路被系统挂起时它会照样返回成功，然后一次回调都不来。
    private func updateIOHealth() {
        guard isRunning, let startedAt else {
            for index in slots.indices { slots[index].alive = true }
            ioWarning = nil
            return
        }

        // 给 1 秒缓冲：设备刚启动时第一轮回调可能还没到。
        guard Date().timeIntervalSince(startedAt) > 1.0 else { return }

        var dead: [String] = []

        for index in slots.indices {
            // 没有设备的槽位是「等待接管」，不是「被挂起」，不能算进告警。
            guard slots[index].deviceID != nil else {
                slots[index].alive = true
                continue
            }

            let alive = (engine.channel(at: index)?.renderCallbacks ?? 0) > 0
            slots[index].alive = alive
            if !alive { dead.append(channelLabel(index)) }
        }

        if dead.isEmpty {
            if ioWarning != nil { ioWarning = nil }
        } else {
            ioWarning = "输出 \(dead.joined(separator: "、")) 没有音频数据流：设备已被系统挂起（蓝牙常见），换用有线/USB 端点或重新连接该耳机。"
        }
    }

    /// 每秒打一行指标。只用于命令行自测（`DUOCAST_DEBUG=1`），
    /// 界面看得到的东西不必再进日志，但脚本化回归需要一个可断言的数字出口。
    private func logMetrics() {
        tickCount += 1
        guard tickCount % 20 == 0 else { return }

        let peaks = slots.indices.map { String(format: "%@ %.4f", channelLabel($0), slots[$0].peak) }.joined(separator: " ")
        let underruns = slots.indices.map { String(format: "%@ %.1f", channelLabel($0), slots[$0].underrunMs) }.joined(separator: " ")
        let drifts = slots.indices.map { String(format: "%@ %+.0f", channelLabel($0), slots[$0].driftPPM) }.joined(separator: " ")

        dcLog("metrics peak \(peaks) | underrun \(underruns) ms | drift \(drifts) ppm | sysAudio \(engine.systemHasReceivedAudio ? "yes" : "no")")
    }

    /// 系统声音模式下，采集端拿到的数据全为零有两种可能：用户还没开始播放，或者录音权限没给。
    /// 无法从 API 上直接区分（权限被拒时 tap 依然能建立，只是数据为静音），所以按时间给出提示。
    private func updatePermissionHint() {
        guard isRunning, sourceMode == .system else {
            silenceSince = nil
            if permissionHint != nil { permissionHint = nil }
            return
        }

        engine.refreshSystemAudioFlag()

        if engine.systemHasReceivedAudio {
            silenceSince = nil
            if permissionHint != nil { permissionHint = nil }
            return
        }

        guard let since = silenceSince else {
            silenceSince = Date()
            return
        }

        if permissionHint == nil, Date().timeIntervalSince(since) > 3 {
            permissionHint = "已运行 3 秒，采集到的仍是数字静音。若此刻正在播放声音，请到「系统设置 › 隐私与安全性 › 录屏与系统录音」允许 DuoCast，然后重启应用。"
        }
    }
}
