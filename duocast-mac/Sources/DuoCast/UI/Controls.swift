import AppKit
import Carbon.HIToolbox
import SwiftUI

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(configuration.isPressed ? Color.white.opacity(0.08) : Color.clear)
            .overlay(Rectangle().stroke(Theme.hairlineStrong))
            .contentShape(Rectangle())
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color(hex: 0x0F0E0E))
            .padding(.horizontal, 18)
            .frame(height: 30)
            .background(Color(hex: configuration.isPressed ? 0xE4E4E4 : 0xF2F2F2))
            .contentShape(Rectangle())
    }
}

/// 输入源分段选择器。用自绘而不是 Picker(.segmented)：
/// 系统分段控件在深色主题里自带浅色描边与圆角，和这套方角细线的界面不一致。
struct SourceModePicker: View {

    @Binding var selection: SourceMode

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SourceMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    Text(mode.title)
                        .font(.system(size: 11, weight: selection == mode ? .medium : .regular))
                        .foregroundStyle(selection == mode ? Color(hex: 0x0F0E0E) : Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(selection == mode ? Color(hex: 0xE8E8E8) : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 28)
        .overlay(Rectangle().stroke(Theme.hairlineStrong))
    }
}

/// 采集范围选择器：「全部 App」或只挑几个 App。
///
/// 用 popover 而不是把复选框直接铺在工具条上：可选 App 的列表随时在变（谁在放声音谁就在），
/// 常驻一块区域会一直闪；而且绝大多数用户只用默认的「全部 App」。
struct CaptureScopeControl: View {

    @ObservedObject var model: AppModel
    @State private var showing = false

    private var title: String {
        switch model.captureScope {
        case .all:
            return "采集：全部 App"
        case .apps:
            return model.selectedApps.isEmpty ? "采集：未选择" : "采集：\(model.selectedApps.count) 个 App"
        }
    }

    var body: some View {
        Button {
            model.refreshSelectableApps()
            showing = true
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
        }
        .buttonStyle(GhostButtonStyle())
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            popoverContent
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(title: "全部 App", subtitle: "整机混音", checked: model.captureScope == .all, playing: false) {
                model.setCaptureScope(.all)
            }

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.vertical, 6)

            Text("只采集这些 App")
                .font(.system(size: 10.5))
                .foregroundStyle(Color(hex: 0x7A746C))
                .padding(.bottom, 6)

            if model.selectableApps.isEmpty {
                Text("当前没有正在使用音频的 App")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.selectableApps) { app in
                            row(
                                title: app.name,
                                subtitle: app.isPlaying ? "正在出声" : app.id,
                                checked: model.captureScope == .apps && model.isSelected(app.id),
                                playing: app.isPlaying
                            ) {
                                model.toggleApp(app.id)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.vertical, 6)

            HStack {
                Button {
                    model.refreshSelectableApps()
                } label: {
                    Text("刷新列表")
                }
                .buttonStyle(GhostButtonStyle())

                Spacer()

                Text("改完需重新开始分发")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(12)
        .frame(width: 340)
        .background(Theme.surface)
    }

    private func row(title: String, subtitle: String, checked: Bool, playing: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(checked ? Theme.accentB : Theme.textQuiet)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(subtitle)
                        .font(Theme.monoSmall)
                        .foregroundStyle(playing ? Theme.accentC : Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 6)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 设置面板：全局快捷键、锁屏自动停止、存档位置。
struct SettingsPanel: View {

    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("全局快捷键")
                .font(.system(size: 10.5))
                .foregroundStyle(Color(hex: 0x7A746C))
                .padding(.bottom, 6)

            HStack(spacing: 10) {
                HotKeyRecorder(model: model)

                Text("点一下再按新的组合键，至少含一个修饰键；Esc 取消")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.vertical, 10)

            Toggle(isOn: $model.stopOnLock) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("锁屏或休眠时停止分发")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textPrimary)

                    Text("人不在时不必继续占着设备；唤醒后不会自动恢复")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .toggleStyle(.checkbox)

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.vertical, 10)

            Button {
                model.revealSettingsFile()
            } label: {
                Text("打开存档位置")
            }
            .buttonStyle(GhostButtonStyle())
        }
        .padding(14)
        .frame(width: 380)
        .background(Theme.surface)
    }
}

