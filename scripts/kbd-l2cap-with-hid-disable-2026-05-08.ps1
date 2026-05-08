# kbd-l2cap-with-hid-disable-2026-05-08.ps1
#
# End-to-end probe of the macOS battery flow on Windows:
#   1. Find the Apple keyboard via BluetoothFindFirstDevice.
#   2. Disable its HID profile via BluetoothSetServiceState
#      (HumanInterfaceDeviceServiceClass_UUID, BLUETOOTH_SERVICE_DISABLE).
#      This releases the in-box BT HID profile's hold on PSM 0x11.
#   3. Open a Winsock AF_BTH socket on PSM 0x11 (HID Control).
#   4. Send `53 4A 03` (SET_REPORT Feature, RID 0x4A, val 0x03) — the init.
#   5. Read handshake.
#   6. Send `43 47` (GET_REPORT Feature, RID 0x47).
#   7. Read response — last byte is battery %.
#   8. ALWAYS re-enable HID profile before exiting (try/finally).
#
# This is the wire-byte exact replica of what macOS does (see
# docs/M4-MAC-CAPTURE-FINDINGS-2026-05-08.md). It bypasses Windows'
# HidD_* RID validation by going below the HID class.
#
# WARNING: while HID is disabled the keyboard cannot type. The window
# is short (typically <1 second). If the script crashes/aborts, the
# keyboard may be stuck without HID — re-run the script (it forces
# re-enable in finally) or do it manually:
#
#   $hid = '00001124-0000-1000-8000-00805f9b34fb'
#   # via Settings > Bluetooth > Disconnect/Connect, or:
#   pnputil /restart-device "BTHENUM\Dev_E806884B0741"
#
# Run as Administrator.

$ErrorActionPreference = 'Stop'
$Out = Join-Path $PSScriptRoot 'kbd-l2cap-with-hid-disable.txt'
$log = @()
function L([string]$m) { $script:log += $m; Write-Host $m }

L "=== KB L2CAP w/ HID-disable PROBE $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
L ""

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    L "FATAL: must run as Administrator."
    $log | Set-Content -Path $Out -Encoding UTF8
    return
}

$KbdBdAddrStr = 'E8:06:88:4B:07:41'
$PSM_HID_CONTROL = 0x11

Add-Type -TypeDefinition @'
using System;
using System.Net.Sockets;
using System.Runtime.InteropServices;

// ---- Winsock AF_BTH ----
public static class L2cap {
    public const int AF_BTH         = 32;
    public const int SOCK_STREAM    = 1;
    public const int BTHPROTO_L2CAP = 0x100;

    [StructLayout(LayoutKind.Sequential)]
    public struct SOCKADDR_BTH {
        public ushort addressFamily;
        public ulong  btAddr;
        public Guid   serviceClassId;
        public uint   port;
    }

    [DllImport("ws2_32.dll", SetLastError=true)]
    public static extern int WSAStartup(ushort wVersionRequested, out WSADATA lpWSAData);
    [DllImport("ws2_32.dll", SetLastError=true)]
    public static extern int WSACleanup();
    [DllImport("ws2_32.dll", SetLastError=true)]
    public static extern IntPtr socket(int af, int type, int protocol);
    [DllImport("ws2_32.dll", SetLastError=true)]
    public static extern int connect(IntPtr s, ref SOCKADDR_BTH addr, int addrlen);
    [DllImport("ws2_32.dll", SetLastError=true)]
    public static extern int send(IntPtr s, byte[] buf, int len, int flags);
    [DllImport("ws2_32.dll", SetLastError=true)]
    public static extern int recv(IntPtr s, byte[] buf, int len, int flags);
    [DllImport("ws2_32.dll", SetLastError=true)]
    public static extern int closesocket(IntPtr s);
    [DllImport("ws2_32.dll", SetLastError=true)]
    public static extern int WSAGetLastError();
    [DllImport("ws2_32.dll", SetLastError=true)]
    public static extern int setsockopt(IntPtr s, int level, int optname,
        ref int optval, int optlen);

