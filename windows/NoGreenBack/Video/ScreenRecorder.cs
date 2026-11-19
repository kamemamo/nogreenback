// 画面録画の書き出し (SPEC.md 9 章)
// - 画面を Windows.Graphics.Capture で取り込み、長辺を決めた大きさまで GPU で縮め、ハードウェアのエンコーダー (Media Foundation) で圧縮する
// - 落ちても消えないよう、録画中は断片化した MP4 (fragmented MP4) に書く (2 秒ごとにキーフレーム)。
//   止めたら再圧縮せずに通常の MP4 へ詰め替え、断片化した方を消す。詰め替えに失敗したら断片化した方を残す
// - 画面が動かない間はコマが届かないので、コマ数が減る。フレームレートは最大値で、それより速く届いたコマは捨てる
// - 音声は 48 kHz・モノラル・AAC。マイクの音は、最初の時刻を基準にサンプル数から時刻を付け直して隙間なく並べる
//   (0.25 秒以上ずれたら基準を取り直す)。映像が始まる前の音は捨てる
// 録画は合成とは別の Direct3D のデバイスで行う (エンコーダーと合成が同じデバイスの状態を取り合わないように)。

using System.Diagnostics;
using System.IO;
using System.Numerics;
using Vortice.Direct3D11;
using Vortice.MediaFoundation;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using NoGreenBack.Audio;

namespace NoGreenBack.Video;

public sealed record RecordOptions(int Mbps, int LongSide, int Fps, bool Hevc, int AudioKbps);

public sealed class ScreenRecorder : IDisposable
{
    const long TicksPerSecond = 10_000_000;   // Media Foundation の時刻の単位 (100 ns)

    readonly object writeLock = new();
    readonly Gpu gpu = new();
    readonly IDirect3DDevice d3dDevice;
    readonly GraphicsCaptureItem item;
    readonly Direct3D11CaptureFramePool pool;
    readonly GraphicsCaptureSession session;
    readonly IMFDXGIDeviceManager deviceManager;
    readonly IMFSinkWriter writer;
    readonly int videoStream, audioStream = -1;
    readonly GpuImage source = new();
    readonly GpuTarget[] ring;
    int ringIndex;
    readonly int outW, outH, fps;
    readonly MicInput? mic;
    readonly string tempPath;
    Windows.Graphics.SizeInt32 poolSize;

    TimeSpan? firstFrameTime;
    long startTicks;        // 最初のコマが届いた時刻 (Stopwatch。音の時刻の基準)

    /// 最初のコマが届いた時刻 (Stopwatch。録画の 0 秒。字幕の時刻の基準)
    public long StartTicks => startTicks;
    long lastVideoTime = long.MinValue;
    long nextKeyFrame;
    long audioNext = long.MinValue;
    short[] pcm = new short[4800];
    bool stopped;

    /// 書いた映像のコマ数・音のサンプル数
    public int FrameCount { get; private set; }
    public long AudioSamples { get; private set; }
    public bool HasAudio => audioStream >= 0;

    /// 書き出し中の、断片化した MP4 のパス
    public string TempPath => tempPath;

    // 外部の音声 (SPEC.md 9 章「録画の音声」)。マイクがあれば外部の音をためておき、マイクの音に 外部 × 下げる倍率 × 音量 を足す。
    // マイクが「なし」なら外部の音だけを × 音量 で録る。外部の機器とマイクが同じ機器なら混ぜない (二重になるため)
    readonly ExternalAudio? external;
    readonly bool mixExternal, externalOnly;
    readonly object extLock = new();
    readonly float[] extBuf = new float[MicInput.SampleRate];   // たまった外部の音 (リングバッファ)
    int extStart, extCount;
    float[] mixBuf = new float[4800];
    float duckGain = 1;
    long lastSpeechTicks = long.MinValue;

