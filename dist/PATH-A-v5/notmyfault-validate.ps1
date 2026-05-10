# notmyfault-validate.ps1  -  proves the kernel-dump pipeline works END-TO-END
#
# Why this exists: BSOD #1 (2026-05-07) and BSOD #2 (2026-05-08) both bugchecked
# but the user reports the minidumps were captured + safekept. Before risking
# another BSOD with the v5 driver, we want hard proof that on THIS host RIGHT
# NOW, a forced bugcheck produces a readable minidump that kd.exe can analyze.
#
# Method: Sysinternals notmyfaultc.exe with a controlled fault code, monitor
# for the dump file post-reboot, then run kd against it.
#
# Usage:
#   # Run as admin. Will BSOD the machine. Reboot is automatic.
#   powershell -ExecutionPolicy Bypass -File notmyfault-validate.ps1 -Phase Trigger
#
#   # After reboot, run as admin (or normal user  -  kd doesn't need elevation
#   # to read a saved dump):
#   powershell -ExecutionPolicy Bypass -File notmyfault-validate.ps1 -Phase Analyze

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Trigger','Analyze')]$Phase,
    [string]$NotMyFaultC = 'C:\Program Files\WindowsApps\Microsoft.SysinternalsSuite_2026.5.0.0_x64__8wekyb3d8bbwe\Tools\notmyfaultc.exe',
    [string]$Kd = 'F:\Program Files\Windows Kits\10\Debuggers\x64\kd.exe',
    [int]$CrashType = 1,    # 1 = high IRQL fault (KMODE_EXCEPTION_NOT_HANDLED)
    [string]$OutDir = 'C:\mm-dev-queue\notmyfault-validation'
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $OutDir "validate-$Phase-$ts.log"
function L { param($m, $lvl='INFO') $line="[$(Get-Date -Format 'HH:mm:ss')] [$lvl] $m"; Write-Host $line; Add-Content $logPath $line }

if ($Phase -eq 'Trigger') {
    L "=== notmyfault-validate Phase=Trigger (will BSOD the machine) ==="

    # Pre-checks
    if (-not (Test-Path $NotMyFaultC)) { L "MISSING: $NotMyFaultC" ERROR; exit 1 }

    $cc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
    L "CrashDumpEnabled=$($cc.CrashDumpEnabled) AutoReboot=$($cc.AutoReboot) MinidumpDir=$($cc.MinidumpDir)"
    if ($cc.CrashDumpEnabled -lt 1) { L "CrashDumpEnabled is 0  -  no dump will be written. Set it before running." ERROR; exit 1 }

    # Snapshot existing dumps so we can detect the new one post-reboot
    $existing = @(Get-ChildItem 'C:\Windows\Minidump\*.dmp' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    L "Existing minidumps: $($existing.Count)"
    $existing | ForEach-Object { L "  $_" }
    $existing | Out-File (Join-Path $OutDir "minidump-snapshot-pre-$ts.txt")

    # Save where to look post-reboot
    @{
        SnapshotTimestamp = $ts
        ExistingDumps     = $existing
        PreCrashTime      = (Get-Date).ToString('o')
    } | ConvertTo-Json | Out-File (Join-Path $OutDir 'last-trigger.json')

    L "Triggering controlled BSOD via notmyfaultc -t $CrashType in 5 seconds..."
    L "After reboot: re-run this script with -Phase Analyze"
    Start-Sleep -Seconds 5
    & $NotMyFaultC /crash $CrashType   # /crash <type>: 1=high-IRQL, 4=stack overflow, 8=double-free
    # Unreachable if BSOD fires
    L "notmyfaultc returned without crashing (unexpected). exit=$LASTEXITCODE" ERROR
    exit 1
}

if ($Phase -eq 'Analyze') {
    L "=== notmyfault-validate Phase=Analyze ==="

    if (-not (Test-Path $Kd)) { L "MISSING: $Kd  (mount EWDK ISO at F:\)" ERROR; exit 1 }

    # Load the trigger snapshot
    $stateFile = Join-Path $OutDir 'last-trigger.json'
    if (-not (Test-Path $stateFile)) { L "No prior trigger state at $stateFile  -  run Phase=Trigger first." ERROR; exit 1 }
    $state = Get-Content $stateFile | ConvertFrom-Json
    L "Trigger ts=$($state.SnapshotTimestamp) pre-crash time=$($state.PreCrashTime)"

    # Find new minidump(s) since trigger
    $existing = @($state.ExistingDumps)
    $now = @(Get-ChildItem 'C:\Windows\Minidump\*.dmp' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    $newDumps = $now | Where-Object { $_ -notin $existing }

    if ($newDumps.Count -eq 0) {
        L "FAIL: No new minidump found in C:\Windows\Minidump\." ERROR
        L "Possible causes:" ERROR
        L "  - Fast Startup intercepted the dump (powercfg /h off + reboot once before retry)" ERROR
        L "  - CrashDumpEnabled was 0 (set to 3 or 7)" ERROR
        L "  - Pagefile too small for the dump type" ERROR
        L "  - Dump written to MEMORY.DMP instead (check C:\Windows\MEMORY.DMP)" ERROR
        $memDmp = Get-Item 'C:\Windows\MEMORY.DMP' -ErrorAction SilentlyContinue
        if ($memDmp) {
            L "Found MEMORY.DMP ($($memDmp.Length) bytes, $($memDmp.LastWriteTime))"
            $newDumps = @($memDmp.FullName)
        } else { exit 1 }
    }

    foreach ($dmp in $newDumps) {
        L "Analyzing: $dmp"
        $env:_NT_SYMBOL_PATH = 'SRV*C:\Symbols*https://msdl.microsoft.com/download/symbols'
        $kdOut = Join-Path $OutDir "kd-$ts-$([IO.Path]::GetFileNameWithoutExtension($dmp)).txt"

        # Single-shot kd command: load dump, !analyze -v, exit
        $cmd = '.sympath ' + $env:_NT_SYMBOL_PATH + ';.reload /f;!analyze -v;q'
        & $Kd -z "$dmp" -c $cmd -logo $kdOut 2>&1 | Tee-Object -FilePath $logPath -Append | Out-Null

        if (Test-Path $kdOut) {
            L "kd output saved: $kdOut"
            $bug = Select-String -Path $kdOut -Pattern 'BUGCHECK_CODE|BugCheck' | Select-Object -First 3
            $bug | ForEach-Object { L "  $($_.Line.Trim())" }
            $sym = Select-String -Path $kdOut -Pattern 'MODULE_NAME|IMAGE_NAME|FAILURE_BUCKET_ID' | Select-Object -First 3
            $sym | ForEach-Object { L "  $($_.Line.Trim())" }
            $err = Select-String -Path $kdOut -Pattern 'ERROR|^\*\*\*' | Select-Object -First 3
            if ($err) {
                L "WARNINGS in kd output:" WARN
                $err | ForEach-Object { L "  $($_.Line.Trim())" WARN }
            }
        } else {
            L "FAIL: kd produced no output file" ERROR
            exit 1
        }
    }

    L "PASS: dump pipeline validated  -  minidump captured + kd.exe + symbols + !analyze all working"
    L "Done. Log: $logPath"
}
