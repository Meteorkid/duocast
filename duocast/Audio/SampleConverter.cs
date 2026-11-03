using System;
using NAudio.Wave;

namespace DuoCast.Audio;

/// <summary>
/// 把采集端 / 文件端的原始字节流统一转换成「交错立体声 float32」。
/// 约定（覆盖 WASAPI 共享模式混音格式与常见音频文件）：
///   4 字节 → IEEE float32
///   3 字节 → 有符号 PCM24
///   2 字节 → 有符号 PCM16
///   1 字节 → 无符号 PCM8
/// 多声道取前两个声道（5.1 即 FL / FR），单声道复制到左右。
/// </summary>
public static class SampleConverter
{
    public static int ToStereoFloat(byte[] buffer, int bytesRecorded, WaveFormat format, float[] dest)
    {
        var channels = Math.Max(1, format.Channels);
        var blockAlign = Math.Max(1, format.BlockAlign);
        var bytesPerSample = Math.Max(1, blockAlign / channels);
        var frames = bytesRecorded / blockAlign;

        if (frames <= 0)
        {
            return 0;
        }

        if (dest.Length < frames * 2)
        {
            throw new ArgumentException("目标缓冲太小", nameof(dest));
        }

        for (var f = 0; f < frames; f++)
        {
            var baseIndex = f * blockAlign;
            var left = ReadSample(buffer, baseIndex, bytesPerSample);
            var right = channels >= 2 ? ReadSample(buffer, baseIndex + bytesPerSample, bytesPerSample) : left;

            dest[f * 2] = left;
            dest[f * 2 + 1] = right;
        }

        return frames;
    }

    private static float ReadSample(byte[] data, int index, int bytesPerSample)
    {
        switch (bytesPerSample)
        {
            case 4:
                return BitConverter.ToSingle(data, index);

            case 3:
            {
                var v = data[index] | (data[index + 1] << 8) | (data[index + 2] << 16);
                if ((v & 0x800000) != 0)
                {
                    v |= unchecked((int)0xFF000000);
                }

                return v / 8388608f;
            }

            case 2:
                return BitConverter.ToInt16(data, index) / 32768f;

            case 1:
                return (data[index] - 128) / 128f;

            default:
                return 0f;
        }
    }
}
