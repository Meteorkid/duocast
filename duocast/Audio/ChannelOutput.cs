using System;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace DuoCast.Audio;

/// <summary>
/// 单个输出通道：环形缓冲 + WASAPI 渲染流 + 独立软件增益 + 时钟漂移补偿。
///
/// 漂移补偿原理：
///   两个物理声卡的时钟不同源，长时间播放必然出现「一个快一个慢」。
///   这里以环形缓冲的堆积量作为误差信号，用比例控制器微调读取速率
///   （±0.2%，即 ±2000 ppm），既不改变音高感知，又能拉住缓冲水位。
///
/// 运行时重配置：
///   BufferMs 变化会在分发过程中重建 WasapiOut（环形缓冲内容与读指针保留），
///   代价是一次极短的断流；重建后重新进入「预灌」状态，不会把断流计成欠载。
/// </summary>
public sealed class ChannelOutput : IDisposable
{
    private readonly StereoRing _ring;
    private readonly object _lifecycleGate = new();

    private WasapiOut? _output;
    private ChannelProvider? _provider;
    private MMDevice? _device;
    private float[] _applyBuffer = Array.Empty<float>();

    private double _readPosition;
    private bool _primed;
    private volatile bool _running;
    private volatile bool _driftCompensation = true;
    private volatile int _bufferMs = 10;
    private volatile float _peak;
    private long _underruns;
    private long _resampleCounter;
    private double _correctionPpm;

    public ChannelOutput(string label, int capacitySeconds = 2)
    {
        Label = label;
        _ring = new StereoRing(48000 * capacitySeconds);
    }

    /// <summary>输出流被重建或初始化失败时抛出异常消息，由上层转成界面提示。</summary>
    public event Action<string>? Fault;

    public string Label { get; }

    /// <summary>本通道的 10 段图示均衡。放在软件增益之前，避免增益改变后还要重算滤波系数。</summary>
    public TenBandEqualizer Equalizer { get; } = new();

    public int SampleRate { get; private set; } = 48000;

    /// <summary>
    /// WASAPI 共享模式下的建议缓冲（毫秒）。越小延迟越低、越容易欠载。
    /// 运行中修改会重建输出流，立即生效。
    /// </summary>
    public int BufferMs
    {
        get => _bufferMs;
        set
        {
            var next = Math.Clamp(value, 3, 200);
            if (next == _bufferMs)
            {
                return;
            }

            _bufferMs = next;

            lock (_lifecycleGate)
            {
                if (_running)
                {
                    ReinitializeOutputCore();
                }
            }
        }
    }

    /// <summary>通道间的额外延迟补偿（毫秒）。正值 = 该通道更晚出声。</summary>
    public int OffsetMs { get; set; }

    /// <summary>软件增益，1.0 = 0 dB。范围 0 ~ 1.5。</summary>
    public float Volume { get; set; } = 0.8f;

    public bool Muted { get; set; }

    /// <summary>
    /// ASRC 漂移补偿开关。关闭后按 1:1 速率读取，两块声卡时钟不同源时
    /// 水位会单向漂移，最终撞到缓冲边界（表现为周期性爆音或断流）。
    /// </summary>
    public bool DriftCompensation
    {
        get => _driftCompensation;
        set => _driftCompensation = value;
    }

    public string DeviceName { get; private set; } = "(未选择)";

    public float PeakLevel => _peak;

    /// <summary>累计欠载帧数。</summary>
    public long Underruns => Interlocked.Read(ref _underruns);

    /// <summary>累计欠载时长（毫秒），比帧数更直观。</summary>
    public double UnderrunMs => Underruns / (double)Math.Max(1, SampleRate) * 1000.0;

    /// <summary>当前缓冲水位（毫秒）。与 BufferMs + OffsetMs 的目标值比较可以判断收敛情况。</summary>
    public double BufferedMs => (_ring.TotalWritten - _readPosition) / (double)Math.Max(1, SampleRate) * 1000.0;

    /// <summary>当前读取速率修正量（ppm）。负值 = 正在放慢读取。</summary>
    public double CorrectionPpm => Volatile.Read(ref _correctionPpm);

    public bool IsRunning => _running;

    public void Start(MMDevice device, int sampleRate)
    {
        lock (_lifecycleGate)
        {
            StopCore();

            SampleRate = sampleRate;
            _ring.Reset();
            _readPosition = 0;
            _primed = false;
            _peak = 0f;
            _underruns = 0;
            _resampleCounter = 0;
            _correctionPpm = 0;

            // 先按本次采样率重建滤波系数，再让通道进入运行态。
            Equalizer.Prepare(sampleRate);
            _running = true;

            _provider = new ChannelProvider(this, sampleRate);
            _device = device;

            try
            {
                CreateOutputCore();
            }
            catch
            {
                _running = false;
                _primed = false;
                _device = null;
                _provider = null;
                throw;
            }

            DeviceName = device.FriendlyName;
        }
    }

    public void Stop()
    {
        lock (_lifecycleGate)
        {
            StopCore();
        }
    }

