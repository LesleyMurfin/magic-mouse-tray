#Requires -RunAsAdministrator
# Set kernel debug-print filter so DbgPrintEx output for ALL components /
# levels is visible to DebugView and the Kernel-Debug-Print ETW provider.
# Without this, DbgPrintEx output is filtered out unless level == ERROR.
# DPFLTR_IHVDRIVER_ID = 77 is the component our MKB_TRACE uses.

$key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Debug Print Filter'
if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
Set-ItemProperty -Path $key -Name 'DEFAULT'        -Value 0xFFFFFFFF -Type DWord
Set-ItemProperty -Path $key -Name 'IHVDRIVER'      -Value 0xFFFFFFFF -Type DWord
Write-Host "Debug Print Filter:"
Get-ItemProperty -Path $key | Format-List

# Apply at runtime too (avoids needing reboot for DbgPrintEx levels).
# Each component's filter mask can be set live via NtSystemDebugControl —
# simpler proxy: enable kernel symbols/diag mode in DebugView session.
# We don't have a userland API to update live mask without driver, but
# DPFLTR_ERROR_LEVEL (0) is always shown regardless of mask, so MKB_TRACE
# (which uses ERROR level) should work without runtime change.
Write-Host "MKB_TRACE uses DPFLTR_ERROR_LEVEL — always visible. Filter set for safety."
