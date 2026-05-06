<#
.SYNOPSIS
    M0 gating validation: reliability harness for the confirmed M0a trigger
    (LowerFilters swap via MM-Dev-Cycle FLIP phases).

.DESCRIPTION
    M0 empirical findings (2026-05-06):
      - H-012 bare pnputil /restart-device: FAIL — COL02 never appeared in 15s.
      - M0a (FLIP:NoFilter → FLIP:AppleFilter): PASS — COL02 at ~1s, battery=17% confirmed.

    This script quantifies the M0a trigger's reliability over N attempts:
      FLIP:NoFilter → wait for COL02 → HidD_GetInputReport(0x90) → FLIP:AppleFilter → verify Mode B

    Uses MM-Dev-Cycle scheduled task queue protocol (no admin required in this script).
    Queue: C:\mm-dev-queue\request.txt / result.txt (PHASE|NONCE format).

.NOTES
    Prerequisites:
      - Magic Mouse v3 (PID 0x0323) paired and in Mode B (COL02 absent).
      - MM-Dev-Cycle scheduled task registered and Ready.
      - mm-state-flip.ps1 at D:\mm3-driver\scripts\mm-state-flip.ps1

.PARAMETER N
    Number of flip attempts. Default 20 (sufficient for reliability baseline).

.PARAMETER ModeATimeoutSec
    Seconds to wait for COL02 after FLIP:NoFilter. Default 15.

.PARAMETER TaskTimeoutSec
    Seconds to wait for MM-Dev-Cycle task result. Default 30.

.PARAMETER PollIntervalMs
    COL02 polling interval in ms. Default 250.

.PARAMETER OutputDir
    Directory for M0-MODE-B-TO-A-VALIDATION.md. Default 'docs'.

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File .\scripts\m0-validate-recycle-to-modeA.ps1
    pwsh -ExecutionPolicy Bypass -File .\scripts\m0-validate-recycle-to-modeA.ps1 -N 50
#>
[CmdletBinding()]
param(
    [int]$N                 = 20,
    [int]$ModeATimeoutSec   = 15,
    [int]$TaskTimeoutSec    = 30,
    [int]$PollIntervalMs    = 250,
    [string]$OutputDir      = 'docs'
)
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version 2

# ── P/Invoke (HID) ────────────────────────────────────────────────────────────
if (-not ([System.Management.Automation.PSTypeName]'M0Hid').Type) {
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class M0Hid {
    [DllImport("kernel32.dll", CharSet=CharSet.Auto, SetLastError=true)]
    public static extern SafeFileHandle CreateFile(string n, uint a, uint s, IntPtr p, uint d, uint f, IntPtr t);
    [DllImport("hid.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.U1)]
    public static extern bool HidD_GetInputReport(SafeFileHandle h, byte[] b, int l);
}
'@
}

# ── Logging ───────────────────────────────────────────────────────────────────
$LogFile = Join-Path $env:TEMP 'm0-validate.log'
if (Test-Path $LogFile) { Remove-Item $LogFile -Force }
function L { param([string]$M, [string]$C = 'White')
    $line = "[$(Get-Date -Format 'HH:mm:ss.fff')] $M"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Host $line -ForegroundColor $C
}

# ── Queue protocol ────────────────────────────────────────────────────────────
$QueueDir = 'C:\mm-dev-queue'
$ReqFile  = Join-Path $QueueDir 'request.txt'
$ResFile  = Join-Path $QueueDir 'result.txt'

function Invoke-FlipPhase {
    param([string]$Mode, [int]$TimeoutSec)
    $nonce = "m0-$Mode-$(Get-Date -Format 'HHmmssff')"
    Remove-Item $ResFile -EA SilentlyContinue
    "$Mode|$nonce" | Set-Content $ReqFile -Encoding ASCII
    $null = schtasks.exe /run /tn 'MM-Dev-Cycle' 2>&1
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if (Test-Path $ResFile) {
            $r = (Get-Content $ResFile -Raw -EA SilentlyContinue).Trim()
            if ($r -like "*$nonce*") {
                $sw.Stop()
                $exitCode = ($r -split '\|')[0]
                return @{ Ok = ($exitCode -eq '0'); ExitCode = $exitCode; LatencyMs = [int]$sw.ElapsedMilliseconds }
            }
        }
    }
    $sw.Stop()
    return @{ Ok = $false; ExitCode = 'TIMEOUT'; LatencyMs = [int]$sw.ElapsedMilliseconds }
}

# ── Device helpers ────────────────────────────────────────────────────────────
function Get-Col02Device {
    return Get-PnpDevice -EA SilentlyContinue |
        Where-Object { $_.InstanceId -like '*VID&0001004C_PID&0323*COL02*' -and $_.Status -eq 'OK' } |
        Select-Object -First 1
}

function Wait-ForModeA {
    param([int]$TimeoutSec, [int]$PollMs)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ([DateTime]::UtcNow -lt $deadline) {
        $d = Get-Col02Device
        if ($d) { $sw.Stop(); return @{ Reached = $true; LatencyMs = [int]$sw.ElapsedMilliseconds; InstanceId = $d.InstanceId } }
        Start-Sleep -Milliseconds $PollMs
    }
    $sw.Stop()
    return @{ Reached = $false; LatencyMs = [int]$sw.ElapsedMilliseconds; InstanceId = $null }
}

function Wait-ForModeB {
    param([int]$TimeoutSec, [int]$PollMs)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Get-Col02Device)) { $sw.Stop(); return @{ Recovered = $true; LatencyMs = [int]$sw.ElapsedMilliseconds } }
        Start-Sleep -Milliseconds $PollMs
    }
    $sw.Stop()
    return @{ Recovered = $false; LatencyMs = [int]$sw.ElapsedMilliseconds }
}

