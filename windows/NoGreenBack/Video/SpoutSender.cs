// Spout での送出 (SPEC.md 4 章「Spout（Mac では Syphon）に送る映像」)
// Spout2 (2.007) の送り手の決まりに合わせて、C# だけで送る (SDK の C++ を挟まない。SPEC.md 17 章)。
// - 共有メモリ "SpoutSenderNames" (256 バイトの名前の枠 × 最大の数) に名前を足す。ロックは "SpoutSenderNames_mutex"
// - 共有メモリ "ActiveSenderName" (256 バイト) に、新しく足したときに名前を書く
// - 送り手の名前の共有メモリ (280 バイト): 共有ハンドル (下位 32 ビット)・幅・高さ・形式 (87 = B8G8R8A8_UNORM)・用途 (0)・説明 (exe のパス)・相手の ID (0)
// - 共有テクスチャは D3D11_RESOURCE_MISC_SHARED (従来の共有ハンドル)。描き込む間は "<名前>_SpoutAccessMutex" を取り、描いたら Flush する
// - レジストリで有効なら、"<名前>_Count_Semaphore" でコマを数える
// - 大きさが変わったらテクスチャを作り直して情報を書き換える。終了するときは名前を一覧から外す
// ここで使うものは、すべて Pipeline の lock の中から呼ぶ。

using System.IO;
using System.IO.MemoryMappedFiles;
using System.Text;
using Microsoft.Win32;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace NoGreenBack.Video;

public sealed class SpoutSender : IDisposable
{
    const int NameLength = 256, InfoSize = 280, FormatBgra = 87;
    const string NamesMap = "SpoutSenderNames", ActiveMap = "ActiveSenderName";

    readonly Gpu gpu;
    readonly string name;
    readonly int maxSenders;
    readonly MemoryMappedFile namesMap;
    readonly MemoryMappedFile activeMap;
    readonly MemoryMappedFile infoMap;
    readonly Mutex namesMutex, activeMutex, infoMutex, accessMutex;
    readonly Semaphore? frameCount;

    ID3D11Texture2D? texture;
    ID3D11RenderTargetView? rtv;
    int width, height;

    public SpoutSender(Gpu gpu, string name)
    {
        this.gpu = gpu;
        this.name = name;
        maxSenders = ReadSpoutSetting("MaxSenders") is int m and > 0 ? m : 64;
        namesMap = MemoryMappedFile.CreateOrOpen(NamesMap, maxSenders * NameLength);
        activeMap = MemoryMappedFile.CreateOrOpen(ActiveMap, NameLength);
        infoMap = MemoryMappedFile.CreateOrOpen(name, InfoSize);
        namesMutex = new Mutex(false, NamesMap + "_mutex");
        activeMutex = new Mutex(false, ActiveMap + "_mutex");
        infoMutex = new Mutex(false, name + "_mutex");
        accessMutex = new Mutex(false, name + "_SpoutAccessMutex");
        if (ReadSpoutSetting("Framecount") == 1) frameCount = new Semaphore(1, int.MaxValue, name + "_Count_Semaphore");

        // 一覧に名前を足す (新しく足したら、いま選ばれている送り手にもする)
        bool added = false;
        WithLock(namesMutex, () =>
        {
            var names = ReadNames();
            if (names.Contains(name)) return;
            if (names.Count >= maxSenders) { Log.Write("Spout: 送り手の数が上限に達しています"); return; }
            names.Add(name);
            WriteNames(names);
            added = true;
        });
        if (added) WithLock(activeMutex, () => WriteName(activeMap, 0, name));
        Log.Write($"Spout: 送り手 \"{name}\" を登録しました");
    }

    /// source (width × height) を共有テクスチャに写して送る。flip なら上下反転、straightAlpha ならストレートα
    public void Send(ID3D11ShaderResourceView source, int w, int h, bool flip, bool straightAlpha)
    {
        if (w <= 0 || h <= 0) return;
        if (texture == null || w != width || h != height) CreateTexture(w, h);
        // 受け取る側が読んでいる間は書かない (待ちきれなければ、このコマは送らない)
        bool locked;
        try { locked = accessMutex.WaitOne(67); }
        catch (AbandonedMutexException) { locked = true; }
        if (!locked) return;
        try
        {
            gpu.CopyForSpout(rtv!, w, h, source, flip, straightAlpha);
            gpu.Context.Flush();
        }
        finally { accessMutex.ReleaseMutex(); }
        if (frameCount != null)
        {
            // 受け取る側は数の増え方で新しいコマを知る (差し引き 1 増やす)
            frameCount.WaitOne(0);
            frameCount.Release(2);
        }
    }

