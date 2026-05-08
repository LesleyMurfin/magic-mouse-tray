# kbd-container-bt-2026-05-07.ps1
# Part A: Query DeviceContainer by exact ContainerID for BatteryLife
# Part B: BluetoothDevice.FromBluetoothAddressAsync by MAC address
# Part C: Try HidD_GetFeature as admin (elevated)

$Out = '\\wsl.localhost\Ubuntu\home\lesley\projects\Personal\magic-mouse-tray\.ai\test-runs\2026-05-07-kbd-battery-probe\container-bt.txt'
$log = @()
function L([string]$m) { $script:log += $m; Write-Host $m }
L "=== KB CONTAINER+BT PROBE $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
L ""

Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop

function Invoke-Async($async, [type]$t) {
    $asTaskMethods = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 1 }
    $task = ($asTaskMethods | Select-Object -First 1).MakeGenericMethod($t).Invoke($null, @($async))
    if (-not $task.Wait(10000)) { throw "Timeout" }
    return $task.Result
}

# ---- PART A: DeviceContainer by exact ContainerID ----------------------------
L "=== PART A: DeviceContainer by ContainerID {49C4A341-7DBD-5FB0-9F4A-84FA5AB58E77} ==="
try {
    $null = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType=WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DeviceInformationKind, Windows.Devices.Enumeration, ContentType=WindowsRuntime]

    $propKeys = [string[]]@("System.Devices.BatteryLife","System.Devices.BatteryPlusOfTotal","System.Devices.Connected","System.Devices.Manufacturer")
    $selector = 'System.Devices.ContainerId:="{49C4A341-7DBD-5FB0-9F4A-84FA5AB58E77}"'
    $kind = [Windows.Devices.Enumeration.DeviceInformationKind]::DeviceContainer
    $async = [Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($selector, $propKeys, $kind)
    $devs = Invoke-Async $async ([Windows.Devices.Enumeration.DeviceInformationCollection])
    L "  Container results: $($devs.Count)"
    foreach ($d in $devs) {
        L "  Container: '$($d.Name)' Id=$($d.Id)"
        foreach ($k in $propKeys) {
            $v = $null; $d.Properties.TryGetValue($k, [ref]$v) | Out-Null
            L "    $k = $v"
        }
    }
} catch { L "  ERROR: $($_.Exception.Message -replace '\r?\n',' ')" }

# ---- PART B: BluetoothDevice by address -------------------------------------------
L ""
L "=== PART B: BluetoothDevice.FromBluetoothAddressAsync ==="
try {
    $null = [Windows.Devices.Bluetooth.BluetoothDevice, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]

    # MAC E8:06:88:4B:07:41 = 0xE806884B0741
    $addr = [ulong]0xE806884B0741

    $async = [Windows.Devices.Bluetooth.BluetoothDevice]::FromBluetoothAddressAsync($addr)
    $btDev = Invoke-Async $async ([Windows.Devices.Bluetooth.BluetoothDevice])

    if ($btDev -eq $null) { L "  Device not found for address 0xE806884B0741"; }
    else {
        L "  Found: '$($btDev.Name)' ClassOfDevice=$($btDev.ClassOfDevice.RawValue)"
        L "  DeviceId: $($btDev.DeviceId)"

        # Try to get battery via DeviceInformation for this device's ID
        $propKeys2 = [string[]]@("System.Devices.BatteryLife","System.Devices.Connected","System.Devices.BatteryPlusOfTotal")
        $diAsync = [Windows.Devices.Enumeration.DeviceInformation]::CreateFromIdAsync($btDev.DeviceId, $propKeys2)
        $di = Invoke-Async $diAsync ([Windows.Devices.Enumeration.DeviceInformation])
        L "  DeviceInformation: '$($di.Name)'"
        foreach ($k in $propKeys2) {
            $v = $null; $di.Properties.TryGetValue($k, [ref]$v) | Out-Null
            L "    $k = $v"
        }

        # Check GATT services if BLE-capable
        try {
            $null = [Windows.Devices.Bluetooth.BluetoothLEDevice, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]
            $leAsync = [Windows.Devices.Bluetooth.BluetoothLEDevice]::FromBluetoothAddressAsync($addr)
            $leDev = Invoke-Async $leAsync ([Windows.Devices.Bluetooth.BluetoothLEDevice])
            if ($leDev -ne $null) {
                L "  BLE device found: '$($leDev.Name)'"
                $null = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattDeviceServicesResult, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]
                $svcAsync = $leDev.GetGattServicesAsync()
                $svcResult = Invoke-Async $svcAsync ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattDeviceServicesResult])
                L "  GATT status: $($svcResult.Status) Services: $($svcResult.Services.Count)"
                foreach ($svc in $svcResult.Services) {
                    L "    Service: $($svc.Uuid)"
                    # 0000180f = Battery Service
                    if ($svc.Uuid.ToString() -like '*180f*') {
                        L "    *** BATTERY SERVICE FOUND ***"
                        $charAsync = $svc.GetCharacteristicsAsync()
                        $charResult = Invoke-Async $charAsync ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicsResult])
                        foreach ($c in $charResult.Characteristics) {
                            L "      Char: $($c.Uuid)"
                            $readAsync = $c.ReadValueAsync()
                            $readResult = Invoke-Async $readAsync ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattReadResult])
                            if ($readResult.Status -eq 0) {
                                $reader = [Windows.Storage.Streams.DataReader]::FromBuffer($readResult.Value)
                                $b = $reader.ReadByte()
                                L "      BATTERY VALUE = $b%"
                            }
                        }
                    }
                }
            } else { L "  Not a BLE device (no BLE counterpart found)" }
        } catch { L "  BLE check error: $($_.Exception.Message -replace '\r?\n',' ')" }
    }
} catch { L "  ERROR: $($_.Exception.Message -replace '\r?\n',' ')" }

# ---- PART C: Check if app is elevated ----------------------------------------
L ""
L "=== PART C: Elevation check ==="
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
L "  Running as admin: $isAdmin"
if (-not $isAdmin) { L "  (Re-run as admin to test elevated GetFeature)" }

$log | Set-Content -Path $Out -Encoding UTF8
L ""
L "=== DONE - saved to $Out ==="
