// 人物の切り抜きのモデルの速さを比べる (SPEC.md 17 章 2)
// windows/models/ のモデルを、DirectML (GPU) と CPU で動かし、1 回の推論にかかる時間を測る。
//   dotnet run -c Release --project windows/Tools/SegBench
// 映像の中身で速さは変わらないので、入力は乱数で埋める。

using System.Diagnostics;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

string modelsDir = args.Length > 0 ? args[0] : FindModelsDir();

// (表示名, ファイル, 入力の高さ, 幅)。品質 Fast / Balanced / Accurate に使うもの
var cases = new (string Name, string File, int H, int W)[]
{
    ("MediaPipe landscape", "mediapipe_selfie_landscape.onnx", 144, 256),
    ("MODNet 288x512", "modnet.onnx", 288, 512),
    ("MODNet 384x672", "modnet.onnx", 384, 672),
};

const int Warmup = 10, Runs = 100;
Console.WriteLine($"モデル: {modelsDir}");
Console.WriteLine($"1 回の推論 (中央値 / 95% 点、{Runs} 回)。初回の読み込みと準備の時間は別\n");
Console.WriteLine($"{"モデル",-22} {"実行",-9} {"中央値",8} {"95%",8} {"準備",8}");

bool printedInfo = false;
foreach (var c in cases)
{
    var path = Path.Combine(modelsDir, c.File);
    if (!File.Exists(path)) { Console.WriteLine($"{c.Name,-22} (ファイルがありません)"); continue; }
    foreach (var ep in new[] { "DirectML", "CPU" })
    {
        try
        {
            var sw = Stopwatch.StartNew();
            using var options = new SessionOptions { GraphOptimizationLevel = GraphOptimizationLevel.ORT_ENABLE_ALL };
            if (ep == "DirectML")
            {
                options.EnableMemoryPattern = false;   // DirectML では使えない
                options.ExecutionMode = ExecutionMode.ORT_SEQUENTIAL;
                options.AppendExecutionProvider_DML(0);
            }
            else options.IntraOpNumThreads = Math.Min(8, Environment.ProcessorCount);
            using var session = new InferenceSession(path, options);

            var input = session.InputMetadata.First();
            if (!printedInfo || c.Name.StartsWith("MediaPipe") || c.Name == "MODNet 288x512")
            {
                if (ep == "DirectML")
                    Console.WriteLine($"  [{c.File}] 入力 {input.Key} {input.Value.ElementType.Name} [{string.Join(",", input.Value.Dimensions)}]"
                        + $" / 出力 {string.Join(", ", session.OutputMetadata.Select(o => $"{o.Key} [{string.Join(",", o.Value.Dimensions)}]"))}");
                printedInfo = true;
            }

            var dims = ShapeFor(input.Value.Dimensions, c.H, c.W);
            var value = MakeInput(input.Value.ElementType, dims);
            var feeds = new List<NamedOnnxValue> { value(input.Key) };

            for (int i = 0; i < Warmup; i++) using (session.Run(feeds)) { }
            double setup = sw.Elapsed.TotalMilliseconds;

            var times = new double[Runs];
            for (int i = 0; i < Runs; i++)
            {
                sw.Restart();
                using (session.Run(feeds)) { }
                times[i] = sw.Elapsed.TotalMilliseconds;
            }
            Array.Sort(times);
            Console.WriteLine($"{c.Name,-22} {ep,-9} {times[Runs / 2],6:F1}ms {times[Runs * 95 / 100],6:F1}ms {setup,6:F0}ms");
        }
        catch (Exception e)
        {
            Console.WriteLine($"{c.Name,-22} {ep,-9} 失敗: {e.Message.Split('\n')[0]}");
        }
    }
}

// 入力の形を決める。NCHW (3 が 2 番目) か NHWC (3 が最後) かをモデルから読み取り、高さと幅を入れる
static int[] ShapeFor(int[] dims, int h, int w)
{
    var d = dims.Select(x => x).ToArray();
    d[0] = 1;
    if (d.Length == 4 && (d[1] == 3 || d[3] != 3)) { d[1] = 3; d[2] = h; d[3] = w; }   // NCHW
    else if (d.Length == 4) { d[1] = h; d[2] = w; d[3] = 3; }                          // NHWC
    return d;
}

static Func<string, NamedOnnxValue> MakeInput(Type type, int[] dims)
{
    var rnd = new Random(1);
    int n = dims.Aggregate(1, (a, b) => a * b);
    if (type == typeof(Float16))
    {
        var t = new DenseTensor<Float16>(dims);
        for (int i = 0; i < n; i++) t.SetValue(i, (Float16)(float)rnd.NextDouble());
        return name => NamedOnnxValue.CreateFromTensor(name, t);
    }
    var f = new DenseTensor<float>(dims);
    for (int i = 0; i < n; i++) f.SetValue(i, (float)rnd.NextDouble());
    return name => NamedOnnxValue.CreateFromTensor(name, f);
}

static string FindModelsDir()
{
    for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
    {
        var candidate = Path.Combine(dir.FullName, "models");
        if (Directory.Exists(candidate) && Directory.GetFiles(candidate, "*.onnx").Length > 0) return candidate;
    }
    throw new DirectoryNotFoundException("windows/models が見つかりません");
}
