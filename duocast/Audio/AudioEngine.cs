using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace DuoCast.Audio;

/// <summary>
/// 音频引擎：一路输入源 → 两路独立通道。
///
/// 输入源三种：
///   1) 系统音频回环（默认输出设备），零配置，但原始声音仍会在默认设备上播放；
///   2) 指定录音设备（推荐配 VB-CABLE / 立体声混音），把播放器输出指向虚拟设备后
///      由本程序接管，才能真正做到「只有两个耳机出声」；
///   3) 本地音频文件，用于自测。
/// </summary>
public sealed class AudioEngine : IDisposable
{
    private readonly MMDeviceEnumerator _enumerator = new();

    private WasapiCapture? _capture;
    private AudioFileReader? _reader;
    private ISampleProvider? _fileProvider;
    private CancellationTokenSource? _fileCts;
    private Thread? _fileThread;
    private float[] _mixBuffer = Array.Empty<float>();
    private float[] _fileBuffer = Array.Empty<float>();
    private double _fileClock;

    public AudioEngine()
    {
        ChannelA = new ChannelOutput("A");
        ChannelB = new ChannelOutput("B");

        ChannelA.Fault += message => RaiseLog("通道 A 异常：" + message);
        ChannelB.Fault += message => RaiseLog("通道 B 异常：" + message);
    }

    public ChannelOutput ChannelA { get; }

    public ChannelOutput ChannelB { get; }

    public bool IsRunning { get; private set; }

    public int SampleRate { get; private set; } = 48000;

    public string SourceDescription { get; private set; } = "未启动";

    /// <summary>两路统一的渲染缓冲（毫秒）。运行中修改会即时重建两条输出流。</summary>
    public int BufferMs
    {
        get => ChannelA.BufferMs;
        set
        {
            ChannelA.BufferMs = value;
            ChannelB.BufferMs = value;
        }
    }

    /// <summary>两路统一的 ASRC 漂移补偿开关。</summary>
    public bool DriftCompensation
    {
        get => ChannelA.DriftCompensation;
        set
        {
            ChannelA.DriftCompensation = value;
            ChannelB.DriftCompensation = value;
        }
    }

    public event Action<string>? Log;

    public void StartLoopback(string deviceAId, string deviceBId)
    {
        var renderDevice = _enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
        var capture = new WasapiLoopbackCapture(renderDevice);
        StartWithCapture(capture, "系统音频回环（默认输出）", deviceAId, deviceBId);
    }

    public void StartCaptureDevice(string captureDeviceId, string deviceAId, string deviceBId)
    {
        var captureDevice = _enumerator.GetDevice(captureDeviceId);
        var capture = new WasapiCapture(captureDevice, true, 20);
        StartWithCapture(capture, "采集设备：" + captureDevice.FriendlyName, deviceAId, deviceBId);
    }

    public void StartFile(string path, string deviceAId, string deviceBId, bool loop)
    {
        Stop();

        if (!File.Exists(path))
        {
            throw new FileNotFoundException("找不到音频文件：" + path, path);
        }

        var reader = new AudioFileReader(path);
        ISampleProvider provider = reader;

        if (provider.WaveFormat.Channels == 1)
        {
            provider = new MonoToStereoSampleProvider(provider);
        }
        else if (provider.WaveFormat.Channels > 2)
        {
            reader.Dispose();
            throw new NotSupportedException("仅支持单声道或立体声文件。");
        }

        var deviceA = _enumerator.GetDevice(deviceAId);
        var deviceB = _enumerator.GetDevice(deviceBId);

        SampleRate = provider.WaveFormat.SampleRate;

        ChannelA.Start(deviceA, SampleRate);
        ChannelB.Start(deviceB, SampleRate);

        _reader = reader;
        _fileProvider = provider;
        _fileBuffer = new float[Math.Max(2048, SampleRate / 10) * 2];
        _fileClock = 0;
        _fileCts = new CancellationTokenSource();

        var token = _fileCts.Token;
        var stopwatch = Stopwatch.StartNew();
        var loopFlag = loop;

        _fileThread = new Thread(() => FileLoop(token, stopwatch, loopFlag))
        {
            IsBackground = true,
            Priority = ThreadPriority.AboveNormal,
            Name = "DuoCast.FilePump"
        };

        // 先置运行标志再开泵：否则空文件 / 极短文件可能在泵线程里先行退出，
        // 把 IsRunning 设回 false 之后又被这里覆盖成 true。
        IsRunning = true;
        SourceDescription = "本地文件：" + Path.GetFileName(path);
        _fileThread.Start();

        RaiseLog($"已启动：{SourceDescription} · {SampleRate} Hz");
        RaiseLog($"输出 A = {deviceA.FriendlyName} / 输出 B = {deviceB.FriendlyName}");
    }

