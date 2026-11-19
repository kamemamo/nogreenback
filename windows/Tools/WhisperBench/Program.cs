// 字幕の認識 (Whisper) の速さを比べる (SPEC.md 17 章 3)
// Windows の音声合成で日本語と英語の文を読み上げた音を作り、モデルごとに 1 回の認識にかかる時間を測る。
//   dotnet run -c Release --project windows/Tools/WhisperBench -- vulkan     (GPU)
//   dotnet run -c Release --project windows/Tools/WhisperBench -- cpu
// モデルがなければ、アプリと同じ方法で %LOCALAPPDATA%\NoGreenBack\models に取ってくる。
// 読み込んだ実行環境 (Vulkan / CPU) は 1 つのプロセスで切り替えられないので、GPU と CPU は別々に実行する。

using System.Diagnostics;
using NoGreenBack.Speech;
using Whisper.net;
using Whisper.net.LibraryLoader;
using Windows.Media.SpeechSynthesis;

Console.OutputEncoding = System.Text.Encoding.UTF8;
bool cpu = args.Contains("cpu");
RuntimeOptions.RuntimeLibraryOrder = cpu ? [RuntimeLibrary.Cpu] : [RuntimeLibrary.Vulkan, RuntimeLibrary.Cpu];

foreach (var m in new[] { WhisperModels.Gpu, WhisperModels.Cpu })
{
    if (m.IsDownloaded) continue;
    Console.Write($"取ってくる: {m.File} ({m.Megabytes:F0} MB) ");
    int last = -1;
    await WhisperModels.DownloadAsync(m, new Progress<double>(p => { int pc = (int)(p * 10); if (pc != last) { last = pc; Console.Write($"{pc * 10}% "); } }), CancellationToken.None);
    Console.WriteLine("済 (大きさと SHA-256 を確かめました)");
}

var clips = new (string Lang, string Text)[]
{
    ("ja", "今日は画面の録画と字幕の機能を説明します。手書きのボタンを押してから、コントロールキーを押しながらドラッグすると線を描けます。"),
    ("ja", "ホワイトボードをオンにすると、半透明の白い板が出ます。"),
    ("en", "Today I will explain the recording and subtitle features. Hold the control key and drag to draw on the screen."),
};
var audio = new List<(string Lang, string Text, float[] Samples)>();
foreach (var (lang, text) in clips) audio.Add((lang, text, await Synthesize(text, lang)));

foreach (var m in new[] { WhisperModels.Gpu, WhisperModels.Cpu })
{
    var sw = Stopwatch.StartNew();
    using var factory = WhisperFactory.FromPath(m.LocalPath);
    Console.WriteLine($"\n== {m.Name}  実行環境 {RuntimeOptions.LoadedLibrary}  読み込み {sw.ElapsedMilliseconds} ms");
    foreach (var (lang, text, samples) in audio)
    {
        using var p = factory.CreateBuilder().WithLanguage(lang).WithNoContext().WithSingleSegment().WithTemperature(0)
            .WithThreads(Math.Clamp(Environment.ProcessorCount / 2, 2, 8)).Build();
        string result = await Run(p, samples);   // 1 回目は準備を含むので数えない
        var times = new List<double>();
        for (int i = 0; i < 3; i++) { sw.Restart(); result = await Run(p, samples); times.Add(sw.Elapsed.TotalMilliseconds); }
        Console.WriteLine($"  {lang} 音 {samples.Length / 16000.0:F1} 秒: 1 回 {times.Average():F0} ms (最小 {times.Min():F0})");
        Console.WriteLine($"    → {result.Trim()}");
    }
}

static async Task<string> Run(WhisperProcessor p, float[] samples)
{
    var sb = new System.Text.StringBuilder();
    await foreach (var s in p.ProcessAsync(samples)) sb.Append(s.Text);
    return sb.ToString();
}

/// Windows の音声合成で読み上げ、16 kHz モノラルの音にする
static async Task<float[]> Synthesize(string text, string lang)
{
    using var synth = new SpeechSynthesizer();
    var voice = SpeechSynthesizer.AllVoices.FirstOrDefault(v => v.Language.StartsWith(lang)) ?? SpeechSynthesizer.DefaultVoice;
    synth.Voice = voice;
    using var stream = await synth.SynthesizeTextToStreamAsync(text);
    var bytes = new byte[stream.Size];
    using (var reader = new Windows.Storage.Streams.DataReader(stream.GetInputStreamAt(0)))
    {
        await reader.LoadAsync((uint)stream.Size);
        reader.ReadBytes(bytes);
    }
    // WAV (16 bit PCM) を読む
    int pos = 12, rate = 16000, channels = 1, dataPos = -1, dataLen = 0;
    while (pos + 8 <= bytes.Length)
    {
        string id = System.Text.Encoding.ASCII.GetString(bytes, pos, 4);
        int len = BitConverter.ToInt32(bytes, pos + 4);
        if (id == "fmt ") { channels = BitConverter.ToInt16(bytes, pos + 10); rate = BitConverter.ToInt32(bytes, pos + 12); }
        if (id == "data") { dataPos = pos + 8; dataLen = Math.Min(len, bytes.Length - dataPos); break; }
        pos += 8 + len;
    }
    int frames = dataLen / 2 / channels;
    var mono = new float[frames];
    for (int i = 0; i < frames; i++) mono[i] = BitConverter.ToInt16(bytes, dataPos + i * 2 * channels) / 32768f;
    // 16 kHz に (線形補間)
    int outN = (int)((long)frames * 16000 / rate);
    var r = new float[outN];
    for (int i = 0; i < outN; i++)
    {
        double x = (double)i * rate / 16000; int k = (int)x; double f = x - k;
        r[i] = (float)(mono[Math.Min(k, frames - 1)] * (1 - f) + mono[Math.Min(k + 1, frames - 1)] * f);
    }
    Console.WriteLine($"読み上げ ({voice.DisplayName}): {outN / 16000.0:F1} 秒");
    return r;
}