    public ScreenRecorder(DisplayInfo display, RecordOptions options, MicInput? mic, string tempPath, ExternalAudio? external = null)
    {
        this.mic = mic;
        this.tempPath = tempPath;
        fps = options.Fps;
        bool hasMic = mic is { Enabled: true };
        if (external?.OpenInputId is { } ext && !(hasMic && ext == mic!.OpenDeviceId))
        {
            this.external = external;
            mixExternal = hasMic;
            externalOnly = !hasMic;
        }

        // 長辺は、画面の実際の画素数を縦横比を保って縮め、偶数にそろえる。画面のほうが小さければ画面のまま
        double scale = options.LongSide > 0 ? Math.Min(1, (double)options.LongSide / Math.Max(display.Width, display.Height)) : 1;
        outW = Math.Max(2, (int)Math.Round(display.Width * scale / 2) * 2);
        outH = Math.Max(2, (int)Math.Round(display.Height * scale / 2) * 2);
        ring = Enumerable.Range(0, 8).Select(_ => new GpuTarget()).ToArray();

        MediaFactory.MFStartup().CheckError();
        deviceManager = MediaFactory.MFCreateDXGIDeviceManager();
        deviceManager.ResetDevice(gpu.Device).CheckError();

        using var attrs = MediaFactory.MFCreateAttributes(4);
        attrs.Set(SinkWriterAttributeKeys.D3DManager, deviceManager);
        attrs.Set(SinkWriterAttributeKeys.ReadwriteEnableHardwareTransforms, 1u);
        attrs.Set(SinkWriterAttributeKeys.DisableThrottling, 1u);
        attrs.Set(TranscodeAttributeKeys.TranscodeContainertype, TranscodeContainerTypeGuids.Fmpeg4);
        writer = MediaFactory.MFCreateSinkWriterFromURL(tempPath, null, attrs);

        // 映像: H.264 か HEVC、平均ビットレート、2 秒ごとにキーフレーム
        using (var outType = MediaFactory.MFCreateMediaType())
        using (var inType = MediaFactory.MFCreateMediaType())
        {
            outType.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
            outType.Set(MediaTypeAttributeKeys.Subtype, FourCC(options.Hevc ? "HEVC" : "H264"));
            outType.Set(MediaTypeAttributeKeys.AvgBitrate, (uint)(options.Mbps * 1_000_000));
            outType.Set(MediaTypeAttributeKeys.InterlaceMode, 2u /* progressive */);
            outType.Set(MediaTypeAttributeKeys.FrameSize, Pack(outW, outH));
            outType.Set(MediaTypeAttributeKeys.FrameRate, Pack(fps, 1));
            outType.Set(MediaTypeAttributeKeys.PixelAspectRatio, Pack(1, 1));
            outType.Set(MediaTypeAttributeKeys.MaxKeyframeSpacing, (uint)(fps * 2));
            videoStream = writer.AddStream(outType);

            inType.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
            inType.Set(MediaTypeAttributeKeys.Subtype, VideoFormatGuids.Rgb32);
            inType.Set(MediaTypeAttributeKeys.InterlaceMode, 2u);
            inType.Set(MediaTypeAttributeKeys.FrameSize, Pack(outW, outH));
            inType.Set(MediaTypeAttributeKeys.FrameRate, Pack(fps, 1));
            inType.Set(MediaTypeAttributeKeys.PixelAspectRatio, Pack(1, 1));
            writer.SetInputMediaType(videoStream, inType, null);
        }

        // 音声: AAC・48 kHz・モノラル (Windows の AAC エンコーダーは 96 / 128 / 160 / 192 kbps だけなので、近いものにする)
        if (hasMic || externalOnly)
        {
            int kbps = new[] { 96, 128, 160, 192 }.MinBy(k => Math.Abs(k - options.AudioKbps));
            using var outType = MediaFactory.MFCreateMediaType();
            using var inType = MediaFactory.MFCreateMediaType();
            outType.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Audio);
            outType.Set(MediaTypeAttributeKeys.Subtype, AudioFormatGuids.Aac);
            outType.Set(MediaTypeAttributeKeys.AudioBitsPerSample, 16u);
            outType.Set(MediaTypeAttributeKeys.AudioSamplesPerSecond, (uint)MicInput.SampleRate);
            outType.Set(MediaTypeAttributeKeys.AudioNumChannels, 1u);
            outType.Set(MediaTypeAttributeKeys.AudioAvgBytesPerSecond, (uint)(kbps * 1000 / 8));
            audioStream = writer.AddStream(outType);

            inType.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Audio);
            inType.Set(MediaTypeAttributeKeys.Subtype, AudioFormatGuids.Pcm);
            inType.Set(MediaTypeAttributeKeys.AudioBitsPerSample, 16u);
            inType.Set(MediaTypeAttributeKeys.AudioSamplesPerSecond, (uint)MicInput.SampleRate);
            inType.Set(MediaTypeAttributeKeys.AudioNumChannels, 1u);
            inType.Set(MediaTypeAttributeKeys.AudioBlockAlignment, 2u);
            inType.Set(MediaTypeAttributeKeys.AudioAvgBytesPerSecond, (uint)(MicInput.SampleRate * 2));
            writer.SetInputMediaType(audioStream, inType, null);
            if (kbps != options.AudioKbps) Log.Write($"録画: 音声は {options.AudioKbps} kbps にできないので {kbps} kbps にします");
        }

        writer.BeginWriting();

        // 画面の取り込み (このアプリの映さないウィンドウは、Overlays.OverlayController が取り込みから外している)
        d3dDevice = CaptureInterop.CreateDirect3DDevice(gpu.Device);
        item = CaptureInterop.CreateItemForMonitor(display);
        poolSize = item.Size;
        pool = Direct3D11CaptureFramePool.CreateFreeThreaded(d3dDevice, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, item.Size);
        pool.FrameArrived += OnFrame;
        session = pool.CreateCaptureSession(item);
        session.IsCursorCaptureEnabled = true;
        try { session.IsBorderRequired = false; } catch { }
        if (hasMic) mic!.SamplesArrived += OnMic;
        if (this.external != null) this.external.SamplesArrived += OnExternal;
        session.StartCapture();
        Log.Write($"録画: {display.Name} {display.Width}x{display.Height} → {outW}x{outH} {fps}fps {options.Mbps}Mbps {(options.Hevc ? "HEVC" : "H.264")}");
    }

    void OnFrame(Direct3D11CaptureFramePool sender, object args)
    {
        using var frame = sender.TryGetNextFrame();
        if (frame == null) return;
        lock (writeLock)
        {
            if (stopped) return;
            var size = frame.ContentSize;
            if (size.Width != poolSize.Width || size.Height != poolSize.Height)
            {
                // 画面の大きさが変わった。次のコマから新しい大きさで受け取る (縮める先の大きさはそのまま)
                poolSize = size;
                sender.Recreate(d3dDevice, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, size);
                return;
            }
            firstFrameTime ??= frame.SystemRelativeTime;
            long time = (frame.SystemRelativeTime - firstFrameTime.Value).Ticks;
            // 最大フレームレートより速く届いたコマは捨てる (少しの揺れは許す)
            if (lastVideoTime != long.MinValue && time - lastVideoTime < TicksPerSecond / fps - 20_000) return;
            if (FrameCount == 0) startTicks = Stopwatch.GetTimestamp();

            // コマを写して、出力の大きさに縮める
            using (var tex = CaptureInterop.GetTexture(frame)) source.CopyFrom(gpu, tex, size.Width, size.Height);
            var target = ring[ringIndex];
            ringIndex = (ringIndex + 1) % ring.Length;
            target.Ensure(gpu, outW, outH);
            gpu.CopyForSpout(target.Rtv!, outW, outH, source.Srv!, flip: false, straightAlpha: false);

            using var buffer = MediaFactory.MFCreateDXGISurfaceBuffer(typeof(ID3D11Texture2D).GUID, target.Texture!, 0, false);
            using (var b2 = buffer.QueryInterface<IMF2DBuffer>()) buffer.CurrentLength = b2.ContiguousLength;
            using var sample = MediaFactory.MFCreateSample();
            sample.AddBuffer(buffer);
            sample.SampleTime = time;
            sample.SampleDuration = TicksPerSecond / fps;
            // 2 秒ごとにキーフレームにする (断片化した MP4 は、キーフレームごとに区切って書くので、落ちてもそこまで再生できる)
            if (time >= nextKeyFrame)
            {
                sample.Set(SampleAttributeKeys.CleanPoint, 1u);
                nextKeyFrame = time + 2 * TicksPerSecond;
            }
            writer.WriteSample(videoStream, sample);
            lastVideoTime = time;
            FrameCount++;
        }
    }

    /// 外部の音が届いた。マイクと混ぜるときはためておき、外部の音だけを録るときはそのまま書く
    void OnExternal(float[] samples, int count, long arrivedTicks)
    {
        float vol = (float)external!.Volume;
        if (externalOnly)
        {
            lock (extLock)
            {
                if (mixBuf.Length < count) mixBuf = new float[count];
                for (int i = 0; i < count; i++) mixBuf[i] = Math.Clamp(samples[i] * vol, -1f, 1f);
                OnAudio(mixBuf, count, arrivedTicks);
            }
            return;
        }
        lock (extLock)
        {
            for (int i = 0; i < count; i++)
            {
                // たまりすぎたら (0.25 秒を超えたら) 古いほうを捨てて、遅れないようにする
                if (extCount >= MicInput.SampleRate / 4) { extStart = (extStart + 1) % extBuf.Length; extCount--; }
                extBuf[(extStart + extCount) % extBuf.Length] = samples[i];
                extCount++;
            }
        }
    }

    /// マイクの音が届いた。外部の音を混ぜるときは、声で下げる倍率を掛けて足す
    void OnMic(float[] samples, int count, long arrivedTicks)
    {
        if (!mixExternal) { OnAudio(samples, count, arrivedTicks); return; }
        // 声で下げる: マイクの音の大きさ (RMS) が -36 dBFS を超えたら、外部の音を「下げる倍率」まで 0.05 秒で下げ、
        // 話し終わって 0.6 秒たったら 0.5 秒かけて戻す
        double sum = 0;
        for (int i = 0; i < count; i++) sum += samples[i] * samples[i];
        double db = 20 * Math.Log10(Math.Sqrt(sum / Math.Max(1, count)) + 1e-12);
        if (db > -36) lastSpeechTicks = arrivedTicks;
        bool holding = lastSpeechTicks != long.MinValue && Stopwatch.GetElapsedTime(lastSpeechTicks, arrivedTicks).TotalSeconds < 0.6;
        float duck = (float)external!.DuckFactor, vol = (float)external.Volume;
        float target = holding ? duck : 1;
        float range = Math.Max(1e-6f, 1 - duck);
        float down = range / (0.05f * MicInput.SampleRate), up = range / (0.5f * MicInput.SampleRate);
        lock (extLock)
        {
            if (mixBuf.Length < count) mixBuf = new float[count];
            for (int i = 0; i < count; i++)
            {
                float e = 0;
                if (extCount > 0) { e = extBuf[extStart]; extStart = (extStart + 1) % extBuf.Length; extCount--; }
                duckGain = duckGain > target ? Math.Max(target, duckGain - down) : Math.Min(target, duckGain + up);
                mixBuf[i] = Math.Clamp(samples[i] + e * duckGain * vol, -1f, 1f);
            }
            OnAudio(mixBuf, count, arrivedTicks);
        }
    }

    void OnAudio(float[] samples, int count, long arrivedTicks)
    {
        lock (writeLock)
        {
            if (stopped || audioStream < 0 || FrameCount == 0) return;   // 映像が始まる前の音は捨てる
            long duration = count * TicksPerSecond / MicInput.SampleRate;
            // 届いた時刻から、このかたまりの始まりの時刻 (映像の最初のコマを 0 とする)
            long arrivedStart = Stopwatch.GetElapsedTime(startTicks, arrivedTicks).Ticks - duration;
            if (audioNext == long.MinValue || Math.Abs(arrivedStart - audioNext) > TicksPerSecond / 4) audioNext = Math.Max(0, arrivedStart);

            if (pcm.Length < count) pcm = new short[count];
            for (int i = 0; i < count; i++) pcm[i] = (short)Math.Clamp(samples[i] * 32767f, -32768f, 32767f);
            using var buffer = MediaFactory.MFCreateMemoryBuffer(count * 2);
            buffer.Lock(out IntPtr ptr, out _, out _);
            System.Runtime.InteropServices.Marshal.Copy(pcm, 0, ptr, count);
            buffer.Unlock();
            buffer.CurrentLength = count * 2;
            using var sample = MediaFactory.MFCreateSample();
            sample.AddBuffer(buffer);
            sample.SampleTime = audioNext;
            sample.SampleDuration = duration;
            writer.WriteSample(audioStream, sample);
            audioNext += duration;
            AudioSamples += count;
        }
    }

    /// 取り込みを止めて、断片化した MP4 を閉じる
    public void Stop()
    {
        if (mic != null) mic.SamplesArrived -= OnMic;
        if (external != null) external.SamplesArrived -= OnExternal;
        try { session.Dispose(); } catch { }
        lock (writeLock)
        {
            if (stopped) return;
            stopped = true;
            pool.FrameArrived -= OnFrame;
            pool.Dispose();
            try { if (FrameCount > 0) writer.Finalize(); }
            catch (Exception e) { Log.Write($"録画を閉じられません: {e.Message}"); }
        }
    }

    /// 断片化した MP4 を、再圧縮せずに通常の MP4 へ詰め替える
    public static void Remux(string fragmented, string output)
    {
        using var reader = MediaFactory.MFCreateSourceReaderFromURL(fragmented, null);
        using var w = MediaFactory.MFCreateSinkWriterFromURL(output, null, null);
        var map = new Dictionary<int, int>();
        for (int i = 0; ; i++)
        {
            IMFMediaType type;
            try { type = reader.GetNativeMediaType(i, 0); }
            catch { break; }   // それ以上の流れはない
            using (type)
            {
                reader.SetStreamSelection(i, true);
                map[i] = w.AddStream(type);   // 入力の形式を決めないので、圧縮したまま書く
            }
        }
        w.BeginWriting();
        var ended = new HashSet<int>();
        while (ended.Count < map.Count)
        {
            using var sample = reader.ReadSample(SourceReaderIndex.AnyStream, 0, out int stream, out var flags, out _);
            if ((flags & SourceReaderFlag.EndOfStream) != 0) { ended.Add(stream); continue; }
            if ((flags & SourceReaderFlag.Error) != 0) throw new IOException("読み込みに失敗しました");
            if (sample != null && map.TryGetValue(stream, out int target)) w.WriteSample(target, sample);
        }
        w.Finalize();
    }

    public void Dispose()
    {
        Stop();
        writer.Dispose();
        deviceManager.Dispose();
        foreach (var t in ring) t.Dispose();
        source.Dispose();
        gpu.Dispose();
    }

    static Guid FourCC(string s) =>
        new(s[0] | s[1] << 8 | s[2] << 16 | s[3] << 24, 0x0000, 0x0010, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71);

    static ulong Pack(int hi, int lo) => (ulong)(uint)hi << 32 | (uint)lo;
}
