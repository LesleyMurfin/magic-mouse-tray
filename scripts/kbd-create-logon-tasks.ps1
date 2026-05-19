#Requires -RunAsAdministrator
# kbd-create-logon-tasks.ps1
# Creates two ONLOGON scheduled tasks for the post-reboot capture cycle:
#   1. KbdDbgViewBoot — auto-start DebugView at logon, capture kernel + verbose,
#      log to C:\mm-dev-queue\dbgview-boot.log. Captures DriverEntry KdPrint
#      from MagicKbDesc on first kb enumeration.
#   2. KbdPostRebootValidate — after user logon (delayed 90s to let BT reconnect),
#      runs post-reboot-validate.ps1, output tee'd to dbgview-boot.log + a
#      task-specific log.
#
# Idempotent: removes any existing tasks of the same name first.

$ErrorActionPreference = 'Stop'
$user = "$env:USERDOMAIN\$env:USERNAME"
$queueDir = 'C:\mm-dev-queue'

# Task 1: DebugView at logon
$dbgTaskName = 'KbdDbgViewBoot'
$dbgLog = 'C:\mm-dev-queue\dbgview-boot.log'

# Resolve DebugView path. Prefer Sysinternals Suite Store install
# (PATH alias at $env:LOCALAPPDATA\Microsoft\WindowsApps\Dbgview.exe).
$dbgExeCandidates = @(
    "$env:LOCALAPPDATA\Microsoft\WindowsApps\Dbgview.exe",
    (Get-Command Dbgview.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1)
)
$dbgExe = $dbgExeCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

# Fallback: search Sysinternals Store package install dir directly
if (-not $dbgExe) {
    $pkg = Get-AppxPackage -Name '*Sysinternals*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg) {
        $dbgExe = Join-Path $pkg.InstallLocation 'Dbgview.exe'
        if (-not (Test-Path $dbgExe)) {
            $dbgExe = Get-ChildItem -Path $pkg.InstallLocation -Filter 'Dbgview*.exe' -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty FullName
        }
    }
}

if (-not $dbgExe -or -not (Test-Path $dbgExe)) {
    throw "Dbgview.exe not found. Install Sysinternals Suite from Microsoft Store or place Dbgview.exe in PATH."
}
Write-Host "[INFO] Using DebugView at: $dbgExe"

Unregister-ScheduledTask -TaskName $dbgTaskName -Confirm:$false -ErrorAction SilentlyContinue
$dbgAction = New-ScheduledTaskAction -Execute $dbgExe `
    -Argument "/k /v /l `"$dbgLog`" /m 50 /accepteula" `
    -WorkingDirectory $queueDir
$dbgTrigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$dbgPrincipal = New-ScheduledTaskPrincipal -UserId $user -RunLevel Highest -LogonType Interactive
$dbgSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 6)
Register-ScheduledTask -TaskName $dbgTaskName -Action $dbgAction -Trigger $dbgTrigger `
    -Principal $dbgPrincipal -Settings $dbgSettings `
    -Description "Auto-start DebugView at logon to capture MagicKbDesc KdPrint output."
Write-Host "[OK] Created task: $dbgTaskName ($dbgExe -> $dbgLog)"

# Task 2: post-reboot-validate at logon, delayed 90s
$valTaskName = 'KbdPostRebootValidate'
$valScript = 'D:\mm3-driver\scripts\post-reboot-validate.ps1'
$valLog = 'C:\mm-dev-queue\post-reboot-validate.log'
if (-not (Test-Path $valScript)) { throw "post-reboot-validate.ps1 not found at $valScript" }

Unregister-ScheduledTask -TaskName $valTaskName -Confirm:$false -ErrorAction SilentlyContinue
# Script self-transcribes via Start-Transcript to $valLog at top — no Tee plumbing needed.
$valAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$valScript`" -SkipReinstall"
$valTrigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$valTrigger.Delay = 'PT90S'   # wait 90s after logon for BT to reconnect kb
$valPrincipal = New-ScheduledTaskPrincipal -UserId $user -RunLevel Highest -LogonType Interactive
$valSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
Register-ScheduledTask -TaskName $valTaskName -Action $valAction -Trigger $valTrigger `
    -Principal $valPrincipal -Settings $valSettings `
    -Description "Run post-reboot-validate.ps1 90s after logon to verify MagicKbDesc bound."
Write-Host "[OK] Created task: $valTaskName ($valScript -> $valLog)"

Write-Host ""
Write-Host "Both tasks registered. Verify:"
Get-ScheduledTask -TaskName $dbgTaskName,$valTaskName | Format-Table TaskName, State, Triggers