    private void StartWithCapture(WasapiCapture capture, string description, string deviceAId, string deviceBId)
    {
        Stop();

        var deviceA = _enumerator.GetDevice(deviceAId);
        var deviceB = _enumerator.GetDevice(deviceBId);

        SampleRate = capture.WaveFormat.SampleRate;
        _mixBuffer = new float[Math.Max(2048, SampleRate / 4) * 2];

        ChannelA.Start(deviceA, SampleRate);
        ChannelB.Start(deviceB, SampleRate);

        capture.DataAvailable += OnCaptureDataAvailable;
        capture.RecordingStopped += OnCaptureStopped;

        _capture = capture;

        try
        {
            capture.StartRecording();
        }
        catch
        {
            // 采集启动失败时把已经打开的输出通道收回去，避免半启动状态。
            _capture = null;
            capture.DataAvailable -= OnCaptureDataAvailable;
            capture.RecordingStopped -= OnCaptureStopped;
            ChannelA.Stop();
            ChannelB.Stop();
            throw;
        }

        IsRunning = true;
        SourceDescription = description;
        RaiseLog($"已启动：{description} · {SampleRate} Hz / {capture.WaveFormat.Channels} ch");
        RaiseLog($"输出 A = {deviceA.FriendlyName} / 输出 B = {deviceB.FriendlyName}");
    }

    private void OnCaptureDataAvailable(object? sender, WaveInEventArgs e)
    {
        var capture = _capture;
        if (capture == null || e.BytesRecorded <= 0)
        {
            return;
        }

        var format = capture.WaveFormat;
        var frames = e.BytesRecorded / Math.Max(1, format.BlockAlign);

        if (_mixBuffer.Length < frames * 2)
        {
            _mixBuffer = new float[frames * 2];
        }

        var produced = SampleConverter.ToStereoFloat(e.Buffer, e.BytesRecorded, format, _mixBuffer);
        ChannelA.Push(_mixBuffer, produced);
        ChannelB.Push(_mixBuffer, produced);
    }

    private void OnCaptureStopped(object? sender, StoppedEventArgs e)
    {
        if (e.Exception != null)
        {
            RaiseLog("采集已停止：" + e.Exception.Message);
        }
        else
        {
            RaiseLog("采集已停止。");
        }

        // 采集端结束意味着没有数据源了，把输出流一并收回，避免两条空转的渲染流。
        ChannelA.Stop();
        ChannelB.Stop();
        IsRunning = false;
        SourceDescription = "未启动";
    }

    private void FileLoop(CancellationToken token, Stopwatch stopwatch, bool loop)
    {
        try
        {
            while (!token.IsCancellationRequested)
            {
                var provider = _fileProvider;
                var reader = _reader;

                if (provider == null || reader == null)
                {
                    break;
                }

                var read = provider.Read(_fileBuffer, 0, _fileBuffer.Length);
                if (read <= 0)
                {
                    if (loop)
                    {
                        reader.Position = 0;
                        _fileClock = 0;
                        stopwatch.Restart();
                        continue;
                    }

                    RaiseLog("文件播放结束。");
                    break;
                }

                var frames = read / 2;
                ChannelA.Push(_fileBuffer, frames);
                ChannelB.Push(_fileBuffer, frames);

                // 按真实时间节奏喂数据，避免把环形缓冲冲爆。
                _fileClock += frames / (double)SampleRate;
                var ahead = _fileClock - stopwatch.Elapsed.TotalSeconds;
                if (ahead > 0.002)
                {
                    var sleep = (int)Math.Min(50, ahead * 1000);
                    if (sleep > 0)
                    {
                        Thread.Sleep(sleep);
                    }
                }
            }
        }
        catch (Exception ex)
        {
            RaiseLog("文件播放中断：" + ex.Message);
        }
        finally
        {
            // 非取消退出（播完 / 解码异常）说明数据源没了，把两条输出流一起收回，
            // 让界面能通过 IsRunning 感知到「已经停了」。
            if (!token.IsCancellationRequested)
            {
                ChannelA.Stop();
                ChannelB.Stop();
                IsRunning = false;
                SourceDescription = "未启动";
            }
        }
    }

    public void Stop()
    {
        var capture = _capture;
        _capture = null;

        if (capture != null)
        {
            capture.DataAvailable -= OnCaptureDataAvailable;
            capture.RecordingStopped -= OnCaptureStopped;

            try
            {
                capture.StopRecording();
            }
            catch
            {
                // 设备已移除时忽略。
            }

            capture.Dispose();
        }

        if (_fileCts != null)
        {
            try
            {
                _fileCts.Cancel();
            }
            catch
            {
                // 忽略。
            }

            _fileThread?.Join(300);
            _fileCts.Dispose();
            _fileCts = null;
            _fileThread = null;
        }

        _fileProvider = null;

        if (_reader != null)
        {
            _reader.Dispose();
            _reader = null;
        }

        ChannelA.Stop();
        ChannelB.Stop();

        if (IsRunning)
        {
            RaiseLog("已停止分发。");
        }

        IsRunning = false;
        SourceDescription = "未启动";
    }

    private void RaiseLog(string message) => Log?.Invoke(message);

    public void Dispose()
    {
        Stop();
        ChannelA.Dispose();
        ChannelB.Dispose();
        _enumerator.Dispose();
    }
}
