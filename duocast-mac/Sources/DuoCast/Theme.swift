import SwiftUI

/// 与 Windows 版共用的一套色板：炭黑底、卡片 #161513、1px 细线、通道 A 白 / B 哑金。
enum Theme {

    static let background = Color(hex: 0x0F0E0E)
    static let header = Color(hex: 0x131210)
    static let surface = Color(hex: 0x161513)
    static let surfaceRaised = Color(hex: 0x1C1A17)

    static let textPrimary = Color(hex: 0xF2F2F2)
    static let textSecondary = Color(hex: 0xC9C3BA)
    static let textQuiet = Color(hex: 0x8A857F)
    static let textMuted = Color(hex: 0x6E6862)

    static let accentA = Color(hex: 0xF2F2F2)
    static let accentB = Color(hex: 0xE8C268)
    static let accentC = Color(hex: 0x7DD9A6)
    static let success = Color(hex: 0x7DD9A6)
    static let warning = Color(hex: 0xE8C268)

    static let track = Color(hex: 0x302D28)
    static let trackDeep = Color(hex: 0x211F1B)
    static let hairline = Color.white.opacity(0.11)
    static let hairlineStrong = Color.white.opacity(0.18)

    static let mono = Font.system(size: 11, design: .monospaced)
    static let monoSmall = Font.system(size: 9.5, design: .monospaced)
    static let monoBig = Font.system(size: 38, weight: .semibold, design: .monospaced)
}

extension Color {
    init(hex: Int) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}