    public const int SOL_SOCKET   = 0xFFFF;
    public const int SO_RCVTIMEO  = 0x1006;
    public const int SO_SNDTIMEO  = 0x1005;

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)]
    public struct WSADATA {
        public short wVersion, wHighVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=257)] public string szDescription;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=129)] public string szSystemStatus;
        public ushort iMaxSockets, iMaxUdpDg;
        public IntPtr lpVendorInfo;
    }
}

// ---- BluetoothAPIs.h ----
public static class BtApi {
    public const uint BLUETOOTH_SERVICE_DISABLE = 0x00;
    public const uint BLUETOOTH_SERVICE_ENABLE  = 0x01;

    [StructLayout(LayoutKind.Sequential)]
    public struct BLUETOOTH_FIND_RADIO_PARAMS {
        public uint dwSize;
    }

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct BLUETOOTH_DEVICE_SEARCH_PARAMS {
        public uint   dwSize;
        public int    fReturnAuthenticated;
        public int    fReturnRemembered;
        public int    fReturnUnknown;
        public int    fReturnConnected;
        public int    fIssueInquiry;
        public byte   cTimeoutMultiplier;
        public IntPtr hRadio;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEMTIME {
        public ushort wYear, wMonth, wDayOfWeek, wDay, wHour, wMinute, wSecond, wMilliseconds;
    }

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct BLUETOOTH_DEVICE_INFO {
        public uint        dwSize;
        public ulong       Address;
        public uint        ulClassofDevice;
        public int         fConnected;
        public int         fRemembered;
        public int         fAuthenticated;
        public SYSTEMTIME  stLastSeen;
        public SYSTEMTIME  stLastUsed;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=248)] public string szName;
    }

    [DllImport("bthprops.cpl", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr BluetoothFindFirstRadio(
        ref BLUETOOTH_FIND_RADIO_PARAMS pbtfrp, out IntPtr phRadio);
    [DllImport("bthprops.cpl", SetLastError=true)]
    public static extern bool BluetoothFindRadioClose(IntPtr hFind);

    [DllImport("bthprops.cpl", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr BluetoothFindFirstDevice(
        ref BLUETOOTH_DEVICE_SEARCH_PARAMS pbtsp,
        ref BLUETOOTH_DEVICE_INFO pbtdi);
    [DllImport("bthprops.cpl", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool BluetoothFindNextDevice(IntPtr hFind,
        ref BLUETOOTH_DEVICE_INFO pbtdi);
    [DllImport("bthprops.cpl", SetLastError=true)]
    public static extern bool BluetoothFindDeviceClose(IntPtr hFind);

    [DllImport("bthprops.cpl", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern uint BluetoothSetServiceState(IntPtr hRadio,
        ref BLUETOOTH_DEVICE_INFO pbtdi,
        ref Guid pGuidService,
        uint dwServiceFlags);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr hObject);
}
'@ -ErrorAction Stop

# HumanInterfaceDeviceServiceClass_UUID
$HID_SERVICE_GUID = [Guid]'00001124-0000-1000-8000-00805F9B34FB'

function Hex([byte[]]$b, [int]$n) {
    $take = [Math]::Min($n, $b.Length)
    if ($take -le 0) { return '' }
    ((0..($take - 1)) | ForEach-Object { '{0:X2}' -f $b[$_] }) -join ' '
}

function ParseBdAddrToUlong([string]$s) {
    $bytes = ($s -split ':') | ForEach-Object { [Convert]::ToByte($_, 16) }
    if ($bytes.Length -ne 6) { throw "Bad BD addr: $s" }
    # BLUETOOTH_ADDRESS stores the 48-bit address in the low 6 bytes,
    # LSByte first (i.e. the rightmost pair of the colon form is byte 0).
    [ulong]$v = 0
    for ($i = 0; $i -lt 6; $i++) {
        $v = $v -bor ([ulong]$bytes[5 - $i] -shl (8 * $i))
    }
    return $v
}

# --- Find the radio + device --------------------------------------------------

$frp = New-Object BtApi+BLUETOOTH_FIND_RADIO_PARAMS
$frp.dwSize = [Runtime.InteropServices.Marshal]::SizeOf([Type]([BtApi+BLUETOOTH_FIND_RADIO_PARAMS]))
$hRadio = [IntPtr]::Zero
$hFindRadio = [BtApi]::BluetoothFindFirstRadio([ref]$frp, [ref]$hRadio)
if ($hFindRadio -eq [IntPtr]::Zero) {
    L "FATAL: no Bluetooth radio found (BluetoothFindFirstRadio err=$([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    $log | Set-Content -Path $Out -Encoding UTF8
    return
}
L "Bluetooth radio handle: 0x$('{0:X}' -f $hRadio.ToInt64())"

$searchParams = New-Object BtApi+BLUETOOTH_DEVICE_SEARCH_PARAMS
$searchParams.dwSize = [Runtime.InteropServices.Marshal]::SizeOf([Type]([BtApi+BLUETOOTH_DEVICE_SEARCH_PARAMS]))
$searchParams.fReturnAuthenticated = 1
$searchParams.fReturnRemembered    = 1
$searchParams.fReturnUnknown       = 0
$searchParams.fReturnConnected     = 1
$searchParams.fIssueInquiry        = 0
$searchParams.cTimeoutMultiplier   = 0
$searchParams.hRadio               = $hRadio

$devInfo = New-Object BtApi+BLUETOOTH_DEVICE_INFO
$devInfo.dwSize = [Runtime.InteropServices.Marshal]::SizeOf([Type]([BtApi+BLUETOOTH_DEVICE_INFO]))

$hFindDev = [BtApi]::BluetoothFindFirstDevice([ref]$searchParams, [ref]$devInfo)
if ($hFindDev -eq [IntPtr]::Zero) {
    L "FATAL: BluetoothFindFirstDevice failed err=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    [BtApi]::BluetoothFindRadioClose($hFindRadio) | Out-Null
    [BtApi]::CloseHandle($hRadio) | Out-Null
    $log | Set-Content -Path $Out -Encoding UTF8
    return
}

$targetAddrUlong = ParseBdAddrToUlong $KbdBdAddrStr
L "Looking for BD address: $KbdBdAddrStr (ulong: 0x$('{0:X12}' -f $targetAddrUlong))"

$found = $false
do {
    L ("  device: addr=0x{0:X12} name='{1}' connected={2} authenticated={3}" -f `
        $devInfo.Address, $devInfo.szName.Trim(), $devInfo.fConnected, $devInfo.fAuthenticated)
    if ($devInfo.Address -eq $targetAddrUlong) {
        $found = $true
        break
    }
} while ([BtApi]::BluetoothFindNextDevice($hFindDev, [ref]$devInfo))

[BtApi]::BluetoothFindDeviceClose($hFindDev) | Out-Null

if (-not $found) {
    L "FATAL: keyboard $KbdBdAddrStr not in device list. Is it paired?"
    [BtApi]::BluetoothFindRadioClose($hFindRadio) | Out-Null
    [BtApi]::CloseHandle($hRadio) | Out-Null
    $log | Set-Content -Path $Out -Encoding UTF8
    return
}
L "Found keyboard: $($devInfo.szName.Trim())"
L ""

# --- Disable HID profile so we can grab PSM 0x11 ---------------------------

$hidGuid = $HID_SERVICE_GUID
$hidDisabled = $false

try {
    L "Disabling HID profile on the device..."
    $rc = [BtApi]::BluetoothSetServiceState($hRadio, [ref]$devInfo, [ref]$hidGuid,
        [BtApi]::BLUETOOTH_SERVICE_DISABLE)
    if ($rc -ne 0) {
        L "BluetoothSetServiceState(DISABLE) returned $rc — aborting probe."
        L "(0x80070005 = ACCESS_DENIED, run as Admin; 0x8007048F = device-not-connected.)"
        return
    }
    $hidDisabled = $true
    L "HID profile disabled. Sleeping 1.5s for the channel to be released..."
    Start-Sleep -Milliseconds 1500

    # --- Winsock init + L2CAP connect ------------------------------------

    $wsa = New-Object L2cap+WSADATA
    if ([L2cap]::WSAStartup([ushort]0x202, [ref]$wsa) -ne 0) {
        L "WSAStartup FAILED"
        return
    }

    $sock = [L2cap]::socket([L2cap]::AF_BTH, [L2cap]::SOCK_STREAM, [L2cap]::BTHPROTO_L2CAP)
    if ($sock -eq [IntPtr](-1) -or $sock -eq [IntPtr]::Zero) {
        L "socket() FAILED err=$([L2cap]::WSAGetLastError())"
        [L2cap]::WSACleanup() | Out-Null
        return
    }

    # Set 5s recv/send timeouts so a misbehaving firmware can't hang the script
    # with HID disabled. If recv times out we surface WSAETIMEDOUT (10060) and
    # the finally block re-enables HID — keyboard usable again within seconds.
    $timeoutMs = 5000
    [L2cap]::setsockopt($sock, [L2cap]::SOL_SOCKET, [L2cap]::SO_RCVTIMEO, [ref]$timeoutMs, 4) | Out-Null
    [L2cap]::setsockopt($sock, [L2cap]::SOL_SOCKET, [L2cap]::SO_SNDTIMEO, [ref]$timeoutMs, 4) | Out-Null

    $sa = New-Object L2cap+SOCKADDR_BTH
    $sa.addressFamily  = [ushort][L2cap]::AF_BTH
    $sa.btAddr         = [ulong]$targetAddrUlong
    $sa.serviceClassId = [Guid]::Empty
    $sa.port           = [uint32]$PSM_HID_CONTROL
    $sasize = [Runtime.InteropServices.Marshal]::SizeOf([Type]([L2cap+SOCKADDR_BTH]))

    L "connect(BD=$KbdBdAddrStr, PSM=0x11)..."
    $cr = [L2cap]::connect($sock, [ref]$sa, $sasize)
    if ($cr -ne 0) {
        $err = [L2cap]::WSAGetLastError()
        $name = switch ($err) {
            10013 { 'WSAEACCES (still owned somehow)' }
            10048 { 'WSAEADDRINUSE' }
            10050 { 'WSAENETDOWN' }
            10060 { 'WSAETIMEDOUT' }
            10061 { 'WSAECONNREFUSED (firmware refused channel — interesting)' }
            10064 { 'WSAEHOSTDOWN (keyboard asleep — wake it and rerun)' }
            default { '' }
        }
        L "connect() FAILED err=$err  $name"
        [L2cap]::closesocket($sock) | Out-Null
        [L2cap]::WSACleanup() | Out-Null
        return
    }
    L "*** L2CAP CONNECTED on PSM 0x11 ***"
    L ""

    # --- 1. SET_REPORT Feature RID 0x4A, val 0x03 ------------------------

    $initBytes = [byte[]]@(0x53, 0x4A, 0x03)
    L "Sending init: [$(Hex $initBytes 3)]"
    $ns = [L2cap]::send($sock, $initBytes, $initBytes.Length, 0)
    if ($ns -ne $initBytes.Length) {
        L "send(init) failed err=$([L2cap]::WSAGetLastError())"
    } else {
        $rb = New-Object byte[] 32
        $nr = [L2cap]::recv($sock, $rb, $rb.Length, 0)
        if ($nr -le 0) {
            L "recv(handshake) returned $nr  err=$([L2cap]::WSAGetLastError())"
        } else {
            L "Handshake: [$(Hex $rb $nr)]  $(if ($rb[0] -eq 0x00) { '(Successful)' } else { '(code 0x' + ('{0:X2}' -f $rb[0]) + ')' })"
        }
    }

    # --- 2. GET_REPORT Feature RID 0x47 (BATTERY LEVEL) -----------------
    # PacketLogger labels the response "BATTERY LEVEL <pct>%" — see
    # docs/M4-MAC-CAPTURE-FINDINGS-2026-05-08.md.

    $queryBytes = [byte[]]@(0x43, 0x47)
    L ""
    L "Sending battery query (Feature RID 0x47): [$(Hex $queryBytes 2)]"
    $ns2 = [L2cap]::send($sock, $queryBytes, $queryBytes.Length, 0)
    if ($ns2 -ne $queryBytes.Length) {
        L "send(query) failed err=$([L2cap]::WSAGetLastError())"
    } else {
        $rb2 = New-Object byte[] 32
        $nr2 = [L2cap]::recv($sock, $rb2, $rb2.Length, 0)
        if ($nr2 -le 0) {
            L "recv(battery) returned $nr2  err=$([L2cap]::WSAGetLastError())"
        } else {
            L "Battery LEVEL response ($nr2 bytes): [$(Hex $rb2 $nr2)]"
            if ($nr2 -ge 3 -and $rb2[0] -eq 0xA3 -and $rb2[1] -eq 0x47) {
                L ""
                L "*** BATTERY LEVEL: $($rb2[2])% ***"
            } elseif ($nr2 -ge 1) {
                L "  unexpected response shape; first byte = 0x$('{0:X2}' -f $rb2[0])"
            }
        }
    }

    # --- 3. GET_REPORT Input RID 0x30 (BATTERY STATUS / WARNING) -------
    # PacketLogger labels the response "BATTERY STATUS OK" when value=0,
    # presumably "BATTERY LEVEL WARNING" when non-zero (low battery).
    # macOS polls this alongside RID 0x47 every 60 s.

    $statusBytes = [byte[]]@(0x41, 0x30)
    L ""
    L "Sending battery status query (Input RID 0x30): [$(Hex $statusBytes 2)]"
    $ns3 = [L2cap]::send($sock, $statusBytes, $statusBytes.Length, 0)
    if ($ns3 -ne $statusBytes.Length) {
        L "send(status query) failed err=$([L2cap]::WSAGetLastError())"
    } else {
        $rb3 = New-Object byte[] 32
        $nr3 = [L2cap]::recv($sock, $rb3, $rb3.Length, 0)
        if ($nr3 -le 0) {
            L "recv(status) returned $nr3  err=$([L2cap]::WSAGetLastError())"
        } else {
            L "Battery STATUS response ($nr3 bytes): [$(Hex $rb3 $nr3)]"
            if ($nr3 -ge 3 -and $rb3[0] -eq 0xA1 -and $rb3[1] -eq 0x30) {
                $statusByte = $rb3[2]
                $statusText = if ($statusByte -eq 0) { 'OK' } else { "WARNING (0x$('{0:X2}' -f $statusByte))" }
                L "*** BATTERY STATUS: $statusText ***"
            }
        }
    }

    [L2cap]::closesocket($sock) | Out-Null
    [L2cap]::WSACleanup() | Out-Null
}
finally {
    if ($hidDisabled) {
        L ""
        L "Re-enabling HID profile..."
        $rc2 = [BtApi]::BluetoothSetServiceState($hRadio, [ref]$devInfo, [ref]$hidGuid,
            [BtApi]::BLUETOOTH_SERVICE_ENABLE)
        if ($rc2 -ne 0) {
            L "BluetoothSetServiceState(ENABLE) returned $rc2 — KEYBOARD MAY BE UNUSABLE."
            L "Manual fix: Settings > Devices > Bluetooth > unpair/repair the keyboard,"
            L "or run: pnputil /restart-device 'BTHENUM\Dev_$($KbdBdAddrStr -replace '[:]','')'"
        } else {
            L "HID profile re-enabled."
        }
    }
    [BtApi]::BluetoothFindRadioClose($hFindRadio) | Out-Null
    [BtApi]::CloseHandle($hRadio) | Out-Null
}

$log | Set-Content -Path $Out -Encoding UTF8
L ""
L "=== DONE - saved to $Out ==="