    private void CreateOutputCore()
    {
        var device = _device;
        var provider = _provider;
        if (device == null || provider == null)
        {
            return;
        }

        var output = new WasapiOut(device, AudioClientShareMode.Shared, true, Math.Max(3, _bufferMs));

        try
        {
            output.Init(provider);
            output.Play();
        }
        catch
        {
            try
            {
                output.Dispose();
            }
            catch
            {
                // 忽略清理阶段的二次异常。
            }

            throw;
        }

        _output = output;
    }

    /// <summary>替换 BufferMs 后重开输出流：环形缓冲与读指针保留，仅重建渲染端。</summary>
    private void ReinitializeOutputCore()
    {
        var device = _device;
        var provider = _provider;

        if (device == null || provider == null)
        {
            return;
        }

        ReleaseOutput();

        try
        {
            // 重新预灌，避免把重建造成的短暂空缺计成欠载。
            _primed = false;
            CreateOutputCore();
        }
        catch (Exception ex)
        {
            _running = false;
            Fault?.Invoke("重建输出流失败（" + _bufferMs + " ms）：" + ex.Message);
        }
    }

    private void StopCore()
    {
        _running = false;
        _primed = false;
        _device = null;
        _provider = null;
        _correctionPpm = 0;

        ReleaseOutput();
    }

    private void ReleaseOutput()
    {
        var output = _output;
        _output = null;

        if (output == null)
        {
            return;
        }

        try
        {
            output.Stop();
        }
        catch
        {
            // 设备已被拔出时 Stop 可能抛异常，忽略即可。
        }

        output.Dispose();
    }

    /// <summary>由采集线程调用：过均衡 → 施加增益 → 写入环形缓冲。</summary>
    public void Push(float[] interleavedStereo, int frames)
    {
        if (!_running || frames <= 0)
        {
            return;
        }

        var needed = frames * 2;
        if (_applyBuffer.Length < needed)
        {
            _applyBuffer = new float[needed];
        }

        // 先拷贝再原地滤波，输入缓冲属于采集回调，不就地改写。
        Array.Copy(interleavedStereo, _applyBuffer, needed);
        Equalizer.Process(_applyBuffer, frames);

        var gain = Muted ? 0f : Volume;
        var peak = 0f;

        for (var i = 0; i < needed; i++)
        {
            var v = _applyBuffer[i] * gain;
            _applyBuffer[i] = v;

            var a = v < 0 ? -v : v;
            if (a > peak)
            {
                peak = a;
            }
        }

        _ring.Write(_applyBuffer, frames);
        _peak = peak;
    }

    /// <summary>由 WASAPI 渲染线程调用：从环形缓冲拉取一帧块。</summary>
    internal void Pull(float[] destination, int frames)
    {
        if (!_running)
        {
            Array.Clear(destination, 0, frames * 2);
            return;
        }

        var target = (_bufferMs + Math.Max(0, OffsetMs)) * 0.001 * SampleRate;
        if (target < SampleRate * 0.005)
        {
            target = SampleRate * 0.005; // 至少 5 ms，避免空跑
        }

        var available = _ring.TotalWritten - _readPosition;

        if (!_primed)
        {
            if (available < target)
            {
                Array.Clear(destination, 0, frames * 2);
                return;
            }

            _primed = true;
        }

        // 缓冲高于目标 → 加快读取；低于目标 → 放慢读取。
        var correction = 0.0;
        if (_driftCompensation)
        {
            var error = available - target;
            correction = Math.Clamp(error * 0.0002, -0.002, 0.002);
        }

        var step = 1.0 + correction;

        _ring.ReadInterpolated(_readPosition, step, destination, frames, out var endPosition, out var underruns);
        _readPosition = endPosition;

        Volatile.Write(ref _correctionPpm, correction * 1000000.0);

        if (Math.Abs(correction) > 0.000002)
        {
            Interlocked.Increment(ref _resampleCounter);
        }

        if (underruns > 0)
        {
            Interlocked.Add(ref _underruns, underruns);
        }
    }

    public void Dispose()
    {
        Stop();
    }

    /// <summary>把 ChannelOutput 适配成 NAudio 的渲染源，输出 IEEE float 立体声。</summary>
    private sealed class ChannelProvider : IWaveProvider
    {
        private readonly ChannelOutput _owner;
        private readonly int _maxFrames;
        private float[] _frames;
        private byte[] _bytes;

        public ChannelProvider(ChannelOutput owner, int sampleRate)
        {
            _owner = owner;
            WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(sampleRate, 2);
            _maxFrames = Math.Max(2048, sampleRate / 8);
            _frames = new float[_maxFrames * 2];
            _bytes = new byte[_maxFrames * 8];
        }

        public WaveFormat WaveFormat { get; }

        public int Read(byte[] buffer, int offset, int count)
        {
            var frames = count / 8;
            if (frames <= 0)
            {
                return 0;
            }

            if (_frames.Length < frames * 2)
            {
                _frames = new float[frames * 2];
                _bytes = new byte[frames * 8];
            }

            _owner.Pull(_frames, frames);
            Buffer.BlockCopy(_frames, 0, buffer, offset, frames * 8);
            return frames * 8;
        }
    }
}
