// 人物の切り抜き (SPEC.md 3 章「処理の順番」)
// - 明るさ安定化 (1): カメラの画素を 64×36 点に間引いて CPU で平均の明るさを求め、RGB に掛ける倍率を出す
// - 人物マスク (2): ONNX Runtime でモデルを動かす (DirectML。使えなければ CPU)
// - マスクの後処理 (3〜6): ちらつき抑制・消失の保持・境界の締まり・境界ぼかしを、マスクの解像度の上で CPU で行う
// どれも取り込みのスレッドから、Pipeline の lock の中で呼ぶ。

using System.IO;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace NoGreenBack.Video;

/// 切り抜きのモデルと、入力の大きさ・前処理 (SPEC.md 17 章 2)
public sealed record ModelSpec(string Name, string File, int Height, int Width, bool CenteredInput)
{
    /// 品質 (Fast / Balanced / Accurate) ごとのモデル
    public static IReadOnlyList<ModelSpec> ByQuality { get; } =
    [
        new("MediaPipe 256x144", "mediapipe_selfie_landscape.onnx", 144, 256, CenteredInput: false),
        new("MODNet 512x288", "modnet.onnx", 288, 512, CenteredInput: true),
        new("MODNet 672x384", "modnet.onnx", 384, 672, CenteredInput: true),
    ];

    public override string ToString() => Name;

    /// モデルのフォルダ: アプリの隣の models か、開発中は上にたどった windows/models
    public static string? FindModelsDir()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "models");
            if (ByQuality.All(m => System.IO.File.Exists(Path.Combine(candidate, m.File)))) return candidate;
        }
        return null;
    }
}

/// 1 つのモデルを動かす
public sealed class Segmenter : IDisposable
{
    public ModelSpec Spec { get; }
    public string Provider { get; }

    readonly InferenceSession session;
    readonly string inputName;
    readonly DenseTensor<float> input;
    readonly float[] mask;

    Segmenter(ModelSpec spec, InferenceSession session, string provider)
    {
        Spec = spec;
        this.session = session;
        Provider = provider;
        inputName = session.InputMetadata.Keys.First();
        input = new DenseTensor<float>([1, 3, spec.Height, spec.Width]);
        mask = new float[spec.Width * spec.Height];
    }

    /// DirectML で開けなかったら、以後は CPU で動かす
    static volatile bool directMLFailed;

    /// 品質に合わせてモデルを読み込む (1 秒ほどかかるので、取り込みのスレッドの外で呼ぶ)。
    /// GPU (DirectML) が使えない PC では、どの品質でも Fast を CPU で動かす (CPU で 30 fps に間に合うのは Fast だけ)
    public static Segmenter Load(int quality, string modelsDir)
    {
        var spec = ByQualityClamped(quality);
        if (!directMLFailed)
        {
            try
            {
                var options = new SessionOptions
                {
                    GraphOptimizationLevel = GraphOptimizationLevel.ORT_ENABLE_ALL,
                    EnableMemoryPattern = false,   // DirectML では使えない
                    ExecutionMode = ExecutionMode.ORT_SEQUENTIAL,
                    LogSeverityLevel = OrtLoggingLevel.ORT_LOGGING_LEVEL_ERROR,
                };
                options.AppendExecutionProvider_DML(0);
                return new Segmenter(spec, new InferenceSession(Path.Combine(modelsDir, spec.File), options), "DirectML");
            }
            catch (Exception e)
            {
                directMLFailed = true;
                Log.Write($"DirectML が使えないので、品質によらず Fast を CPU で動かします: {e.Message}");
            }
        }
        spec = ModelSpec.ByQuality[0];
        var cpu = new SessionOptions
        {
            GraphOptimizationLevel = GraphOptimizationLevel.ORT_ENABLE_ALL,
            IntraOpNumThreads = Math.Clamp(Environment.ProcessorCount / 2, 1, 8),
            LogSeverityLevel = OrtLoggingLevel.ORT_LOGGING_LEVEL_ERROR,
        };
        return new Segmenter(spec, new InferenceSession(Path.Combine(modelsDir, spec.File), cpu), "CPU");
    }

    static ModelSpec ByQualityClamped(int quality) =>
        ModelSpec.ByQuality[Math.Clamp(quality, 0, ModelSpec.ByQuality.Count - 1)];

    /// BGRA のコマから人物マスク (0〜1、Width×Height) を作る。gain は明るさ安定化の倍率
    public float[] Run(byte[] bgra, int srcW, int srcH, float gain)
    {
        Preprocess(bgra, srcW, srcH, gain);
        using var results = session.Run([NamedOnnxValue.CreateFromTensor(inputName, input)]);
        var buf = ((DenseTensor<float>)results.First().AsTensor<float>()).Buffer.Span;
        for (int i = 0; i < mask.Length; i++) mask[i] = Math.Clamp(buf[i], 0f, 1f);
        return mask;
    }

