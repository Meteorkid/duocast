using System;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using DuoCast.Audio;

namespace DuoCast;

/// <summary>
/// 高级设置面板（对应设计稿 640 宽的面板）。
/// 只承载「分发过程中也可能想改」的三项：渲染缓冲、ASRC 漂移补偿、文件循环。
/// 所有改动立即回调给 MainWindow 并下发到 AudioEngine，没有「保存」概念。
/// </summary>
public partial class SettingsWindow : Window
{
    private static readonly Brush ActiveSegBrush = new SolidColorBrush(Color.FromRgb(0x2A, 0x27, 0x24));
    private static readonly Brush IdleSegBrush = Brushes.Transparent;
    private static readonly Brush ActiveTextBrush = new SolidColorBrush(Color.FromRgb(0xF2, 0xF2, 0xF2));
    private static readonly Brush IdleTextBrush = new SolidColorBrush(Color.FromRgb(0x8A, 0x85, 0x7F));
    private static readonly Brush OnBrush = new SolidColorBrush(Color.FromRgb(0x7D, 0xD9, 0xA6));
    private static readonly Brush QuietBrush = new SolidColorBrush(Color.FromRgb(0xC9, 0xC3, 0xBA));
    private static readonly Brush ValueBrush = new SolidColorBrush(Color.FromRgb(0xE2, 0xDD, 0xD5));
    private static readonly Brush WarningGold = new SolidColorBrush(Color.FromRgb(0xE8, 0xC2, 0x68));
    private static readonly Brush ActiveBorderBrush = new SolidColorBrush(Color.FromArgb(0x40, 0xFF, 0xFF, 0xFF));
    private static readonly Brush IdleBorderBrush = new SolidColorBrush(Color.FromArgb(0x24, 0xFF, 0xFF, 0xFF));

    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    private readonly AudioEngine _engine;
    private readonly Action<int> _bufferChanged;
    private readonly Action<bool> _driftChanged;
    private readonly Action<bool> _loopChanged;
    private readonly DispatcherTimer _timer;

    private int _bufferMs;
    private bool _drift;
    private bool _loop;

    public SettingsWindow(
        AudioEngine engine,
        int bufferMs,
        bool driftCompensation,
        bool loopFile,
        Action<int> bufferChanged,
        Action<bool> driftChanged,
        Action<bool> loopChanged)
    {
        InitializeComponent();

        _engine = engine;
        _bufferChanged = bufferChanged;
        _driftChanged = driftChanged;
        _loopChanged = loopChanged;
        _bufferMs = bufferMs;
        _drift = driftCompensation;
        _loop = loopFile;

        _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(200) };
        _timer.Tick += (_, _) => UpdateLiveReadout();
        _timer.Start();

        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                Close();
            }
        };

        ApplyVisualState();
        UpdateLiveReadout();
    }

    private void Header_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed)
        {
            return;
        }

        try
        {
            DragMove();
        }
        catch (InvalidOperationException)
        {
            // 鼠标已在拖动开始前释放，忽略。
        }
    }

    private void BtnClose_Click(object sender, RoutedEventArgs e) => Close();

    private void BufferSeg_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string tag } || !int.TryParse(tag, NumberStyles.Integer, Inv, out var ms))
        {
            return;
        }

        if (ms == _bufferMs)
        {
            return;
        }

        _bufferMs = ms;
        ApplyVisualState();
        _bufferChanged?.Invoke(_bufferMs);
    }

    private void BtnDrift_Click(object sender, RoutedEventArgs e)
    {
        _drift = !_drift;
        ApplyVisualState();
        _driftChanged?.Invoke(_drift);
    }

    private void BtnLoop_Click(object sender, RoutedEventArgs e)
    {
        _loop = !_loop;
        ApplyVisualState();
        _loopChanged?.Invoke(_loop);
    }

    private void BtnDefaults_Click(object sender, RoutedEventArgs e)
    {
        _bufferMs = 10;
        _drift = true;
        _loop = true;

        ApplyVisualState();
        _bufferChanged?.Invoke(_bufferMs);
        _driftChanged?.Invoke(_drift);
        _loopChanged?.Invoke(_loop);
    }

    private void ApplyVisualState()
    {
        StyleSegment(Buf5, _bufferMs == 5);
        StyleSegment(Buf10, _bufferMs == 10);
        StyleSegment(Buf20, _bufferMs == 20);
        StyleSegment(Buf40, _bufferMs == 40);

        BtnDrift.Content = _drift ? "开启" : "关闭";
        BtnDrift.Foreground = _drift ? OnBrush : IdleTextBrush;

        BtnLoop.Content = _loop ? "循环" : "单次";
        BtnLoop.Foreground = _loop ? QuietBrush : IdleTextBrush;

        DriftHint.Text = _drift
            ? "补偿开启：两条输出流各自跟踪缓冲水位，长期播放不会出现一路快一路慢。"
            : "补偿已关闭：按 1:1 速率读取。两块声卡时钟不同源时水位会单向漂移，最终撞到缓冲边界，表现为周期性爆音或断流。";
    }

    private static void StyleSegment(Button button, bool active)
    {
        button.Background = active ? ActiveSegBrush : IdleSegBrush;
        button.Foreground = active ? ActiveTextBrush : IdleTextBrush;
        button.BorderBrush = active ? ActiveBorderBrush : IdleBorderBrush;
        button.FontWeight = active ? FontWeights.SemiBold : FontWeights.Normal;
    }

    private void UpdateLiveReadout()
    {
        if (!_engine.IsRunning)
        {
            DriftA.Text = "—";
            DriftB.Text = "—";
            LevelA.Text = "—";
            LevelB.Text = "—";
            UnderA.Text = "—";
            UnderB.Text = "—";
            return;
        }

        var a = _engine.ChannelA;
        var b = _engine.ChannelB;

        DriftA.Text = FormatPpm(a.CorrectionPpm);
        DriftB.Text = FormatPpm(b.CorrectionPpm);
        DriftA.Foreground = a.DriftCompensation ? ValueBrush : IdleTextBrush;
        DriftB.Foreground = b.DriftCompensation ? ValueBrush : IdleTextBrush;

        LevelA.Text = FormatMs(a.BufferedMs);
        LevelB.Text = FormatMs(b.BufferedMs);

        UnderA.Text = FormatMs(a.UnderrunMs);
        UnderB.Text = FormatMs(b.UnderrunMs);
        UnderA.Foreground = a.UnderrunMs > 1 ? WarningGold : IdleTextBrush;
        UnderB.Foreground = b.UnderrunMs > 1 ? WarningGold : IdleTextBrush;
    }

    private static string FormatPpm(double ppm)
    {
        if (double.IsNaN(ppm) || double.IsInfinity(ppm))
        {
            return "—";
        }

        var sign = ppm >= 0 ? "+" : "-";
        return sign + Math.Abs(ppm).ToString("0.0", Inv) + " ppm";
    }

    private static string FormatMs(double ms)
    {
        if (double.IsNaN(ms) || double.IsInfinity(ms))
        {
            return "—";
        }

        return ms.ToString("0.0", Inv) + " ms";
    }

    protected override void OnClosed(EventArgs e)
    {
        _timer.Stop();
        base.OnClosed(e);
    }
}
