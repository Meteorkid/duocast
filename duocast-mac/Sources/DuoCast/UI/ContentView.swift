import SwiftUI

struct ContentView: View {

    @ObservedObject var model: AppModel

    /// 菜单栏「显示主窗口」在没有窗口时用它重新打开。
    /// Environment 里的 `openWindow` 只有 View 能拿到，所以在这里注册给菜单栏用。
    @Environment(\.openWindow) private var openWindow

    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            sourceBar
                .padding(.horizontal, 24)
                .padding(.top, 16)

            channelToolbar
                .padding(.horizontal, 24)
                .padding(.top, 14)

            HStack(alignment: .top, spacing: 14) {
                ForEach(model.slots.indices, id: \.self) { index in
                    ChannelCard(model: model, index: index)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 16)

            Spacer(minLength: 0)
            statusBar
        }
        .background(Theme.background)
        .onAppear {
            WindowActions.shared.openWindow = { openWindow(id: "main") }
        }
    }

    // MARK: - 通道工具条

    private var channelToolbar: some View {
        HStack(spacing: 8) {
            Text("输出通道")
                .font(.system(size: 10.5))
                .foregroundStyle(Color(hex: 0x7A746C))

            Text("\(model.slots.count) / \(AppModel.maxChannels)")
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textMuted)
                .monospacedDigit()

            Spacer()

            Button {
                model.addSlot()
            } label: {
                Text(model.canAddSlot ? "+ 添加一路" : "已达上限")
            }
            .buttonStyle(GhostButtonStyle())
            .disabled(!model.canAddSlot)
        }
    }

    // MARK: - 标题栏

    private var header: some View {
        HStack(spacing: 10) {
            Logomark()

            Text("DuoCast")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Rectangle()
                .fill(Color(hex: 0x2E2B27))
                .frame(width: 1, height: 14)

            Text("多路音频分发 · CoreAudio 多设备输出")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textQuiet)

            Spacer()

            Button {
                model.refreshDevices()
            } label: {
                Text("刷新设备")
            }
            .buttonStyle(GhostButtonStyle())

            Button {
                model.runOutputSelfCheck()
            } label: {
                Text("输出自检")
            }
            .buttonStyle(GhostButtonStyle())

            Button {
                showingSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(Rectangle().stroke(Theme.hairlineStrong))
            .help("设置：全局快捷键、锁屏行为、存档位置")
            .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                SettingsPanel(model: model)
            }

            HStack(spacing: 7) {
                Circle()
                    .fill(model.isRunning ? Theme.success : Theme.textMuted)
                    .frame(width: 6, height: 6)

                Text(model.isRunning ? "引擎运行中" : "引擎待机")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .overlay(Rectangle().stroke(Theme.hairlineStrong))
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(Theme.header)
    }

    // MARK: - 输入源

    private var sourceBar: some View {
        HStack(spacing: 14) {
            SourceModePicker(selection: $model.sourceMode)

            VStack(alignment: .leading, spacing: 4) {
                Text("输入源")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(hex: 0x7A746C))

                Text(model.sourceName)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 186, alignment: .leading)

            if model.sourceMode == .file {
                Button {
                    model.chooseFile()
                } label: {
                    Text("选择音频文件")
                }
                .buttonStyle(GhostButtonStyle())

                Toggle(isOn: $model.loopFile) {
                    Text("循环")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                .toggleStyle(.checkbox)
            } else {
                CaptureScopeControl(model: model)
            }

            Spacer(minLength: 8)

            Text(model.isRunning ? "\(Int(model.engine.sourceRate)) Hz / float32" : "—")
                .font(Theme.mono)
                .foregroundStyle(Theme.textQuiet)
                .monospacedDigit()

            Button {
                model.togglePlay()
            } label: {
                Text(model.isRunning ? "停止分发" : "开始分发")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 16)
        .frame(height: 68)
        .background(Theme.surface)
        .overlay(Rectangle().stroke(Theme.hairline))
    }

    // MARK: - 状态栏

    private var statusBar: some View {
        HStack(spacing: 16) {
            Text(statusLine)
                .font(.system(size: 11))
                .foregroundStyle(statusIsWarning ? Theme.warning : Theme.textQuiet)
                .lineLimit(1)
                .help(statusLine)

            Spacer()

            Text("\(model.hotKeyLabel) 切换")
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textMuted)
                .help("全局快捷键：开始 / 停止分发（窗口关掉也有效，可在设置里改）")

            Text(driftSummary)
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textMuted)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .frame(height: 34)
        .background(Theme.header)
    }

    private var statusLine: String {
        model.permissionHint ?? model.ioWarning ?? model.statusText
    }

    private var statusIsWarning: Bool {
        model.permissionHint != nil || model.ioWarning != nil
    }

    private var driftSummary: String {
        guard model.isRunning else { return "漂移 —" }

        let parts = model.slots.indices.map {
            String(format: "%@ %+.0f", model.channelLabel($0), model.slots[$0].driftPPM)
        }

        return "漂移 " + parts.joined(separator: " / ") + " ppm"
    }
}
