# instrumented-test.ps1  -  full observability wrapper around install.ps1
#
# Wraps the v5 install in:
#   - Pre-flight: bundle integrity, EWDK presence, InfVerif gate (already in install.ps1)
#   - Pre-state snapshot via mm-bt-stack-snapshot.ps1 (if available)
#   - tracelog -start against KMDF runtime WPP provider (captures every WDF
#     callback dispatch, including F2/F3 in applewirelessmouse  -  even though
#     applewirelessmouse never calls TraceEvents itself)
#   - install.ps1 -Apply
#   - Soak window with periodic state snapshots
#   - Minidump watchdog: monitors C:\Windows\Minidump\ for new files; on
#     detection, immediately stops tracelog + saves all artifacts
#   - tracelog -stop + tracefmt convert
#   - Post-state snapshot
#
# Designed for the user's Windows host. Run as Administrator.
#
# Usage:
#   # DRY-RUN (no install, just exercise pre-flight + tracelog start/stop):
#   powershell -ExecutionPolicy Bypass -File instrumented-test.ps1 -SoakSeconds 60
#
#   # LIVE (admin, applies the install):
#   powershell -ExecutionPolicy Bypass -File instrumented-test.ps1 -Apply -SoakSeconds 1800

[CmdletBinding()]
param(
    [switch]$Apply,
    [int]$SoakSeconds = 1800,                 # default 30-min soak window
    [string]$BundleDir = $PSScriptRoot,
    [string]$RunRoot   = "C:\mm-dev-queue\PATH-A-v5\runs"
)

$ErrorActionPreference = 'Stop'
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$RunDir = Join-Path $RunRoot "run-$ts"
New-Item -ItemType Directory -Path $RunDir -Force | Out-Null
$logPath = Join-Path $RunDir "orchestrator.log"

function L {
    param($m, $lvl='INFO')
    $line = "[$(Get-Date -Format 'HH:mm:ss')] [$lvl] $m"
    Write-Host $line; Add-Content $logPath $line
}

