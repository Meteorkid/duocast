using System;

namespace DuoCast.Audio;

/// <summary>
/// 10 段图示均衡：31 Hz – 16 kHz，每段一个 RBJ peaking biquad（Q = 1.41，约 1 倍频程带宽）。
///
/// 线程模型：
///   系数由界面线程修改，音频处理在采集线程的 Push 里跑。
///   每段把「一整组系数」装进一个不可变对象，改系数时整组替换引用（volatile 写），
///   音频线程一次读到的必然是同一组 b0/b1/b2/a1/a2，不会出现新旧混搭导致的爆音。
///   系数全为恒等时（增益 0 或该段超出奈奎斯特），处理直接短路返回。
/// </summary>
public sealed class TenBandEqualizer
{
    public const int BandCount = 10;
    public const double MinGainDb = -12.0;
    public const double MaxGainDb = 12.0;

    private const double Q = 1.41;

    private static readonly double[] CenterFrequencies = { 31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 };

    private readonly Band[] _bands = new Band[BandCount];
    private readonly float[] _gainsDb = new float[BandCount];

    private volatile bool _enabled = true;
    private int _sampleRate = 48000;

    public TenBandEqualizer()
    {
        for (var i = 0; i < BandCount; i++)
        {
            _bands[i] = new Band();
        }
    }

    /// <summary>旁通开关：关闭时完全跳过处理，用于 A/B 对比。</summary>
    public bool Enabled
    {
        get => _enabled;
        set => _enabled = value;
    }

    public int SampleRate => _sampleRate;

    public static double FrequencyOf(int index) => CenterFrequencies[index];

    public float GetGain(int index)
    {
        return index < 0 || index >= BandCount ? 0f : _gainsDb[index];
    }

    public bool IsFlat()
    {
        for (var i = 0; i < BandCount; i++)
        {
            if (Math.Abs(_gainsDb[i]) >= 0.05f)
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>按实际采样率重建全部系数并清空滤波器状态。每次开始分发时调用。</summary>
    public void Prepare(int sampleRate)
    {
        _sampleRate = sampleRate > 4000 ? sampleRate : 48000;

        for (var i = 0; i < BandCount; i++)
        {
            _bands[i].Reset();
            Rebuild(i);
        }
    }

    public void SetGain(int index, float decibel)
    {
        if (index < 0 || index >= BandCount)
        {
            return;
        }

        var clamped = (float)Math.Clamp(decibel, MinGainDb, MaxGainDb);
        if (Math.Abs(_gainsDb[index] - clamped) < 0.001f)
        {
            return;
        }

        _gainsDb[index] = clamped;
        Rebuild(index);
    }

    public void SetGains(float[] decibels)
    {
        if (decibels == null)
        {
            return;
        }

        for (var i = 0; i < BandCount && i < decibels.Length; i++)
        {
            SetGain(i, decibels[i]);
        }
    }

    public void Reset()
    {
        for (var i = 0; i < BandCount; i++)
        {
            SetGain(i, 0f);
        }
    }

    /// <summary>处理交错立体声（L,R,L,R…）缓冲区，原地改写。</summary>
    public void Process(float[] interleaved, int frames)
    {
        if (!_enabled || frames <= 0)
        {
            return;
        }

        for (var i = 0; i < BandCount; i++)
        {
            _bands[i].Process(interleaved, frames);
        }
    }

    private void Rebuild(int index)
    {
        var decibel = _gainsDb[index];
        var frequency = CenterFrequencies[index];

        // 增益为 0 或该段越过奈奎斯特（低采样率下的 16 kHz）时退化为恒等。
        if (Math.Abs(decibel) < 0.05f || frequency >= _sampleRate * 0.45)
        {
            _bands[index].Coeffs = Coefficients.Identity;
            return;
        }

        var a = Math.Pow(10.0, decibel / 40.0);
        var w0 = 2.0 * Math.PI * frequency / _sampleRate;
        var cos = Math.Cos(w0);
        var alpha = Math.Sin(w0) / (2.0 * Q);
        var a0 = 1.0 + alpha / a;

        _bands[index].Coeffs = new Coefficients(
            (1.0 + alpha * a) / a0,
            -2.0 * cos / a0,
            (1.0 - alpha * a) / a0,
            -2.0 * cos / a0,
            (1.0 - alpha / a) / a0);
    }

    private sealed class Coefficients
    {
        public static readonly Coefficients Identity = new(1.0, 0.0, 0.0, 0.0, 0.0);

        public Coefficients(double b0, double b1, double b2, double a1, double a2)
        {
            B0 = b0;
            B1 = b1;
            B2 = b2;
            A1 = a1;
            A2 = a2;
        }

        public double B0 { get; }

        public double B1 { get; }

        public double B2 { get; }

        public double A1 { get; }

        public double A2 { get; }
    }

    /// <summary>单段的双声道直一型（direct form I）状态与系数。</summary>
    private sealed class Band
    {
        public volatile Coefficients Coeffs = Coefficients.Identity;

        private double _lx1, _lx2, _ly1, _ly2;
        private double _rx1, _rx2, _ry1, _ry2;

        public void Reset()
        {
            _lx1 = _lx2 = _ly1 = _ly2 = 0;
            _rx1 = _rx2 = _ry1 = _ry2 = 0;
        }

        public void Process(float[] buffer, int frames)
        {
            var c = Coeffs;
            if (ReferenceEquals(c, Coefficients.Identity))
            {
                return;
            }

            for (var f = 0; f < frames; f++)
            {
                var index = f * 2;

                var x = buffer[index];
                var y = (c.B0 * x) + (c.B1 * _lx1) + (c.B2 * _lx2) - (c.A1 * _ly1) - (c.A2 * _ly2);
                _lx2 = _lx1;
                _lx1 = x;
                _ly2 = _ly1;
                _ly1 = y;
                buffer[index] = Clamp(y);

                x = buffer[index + 1];
                y = (c.B0 * x) + (c.B1 * _rx1) + (c.B2 * _rx2) - (c.A1 * _ry1) - (c.A2 * _ry2);
                _rx2 = _rx1;
                _rx1 = x;
                _ry2 = _ry1;
                _ry1 = y;
                buffer[index + 1] = Clamp(y);
            }
        }

        /// <summary>系数组被异常数据污染时不让 NaN 顺着通道一路传播下去。</summary>
        private static float Clamp(double value)
        {
            if (double.IsNaN(value))
            {
                return 0f;
            }

            if (value > 4.0)
            {
                return 4f;
            }

            if (value < -4.0)
            {
                return -4f;
            }

            return (float)value;
        }
    }
}
