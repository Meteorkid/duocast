import Foundation

/// 交错立体声（L,R,L,R…）float32 环形缓冲。
///
/// 写入端：文件泵线程 / 采集线程；读取端：CoreAudio 渲染线程。
/// 这里用一把 NSLock 保护整块拷贝——和 Windows 版一样的取舍：
/// 每次操作是一条连续的标量循环，锁持有时间在微秒级，
/// 再靠 2 秒容量把「写满 / 读空」的概率压到可忽略。
final class StereoRing {

    struct ReadResult {
        var endPosition: Double
        var underrunFrames: Int
    }

    private var buffer: [Float]
    private let capacityFrames: Int
    private let mask: Int
    private let lock = NSLock()
    private var written: Int64 = 0

    init(capacityFrames: Int) {
        var capacity = 1
        while capacity < capacityFrames {
            capacity <<= 1
        }

        self.capacityFrames = capacity
        self.mask = capacity - 1
        self.buffer = [Float](repeating: 0, count: capacity * 2)
    }

    var capacity: Int { capacityFrames }

    var totalWritten: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return written
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }

        for index in buffer.indices {
            buffer[index] = 0
        }

        written = 0
    }

    func write(_ samples: [Float], frames: Int) {
        guard frames > 0 else { return }

        samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            self.write(base, frames: frames)
        }
    }

    func write(_ samples: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }

        lock.lock()
        defer { lock.unlock() }

        var count = frames
        var offset = 0

        if count > capacityFrames {
            offset = count - capacityFrames
            count = capacityFrames
        }

        for frame in 0..<count {
            let slot = Int((written + Int64(frame)) & Int64(mask))
            buffer[slot * 2] = samples[(offset + frame) * 2]
            buffer[slot * 2 + 1] = samples[(offset + frame) * 2 + 1]
        }

        written += Int64(count)
    }

    /// 从 start（帧，可为小数）开始按 step 步进读取，线性插值。
    /// step 同时承担两件事：写入/读取采样率不同时的重采样，以及时钟漂移修正。
    func readInterpolated(
        start: Double,
        step: Double,
        into output: UnsafeMutablePointer<Float>,
        frames: Int
    ) -> ReadResult {
        lock.lock()
        defer { lock.unlock() }

        var position = start
        var underruns = 0
        let lastValid = written - 1
        let oldestValid = written - Int64(capacityFrames)

        for frame in 0..<frames {
            let base = Int64(position.rounded(.down))
            let fraction = Float(position - Double(base))

            if base > lastValid - 1 || base < oldestValid {
                output[frame * 2] = 0
                output[frame * 2 + 1] = 0
                underruns += 1
            } else {
                let first = Int(base & Int64(mask))
                let second = Int((base + 1) & Int64(mask))

                let left0 = buffer[first * 2]
                let right0 = buffer[first * 2 + 1]
                let left1 = buffer[second * 2]
                let right1 = buffer[second * 2 + 1]

                output[frame * 2] = left0 + (left1 - left0) * fraction
                output[frame * 2 + 1] = right0 + (right1 - right0) * fraction
            }

            position += step
        }

        return ReadResult(endPosition: position, underrunFrames: underruns)
    }
}
