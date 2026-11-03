import Foundation

/// 极简日志：写 stderr。
/// 默认静默，只有 `DUOCAST_DEBUG=1` 时才输出——
/// GUI 应用从 Finder 启动时 stderr 没人看，留着只会污染日志；
/// 但排查「启动卡在哪一步」时它是唯一线索。
///
/// 用法：
///   DUOCAST_DEBUG=1 ./DuoCast.app/Contents/MacOS/DuoCast --play /path/a.aiff
func dcLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["DUOCAST_DEBUG"] == "1" else { return }
    FileHandle.standardError.write(Data(("[DuoCast] " + message + "\n").utf8))
}
