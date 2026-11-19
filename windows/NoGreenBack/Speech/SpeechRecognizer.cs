// 字幕の認識 (SPEC.md 10 章「認識」、17 章 3)。端末の中だけで認識し、音声はネットに送らない (Whisper。whisper.cpp を Whisper.net から使う)
// - マイクの音 (48 kHz モノラル) を 16 kHz にし、音の大きさで「話している・黙っている」を分けて区間を作る
// - 話している間は、約 1 秒ごとに区間の始まりからの音を Whisper で読み直して、途中の文字を出す
// - 0.7 秒黙ったら (または 20 秒続いたら)、区間をもう一度読んで文を確定する
// - 「字幕の置き換え」の正しい表記を、Whisper に最初に渡す文章 (prompt) に入れて、認識のヒントにする
// 認識は 1 つのスレッドで順に行う (Whisper は同時に 1 つずつ)。

using System.Diagnostics;
using Whisper.net;
using Whisper.net.LibraryLoader;

namespace NoGreenBack.Speech;

public sealed class SpeechRecognizer : IDisposable
{
    const int Rate = 16000;
    const int FrameLength = Rate / 50;                  // 20 ms ごとに音の大きさを調べる
    const int PreRoll = Rate * 3 / 10;                  // 話し始めの 0.3 秒前から読む
    const int SilenceToFinish = Rate * 7 / 10;          // 0.7 秒黙ったら確定する
    const int MaxSegment = Rate * 20;                   // 20 秒続いたら区切る
    const int MinSegment = Rate * 6 / 10;               // 0.6 秒より短い音は読まない
    const int KeepSeconds = 60;

    readonly object gate = new();
    readonly WhisperModel model;
    readonly CancellationTokenSource cts = new();
    readonly SemaphoreSlim wake = new(0);
    readonly Task worker;

    // 16 kHz の音 (先頭は baseIndex 番目のサンプル)
    float[] audio = new float[Rate * KeepSeconds];
    int audioCount;
    long baseIndex;
    long totalIndex;                 // これまでに受け取ったサンプル数
    long lastFeedTicks;              // 最後に受け取った時刻 (Stopwatch)
    float carry0, carry1; int carryN;   // 48 kHz → 16 kHz の端数

    // 音の大きさと区間
    double noiseDb = -60;
    int frameFill; double frameSum;
    bool inSegment;
    long segStart, lastSpeech;
    readonly Queue<(long Start, long End)> finals = new();
    long lastPartialTicks;

    string language, prompt;
    bool settingsChanged = true;

    /// 話している途中の文字が変わった (認識のスレッドで呼ばれる)
    public event Action<string>? Partial;
    /// 文が確定した (文字、話し始めた時刻、確定した時刻。時刻は Stopwatch)
    public event Action<string, long, long>? Final;
    /// 準備ができた・失敗した (知らせる文。空なら準備できた)
    public event Action<string>? Status;

    /// 認識の 1 回にかかった時間の合計と回数 (速さの記録)
    public double TotalMillis, TotalAudioSeconds;
    public int Runs;

    public string RuntimeName { get; private set; } = "";

    public SpeechRecognizer(WhisperModel model, string language, string prompt)
    {
        this.model = model;
        this.language = language;
        this.prompt = prompt;
        worker = Task.Factory.StartNew(Run, TaskCreationOptions.LongRunning).Unwrap();
    }

    /// 言語と認識のヒントを変える (次に読むときから)
    public void Configure(string language, string prompt)
    {
        lock (gate) { this.language = language; this.prompt = prompt; settingsChanged = true; }
    }

    /// マイクの音 (48 kHz モノラル) を受け取る (マイクのスレッドから呼ぶ)
    public void Feed(float[] samples, int count, long arrivedTicks)
    {
        bool signal = false;
        lock (gate)
        {
            lastFeedTicks = arrivedTicks;
            for (int i = 0; i < count; i++)
            {
                // 3 つずつ平均して 16 kHz にする (平均がそのまま低域通過になる)
                if (carryN == 0) carry0 = samples[i];
                else if (carryN == 1) carry1 = samples[i];
                carryN++;
                if (carryN < 3) continue;
                carryN = 0;
                float v = (carry0 + carry1 + samples[i]) / 3f;
                Append(v);
                frameSum += v * v;
                if (++frameFill == FrameLength) { signal |= EndFrame(); frameFill = 0; frameSum = 0; }
            }
        }
        if (signal) wake.Release();
    }

    void Append(float v)
    {
        if (audioCount == audio.Length)
        {
            // 古い方の半分を捨てる (いま読んでいる区間より前だけ)
            int drop = audio.Length / 2;
            long keepFrom = inSegment ? segStart : totalIndex;
            foreach (var f in finals) keepFrom = Math.Min(keepFrom, f.Start);
            drop = (int)Math.Min(drop, Math.Max(0, keepFrom - baseIndex));
            if (drop == 0) { Array.Resize(ref audio, audio.Length * 2); }
            else
            {
                Array.Copy(audio, drop, audio, 0, audioCount - drop);
                audioCount -= drop;
                baseIndex += drop;
            }
        }
        audio[audioCount++] = v;
        totalIndex++;
    }

