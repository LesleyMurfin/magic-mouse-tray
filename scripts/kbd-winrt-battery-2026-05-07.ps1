# kbd-winrt-battery-2026-05-07.ps1
# Part A: WinRT BluetoothDevice selector + BatteryLife property
# Part B: Registry scan of BTHENUM and HID interface nodes for battery data
# Part C: Get-PnpDeviceProperty on HID col02/col03 nodes

$Out = '\\wsl.localhost\Ubuntu\home\lesley\projects\Personal\magic-mouse-tray\.ai\test-runs\2026-05-07-kbd-battery-probe\winrt-battery.txt'
$log = @()
function L([string]$m) { $script:log += $m; Write-Host $m }
L "=== KB WINRT+REG BATTERY PROBE $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
L ""

# ---- PART A: WinRT BluetoothDevice -------------------------------------------
L "=== PART A: WinRT BluetoothDevice.GetDeviceSelector() ==="
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
    $null = [Windows.Devices.Bluetooth.BluetoothDevice, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType=WindowsRuntime]

    $propKeys = [string[]]@(
        "System.Devices.BatteryLife",
        "System.Devices.Connected",
        "System.Devices.BatteryPlusOfTotal"
    )
    $selector = [Windows.Devices.Bluetooth.BluetoothDevice]::GetDeviceSelector()
    L "  Selector: $($selector.Substring(0,[Math]::Min(80,$selector.Length)))..."

    $async = [Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($selector, $propKeys)
    $asyncType = $async.GetType()

    # Find correct AsTask overload for IAsyncOperation<T>
    $asTaskMethods = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 1 }
    $asTask = $asTaskMethods | Select-Object -First 1

    if ($asTask -eq $null) { L "  ERROR: AsTask not found"; }
    else {
        $resultType = [Windows.Devices.Enumeration.DeviceInformationCollection]
        $task = $asTask.MakeGenericMethod($resultType).Invoke($null, @($async))
        if (-not $task.Wait(10000)) { L "  TIMEOUT 10s" }
        else {
            $devs = $task.Result
            L "  BT devices: $($devs.Count)"
            foreach ($d in $devs) {
                $nameMatch = $d.Name -like '*keyboard*' -or $d.Name -like '*magic*' -or
                             $d.Name -like '*apple*' -or $d.Name -like '*wireless*'
                $batt = $null; $d.Properties.TryGetValue("System.Devices.BatteryLife", [ref]$batt) | Out-Null
                if (-not $nameMatch -and $batt -eq $null) { continue }
                L "  BT Device: '$($d.Name)'"
                L "    Id: $($d.Id)"
                foreach ($k in $propKeys) {
                    $v = $null; $d.Properties.TryGetValue($k, [ref]$v) | Out-Null
                    L "    $k = $v"
                }
            }
        }
    }
} catch {
    L "  WinRT error: $($_.Exception.Message -replace '\r?\n',' ')"
}

# ---- PART B: Registry scan ---------------------------------------------------
L ""
L "=== PART B: Registry scan for battery data ==="

# Check BTHENUM devnode properties
$kbBthenum = "BTHENUM\{00001124-0000-1000-8000-00805f9b34fb}_VID&000205AC_PID&0239"
$bthenumBase = "HKLM:\SYSTEM\CurrentControlSet\Enum\BTHENUM"

L "  Scanning BTHENUM keys for $kbBthenum..."
try {
    $matchKey = Get-ChildItem $bthenumBase -ErrorAction Stop |
        Where-Object { $_.PSChildName -like '*00001124*' -and $_.PSChildName -like '*0239*' } |
        Select-Object -First 1

    if ($matchKey) {
        L "  Found: $($matchKey.PSChildName)"
        $instKeys = Get-ChildItem $matchKey.PSPath -ErrorAction SilentlyContinue
        foreach ($inst in $instKeys) {
            L "  Instance: $($inst.PSChildName)"
            # Look for battery-related values
            $vals = Get-ItemProperty $inst.PSPath -ErrorAction SilentlyContinue
            $vals.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object {
                $name = $_.Name
                if ($name -like '*batt*' -or $name -like '*power*' -or $name -like '*energy*') {
                    L "    REG: $name = $($_.Value)"
                }
            }
            # Check DeviceParameters subkey
            $dp = Join-Path $inst.PSPath "Device Parameters"
            if (Test-Path $dp) {
                $dpVals = Get-ItemProperty $dp -ErrorAction SilentlyContinue
                $dpVals.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object {
                    $name = $_.Name
                    if ($name -like '*batt*' -or $name -like '*power*' -or $name -like '*energy*') {
                        L "    DP: $name = $($_.Value)"
                    }
                }
            }
        }
    } else {
        L "  Not found in BTHENUM"
    }
} catch { L "  Error: $($_.Exception.Message)" }

# Check the BT device store / pairing data
$btDevStore = "HKLM:\SYSTEM\CurrentControlSet\Services\BthA2dp"
L ""
L "  Scanning BT radio properties..."
$btKeys = @(
    "HKLM:\SYSTEM\CurrentControlSet\Services\BthEnum\Enum",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeviceMetadata",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Bluetooth"
)
foreach ($k in $btKeys) {
    if (Test-Path $k) {
        L "  EXISTS: $k"
        try {
            Get-ItemProperty $k -ErrorAction SilentlyContinue | Select-Object * -ExcludeProperty PS* |
                Format-List | Out-String | ForEach-Object { L "    $_" }
        } catch {}
    }
}

# ---- PART C: Get-PnpDeviceProperty on HID interface nodes --------------------
L ""
L "=== PART C: PnpDeviceProperty on HID col02 and col03 ==="

$hidIds = @(
    "HID\{00001124-0000-1000-8000-00805f9b34fb}_VID&000205AC_PID&0239&Col02",
    "HID\{00001124-0000-1000-8000-00805f9b34fb}_VID&000205AC_PID&0239&Col03"
)
foreach ($id in $hidIds) {
    $pnpDev = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like "*$($id.Split('\')[1])*" } | Select-Object -First 1
    if (-not $pnpDev) { L "  $id : NOT FOUND"; continue }
    L "  $($pnpDev.InstanceId)"
    $battKeys = @(
        "{104EA319-6EE2-4701-BD47-8DDBF425BBE5} 2",
        "{83DA6326-97A6-4088-9453-A1923F573B29} 16",
        "{49CD1F76-5626-4B17-A4E8-18B4AA1A2213} 4",
        "{83DA6326-97A6-4088-9453-A1923F573B29} 4"
    )
    foreach ($k in $battKeys) {
        try {
            $p = Get-PnpDeviceProperty -InstanceId $pnpDev.InstanceId -KeyName $k -ErrorAction Stop
            if ($p.Data -ne $null -and $p.Data -ne '') { L "    HIT $k => $($p.Data)" }
        } catch { }
    }
    # Dump non-null props
    try {
        $all = Get-PnpDeviceProperty -InstanceId $pnpDev.InstanceId -ErrorAction Stop
        $hits = $all | Where-Object { $p = $_; $p.Data -ne $null -and $p.Data -ne '' -and $p.Data -notmatch '^0+$' }
        L "  Non-null props: $($hits.Count)"
        $hits | Select-Object -First 5 | ForEach-Object { L "    $($_.KeyName) = $($_.Data)" }
    } catch { }
}

$log | Set-Content -Path $Out -Encoding UTF8
L ""
L "=== DONE - saved to $Out ==="
