# kbd-ble-gatt-2026-05-07.ps1
# Check if keyboard has BLE counterpart and GATT Battery Service (0x180F).
# Also scan all DeviceContainers for our keyboard's ContainerId battery property.

$Out = '\\wsl.localhost\Ubuntu\home\lesley\projects\Personal\magic-mouse-tray\.ai\test-runs\2026-05-07-kbd-battery-probe\ble-gatt.txt'
$log = @()
function L([string]$m) { $script:log += $m; Write-Host $m }
L "=== KB BLE/GATT PROBE $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
L ""

Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop

function Invoke-WinRtAsync($async, [type]$resultType) {
    $methods = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 1 }
    $task = ($methods | Select-Object -First 1).MakeGenericMethod($resultType).Invoke($null, @($async))
    if (-not $task.Wait(10000)) { throw "Timeout" }
    return $task.Result
}

# ---- PART A: DeviceContainer scan for keyboard ContainerId -------------------
L "=== PART A: DeviceContainer BatteryLife for ContainerId {49C4A341-7DBD-5FB0-9F4A-84FA5AB58E77} ==="
try {
    $null = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType=WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DeviceInformationKind, Windows.Devices.Enumeration, ContentType=WindowsRuntime]

    $propKeys = [string[]]@("System.Devices.BatteryLife","System.Devices.BatteryPlusOfTotal","System.Devices.Connected","System.ItemNameDisplay")
    $kind = [Windows.Devices.Enumeration.DeviceInformationKind]::DeviceContainer
    $async = [Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync("", $propKeys, $kind)
    $all = Invoke-WinRtAsync $async ([Windows.Devices.Enumeration.DeviceInformationCollection])
    L "  Total containers: $($all.Count)"

    $targetId = "{49c4a341-7dbd-5fb0-9f4a-84fa5ab58e77}"
    foreach ($d in $all) {
        if ($d.Id.ToLower() -ne $targetId) { continue }
        L "  FOUND keyboard container: '$($d.Name)'"
        foreach ($k in $propKeys) {
            $v = $null; $d.Properties.TryGetValue($k, [ref]$v) | Out-Null
            L "    $k = $v"
        }
    }
} catch { L "  ERROR: $($_.Exception.Message -replace '\r?\n',' ')" }

# ---- PART B: BluetoothDevice by address --------------------------------------
L ""
L "=== PART B: BluetoothDevice + BLE GATT Battery Service ==="
try {
    $null = [Windows.Devices.Bluetooth.BluetoothDevice, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]
    $null = [Windows.Devices.Bluetooth.BluetoothLEDevice, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]

    # MAC: E8:06:88:4B:07:41  -- from BTHENUM instance E806884B0741
    $addr = [System.UInt64]0xE806884B0741

    L "  Trying BluetoothDevice (Classic BT)..."
    $async = [Windows.Devices.Bluetooth.BluetoothDevice]::FromBluetoothAddressAsync($addr)
    $btDev = Invoke-WinRtAsync $async ([Windows.Devices.Bluetooth.BluetoothDevice])
    if ($btDev -ne $null) {
        L "  Classic BT found: '$($btDev.Name)' DeviceId=$($btDev.DeviceId)"
        # Read BatteryLife via DeviceInformation
        $propKeys2 = [string[]]@("System.Devices.BatteryLife","System.Devices.Connected","System.Devices.BatteryPlusOfTotal")
        $diAsync = [Windows.Devices.Enumeration.DeviceInformation]::CreateFromIdAsync($btDev.DeviceId, $propKeys2)
        $di = Invoke-WinRtAsync $diAsync ([Windows.Devices.Enumeration.DeviceInformation])
        L "  DeviceInfo name: '$($di.Name)'"
        foreach ($k in $propKeys2) {
            $v = $null; $di.Properties.TryGetValue($k, [ref]$v) | Out-Null
            L "    $k = $v"
        }
    } else { L "  Classic BT not found" }

    L ""
    L "  Trying BluetoothLEDevice (BLE)..."
    $leAsync = [Windows.Devices.Bluetooth.BluetoothLEDevice]::FromBluetoothAddressAsync($addr)
    $leDev = Invoke-WinRtAsync $leAsync ([Windows.Devices.Bluetooth.BluetoothLEDevice])
    if ($leDev -ne $null) {
        L "  BLE found: '$($leDev.Name)' ConnectionStatus=$($leDev.ConnectionStatus)"
        $null = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattDeviceServicesResult, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]
        $null = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicsResult, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]
        $null = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattReadResult, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]

        $svcAsync = $leDev.GetGattServicesAsync()
        $svcResult = Invoke-WinRtAsync $svcAsync ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattDeviceServicesResult])
        L "  GATT status=$($svcResult.Status) Services=$($svcResult.Services.Count)"
        foreach ($svc in $svcResult.Services) {
            L "    Service UUID: $($svc.Uuid)"
            if ($svc.Uuid.ToString() -match '0000180f') {
                L "    *** GATT Battery Service (0x180F) found! ***"
                $charAsync = $svc.GetCharacteristicsAsync()
                $charResult = Invoke-WinRtAsync $charAsync ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicsResult])
                foreach ($c in $charResult.Characteristics) {
                    L "      Char: $($c.Uuid)"
                    $rAsync = $c.ReadValueAsync()
                    $rResult = Invoke-WinRtAsync $rAsync ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattReadResult])
                    L "      Read status: $($rResult.Status)"
                    if ($rResult.Status -eq [Windows.Devices.Bluetooth.GenericAttributeProfile.GattCommunicationStatus]::Success) {
                        $reader = [Windows.Storage.Streams.DataReader]::FromBuffer($rResult.Value)
                        $batt = $reader.ReadByte()
                        L "      *** BATTERY = $batt% ***"
                    }
                }
            }
        }
    } else { L "  BLE device not found (keyboard may be Classic BT only)" }
} catch { L "  ERROR: $($_.Exception.Message -replace '\r?\n',' ')" }

$log | Set-Content -Path $Out -Encoding UTF8
L ""
L "=== DONE - saved to $Out ==="
