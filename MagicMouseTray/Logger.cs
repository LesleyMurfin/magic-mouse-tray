// SPDX-License-Identifier: MIT
using System.IO;

namespace MagicMouseTray;

// File logger for diagnosing battery read failures in the headless tray app.
// Output: %APPDATA%\MagicMouseTray\debug.log  (rotates at 1MB → debug.log.1)
// Never throws — all I/O errors are silently swallowed.
internal static class Logger
{
    internal static readonly string LogPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "MagicMouseTray", "debug.log");

    internal static string LogDir => Path.GetDirectoryName(LogPath)!;

    const long MaxBytes = 1024 * 1024; // 1 MB rotation threshold
    static readonly object Lock = new();
    static string _appStartBanner = string.Empty;

    internal static void LogAppStart()
    {
        var asm = System.Reflection.Assembly.GetExecutingAssembly();
        var ver = asm.GetCustomAttribute<System.Reflection.AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? asm.GetName().Version?.ToString() ?? "unknown";
        var fx = System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription;
        var os = System.Runtime.InteropServices.RuntimeInformation.OSDescription;
        var pid = Environment.ProcessId;
        _appStartBanner = $"INFO APP_START version={ver} framework={fx} os=\"{os}\" pid={pid}";
        Log(_appStartBanner);
    }

    internal static void Log(string message)
    {
        message = System.Text.RegularExpressions.Regex.Replace(message, @"[^\x00-\x7F]", string.Empty);
        try
        {
            lock (Lock)
            {
                var dir = Path.GetDirectoryName(LogPath)!;
                Directory.CreateDirectory(dir);

                if (File.Exists(LogPath) && new FileInfo(LogPath).Length >= MaxBytes)
                {
                    File.Move(LogPath, LogPath + ".1", overwrite: true);
                    if (!string.IsNullOrEmpty(_appStartBanner))
                    {
                        File.AppendAllText(LogPath,
                            $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {_appStartBanner}{Environment.NewLine}", new System.Text.UTF8Encoding(true));
                    }
                }

                File.AppendAllText(LogPath,
                    $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {message}{Environment.NewLine}", new System.Text.UTF8Encoding(true));
            }
        }
        catch { }
    }
}
