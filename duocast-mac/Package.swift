// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DuoCast",
    // 14.2 是 Process Tap（AudioHardwareCreateProcessTap）的最低版本，
    // 系统音频采集靠它实现，低于这个版本无法做产品主路径。
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "DuoCast",
            path: "Sources/DuoCast",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
