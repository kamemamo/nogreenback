// 保存する設定 (SPEC.md「13. 設定の一覧」)
// %APPDATA%\NoGreenBack\settings.json に、Mac 版の UserDefaults と同じキーの名前で保存する。
// 値を変えると 0.3 秒待ってから書き込み、終了するときにも書き込む。

using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows.Threading;

namespace NoGreenBack;

public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected void Raise([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name);
        return true;
    }
}

/// 選択肢の一覧 (XAML の ItemsSource に使う)
public static class Choices
{
    public static int[] FrameRates { get; } = [30, 25, 20];
    public static int[] RecMbps { get; } = [4, 6, 8, 10, 12, 16, 20, 30, 40];
    /// 0 は「縮めない」
    public static int[] RecLongSides { get; } = [1280, 1920, 2560, 3840, 0];
    public static int[] RecFPS { get; } = [24, 25, 30, 50, 60];
    public static int[] RecAudioKbps { get; } = [64, 96, 128, 192, 256];
    public static double[] ExternalDucks { get; } = [1, 0.5, 0.25, 0.1];
}

public sealed class Settings : Observable
{
    // ── カメラ ──
    int frameRate = 25;
    [JsonPropertyName("frameRate")] public int FrameRate { get => frameRate; set { if (Set(ref frameRate, value)) Raise(nameof(FrameRateIndex)); } }
    [JsonIgnore] public int FrameRateIndex { get => Math.Max(0, Array.IndexOf(Choices.FrameRates, FrameRate)); set { if (value >= 0) FrameRate = Choices.FrameRates[value]; } }

    bool mirror = true;
    [JsonPropertyName("mirror")] public bool Mirror { get => mirror; set => Set(ref mirror, value); }
    bool flipVertical = true;
    [JsonPropertyName("flipVertical")] public bool FlipVertical { get => flipVertical; set => Set(ref flipVertical, value); }
    bool straightAlpha;
    [JsonPropertyName("straightAlpha")] public bool StraightAlpha { get => straightAlpha; set => Set(ref straightAlpha, value); }
    bool tuningOpen;
    [JsonPropertyName("tuningOpen")] public bool TuningOpen { get => tuningOpen; set => Set(ref tuningOpen, value); }

    // ── 人物とワイプ ──
    bool personOn = true;
    [JsonPropertyName("personOn")] public bool PersonOn { get => personOn; set => Set(ref personOn, value); }
    bool overlayOn;
    [JsonPropertyName("overlayOn")] public bool OverlayOn { get => overlayOn; set => Set(ref overlayOn, value); }
    /// 0 右下, 1 左下, 2 右上, 3 左上
    int overlayCorner;
    [JsonPropertyName("overlayCorner")] public int OverlayCorner { get => overlayCorner; set => Set(ref overlayCorner, value); }
    double overlayScale = 0.35;
    [JsonPropertyName("overlayScale")] public double OverlayScale { get => overlayScale; set => Set(ref overlayScale, Math.Clamp(value, 0.15, 0.8)); }
    string? overlayScreen;
    [JsonPropertyName("overlayScreen")] public string? OverlayScreen { get => overlayScreen; set => Set(ref overlayScreen, value); }

    // ── 背景と全画面出力 ──
    string? backgroundID;
    [JsonPropertyName("backgroundID")] public string? BackgroundID { get => backgroundID; set => Set(ref backgroundID, value); }
    string? outputScreen;
    [JsonPropertyName("outputScreen")] public string? OutputScreen { get => outputScreen; set => Set(ref outputScreen, value); }
    bool matchOutputAspect = true;
    [JsonPropertyName("matchOutputAspect")] public bool MatchOutputAspect { get => matchOutputAspect; set { if (Set(ref matchOutputAspect, value)) Raise(nameof(AspectIndex)); } }
    /// 0 出す画面に合わせる, 1 カメラと同じ
    [JsonIgnore] public int AspectIndex { get => MatchOutputAspect ? 0 : 1; set => MatchOutputAspect = value == 0; }

