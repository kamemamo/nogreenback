// AudioGraph のフレームから音を読む (マイクと外部の音声で共通)

using System.Runtime.InteropServices;
using Windows.Media;
using Windows.Media.Audio;
using WinRT;

namespace NoGreenBack.Audio;

static class AudioFrames
{
    /// 音の大きさのしきい (無音)
    public const double SilentDb = -160;

    /// 出力ノードに届いたフレームを buffer (48 kHz モノラル float) に写し、サンプル数と大きさ (RMS、dBFS) を返す。
    /// buffer は足りなければ大きくする
    public static unsafe int Read(AudioFrameOutputNode node, ref float[] buffer, out double levelDb)
    {
        levelDb = SilentDb;
        using var frame = node.GetFrame();
        using var buf = frame.LockBuffer(AudioBufferAccessMode.Read);
        using var reference = buf.CreateReference();
        reference.As<IMemoryBufferByteAccess>().GetBuffer(out byte* data, out _);
        int n = (int)(buf.Length / sizeof(float));
        if (n <= 0) return 0;
        if (buffer.Length < n) buffer = new float[n];
        new ReadOnlySpan<float>(data, n).CopyTo(buffer);
        double sum = 0;
        for (int i = 0; i < n; i++) sum += buffer[i] * buffer[i];
        double rms = Math.Sqrt(sum / n);
        levelDb = rms > 1e-8 ? 20 * Math.Log10(rms) : SilentDb;
        return n;
    }

    /// メーターの値 (0〜30。(dB + 60) / 2。24 が -12 dB、28 が -4 dB。Mac 版と同じ目盛り)
    public static double Meter(double levelDb) => Math.Clamp((levelDb + 60) / 2, 0, 30);

    [ComImport, Guid("5B0D3235-4DBA-4D44-865E-8F1D0E4FD04D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    unsafe interface IMemoryBufferByteAccess
    {
        void GetBuffer(out byte* buffer, out uint capacity);
    }
}