function Read-Battery0x90 {
    param([string]$InstanceId)
    $norm = $InstanceId.ToLower().Replace('\', '#')
    $path = "\\?\$norm#{4d1e55b2-f16f-11cf-88cb-001111000030}"
    $h = [M0Hid]::CreateFile($path, [uint32]0, [uint32]3, [IntPtr]::Zero, [uint32]3, [uint32]0, [IntPtr]::Zero)
    if ($h.IsInvalid) {
        $gle = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        return @{ Ok = $false; BatteryPct = -1; Gle = $gle; Hex = '' }
    }
    try {
        $buf = New-Object byte[] 65; $buf[0] = 0x90
        $ok  = [M0Hid]::HidD_GetInputReport($h, $buf, $buf.Length)
        $gle = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        $hex = ($buf[0..7] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
        if ($ok -and $buf[2] -ge 0 -and $buf[2] -le 100) {
            return @{ Ok = $true; BatteryPct = [int]$buf[2]; Gle = 0; Hex = $hex }
        }
        return @{ Ok = $false; BatteryPct = -1; Gle = $gle; Hex = $hex }
    } finally { $h.Close() }
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
L '════════════════════════════════════════════════════════' Cyan
L 'M0 RELIABILITY HARNESS — M0a trigger (LowerFilters swap)' Cyan
L 'PRD-26 / PATH-B Userland Recycler' Cyan
L '════════════════════════════════════════════════════════' Cyan
L ''
L "Parameters: N=$N  ModeATimeout=${ModeATimeoutSec}s  TaskTimeout=${TaskTimeoutSec}s  PollIntervalMs=$PollIntervalMs"

# Verify task and queue dir
$taskInfo = schtasks.exe /query /tn 'MM-Dev-Cycle' /fo LIST 2>&1 | Out-String
if ($taskInfo -notmatch 'Ready|Running') {
    L 'ABORT: MM-Dev-Cycle task not found or not Ready.' Red; exit 1
}
L 'MM-Dev-Cycle task: Ready' Green

if (-not (Test-Path $QueueDir)) {
    L "ABORT: Queue dir not found: $QueueDir" Red; exit 1
}

if (Get-Col02Device) {
    L 'ABORT: COL02 present — not in Mode B. Restore Apple filter first.' Red; exit 1
}
L 'Pre-flight: Mode B confirmed (COL02 absent).' Green
L ''

# ── Main loop ─────────────────────────────────────────────────────────────────
$results  = [System.Collections.Generic.List[hashtable]]::new()
$modeAMs  = [System.Collections.Generic.List[int]]::new()
$modeBMs  = [System.Collections.Generic.List[int]]::new()
$batPcts  = [System.Collections.Generic.List[int]]::new()

for ($i = 1; $i -le $N; $i++) {
    L "── Attempt $i / $N ──"

    if (Get-Col02Device) {
        L "  WARNING: COL02 still present — waiting 10s for residual Mode B recovery..." Yellow
        Start-Sleep -Seconds 10
        if (Get-Col02Device) {
            L "  COL02 still present. Forcing restore flip..." Yellow
            Invoke-FlipPhase 'FLIP:AppleFilter' $TaskTimeoutSec | Out-Null
            Start-Sleep -Seconds 5
        }
    }

    # Trigger: FLIP:NoFilter
    L "  FLIP:NoFilter..."
    $flipResult = Invoke-FlipPhase 'FLIP:NoFilter' $TaskTimeoutSec
    L "  Task exit=$($flipResult.ExitCode) latency=$($flipResult.LatencyMs)ms"

    if (-not $flipResult.Ok) {
        L "  FLIP:NoFilter FAILED (exit=$($flipResult.ExitCode)). Skipping attempt." Red
        $results.Add(@{ Attempt=$i; ModeClass='FLIP_FAIL'; BatteryClass='NOT_ATTEMPTED';
            ModeALatencyMs=-1; ModeBRestoreMs=-1; BatteryPct=-1; FlipExitCode=$flipResult.ExitCode })
        continue
    }

    # Wait for Mode A (COL02)
    $modeA = Wait-ForModeA -TimeoutSec $ModeATimeoutSec -PollMs $PollIntervalMs
    if ($modeA.Reached) {
        $modeAMs.Add($modeA.LatencyMs)
        L "  COL02 present at $($modeA.LatencyMs)ms: $($modeA.InstanceId)" Green

        # Battery probe
        $bat = Read-Battery0x90 $modeA.InstanceId
        if ($bat.Ok) {
            $batPcts.Add($bat.BatteryPct)
            L "  Battery: $($bat.BatteryPct)% — hex: $($bat.Hex)" Green
            $batteryClass = 'BATTERY_READ_OK'
        } else {
            L "  Battery read FAIL: gle=$($bat.Gle) hex=$($bat.Hex)" Yellow
            $batteryClass = 'BATTERY_READ_FAIL'
        }

        # Restore: FLIP:AppleFilter
        L "  FLIP:AppleFilter (restore)..."
        $restore = Invoke-FlipPhase 'FLIP:AppleFilter' $TaskTimeoutSec
        L "  Restore exit=$($restore.ExitCode) latency=$($restore.LatencyMs)ms"

        # Verify Mode B
        $modeB = Wait-ForModeB -TimeoutSec 20 -PollMs $PollIntervalMs
        if ($modeB.Recovered) {
            $modeBMs.Add($modeB.LatencyMs)
            L "  Mode B confirmed at $($modeB.LatencyMs)ms after restore" Green
        } else {
            L "  Mode B NOT confirmed after 20s — may need extra time" Yellow
        }

        $results.Add(@{ Attempt=$i; ModeClass='MODE_A_REACHED'; BatteryClass=$batteryClass;
            ModeALatencyMs=$modeA.LatencyMs; ModeBRestoreMs=$(if ($modeB.Recovered) { $modeB.LatencyMs } else { -1 });
            BatteryPct=$(if ($bat.Ok) { $bat.BatteryPct } else { -1 }); FlipExitCode=$flipResult.ExitCode })
    } else {
        L "  COL02 NEVER appeared after ${ModeATimeoutSec}s — MODE_A_MISSED" Red
        # Still restore
        Invoke-FlipPhase 'FLIP:AppleFilter' $TaskTimeoutSec | Out-Null
        $results.Add(@{ Attempt=$i; ModeClass='MODE_A_MISSED'; BatteryClass='NOT_ATTEMPTED';
            ModeALatencyMs=-1; ModeBRestoreMs=-1; BatteryPct=-1; FlipExitCode=$flipResult.ExitCode })
    }

    if ($i % 5 -eq 0) {
        $ok = ($results | Where-Object { $_.ModeClass -eq 'MODE_A_REACHED' }).Count
        L "  ── Progress $i/$N — Mode A rate: $([Math]::Round(($ok/$i)*100,1))% ($ok/$i) ──" Cyan
    }
}

# ── Aggregate ─────────────────────────────────────────────────────────────────
$total      = $results.Count
$modeAOk    = ($results | Where-Object { $_.ModeClass -eq 'MODE_A_REACHED' }).Count
$modeAMiss  = ($results | Where-Object { $_.ModeClass -eq 'MODE_A_MISSED'  }).Count
$flipFail   = ($results | Where-Object { $_.ModeClass -eq 'FLIP_FAIL'      }).Count
$batOk      = ($results | Where-Object { $_.BatteryClass -eq 'BATTERY_READ_OK'   }).Count
$batFail    = ($results | Where-Object { $_.BatteryClass -eq 'BATTERY_READ_FAIL'  }).Count
$rate       = if ($total -gt 0) { [Math]::Round(($modeAOk / $total) * 100, 1) } else { 0 }

function Pct { param([System.Collections.Generic.List[int]]$L, [int]$P)
    if ($L.Count -eq 0) { return 'N/A' }
    $s = $L | Sort-Object; return $s[[int][Math]::Ceiling($P/100.0*$s.Count)-1]
}

$modeAP50 = Pct $modeAMs 50; $modeAP95 = Pct $modeAMs 95
$modeBP50 = Pct $modeBMs 50; $modeBP95 = Pct $modeBMs 95
$batAvg   = if ($batPcts.Count -gt 0) { [Math]::Round(($batPcts | Measure-Object -Sum).Sum / $batPcts.Count, 1) } else { 'N/A' }

$verdict = if ($rate -ge 70) { 'PASS' } elseif ($rate -ge 30) { 'PARTIAL' } else { 'FAIL' }
$vColor  = switch ($verdict) { 'PASS' { 'Green' }; 'PARTIAL' { 'Yellow' }; 'FAIL' { 'Red' } }

L ''
L '════════════════════════════════════════════════════════' Cyan
L "RESULTS — $total attempts" Cyan
L '════════════════════════════════════════════════════════' Cyan
L "  MODE_A_REACHED:  $modeAOk  ($rate%)" $(if ($rate -ge 70) { 'Green' } elseif ($rate -ge 30) { 'Yellow' } else { 'Red' })
L "  MODE_A_MISSED:   $modeAMiss"
L "  FLIP_FAIL:       $flipFail"
L "  BATTERY_READ_OK: $batOk  (avg $batAvg%)"
L "  BATTERY_READ_FAIL: $batFail"
L "  Time-to-Mode-A:  P50=${modeAP50}ms  P95=${modeAP95}ms"
L "  Mode-B-restore:  P50=${modeBP50}ms  P95=${modeBP95}ms"
L ''
L "VERDICT: $verdict ($rate%)" $vColor
L ''

# ── Write report ──────────────────────────────────────────────────────────────
$jsonlPath = Join-Path $env:TEMP 'm0-validate-raw.jsonl'
$results | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content $jsonlPath -Encoding UTF8

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }
$reportPath = Join-Path $OutputDir 'M0-MODE-B-TO-A-VALIDATION.md'

$report = @"
---
title: M0 Mode B → A Validation Report
prd: PRD-26
date: $(Get-Date -Format 'yyyy-MM-dd')
trigger: FLIP:NoFilter / FLIP:AppleFilter (MM-Dev-Cycle queue)
verdict: $verdict
success_rate: $rate%
attempts: $total
battery_confirmed: $($batOk -gt 0)
---

# M0 Mode B → A Validation Report

**PRD-26 PATH-B — M0 Gating Gate**

## Empirical Findings (2026-05-06)

| Trigger | Result |
|---|---|
| ``pnputil /restart-device`` (H-012 bare) | **FAIL** — COL02 never appeared in 15s; filter reloads before window opens |
| FLIP:NoFilter (LowerFilters swap + disable/enable) | **PASS** — COL02 at ~1s; battery=17%; buf: ``90 04 11 00 00 00 00 00`` |

## Reliability Harness Results

Trigger: ``FLIP:NoFilter`` → COL02 probe → ``HidD_GetInputReport(RID=0x90)`` → ``FLIP:AppleFilter``

| Metric | Value |
|---|---|
| Total attempts | $total |
| MODE_A_REACHED | $modeAOk ($rate%) |
| MODE_A_MISSED | $modeAMiss |
| FLIP_FAIL | $flipFail |
| BATTERY_READ_OK | $batOk |
| BATTERY_READ_FAIL | $batFail |
| Battery avg (successful reads) | $batAvg% |

## Timing

| Metric | P50 | P95 |
|---|---|---|
| Time to COL02 (ms) | $modeAP50 | $modeAP95 |
| Mode B restore after FLIP:AppleFilter (ms) | $modeBP50 | $modeBP95 |

## Verdict: $verdict

$(switch ($verdict) {
    'PASS'    { "Trigger is reliable. Proceed to M1 (multi-device scaffolding). M3 trigger = FLIP:NoFilter / FLIP:AppleFilter sequence via MM-Dev-Cycle queue." }
    'PARTIAL' { "Trigger works but inconsistently. M3 must include retry logic (up to 3x before reporting unavailable)." }
    'FAIL'    { "Trigger unreliable. Investigate FLIP phase errors. Check MM-Dev-Cycle task and mm-state-flip.ps1 at D:\mm3-driver\scripts\." }
})

## Architecture Confirmed

- **Admin bridge**: MM-Dev-Cycle scheduled task (existing, no new registration)
- **Queue dir**: ``C:\mm-dev-queue\``
- **Flip script**: ``D:\mm3-driver\scripts\mm-state-flip.ps1``
- **Mode B restoration**: forced (FLIP:AppleFilter) — device stays in Mode A indefinitely without explicit restore

## Raw Data

JSONL: ``$jsonlPath``
Fields: Attempt, ModeClass, BatteryClass, ModeALatencyMs, ModeBRestoreMs, BatteryPct, FlipExitCode

## References

- PRD-26 PATH-B Userland Recycler
- H-009: Mode A → Mode B natural recovery (confirmed — but irrelevant; Mode A is not a natural recovery state when LowerFilters removed)
- H-012: Mode B → Mode A via bare pnputil — FAIL
- M0a: Mode B → Mode A via LowerFilters swap — PASS
"@

Set-Content $reportPath $report -Encoding UTF8
L "Report: $reportPath" Green
L "Log:    $LogFile" Cyan
