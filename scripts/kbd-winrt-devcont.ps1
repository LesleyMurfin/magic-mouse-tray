# kbd-winrt-devcont-2026-05-07.ps1 (v3 - minimal properties, find battery any way possible)

$Out = '\\wsl.localhost\Ubuntu\home\lesley\projects\Personal\magic-mouse-tray\.ai\test-runs\2026-05-07-kbd-battery-probe\winrt-devcont.txt'
$log = @()
function L([string]$m) { $script:log += $m; Write-Host $m }
L "=== KBD WINRT+DEVCONT PROBE v3 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
L ""

Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop

function Await($async, [type]$t) {
    $methods = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 1 }
    $task = ($methods | Select-Object -First 1).MakeGenericMethod($t).Invoke($null, @($async))
    if (-not $task.Wait(12000)) { throw "Timeout 12s" }
    return $task.Result
}

# ---- PART A: BluetoothDevice - dump ALL properties ---------------------------
L "=== PART A: BluetoothDevice - ALL properties ==="
try {
    $null = [Windows.Devices.Bluetooth.BluetoothDevice, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType=WindowsRuntime]

    $addr = [System.UInt64]0xE806884B0741
    $async = [Windows.Devices.Bluetooth.BluetoothDevice]::FromBluetoothAddressAsync($addr)
    $btDev = Await $async ([Windows.Devices.Bluetooth.BluetoothDevice])

    if ($btDev -eq $null) { L "  null"; }
    else {
        L "  Found: '$($btDev.Name)'  Id=$($btDev.DeviceId)"

        # Get DeviceInformation with NO extra properties - just check what's already there
        $diAsync = [Windows.Devices.Enumeration.DeviceInformation]::CreateFromIdAsync($btDev.DeviceId)
        $di = Await $diAsync ([Windows.Devices.Enumeration.DeviceInformation])
        L "  DeviceInformation: '$($di.Name)'  IsEnabled=$($di.IsEnabled)"
        L "  Properties count: $($di.Properties.Count)"
        foreach ($kv in $di.Properties) {
            L "    $($kv.Key) = $($kv.Value)"
        }
    }
} catch { L "  ERROR: $($_.Exception.Message -replace '\r?\n',' ')" }

# ---- PART B: DeviceContainer - ALL properties for keyboard container ---------
L ""
L "=== PART B: DeviceContainer - ALL properties ==="
try {
    $null = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType=WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DeviceInformationKind, Windows.Devices.Enumeration, ContentType=WindowsRuntime]

    $kind = [Windows.Devices.Enumeration.DeviceInformationKind]::DeviceContainer
    # No extra properties - get defaults only
    $async = [Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync("", $null, $kind)
    $all = Await $async ([Windows.Devices.Enumeration.DeviceInformationCollection])
    L "  Total containers: $($all.Count)"
    $target = "{49c4a341-7dbd-5fb0-9f4a-84fa5ab58e77}"
    foreach ($d in $all) {
        if ($d.Id.ToLower() -ne $target) { continue }
        L "  FOUND: '$($d.Name)'"
        L "  Properties count: $($d.Properties.Count)"
        foreach ($kv in $d.Properties) {
            L "    $($kv.Key) = $($kv.Value)"
        }
    }
} catch { L "  ERROR: $($_.Exception.Message -replace '\r?\n',' ')" }

$log | Set-Content -Path $Out -Encoding UTF8
L ""
L "=== DONE - saved to $Out ==="
