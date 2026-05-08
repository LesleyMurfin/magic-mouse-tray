# kbd-battery-safe-probe-2026-05-07.ps1
# Read-only battery probe. No HID Get_Report. No BT traffic. No blocking reads.
# Part A: Get-PnpDeviceProperty (DEVPKEY candidates on BTHENUM devnode)
# Part B: WinRT DeviceContainer BatteryLife property
$Out = '\\wsl.localhost\Ubuntu\home\lesley\projects\Personal\magic-mouse-tray\.ai\test-runs\2026-05-07-kbd-battery-probe\safe-probe.txt'
$log = @()
function L([string]$m) { $script:log += $m; Write-Host $m }
L "=== KB BATTERY SAFE PROBE $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="

# ---- PART A: Get-PnpDeviceProperty ----------------------------------------
L ""
L "=== PART A: PnpDeviceProperty battery DEVPKEY candidates ==="

$kbInstance = (Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -like '*00001124*' -and
                   $_.InstanceId -like '*000205AC*' -and
                   $_.InstanceId -like '*0239*' -and
                   $_.InstanceId -notlike '*HID*' } |
    Select-Object -First 1).InstanceId

if ($kbInstance) {
    L "  InstanceId: $kbInstance"
    # Candidate property keys to check
    $propKeys = @(
        "{104EA319-6EE2-4701-BD47-8DDBF425BBE5} 2",
        "{83DA6326-97A6-4088-9453-A1923F573B29} 16",
        "{49CD1F76-5626-4B17-A4E8-18B4AA1A2213} 4",
        "{83DA6326-97A6-4088-9453-A1923F573B29} 4",
        "{104EA319-6EE2-4701-BD47-8DDBF425BBE5} 1",
        "{104EA319-6EE2-4701-BD47-8DDBF425BBE5} 4",
        "{49CD1F76-5626-4B17-A4E8-18B4AA1A2213} 2"
    )
    foreach ($k in $propKeys) {
        try {
            $p = Get-PnpDeviceProperty -InstanceId $kbInstance -KeyName $k -ErrorAction Stop
            L "  HIT  $k => Type=$($p.Type) Data=$($p.Data)"
        } catch {
            L "  MISS $k ($($_.Exception.Message -replace '\r?\n',' '))"
        }
    }
    # Also dump ALL properties that have non-null data
    L "  --- All non-null properties on BTHENUM devnode ---"
    try {
        $all = Get-PnpDeviceProperty -InstanceId $kbInstance -ErrorAction Stop
        foreach ($p in $all) {
            if ($p.Data -ne $null -and $p.Data -ne '') {
                L "  PROP $($p.KeyName) Type=$($p.Type) Data=$($p.Data)"
            }
        }
    } catch {
        L "  Error dumping all props: $($_.Exception.Message)"
    }
} else {
    L "  ERROR: keyboard BTHENUM devnode not found"
}

# ---- PART B: WinRT DeviceContainer ----------------------------------------
L ""
L "=== PART B: WinRT DeviceContainer BatteryLife ==="
try {
    # Load WinRT type via ContentType=WindowsRuntime trick
    $null = [Windows.Devices.Enumeration.DeviceInformation,
             Windows.Devices.Enumeration,
             ContentType=WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DeviceInformationKind,
             Windows.Devices.Enumeration,
             ContentType=WindowsRuntime]
    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop

    $propKeys = [string[]]@(
        "System.Devices.BatteryLife",
        "System.Devices.BatteryPlusOfTotal",
        "System.Devices.Connected"
    )
    $kind = [Windows.Devices.Enumeration.DeviceInformationKind]::DeviceContainer
    $async = [Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync("", $propKeys, $kind)

    $ext = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 } |
        Select-Object -First 1
    $task = $ext.MakeGenericMethod(
        [Windows.Devices.Enumeration.DeviceInformationCollection]
    ).Invoke($null, @($async))

    if (-not $task.Wait(8000)) {
        L "  TIMEOUT after 8s"
    } else {
        $containers = $task.Result
        L "  Total DeviceContainers: $($containers.Count)"
        foreach ($c in $containers) {
            $batt = $null
            $c.Properties.TryGetValue("System.Devices.BatteryLife", [ref]$batt) | Out-Null
            $conn = $null
            $c.Properties.TryGetValue("System.Devices.Connected", [ref]$conn) | Out-Null
            $nameMatch = $c.Name -like '*keyboard*' -or $c.Name -like '*magic*' -or $c.Name -like '*apple*'
            if (-not $nameMatch -and $batt -eq $null) { continue }
            L "  Container: '$($c.Name)'"
            foreach ($k in $propKeys) {
                $v = $null
                $c.Properties.TryGetValue($k, [ref]$v) | Out-Null
                L "    $k = $v"
            }
        }
    }
} catch {
    L "  ERROR: $($_.Exception.Message)"
}

$log | Set-Content -Path $Out -Encoding UTF8
L ""
L "=== DONE - saved to $Out ==="