    // ── 手書き ──
    bool annotationOn;
    [JsonPropertyName("annotationOn")] public bool AnnotationOn { get => annotationOn; set => Set(ref annotationOn, value); }
    /// Windows では 0 Ctrl, 1 Alt, 2 Ctrl+Alt (Mac 版とは番号の意味が違う。SPEC.md 17 章)
    int drawKey;
    [JsonPropertyName("drawKey")] public int DrawKey { get => drawKey; set => Set(ref drawKey, value); }
    /// 0 赤, 1 黄, 2 青, 3 緑, 4 白, 5 黒
    int penColor;
    [JsonPropertyName("penColor")] public int PenColor { get => penColor; set => Set(ref penColor, value); }
    double penWidth = 5;
    [JsonPropertyName("penWidth")] public double PenWidth { get => penWidth; set => Set(ref penWidth, Math.Clamp(value, 2, 20)); }
    /// 0 消さない, 1 3 秒, 2 10 秒
    int penFade;
    [JsonPropertyName("penFade")] public int PenFade { get => penFade; set => Set(ref penFade, value); }
    double boardOpacity = 0.7;
    [JsonPropertyName("boardOpacity")] public double BoardOpacity { get => boardOpacity; set => Set(ref boardOpacity, Math.Clamp(value, 0.3, 0.95)); }

