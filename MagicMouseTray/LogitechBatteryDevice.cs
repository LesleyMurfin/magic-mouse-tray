// SPDX-License-Identifier: MIT
// IBatteryDevice implementation for directly-connected (BT/USB) Logitech HID++ 2.0 devices.
//
// EXPERIMENTAL — flag-gated behind Config.EnableThirdParty (default off). No Logitech hardware
// was available to verify this path; it is concrete, buildable scaffolding only.
//
// The HID++ 2.0 negotiation TECHNIQUE (Root feature lookup, then BatteryStatus/UnifiedBattery
// query) is reimplemented from the MIT-licensed project Ithilias/logitray. No source was copied;
// this is an independent C# implementation. See THIRD-PARTY-NOTICES.md.
//
// SCOPE: directly-connected devices only (deviceIndex 0xFF addresses the device itself).
// Unifying/Bolt receivers are out of scope (they require per-paired-device index 1-6) and are
// excluded at discovery time (DeviceRegistry.IsLogitechReceiver).
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace MagicMouseTray;

internal sealed class LogitechBatteryDevice : IBatteryDevice
{
    const ushort UP_VENDOR = 0xFF00;   // HID++ vendor-defined collection
    const byte DEV_INDEX   = 0xFF;     // direct-connect: addresses the device itself
    const byte SW_ID       = 0x05;     // arbitrary software id (low nibble of byte3)
    const byte SHORT_ID    = 0x10;     // short report: 7 bytes total
    const byte LONG_ID     = 0x11;     // long report: 20 bytes total
    const int  TIMEOUT_MS  = 600;      // mirrors the per-read budget elsewhere in the app

    readonly string _path;

    public string DeviceName { get; } = "Logitech Mouse"; // provisional; name query out of scope
    public DeviceKind Kind => DeviceKind.LogitechMouse;

    internal LogitechBatteryDevice(string path) => _path = path;

    public int GetBatteryPercent()
    {
        using var handle = HidNative.CreateFile(
            _path,
            HidNative.GENERIC_READ | 0x40000000u /* GENERIC_WRITE */,
            HidNative.FILE_SHARE_READ | HidNative.FILE_SHARE_WRITE,
            IntPtr.Zero,
            HidNative.OPEN_EXISTING,
            HidNative.FILE_FLAG_OVERLAPPED,
            IntPtr.Zero);

        if (handle.IsInvalid)
        {
            Logger.Log($"LOGI_OPEN_FAILED path={_path} err={Marshal.GetLastWin32Error()}");
            return -1;
        }

        // Confirm vendor collection and pick short vs long report length from OutputReportByteLength.
        int reportLen;
        byte reportId;
        if (!HidNative.HidD_GetPreparsedData(handle, out var preparsed)) return -1;
        try
        {
            var caps = new HidNative.HIDP_CAPS();
            if (HidNative.HidP_GetCaps(preparsed, ref caps) != HidNative.HIDP_STATUS_SUCCESS) return -1;
            if (caps.UsagePage != UP_VENDOR) { Logger.Log($"LOGI_NOT_VENDOR up=0x{caps.UsagePage:X4}"); return -1; }
            if (caps.OutputReportByteLength >= 20) { reportId = LONG_ID; reportLen = 20; }
            else                                   { reportId = SHORT_ID; reportLen = 7; }
        }
        finally { HidNative.HidD_FreePreparsedData(preparsed); }

        // Prefer BatteryStatus (0x1000, fn0 = % directly); fall back to UnifiedBattery (0x1004, fn1).
        int pct = ReadFeatureBattery(handle, reportId, reportLen, 0x1000, funcIndex: 0);
        if (pct < 0)
            pct = ReadFeatureBattery(handle, reportId, reportLen, 0x1004, funcIndex: 1);

        if (pct >= 0) Logger.Log($"LOGI_BATTERY_OK device={DeviceName} pct={pct}%");
        return pct;
    }

    // Resolves a HID++ 2.0 feature via Root (0x0000) GetFeature, then queries it for battery %.
    int ReadFeatureBattery(SafeFileHandle handle, byte reportId, int reportLen, ushort featureId, byte funcIndex)
    {
        // Root.GetFeature(featureId): byte3 = 0x00 | swId (function 0 on the Root feature).
        var rootReq = NewReport(reportId, reportLen, featureIndex: 0x00,
            funcByte: (byte)(0x00 | SW_ID), arg0: (byte)(featureId >> 8), arg1: (byte)(featureId & 0xFF));
        var rootResp = SendReceive(handle, rootReq, reportLen);
        if (rootResp is null) return -1;
        byte featureIndex = rootResp[4];
        if (featureIndex == 0) return -1; // feature absent on this device

        // Query the feature: byte3 = (funcIndex << 4) | swId.
        var req = NewReport(reportId, reportLen, featureIndex,
            funcByte: (byte)((funcIndex << 4) | SW_ID), arg0: 0, arg1: 0);
        var resp = SendReceive(handle, req, reportLen);
        if (resp is null) return -1;

        int pct = resp[4]; // % at offset 4 for both 0x1000 GetBatteryLevelStatus and 0x1004 GetStatus
        return pct is >= 0 and <= 100 ? pct : -1;
    }

    static byte[] NewReport(byte reportId, int len, byte featureIndex, byte funcByte, byte arg0, byte arg1)
    {
        var b = new byte[len];
        b[0] = reportId;
        b[1] = DEV_INDEX;
        b[2] = featureIndex;
        b[3] = funcByte;
        b[4] = arg0;
        b[5] = arg1;
        return b;
    }

    // Writes the HID++ request and waits (overlapped) for the matching response, reusing the
    // same event/wait helpers KeyboardBatteryDevice-era code uses for timed HID reads.
    static byte[]? SendReceive(SafeFileHandle handle, byte[] req, int reportLen)
    {
        if (!HidNative.HidD_SetOutputReport(handle, req, req.Length))
            return null;

        IntPtr evt = HidNative.CreateEvent(IntPtr.Zero, true, false, IntPtr.Zero);
        try
        {
            var buf = new byte[reportLen];
            var ov = new HidNative.OVERLAPPED { hEvent = evt };
            if (!HidNative.ReadFile(handle, buf, (uint)buf.Length, IntPtr.Zero, ref ov))
            {
                if ((uint)Marshal.GetLastWin32Error() != HidNative.ERROR_IO_PENDING) return null;
                if (HidNative.WaitForSingleObject(evt, TIMEOUT_MS) != HidNative.WAIT_OBJECT_0)
                {
                    HidNative.CancelIo(handle);
                    return null;
                }
            }
            if (!HidNative.GetOverlappedResult(handle, ref ov, out uint got, false) || got == 0)
                return null;

            // Match the response to our request (same feature index + swId).
            if (buf[0] != req[0] || buf[2] != req[2]) return null;
            return buf;
        }
        finally { HidNative.CloseHandle(evt); }
    }
}
