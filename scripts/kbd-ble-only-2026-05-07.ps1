# kbd-ble-only-2026-05-07.ps1
# Focused: BluetoothLEDevice from keyboard MAC address, GATT Battery Service (0x180F).
# Also: AEP (AssociationEndpoint) DeviceInformation battery property.
# MAC: E8:06:88:4B:07:41 from BTHENUM instance

$Out = '\\wsl.localhost\Ubuntu\home\lesley\projects\Personal\magic-mouse-tray\.ai\test-runs\2026-05-07-kbd-battery-probe\ble-only.txt'
$log = @()
function L([string]$m) { $script:log += $m; Write-Host $m }
L "=== KB BLE-ONLY PROBE $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
L "MAC: E8:06:88:4B:07:41"
L ""

Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop

function Invoke-WinRtAsync($async, [type]$resultType) {
    $methods = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 1 }
    $task = ($methods | Select-Object -First 1).MakeGenericMethod($resultType).Invoke($null, @($async))
    if (-not $task.Wait(12000)) { throw "Timeout 12s" }
    return $task.Result
}

$addr = [System.UInt64]0xE806884B0741

# ---- PART A: AssociationEndpoint DeviceInformation battery -------------------
L "=== PART A: AEP DeviceInformation (Bluetooth#Bluetooth device) ==="
try {
    $null = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType=WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DeviceInformationKind, Windows.Devices.Enumeration, ContentType=WindowsRuntime]
    $null = [Windows.Devices.Bluetooth.BluetoothDevice, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]

    $btAddr = [Windows.Devices.Bluetooth.BluetoothDevice]::GetDeviceSelectorFromBluetoothAddress($addr)
    L "  Selector: $($btAddr.Substring(0,[Math]::Min(100,$btAddr.Length)))"

    # Use FMTID property key format for BatteryLife: {49CD1F76-5626-4B17-A4E8-18B4AA1A2213} 9
    # System.Devices.BatteryLife canonical -> FMTID {49CD1F76-5626-4B17-A4E8-18B4AA1A2213} pid=9
    $propKeys = [string[]]@(
        "{49CD1F76-5626-4B17-A4E8-18B4AA1A2213} 9",
        "{49CD1F76-5626-4B17-A4E8-18B4AA1A2213} 2",
        "{78C34FC8-104A-4ACA-9EA4-524D52996E57} 9"
    )
    $kind = [Windows.Devices.Enumeration.DeviceInformationKind]::AssociationEndpoint
    $async = [Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($btAddr, $propKeys, $kind)
    $devs = Invoke-WinRtAsync $async ([Windows.Devices.Enumeration.DeviceInformationCollection])
    L "  AEP results: $($devs.Count)"
    foreach ($d in $devs) {
        L "  AEP: '$($d.Name)' Id=$($d.Id)"
        foreach ($k in $propKeys) {
            $v = $null; $d.Properties.TryGetValue($k, [ref]$v) | Out-Null
            L "    [$k] = $v"
        }
    }
} catch { L "  ERROR: $($_.Exception.Message -replace '\r?\n',' ')" }

# ---- PART B: BluetoothLEDevice GATT Battery Service -------------------------
L ""
L "=== PART B: BluetoothLEDevice GATT Battery Service (0x180F) ==="
try {
    $null = [Windows.Devices.Bluetooth.BluetoothLEDevice, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]
    $null = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattDeviceServicesResult, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]

    L "  Calling FromBluetoothAddressAsync(0xE806884B0741)..."
    $leAsync = [Windows.Devices.Bluetooth.BluetoothLEDevice]::FromBluetoothAddressAsync($addr)
    $leDev = Invoke-WinRtAsync $leAsync ([Windows.Devices.Bluetooth.BluetoothLEDevice])

    if ($leDev -eq $null) {
        L "  Result: null - keyboard has no BLE counterpart (Classic BT only)"
    } else {
        L "  BLE found: '$($leDev.Name)' Status=$($leDev.ConnectionStatus)"
        L "  BLE DeviceId: $($leDev.DeviceId)"

        $svcAsync = $leDev.GetGattServicesAsync()
        $svcResult = Invoke-WinRtAsync $svcAsync ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattDeviceServicesResult])
        L "  GATT status=$($svcResult.Status) Services=$($svcResult.Services.Count)"

        foreach ($svc in $svcResult.Services) {
            $uStr = $svc.Uuid.ToString()
            L "    Service: $uStr"
            if ($uStr -match '0000180f') {
                L "    *** GATT Battery Service FOUND ***"
                $cAsync = $svc.GetCharacteristicsAsync()
                $cResult = Invoke-WinRtAsync $cAsync ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicsResult])
                foreach ($c in $cResult.Characteristics) {
                    L "      Char: $($c.Uuid)"
                    try {
                        $rAsync = $c.ReadValueAsync()
                        $rResult = Invoke-WinRtAsync $rAsync ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattReadResult])
                        L "      Status: $($rResult.Status)"
                        if ($rResult.Status.ToString() -eq 'Success') {
                            $reader = [Windows.Storage.Streams.DataReader]::FromBuffer($rResult.Value)
                            $batt = $reader.ReadByte()
                            L "      *** BATTERY = $batt% ***"
                        }
                    } catch { L "      Read error: $($_.Exception.Message -replace '\r?\n',' ')" }
                }
            }
        }
    }
} catch { L "  ERROR: $($_.Exception.Message -replace '\r?\n',' ')" }

# ---- PART C: BT device paired info via btpairhelper -------------------------
L ""
L "=== PART C: Registry paired device battery cache ==="
try {
    # Windows stores BT pairing info in HKCU AppData sometimes
    $paths = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Bluetooth\BtpairHelper",
        "HKLM:\SOFTWARE\Microsoft\Bluetooth\btpairhelper",
        "HKLM:\SYSTEM\CurrentControlSet\Services\HidBth"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { L "  EXISTS: $p"; Get-ChildItem $p -ErrorAction SilentlyContinue | Select-Object -First 3 | ForEach-Object { L "    $($_.PSChildName)" } }
        else { L "  NOT FOUND: $p" }
    }

    # Check UserChoice / BT device store
    $btStore = "HKLM:\SYSTEM\CurrentControlSet\Enum\BTHENUM\{00001124-0000-1000-8000-00805f9b34fb}_VID&000205ac_PID&0239\9&73b8b28&0&E806884B0741_C00000000\Device Parameters"
    if (Test-Path $btStore) {
        L "  Device Parameters found - all values:"
        Get-ItemProperty $btStore -ErrorAction SilentlyContinue | Select-Object * -ExcludeProperty PS* | Format-List |
            Out-String -Width 200 | ForEach-Object { L "  $_" }
    } else { L "  Device Parameters path not found" }
} catch { L "  ERROR: $($_.Exception.Message)" }

$log | Set-Content -Path $Out -Encoding UTF8
L ""
L "=== DONE - saved to $Out ==="
