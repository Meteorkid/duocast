import AppKit
import Carbon.HIToolbox
import Combine

/// 需要由菜单栏触发、但只存在于 SwiftUI 环境里的动作（打开窗口）。
///
/// SwiftUI 的 `openWindow` 只能从 View 里拿到，AppDelegate 拿不到。
/// 这里做一层转交：ContentView 出现时注册，菜单栏调用时取用。
final class WindowActions {
    static let shared = WindowActions()
    var openWindow: (() -> Void)?
}

/// 快捷键的出厂值。用户改过之后以 `settings.json` 为准。
enum HotKeyDefaults {
    static let code = UInt32(kVK_ANSI_D)
    static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    static let label = "⌃⌥⌘D"
}

/// 菜单栏常驻 + 全局快捷键。
///
/// 为什么需要：DuoCast 实际使用中 90% 的时间只需要一个「开始/停止」开关，
/// 却要一直开着一个 1400 pt 宽的窗口。常驻菜单栏之后窗口可以关掉，切换靠快捷键。
///
/// 快捷键用 Carbon 的 `RegisterEventHotKey`：它在系统层注册，不需要辅助功能权限。
/// `NSEvent.addGlobalMonitorForEvents` 需要，而且只能监听不能拦截，反而更难用。
final class MenuBarController: NSObject, NSMenuDelegate {

    private let model: AppModel
    private let statusItem: NSStatusItem
    private var cancellables: Set<AnyCancellable> = []
    private let hotKey = GlobalHotKey()
    private(set) var hotKeyCode = HotKeyDefaults.code
    private(set) var hotKeyModifiers = HotKeyDefaults.modifiers

    init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
    }

    // MARK: - 安装

    func install() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly
        updateIcon()

        // 引擎启停、采集范围变化都要同步图标与菜单，否则状态栏会显示过期的状态。
        model.$isRunning
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)

        let registered = registerHotKey(code: model.hotKeyCode, modifiers: model.hotKeyModifiers)

        dcLog("menu bar installed, hotkey registered=\(registered) label=\(model.hotKeyLabel)")
        dcLog("status item: visible=\(statusItem.isVisible) hasImage=\(statusItem.button?.image != nil) length=\(statusItem.length) frame=\(statusItem.button?.frame.debugDescription ?? "-")")

        if let window = statusItem.button?.window {
            dcLog("status window frame=\(window.frame) screen=\(NSScreen.main?.frame.debugDescription ?? "-")")
        }
    }

    /// 换快捷键。注册失败时把旧的装回去——不能让用户既用不了新的、也丢了旧的。
    @discardableResult
    func applyHotKey(code: UInt32, modifiers: UInt32) -> Bool {
        let previousCode = hotKeyCode
        let previousModifiers = hotKeyModifiers

        if registerHotKey(code: code, modifiers: modifiers) {
            return true
        }

        _ = registerHotKey(code: previousCode, modifiers: previousModifiers)
        return false
    }

    @discardableResult
    private func registerHotKey(code: UInt32, modifiers: UInt32) -> Bool {
        let ok = hotKey.register(keyCode: code, modifiers: modifiers) { [weak self] in
            self?.model.togglePlay()
        }

        if ok {
            hotKeyCode = code
            hotKeyModifiers = modifiers
        }

        dcLog("hotkey register code=\(code) modifiers=\(modifiers) ok=\(ok)")
        return ok
    }

    // MARK: - 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: (model.isRunning ? "停止分发" : "开始分发") + "　\(model.hotKeyLabel)",
            action: #selector(togglePlay),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        let show = NSMenuItem(title: "显示主窗口", action: #selector(showWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 DuoCast", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private var statusTitle: String {
        var parts: [String] = [model.isRunning ? "运行中" : "待机"]

        if model.isRunning {
            parts.append("\(model.slots.count) 路")
        }

        let activeChannels = model.slots.filter { $0.deviceID != nil }.count
        if activeChannels < model.slots.count {
            parts.append("\(activeChannels)/\(model.slots.count) 路已接设备")
        }

        if model.sourceMode == .system {
            parts.append(model.captureScope == .all ? "全部 App" : "\(model.selectedApps.count) 个 App")
        } else {
            parts.append(model.sourceName)
        }

        return parts.joined(separator: " · ")
    }

    private func updateIcon() {
        let symbol = model.isRunning ? "hifispeaker.2.fill" : "hifispeaker.2"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "DuoCast")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = model.isRunning ? "DuoCast · 正在分发" : "DuoCast · 待机"

        // 菜单栏右侧被占满时，系统会把状态项排到屏幕外（不可见但仍存在）。
        // Dock 角标是这种情况下唯一能一眼看到状态的入口。
        NSApp.dockTile.badgeLabel = model.isRunning ? "ON" : nil
        NSApp.dockTile.display()
    }

    // MARK: - 动作

    @objc private func togglePlay() {
        model.togglePlay()
        updateIcon()
    }

    @objc private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
            return
        }

        WindowActions.shared.openWindow?()
    }

    @objc private func quit() {
        model.stop()
        NSApp.terminate(nil)
    }
}

/// 全局快捷键。Carbon 的注册方式不需要辅助功能权限，也不会被前台 App 吞掉。
final class GlobalHotKey {

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var handlerInstalled = false
    private var onTrigger: (() -> Void)?

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// 返回是否注册成功。被别的 App 占用时会返回 false——这种情况要如实告诉用户，
    /// 不能装作注册上了。
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, onTrigger: @escaping () -> Void) -> Bool {
        self.onTrigger = onTrigger

        // 事件处理器只装一次；换快捷键只换注册，不重复装处理器（否则会越换越多）。
        if !handlerInstalled {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )

            let installStatus = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, userData -> OSStatus in
                    guard let userData else { return OSStatus(eventNotHandledErr) }
                    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                    hotKey.onTrigger?()
                    return noErr
                },
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &handlerRef
            )

            guard installStatus == noErr else {
                dcLog("hotkey: InstallEventHandler failed \(installStatus)")
                return false
            }

            handlerInstalled = true
        }

        unregister()

        // 'DUCS'
        let hotKeyID = EventHotKeyID(signature: OSType(0x44554353), id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus != noErr {
            dcLog("hotkey: RegisterEventHotKey failed \(registerStatus)")
            return false
        }

        return true
    }

    func unregister() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
    }
}
