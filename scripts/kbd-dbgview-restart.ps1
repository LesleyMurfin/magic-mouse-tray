#Requires -RunAsAdministrator
# Stop ALL Dbgview instances, then re-trigger the KbdDbgViewBoot task.
# Only one Dbgview can hold the Dbgv.sys kernel-capture driver at a time.

Get-Process Dbgview* -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "Stopping Dbgview PID=$($_.Id) StartTime=$($_.StartTime)"
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 2
Write-Host "Remaining Dbgview procs:"
Get-Process Dbgview* -ErrorAction SilentlyContinue | Format-Table Id, ProcessName

# Archive stale log
$log = 'C:\mm-dev-queue\dbgview-boot.log'
if (Test-Path $log) {
    $archive = "C:\mm-dev-queue\dbgview-boot-archive-$(Get-Date -Format yyyyMMdd-HHmmss).log"
    Move-Item $log $archive -Force -ErrorAction SilentlyContinue
    Write-Host "Archived prior log -> $archive"
}

# Re-trigger the task
schtasks /run /tn 'KbdDbgViewBoot' | Write-Host
Start-Sleep -Seconds 4

Write-Host ""
Write-Host "After restart:"
Get-Process Dbgview* | Format-Table Id, ProcessName, StartTime, Path -AutoSize
Get-Item $log -ErrorAction SilentlyContinue | Format-List Length, LastWriteTime