function Test-Admin {
    $current = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

L "================================================================"
L "instrumented-test (Apply=$Apply, soak=${SoakSeconds}s)"
L "RunDir: $RunDir"
L "================================================================"

# ---- Tool paths (EWDK F:\) ----
$ewdk     = 'F:\Program Files\Windows Kits\10'
$traceLog = "$ewdk\bin\10.0.26100.0\x64\tracelog.exe"
$traceFmt = "$ewdk\bin\10.0.26100.0\x64\tracefmt.exe"
$tracePdb = "$ewdk\bin\10.0.26100.0\x64\tracepdb.exe"
$kdExe    = "$ewdk\Debuggers\x64\kd.exe"
$symChk   = "$ewdk\Debuggers\x64\symchk.exe"

foreach ($t in @($traceLog, $traceFmt, $tracePdb, $kdExe)) {
    if (Test-Path $t) { L "EWDK: $t" } else { L "EWDK MISSING: $t  -  mount EWDK ISO at F:\" ERROR }
}

# Symbol path (kd will use this)
$env:_NT_SYMBOL_PATH = 'SRV*C:\Symbols*https://msdl.microsoft.com/download/symbols'
L "_NT_SYMBOL_PATH = $env:_NT_SYMBOL_PATH"

# Admin check (needed for tracelog kernel session + install)
if ($Apply -and -not (Test-Admin)) {
    L "FAIL: -Apply requires Administrator" ERROR
    exit 1
}

# ====================================================================
# 1. PRE-STATE SNAPSHOT
# ====================================================================
L "=== 1. Pre-state snapshot ==="
$preSnap = Join-Path $RunDir "pre-state.txt"
$snapScript = Join-Path (Split-Path $BundleDir -Parent) '..\scripts\mm-bt-stack-snapshot.ps1'
if (Test-Path $snapScript) {
    L "Invoking $snapScript"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $snapScript *> $preSnap
} else {
    L "mm-bt-stack-snapshot.ps1 not found  -  using inline snapshot" WARN
    @"
=== Pre-state $ts ===
$(Get-Date)

=== v3 BTHENUM ===
$((Get-PnpDevice | Where-Object { $_.InstanceId -match 'BTHENUM.*00001124.*PID&0323' } | Format-List Status,InstanceId | Out-String))

=== v3 LowerFilters ===
$((Get-PnpDevice | Where-Object { $_.InstanceId -match 'BTHENUM.*00001124.*PID&0323' } | ForEach-Object { (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_LowerFilters' -EA SilentlyContinue).Data -join ', ' }))

=== v3 Stack ===
$((Get-PnpDevice | Where-Object { $_.InstanceId -match 'BTHENUM.*00001124.*PID&0323' } | ForEach-Object { (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_Stack' -EA SilentlyContinue).Data -join ', ' }))

=== v3 HID children ===
$(Get-PnpDevice -Class HIDClass -EA SilentlyContinue | Where-Object { $_.InstanceId -match 'PID&0323' } | Format-Table Status,InstanceId -AutoSize | Out-String)

=== Services ===
$(Get-Service applewirelessmouse,MagicMouse,MagicMouseFixV3 -EA SilentlyContinue | Format-Table Name,Status,StartType -AutoSize | Out-String)

=== Existing minidumps ===
$(Get-ChildItem 'C:\Windows\Minidump\*.dmp' -EA SilentlyContinue | Format-Table Name,Length,LastWriteTime -AutoSize | Out-String)
"@ | Out-File $preSnap
}
L "Pre-state saved: $preSnap"

# Snapshot existing minidumps so the watchdog detects only NEW ones
$existingDumps = @(Get-ChildItem 'C:\Windows\Minidump\*.dmp' -EA SilentlyContinue | Select-Object -ExpandProperty FullName)
$existingDumps | Out-File (Join-Path $RunDir 'minidump-baseline.txt')
L "Minidump baseline: $($existingDumps.Count) existing dump(s)"

# ====================================================================
# 2. START TRACELOG (KMDF runtime WPP provider)
# ====================================================================
# KMDF V1 runtime provider GUID (well-known): 544D4C25-942C-46C5-BD06-5BBCBA7C7906
# Captures every WDF framework callback dispatch + IFR events for every WDF driver.
# Level 5 = Information; flags 0xFFFF = all categories.

$kmdfGuid = '544D4C25-942C-46C5-BD06-5BBCBA7C7906'
$etlPath  = Join-Path $RunDir "kmdf-trace.etl"
$sessionName = "MagicMouseFixV3Trace"

if ($Apply) {
    L "=== 2. tracelog -start (KMDF runtime provider) ==="
    if (Test-Path $traceLog) {
        # Stop any prior session with the same name (idempotent)
        & $traceLog -stop $sessionName 2>&1 | Out-Null
        $tlOut = & $traceLog -start $sessionName -guid "#$kmdfGuid" -f $etlPath -flag 0xFFFF -level 5 2>&1
        $tlOut | ForEach-Object { L "  tracelog: $_" }
        if ($LASTEXITCODE -ne 0) { L "tracelog -start FAILED ($LASTEXITCODE)" ERROR }
    } else {
        L "tracelog.exe missing  -  proceeding without ETW capture (post-mortem will rely on WDF IFR in dump)" WARN
    }
}

# ====================================================================
# 3. RUN install.ps1 -Apply
# ====================================================================
L "=== 3. install.ps1 ==="
$installScript = Join-Path $BundleDir 'install.ps1'
if (-not (Test-Path $installScript)) { L "MISSING $installScript" ERROR; exit 1 }
$installArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$installScript,'-BundleDir',$BundleDir)
if ($Apply) { $installArgs += '-Apply' }
$installOut = Join-Path $RunDir 'install-output.log'
& powershell.exe @installArgs *> $installOut
$installExit = $LASTEXITCODE
L "install.ps1 exit=$installExit. output: $installOut"
Get-Content $installOut -Tail 25 | ForEach-Object { L "  install: $_" }

if ($installExit -ne 0 -and $Apply) {
    L "Install failed  -  stopping tracelog + bailing" ERROR
    if (Test-Path $traceLog) { & $traceLog -stop $sessionName 2>&1 | Out-Null }
    exit $installExit
}

# ====================================================================
# 4. SOAK with minidump watchdog
# ====================================================================
$soakStart = Get-Date
$deadline  = $soakStart.AddSeconds($SoakSeconds)
L "=== 4. Soak (until $($deadline.ToString('HH:mm:ss')))  -  watching for minidumps ==="

$cycle = 0
$earlyExit = $false
while ((Get-Date) -lt $deadline) {
    $cycle++
    Start-Sleep -Seconds 5

    # Watch for NEW minidumps
    $current = @(Get-ChildItem 'C:\Windows\Minidump\*.dmp' -EA SilentlyContinue | Select-Object -ExpandProperty FullName)
    $new = $current | Where-Object { $_ -notin $existingDumps }
    if ($new -and $new.Count -gt 0) {
        L "!!! NEW MINIDUMP DETECTED  -  BSOD occurred during soak !!!" ERROR
        foreach ($d in $new) { L "  $d" ERROR }
        # Copy new dumps to RunDir so they're alongside the trace
        foreach ($d in $new) {
            $dest = Join-Path $RunDir "bsod-$([IO.Path]::GetFileName($d))"
            try { Copy-Item $d $dest -Force; L "  copied -> $dest" } catch { L "  copy failed: $_" WARN }
        }
        $earlyExit = $true
        break
    }

    # Periodic state snapshot every minute
    if (($cycle % 12) -eq 0) {
        $stateSnap = Join-Path $RunDir "state-cycle-$cycle.txt"
        try {
            $v3 = Get-PnpDevice -EA SilentlyContinue | Where-Object { $_.InstanceId -match 'BTHENUM.*00001124.*PID&0323' } | Select-Object -First 1
            if ($v3) {
                $stk = (Get-PnpDeviceProperty -InstanceId $v3.InstanceId -KeyName 'DEVPKEY_Device_Stack' -EA SilentlyContinue).Data -join ', '
                $lf  = (Get-PnpDeviceProperty -InstanceId $v3.InstanceId -KeyName 'DEVPKEY_Device_LowerFilters' -EA SilentlyContinue).Data -join ', '
                "[$(Get-Date -Format 'HH:mm:ss')] cycle=$cycle status=$($v3.Status) lf=$lf stack=$stk" | Out-File $stateSnap -Append
                L "  cycle=$cycle status=$($v3.Status) lf=$lf"
            }
        } catch { L "  state snapshot failed: $_" WARN }
    }
}

if (-not $earlyExit) {
    L "Soak completed without BSOD ($SoakSeconds seconds elapsed)"
}

# ====================================================================
# 5. STOP tracelog + tracefmt
# ====================================================================
L "=== 5. tracelog -stop + tracefmt ==="
if ($Apply -and (Test-Path $traceLog)) {
    & $traceLog -stop $sessionName 2>&1 | ForEach-Object { L "  tracelog stop: $_" }
    if (Test-Path $etlPath) {
        $etlSize = (Get-Item $etlPath).Length
        L "ETL captured: $etlPath ($etlSize bytes)"
        # tracefmt to text (without TMF, output will be raw event headers  -  still useful)
        $etlTxt = "$etlPath.txt"
        if (Test-Path $traceFmt) {
            & $traceFmt $etlPath -o $etlTxt 2>&1 | Out-Null
            if (Test-Path $etlTxt) { L "tracefmt converted: $etlTxt" }
        }
    } else {
        L "ETL not produced  -  tracelog session may have failed" WARN
    }
}

# ====================================================================
# 6. POST-STATE SNAPSHOT
# ====================================================================
L "=== 6. Post-state snapshot ==="
$postSnap = Join-Path $RunDir "post-state.txt"
"=== Post-state $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Out-File $postSnap
"=== v3 ===" | Out-File $postSnap -Append
Get-PnpDevice -EA SilentlyContinue | Where-Object { $_.InstanceId -match 'BTHENUM.*00001124.*PID&0323' } | Format-List | Out-String | Out-File $postSnap -Append
"=== Services ===" | Out-File $postSnap -Append
Get-Service applewirelessmouse,MagicMouse,MagicMouseFixV3 -EA SilentlyContinue | Format-Table -AutoSize | Out-String | Out-File $postSnap -Append
"=== Minidumps after soak ===" | Out-File $postSnap -Append
Get-ChildItem 'C:\Windows\Minidump\*.dmp' -EA SilentlyContinue | Format-Table Name,Length,LastWriteTime -AutoSize | Out-String | Out-File $postSnap -Append
L "Post-state saved: $postSnap"

# ====================================================================
# 7. FINAL REPORT
# ====================================================================
L "================================================================"
L "RUN SUMMARY"
L "  RunDir:         $RunDir"
L "  Pre-state:      $preSnap"
L "  Install log:    $installOut"
L "  ETL trace:      $etlPath"
L "  Post-state:     $postSnap"
L "  BSOD detected:  $earlyExit"
L "================================================================"

if ($earlyExit) {
    L "Post-mortem checklist:" WARN
    L "  1. Reboot the host if not auto-rebooted" WARN
    L "  2. cd $RunDir" WARN
    L "  3. & '$kdExe' -z 'bsod-*.dmp' -c '.sympath $env:_NT_SYMBOL_PATH;.reload /f;!analyze -v;!wdfkd.wdflogdump applewirelessmouse;q' -logo 'kd-analyze.txt'" WARN
    L "  4. Read kd-analyze.txt for BUGCHECK_CODE + FAILURE_BUCKET_ID + WDF IFR events" WARN
    L "  5. Compare against BSOD #1/#2 minidumps you safekept" WARN
    L "  6. Run uninstall.ps1 to restore stock state" WARN
    exit 2
}
exit 0
