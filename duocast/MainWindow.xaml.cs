using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using DuoCast.Audio;
using Microsoft.Win32;

namespace DuoCast;

public partial class MainWindow : Window
{
    private static readonly Brush ActiveSegBrush = new SolidColorBrush(Color.FromRgb(0x2A, 0x27, 0x24));
    private static readonly Brush IdleSegBrush = Brushes.Transparent;
    private static readonly Brush ActiveTextBrush = new SolidColorBrush(Color.FromRgb(0xF2, 0xF2, 0xF2));
    private static readonly Brush IdleTextBrush = new SolidColorBrush(Color.FromRgb(0x8A, 0x85, 0x7F));
    private static readonly Brush ReadyBrush = new SolidColorBrush(Color.FromRgb(0x7D, 0xD9, 0xA6));
    private static readonly Brush WarningBrush = new SolidColorBrush(Color.FromRgb(0xE8, 0xC2, 0x68));
    private static readonly Brush MutedBrush = new SolidColorBrush(Color.FromRgb(0x6E, 0x68, 0x62));
    private static readonly Brush QuietTextBrush = new SolidColorBrush(Color.FromRgb(0xC9, 0xC3, 0xBA));

    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    private readonly AudioEngine _engine = new();
    private readonly DispatcherTimer _timer;

    private List<DeviceEntry> _renderDevices = new();
    private List<DeviceEntry> _captureDevices = new();

    private DeviceEntry? _deviceA;
    private DeviceEntry? _deviceB;
    private DeviceEntry? _captureDevice;
    private string? _filePath;
    private bool _loopFile = true;

    private int _mode;
    private int _offsetA;
    private int _offsetB;
    private bool _mutedA;
    private bool _mutedB;
    private double _peakA;
    private double _peakB;
    private DateTime _startedAt;

    private int _bufferMs = 10;
    private bool _driftOn = true;
    private SettingsWindow? _settings;
    private EqualizerWindow? _equalizer;

    private string _deviceSignature = string.Empty;
    private DateTime _nextDeviceScan;
    private string? _activeAId;
    private string? _activeBId;
    private bool _uiRunning;

