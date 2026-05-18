# kbd-readfile-wait-2026-05-07.ps1
# Waits 60s for keyboard to push battery report via ReadFile on col02.
# Uses overlapped I/O so we can timeout without blocking PS.
# No BT requests. Safe.

$Out = '\\wsl.localhost\Ubuntu\home\lesley\projects\Personal\magic-mouse-tray\.ai\test-runs\2026-05-07-kbd-battery-probe\readfile-wait.txt'
$log = @()
function L([string]$m) { $script:log += $m; Write-Host $m }

L "=== KB READFILE WAIT $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public static class HidReadOverlapped {
    const uint GENERIC_READ = 0x80000000;
    const uint FILE_SHARE_READWRITE = 3;
    const uint OPEN_EXISTING = 3;
    const uint FILE_FLAG_OVERLAPPED = 0x40000000;
    const uint WAIT_OBJECT_0 = 0;
    const uint WAIT_TIMEOUT = 258;
    const uint INFINITE = 0xFFFFFFFF;
    const uint ERROR_IO_PENDING = 997;

    [DllImport("kernel32.dll", CharSet=CharSet.Auto, SetLastError=true)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share,
        IntPtr sec, uint disp, uint flags, IntPtr templ);

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool ReadFile(SafeFileHandle h, byte[] buf, uint toRead,
        IntPtr bytesRead, ref OVERLAPPED overlapped);

    [DllImport("kernel32.dll")]
    static extern bool CancelIo(SafeFileHandle h);

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetOverlappedResult(SafeFileHandle h, ref OVERLAPPED ov,
        out uint bytesTransferred, bool wait);

    [DllImport("kernel32.dll")]
    static extern uint WaitForSingleObject(IntPtr h, uint ms);

    [DllImport("kernel32.dll")]
    static extern IntPtr CreateEvent(IntPtr sec, bool manualReset, bool initial, IntPtr name);

    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);

    [StructLayout(LayoutKind.Sequential)]
    struct OVERLAPPED {
        public UIntPtr Internal;    // ULONG_PTR = 8 bytes on x64
        public UIntPtr InternalHigh;
        public uint Offset;
        public uint OffsetHigh;
        public IntPtr hEvent;       // total: 8+8+4+4+8 = 32 bytes on x64
    }

    // Returns battery% (0-100) or -1=timeout, -2=open fail, -3=io error, -4=disconnected
    public static int WaitForBatteryReport(string path, int timeoutSeconds, out string detail) {
        var hDev = CreateFile(path, GENERIC_READ, FILE_SHARE_READWRITE, IntPtr.Zero,
            OPEN_EXISTING, FILE_FLAG_OVERLAPPED, IntPtr.Zero);
        if (hDev.IsInvalid) {
            detail = "OPEN FAIL err=" + Marshal.GetLastWin32Error();
            return -2;
        }

        var hEvent = CreateEvent(IntPtr.Zero, true, false, IntPtr.Zero);
        try {
            var deadline = DateTime.Now.AddSeconds(timeoutSeconds);
            var buf = new byte[64];
            int tick = 0;

            while (DateTime.Now < deadline) {
                var ov = new OVERLAPPED();
                ov.hEvent = hEvent;

                bool ok = ReadFile(hDev, buf, (uint)buf.Length, IntPtr.Zero, ref ov);
                int err = Marshal.GetLastWin32Error();

                if (!ok && err != (int)ERROR_IO_PENDING) {
                    detail = "ReadFile err=" + err;
                    return err == 1167 ? -4 : -3;
                }

                int msLeft = (int)Math.Max(0, (deadline - DateTime.Now).TotalMilliseconds);
                int waitMs = Math.Min(5000, msLeft);
                uint wr = WaitForSingleObject(hEvent, (uint)waitMs);

                if (wr == WAIT_OBJECT_0) {
                    uint xferred = 0;
                    if (GetOverlappedResult(hDev, ref ov, out xferred, false) && xferred >= 2) {
                        int elapsed = (int)(DateTime.Now - (deadline.AddSeconds(-timeoutSeconds))).TotalSeconds;
                        detail = string.Format("HIT at {0}s: bytes=[{1}] RID=0x{2:X2} buf[1]={3}",
                            elapsed,
                            string.Join(" ", Array.ConvertAll(buf, b => b.ToString("X2"))).Substring(0, Math.Min(24, buf.Length*3)),
                            buf[0], buf[1]);
                        return buf[1];
                    }
                } else {
                    // Timeout on this tick - cancel and retry
                    CancelIo(hDev);
                    tick++;
                    int secLeft = (int)(deadline - DateTime.Now).TotalSeconds;
                    Console.WriteLine("  [" + (tick*5) + "s] no data yet (" + secLeft + "s remain)");
                }
            }

            detail = "TIMEOUT: keyboard sent nothing in " + timeoutSeconds + " seconds";
            return -1;
        }
        finally {
            CloseHandle(hEvent);
            hDev.Close();
        }
    }
}
'@ -ErrorAction Stop

$col02 = "\\?\hid#{00001124-0000-1000-8000-00805f9b34fb}_vid&000205ac_pid&0239&col02#a&eaf9d13&3&0001#{4d1e55b2-f16f-11cf-88cb-001111000030}"

L "Waiting up to 120 seconds on col02 (no BT requests, event-driven only)..."
L ">> TYPE ON YOUR KEYBOARD while waiting to see if key presses trigger a battery push <<"
L ""

$detail = ""
$result = [HidReadOverlapped]::WaitForBatteryReport($col02, 120, [ref]$detail)

L $detail
L ""
if ($result -ge 0) {
    L "BATTERY PERCENT = $result%"
    L "RESULT: Keyboard IS event-driven. ReadFile works. No polling needed."
} elseif ($result -eq -1) {
    L "RESULT: Keyboard sent NO data in 120 seconds. Not event-driven (or interval > 2min)."
} elseif ($result -eq -4) {
    L "RESULT: Keyboard disconnected during wait."
} else {
    L "RESULT: I/O error - $detail"
}

$log | Set-Content -Path $Out -Encoding UTF8
L ""
L "=== DONE - saved to $Out ==="
