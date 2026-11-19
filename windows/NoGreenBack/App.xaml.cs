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

        // どんな終わり方でも、指し棒で隠したカーソルを戻す
        AppDomain.CurrentDomain.ProcessExit += (_, _) => Overlays.CursorHider.Show();

        Model = new AppModel(Settings.Load());
        MainWindow = new MainWindow(Model);
        MainWindow.Show();
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
        // 画面を覆う透明なウィンドウ・録画の後片付けは、作ったらここで行う (SPEC.md 2 章)
        Model.Recording.Dispose();   // 録画中なら、ファイルを閉じてから終える
        Model.Overlays.Dispose();
        Model.Outputs.Dispose();
        Model.Video.Dispose();
        Model.Displays.Dispose();
        Model.Mic.Dispose();
        Model.Settings.Save();
        base.OnExit(e);
    }
}
