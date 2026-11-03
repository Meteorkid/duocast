using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace DuoCast;

/// <summary>
/// 会话状态：下次启动要恢复的东西。
/// 只存「用户显式选择过」的内容，不存运行态（是否正在分发、电平、欠载计数等）。
/// </summary>
public sealed class AppSettings
{
    public int BufferMs { get; set; } = 10;

    public bool DriftCompensation { get; set; } = true;

    public bool LoopFile { get; set; } = true;

    public int Mode { get; set; }

    public int OffsetA { get; set; }

    public int OffsetB { get; set; }

    public double VolumeA { get; set; } = 78;

    public double VolumeB { get; set; } = 52;

    public bool MutedA { get; set; }

    public bool MutedB { get; set; }

    public string? DeviceAId { get; set; }

    public string? DeviceBId { get; set; }

    public string? CaptureDeviceId { get; set; }

    public string? LastFile { get; set; }

    public bool EqEnabled { get; set; } = true;

    public float[] EqA { get; set; } = new float[10];

    public float[] EqB { get; set; } = new float[10];

    /// <summary>
    /// 把手改过的 json（或旧版本文件）收进合法范围。
    /// 任何一项越界都退回默认值，不让一个坏值把启动流程带崩。
    /// </summary>
    public void Normalize()
    {
        BufferMs = BufferMs is 5 or 10 or 20 or 40 ? BufferMs : 10;
        Mode = Mode is >= 0 and <= 2 ? Mode : 0;

        OffsetA = Math.Clamp(OffsetA, 0, 500);
        OffsetB = Math.Clamp(OffsetB, 0, 500);

        VolumeA = double.IsNaN(VolumeA) ? 78 : Math.Clamp(VolumeA, 0, 120);
        VolumeB = double.IsNaN(VolumeB) ? 52 : Math.Clamp(VolumeB, 0, 120);

        EqA = NormalizeBands(EqA);
        EqB = NormalizeBands(EqB);
    }

    private static float[] NormalizeBands(float[]? source)
    {
        var result = new float[10];

        if (source == null)
        {
            return result;
        }

        for (var i = 0; i < result.Length && i < source.Length; i++)
        {
            var value = source[i];
            result[i] = float.IsNaN(value) ? 0f : Math.Clamp(value, -12f, 12f);
        }

        return result;
    }
}

/// <summary>
/// settings.json 的读写。路径固定在 %AppData%\DuoCast\。
/// 写入走「临时文件 + 覆盖改名」，避免断电/崩溃时留下半个文件把下次启动搞坏。
/// 任何异常都吞掉：设置读不到只是回到默认值，不应该阻止程序启动。
/// </summary>
public static class SettingsStore
{
    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never
    };

    public static string FilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "DuoCast",
        "settings.json");

    public static AppSettings Load()
    {
        try
        {
            var path = FilePath;
            if (!File.Exists(path))
            {
                return new AppSettings();
            }

            var json = File.ReadAllText(path);
            var settings = JsonSerializer.Deserialize<AppSettings>(json, Options) ?? new AppSettings();
            settings.Normalize();
            return settings;
        }
        catch
        {
            return new AppSettings();
        }
    }

    public static void Save(AppSettings settings)
    {
        try
        {
            var path = FilePath;
            var directory = Path.GetDirectoryName(path);

            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }

            var json = JsonSerializer.Serialize(settings, Options);
            var temporary = path + ".tmp";
            File.WriteAllText(temporary, json);
            File.Move(temporary, path, true);
        }
        catch
        {
            // 设置写盘失败不影响正在进行的分发。
        }
    }
}