    /// 20 ms ごと: 話しているかを決め、区間を進める。確定する区間ができたら true
    bool EndFrame()
    {
        double rms = Math.Sqrt(frameSum / FrameLength);
        double db = rms > 1e-7 ? 20 * Math.Log10(rms) : -140;
        // 雑音の大きさは、静かなときに下がり、ゆっくり上がる
        noiseDb = db < noiseDb ? noiseDb * 0.9 + db * 0.1 : noiseDb + 0.02;
        bool speech = db > Math.Max(-50, noiseDb + 10);

        if (speech)
        {
            if (!inSegment) { inSegment = true; segStart = Math.Max(baseIndex, totalIndex - PreRoll); }
            lastSpeech = totalIndex;
        }
        if (!inSegment) return false;
        if (totalIndex - lastSpeech > SilenceToFinish)
        {
            finals.Enqueue((segStart, lastSpeech + Rate / 5));
            inSegment = false;
            return true;
        }
        if (totalIndex - segStart > MaxSegment)
        {
            finals.Enqueue((segStart, totalIndex));
            segStart = totalIndex;
            return true;
        }
        return false;
    }

    /// サンプルの番号を、その音が届いた時刻 (Stopwatch) に直す
    long TicksOf(long index) => lastFeedTicks - (long)((totalIndex - index) * (double)Stopwatch.Frequency / Rate);

    float[] Slice(long start, long end)
    {
        start = Math.Max(start, baseIndex);
        end = Math.Min(end, totalIndex);
        if (end <= start) return [];
        var r = new float[end - start];
        Array.Copy(audio, start - baseIndex, r, 0, r.Length);
        return r;
    }

    async Task Run()
    {
        WhisperFactory? factory = null;
        WhisperProcessor? processor = null;
        try
        {
            RuntimeOptions.RuntimeLibraryOrder = WhisperModels.VulkanAvailable
                ? [RuntimeLibrary.Vulkan, RuntimeLibrary.Cpu] : [RuntimeLibrary.Cpu];
            var sw = Stopwatch.StartNew();
            factory = WhisperFactory.FromPath(model.LocalPath);
            RuntimeName = RuntimeOptions.LoadedLibrary?.ToString() ?? "?";
            // 最初の 1 回は GPU の準備などで何秒もかかるので、無音で 1 回読んでおく (話し始めの字幕が遅れないように)
            await using (var warm = factory.CreateBuilder().WithLanguage(language).WithSingleSegment().Build())
                await foreach (var _ in warm.ProcessAsync(new float[Rate], cts.Token).ConfigureAwait(false)) { }
            Log.Write($"字幕: {model.Name} を {RuntimeName} で読み込みました (準備を含めて {sw.ElapsedMilliseconds} ms)");
            Status?.Invoke("");

            while (!cts.IsCancellationRequested)
            {
                await wake.WaitAsync(TimeSpan.FromMilliseconds(250), cts.Token).ConfigureAwait(false);

                // 言語やヒントが変わっていたら作り直す
                string lang, hint; bool rebuild;
                lock (gate) { lang = language; hint = prompt; rebuild = settingsChanged; settingsChanged = false; }
                if (rebuild || processor == null)
                {
                    if (processor != null) await processor.DisposeAsync();
                    var b = factory.CreateBuilder()
                        .WithLanguage(lang)
                        .WithNoContext()
                        .WithSingleSegment()
                        .WithTemperature(0)
                        .WithThreads(Math.Clamp(Environment.ProcessorCount / 2, 2, 8));
                    if (hint.Length > 0) b = b.WithPrompt(hint);
                    processor = b.Build();
                }

                // 確定する区間があれば先に読む。なければ、話している途中の区間を 1 秒ごとに読む
                float[] samples; long start, end; bool isFinal;
                lock (gate)
                {
                    if (finals.Count > 0) { (start, end) = finals.Dequeue(); isFinal = true; }
                    else if (inSegment && totalIndex - segStart >= MinSegment
                             && Stopwatch.GetElapsedTime(lastPartialTicks).TotalSeconds >= 1)
                    { start = segStart; end = totalIndex; isFinal = false; }
                    else continue;
                    samples = Slice(start, end);
                }
                if (samples.Length < MinSegment) { if (isFinal) Partial?.Invoke(""); continue; }

                var t0 = Stopwatch.GetTimestamp();
                var text = new System.Text.StringBuilder();
                await foreach (var seg in processor.ProcessAsync(samples, cts.Token).ConfigureAwait(false))
                    if (seg.NoSpeechProbability < 0.6f) text.Append(seg.Text);
                double ms = Stopwatch.GetElapsedTime(t0).TotalMilliseconds;
                TotalMillis += ms; TotalAudioSeconds += samples.Length / (double)Rate; Runs++;
                if (!isFinal) lastPartialTicks = Stopwatch.GetTimestamp();

                string result = SubtitleText.Clean(text.ToString());
                if (isFinal)
                {
                    long s, e;
                    lock (gate) { s = TicksOf(start); e = TicksOf(end); }
                    Partial?.Invoke("");
                    if (result.Length > 0) Final?.Invoke(result, s, e);
                }
                else Partial?.Invoke(result);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            Log.Write($"字幕の認識が止まりました: {e}");
            Status?.Invoke(Loc.L("字幕の認識が止まりました: %@", e.Message));
        }
        finally
        {
            if (processor != null) await processor.DisposeAsync();
            factory?.Dispose();
        }
    }

    public void Dispose()
    {
        cts.Cancel();
        try { worker.Wait(TimeSpan.FromSeconds(5)); } catch { }
        if (Runs > 0)
            Log.Write($"字幕: 認識 {Runs} 回、1 回 平均 {TotalMillis / Runs:F0} ms (音 平均 {TotalAudioSeconds / Runs:F1} 秒)");
    }
}
