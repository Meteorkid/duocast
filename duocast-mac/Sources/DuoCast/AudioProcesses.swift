import AppKit
import CoreAudio
import Foundation

/// 一个「正在使用音频的 App」。
///
/// 身份用 bundle ID 而不是 HAL 的进程对象 ID：后者每次启动都变，存不住，
/// 也不适合作为界面上的勾选键。同一个 App 的多个进程（Chrome 的 Helper、
/// WebKit 的 GPU 进程）合并成一条。
struct AudioApp: Identifiable, Hashable {
    let id: String
    let name: String
    /// 当前是否真的在做音频 IO。为 false 只说明「静着」，不代表不能选——
    /// 暂停的播放器进程对象通常还在，选定后一按播放就能采到。
    let isPlaying: Bool
}

/// 枚举 HAL 里的音频进程。
///
/// Process Tap 的「只采某个 App」有两条路：
/// 1. `CATapDescription.bundleIDs`（macOS 26+）——实测**单独使用不生效**：
///    把 bundleIDs 设成 `com.duocast.app`、进程列表留空，DuoCast 明明在出声（峰值 0.17–0.28），
///    采集端却全程 0；
/// 2. `initStereoMixdownOfProcesses:` 传 HAL 进程对象 ID——实测有效（同一场景峰值 0.39–0.65）。
///
/// 所以走第 2 条：先按 bundle ID 把进程对象找出来，再建 tap。
enum AudioProcesses {

    /// 按 bundle ID 找出对应的 HAL 进程对象。一个 App 可能有多个（Helper、GPU 进程）。
    static func processObjects(for bundleIDs: [String]) -> [AudioObjectID] {
        let wanted = Set(bundleIDs)
        guard !wanted.isEmpty else { return [] }

        return enumerate()
            .filter { entry in
                guard let bundleID = entry.bundleID else { return false }
                return wanted.contains(bundleID)
            }
            .map { $0.object }
    }

    /// 界面上可选的 App 列表：按 bundle ID 归并，正在出声的排在前面。
    static func audioApps(excluding excluded: Set<String> = []) -> [AudioApp] {
        var merged: [String: (name: String, playing: Bool)] = [:]

        for entry in enumerate() {
            guard let bundleID = entry.bundleID, !bundleID.isEmpty else { continue }
            guard !excluded.contains(bundleID) else { continue }

            let name = displayName(bundleID: bundleID, pid: entry.pid)

            if let existing = merged[bundleID] {
                // 同一个 bundle 的多个进程：名字取最短的那个（Helper 的名字总是更长），
                // 播放状态取「任一进程在跑」。
                let shortest = name.count < existing.name.count ? name : existing.name
                merged[bundleID] = (shortest, existing.playing || entry.running)
            } else {
                merged[bundleID] = (name, entry.running)
            }
        }

        return merged
            .map { AudioApp(id: $0.key, name: $0.value.name, isPlaying: $0.value.playing) }
            .sorted { left, right in
                if left.isPlaying != right.isPlaying { return left.isPlaying }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
    }

    // MARK: - 内部

    private struct Entry {
        let object: AudioObjectID
        let pid: pid_t
        let bundleID: String?
        let running: Bool
    }

    private static func enumerate() -> [Entry] {
        var address = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0

        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }

        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else {
            return []
        }

        return objects.map { object in
            Entry(
                object: object,
                pid: pid_t(readUInt32(object, kAudioProcessPropertyPID) ?? 0),
                bundleID: readString(object, kAudioProcessPropertyBundleID),
                running: (readUInt32(object, kAudioProcessPropertyIsRunning) ?? 0) != 0
            )
        }
    }

    private static func displayName(bundleID: String, pid: pid_t) -> String {
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName, !name.isEmpty {
            return name
        }

        // 进程拿不到本地化名字时退到 bundle ID 的最后一段，至少能认出来。
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    private static func readUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = propertyAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)

        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }

        return value
    }

    private static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var unmanaged: Unmanaged<CFString>?

        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &unmanaged) == noErr,
              let unmanaged else {
            return nil
        }

        return unmanaged.takeRetainedValue() as String
    }

    private static func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
