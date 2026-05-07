// P/Invoke declarations for HID and SetupDi APIs shared across all device readers.
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

namespace MagicMouseTray;

internal static class HidNative
{
    internal const uint FILE_SHARE_READ       = 0x00000001;
    internal const uint FILE_SHARE_WRITE      = 0x00000002;
    internal const uint OPEN_EXISTING         = 3;
    internal const uint DIGCF_PRESENT         = 0x02;
    internal const uint DIGCF_DEVICEINTERFACE = 0x10;
    internal const int  HIDP_STATUS_SUCCESS   = 0x00110000;
    internal const uint GENERIC_READ          = 0x80000000u;
    internal const uint FILE_FLAG_OVERLAPPED  = 0x40000000u;
    internal const uint WAIT_OBJECT_0         = 0;
    internal const uint ERROR_IO_PENDING      = 997;
    internal const uint ERROR_DEVICE_NOT_CONNECTED = 1167;
    internal static readonly IntPtr INVALID_HANDLE_VALUE = new(-1);

    internal static readonly Guid HidGuid = new("4d1e55b2-f16f-11cf-88cb-001111000030");

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    internal static extern SafeFileHandle CreateFile(string lpFileName, uint dwDesiredAccess,
        uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    // Overlapped ReadFile — lpNumberOfBytesRead must be IntPtr.Zero when lpOverlapped is used.
    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool ReadFile(SafeFileHandle hFile, byte[] lpBuffer,
        uint nNumberOfBytesToRead, IntPtr lpNumberOfBytesRead, ref OVERLAPPED lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool GetOverlappedResult(SafeFileHandle hFile,
        ref OVERLAPPED lpOverlapped, out uint lpNumberOfBytesTransferred, bool bWait);

    [DllImport("kernel32.dll")]
    internal static extern IntPtr CreateEvent(IntPtr lpEventAttributes, bool bManualReset,
        bool bInitialState, IntPtr lpName);

    [DllImport("kernel32.dll")]
    internal static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll")]
    internal static extern bool CancelIo(SafeFileHandle hFile);

    [DllImport("kernel32.dll")]
    internal static extern bool CloseHandle(IntPtr hObject);

    [DllImport("hid.dll", SetLastError = true)]
    internal static extern bool HidD_GetInputReport(SafeFileHandle HidDeviceObject,
        byte[] ReportBuffer, int ReportBufferLength);

    [DllImport("hid.dll", SetLastError = true)]
    internal static extern bool HidD_GetFeature(SafeFileHandle HidDeviceObject,
        byte[] ReportBuffer, int ReportBufferLength);

    [DllImport("hid.dll")]
    internal static extern bool HidD_GetPreparsedData(SafeFileHandle HidDeviceObject,
        out IntPtr PreparsedData);

    [DllImport("hid.dll")]
    internal static extern bool HidD_FreePreparsedData(IntPtr PreparsedData);

    [DllImport("hid.dll")]
    internal static extern int HidP_GetCaps(IntPtr PreparsedData, ref HIDP_CAPS Capabilities);

    [DllImport("hid.dll")]
    internal static extern int HidP_GetValueCaps(int ReportType,
        [In, Out] HIDP_VALUE_CAPS[] ValueCaps,
        ref ushort ValueCapsLength, IntPtr PreparsedData);

    [DllImport("setupapi.dll", SetLastError = true)]
    internal static extern IntPtr SetupDiGetClassDevs(ref Guid ClassGuid, string? Enumerator,
        IntPtr hwndParent, uint Flags);

    // Overload: null ClassGuid with enumerator string (DIGCF_ALLCLASSES required)
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern IntPtr SetupDiGetClassDevs(IntPtr ClassGuid, string Enumerator,
        IntPtr hwndParent, uint Flags);

    [DllImport("setupapi.dll", SetLastError = true)]
    internal static extern bool SetupDiEnumDeviceInterfaces(IntPtr DeviceInfoSet,
        IntPtr DeviceInfoData, ref Guid InterfaceClassGuid, uint MemberIndex,
        ref SP_DEVICE_INTERFACE_DATA DeviceInterfaceData);

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Auto)]
    internal static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr DeviceInfoSet,
        ref SP_DEVICE_INTERFACE_DATA DeviceInterfaceData,
        ref SP_DEVICE_INTERFACE_DETAIL_DATA DeviceInterfaceDetailData,
        uint DeviceInterfaceDetailDataSize, out uint RequiredSize,
        IntPtr DeviceInfoData);

    // Overload: captures SP_DEVINFO_DATA (devnode) alongside the interface detail
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Auto)]
    static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr DeviceInfoSet,
        ref SP_DEVICE_INTERFACE_DATA DeviceInterfaceData,
        ref SP_DEVICE_INTERFACE_DETAIL_DATA DeviceInterfaceDetailData,
        uint DeviceInterfaceDetailDataSize, out uint RequiredSize,
        ref SP_DEVINFO_DATA DeviceInfoData);

    [DllImport("setupapi.dll")]
    internal static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiEnumDeviceInfo(IntPtr DeviceInfoSet, uint MemberIndex,
        ref SP_DEVINFO_DATA DeviceInfoData);

    // cfgmgr32: read device instance ID string from devnode handle
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern uint CM_Get_Device_ID(uint dnDevInst, StringBuilder Buffer, uint BufferLen, uint ulFlags);

    // cfgmgr32: query devnode operational status flags
    [DllImport("cfgmgr32.dll")]
    static extern uint CM_Get_DevNode_Status(out uint pulStatus, out uint pulProblemNumber, uint dnDevInst, uint ulFlags);

    const uint DN_STARTED = 0x00000008; // driver start routine completed — device is running

    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVINFO_DATA
    {
        public uint cbSize;
        public Guid ClassGuid;
        public uint DevInst;
        public IntPtr Reserved;
    }

    // GUID_DEVCLASS_MOUSE — Mouse class devices created by mouhid.sys when it binds to HID device
    static readonly Guid MouseClassGuid = new("4d36e96f-e325-11ce-bfc1-08002be10318");

    // Returns true if a Mouse class device for the v3 Magic Mouse exists, is present,
    // AND has DN_STARTED set — meaning mouhid.sys has completed its start routine and
    // is actively processing input. Device node existence alone is not sufficient;
    // DN_STARTED is the empirical proof that the driver stack is operational.
    //
    // Note: uses DIGCF_PRESENT only (not DIGCF_DEVICEINTERFACE) — Mouse class devices
    // are device instances, not HID interface paths.
    internal static bool IsV3MouseClassPresent()
    {
        var guid = MouseClassGuid;
        var devs = SetupDiGetClassDevs(ref guid, null, IntPtr.Zero, DIGCF_PRESENT);
        if (devs == IntPtr.Zero || devs == INVALID_HANDLE_VALUE) return false;
        try
        {
            uint idx = 0;
            while (true)
            {
                var info = new SP_DEVINFO_DATA();
                info.cbSize = (uint)Marshal.SizeOf<SP_DEVINFO_DATA>();
                if (!SetupDiEnumDeviceInfo(devs, idx++, ref info)) break;

                // Instance ID directly contains VID/PID markers:
                // HID\{00001124-...}_VID&0001004C_PID&0323\A&31E5D054&1B&0000
                var idBuf = new StringBuilder(512);
                if (CM_Get_Device_ID(info.DevInst, idBuf, (uint)idBuf.Capacity, 0) != 0) continue;
                var id = idBuf.ToString().ToLowerInvariant();

                if (!((id.Contains("0001004c") && id.Contains("0323")) ||
                      (id.Contains("vid_05ac") && id.Contains("pid_0323"))))
                    continue;

                // Empirical proof: mouhid must have DN_STARTED — driver start routine complete.
                // Device node existing without DN_STARTED means mouhid is still initializing.
                CM_Get_DevNode_Status(out uint status, out _, info.DevInst, 0);
                if ((status & DN_STARTED) != 0)
                    return true;
            }
        }
        finally { SetupDiDestroyDeviceInfoList(devs); }
        return false;
    }

    // Returns true if the v3 Magic Mouse BTHENUM parent device has DN_STARTED set.
    // This is the pre-flip baseline check — if BTHENUM is not started before the flip,
    // the BT stack is already wedged and the cycle should be skipped.
    // Searches the BTHENUM enumerator directly (DIGCF_PRESENT|DIGCF_ALLCLASSES = 0x06),
    // independent of mouhid binding state.
    internal static bool IsV3BtStackHealthy()
    {
        const uint DIGCF_PRESENT_ALLCLASSES = 0x06;
        var devs = SetupDiGetClassDevs(IntPtr.Zero, "BTHENUM", IntPtr.Zero, DIGCF_PRESENT_ALLCLASSES);
        if (devs == IntPtr.Zero || devs == INVALID_HANDLE_VALUE) return false;
        try
        {
            uint idx = 0;
            while (true)
            {
                var info = new SP_DEVINFO_DATA();
                info.cbSize = (uint)Marshal.SizeOf<SP_DEVINFO_DATA>();
                if (!SetupDiEnumDeviceInfo(devs, idx++, ref info)) break;

                var idBuf = new StringBuilder(512);
                if (CM_Get_Device_ID(info.DevInst, idBuf, (uint)idBuf.Capacity, 0) != 0) continue;
                var id = idBuf.ToString().ToLowerInvariant();

                // Require HID service UUID {00001124} — avoids matching Generic Access
                // Profile {00001200} or other BTHENUM-enumerated profiles on the same device.
                if (!id.Contains("00001124")) continue;

                if (!((id.Contains("0001004c") && id.Contains("0323")) ||
                      (id.Contains("vid_05ac") && id.Contains("pid_0323"))))
                    continue;

                CM_Get_DevNode_Status(out uint status, out _, info.DevInst, 0);
                return (status & DN_STARTED) != 0;
            }
        }
        finally { SetupDiDestroyDeviceInfoList(devs); }
        return false;
    }

    // Returns true if applewirelessmouse is in LowerFilters for the v3 Magic Mouse BTHENUM
    // devnode. Reads directly from the registry — no SetupDi device enumeration, no DIGCF_PRESENT
    // dependency. LowerFilters is written by FLIP:AppleFilter BEFORE disable+enable, so it is
    // readable immediately after FLIP:AppleFilter exits, regardless of PnP device presence state.
    // This is the authoritative Mode B discriminator (confirmed 2026-05-07).
    internal static bool IsApplewirelessmouseInStack()
    {
        try
        {
            using var bthEnum = Registry.LocalMachine.OpenSubKey(
                @"SYSTEM\CurrentControlSet\Enum\BTHENUM");
            if (bthEnum is null) return false;

            foreach (var devIdName in bthEnum.GetSubKeyNames())
            {
                // Match HID service UUID {00001124} + Apple VID 004C PID 0323
                if (!devIdName.Contains("00001124", StringComparison.OrdinalIgnoreCase)) continue;
                if (!devIdName.Contains("0001004C", StringComparison.OrdinalIgnoreCase) &&
                    !devIdName.Contains("VID_05AC", StringComparison.OrdinalIgnoreCase)) continue;
                if (!devIdName.Contains("0323", StringComparison.OrdinalIgnoreCase)) continue;

                using var devIdKey = bthEnum.OpenSubKey(devIdName);
                if (devIdKey is null) continue;

                foreach (var instName in devIdKey.GetSubKeyNames())
                {
                    using var instKey = devIdKey.OpenSubKey(instName);
                    if (instKey is null) continue;
                    if (instKey.GetValue("LowerFilters") is string[] lf &&
                        lf.Any(f => f.IndexOf("applewireless", StringComparison.OrdinalIgnoreCase) >= 0))
                        return true;
                }
            }
        }
        catch { }
        return false;
    }

    // Returns true if the v3 col02 HID interface path exists AND its devnode has DN_STARTED.
    // col02 appearing in HID enumeration precedes HID class driver initialisation —
    // DN_STARTED is the empirical proof the stack is ready for HidD_GetInputReport.
    internal static bool IsV3Col02Ready()
    {
        var guid = HidGuid;
        var devs = SetupDiGetClassDevs(ref guid, null, IntPtr.Zero,
            DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (devs == IntPtr.Zero || devs == INVALID_HANDLE_VALUE) return false;
        try
        {
            uint index = 0;
            while (true)
            {
                var iface = new SP_DEVICE_INTERFACE_DATA();
                iface.cbSize = (uint)Marshal.SizeOf<SP_DEVICE_INTERFACE_DATA>();
                if (!SetupDiEnumDeviceInterfaces(devs, IntPtr.Zero, ref guid, index++, ref iface))
                    break;

                var detail = new SP_DEVICE_INTERFACE_DETAIL_DATA();
                detail.cbSize = IntPtr.Size == 8 ? 8u : 6u;
                var devInfo = new SP_DEVINFO_DATA();
                devInfo.cbSize = (uint)Marshal.SizeOf<SP_DEVINFO_DATA>();
                SetupDiGetDeviceInterfaceDetail(devs, ref iface, ref detail, 512, out _, ref devInfo);

                if (string.IsNullOrEmpty(detail.DevicePath)) continue;
                var p = detail.DevicePath;
                if (!p.Contains("col02", StringComparison.OrdinalIgnoreCase)) continue;
                if (!((p.Contains("0001004c", StringComparison.OrdinalIgnoreCase) &&
                       p.Contains("pid&0323", StringComparison.OrdinalIgnoreCase)) ||
                      (p.Contains("vid_05ac", StringComparison.OrdinalIgnoreCase) &&
                       p.Contains("pid_0323", StringComparison.OrdinalIgnoreCase))))
                    continue;

                CM_Get_DevNode_Status(out uint status, out _, devInfo.DevInst, 0);
                return (status & DN_STARTED) != 0;
            }
        }
        finally { SetupDiDestroyDeviceInfoList(devs); }
        return false;
    }

    // Enumerates all present HID device interface paths.
    internal static IEnumerable<string> EnumerateHidPaths()
    {
        var guid = HidGuid;
        var devs = SetupDiGetClassDevs(ref guid, null, IntPtr.Zero,
            DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (devs == IntPtr.Zero || devs == INVALID_HANDLE_VALUE)
            yield break;

        try
        {
            uint index = 0;
            while (true)
            {
                var iface = new SP_DEVICE_INTERFACE_DATA();
                iface.cbSize = (uint)Marshal.SizeOf<SP_DEVICE_INTERFACE_DATA>();
                if (!SetupDiEnumDeviceInterfaces(devs, IntPtr.Zero, ref guid, index++, ref iface))
                    yield break;

                var detail = new SP_DEVICE_INTERFACE_DETAIL_DATA();
                detail.cbSize = IntPtr.Size == 8 ? 8u : 6u;
                SetupDiGetDeviceInterfaceDetail(devs, ref iface, ref detail, 512,
                    out _, IntPtr.Zero);

                if (!string.IsNullOrEmpty(detail.DevicePath))
                    yield return detail.DevicePath;
            }
        }
        finally
        {
            SetupDiDestroyDeviceInfoList(devs);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct SP_DEVICE_INTERFACE_DATA
    {
        public uint cbSize;
        public Guid InterfaceClassGuid;
        public uint Flags;
        public IntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    internal struct SP_DEVICE_INTERFACE_DETAIL_DATA
    {
        public uint cbSize;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 512)]
        public string DevicePath;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct HIDP_CAPS
    {
        public ushort Usage;
        public ushort UsagePage;
        public ushort InputReportByteLength;
        public ushort OutputReportByteLength;
        public ushort FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)]
        public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes;
        public ushort NumberInputButtonCaps;
        public ushort NumberInputValueCaps;
        public ushort NumberInputDataIndices;
        public ushort NumberOutputButtonCaps;
        public ushort NumberOutputValueCaps;
        public ushort NumberOutputDataIndices;
        public ushort NumberFeatureButtonCaps;
        public ushort NumberFeatureValueCaps;
        public ushort NumberFeatureDataIndices;
    }

    // Must match Windows OVERLAPPED exactly: ULONG_PTR fields = 8 bytes on x64 (total 32 bytes).
    [StructLayout(LayoutKind.Sequential)]
    internal struct OVERLAPPED
    {
        public UIntPtr Internal;
        public UIntPtr InternalHigh;
        public uint Offset;
        public uint OffsetHigh;
        public IntPtr hEvent;
    }

    // Layout matches hidpi.h (Pack=4, 96 bytes on x64). Only IsRange=false fields used.
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    internal struct HIDP_VALUE_CAPS
    {
        public ushort UsagePage;
        public byte ReportID;
        [MarshalAs(UnmanagedType.U1)] public bool IsAlias;
        public ushort BitField;
        public ushort LinkCollection;
        public ushort LinkUsage;
        public ushort LinkUsagePage;
        [MarshalAs(UnmanagedType.U1)] public bool IsRange;
        [MarshalAs(UnmanagedType.U1)] public bool IsStringRange;
        [MarshalAs(UnmanagedType.U1)] public bool IsDesignatorRange;
        [MarshalAs(UnmanagedType.U1)] public bool IsAbsolute;
        [MarshalAs(UnmanagedType.U1)] public bool HasNull;
        public byte Reserved;
        public ushort BitSize;
        public ushort ReportCount;
        public ushort Reserved1, Reserved2, Reserved3, Reserved4, Reserved5;
        public uint UnitsExp;
        public uint Units;
        public int LogicalMin, LogicalMax;
        public int PhysicalMin, PhysicalMax;
        public ushort Usage;      // [NotRange] Usage (same slot as [Range] UsageMin)
        public ushort UsageMax;
        public ushort StringMin;
        public ushort StringMax;
        public ushort DesigMin;
        public ushort DesigMax;
        public ushort DataIdxMin;
        public ushort DataIdxMax;
    }
}
