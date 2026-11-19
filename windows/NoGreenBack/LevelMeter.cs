// 音量のメーター (SPEC.md 11 章)。値は 0〜30 ((dB + 60) / 2)。24 (-12 dB) から黄色、28 (-4 dB) から赤 (Mac 版の NSLevelIndicator と同じ目盛り)

using System.Windows;
using System.Windows.Media;

namespace NoGreenBack;

public sealed class LevelMeter : FrameworkElement
{
    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(
        nameof(Value), typeof(double), typeof(LevelMeter), new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));

    public double Value { get => (double)GetValue(ValueProperty); set => SetValue(ValueProperty, value); }

    static readonly Brush Back = Frozen(new SolidColorBrush(Color.FromRgb(0xDC, 0xDC, 0xE0)));
    static readonly Brush Green = Frozen(new SolidColorBrush(Color.FromRgb(0x34, 0xC7, 0x59)));
    static readonly Brush Yellow = Frozen(new SolidColorBrush(Color.FromRgb(0xFF, 0xCC, 0x00)));
    static readonly Brush Red = Frozen(new SolidColorBrush(Color.FromRgb(0xFF, 0x3B, 0x30)));
    static T Frozen<T>(T f) where T : Freezable { f.Freeze(); return f; }

    protected override void OnRender(DrawingContext dc)
    {
        double w = ActualWidth, h = ActualHeight, v = Math.Clamp(Value, 0, 30) / 30;
        dc.DrawRoundedRectangle(Back, null, new Rect(0, 0, w, h), h / 2, h / 2);
        if (v <= 0) return;
        dc.PushClip(new RectangleGeometry(new Rect(0, 0, w * v, h), h / 2, h / 2));
        dc.DrawRectangle(Green, null, new Rect(0, 0, w * 24 / 30, h));
        dc.DrawRectangle(Yellow, null, new Rect(w * 24 / 30, 0, w * 4 / 30, h));
        dc.DrawRectangle(Red, null, new Rect(w * 28 / 30, 0, w * 2 / 30, h));
        dc.Pop();
    }
}
