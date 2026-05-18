#Requires -RunAsAdministrator
# Dump raw lines around the kb CachedServices section to see actual format.
param(
    [string]$RegFile = 'D:\Users\Lesley\Documents\Backups\2026 04 03 - Windows11_registry-backup.reg'
)
$bytes = [IO.File]::ReadAllBytes($RegFile)
if ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
    $text = [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
} else {
    $text = [Text.Encoding]::UTF8.GetString($bytes)
}
$lines = $text -split "`r`n"

# Find kb CachedServices
$header = '[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices\e806884b0741\CachedServices]'
$startIdx = -1
for ($i = 0; $i -lt $lines.Length; $i++) {
    if ($lines[$i] -ceq $header) { $startIdx = $i; break }
}
Write-Host "Header found at line $startIdx"
Write-Host ""
Write-Host "=== 50 lines starting at $startIdx ==="
for ($i = $startIdx; $i -lt [Math]::Min($startIdx + 50, $lines.Length); $i++) {
    Write-Host ("{0,7}: {1}" -f $i, $lines[$i])
}
