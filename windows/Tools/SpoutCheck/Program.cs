// Spout の受け取る側として、送っている映像を確かめる (SPEC.md 4 章)
// 送り手の一覧と情報を共有メモリから読み、共有テクスチャを開いて画素を読み、数字だけを出す (画像は保存しない)。
//   dotnet run --project windows/Tools/SpoutCheck [送り手の名前 (既定 NoGreenBack)]
// 出すもの: 大きさ、上半分と下半分で透明でない画素の割合 (人物なら下の方が多い = 上下の向きが合っている)、
//           上端と下端 (高さの 5%) の明るさの平均 (画面を背景にしたとき、実際の画面と比べて向きを確かめる)、
//           rgb が α を超える画素の割合 (プリマルチプライドなら 0)

using System.IO.MemoryMappedFiles;
using System.Text;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

string name = args.Length > 0 ? args[0] : "NoGreenBack";

static string ReadName(MemoryMappedViewAccessor v, long offset)
{
    var buf = new byte[256];
    v.ReadArray(offset, buf, 0, 256);
    int end = Array.IndexOf(buf, (byte)0);
    return Encoding.ASCII.GetString(buf, 0, end < 0 ? 256 : end);
}

try
{
    using var names = MemoryMappedFile.OpenExisting("SpoutSenderNames");
    using var nv = names.CreateViewAccessor();
    var list = new List<string>();
    for (long o = 0; o + 256 <= nv.Capacity; o += 256) { var n = ReadName(nv, o); if (n.Length == 0) break; list.Add(n); }
    Console.WriteLine($"送り手の一覧: {string.Join(", ", list)}");
    using var active = MemoryMappedFile.OpenExisting("ActiveSenderName");
    using var av = active.CreateViewAccessor(0, 256);
    Console.WriteLine($"選ばれている送り手: {ReadName(av, 0)}");
}
catch (FileNotFoundException) { Console.WriteLine("送り手の一覧がありません (Spout の送り手が動いていない)"); return 1; }

using var info = MemoryMappedFile.OpenExisting(name);
using var iv = info.CreateViewAccessor(0, 280);
uint handle = iv.ReadUInt32(0), w = iv.ReadUInt32(4), h = iv.ReadUInt32(8), format = iv.ReadUInt32(12);
Console.WriteLine($"{name}: ハンドル 0x{handle:X} 大きさ {w}x{h} 形式 {format} 説明 {ReadName(iv, 20)}");
if (handle == 0) { Console.WriteLine("ハンドルが 0 です"); return 1; }

D3D11.D3D11CreateDevice(null, DriverType.Hardware, DeviceCreationFlags.BgraSupport, [FeatureLevel.Level_11_0],
    out ID3D11Device device, out ID3D11DeviceContext context).CheckError();
using (device) using (context)
{
    using var shared = device.OpenSharedResource<ID3D11Texture2D>((IntPtr)handle);
    var desc = shared.Description;
    desc.Usage = ResourceUsage.Staging; desc.BindFlags = BindFlags.None; desc.CPUAccessFlags = CpuAccessFlags.Read; desc.MiscFlags = ResourceOptionFlags.None;
    using var staging = device.CreateTexture2D(desc);
    using (var access = new Mutex(false, name + "_SpoutAccessMutex"))
    {
        access.WaitOne(1000);
        context.CopyResource(staging, shared);
        context.Flush();
        access.ReleaseMutex();
    }
    var map = context.Map(staging, 0, MapMode.Read);
    long top = 0, bottom = 0, over = 0, total = 0;
    double topLuma = 0, bottomLuma = 0; long topN = 0, bottomN = 0;
    int strip = (int)(desc.Height * 0.05);
    unsafe
    {
        for (int y = 0; y < desc.Height; y += 4)
        {
            byte* row = (byte*)map.DataPointer + (long)y * map.RowPitch;
            for (int x = 0; x < desc.Width; x += 4)
            {
                byte b = row[x * 4], g = row[x * 4 + 1], r = row[x * 4 + 2], a = row[x * 4 + 3];
                total++;
                if (a > 8) { if (y < desc.Height / 2) top++; else bottom++; }
                if (r > a + 2 || g > a + 2 || b > a + 2) over++;
                double luma = 0.299 * r + 0.587 * g + 0.114 * b;
                if (y < strip) { topLuma += luma; topN++; }
                if (y >= desc.Height - strip) { bottomLuma += luma; bottomN++; }
            }
        }
    }
    context.Unmap(staging, 0);
    long half = Math.Max(1, total / 2);
    Console.WriteLine($"透明でない画素: 上半分 {100.0 * top / half:F1}% / 下半分 {100.0 * bottom / half:F1}%");
    Console.WriteLine($"明るさの平均: 上端 {topLuma / Math.Max(1, topN):F0} / 下端 {bottomLuma / Math.Max(1, bottomN):F0}");
    Console.WriteLine($"rgb が α を超える画素: {100.0 * over / Math.Max(1, total):F1}% (プリマルチプライドなら 0)");
}
return 0;