/// 快捷键录制控件。
///
/// 用本地事件监听（`addLocalMonitorForEvents`）而不是自定义 NSView：
/// 录制只在设置面板打开时生效，不需要辅助功能权限，也不会影响别处的键盘输入。
struct HotKeyRecorder: View {

    @ObservedObject var model: AppModel

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stopRecording() : startRecording()
        } label: {
            Text(recording ? "按下组合键…" : model.hotKeyLabel)
                .foregroundStyle(recording ? Theme.warning : Theme.textPrimary)
                .frame(minWidth: 70)
        }
        .buttonStyle(GhostButtonStyle())
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        guard monitor == nil else { return }
        recording = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil   // 吞掉这次按键，避免触发菜单里的快捷键或响一声
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        recording = false
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }

        // 不带修饰键的组合会把普通输入劫走，不允许。
        guard carbon != 0 else {
            model.statusText = "快捷键至少要包含一个修饰键（⌃⌥⇧⌘）。"
            return
        }

        let label = Self.label(flags: flags, event: event)
        model.changeHotKey(code: UInt32(event.keyCode), modifiers: carbon, label: label)
        stopRecording()
    }

    private static func label(flags: NSEvent.ModifierFlags, event: NSEvent) -> String {
        var text = ""

        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }

        let key = event.charactersIgnoringModifiers?.uppercased() ?? "?"
        return text + key
    }
}

/// 标题栏里的双分叉标记：一路进、两路出。
struct Logomark: View {
    var body: some View {
        ZStack {
            Rectangle().stroke(Theme.accentB.opacity(0.45), lineWidth: 1)

            Path { path in
                path.move(to: CGPoint(x: 4, y: 10))
                path.addLine(to: CGPoint(x: 8, y: 10))
                path.move(to: CGPoint(x: 8, y: 10))
                path.addCurve(
                    to: CGPoint(x: 14, y: 5),
                    control1: CGPoint(x: 11, y: 10),
                    control2: CGPoint(x: 11, y: 5)
                )
                path.move(to: CGPoint(x: 8, y: 10))
                path.addCurve(
                    to: CGPoint(x: 14, y: 15),
                    control1: CGPoint(x: 11, y: 10),
                    control2: CGPoint(x: 11, y: 15)
                )
            }
            .stroke(Theme.textPrimary, lineWidth: 1.4)
        }
        .frame(width: 20, height: 20)
    }
}

/// 竖向均衡滑块：细轨道 + 零位刻度 + 从零位到当前值的填充。
/// 用自定义手势而不是旋转系统的水平滑块——旋转在 macOS 上会带来看不清的命中区和反直觉的拖动方向。
struct EqBandSlider: View {

    @Binding var value: Double
    var accent: Color
    var frequency: String
    var height: CGFloat = 96

    var body: some View {
        VStack(spacing: 4) {
            Text(String(format: "%+.1f", value))
                .font(Theme.monoSmall)
                .foregroundStyle(abs(value) >= 0.5 ? accent : Theme.textQuiet)
                .monospacedDigit()

            GeometryReader { geometry in
                let center = geometry.size.height / 2
                let usable = max(geometry.size.height / 2 - 6, 1)
                let thumbY = center - CGFloat(value / TenBandEQ.maxGainDb) * usable

                ZStack {
                    Capsule()
                        .fill(Theme.track)
                        .frame(width: 2)

                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(width: 14, height: 1)
                        .position(x: geometry.size.width / 2, y: center)

                    Capsule()
                        .fill(accent.opacity(0.4))
                        .frame(width: 2, height: abs(center - thumbY))
                        .position(x: geometry.size.width / 2, y: (center + thumbY) / 2)

                    RoundedRectangle(cornerRadius: 1)
                        .fill(accent)
                        .frame(width: geometry.size.width - 4, height: 4)
                        .position(x: geometry.size.width / 2, y: thumbY)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let clamped = min(max(gesture.location.y, 6), geometry.size.height - 6)
                            let raw = Double(center - clamped) / Double(usable) * TenBandEQ.maxGainDb
                            value = (raw * 2).rounded() / 2
                        }
                )
            }
            .frame(height: height)

            Text(frequency)
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textMuted)
        }
        .frame(width: 26)
    }
}
