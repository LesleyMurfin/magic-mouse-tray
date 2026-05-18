# postpatch-stack-snapshot-2026-05-08.ps1
# Driver-stack snapshot for all three Apple HID devices.
# Captures: BTHENUM LowerFilters, DEVPKEY_Device_Stack, service states.
# Run before AND after the patch lands; diff to see exactly what changed.
#
# Goal: confirm the new keyboard filter (MagicKbDesc) is bound to the keyboard
#       and the new Apple driver patch is bound to the v3 mouse, while
#       the existing applewirelessmouse arrangement on v3 (or its replacement)
#       is correctly in place.

$OutDir = '\\wsl.localhost\Ubuntu\home\lesley\projects\Personal\magic-mouse-tray\.ai\test-runs\2026-05-08-postpatch'
$OutTxt = Join-Path $OutDir 'stack-snapshot.txt'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$log = @()
function L([string]$m) { $script:log += $m; Write-Host $m }

L "=== STACK SNAPSHOT $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
L ""

# Devices of interest by VID/PID pattern.
$DEVICES = @(
    @{ Name = "v1 Magic Mouse"; VidPid = "VID_05AC&PID_030D"; BthVidPid = "VID&000205AC_PID&030D" },
    @{ Name = "v3 Magic Mouse"; VidPid = "VID_004C&PID_0323"; BthVidPid = "VID&0001004C_PID&0323" },
    @{ Name = "Apple Keyboard"; VidPid = "VID_05AC&PID_0239"; BthVidPid = "VID&000205AC_PID&0239" }
)

# Services to check (current + likely new patcher names).
$SERVICES = @(
    'applewirelessmouse',  # current v3 mouse filter
    'MagicKbDesc',         # rumored new keyboard filter name
    'AppleHIDPatcher',     # speculative new patcher name
    'HidBth',              # standard BT HID
    'BTHPORT',             # BT port
    'BTHUSB'               # BT USB
)

# --- 1. Service states ---
L "--- SERVICE STATES ---"
foreach ($svc in $SERVICES) {
    $s = sc.exe query $svc 2>&1
    $state = ($s | Select-String 'STATE') -join ' '
    if ($state) {
        L "  ${svc}: $state"
    } else {
        L "  ${svc}: (not installed)"
    }
}
L ""

# --- 2. PnP devices and their driver stacks ---
L "--- DEVICE DRIVER STACKS ---"
foreach ($dev in $DEVICES) {
    L ""
    L "### $($dev.Name) ($($dev.VidPid)) ###"

    $pnpList = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
        $_.InstanceId -match $dev.BthVidPid -or $_.InstanceId -match $dev.VidPid
    }

    if (-not $pnpList) {
        L "  NOT PRESENT"
        continue
    }

    foreach ($pnp in $pnpList) {
        L "  Instance: $($pnp.InstanceId)"
        L "    FriendlyName : $($pnp.FriendlyName)"
        L "    Class        : $($pnp.Class)"
        L "    Status       : $($pnp.Status)"

        $stack = Get-PnpDeviceProperty -InstanceId $pnp.InstanceId -KeyName 'DEVPKEY_Device_Stack' -ErrorAction SilentlyContinue
        if ($stack) {
            L "    Stack:"
            $stack.Data | ForEach-Object { L "      - $_" }
        }

        $service = Get-PnpDeviceProperty -InstanceId $pnp.InstanceId -KeyName 'DEVPKEY_Device_Service' -ErrorAction SilentlyContinue
        if ($service) { L "    Service: $($service.Data)" }

        $lowerFil = Get-PnpDeviceProperty -InstanceId $pnp.InstanceId -KeyName 'DEVPKEY_Device_LowerFilters' -ErrorAction SilentlyContinue
        if ($lowerFil -and $lowerFil.Data) { L "    LowerFilters: $($lowerFil.Data -join ', ')" }

        $upperFil = Get-PnpDeviceProperty -InstanceId $pnp.InstanceId -KeyName 'DEVPKEY_Device_UpperFilters' -ErrorAction SilentlyContinue
        if ($upperFil -and $upperFil.Data) { L "    UpperFilters: $($upperFil.Data -join ', ')" }
    }
}

# --- 3. Registry LowerFilter references for BTHENUM nodes ---
L ""
L "--- BTHENUM REGISTRY LowerFilters (Enum key, the persistent reference) ---"
foreach ($dev in $DEVICES) {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\BTHENUM"
    $matches = Get-ChildItem $regPath -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $dev.BthVidPid }
    foreach ($m in $matches) {
        $devParams = Join-Path $m.PSPath 'Device Parameters'
        $lf = (Get-ItemProperty $devParams -Name LowerFilters -ErrorAction SilentlyContinue).LowerFilters
        $sub = $m.PSChildName
        L "  $($dev.Name) / $sub :  LowerFilters = $($lf -join ', ')"
    }
}

L ""
L "Saved: $OutTxt"
$log | Set-Content -Path $OutTxt -Encoding UTF8
