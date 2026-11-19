// 録画した MP4 に字幕トラック (3GPP 字幕 / tx3g) を足す (SPEC.md 10 章「録画したときの字幕」)。再生するときにオン・オフできる。
// 映像と音声のデータの位置を変えないよう、元の moov は同じ大きさの free に名前を変えて残し、
// 末尾に字幕の文字 (mdat) と、字幕のトラックを足した新しい moov を書く。
// 字幕のない時間は、空のサンプルで埋める (Mac 版の SubtitleTrack と同じ)。

using System.Buffers.Binary;
using System.IO;
using System.Text;

namespace NoGreenBack.Speech;

public static class Mp4SubtitleTrack
{
    /// path の MP4 に字幕トラックを足す。language は ISO 639-2 の 3 文字 (jpn / eng)
    public static void Append(string path, IReadOnlyList<SubtitleCue> cues, string language)
    {
        using var fs = new FileStream(path, FileMode.Open, FileAccess.ReadWrite);
        // いちばん上の箱から moov を探す
        long moovPos = -1, moovSize = 0, pos = 0;
        while (pos + 8 <= fs.Length)
        {
            var head = ReadAt(fs, pos, 16);
            long size = BinaryPrimitives.ReadUInt32BigEndian(head);
            string type = Encoding.ASCII.GetString(head, 4, 4);
            if (size == 1) size = (long)BinaryPrimitives.ReadUInt64BigEndian(head.AsSpan(8));
            else if (size == 0) size = fs.Length - pos;
            if (size < 8) throw new InvalidDataException("MP4 の箱の大きさが不正です");
            if (type == "moov") { moovPos = pos; moovSize = size; }
            pos += size;
        }
        if (moovPos < 0) throw new InvalidDataException("moov がありません");
        if (moovSize > int.MaxValue) throw new InvalidDataException("moov が大きすぎます");
        var moov = ReadAt(fs, moovPos, (int)moovSize);

        // 動画の長さと時間の単位 (mvhd)、次のトラックの番号
        int mvhd = FindChild(moov, 8, moov.Length, "mvhd");
        if (mvhd < 0) throw new InvalidDataException("mvhd がありません");
        int ver = moov[mvhd + 8];
        uint timescale; ulong duration; int nextIdPos;
        if (ver == 1)
        {
            timescale = BinaryPrimitives.ReadUInt32BigEndian(moov.AsSpan(mvhd + 8 + 4 + 16));
            duration = BinaryPrimitives.ReadUInt64BigEndian(moov.AsSpan(mvhd + 8 + 4 + 20));
            nextIdPos = mvhd + 8 + 4 + 28 + 76;   // rate 4, volume 2, reserved 10, matrix 36, pre_defined 24
        }
        else
        {
            timescale = BinaryPrimitives.ReadUInt32BigEndian(moov.AsSpan(mvhd + 8 + 4 + 8));
            duration = BinaryPrimitives.ReadUInt32BigEndian(moov.AsSpan(mvhd + 8 + 4 + 12));
            nextIdPos = mvhd + 8 + 4 + 16 + 76;
        }
        uint trackId = BinaryPrimitives.ReadUInt32BigEndian(moov.AsSpan(nextIdPos));
        if (trackId == 0 || trackId == uint.MaxValue) trackId = 100;
        double movieSeconds = timescale > 0 ? (double)duration / timescale : 0;

        // 字幕のサンプル (ミリ秒): 字幕のない時間は空のサンプルで埋める
        var samples = new List<(string Text, long Duration)>();
        long t = 0, end = (long)Math.Round(movieSeconds * 1000);
        foreach (var c in SubtitleText.Split(cues).OrderBy(c => c.Start))
        {
            long s = Math.Max((long)Math.Round(c.Start * 1000), t);
            long e = Math.Min(Math.Max((long)Math.Round(c.End * 1000), s + 300), end);
            if (e <= s) continue;
            if (s > t) samples.Add(("", s - t));
            samples.Add((c.Text, e - s));
            t = e;
        }
        if (end > t) samples.Add(("", end - t));
        if (samples.Count == 0) return;

        // 末尾に字幕の文字 (mdat) を書く
        var data = new MemoryStream();
        var sizes = new List<uint>();
        foreach (var (text, _) in samples)
        {
            var utf8 = Encoding.UTF8.GetBytes(text);
            data.Write([(byte)(utf8.Length >> 8), (byte)utf8.Length]);
            data.Write(utf8);
            sizes.Add((uint)(utf8.Length + 2));
        }
        long mdatPos = fs.Length;
        long dataOffset = mdatPos + 8;

        int videoW = 1920, videoH = 1080;
        FindVideoSize(moov, ref videoW, ref videoH);
        var trak = Trak(trackId, timescale, (ulong)Math.Round(movieSeconds * timescale), (ulong)end, samples, sizes, dataOffset, language, videoW, videoH);

        // 新しい moov: 元の中身 + 字幕のトラック。次のトラックの番号を進める
        var newMoov = new byte[moov.Length + trak.Length];
        Buffer.BlockCopy(moov, 0, newMoov, 0, moov.Length);
        Buffer.BlockCopy(trak, 0, newMoov, moov.Length, trak.Length);
        if (BinaryPrimitives.ReadUInt32BigEndian(moov) == 1) throw new InvalidDataException("64 ビットの moov には対応していません");
        BinaryPrimitives.WriteUInt32BigEndian(newMoov, (uint)newMoov.Length);
        BinaryPrimitives.WriteUInt32BigEndian(newMoov.AsSpan(nextIdPos), trackId + 1);

        // 元の moov を free にする (同じ大きさのまま。映像と音声の位置は変わらない)
        fs.Position = moovPos + 4;
        fs.Write("free"u8);
        fs.Position = mdatPos;
        var mdatHead = new byte[8];
        BinaryPrimitives.WriteUInt32BigEndian(mdatHead, (uint)(8 + data.Length));
        "mdat"u8.CopyTo(mdatHead.AsSpan(4));
        fs.Write(mdatHead);
        data.Position = 0;
        data.CopyTo(fs);
        fs.Write(newMoov);
    }

