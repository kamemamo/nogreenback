using System.IO;
using System.Windows;

namespace NoGreenBack;

public partial class App : Application
{
    public static AppModel Model { get; private set; } = null!;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += (_, args) =>
        {
            ReportCrash(args.Exception);
            args.Handled = true;
            Shutdown(1);
        };
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            if (args.ExceptionObject is Exception ex) ReportCrash(ex);
        };

        // 二重に起動したら、先に動いている方の操作ウィンドウを前に出して終わる
        // (2 つ動くと、ショートカット・カメラ・Spout の名前を取り合うため)
        singleInstance = new Mutex(true, @"Local\NoGreenBack.SingleInstance", out bool first);
        if (!first)
        {
            BringOtherInstanceToFront();
            Shutdown();
            return;
        }

        // どんな終わり方でも、指し棒で隠したカーソルを戻す
        AppDomain.CurrentDomain.ProcessExit += (_, _) => Overlays.CursorHider.Show();

        Model = new AppModel(Settings.Load());
        MainWindow = new MainWindow(Model);
        MainWindow.Show();
    }

    static Mutex? singleInstance;

    static void BringOtherInstanceToFront()
    {
        int me = Environment.ProcessId;
        foreach (var p in System.Diagnostics.Process.GetProcessesByName("NoGreenBack"))
        {
            if (p.Id == me || p.MainWindowHandle == IntPtr.Zero) continue;
            if (NativeMethods.IsIconic(p.MainWindowHandle)) NativeMethods.ShowWindow(p.MainWindowHandle, 9 /* SW_RESTORE */);
            NativeMethods.SetForegroundWindow(p.MainWindowHandle);
            return;
        }
    }

    /// 思わぬエラーで止まるときは、%LOCALAPPDATA%\NoGreenBack\crash.log に書いて知らせる
    static void ReportCrash(Exception ex)
    {
        Overlays.CursorHider.Show();   // 指し棒で隠したカーソルを戻す
        var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NoGreenBack", "crash.log");
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.AppendAllText(path, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}]\n{ex}\n\n");
        }
        catch { }
        MessageBox.Show(Loc.L("エラーが起きたため終了します: %@", ex.Message) + "\n\n" + path,
            "NoGreenBack", MessageBoxButton.OK, MessageBoxImage.Error);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (Model == null) { base.OnExit(e); return; }   // 二重に起動して、すぐ終えたとき
        // 画面を覆う透明なウィンドウ・録画の後片付けは、作ったらここで行う (SPEC.md 2 章)
        Model.Recording.Dispose();   // 録画中なら、ファイルを閉じてから終える
        Model.Subtitles.Dispose();
        Model.Overlays.Dispose();
        Model.Outputs.Dispose();
        Model.Video.Dispose();
        Model.Displays.Dispose();
        Model.Mic.Dispose();
        Model.External.Dispose();
        Model.Atem.Dispose();
        Model.Settings.Save();
        singleInstance?.ReleaseMutex();
        base.OnExit(e);
    }
}

static partial class NativeMethods
{
    [System.Runtime.InteropServices.LibraryImport("user32.dll")]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    internal static partial bool IsIconic(IntPtr hwnd);

    [System.Runtime.InteropServices.LibraryImport("user32.dll")]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    internal static partial bool ShowWindow(IntPtr hwnd, int cmd);

    [System.Runtime.InteropServices.LibraryImport("user32.dll")]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    internal static partial bool SetForegroundWindow(IntPtr hwnd);
}
