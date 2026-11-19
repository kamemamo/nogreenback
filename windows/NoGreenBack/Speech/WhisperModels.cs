// 字幕の認識に使う Whisper のモデル (SPEC.md 17 章 3)
// モデルは同梱せず、初めて字幕をオンにしたときに Hugging Face (ggerganov/whisper.cpp) から取ってくる。
// 版を固定するため URL にはリポジトリのコミットを入れ、大きさと SHA-256 を確かめる。置き場所は %LOCALAPPDATA%\NoGreenBack\models。
// GPU (Vulkan) が使える PC では大きいモデル、使えない PC では小さいモデルを使う。

using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace NoGreenBack.Speech;

public sealed record WhisperModel(string Name, string File, long Size, string Sha256)
{
    const string Commit = "5359861c739e955e79d9a303bcbc70fb988958b1";
    public string Url => $"https://huggingface.co/ggerganov/whisper.cpp/resolve/{Commit}/{File}";
    public string LocalPath => Path.Combine(WhisperModels.Folder, File);
    public bool IsDownloaded => System.IO.File.Exists(LocalPath) && new FileInfo(LocalPath).Length == Size;
    public double Megabytes => Size / 1_000_000.0;
}

public static class WhisperModels
{
    /// GPU (Vulkan) が使えるとき
    public static readonly WhisperModel Gpu = new("large-v3-turbo (q5_0)", "ggml-large-v3-turbo-q5_0.bin", 574_041_195,
        "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2");

    /// GPU が使えないとき
    public static readonly WhisperModel Cpu = new("small (q5_1)", "ggml-small-q5_1.bin", 190_085_487,
        "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb");

    public static string Folder { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NoGreenBack", "models");

    /// Vulkan が使えるか (vulkan-1.dll を読み込めるか)。使えれば Whisper の GPU 版で動かす
    public static bool VulkanAvailable { get; } = CheckVulkan();

    static bool CheckVulkan()
    {
        if (!NativeLibrary.TryLoad("vulkan-1.dll", out var h)) return false;
        NativeLibrary.Free(h);
        return true;
    }

    /// この PC で使うモデル
    public static WhisperModel ForThisPC => VulkanAvailable ? Gpu : Cpu;

    /// 取ってくる (一時ファイルに書いて、大きさと SHA-256 を確かめてから置き換える)。progress は 0〜1
    public static async Task DownloadAsync(WhisperModel model, IProgress<double>? progress, CancellationToken ct)
    {
        Directory.CreateDirectory(Folder);
        string part = model.LocalPath + ".part";
        using (var http = new HttpClient { Timeout = TimeSpan.FromHours(2) })
        {
            http.DefaultRequestHeaders.UserAgent.ParseAdd("NoGreenBack");
            using var res = await http.GetAsync(model.Url, HttpCompletionOption.ResponseHeadersRead, ct);
            res.EnsureSuccessStatusCode();
            await using var src = await res.Content.ReadAsStreamAsync(ct);
            await using var dst = new FileStream(part, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20, useAsync: true);
            var buf = new byte[1 << 20];
            long done = 0;
            int n;
            while ((n = await src.ReadAsync(buf, ct)) > 0)
            {
                await dst.WriteAsync(buf.AsMemory(0, n), ct);
                done += n;
                progress?.Report((double)done / model.Size);
            }
        }
        var info = new FileInfo(part);
        if (info.Length != model.Size) { info.Delete(); throw new IOException($"大きさが違います ({info.Length} / {model.Size})"); }
        string hash;
        await using (var fs = File.OpenRead(part)) hash = Convert.ToHexStringLower(await SHA256.HashDataAsync(fs, ct));
        if (hash != model.Sha256) { File.Delete(part); throw new IOException("SHA-256 が違います"); }
        File.Move(part, model.LocalPath, overwrite: true);
    }
}