    static byte[] ReadAt(FileStream fs, long pos, int count)
    {
        var buf = new byte[count];
        fs.Position = pos;
        fs.ReadExactly(buf);
        return buf;
    }

    /// buf[start..end) の中から、子の箱 type の位置を探す
    static int FindChild(byte[] buf, int start, int end, string type)
    {
        int p = start;
        while (p + 8 <= end)
        {
            int size = (int)BinaryPrimitives.ReadUInt32BigEndian(buf.AsSpan(p));
            if (size < 8) return -1;
            if (Encoding.ASCII.GetString(buf, p + 4, 4) == type) return p;
            p += size;
        }
        return -1;
    }

    /// 映像のトラックの tkhd から大きさを読む (字幕の枠の大きさに使う)
    static void FindVideoSize(byte[] moov, ref int w, ref int h)
    {
        int p = 8;
        while ((p = FindNext(moov, p, "trak")) >= 0)
        {
            int size = (int)BinaryPrimitives.ReadUInt32BigEndian(moov.AsSpan(p));
            int tkhd = FindChild(moov, p + 8, p + size, "tkhd");
            if (tkhd >= 0)
            {
                int ver = moov[tkhd + 8];
                int whPos = tkhd + 8 + 4 + (ver == 1 ? 32 : 20) + 8 + 2 + 2 + 2 + 2 + 36;
                int tw = (int)(BinaryPrimitives.ReadUInt32BigEndian(moov.AsSpan(whPos)) >> 16);
                int th = (int)(BinaryPrimitives.ReadUInt32BigEndian(moov.AsSpan(whPos + 4)) >> 16);
                if (tw > 0 && th > 0) { w = tw; h = th; return; }
            }
            p += size;
        }
    }

    static int FindNext(byte[] buf, int start, string type)
    {
        int p = start;
        while (p + 8 <= buf.Length)
        {
            int size = (int)BinaryPrimitives.ReadUInt32BigEndian(buf.AsSpan(p));
            if (size < 8) return -1;
            if (Encoding.ASCII.GetString(buf, p + 4, 4) == type) return p;
            p += size;
        }
        return -1;
    }

    // ── 箱を作る ──

