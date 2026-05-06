// P/Invoke declarations for HID and SetupDi APIs shared across all device readers.
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace MagicMouseTray;

internal static class HidNative
{
    internal const uint FILE_SHARE_READ    = 0x00000001;
    internal const uint FILE_SHARE_WRITE   = 0x00000002;
    internal const uint OPEN_EXISTING      = 3;
    internal const uint DIGCF_PRESENT      = 0x02;
    internal const uint DIGCF_DEVICEINTERFACE = 0x10;
    internal const int  HIDP_STATUS_SUCCESS = 0x00110000;
    internal static readonly IntPtr INVALID_HANDLE_VALUE = new(-1);

    internal static readonly Guid HidGuid = new("4d1e55b2-f16f-11cf-88cb-001111000030");

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    internal static extern SafeFileHandle CreateFile(string lpFileName, uint dwDesiredAccess,
        uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);

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

    [DllImport("setupapi.dll")]
    internal static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiEnumDeviceInfo(IntPtr DeviceInfoSet, uint MemberIndex,
        ref SP_DEVINFO_DATA DeviceInfoData);

    // cfgmgr32: read device instance ID string from devnode handle
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern uint CM_Get_Device_ID(uint dnDevInst, StringBuilder Buffer, uint BufferLen, uint ulFlags);

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

    // Returns true if a Mouse class device with a v3 Magic Mouse instance ID exists and is present.
    // mouhid.sys creates a Mouse class device only after it successfully binds — this is the
    // definitive signal that cursor input is restored (unlike CreateFile which fires at PnP enumeration,
    // before mouhid has attached). The Mouse class device instance ID directly encodes VID/PID.
    //
    // Note: uses DIGCF_PRESENT only (not DIGCF_DEVICEINTERFACE) — Mouse class devices are device
    // instances, not HID interface paths. Using DIGCF_DEVICEINTERFACE returns an empty set.
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

                // The Mouse class device instance ID directly contains VID/PID markers.
                // e.g. HID\{00001124-...}_VID&0001004C_PID&0323\A&31E5D054&1B&0000
                var idBuf = new StringBuilder(512);
                if (CM_Get_Device_ID(info.DevInst, idBuf, (uint)idBuf.Capacity, 0) != 0) continue;
                var id = idBuf.ToString().ToLowerInvariant();

                if ((id.Contains("0001004c") && id.Contains("0323")) ||
                    (id.Contains("vid_05ac") && id.Contains("pid_0323")))
                    return true;
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
