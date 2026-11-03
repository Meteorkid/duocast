import Foundation
import SwiftUI

struct ChannelCard: View {

    @ObservedObject var model: AppModel
    let index: Int

    private static let frequencyLabels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    private var slot: OutputSlot {
        model.slots.indices.contains(index) ? model.slots[index] : OutputSlot()
    }

    private var accent: Color {
        switch index {
        case 0: return Theme.accentA
        case 1: return Theme.accentB
        default: return Theme.accentC
        }
    }

    private var badgeBackground: Color {
        switch index {
        case 0: return Color(hex: 0x26241F)
        case 1: return Color(hex: 0x241F16)
        default: return Color(hex: 0x17211D)
        }
    }

    private var title: String {
        switch index {
        case 0: return "输出 A · 主控"
        case 1: return "输出 B · 辅助"
        default: return "输出 C · 扩展"
        }
    }

    private var device: AudioDevice? { model.device(for: index) }
    private var isMuted: Bool { slot.muted }
    private var isAlive: Bool { slot.alive }
    private var peak: Double { slot.peak }
    private var underrunMs: Double { slot.underrunMs }
    private var driftPPM: Double { slot.driftPPM }

    private var volume: Binding<Double> { model.volumeBinding(index) }
    private var delay: Binding<Double> { model.delayBinding(index) }
    private var muted: Binding<Bool> { model.mutedBinding(index) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            deviceMenu.padding(.top, 14)
            volumeSection.padding(.top, 16)
            delaySection.padding(.top, 12)
            meterSection.padding(.top, 14)

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.top, 16)

            eqSection.padding(.top, 12)
            footer.padding(.top, 12)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .overlay(Rectangle().stroke(Theme.hairline))
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 10) {
            Text(model.channelLabel(index))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 24, height: 24)
                .background(Rectangle().fill(badgeBackground))
                .overlay(Rectangle().stroke(Theme.hairlineStrong))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Text(connectionText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(model.isRunning && !isAlive ? Theme.warning : Theme.textQuiet)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            Button {
                muted.wrappedValue = !isMuted
            } label: {
                Text(isMuted ? "已静音" : "静音")
                    .foregroundStyle(isMuted ? Theme.warning : Theme.textSecondary)
            }
            .buttonStyle(GhostButtonStyle())

            if model.slots.count > 1 {
                Button {
                    model.removeSlot(at: index)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textQuiet)
                        .frame(width: 24, height: 26)
                        .overlay(Rectangle().stroke(Theme.hairlineStrong))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("移除这一路输出")
            }
        }
    }

    private var connectionText: String {
        guard let device else {
            return model.isRunning ? "等待设备接入（自动接管）" : "未连接 · 等待设备"
        }
        guard model.isRunning else { return "已选择 · 未启动" }
        guard isAlive else { return "无数据流 · \(device.name)" }
        return "已连接 · \(device.name)"
    }

    // MARK: - 设备

    private var deviceMenu: some View {
        Menu {
            ForEach(model.devices) { item in
                Button(item.displayName) {
                    model.selectDevice(item.id, slot: index)
                }
            }

            if model.devices.isEmpty {
                Text("无可用输出设备")
            }

            Divider()

            Button("刷新设备列表") {
                model.refreshDevices()
            }
        } label: {
            HStack(spacing: 8) {
                Text(device?.displayName ?? "选择输出设备")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textQuiet)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Theme.background.opacity(0.45))
            .overlay(Rectangle().stroke(Theme.hairlineStrong))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 音量

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("通道增益")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(hex: 0x7A746C))

                Spacer()

                Text(decibelText)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textQuiet)
                    .monospacedDigit()
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(volume.wrappedValue.rounded()))")
                    .font(Theme.monoBig)
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()

                Text("%")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textQuiet)
                    .padding(.bottom, 8)
            }

            Slider(value: volume, in: 0...120)
                .tint(accent)
        }
    }

    private var decibelText: String {
        let percent = volume.wrappedValue
        guard percent > 0.5 else { return "-∞ dB" }
        return String(format: "%+.1f dB", 20 * log10(percent / 100))
    }

    // MARK: - 延迟补偿

    /// 蓝牙耳机有 100–200 ms 的固有延迟，有线/内置几乎为零。
    /// 多人同时听同一个东西时，这个差值是唯一会让人觉得「对不上」的原因，
    /// 所以每路给一个独立的额外延迟，把快的那一路拖到慢的那一路。
    private var delaySection: some View {
        HStack(spacing: 10) {
            Text("延迟")
                .font(.system(size: 10.5))
                .foregroundStyle(Color(hex: 0x7A746C))
                .frame(width: 32, alignment: .leading)

            Slider(value: delay, in: 0...300, step: 5)
                .tint(accent)
                .help("给这一路加额外延迟（0–300 ms）。蓝牙比有线慢 100–200 ms，所以延迟要加在有线/内置扬声器那几路上，把它们拖到和蓝牙一致。")

            Text(String(format: "%d ms", Int(delay.wrappedValue)))
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textQuiet)
                .monospacedDigit()
                .frame(width: 50, alignment: .trailing)
        }
    }

    // MARK: - 电平

    private var meterSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("输出电平")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(hex: 0x7A746C))

                Spacer()

                Text(peakText)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textQuiet)
                    .monospacedDigit()
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.trackDeep)

                    Rectangle()
                        .fill(accent)
                        .frame(width: max(0, min(1, peak)) * geometry.size.width)
                }
            }
            .frame(height: 6)
        }
    }

    private var peakText: String {
        guard peak > 0 else { return "—" }
        return String(format: "%.1f dBFS", 20 * log10(peak))
    }

    // MARK: - 均衡

    private var eqSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("10 段均衡")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(hex: 0x7A746C))

                Spacer()

                Text(model.eqEnabled ? "±12 dB" : "旁通")
                    .font(Theme.monoSmall)
                    .foregroundStyle(model.eqEnabled ? Color(hex: 0x5F5A54) : Theme.warning)
            }

            HStack(spacing: 0) {
                ForEach(0..<TenBandEQ.bandCount, id: \.self) { band in
                    EqBandSlider(
                        value: model.eqBinding(channel: index, band: band),
                        accent: accent,
                        frequency: Self.frequencyLabels[band]
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 128)
        }
    }

    // MARK: - 底部指标

    private var footer: some View {
        HStack(spacing: 12) {
            Text(String(format: "欠载 %.1f ms", underrunMs))
            Spacer()
            Text(model.isRunning ? String(format: "漂移 %+.1f ppm", driftPPM) : "漂移 —")
        }
        .font(Theme.monoSmall)
        .foregroundStyle(Theme.textMuted)
        .monospacedDigit()
    }
}
