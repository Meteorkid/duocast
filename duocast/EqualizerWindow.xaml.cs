using System;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using DuoCast.Audio;

namespace DuoCast;

/// <summary>
/// 10 段图示均衡器窗口：A / B 两组各自独立的 10 根竖向滑块。
/// 滑块共 20 个，直接在代码里生成（XAML 里手写 20 段会失去可读性），
/// 每根滑块的值变化立刻写入对应通道的 TenBandEqualizer。
/// </summary>
public partial class EqualizerWindow : Window
{
    private static readonly Brush AccentA = new SolidColorBrush(Color.FromRgb(0xF2, 0xF2, 0xF2));
    private static readonly Brush AccentB = new SolidColorBrush(Color.FromRgb(0xE8, 0xC2, 0x68));
    private static readonly Brush IdleBrush = new SolidColorBrush(Color.FromRgb(0x8A, 0x85, 0x7F));
    private static readonly Brush QuietBrush = new SolidColorBrush(Color.FromRgb(0xC9, 0xC3, 0xBA));
    private static readonly Brush BypassBrush = new SolidColorBrush(Color.FromRgb(0xE8, 0xC2, 0x68));
    private static readonly Brush LabelBrush = new SolidColorBrush(Color.FromRgb(0x6E, 0x68, 0x62));

    private static readonly FontFamily MonoFont = new("Consolas");
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    private static readonly string[] FrequencyLabels = { "31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k" };

    private static readonly float[] PresetFlat = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    private static readonly float[] PresetBass = { 6, 5, 3, 1, 0, 0, 0, 0, 0, 0 };
    private static readonly float[] PresetVocal = { -3, -2, -1, 0, 1, 2, 3, 2, 1, 0 };
    private static readonly float[] PresetBright = { 0, 0, 0, 0, -1, 0, 1, 2, 4, 5 };

    private readonly TenBandEqualizer _eqA;
    private readonly TenBandEqualizer _eqB;

    private readonly Slider[] _slidersA = new Slider[TenBandEqualizer.BandCount];
    private readonly Slider[] _slidersB = new Slider[TenBandEqualizer.BandCount];

    public EqualizerWindow(TenBandEqualizer eqA, TenBandEqualizer eqB)
    {
        InitializeComponent();

        _eqA = eqA;
        _eqB = eqB;

        BuildBands(EqA, _eqA, AccentA, _slidersA);
        BuildBands(EqB, _eqB, AccentB, _slidersB);

        UpdateBypassVisual();

        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                Close();
            }
        };
    }

    private void BuildBands(StackPanel host, TenBandEqualizer equalizer, Brush accent, Slider[] sliders)
    {
        for (var i = 0; i < TenBandEqualizer.BandCount; i++)
        {
            var index = i;
            var gain = equalizer.GetGain(index);

            var value = new TextBlock
            {
                Text = FormatGain(gain),
                Foreground = Math.Abs(gain) >= 0.5f ? accent : IdleBrush,
                FontSize = 9,
                FontFamily = MonoFont,
                HorizontalAlignment = HorizontalAlignment.Center
            };

            var slider = new Slider
            {
                Style = (Style)FindResource("EqSlider"),
                Foreground = accent,
                Value = gain,
                Margin = new Thickness(0, 5, 0, 3)
            };

            slider.ValueChanged += (_, e) =>
            {
                equalizer.SetGain(index, (float)e.NewValue);
                value.Text = FormatGain(e.NewValue);
                value.Foreground = Math.Abs(e.NewValue) >= 0.5 ? accent : IdleBrush;
            };

            var frequency = new TextBlock
            {
                Text = FrequencyLabels[index],
                Foreground = LabelBrush,
                FontSize = 9,
                FontFamily = MonoFont,
                HorizontalAlignment = HorizontalAlignment.Center
            };

            var column = new StackPanel { Width = 25 };
            column.Children.Add(value);
            column.Children.Add(slider);
            column.Children.Add(frequency);

            host.Children.Add(column);

            sliders[index] = slider;
        }
    }

    private void SyncSliders()
    {
        for (var i = 0; i < TenBandEqualizer.BandCount; i++)
        {
            _slidersA[i].Value = _eqA.GetGain(i);
            _slidersB[i].Value = _eqB.GetGain(i);
        }
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
            // 鼠标在拖动开始前已释放，忽略。
        }
    }

    private void BtnClose_Click(object sender, RoutedEventArgs e) => Close();

    private void BtnBypass_Click(object sender, RoutedEventArgs e)
    {
        var next = !_eqA.Enabled;
        _eqA.Enabled = next;
        _eqB.Enabled = next;
        UpdateBypassVisual();
    }

    private void UpdateBypassVisual()
    {
        var enabled = _eqA.Enabled && _eqB.Enabled;
        BtnBypass.Content = enabled ? "旁通：关" : "旁通：开";
        BtnBypass.Foreground = enabled ? QuietBrush : BypassBrush;
    }

    private void PresetFlat_Click(object sender, RoutedEventArgs e) => ApplyPreset(PresetFlat);

    private void PresetBass_Click(object sender, RoutedEventArgs e) => ApplyPreset(PresetBass);

    private void PresetVocal_Click(object sender, RoutedEventArgs e) => ApplyPreset(PresetVocal);

    private void PresetBright_Click(object sender, RoutedEventArgs e) => ApplyPreset(PresetBright);

    private void BtnReset_Click(object sender, RoutedEventArgs e)
    {
        _eqA.Reset();
        _eqB.Reset();
        _eqA.Enabled = true;
        _eqB.Enabled = true;

        SyncSliders();
        UpdateBypassVisual();
    }

    private void ApplyPreset(float[] gains)
    {
        _eqA.SetGains(gains);
        _eqB.SetGains(gains);
        SyncSliders();
    }

    private static string FormatGain(double value)
    {
        return value.ToString("+0.0;-0.0;0.0", Inv);
    }
}
