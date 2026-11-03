using System;
using System.Collections.Generic;
using NAudio.CoreAudioApi;

namespace DuoCast.Audio;

public sealed class DeviceEntry
{
    public DeviceEntry(string id, string name, bool isDefault)
    {
        Id = id;
        Name = name;
        IsDefault = isDefault;
    }

    public string Id { get; }

    public string Name { get; }

    public bool IsDefault { get; }

    public string DisplayName => IsDefault ? Name + "（默认）" : Name;

    public override string ToString() => DisplayName;
}

/// <summary>音频端点枚举：只返回当前处于 Active 状态的设备。</summary>
public static class Devices
{
    private static readonly string[] BluetoothKeywords =
    {
        "bluetooth", "蓝牙", "airpods", "hands-free", "handsfree", "buds", "beats",
        "wh-1000", "wf-1000", "bose", "soundcore", "enco", "freebuds"
    };

    /// <summary>
    /// 端点名启发式判断是否为蓝牙设备。WASAPI 不暴露传输类型，
    /// 只能靠名称匹配（Windows 蓝牙端点通常含 "Bluetooth" / "蓝牙" 或耳机型号）。
    /// </summary>
    public static bool LooksBluetooth(string? name)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            return false;
        }

        var lower = name.ToLowerInvariant();
        foreach (var keyword in BluetoothKeywords)
        {
            if (lower.Contains(keyword, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }

    public static List<DeviceEntry> Render()
    {
        var result = new List<DeviceEntry>();

        using var enumerator = new MMDeviceEnumerator();
        var defaultId = string.Empty;

        try
        {
            using var defaultDevice = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            defaultId = defaultDevice.ID;
        }
        catch
        {
            // 没有默认输出设备时忽略。
        }

        foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
        {
            using (device)
            {
                result.Add(new DeviceEntry(device.ID, device.FriendlyName, device.ID == defaultId));
            }
        }

        return result;
    }

    public static List<DeviceEntry> Capture()
    {
        var result = new List<DeviceEntry>();

        using var enumerator = new MMDeviceEnumerator();
        var defaultId = string.Empty;

        try
        {
            using var defaultDevice = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Multimedia);
            defaultId = defaultDevice.ID;
        }
        catch
        {
            // 没有默认录音设备时忽略。
        }

        foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
        {
            using (device)
            {
                result.Add(new DeviceEntry(device.ID, device.FriendlyName, device.ID == defaultId));
            }
        }

        return result;
    }
}