    void CreateTexture(int w, int h)
    {
        rtv?.Dispose(); texture?.Dispose();
        gpu.Context.Flush();
        texture = gpu.Device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)w, Height = (uint)h, MipLevels = 1, ArraySize = 1,
            Format = Format.B8G8R8A8_UNorm, SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default, BindFlags = BindFlags.RenderTarget | BindFlags.ShaderResource,
            MiscFlags = ResourceOptionFlags.Shared,
        });
        rtv = gpu.Device.CreateRenderTargetView(texture);
        gpu.Context.Flush();
        width = w; height = h;

        IntPtr handle;
        using (var res = texture.QueryInterface<IDXGIResource>()) handle = res.SharedHandle;
        WithLock(infoMutex, () =>
        {
            using var view = infoMap.CreateViewAccessor(0, InfoSize);
            view.Write(0, (uint)(handle.ToInt64() & 0xFFFFFFFF));
            view.Write(4, (uint)w);
            view.Write(8, (uint)h);
            view.Write(12, (uint)FormatBgra);
            view.Write(16, 0u);
            var desc = new byte[256];
            Encoding.ASCII.GetBytes(Environment.ProcessPath ?? "NoGreenBack", 0, Math.Min(255, (Environment.ProcessPath ?? "NoGreenBack").Length), desc, 0);
            view.WriteArray(20, desc, 0, desc.Length);
            view.Write(276, 0u);
        });
        Log.Write($"Spout: {w}x{h}");
    }

    List<string> ReadNames()
    {
        var list = new List<string>();
        using var view = namesMap.CreateViewAccessor(0, maxSenders * NameLength);
        for (int i = 0; i < maxSenders; i++)
        {
            string n = ReadName(view, i * NameLength);
            if (n.Length == 0) break;
            list.Add(n);
        }
        return list;
    }

    void WriteNames(List<string> names)
    {
        using var view = namesMap.CreateViewAccessor(0, maxSenders * NameLength);
        for (int i = 0; i < maxSenders; i++) WriteName(view, i * NameLength, i < names.Count ? names[i] : "");
    }

    static string ReadName(MemoryMappedViewAccessor view, long offset)
    {
        var buf = new byte[NameLength];
        view.ReadArray(offset, buf, 0, NameLength);
        int end = Array.IndexOf(buf, (byte)0);
        return Encoding.ASCII.GetString(buf, 0, end < 0 ? NameLength : end);
    }

    static void WriteName(MemoryMappedViewAccessor view, long offset, string value)
    {
        var buf = new byte[NameLength];
        Encoding.ASCII.GetBytes(value, 0, Math.Min(value.Length, NameLength - 1), buf, 0);
        view.WriteArray(offset, buf, 0, NameLength);
    }

    static void WriteName(MemoryMappedFile map, long offset, string value)
    {
        using var view = map.CreateViewAccessor(0, NameLength);
        WriteName(view, offset, value);
    }

    static void WithLock(Mutex m, Action action)
    {
        bool locked;
        try { locked = m.WaitOne(67); }
        catch (AbandonedMutexException) { locked = true; }
        try { action(); }
        finally { if (locked) m.ReleaseMutex(); }
    }

    static int? ReadSpoutSetting(string key)
    {
        try { return Registry.CurrentUser.OpenSubKey(@"Software\Leading Edge\Spout")?.GetValue(key) as int?; }
        catch { return null; }
    }

    /// 名前を一覧から外し、いま選ばれている送り手だったら残った最初の送り手にする
    public void Dispose()
    {
        try
        {
            string? first = null;
            WithLock(namesMutex, () =>
            {
                var names = ReadNames();
                names.Remove(name);
                WriteNames(names);
                first = names.FirstOrDefault();
            });
            WithLock(activeMutex, () =>
            {
                using var view = activeMap.CreateViewAccessor(0, NameLength);
                if (ReadName(view, 0) == name) WriteName(view, 0, first ?? "");
            });
            WithLock(infoMutex, () =>
            {
                using var view = infoMap.CreateViewAccessor(0, InfoSize);
                view.Write(0, 0u);   // 受け取る側が古いハンドルを開かないように
            });
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        rtv?.Dispose(); texture?.Dispose();
        frameCount?.Dispose();
        accessMutex.Dispose(); infoMutex.Dispose(); activeMutex.Dispose(); namesMutex.Dispose();
        infoMap.Dispose(); activeMap.Dispose(); namesMap.Dispose();
    }
}
