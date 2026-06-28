// SPDX-License-Identifier: MIT
using System.Windows;

namespace MagicMouseTray;

public partial class App
{
    TrayApp? _trayApp;
    static Mutex? _instanceMutex;
    static bool _ownsMutex;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // Single-instance guard: a second launch would create a competing V3RecycleManager
        // racing on C:\mm-dev-queue\request.txt. Local\ scope is correct for a per-user tray app.
        _instanceMutex = new Mutex(initiallyOwned: true, @"Local\MagicMouseTray.SingleInstance", out _ownsMutex);
        if (!_ownsMutex)
        {
            _instanceMutex.Dispose();   // not owned — release handle, do NOT ReleaseMutex
            _instanceMutex = null;
            Shutdown();
            return;                      // second instance exits silently
        }

        Logger.LogAppStart();

        System.AppDomain.CurrentDomain.UnhandledException += (s, ev) =>
        {
            if (ev.ExceptionObject is System.Exception ex)
                Logger.Log($"FATAL_ERROR AppDomain: {ex.Message}\n{ex.StackTrace}");
            else
                Logger.Log("FATAL_ERROR AppDomain: Unknown exception");
        };

        DispatcherUnhandledException += (s, ev) =>
        {
            Logger.Log($"ERROR Dispatcher: {ev.Exception.Message}\n{ev.Exception.StackTrace}");
            ev.Handled = true;
        };

        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        _trayApp = new TrayApp(Config.Load());
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _trayApp?.Dispose();
        if (_ownsMutex)                  // only the owner releases + disposes
        {
            _instanceMutex?.ReleaseMutex();
            _instanceMutex?.Dispose();
        }
        base.OnExit(e);
    }
}