    sealed class Box
    {
        readonly MemoryStream ms = new();
        public Box U8(int v) { ms.WriteByte((byte)v); return this; }
        public Box U16(int v) { Span<byte> b = stackalloc byte[2]; BinaryPrimitives.WriteUInt16BigEndian(b, (ushort)v); ms.Write(b); return this; }
        public Box U32(uint v) { Span<byte> b = stackalloc byte[4]; BinaryPrimitives.WriteUInt32BigEndian(b, v); ms.Write(b); return this; }
        public Box U64(ulong v) { Span<byte> b = stackalloc byte[8]; BinaryPrimitives.WriteUInt64BigEndian(b, v); ms.Write(b); return this; }
        public Box Tag(string s) { ms.Write(Encoding.ASCII.GetBytes(s)); return this; }
        public Box Bytes(byte[] b) { ms.Write(b); return this; }
        public Box Zeros(int n) { ms.Write(new byte[n]); return this; }
        public byte[] Make(string type)
        {
            var body = ms.ToArray();
            var r = new byte[8 + body.Length];
            BinaryPrimitives.WriteUInt32BigEndian(r, (uint)r.Length);
            Encoding.ASCII.GetBytes(type).CopyTo(r, 4);
            body.CopyTo(r, 8);
            return r;
        }
    }

    static readonly uint[] Identity = [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000];

    static byte[] Trak(uint trackId, uint movieTimescale, ulong movieDuration, ulong durationMs,
        List<(string Text, long Duration)> samples, List<uint> sizes, long dataOffset, string language, int videoW, int videoH)
    {
        // tkhd: 有効・映像に入る。大きさは映像の幅と、下の 15%
        var tkhd = new Box().U8(1).U8(0).U16(0x0003).U64(0).U64(0).U32(trackId).U32(0).U64(movieDuration)
            .Zeros(8).U16(0).U16(0).U16(0).U16(0);
        foreach (var m in Identity) tkhd.U32(m);
        int boxH = Math.Max(1, videoH * 15 / 100);
        tkhd.U32((uint)videoW << 16).U32((uint)boxH << 16);

        int lang = 0;
        foreach (char c in language.PadRight(3, 'u')[..3]) lang = (lang << 5) | ((c - 0x60) & 0x1F);
        var mdhd = new Box().U8(1).U8(0).U16(0).U64(0).U64(0).U32(1000).U64(durationMs).U16(lang).U16(0).Make("mdhd");
        var hdlr = new Box().U32(0).U32(0).Tag("sbtl").Zeros(12).Bytes(Encoding.UTF8.GetBytes("NoGreenBack Subtitles\0")).Make("hdlr");

        var dref = new Box().U32(0).U32(1).Bytes(new Box().U32(1).Make("url ")).Make("dref");
        var dinf = new Box().Bytes(dref).Make("dinf");
        var nmhd = new Box().U32(0).Make("nmhd");

        // 3GPP 字幕のサンプルの説明 (横: 中央、縦: 下。白い文字、背景は透明)
        const string fontName = "Yu Gothic";
        var ftab = new Box().U16(1).U16(1).U8(fontName.Length).Tag(fontName).Make("ftab");
        var tx3g = new Box().Zeros(6).U16(1)          // reserved, data reference index
            .U32(0)                                   // display flags
            .U8(1).U8(0xFF)                           // 横: 中央, 縦: 下
            .U32(0x00000000)                          // 背景色
            .U16(0).U16(0).U16(0).U16(0)              // text box
            .U16(0).U16(0).U16(1).U8(0).U8(18).U32(0xFFFFFFFF)   // style: font 1, size 18, 白
            .Bytes(ftab).Make("tx3g");
        var stsd = new Box().U32(0).U32(1).Bytes(tx3g).Make("stsd");

        var stts = new Box().U32(0).U32((uint)samples.Count);
        foreach (var (_, d) in samples) stts.U32(1).U32((uint)d);
        var stsz = new Box().U32(0).U32(0).U32((uint)sizes.Count);
        foreach (var s in sizes) stsz.U32(s);
        var stsc = new Box().U32(0).U32(1).U32(1).U32((uint)samples.Count).U32(1).Make("stsc");
        byte[] chunk = dataOffset > uint.MaxValue
            ? new Box().U32(0).U32(1).U64((ulong)dataOffset).Make("co64")
            : new Box().U32(0).U32(1).U32((uint)dataOffset).Make("stco");
        var stbl = new Box().Bytes(stsd).Bytes(stts.Make("stts")).Bytes(stsc).Bytes(stsz.Make("stsz")).Bytes(chunk).Make("stbl");
        var minf = new Box().Bytes(nmhd).Bytes(dinf).Bytes(stbl).Make("minf");
        var mdia = new Box().Bytes(mdhd).Bytes(hdlr).Bytes(minf).Make("mdia");
        return new Box().Bytes(tkhd.Make("tkhd")).Bytes(mdia).Make("trak");
    }
}