    public MainWindow()
    {
        InitializeComponent();

        _engine.Log += OnEngineLog;
        _engine.BufferMs = _bufferMs;
        _engine.DriftCompensation = _driftOn;

        _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) };
        _timer.Tick += (_, _) => OnTick();
        _timer.Start();

        _nextDeviceScan = DateTime.Now.AddSeconds(2);

        RefreshDevices();
        SelectMode(0);
        UpdateVolumeLabels();
        SetEngineState(false, "引擎待机");
        StatusText.Text = "就绪。选择两路输出设备后点击「开始分发」。";
    }

    // ── 设备枚举 ───────────────────────────────────────────────

    private void RefreshDevices() => ApplyDeviceLists(Devices.Render(), Devices.Capture(), false);

    /// <summary>
    /// 用最新的端点列表重建两个下拉菜单。
    /// preserveSelection = true 时尽量保留用户已选设备（热插拔刷新走这条路径）。
    /// </summary>
    private void ApplyDeviceLists(List<DeviceEntry> render, List<DeviceEntry> capture, bool preserveSelection)
    {
        var previousA = preserveSelection ? _deviceA?.Id : null;
        var previousB = preserveSelection ? _deviceB?.Id : null;
        var running = _engine.IsRunning;

        _renderDevices = render;
        _captureDevices = capture;
        _deviceSignature = BuildSignature(render, capture);

        BuildDeviceMenu(BtnDevA, _renderDevices, device =>
        {
            _deviceA = device;
            DevAName.Text = device.DisplayName;
            if (!_engine.IsRunning)
            {
                StatusA.Text = "已选择 · 未启动";
            }

            ResetChannelState();
        });

        BuildDeviceMenu(BtnDevB, _renderDevices, device =>
        {
            _deviceB = device;
            DevBName.Text = device.DisplayName;
            if (!_engine.IsRunning)
            {
                StatusB.Text = "已选择 · 未启动";
            }

            ResetChannelState();
        });

        BuildCaptureMenu();

        _deviceA = previousA == null ? null : _renderDevices.FirstOrDefault(d => d.Id == previousA);
        _deviceB = previousB == null ? null : _renderDevices.FirstOrDefault(d => d.Id == previousB);

        if (_deviceA == null && _renderDevices.Count > 0)
        {
            _deviceA = _renderDevices[0];
        }

        if (_deviceB == null && _renderDevices.Count > 1)
        {
            _deviceB = _renderDevices[1];
        }

        BtnDevA.IsEnabled = _renderDevices.Count > 0;
        BtnDevB.IsEnabled = _renderDevices.Count > 0;

        DevAName.Text = _deviceA?.DisplayName ?? (_renderDevices.Count == 0 ? "未检测到输出设备" : "选择输出设备");
        DevBName.Text = _deviceB?.DisplayName ?? (_renderDevices.Count == 0 ? "未检测到输出设备" : "选择输出设备");

        if (!running)
        {
            StatusA.Text = _deviceA == null ? "未连接" : "已选择 · 未启动";
            StatusB.Text = _deviceB == null ? "未连接" : "已选择 · 未启动";
        }

        if (_renderDevices.Count == 0)
        {
            StatusText.Text = "未检测到可用的音频输出设备。插入设备后会自动刷新。";
        }
    }

    private void BuildDeviceMenu(Button button, List<DeviceEntry> devices, Action<DeviceEntry> onPick)
    {
        var menu = CreateMenu();

        foreach (var device in devices)
        {
            var item = new MenuItem { Header = device.DisplayName, Tag = device };
            item.Click += (_, _) => onPick(device);
            menu.Items.Add(item);
        }

        if (devices.Count == 0)
        {
            menu.Items.Add(new MenuItem { Header = "(无可用设备)", IsEnabled = false });
        }

        button.ContextMenu = menu;
    }

    private void BuildCaptureMenu()
    {
        var menu = CreateMenu();

        foreach (var device in _captureDevices)
        {
            var item = new MenuItem { Header = device.DisplayName, Tag = device };
            item.Click += (_, _) =>
            {
                _captureDevice = device;
                BtnCaptureDev.Content = device.DisplayName;
                if (!_engine.IsRunning)
                {
                    SourceText.Text = device.DisplayName;
                }

                StatusText.Text = "采集设备已选择：" + device.Name;
            };
            menu.Items.Add(item);
        }

        if (_captureDevices.Count == 0)
        {
            menu.Items.Add(new MenuItem { Header = "(无可用采集设备)", IsEnabled = false });
        }

        BtnCaptureDev.ContextMenu = menu;

        var captureSelection = _captureDevice;
        if (captureSelection != null && !_captureDevices.Any(d => d.Id == captureSelection.Id))
        {
            _captureDevice = null;
            BtnCaptureDev.Content = "选择采集设备";
        }
        else if (captureSelection != null)
        {
            BtnCaptureDev.Content = captureSelection.DisplayName;
        }
    }

    private ContextMenu CreateMenu()
    {
        return new ContextMenu
        {
            Background = new SolidColorBrush(Color.FromRgb(0x1C, 0x1A, 0x17)),
            Foreground = new SolidColorBrush(Color.FromRgb(0xE2, 0xDD, 0xD5)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x24, 0xFF, 0xFF, 0xFF)),
            BorderThickness = new Thickness(1),
            ItemContainerStyle = (Style)FindResource("DarkMenuItem")
        };
    }

    private void BtnDevA_Click(object sender, RoutedEventArgs e) => OpenMenu(BtnDevA);

    private void BtnDevB_Click(object sender, RoutedEventArgs e) => OpenMenu(BtnDevB);

    private static void OpenMenu(Button button)
    {
        if (button.ContextMenu == null)
        {
            return;
        }

        button.ContextMenu.PlacementTarget = button;
        button.ContextMenu.IsOpen = true;
    }

    // ── 输入源 ─────────────────────────────────────────────────

    private void Seg_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string tag } && int.TryParse(tag, out var mode))
        {
            SelectMode(mode);
        }
    }

    private void SelectMode(int mode)
    {
        _mode = mode;

        StyleSegment(Seg0, mode == 0);
        StyleSegment(Seg1, mode == 1);
        StyleSegment(Seg2, mode == 2);

        BtnCaptureDev.Visibility = mode == 1 ? Visibility.Visible : Visibility.Collapsed;
        BtnPickFile.Visibility = mode == 2 ? Visibility.Visible : Visibility.Collapsed;

        if (!_engine.IsRunning)
        {
            SourceText.Text = mode switch
            {
                0 => "系统音频 · 默认输出回环",
                1 => _captureDevice?.DisplayName ?? "采集设备 · 未选择",
                _ => _filePath == null ? "本地文件 · 未选择" : "本地文件 · " + System.IO.Path.GetFileName(_filePath)
            };
        }
    }

    private static void StyleSegment(Button button, bool active)
    {
        button.Background = active ? ActiveSegBrush : IdleSegBrush;
        button.Foreground = active ? ActiveTextBrush : IdleTextBrush;
        button.FontWeight = active ? FontWeights.SemiBold : FontWeights.Normal;
    }

    private void BtnCaptureDev_Click(object sender, RoutedEventArgs e) => OpenMenu(BtnCaptureDev);

    private void BtnPickFile_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = "选择要分发的音频文件",
            Filter = "音频文件|*.wav;*.mp3;*.aiff;*.aif;*.wma;*.m4a|所有文件|*.*"
        };

        if (dialog.ShowDialog(this) == true)
        {
            _filePath = dialog.FileName;
            BtnPickFile.Content = System.IO.Path.GetFileName(_filePath);
            SourceText.Text = "本地文件 · " + System.IO.Path.GetFileName(_filePath);
        }
    }

    // ── 分发控制 ───────────────────────────────────────────────

    private void BtnStart_Click(object sender, RoutedEventArgs e)
    {
        if (_engine.IsRunning)
        {
            _engine.Stop();
            ResetChannelState();
            return;
        }

        if (_deviceA == null)
        {
            StatusText.Text = "请先为输出 A 选择设备。";
            return;
        }

        if (_deviceB == null)
        {
            StatusText.Text = "请先为输出 B 选择设备（需要两个不同的输出端点）。";
            return;
        }

        if (_deviceA.Id == _deviceB.Id)
        {
            var result = MessageBox.Show(this,
                "两路选择了同一个输出设备。这样只会听到一路声音叠加，是否继续？",
                "提示", MessageBoxButton.OKCancel, MessageBoxImage.Warning);

            if (result != MessageBoxResult.OK)
            {
                return;
            }
        }

        var bluetoothA = Devices.LooksBluetooth(_deviceA.Name);
        var bluetoothB = Devices.LooksBluetooth(_deviceB.Name);

        if (bluetoothA && bluetoothB)
        {
            var answer = MessageBox.Show(this,
                "两路输出设备都像是蓝牙耳机。\n\n多数蓝牙芯片同一时刻只承载一路 A2DP 立体声流，第二路很可能无声（即使日志显示已连接）。\n\n确定继续？",
                "蓝牙输出限制", MessageBoxButton.OKCancel, MessageBoxImage.Warning);

            if (answer != MessageBoxResult.OK)
            {
                return;
            }
        }

        try
        {
            _engine.ChannelA.Volume = (float)(SliderA.Value / 100.0);
            _engine.ChannelB.Volume = (float)(SliderB.Value / 100.0);
            _engine.ChannelA.Muted = _mutedA;
            _engine.ChannelB.Muted = _mutedB;
            _engine.ChannelA.OffsetMs = _offsetA;
            _engine.ChannelB.OffsetMs = _offsetB;

            switch (_mode)
            {
                case 0:
                    _engine.StartLoopback(_deviceA.Id, _deviceB.Id);
                    break;

                case 1:
                    if (_captureDevice == null)
                    {
                        StatusText.Text = "请先选择采集设备。";
                        return;
                    }

                    _engine.StartCaptureDevice(_captureDevice.Id, _deviceA.Id, _deviceB.Id);
                    break;

                default:
                    if (string.IsNullOrEmpty(_filePath))
                    {
                        StatusText.Text = "请先选择音频文件。";
                        return;
                    }

                    _engine.StartFile(_filePath, _deviceA.Id, _deviceB.Id, _loopFile);
                    break;
            }

            _activeAId = _deviceA.Id;
            _activeBId = _deviceB.Id;
            _uiRunning = true;
            _startedAt = DateTime.Now;
            SetEngineState(true, "引擎运行中 · " + _engine.SampleRate.ToString(Inv) + " Hz");
            FormatText.Text = _engine.SampleRate.ToString(Inv) + " Hz / float32";
            StatusA.Text = "已连接 · " + _engine.ChannelA.DeviceName;
            StatusB.Text = "已连接 · " + _engine.ChannelB.DeviceName;
            BtnStart.Content = "停止分发";

            if (bluetoothA || bluetoothB)
            {
                Dispatcher.BeginInvoke(DispatcherPriority.ContextIdle, new Action(() =>
                {
                    StatusText.Text = "已开始分发 · 注意：其中一路为蓝牙端点，两副蓝牙耳机通常无法并行输出。";
                }));
            }
        }
        catch (Exception ex)
        {
            StatusText.Text = "启动失败：" + ex.Message;
            SetEngineState(false, "引擎报错");
            _engine.Stop();
            ResetChannelState();
        }
    }

    private void ResetChannelState()
    {
        if (_engine.IsRunning)
        {
            _engine.Stop();
        }

        _activeAId = null;
        _activeBId = null;
        _uiRunning = false;

        BtnStart.Content = "开始分发";
        SetEngineState(false, "引擎待机");
        FormatText.Text = "—";
        StatusA.Text = _deviceA == null ? "未连接" : "已选择 · 未启动";
        StatusB.Text = _deviceB == null ? "未连接" : "已选择 · 未启动";
        _peakA = 0;
        _peakB = 0;
        MeterA.Width = 0;
        MeterB.Width = 0;
        PeakA.Text = "—";
        PeakB.Text = "—";
        DriftText.Text = "漂移 —";
    }

    private void SetEngineState(bool running, string text)
    {
        EngineText.Text = text;
        EngineDot.Fill = running ? ReadyBrush : MutedBrush;
    }

    private void OnEngineLog(string message)
    {
        Dispatcher.BeginInvoke(new Action(() => StatusText.Text = message));
    }

    // ── 高级设置 ───────────────────────────────────────────────

    private void BtnEq_Click(object sender, RoutedEventArgs e)
    {
        if (_equalizer != null)
        {
            _equalizer.Activate();
            return;
        }

        _equalizer = new EqualizerWindow(_engine.ChannelA.Equalizer, _engine.ChannelB.Equalizer)
        {
            Owner = this
        };

        _equalizer.Closed += (_, _) => _equalizer = null;
        _equalizer.Show();
    }

    private void BtnSettings_Click(object sender, RoutedEventArgs e)
    {
        if (_settings != null)
        {
            _settings.Activate();
            return;
        }

        _settings = new SettingsWindow(_engine, _bufferMs, _driftOn, _loopFile,
            OnBufferChanged, OnDriftChanged, OnLoopChanged)
        {
            Owner = this
        };

        _settings.Closed += (_, _) => _settings = null;
        _settings.Show();
    }

    private void OnBufferChanged(int milliseconds)
    {
        _bufferMs = milliseconds;
        _engine.BufferMs = milliseconds;

        StatusText.Text = _engine.IsRunning
            ? "缓冲已设为 " + milliseconds.ToString(Inv) + " ms，两条输出流已重建并重新预灌。"
            : "缓冲已设为 " + milliseconds.ToString(Inv) + " ms。";
    }

    private void OnDriftChanged(bool enabled)
    {
        _driftOn = enabled;
        _engine.DriftCompensation = enabled;

        StatusText.Text = enabled
            ? "已开启 ASRC 漂移补偿。"
            : "已关闭 ASRC 漂移补偿：两块声卡时钟不同源时，长时间播放会一路快一路慢。";
    }

    private void OnLoopChanged(bool loop)
    {
        _loopFile = loop;
        StatusText.Text = loop
            ? "本地文件将循环播放（下次开始分发时生效）。"
            : "本地文件将单次播放（下次开始分发时生效）。";
    }

    // ── 通道控制 ───────────────────────────────────────────────

    private void BtnMuteA_Click(object sender, RoutedEventArgs e)
    {
        _mutedA = !_mutedA;
        _engine.ChannelA.Muted = _mutedA;
        BtnMuteA.Content = _mutedA ? "已静音" : "静音";
        BtnMuteA.Foreground = _mutedA ? WarningBrush : QuietTextBrush;
    }

    private void BtnMuteB_Click(object sender, RoutedEventArgs e)
    {
        _mutedB = !_mutedB;
        _engine.ChannelB.Muted = _mutedB;
        BtnMuteB.Content = _mutedB ? "已静音" : "静音";
        BtnMuteB.Foreground = _mutedB ? WarningBrush : QuietTextBrush;
    }

    private void SliderA_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (VolTextA == null || DbA == null)
        {
            return;
        }

        _engine.ChannelA.Volume = (float)(e.NewValue / 100.0);
        UpdateVolumeLabels();
    }

    private void SliderB_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (VolTextB == null || DbB == null)
        {
            return;
        }

        _engine.ChannelB.Volume = (float)(e.NewValue / 100.0);
        UpdateVolumeLabels();
    }

    private void UpdateVolumeLabels()
    {
        if (VolTextA == null || VolTextB == null)
        {
            return;
        }

        VolTextA.Text = ((int)Math.Round(SliderA.Value)).ToString(Inv);
        VolTextB.Text = ((int)Math.Round(SliderB.Value)).ToString(Inv);
        DbA.Text = ToDecibel(SliderA.Value);
        DbB.Text = ToDecibel(SliderB.Value);
    }

    private static string ToDecibel(double percent)
    {
        if (percent <= 0.5)
        {
            return "-∞ dB";
        }

        var db = 20 * Math.Log10(percent / 100.0);
        return db.ToString("0.0", Inv) + " dB";
    }

    private void OffAMinus_Click(object sender, RoutedEventArgs e) => SetOffset(ref _offsetA, -5, OffAValue, _engine.ChannelA);

    private void OffAPlus_Click(object sender, RoutedEventArgs e) => SetOffset(ref _offsetA, 5, OffAValue, _engine.ChannelA);

    private void OffBMinus_Click(object sender, RoutedEventArgs e) => SetOffset(ref _offsetB, -5, OffBValue, _engine.ChannelB);

    private void OffBPlus_Click(object sender, RoutedEventArgs e) => SetOffset(ref _offsetB, 5, OffBValue, _engine.ChannelB);

    private void SetOffset(ref int field, int delta, TextBlock label, ChannelOutput channel)
    {
        var next = Math.Clamp(field + delta, 0, 500);
        field = next;
        label.Text = next.ToString(Inv) + " ms";
        channel.OffsetMs = next;
    }

    // ── 定时刷新 ───────────────────────────────────────────────

    private void OnTick()
    {
        if (_uiRunning && !_engine.IsRunning)
        {
            ResetChannelState();
            StatusText.Text = "分发已停止：输入源结束或设备异常，请检查后重新开始。";
            return;
        }

        UpdateMeter(_engine.ChannelA.PeakLevel, ref _peakA, MeterA, PeakA);
        UpdateMeter(_engine.ChannelB.PeakLevel, ref _peakB, MeterB, PeakB);

        UnderA.Text = "欠载 " + _engine.ChannelA.UnderrunMs.ToString("0.0", Inv) + " ms";
        UnderB.Text = "欠载 " + _engine.ChannelB.UnderrunMs.ToString("0.0", Inv) + " ms";

        if (_engine.IsRunning)
        {
            var elapsed = DateTime.Now - _startedAt;
            ClockText.Text = elapsed.ToString(@"hh\:mm\:ss", Inv);

            DriftText.Text = _driftOn
                ? "漂移 A " + FormatPpm(_engine.ChannelA.CorrectionPpm) + " / B " + FormatPpm(_engine.ChannelB.CorrectionPpm)
                : "漂移补偿已关闭";
        }

        if (DateTime.Now >= _nextDeviceScan)
        {
            _nextDeviceScan = DateTime.Now.AddSeconds(3);
            CheckDeviceChanges();
        }
    }

    /// <summary>
    /// 轮询端点列表代替 IMMNotificationClient：实现简单、无 COM 回调线程问题，
    /// 3 秒的延迟对「插拔耳机」这个场景完全够用。代价是空闲时每 3 秒一次 COM 枚举。
    /// </summary>
    private void CheckDeviceChanges()
    {
        List<DeviceEntry> render;
        List<DeviceEntry> capture;

        try
        {
            render = Devices.Render();
            capture = Devices.Capture();
        }
        catch (Exception ex)
        {
            StatusText.Text = "刷新设备列表失败：" + ex.Message;
            return;
        }

        if (BuildSignature(render, capture) == _deviceSignature)
        {
            return;
        }

        if (_engine.IsRunning)
        {
            var lost = (_activeAId != null && !ContainsId(render, _activeAId))
                       || (_activeBId != null && !ContainsId(render, _activeBId));

            if (lost)
            {
                _engine.Stop();
                ResetChannelState();
                ApplyDeviceLists(render, capture, true);
                StatusText.Text = "正在使用的输出设备已移除，分发已停止。请重新选择设备后再次开始。";
                return;
            }
        }

        ApplyDeviceLists(render, capture, true);
        StatusText.Text = "设备列表已更新 · 当前 " + render.Count.ToString(Inv) + " 个输出端点。";
    }

    private static bool ContainsId(List<DeviceEntry> devices, string id)
    {
        foreach (var device in devices)
        {
            if (device.Id == id)
            {
                return true;
            }
        }

        return false;
    }

    private static string BuildSignature(List<DeviceEntry> render, List<DeviceEntry> capture)
    {
        var builder = new StringBuilder();

        foreach (var device in render)
        {
            builder.Append(device.Id).Append(';');
        }

        builder.Append('|');

        foreach (var device in capture)
        {
            builder.Append(device.Id).Append(';');
        }

        return builder.ToString();
    }

    private static string FormatPpm(double ppm)
    {
        if (double.IsNaN(ppm) || double.IsInfinity(ppm))
        {
            return "—";
        }

        var sign = ppm >= 0 ? "+" : "-";
        return sign + Math.Abs(ppm).ToString("0.0", Inv) + "ppm";
    }

    private static void UpdateMeter(float peakFromEngine, ref double peakState, Rectangle bar, TextBlock label)
    {
        var parent = bar.Parent as FrameworkElement;
        var width = parent?.ActualWidth ?? 0;

        peakState = Math.Max(peakFromEngine, peakState * 0.86);
        if (peakState < 0.0005)
        {
            peakState = 0;
        }

        bar.Width = Math.Min(width, width * peakState);
        label.Text = peakState <= 0
            ? "—"
            : (20 * Math.Log10(peakState)).ToString("0.0", Inv) + " dBFS";
    }

    protected override void OnClosed(EventArgs e)
    {
        _timer.Stop();

        if (_settings != null)
        {
            _settings.Close();
            _settings = null;
        }

        if (_equalizer != null)
        {
            _equalizer.Close();
            _equalizer = null;
        }

        _engine.Dispose();
        base.OnClosed(e);
    }
}
