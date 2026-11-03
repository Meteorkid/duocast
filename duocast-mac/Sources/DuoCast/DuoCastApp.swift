import SwiftUI

@main
struct DuoCastApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    init() {
        // 自检命令不进入界面：跑完直接退出，方便脚本与远程排障。
        if CommandLine.arguments.contains("--probe-outputs") {
            exit(OutputProbe.run())
        }
    }

    var body: some Scene {
        WindowGroup("DuoCast · 多路音频分发器", id: "main") {
            ContentView(model: model)
                // 每多一路输出就多一列卡片，窗口跟着变宽；两路时不额外占地方。
                .frame(
                    minWidth: 1_020 + CGFloat(max(0, model.slots.count - 2)) * 380,
                    idealWidth: 1_040 + CGFloat(max(0, model.slots.count - 2)) * 380,
                    minHeight: 740
                )
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let controller = MenuBarController(model: AppModel.shared)
        controller.install()
        menuBar = controller
        AppModel.shared.menuBar = controller

        handleDebugFlags()
    }

    /// 关窗口不再退出应用：窗口只是控制面板，引擎和菜单栏还要继续工作。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 点 Dock 图标时把控制面板找回来。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }

        return true
    }

    /// Dock 图标右键菜单。
    ///
    /// 这是菜单栏之外的第二个常驻入口，不是冗余：菜单栏右侧一旦被占满，
    /// 系统会把新状态项排到屏幕外（本机实测连续三个都落在负坐标、不可见），
    /// 而 Dock 菜单和全局快捷键不受这个限制。
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let model = AppModel.shared
        let menu = NSMenu()

        let toggle = NSMenuItem(
            title: model.isRunning ? "停止分发" : "开始分发（\(model.hotKeyLabel)）",
            action: #selector(toggleFromDock),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        let show = NSMenuItem(title: "显示控制面板", action: #selector(showFromDock), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        return menu
    }

    @objc private func toggleFromDock() {
        AppModel.shared.togglePlay()
    }

    @objc private func showFromDock() {
        showMainWindow()
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            WindowActions.shared.openWindow?()
        }
    }

    /// 自测用：`--close-window 2` 会在 2 秒后关掉窗口，用来验证「关窗不退出」这条路径。
    private func handleDebugFlags() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--close-window"),
              index + 1 < arguments.count,
              let delay = Double(arguments[index + 1]) else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NSApp.windows.first(where: { $0.canBecomeMain })?.close()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let visible = NSApp.windows.filter { $0.isVisible }.count
                dcLog("after window close: app alive=true, visible windows=\(visible), menuBar=\(self.menuBar != nil)")
            }
        }
    }
}
