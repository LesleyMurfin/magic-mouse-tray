# kbd-raw-l2cap-2026-05-08.ps1
#
# Replicate macOS's exact wire flow for Apple keyboard battery on Windows
# by going around the HID class driver and talking directly to L2CAP HID
# Control (PSM 0x11) via Winsock AF_BTH.
#
# macOS HCI capture (docs/M4-MAC-CAPTURE-FINDINGS-2026-05-08.md) shows:
#   On connect:  host->kbd  53 4A 03   (SET_REPORT Feature, RID 0x4A, val 0x03)
#                kbd->host  00         (HANDSHAKE Successful)
#   Every 60s:   host->kbd  43 47      (GET_REPORT Feature, RID 0x47)
#                kbd->host  A3 47 ??   (DATA Feature, RID 0x47, value=battery%)
#
# Both RID 0x4A and the Feature variant of 0x47 are absent from the public
# HID descriptor, which is why all Windows HidD_* attempts fail (Windows
# validates the RID against the descriptor before sending). Going below
# the HID class via raw L2CAP bypasses that validation.
#
# Caveat: the Windows in-box BT HID profile owns PSM 0x11 for a paired HID
# device. Opening a second L2CAP socket on it usually fails with
# WSAEADDRINUSE / ERROR_SHARING_VIOLATION. This script tries it anyway,
# and if it fails, prints the diagnostic so we know whether the next
# step is BluetoothSetServiceState (HID-disable) or a kernel filter
# driver.
#
# Run as Administrator. Keyboard must be paired. PROBE: makes one
# connect attempt + one query; will not loop or stress the device.

$ErrorActionPreference = 'Stop'
$Out = Join-Path $PSScriptRoot 'kbd-raw-l2cap.txt'
$log = @()
function L([string]$m) { $script:log += $m; Write-Host $m }
L "=== KB RAW L2CAP PROBE $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
L ""

# Keyboard's BD address (Lesley's keyboard, observed on Mac):
$KbdBdAddr = 'E8:06:88:4B:07:41'
$PSM_HID_CONTROL = 0x11   # BT HID Control L2CAP PSM

L "Target: $KbdBdAddr  PSM: 0x$('{0:X2}' -f $PSM_HID_CONTROL) (HID Control)"
L ""

Add-Type -TypeDefinition @'
using System;
using System.Net.Sockets;
using System.Runtime.InteropServices;

public static class L2cap {
    public const int AF_BTH         = 32;
    public const int SOCK_STREAM    = 1;
    public const int BTHPROTO_L2CAP = 0x100;

    [StructLayout(LayoutKind.Sequential)]
    public struct SOCKADDR_BTH {
        public ushort addressFamily;       // AF_BTH
        public ulong  btAddr;              // 6-byte BD addr in low 48 bits
        public Guid   serviceClassId;      // unused for L2CAP-by-PSM
        public uint   port;                // PSM
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

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)]
    public struct WSADATA {
        public short wVersion, wHighVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=257)] public string szDescription;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=129)] public string szSystemStatus;
        public ushort iMaxSockets, iMaxUdpDg;
        public IntPtr lpVendorInfo;
    }
}
'@ -ErrorAction Stop

function Hex([byte[]]$b, [int]$n) {
    $take = [Math]::Min($n, $b.Length)
    ((0..($take-1)) | ForEach-Object { '{0:X2}' -f $b[$_] }) -join ' '
}

function ParseBdAddr([string]$s) {
    $bytes = ($s -split ':') | ForEach-Object { [Convert]::ToByte($_, 16) }
    if ($bytes.Length -ne 6) { throw "Bad BD addr: $s" }
    # Pack as little-endian 48-bit ulong (Microsoft docs: byte 0 = LSByte)
    [ulong]$v = 0
    for ($i = 0; $i -lt 6; $i++) {
        $v = $v -bor ([ulong]$bytes[$i] -shl (8 * (5 - $i)))
    }
    return $v
}

# --- Init Winsock ---
$wsa = New-Object L2cap+WSADATA
$rc  = [L2cap]::WSAStartup([ushort]0x202, [ref]$wsa)
if ($rc -ne 0) { L "WSAStartup FAILED rc=$rc"; $log | Set-Content $Out -Encoding UTF8; return }
L "Winsock initialized: $($wsa.szDescription.Trim())"

# --- Socket ---
$sock = [L2cap]::socket([L2cap]::AF_BTH, [L2cap]::SOCK_STREAM, [L2cap]::BTHPROTO_L2CAP)
if ($sock -eq [IntPtr](-1) -or $sock -eq [IntPtr]::Zero) {
    L "socket() FAILED err=$([L2cap]::WSAGetLastError())"
    [L2cap]::WSACleanup() | Out-Null
    $log | Set-Content $Out -Encoding UTF8; return
}
L "Socket created."

