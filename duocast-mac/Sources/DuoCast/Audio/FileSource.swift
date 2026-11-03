import AVFoundation
import Foundation

/// 本地音频文件作为输入源：解码成交错立体声 float32，按真实时间节奏喂给两路。
///
/// 为什么要自带一个「按真实时间喂」的泵：两个输出单元各自按自己的时钟拉数据，
/// 如果我们一次性把整个文件塞进环形缓冲，2 秒容量立刻溢出。
/// 泵按「已喂时长 ≈ 墙钟时长」的节奏推进，剩下的少量偏差交给读步长的漂移补偿去吸收。
final class FileSource {

    let url: URL
    let sampleRate: Double

    var loop = true
    var onBuffer: ((UnsafePointer<Float>, Int) -> Void)?
    var onFinished: (() -> Void)?

    private var running = false
    private var thread: Thread?

    init(url: URL) throws {
        self.url = url

        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        sampleRate = rate > 0 ? rate : 48_000
    }

    func start() {
        guard !running else { return }

        running = true

        let thread = Thread { [weak self] in
            self?.pump()
        }
        thread.name = "DuoCast.FilePump"
        thread.qualityOfService = .userInitiated

        self.thread = thread
        thread.start()
    }

    func stop() {
        running = false
        thread = nil
    }

    private func pump() {
        var reachedEnd = false

        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let channels = Int(format.channelCount)
            // 块要小：块越大，环形缓冲水位摆幅越大，漂移控制器越容易饱和。
            // 256 帧在 22.05k 下约 11.6 ms，配合 2 ms 的睡眠粒度可以喂得很均匀。
            let capacity: AVAudioFrameCount = 256

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                running = false
                DispatchQueue.main.async { [weak self] in self?.onFinished?() }
                return
            }

            dcLog("pump: file opened, format=\(format.sampleRate) Hz / \(channels) ch / frames=\(file.length)")

            var scratch = [Float](repeating: 0, count: Int(capacity) * 2)
            var fedSeconds = 0.0
            let startedAt = DispatchTime.now().uptimeNanoseconds

            while running {
                // EOF 必须主动判断：AVAudioFile.read 在文件末尾会抛 nilError，
                // 而不是像文档暗示的那样返回 0 帧。不先判断就会把「播放结束」当成异常。
                if file.framePosition >= file.length {
                    if loop {
                        file.framePosition = 0
                    } else {
                        reachedEnd = true
                        break
                    }
                }

                buffer.frameLength = 0
                try file.read(into: buffer, frameCount: capacity)

                let frames = Int(buffer.frameLength)
                if frames == 0 {
                    if loop {
                        file.framePosition = 0
                        continue
                    }

                    reachedEnd = true
                    break
                }

                guard let channelData = buffer.floatChannelData else {
                    reachedEnd = true
                    break
                }

                scratch.withUnsafeMutableBufferPointer { destination in
                    for frame in 0..<frames {
                        let left = channelData[0][frame]
                        let right = channels > 1 ? channelData[1][frame] : left
                        destination[frame * 2] = left
                        destination[frame * 2 + 1] = right
                    }
                }

                scratch.withUnsafeBufferPointer { source in
                    guard let base = source.baseAddress else { return }
                    self.onBuffer?(base, frames)
                }

                fedSeconds += Double(frames) / format.sampleRate
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000
                let ahead = fedSeconds - elapsed

                // 睡满这一块对应的时长：块 11.6 ms 就睡到 11.6 ms 之后再读下一块。
                // 之前只睡 2 ms 等于几乎没有节流，泵会把缓冲灌满、节流彻底失效。
                if ahead > 0.001 {
                    Thread.sleep(forTimeInterval: min(ahead, 0.012))
                }
            }
        } catch {
            dcLog("pump: error \(error)")
            reachedEnd = true
        }

        dcLog("pump: exit, reachedEnd=\(reachedEnd), running=\(running)")
        running = false

        if reachedEnd {
            DispatchQueue.main.async { [weak self] in
                self?.onFinished?()
            }
        }
    }
}