    // ── キーボード ──
    bool keyboardOn;
    [JsonPropertyName("keyboardOn")] public bool KeyboardOn { get => keyboardOn; set => Set(ref keyboardOn, value); }
    /// 0 JIS, 1 US。保存していなければ、表示が英語なら US
    int? keyboardLayout;
    [JsonPropertyName("keyboardLayout"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? KeyboardLayout { get => keyboardLayout; set { if (Set(ref keyboardLayout, value)) Raise(nameof(KeyboardLayoutIndex)); } }
    [JsonIgnore] public int KeyboardLayoutIndex { get => KeyboardLayout ?? (Loc.IsEnglish ? 1 : 0); set => KeyboardLayout = value; }
    /// 0 人物の反対側, 1 下の中央, 2 左下, 3 右下, 4 上の中央
    int keyboardPlace;
    [JsonPropertyName("keyboardPlace")] public int KeyboardPlace { get => keyboardPlace; set => Set(ref keyboardPlace, value); }
    double keyboardSize = 0.58;
    [JsonPropertyName("keyboardSize")] public double KeyboardSize { get => keyboardSize; set => Set(ref keyboardSize, Math.Clamp(value, 0.35, 0.95)); }

    // ── 字幕 ──
    /// ja-JP / en-US。保存していなければ、表示が英語なら en-US
    string? subtitleLanguage;
    [JsonPropertyName("subtitleLanguage"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? SubtitleLanguage { get => subtitleLanguage; set => Set(ref subtitleLanguage, value); }
    [JsonIgnore] public string EffectiveSubtitleLanguage => SubtitleLanguage ?? (Loc.IsEnglish ? "en-US" : "ja-JP");
    bool subtitleAI = true;
    [JsonPropertyName("subtitleAI")] public bool SubtitleAI { get => subtitleAI; set => Set(ref subtitleAI, value); }
    string subtitleTerms = "";
    [JsonPropertyName("subtitleTerms")] public string SubtitleTerms { get => subtitleTerms; set => Set(ref subtitleTerms, value); }

    // ── 録画 ──
    string? recordScreen;
    [JsonPropertyName("recordScreen")] public string? RecordScreen { get => recordScreen; set => Set(ref recordScreen, value); }
    bool recordMic = true;
    [JsonPropertyName("recordMic")] public bool RecordMic { get => recordMic; set => Set(ref recordMic, value); }
    string? recordMicID;
    [JsonPropertyName("recordMicID")] public string? RecordMicID { get => recordMicID; set => Set(ref recordMicID, value); }
    int recMbps = 8;
    [JsonPropertyName("recMbps")] public int RecMbps { get => recMbps; set { if (Set(ref recMbps, value)) Raise(nameof(GigabytesPerHourText)); } }
    int recLongSide = 1920;
    [JsonPropertyName("recLongSide")] public int RecLongSide { get => recLongSide; set => Set(ref recLongSide, value); }
    int recFPS = 30;
    [JsonPropertyName("recFPS")] public int RecFPS { get => recFPS; set => Set(ref recFPS, value); }
    bool recHEVC;
    [JsonPropertyName("recHEVC")] public bool RecHEVC { get => recHEVC; set { if (Set(ref recHEVC, value)) Raise(nameof(RecFormatIndex)); } }
    [JsonIgnore] public int RecFormatIndex { get => RecHEVC ? 1 : 0; set => RecHEVC = value == 1; }
    int recAudioKbps = 128;
    [JsonPropertyName("recAudioKbps")] public int RecAudioKbps { get => recAudioKbps; set { if (Set(ref recAudioKbps, value)) Raise(nameof(GigabytesPerHourText)); } }

    /// 「1 時間で最大 約 ○ GB」(SPEC.md 9 章の式)
    [JsonIgnore] public string GigabytesPerHourText =>
        Loc.L("1 時間で最大 約 %.1f GB", (RecMbps * 1000.0 + RecAudioKbps) * 3600 / 8 / 1_000_000);

    // ── 外部の音声 ──
    string? externalInputID;
    [JsonPropertyName("externalInputID")] public string? ExternalInputID { get => externalInputID; set => Set(ref externalInputID, value); }
    /// null は出さない、空はシステムの出力
    string? externalOutputUID;
    [JsonPropertyName("externalOutputUID")] public string? ExternalOutputUID { get => externalOutputUID; set => Set(ref externalOutputUID, value); }
    double externalVolume = 1;
    [JsonPropertyName("externalVolume")] public double ExternalVolume { get => externalVolume; set => Set(ref externalVolume, Math.Clamp(value, 0, 1)); }
    double externalDuck = 0.25;
    [JsonPropertyName("externalDuck")] public double ExternalDuck { get => externalDuck; set { if (Set(ref externalDuck, value)) Raise(nameof(ExternalDuckIndex)); } }
    [JsonIgnore] public int ExternalDuckIndex
    {
        get { int i = Array.IndexOf(Choices.ExternalDucks, ExternalDuck); return i < 0 ? 2 : i; }
        set { if (value >= 0) ExternalDuck = Choices.ExternalDucks[value]; }
    }

    // ── ATEM ──
    bool atemMix;
    [JsonPropertyName("atemMix")] public bool AtemMix { get => atemMix; set => Set(ref atemMix, value); }

    // ── 読み書き ──

    public static string FilePath { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "NoGreenBack", "settings.json");

    static readonly JsonSerializerOptions jsonOptions = new() { WriteIndented = true };

    DispatcherTimer? saveTimer;

    public static Settings Load()
    {
        Settings s;
        try
        {
            s = File.Exists(FilePath)
                ? JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath), jsonOptions) ?? new Settings()
                : new Settings();
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            // 壊れたファイルは既定から始める (元のファイルは .bad として残す)
            try { File.Copy(FilePath, FilePath + ".bad", overwrite: true); } catch { }
            s = new Settings();
        }
        s.PropertyChanged += (_, _) => s.ScheduleSave();
        return s;
    }

    void ScheduleSave()
    {
        saveTimer ??= new DispatcherTimer(TimeSpan.FromSeconds(0.3), DispatcherPriority.Background, (_, _) => Save(), Dispatcher.CurrentDispatcher);
        saveTimer.Stop();
        saveTimer.Start();
    }

    /// すぐ書き込む (一時ファイルに書いてから置き換えるので、途中で落ちても壊れない)
    public void Save()
    {
        saveTimer?.Stop();
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(this, jsonOptions));
            File.Move(tmp, FilePath, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            System.Diagnostics.Debug.WriteLine($"設定を保存できません: {e.Message}");
        }
    }
}

/// 保存しない状態 (起動するたびに既定に戻る。SPEC.md 13 章の「保存しないもの」)
public sealed class AppState : Observable
{
    /// 0 Fast, 1 Balanced, 2 Accurate
    int quality = 1;
    public int Quality { get => quality; set => Set(ref quality, value); }
    double brightnessStabilization = 0.7;
    public double BrightnessStabilization { get => brightnessStabilization; set => Set(ref brightnessStabilization, value); }
    double flickerReduction = 0.6;
    public double FlickerReduction { get => flickerReduction; set => Set(ref flickerReduction, value); }
    double dropoutHold = 0.2;
    public double DropoutHold { get => dropoutHold; set => Set(ref dropoutHold, value); }
    double edgeTightness = 0.3;
    public double EdgeTightness { get => edgeTightness; set => Set(ref edgeTightness, value); }
    double edgeBlur = 1.5;
    public double EdgeBlur { get => edgeBlur; set => Set(ref edgeBlur, value); }

    bool fullScreen;
    public bool FullScreen { get => fullScreen; set => Set(ref fullScreen, value); }
    bool subtitlesOn;
    public bool SubtitlesOn { get => subtitlesOn; set => Set(ref subtitlesOn, value); }
    bool penLock;
    public bool PenLock { get => penLock; set => Set(ref penLock, value); }
    bool whiteboardOn;
    public bool WhiteboardOn { get => whiteboardOn; set => Set(ref whiteboardOn, value); }
    bool pointerOn;
    public bool PointerOn { get => pointerOn; set => Set(ref pointerOn, value); }
    bool recording;
    public bool Recording { get => recording; set => Set(ref recording, value); }

    string fpsText = "";
    public string FpsText { get => fpsText; set => Set(ref fpsText, value); }
    string elapsedText = "";
    public string ElapsedText { get => elapsedText; set => Set(ref elapsedText, value); }
}
