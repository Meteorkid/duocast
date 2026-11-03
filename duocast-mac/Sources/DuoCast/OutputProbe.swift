import AudioToolbox
import CoreAudio
import Foundation

/// `--probe-outputs`：逐个 / 同时打开每个输出端点，看 HAL 到底有没有来拉数据。
///
/// 存在的理由：「两副蓝牙耳机能不能同时出声」这类问题只能靠实测回答，网上的说法互相矛盾。
/// 而 `AudioOutputUnitStart` 返回成功**不代表**设备真的在放——蓝牙链路被系统挂起时，
/// 单元照样能启动，但渲染回调一次都不会被调用。所以判据是回调次数与累计帧数，不是返回值。
///
/// 两阶段设计：
///   阶段 1 逐个试，定位「单独也放不了」的设备；
///   阶段 2 同时开全部，这才是真正的判据——有些设备单独能放、并存时被挤掉。
enum OutputProbe {

    /// 单个端点的测量结果。界面里的「输出自检」和命令行的 `--probe-outputs` 共用同一套判据。
    struct Measurement {
        let device: AudioDevice
        var started = false
        var callbacks: Int64 = 0
        var frames: Int64 = 0
        var error: String?

        var works: Bool { started && callbacks > 0 }
    }

    /// 打开一个端点，静音渲染一段时间，读数后关闭。
    /// 判据是回调次数：单元启动成功但一次回调都不来，说明设备没有在拉数据。
    static func measure(_ device: AudioDevice, seconds: Double) -> Measurement {
        var result = Measurement(device: device)
        let channel = OutputChannel(label: "probe-\(device.id)")
        channel.bufferMs = 20

        do {
            try channel.start(device: device, sourceRate: device.sampleRate)
            result.started = true
            Thread.sleep(forTimeInterval: seconds)
        } catch {
            result.error = error.localizedDescription
        }

        result.callbacks = channel.renderCallbacks
        result.frames = channel.renderedFrames
        channel.stop()

        return result
    }

    private struct Result {
        let device: AudioDevice
        var started = false
        var callbacks: Int64 = 0
        var frames: Int64 = 0
        var error: String?

        var works: Bool { started && callbacks > 0 }

        init(_ measurement: Measurement) {
            device = measurement.device
            started = measurement.started
            callbacks = measurement.callbacks
            frames = measurement.frames
            error = measurement.error
        }
    }

    static func run() -> Int32 {
        let devices = AudioDevices.outputDevices()

        print("DuoCast 输出端点自检")
        print(String(repeating: "=", count: 76))
        print("")

        guard !devices.isEmpty else {
            print("未发现可用的输出端点。")
            return 1
        }

        print("[阶段 1] 逐个单独打开（每路 0.6 s）")
        var singles: [Result] = []

        for device in devices {
            let result = Result(measure(device, seconds: 0.6))
            singles.append(result)
            printRow(result)
        }

        print("")
        print("[阶段 2] 全部端点同时打开（1.2 s）")
        print("        —— 这一阶段回答「能不能同时出声」，单独能放不代表并存能放。")

        var channels: [(Int, OutputChannel)] = []
        var simultaneous: [Result] = []

        for device in devices {
            var measurement = Measurement(device: device)
            let channel = OutputChannel(label: "probe2-\(device.id)")
            channel.bufferMs = 20

            do {
                try channel.start(device: device, sourceRate: device.sampleRate)
                measurement.started = true
            } catch {
                measurement.error = error.localizedDescription
            }

            channels.append((simultaneous.count, channel))
            simultaneous.append(Result(measurement))
        }

        Thread.sleep(forTimeInterval: 1.2)

        for (index, channel) in channels {
            simultaneous[index].callbacks = channel.renderCallbacks
            simultaneous[index].frames = channel.renderedFrames
            channel.stop()
        }

        print("")
        for result in simultaneous {
            printRow(result)
        }

        return verdict(singles: singles, simultaneous: simultaneous)
    }

    // MARK: - 输出

    private static func printRow(_ result: Result) {
        let device = result.device
        var transport = AudioDevices.transportName(device.transport)
        if device.isBluetooth { transport += " · 蓝牙" }

        let mark = result.works ? "✓" : "✗"
        let state = result.works ? "有数据流" : "无数据流"

        print("  \(mark)  \(device.name)  [\(transport)]  \(Int(device.sampleRate)) Hz  \(state)  \(result.callbacks) 回调 / \(result.frames) 帧")

        if let error = result.error {
            print("     └ 错误：\(error)")
        }
    }

    private static func verdict(singles: [Result], simultaneous: [Result]) -> Int32 {
        print("")
        print(String(repeating: "=", count: 76))

        let alive = simultaneous.filter { $0.works }
        print("同时打开时可用端点 \(alive.count) / \(simultaneous.count)")

        let bluetooth = simultaneous.filter { $0.device.isBluetooth }
        let aliveBluetooth = bluetooth.filter { $0.works }

        if bluetooth.count >= 2 {
            print("蓝牙端点 \(bluetooth.count) 个，同时打开后有数据流 \(aliveBluetooth.count) 个")

            if aliveBluetooth.count < 2 {
                print("")
                print("结论：这台机器上两副蓝牙耳机不能同时出声。")
                print("      第二副即使显示「已连接」，HAL 也不会向它推送音频。")
                print("      可行的替代：第二副改用 USB 蓝牙音频发射器（对系统是一个 USB 声卡），")
                print("      或第二副用有线/USB 耳机。见 README 第 8 节。")
            } else {
                print("")
                print("结论：这台机器上两副蓝牙耳机可以同时出声。")
            }
        } else if !bluetooth.isEmpty {
            print("蓝牙端点 \(bluetooth.count) 个，同时打开后有数据流 \(aliveBluetooth.count) 个")
            print("要验证「两副蓝牙」需先连接第二副蓝牙耳机再运行本命令。")
        }

        let dead = simultaneous.filter { !$0.works }
        for item in dead {
            print("")
            print("注意：\(item.device.name) 在同时打开时没有数据流。")
        }

        return dead.isEmpty ? 0 : 2
    }
}
