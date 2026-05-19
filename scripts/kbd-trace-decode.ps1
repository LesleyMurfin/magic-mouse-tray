#Requires -RunAsAdministrator
# kbd-trace-decode.ps1 — decode the kbd-trace-live.etl with publisher manifest

$etl = 'C:\mm-dev-queue\kbd-trace-live.etl'
$txt = 'C:\mm-dev-queue\kbd-trace-decoded.txt'

if (-not (Test-Path $etl)) { Write-Host "ETL not found: $etl"; exit 1 }

$evt = Get-WinEvent -Path $etl -Oldest -ErrorAction SilentlyContinue
$total = ($evt | Measure-Object).Count
Write-Host "Total events in ETL: $total"

"=== KBD TRACE DECODE $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Set-Content $txt -Encoding UTF8
"ETL: $etl  ($((Get-Item $etl).Length) bytes)" | Add-Content $txt
"Total events: $total" | Add-Content $txt
"" | Add-Content $txt

# Per-provider counts
"=== Events per provider ===" | Add-Content $txt
$evt | Group-Object ProviderName | Sort-Object Count -Descending | ForEach-Object {
    "  $($_.Count.ToString().PadLeft(6))  $($_.Name)" | Add-Content $txt
}
"" | Add-Content $txt

# Search for keyboard-relevant content
"=== Lines mentioning MagicKbDesc / kb instance / IOCTL_HID_GET_REPORT_DESCRIPTOR ===" | Add-Content $txt
$kbHits = $evt | Where-Object {
    $msg = $_.Message
    $msg -match 'MagicKbDesc' -or
    $msg -match 'BTHENUM.*0239' -or
    $msg -match 'VID&000205AC.*PID&0239' -or
    $msg -match 'GET_REPORT_DESCRIPTOR' -or
    $msg -match 'EvtIoInternalDeviceControl' -or
    $msg -match 'E806884B0741'
}
$kbCount = ($kbHits | Measure-Object).Count
"  Filter-relevant events: $kbCount" | Add-Content $txt
"" | Add-Content $txt

if ($kbCount -gt 0) {
    "=== First 50 filter-relevant events ===" | Add-Content $txt
    $kbHits | Select-Object -First 50 | ForEach-Object {
        $line = "[$($_.TimeCreated.ToString('HH:mm:ss.fff'))] [$($_.ProviderName)] [Id=$($_.Id)] $($_.Message)"
        $line | Add-Content $txt
        "" | Add-Content $txt
    }
}

# KMDF events specifically (provider name match)
"=== KMDF (DriverFrameworks) events count ===" | Add-Content $txt
$kmdfCount = ($evt | Where-Object { $_.ProviderName -match 'DriverFrameworks' } | Measure-Object).Count
"  $kmdfCount" | Add-Content $txt

# Kernel-PnP events for our kb instance
"=== Kernel-PnP events mentioning kb (E806884B0741 or VID&000205AC.*PID&0239) ===" | Add-Content $txt
$pnpKb = $evt | Where-Object { $_.ProviderName -match 'Kernel-PnP' -and ($_.Message -match 'E806884B0741|VID&000205AC.*PID&0239') }
($pnpKb | Measure-Object).Count | ForEach-Object { "  $_" | Add-Content $txt }
$pnpKb | Select-Object -First 30 | ForEach-Object {
    "[$($_.TimeCreated.ToString('HH:mm:ss.fff'))] [Id=$($_.Id)] $($_.Message.Substring(0,[Math]::Min(300,$_.Message.Length)))" | Add-Content $txt
}

Write-Host "Decoded -> $txt"