# --- Connect ---
$addr = New-Object L2cap+SOCKADDR_BTH
$addr.addressFamily  = [ushort][L2cap]::AF_BTH
$addr.btAddr         = ParseBdAddr $KbdBdAddr
$addr.serviceClassId = [Guid]::Empty
$addr.port           = [uint32]$PSM_HID_CONTROL

$size = [Runtime.InteropServices.Marshal]::SizeOf([Type]([L2cap+SOCKADDR_BTH]))
L "connect(BD=$KbdBdAddr, PSM=0x$('{0:X2}' -f $PSM_HID_CONTROL))..."
$cr = [L2cap]::connect($sock, [ref]$addr, $size)
if ($cr -ne 0) {
    $err = [L2cap]::WSAGetLastError()
    $errName = switch ($err) {
        10013 { 'WSAEACCES (PSM owned by HID class — try BluetoothSetServiceState to disable HID first)' }
        10048 { 'WSAEADDRINUSE (channel already in use)' }
        10050 { 'WSAENETDOWN (BT radio off?)' }
        10060 { 'WSAETIMEDOUT' }
        10061 { 'WSAECONNREFUSED' }
        10064 { 'WSAEHOSTDOWN (keyboard not advertising — wake it)' }
        default { '' }
    }
    L "connect() FAILED err=$err  $errName"
    L ""
    L "Most common outcome: WSAEACCES because the in-box HID profile owns PSM 0x11."
    L "Next step: programmatically disable the BT HID profile for this device"
    L "(BluetoothSetServiceState with HumanInterfaceDeviceServiceClass_UUID),"
    L "retry connect, then re-enable HID after our query completes."
    [L2cap]::closesocket($sock) | Out-Null
    [L2cap]::WSACleanup() | Out-Null
    $log | Set-Content $Out -Encoding UTF8; return
}
L "*** L2CAP CONNECTED ***"
L ""

# --- Init: SET_REPORT Feature, RID 0x4A, val 0x03 ---
$initBytes = [byte[]]@(0x53, 0x4A, 0x03)
L "Sending init: [$(Hex $initBytes 3)]"
$ns = [L2cap]::send($sock, $initBytes, $initBytes.Length, 0)
if ($ns -ne $initBytes.Length) {
    L "send(init) failed err=$([L2cap]::WSAGetLastError())"
} else {
    L "init sent ($ns bytes)"
}

# --- Read handshake ---
$rb = New-Object byte[] 32
$nr = [L2cap]::recv($sock, $rb, $rb.Length, 0)
if ($nr -lt 0) {
    L "recv(handshake) failed err=$([L2cap]::WSAGetLastError())"
} elseif ($nr -eq 0) {
    L "recv(handshake) returned 0 (peer closed)"
} else {
    L "Handshake recv ($nr bytes): [$(Hex $rb $nr)]"
    if ($rb[0] -eq 0x00) { L "  HANDSHAKE Successful" }
    else { L "  HANDSHAKE result code = 0x$('{0:X2}' -f $rb[0])" }
}

# --- Query: GET_REPORT Feature, RID 0x47 ---
$queryBytes = [byte[]]@(0x43, 0x47)
L ""
L "Sending battery query: [$(Hex $queryBytes 2)]"
$ns2 = [L2cap]::send($sock, $queryBytes, $queryBytes.Length, 0)
L "query sent ($ns2 bytes)"

$rb2 = New-Object byte[] 32
$nr2 = [L2cap]::recv($sock, $rb2, $rb2.Length, 0)
if ($nr2 -lt 0) {
    L "recv(battery) failed err=$([L2cap]::WSAGetLastError())"
} elseif ($nr2 -eq 0) {
    L "recv(battery) returned 0"
} else {
    L "Battery response ($nr2 bytes): [$(Hex $rb2 $nr2)]"
    # Expect: A3 47 <pct>
    if ($nr2 -ge 3 -and $rb2[0] -eq 0xA3 -and $rb2[1] -eq 0x47) {
        L ""
        L "*** BATTERY: $($rb2[2])% ***"
    } else {
        L "  unexpected response shape (wanted A3 47 <pct>)"
    }
}

[L2cap]::closesocket($sock) | Out-Null
[L2cap]::WSACleanup() | Out-Null
L ""
$log | Set-Content $Out -Encoding UTF8
L "=== DONE - saved to $Out ==="
