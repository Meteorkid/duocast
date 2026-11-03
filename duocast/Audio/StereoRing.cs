using System;

namespace DuoCast.Audio;

/// <summary>
/// 交错立体声（L,R,L,R...）float32 环形缓冲。
/// 写入端由采集线程调用，读取端由 WASAPI 渲染线程调用，内部用单锁保护。
/// </summary>
public sealed class StereoRing
{
    private readonly float[] _buffer;
    private readonly int _mask;
    private readonly object _gate = new();
    private long _written;

    public StereoRing(int capacityFrames)
    {
        var capacity = 1;
        while (capacity < capacityFrames)
        {
            capacity <<= 1;
        }

        _buffer = new float[capacity * 2];
        _mask = capacity - 1;
    }

    public int CapacityFrames => _mask + 1;

    public long TotalWritten
    {
        get
        {
            lock (_gate)
            {
                return _written;
            }
        }
    }

    public void Reset()
    {
        lock (_gate)
        {
            Array.Clear(_buffer, 0, _buffer.Length);
            _written = 0;
        }
    }

    /// <summary>写入交错立体声数据。溢出时丢弃最旧数据。</summary>
    public void Write(float[] interleaved, int frames)
    {
        if (frames <= 0)
        {
            return;
        }

        lock (_gate)
        {
            var offset = 0;
            if (frames > CapacityFrames)
            {
                offset = frames - CapacityFrames;
                frames = CapacityFrames;
            }

            for (var f = 0; f < frames; f++)
            {
                var slot = (int)((_written + f) & _mask);
                _buffer[slot * 2] = interleaved[(offset + f) * 2];
                _buffer[slot * 2 + 1] = interleaved[(offset + f) * 2 + 1];
            }

            _written += frames;
        }
    }

    /// <summary>
    /// 从 startPos（帧，可为小数）开始按 step 步进读取，用线性插值做亚采样重采样。
    /// 返回结束位置与欠载帧数（欠载处补静音）。
    /// </summary>
    public void ReadInterpolated(double startPos, double step, float[] dest, int frames,
        out double endPos, out int underrunFrames)
    {
        lock (_gate)
        {
            var pos = startPos;
            var underruns = 0;
            var lastValid = _written - 1;
            var oldestValid = _written - CapacityFrames;

            for (var f = 0; f < frames; f++)
            {
                var i0 = (long)Math.Floor(pos);
                var frac = (float)(pos - i0);

                if (i0 > lastValid - 1 || i0 < oldestValid)
                {
                    dest[f * 2] = 0f;
                    dest[f * 2 + 1] = 0f;
                    underruns++;
                }
                else
                {
                    var s0 = (int)(i0 & _mask);
                    var s1 = (int)((i0 + 1) & _mask);
                    var l0 = _buffer[s0 * 2];
                    var r0 = _buffer[s0 * 2 + 1];
                    var l1 = _buffer[s1 * 2];
                    var r1 = _buffer[s1 * 2 + 1];
                    dest[f * 2] = l0 + (l1 - l0) * frac;
                    dest[f * 2 + 1] = r0 + (r1 - r0) * frac;
                }

                pos += step;
            }

            endPos = pos;
            underrunFrames = underruns;
        }
    }
}