    /// 縮小 (区画の平均) して、RGB の NCHW にする。CenteredInput なら -1〜1、そうでなければ 0〜1
    void Preprocess(byte[] bgra, int srcW, int srcH, float gain)
    {
        int w = Spec.Width, h = Spec.Height, plane = w * h;
        var data = input.Buffer;
        float scale = gain / 255f;
        bool centered = Spec.CenteredInput;
        Parallel.For(0, h, y =>
        {
            var span = data.Span;
            int y0 = y * srcH / h, y1 = Math.Max(y0 + 1, (y + 1) * srcH / h);
            int stepY = Math.Max(1, (y1 - y0) / 4);   // 区画の中は最大 4×4 点だけ見る (速さのため)
            for (int x = 0; x < w; x++)
            {
                int x0 = x * srcW / w, x1 = Math.Max(x0 + 1, (x + 1) * srcW / w);
                int stepX = Math.Max(1, (x1 - x0) / 4);
                float r = 0, g = 0, b = 0; int count = 0;
                for (int sy = y0; sy < y1; sy += stepY)
                {
                    int row = sy * srcW * 4;
                    for (int sx = x0; sx < x1; sx += stepX)
                    {
                        int p = row + sx * 4;
                        b += bgra[p]; g += bgra[p + 1]; r += bgra[p + 2]; count++;
                    }
                }
                float k = scale / count;
                float rv = Math.Min(r * k, 1f), gv = Math.Min(g * k, 1f), bv = Math.Min(b * k, 1f);
                if (centered) { rv = rv * 2 - 1; gv = gv * 2 - 1; bv = bv * 2 - 1; }
                int i = y * w + x;
                span[i] = rv; span[plane + i] = gv; span[2 * plane + i] = bv;
            }
        });
    }

    public void Dispose() => session.Dispose();
}

/// 明るさ安定化 (照明のフリッカーによる画面全体の明滅をならす)
public sealed class BrightnessStabilizer
{
    double reference = -1;

    public void Reset() => reference = -1;

    /// RGB に掛ける倍率。strength は 0〜1
    public float Gain(byte[] bgra, int w, int h, double strength)
    {
        // 64×36 点に間引いて、リニアにした明るさの平均を求める
        double sum = 0;
        for (int j = 0; j < 36; j++)
        {
            int row = (int)((j + 0.5) * h / 36) * w * 4;
            for (int i = 0; i < 64; i++)
            {
                int p = row + (int)((i + 0.5) * w / 64) * 4;
                sum += 0.114 * Lin(bgra[p]) + 0.587 * Lin(bgra[p + 1]) + 0.299 * Lin(bgra[p + 2]);
            }
        }
        double luma = sum / (64 * 36);
        if (luma < 1e-4) return 1;
        reference = reference < 0 ? luma : reference * 0.9 + luma * 0.1;   // 約 10 コマで追従
        if (strength <= 0) return 1;
        double gain = Math.Clamp(reference / luma, 0.8, 1.25);
        return (float)(1 + (gain - 1) * strength);
    }

    static readonly double[] linear = Enumerable.Range(0, 256).Select(v => Math.Pow(v / 255.0, 2.2)).ToArray();
    static double Lin(byte v) => linear[v];
}

/// マスクの後処理 (ちらつき抑制・消失の保持・境界の締まり・境界ぼかし)
public sealed class MaskProcessor
{
    float[]? prev;
    float[] work = [], temp = [];
    byte[] bytes = [];

    /// 品質やモデルを変えたら、マスクの履歴を捨てる
    public void Reset() => prev = null;

    public byte[] Process(float[] cur, int w, int h, AppState s)
    {
        int n = w * h;
        if (work.Length != n) { work = new float[n]; temp = new float[n]; bytes = new byte[n]; prev = null; }

        // 3. ちらつき抑制: 動いた画素はすぐ追従し、止まっている画素ほど前のマスクを残す
        // 4. 消失の保持: 減る方向だけ 1 コマあたり d までに抑える
        float smooth = (float)s.FlickerReduction;
        float d = (float)Math.Pow(0.02, s.DropoutHold);
        if (prev == null)
        {
            Array.Copy(cur, work, n);
            prev = new float[n];
        }
        else
        {
            float baseW = 1 - smooth * 0.92f;
            for (int i = 0; i < n; i++)
            {
                float p = prev[i], c = cur[i];
                float wgt = Math.Clamp(baseW + Math.Abs(c - p) * 5, 0, 1);
                float o = p + (c - p) * wgt;
                work[i] = Math.Max(o, p - d);
            }
        }
        Array.Copy(work, prev, n);   // 3 と 4 の結果を次のコマの prev にする

        // 5. 境界の締まり: 0.5 を中心にコントラストを上げる
        float g = 1 + (float)s.EdgeTightness * 3;
        float off = 0.5f * (1 - g);
        for (int i = 0; i < n; i++) work[i] = Math.Clamp(work[i] * g + off, 0, 1);

        // 6. 境界ぼかし: マスクの解像度の上でガウスぼかし (端は引き延ばす)
        if (s.EdgeBlur > 0.05) GaussianBlur(work, temp, w, h, (float)s.EdgeBlur);

        for (int i = 0; i < n; i++) bytes[i] = (byte)(work[i] * 255 + 0.5f);
        return bytes;
    }

    static void GaussianBlur(float[] data, float[] temp, int w, int h, float sigma)
    {
        int r = (int)Math.Ceiling(sigma * 3);
        var k = new float[r * 2 + 1];
        float sum = 0;
        for (int i = -r; i <= r; i++) sum += k[i + r] = MathF.Exp(-i * i / (2 * sigma * sigma));
        for (int i = 0; i < k.Length; i++) k[i] /= sum;

        Parallel.For(0, h, y =>
        {
            int row = y * w;
            for (int x = 0; x < w; x++)
            {
                float acc = 0;
                for (int i = -r; i <= r; i++) acc += data[row + Math.Clamp(x + i, 0, w - 1)] * k[i + r];
                temp[row + x] = acc;
            }
        });
        Parallel.For(0, h, y =>
        {
            for (int x = 0; x < w; x++)
            {
                float acc = 0;
                for (int i = -r; i <= r; i++) acc += temp[Math.Clamp(y + i, 0, h - 1) * w + x] * k[i + r];
                data[y * w + x] = acc;
            }
        });
    }
}
