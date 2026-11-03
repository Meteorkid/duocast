import Foundation

/// 10 段图示均衡：31 Hz – 16 kHz，每段一个 RBJ peaking biquad（Q = 1.41，约 1 倍频程带宽）。
///
/// 与 C# 版一一对应的实现。线程模型同样是「整组系数换引用」：
/// 系数由界面线程算好后装进不可变对象，音频线程每块只读一次引用，
/// 不会读到 b0 新、a1 旧的混搭组合（二阶节在这种状态下会瞬间发散）。
final class TenBandEQ {

    static let bandCount = 10
    static let minGainDb = -12.0
    static let maxGainDb = 12.0
    static let frequencies: [Double] = [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]

    private static let q = 1.41

    private final class Coefficients {
        let b0: Double
        let b1: Double
        let b2: Double
        let a1: Double
        let a2: Double

        init(_ b0: Double, _ b1: Double, _ b2: Double, _ a1: Double, _ a2: Double) {
            self.b0 = b0
            self.b1 = b1
            self.b2 = b2
            self.a1 = a1
            self.a2 = a2
        }

        static let identity = Coefficients(1, 0, 0, 0, 0)

        var isIdentity: Bool { self === Coefficients.identity }
    }

    private final class Band {
        var coefficients: Coefficients = Coefficients.identity

        private var lx1 = 0.0
        private var lx2 = 0.0
        private var ly1 = 0.0
        private var ly2 = 0.0
        private var rx1 = 0.0
        private var rx2 = 0.0
        private var ry1 = 0.0
        private var ry2 = 0.0

        func reset() {
            lx1 = 0; lx2 = 0; ly1 = 0; ly2 = 0
            rx1 = 0; rx2 = 0; ry1 = 0; ry2 = 0
        }

        func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int) {
            let c = coefficients
            guard !c.isIdentity else { return }

            for frame in 0..<frames {
                let index = frame * 2

                let leftInput = Double(buffer[index])
                var leftOutput = c.b0 * leftInput
                leftOutput += c.b1 * lx1
                leftOutput += c.b2 * lx2
                leftOutput -= c.a1 * ly1
                leftOutput -= c.a2 * ly2

                lx2 = lx1
                lx1 = leftInput
                ly2 = ly1
                ly1 = leftOutput
                buffer[index] = Self.clamp(leftOutput)

                let rightInput = Double(buffer[index + 1])
                var rightOutput = c.b0 * rightInput
                rightOutput += c.b1 * rx1
                rightOutput += c.b2 * rx2
                rightOutput -= c.a1 * ry1
                rightOutput -= c.a2 * ry2

                rx2 = rx1
                rx1 = rightInput
                ry2 = ry1
                ry1 = rightOutput
                buffer[index + 1] = Self.clamp(rightOutput)
            }
        }

        /// 系数被异常数据污染时，不让 NaN 顺着级联一路传下去。
        private static func clamp(_ value: Double) -> Float {
            if value.isNaN { return 0 }
            if value > 4 { return 4 }
            if value < -4 { return -4 }
            return Float(value)
        }
    }

    private let bands: [Band] = (0..<TenBandEQ.bandCount).map { _ in Band() }
    private var gains = [Float](repeating: 0, count: TenBandEQ.bandCount)
    private var sampleRate: Double = 48_000

    /// 旁通开关：关闭时完全跳过处理，用于 A/B 对比。
    var enabled = true

    func gain(at index: Int) -> Float {
        guard index >= 0, index < Self.bandCount else { return 0 }
        return gains[index]
    }

    func isFlat() -> Bool {
        gains.allSatisfy { abs($0) < 0.05 }
    }

    /// 按实际采样率重建全部系数并清空滤波器状态。每次开始播放时调用。
    func prepare(sampleRate: Double) {
        self.sampleRate = sampleRate > 4_000 ? sampleRate : 48_000

        for index in 0..<Self.bandCount {
            bands[index].reset()
            rebuild(index)
        }
    }

    func setGain(_ decibel: Float, at index: Int) {
        guard index >= 0, index < Self.bandCount else { return }

        let clamped = Float(min(max(Double(decibel), Self.minGainDb), Self.maxGainDb))
        guard abs(gains[index] - clamped) >= 0.001 else { return }

        gains[index] = clamped
        rebuild(index)
    }

    func setGains(_ values: [Float]) {
        for index in 0..<min(values.count, Self.bandCount) {
            setGain(values[index], at: index)
        }
    }

    func reset() {
        for index in 0..<Self.bandCount {
            setGain(0, at: index)
        }
    }

    /// 处理交错立体声缓冲区（原地改写）。
    func process(_ interleaved: UnsafeMutablePointer<Float>, frames: Int) {
        guard enabled, frames > 0 else { return }

        for band in bands {
            band.process(interleaved, frames: frames)
        }
    }

    private func rebuild(_ index: Int) {
        let decibel = Double(gains[index])
        let frequency = Self.frequencies[index]

        // 增益为 0，或该段越过奈奎斯特（低采样率下的 16 kHz）时退化为恒等。
        guard abs(decibel) >= 0.05, frequency < sampleRate * 0.45 else {
            bands[index].coefficients = Coefficients.identity
            return
        }

        let a = pow(10.0, decibel / 40.0)
        let w0 = 2.0 * Double.pi * frequency / sampleRate
        let cosw0 = cos(w0)
        let alpha = sin(w0) / (2.0 * Self.q)
        let a0 = 1.0 + alpha / a

        bands[index].coefficients = Coefficients(
            (1.0 + alpha * a) / a0,
            -2.0 * cosw0 / a0,
            (1.0 - alpha * a) / a0,
            -2.0 * cosw0 / a0,
            (1.0 - alpha / a) / a0
        )
    }
}
