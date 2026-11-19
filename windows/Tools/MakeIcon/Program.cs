// Windows 版のアイコン (.ico) を、Mac 版と同じ Icons/AppIcon.png から作る (SPEC.md 17 章 6: アイコンは共有する)
//   dotnet run --project windows/Tools/MakeIcon
// Mac のアイコンは周りに透明な余白 (1024 のうち 100) があり、Windows ではタスクバーで小さく見えるので、
// 角の丸い四角のまわりを少しだけ残して切り出す。大きさごとに PNG で入れる (Windows Vista 以降はすべての大きさで PNG を読める)。

using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

string root = FindRoot();
string input = Path.Combine(root, "Icons", "AppIcon.png");
string output = Path.Combine(root, "windows", "NoGreenBack", "Resources", "AppIcon.ico");
int[] sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256];

var source = new BitmapImage();
source.BeginInit();
source.UriSource = new Uri(input);
source.CacheOption = BitmapCacheOption.OnLoad;
source.EndInit();

// 1024 のうち、四角は 100〜924。まわりを 16 だけ残して 84〜940 を使う
var crop = new CroppedBitmap(source, new Int32Rect(84, 84, 856, 856));

var images = new List<byte[]>();
foreach (int size in sizes)
{
    var visual = new DrawingVisual();
    RenderOptions.SetBitmapScalingMode(visual, BitmapScalingMode.HighQuality);
    using (var dc = visual.RenderOpen()) dc.DrawImage(crop, new Rect(0, 0, size, size));
    var bmp = new RenderTargetBitmap(size, size, 96, 96, PixelFormats.Pbgra32);
    bmp.Render(visual);
    var encoder = new PngBitmapEncoder();
    encoder.Frames.Add(BitmapFrame.Create(bmp));
    using var ms = new MemoryStream();
    encoder.Save(ms);
    images.Add(ms.ToArray());
}

// ICO: ヘッダー (6 バイト) + 画像ごとの目録 (16 バイト) + 画像 (PNG)
using (var fs = File.Create(output))
using (var w = new BinaryWriter(fs))
{
    w.Write((ushort)0); w.Write((ushort)1); w.Write((ushort)sizes.Length);
    int offset = 6 + 16 * sizes.Length;
    for (int i = 0; i < sizes.Length; i++)
    {
        w.Write((byte)(sizes[i] >= 256 ? 0 : sizes[i]));   // 256 は 0 と書く
        w.Write((byte)(sizes[i] >= 256 ? 0 : sizes[i]));
        w.Write((byte)0); w.Write((byte)0);
        w.Write((ushort)1); w.Write((ushort)32);
        w.Write(images[i].Length);
        w.Write(offset);
        offset += images[i].Length;
    }
    foreach (var img in images) w.Write(img);
}
Console.WriteLine($"{output} ({string.Join(", ", sizes)} px, {new FileInfo(output).Length:N0} バイト)");

static string FindRoot()
{
    for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
        if (File.Exists(Path.Combine(dir.FullName, "Icons", "AppIcon.png"))) return dir.FullName;
    throw new FileNotFoundException("Icons/AppIcon.png が見つかりません");
}
