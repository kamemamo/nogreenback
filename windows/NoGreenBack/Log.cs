// 動きを確かめるためのログ (%LOCALAPPDATA%\NoGreenBack\log.txt)。起動するたびに作り直す

using System.IO;

namespace NoGreenBack;

public static class Log
{
    public static string FilePath { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NoGreenBack", "log.txt");

    static readonly object gate = new();
    static bool started;

    public static void Write(string message)
    {
        lock (gate)
        {
            try
            {
                if (!started)
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
                    File.WriteAllText(FilePath, "");
                    started = true;
                }
                File.AppendAllText(FilePath, $"{DateTime.Now:HH:mm:ss.fff} {message}\n");
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
