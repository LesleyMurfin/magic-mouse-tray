<#
.SYNOPSIS
    M0 gating validation: empirically test H-012 (Mode B → Mode A on demand via pnputil /restart-device).
    Runs N attempts. Classifies each. Produces aggregate stats + docs/M0-MODE-B-TO-A-VALIDATION.md.

.DESCRIPTION
    PATH-B premise: pnputil /restart-device on the BTHENUM HID PDO triggers AddDevice,
    during which a brief window may allow COL02 (split descriptor) to enumerate before the
    Apple filter (applewirelessmouse.sys) applies the unified descriptor (Mode B).

    H-012 has NOT been confirmed — H-009 only confirmed Mode A → Mode B natural recovery.
    This harness validates H-012 before any implementation begins (PRD-26 M0 gate).

.NOTES
    REQUIRES: Admin (pnputil /restart-device needs elevated).
    Mouse must be paired and in Mode B steady state (COL02 absent, LowerFilters active).
    Run from the magic-mouse-tray project root.

.PARAMETER N
    Number of recycle attempts. Default 100.

.PARAMETER ModeATimeoutSec
    Max seconds to wait for COL02 to appear after restart. Default 30.

.PARAMETER ModeBRecoverTimeoutSec
    Max seconds to wait for natural Mode B recovery after battery read. Default 60.

.PARAMETER BatteryProbe
    If set: attempt HidD_GetInputReport(RID=0x90) on COL02 when Mode A reached.

.PARAMETER PollIntervalMs
    COL02 polling interval in ms. Default 500.

.PARAMETER OutputDir
    Directory for M0-MODE-B-TO-A-VALIDATION.md. Default 'docs'.

.EXAMPLE
    # Full 100-attempt run with battery probe (recommended for M0 gate):
    pwsh -ExecutionPolicy Bypass -File .\scripts\m0-validate-recycle-to-modeA.ps1 -BatteryProbe

    # Quick 10-attempt feasibility check:
    pwsh -ExecutionPolicy Bypass -File .\scripts\m0-validate-recycle-to-modeA.ps1 -N 10 -BatteryProbe
#>
[CmdletBinding()]
param(
    [int]$N                      = 100,
    [int]$ModeATimeoutSec        = 30,
    [int]$ModeBRecoverTimeoutSec = 60,
    [switch]$BatteryProbe,
    [int]$PollIntervalMs         = 500,
    [string]$OutputDir           = 'docs'
)
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version 2

# ── Admin guard ──────────────────────────────────────────────────────────────
$id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object System.Security.Principal.WindowsPrincipal($id)).IsInRole(
    [System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'Run as Administrator (pnputil /restart-device requires admin).'
    exit 3
}

# ── P/Invoke (HID) — compiled once per session ───────────────────────────────
if (-not ([System.Management.Automation.PSTypeName]'M0Hid').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
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
function L {
    param([string]$M, [string]$C = 'White')
    $line = "[$(Get-Date -Format 'HH:mm:ss.fff')] $M"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Host $line -ForegroundColor $C
}

# ── Device discovery ──────────────────────────────────────────────────────────
function Get-BthenumHidInstanceId {
    # Returns the BTHENUM HID PDO InstanceId for Magic Mouse v3 (PID 0x0323).
    $dev = Get-PnpDevice -Class HIDClass -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match 'BTHENUM\\\{00001124[^\\]*VID&0001004C_PID&0323' -and
                       $_.Status -eq 'OK' } |
        Select-Object -First 1
    return $(if ($dev) { $dev.InstanceId } else { $null })
}

function Get-Col02Device {
    # Returns PnP device object for COL02 (Mode A indicator) if present and OK.
    return Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like '*VID&0001004C_PID&0323*COL02*' -and
                       $_.Status -eq 'OK' } |
        Select-Object -First 1
}

function ConvertTo-HidDevicePath {
    param([string]$InstanceId)
    # Device interface path from InstanceId: lower-case, \ → #, wrap + HID interface GUID.
    $normalized = $InstanceId.ToLower().Replace('\', '#')
    return "\\?\$normalized#{4d1e55b2-f16f-11cf-88cb-001111000030}"
}

# ── Recycle trigger ───────────────────────────────────────────────────────────
function Invoke-PnpRestart {
    param([string]$InstanceId)
    $result = & pnputil.exe /restart-device $InstanceId 2>&1
    return @{
        ExitCode = $LASTEXITCODE
        Output   = ($result -join ' ').Trim()
    }
}

# ── Polling helpers ───────────────────────────────────────────────────────────
function Wait-ForModeA {
    param([int]$TimeoutSec, [int]$PollMs)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ([DateTime]::UtcNow -lt $deadline) {
        $col02 = Get-Col02Device
        if ($col02) {
            $sw.Stop()
            return @{ Reached = $true; LatencyMs = [int]$sw.ElapsedMilliseconds; Col02Id = $col02.InstanceId }
        }
        Start-Sleep -Milliseconds $PollMs
    }
    $sw.Stop()
    return @{ Reached = $false; LatencyMs = [int]$sw.ElapsedMilliseconds; Col02Id = $null }
}

function Wait-ForModeB {
    param([int]$TimeoutSec, [int]$PollMs)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Get-Col02Device)) {
            $sw.Stop()
            return @{ Recovered = $true; LatencyMs = [int]$sw.ElapsedMilliseconds }
        }
        Start-Sleep -Milliseconds $PollMs
    }
    $sw.Stop()
    return @{ Recovered = $false; LatencyMs = [int]$sw.ElapsedMilliseconds }
}

# ── Battery probe (0x90) ──────────────────────────────────────────────────────
function Read-Battery0x90 {
    param([string]$Col02InstanceId)
    $path = ConvertTo-HidDevicePath $Col02InstanceId
    $h = [M0Hid]::CreateFile($path, [uint32]0, [uint32]3, [IntPtr]::Zero, [uint32]3, [uint32]0, [IntPtr]::Zero)
    if ($h.IsInvalid) {
        $gle = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        return @{ Ok = $false; BatteryPct = -1; Gle = $gle; Note = "CreateFile FAIL gle=$gle" }
    }
    try {
        $buf = New-Object byte[] 65
        $buf[0] = 0x90
        $ok = [M0Hid]::HidD_GetInputReport($h, $buf, $buf.Length)
        $gle = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($ok -and $buf[2] -ge 0 -and $buf[2] -le 100) {
            return @{ Ok = $true; BatteryPct = [int]$buf[2]; Gle = 0; Note = "buf[0..3]=$(($buf[0..3] | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')" }
        } else {
            return @{ Ok = $false; BatteryPct = -1; Gle = $gle; Note = "GetInputReport ok=$ok gle=$gle buf[2]=$($buf[2])" }
        }
    } finally {
        $h.Close()
    }
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
L '════════════════════════════════════════════════════════' Cyan
L "M0 GATING VALIDATION — H-012: Mode B → Mode A on demand" Cyan
L "PRD-26 / PATH-B Userland Recycler" Cyan
L '════════════════════════════════════════════════════════' Cyan
L ''
L "Parameters: N=$N  ModeATimeout=${ModeATimeoutSec}s  RecoverTimeout=${ModeBRecoverTimeoutSec}s  BatteryProbe=$BatteryProbe  PollIntervalMs=$PollIntervalMs"

$bthenumId = Get-BthenumHidInstanceId
if (-not $bthenumId) {
    L 'ABORT: Magic Mouse v3 (PID 0x0323) BTHENUM HID device not found. Pair the mouse and retry.' Red
    exit 1
}
L "Target device: $bthenumId" Green

# Verify Mode B steady state before starting
$initialCol02 = Get-Col02Device
if ($initialCol02) {
    L 'ABORT: COL02 is present — device is already in Mode A. Ensure Apple stock driver is active (Mode B).' Red
    L "COL02: $($initialCol02.InstanceId)" Red
    exit 1
}
L 'Pre-flight: Mode B confirmed (COL02 absent). Starting harness.' Green
L ''

# ── Main loop ─────────────────────────────────────────────────────────────────
$results = [System.Collections.Generic.List[hashtable]]::new()
$modeALatencies  = [System.Collections.Generic.List[int]]::new()
$modeBLatencies  = [System.Collections.Generic.List[int]]::new()

for ($i = 1; $i -le $N; $i++) {
    L "── Attempt $i / $N ──"

    # Refresh InstanceId (MAC-derived suffix may be stable but re-query to be safe)
    $bthenumId = Get-BthenumHidInstanceId
    if (-not $bthenumId) {
        L "  Device lost — mouse disconnected? Aborting at attempt $i." Red
        break
    }

    # Verify Mode B at start of each attempt
    if (Get-Col02Device) {
        L "  WARNING: COL02 still present from prior attempt — waiting extra 10s for Mode B recovery..." Yellow
        Start-Sleep -Seconds 10
        if (Get-Col02Device) {
            L "  COL02 still present after wait. Recording as PRECONDITION_FAIL and skipping." Red
            $results.Add(@{ Attempt=$i; ModeClass='PRECONDITION_FAIL'; BatteryClass='NOT_ATTEMPTED';
                ModeALatencyMs=-1; ModeBRecoverMs=-1; BatteryPct=-1; RestartExitCode=-1; Note='COL02 not cleared from prior attempt' })
            continue
        }
    }

    # Trigger restart
    L "  pnputil /restart-device $bthenumId"
    $restart = Invoke-PnpRestart $bthenumId
    L "  restart exit=$($restart.ExitCode) output: $($restart.Output)"

    if ($restart.ExitCode -ne 0) {
        $modeClass = if ($restart.ExitCode -eq 22 -or $restart.Output -match 'disabled|not present') {
            'ERROR_22_DISABLED'
        } else {
            'ERROR_OTHER'
        }
        L "  Classified: $modeClass (exit=$($restart.ExitCode))" Yellow
        $results.Add(@{ Attempt=$i; ModeClass=$modeClass; BatteryClass='NOT_ATTEMPTED';
            ModeALatencyMs=-1; ModeBRecoverMs=-1; BatteryPct=-1; RestartExitCode=$restart.ExitCode;
            Note=$restart.Output })
        # Brief pause to let device settle
        Start-Sleep -Seconds 3
        continue
    }

    # Wait for Mode A (COL02 appearance)
    $modeAResult = Wait-ForModeA -TimeoutSec $ModeATimeoutSec -PollMs $PollIntervalMs

    $modeClass    = if ($modeAResult.Reached) { 'MODE_A_REACHED' } else { 'MODE_B_LOCKED' }
    $batteryClass = 'NOT_ATTEMPTED'
    $batteryPct   = -1

    if ($modeAResult.Reached) {
        $modeALatencies.Add($modeAResult.LatencyMs)
        L "  Mode A reached in $($modeAResult.LatencyMs)ms — COL02: $($modeAResult.Col02Id)" Green

        if ($BatteryProbe) {
            L '  Probing battery (RID=0x90)...'
            $batResult = Read-Battery0x90 $modeAResult.Col02Id
            if ($batResult.Ok) {
                $batteryClass = 'BATTERY_READ_OK'
                $batteryPct   = $batResult.BatteryPct
                L "  Battery: $batteryPct% — $($batResult.Note)" Green
            } else {
                $batteryClass = 'BATTERY_READ_FAIL'
                L "  Battery read failed: $($batResult.Note)" Yellow
            }
        }

        # Wait for natural Mode B recovery
        L "  Waiting for Mode B natural recovery (up to ${ModeBRecoverTimeoutSec}s)..."
        $modeBResult = Wait-ForModeB -TimeoutSec $ModeBRecoverTimeoutSec -PollMs $PollIntervalMs
        if ($modeBResult.Recovered) {
            $modeBLatencies.Add($modeBResult.LatencyMs)
            L "  Mode B recovered in $($modeBResult.LatencyMs)ms" Green
        } else {
            L "  Mode B did NOT recover within ${ModeBRecoverTimeoutSec}s — forcing restart to reset state" Yellow
            Invoke-PnpRestart $bthenumId | Out-Null
            Start-Sleep -Seconds 5
        }

        $results.Add(@{ Attempt=$i; ModeClass=$modeClass; BatteryClass=$batteryClass;
            ModeALatencyMs=$modeAResult.LatencyMs; ModeBRecoverMs=$(if ($modeBResult.Recovered) { $modeBResult.LatencyMs } else { -1 });
            BatteryPct=$batteryPct; RestartExitCode=$restart.ExitCode; Note='' })

    } else {
        L "  Mode B locked — COL02 never appeared in ${ModeATimeoutSec}s" Yellow
        $results.Add(@{ Attempt=$i; ModeClass='MODE_B_LOCKED'; BatteryClass='NOT_ATTEMPTED';
            ModeALatencyMs=-1; ModeBRecoverMs=-1; BatteryPct=-1; RestartExitCode=$restart.ExitCode; Note='' })
        # Device already back in Mode B; small settle delay
        Start-Sleep -Seconds 2
    }

    # Progress report every 10 attempts
    if ($i % 10 -eq 0) {
        $modeACount = ($results | Where-Object { $_.ModeClass -eq 'MODE_A_REACHED' }).Count
        $rate = [Math]::Round(($modeACount / $i) * 100, 1)
        L "  ── Progress $i/$N — Mode A rate so far: $rate% ($modeACount/$i) ──" Cyan
    }
}

# ── Aggregate stats ────────────────────────────────────────────────────────────
$total            = $results.Count
$modeACnt         = ($results | Where-Object { $_.ModeClass -eq 'MODE_A_REACHED' }).Count
$modeBLockedCnt   = ($results | Where-Object { $_.ModeClass -eq 'MODE_B_LOCKED' }).Count
$error22Cnt       = ($results | Where-Object { $_.ModeClass -eq 'ERROR_22_DISABLED' }).Count
$errorOtherCnt    = ($results | Where-Object { $_.ModeClass -eq 'ERROR_OTHER' }).Count
$precondFailCnt   = ($results | Where-Object { $_.ModeClass -eq 'PRECONDITION_FAIL' }).Count
$batOkCnt         = ($results | Where-Object { $_.BatteryClass -eq 'BATTERY_READ_OK' }).Count
$batFailCnt       = ($results | Where-Object { $_.BatteryClass -eq 'BATTERY_READ_FAIL' }).Count
$successRate      = if ($total -gt 0) { [Math]::Round(($modeACnt / $total) * 100, 1) } else { 0 }

function Percentile { param([System.Collections.Generic.List[int]]$List, [int]$Pct)
    if ($List.Count -eq 0) { return 'N/A' }
    $sorted = $List | Sort-Object
    $idx = [int][Math]::Ceiling($Pct / 100.0 * $sorted.Count) - 1
    return $sorted[$idx]
}

$modeAP50  = Percentile $modeALatencies 50
$modeAP95  = Percentile $modeALatencies 95
$modeBP50  = Percentile $modeBLatencies 50
$modeBP95  = Percentile $modeBLatencies 95

$verdict = if ($successRate -ge 70)      { 'PASS'    }
           elseif ($successRate -ge 30)  { 'PARTIAL' }
           else                          { 'FAIL'    }

$verdictColor = switch ($verdict) { 'PASS' { 'Green' }; 'PARTIAL' { 'Yellow' }; 'FAIL' { 'Red' } }

L ''
L '════════════════════════════════════════════════════════' Cyan
L "RESULTS — $total attempts completed" Cyan
L '════════════════════════════════════════════════════════' Cyan
L "  MODE_A_REACHED:       $modeACnt  ($successRate%)" $(if ($successRate -ge 70) { 'Green' } elseif ($successRate -ge 30) { 'Yellow' } else { 'Red' })
L "  MODE_B_LOCKED:        $modeBLockedCnt"
L "  ERROR_22_DISABLED:    $error22Cnt"
L "  ERROR_OTHER:          $errorOtherCnt"
L "  PRECONDITION_FAIL:    $precondFailCnt"
L "  BATTERY_READ_OK:      $batOkCnt"
L "  BATTERY_READ_FAIL:    $batFailCnt"
L "  Time-to-Mode-A:       P50=${modeAP50}ms  P95=${modeAP95}ms"
L "  Mode-B-recovery:      P50=${modeBP50}ms  P95=${modeBP95}ms"
L ''
L "VERDICT: $verdict ($successRate% success rate)" $verdictColor
L ''

$verdictNote = switch ($verdict) {
    'PASS'    { 'H-012 CONFIRMED. Proceed to M1 (multi-device scaffolding).' }
    'PARTIAL' { 'H-012 PARTIALLY confirmed. M3 must include retry + exponential backoff (up to 3x per poll).' }
    'FAIL'    { 'H-012 NOT confirmed at simple pnputil /restart-device. Run M0a/M0b/M0c/M0d sub-tests before M1.' }
}
L $verdictNote

# ── Write raw JSONL ───────────────────────────────────────────────────────────
$jsonlPath = Join-Path $env:TEMP 'm0-validate-raw.jsonl'
$results | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content -Path $jsonlPath -Encoding UTF8
L "Raw data: $jsonlPath"

# ── Write M0-MODE-B-TO-A-VALIDATION.md ────────────────────────────────────────
$outPath = Join-Path $OutputDir 'M0-MODE-B-TO-A-VALIDATION.md'
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }

$batSection = if ($BatteryProbe) {
    @"

## Battery Read Results (0x90 via HidD_GetInputReport on COL02)

| Metric | Value |
|---|---|
| BATTERY_READ_OK | $batOkCnt |
| BATTERY_READ_FAIL | $batFailCnt |
| Mode A attempts with probe | $modeACnt |
| Battery read success rate | $(if ($modeACnt -gt 0) { "$([Math]::Round(($batOkCnt/$modeACnt)*100,1))%" } else { 'N/A' }) |

$(if ($batOkCnt -gt 0) {
    $samples = ($results | Where-Object { $_.BatteryClass -eq 'BATTERY_READ_OK' } | Select-Object -First 5 | ForEach-Object { "  - Attempt $($_.Attempt): $($_.BatteryPct)%" }) -join "`n"
    "Sample readings:`n$samples"
})
"@
} else { '' }

$subTestSection = if ($verdict -eq 'FAIL') { @"

## Sub-Test Escalation Required

M0 FAIL verdict requires sub-test validation before M1 begins. Recommended execution order:

| Sub-Test | Trigger | Purpose |
|---|---|---|
| **M0a** | Remove `applewirelessmouse` from LowerFilters → pnputil /restart-device → re-add filter → restart | Explicit filter-detach window |
| **M0b** | Delete BTHPORT device cache key → pnputil /restart-device on BTHPORT | Cache bypass |
| **M0c** | pnputil /restart-device on BTHENUM parent (not HID PDO) | Higher-level recycle |
| **M0d** | pnputil /disable-device → pnputil /scan-devices → pnputil /enable-device | Full re-enumeration |

Run each sub-test for 20 attempts minimum. Select highest Mode A success rate. Update PRD-26 Decisions table with selected trigger. Revise M3 design before implementing.
"@ } else { '' }

$reportContent = @"
---
title: M0 MODE B → A Recycle Validation
prd: PRD-26
hypothesis: H-012
date: $(Get-Date -Format 'yyyy-MM-dd')
verdict: $verdict
success_rate: $successRate%
attempts: $total
---

# M0 Validation Report — Mode B → Mode A Recycle Reliability

**PRD-26 PATH-B: GATING gate. All M1+ implementation is blocked on this result.**

## Verdict: $verdict

$verdictNote

Success rate: **$successRate%** ($modeACnt Mode A reached / $total attempts)
Threshold: PASS ≥70% · PARTIAL 30–70% · FAIL <30%

## Test Configuration

| Parameter | Value |
|---|---|
| Trigger | ``pnputil /restart-device <BTHENUM HID PDO>`` |
| Total attempts | $N |
| Mode A timeout | ${ModeATimeoutSec}s |
| Mode B recovery timeout | ${ModeBRecoverTimeoutSec}s |
| Poll interval | ${PollIntervalMs}ms |
| Battery probe | $BatteryProbe |
| Run date | $(Get-Date -Format 'yyyy-MM-dd HH:mm') |
| Mouse state | Mode B steady-state (applewirelessmouse in LowerFilters, COL02 absent) |
| LowerFilters modified | **No** (stock applewirelessmouse driver active throughout) |

## Mode Classification Results

| Classification | Count | % |
|---|---|---|
| MODE_A_REACHED | $modeACnt | $successRate% |
| MODE_B_LOCKED | $modeBLockedCnt | $([Math]::Round(($modeBLockedCnt / [Math]::Max($total,1)) * 100, 1))% |
| ERROR_22_DISABLED | $error22Cnt | $([Math]::Round(($error22Cnt / [Math]::Max($total,1)) * 100, 1))% |
| ERROR_OTHER | $errorOtherCnt | $([Math]::Round(($errorOtherCnt / [Math]::Max($total,1)) * 100, 1))% |
| PRECONDITION_FAIL | $precondFailCnt | $([Math]::Round(($precondFailCnt / [Math]::Max($total,1)) * 100, 1))% |

## Timing Analysis

| Metric | P50 | P95 |
|---|---|---|
| Time to Mode A (ms) | $modeAP50 | $modeAP95 |
| Mode B natural recovery (ms) | $modeBP50 | $modeBP95 |

$(if ($verdict -in 'PASS','PARTIAL') {
    "Mode A latency distribution is a key input for the polling strategy in M3 (idle timer design)."
})
$batSection

## Interpretation

$(switch ($verdict) {
    'PASS' { @"
**H-012 confirmed.** The simple ``pnputil /restart-device`` trigger reliably transitions the device
from Mode B (unified descriptor, no COL02) to Mode A (split descriptor, COL02 present) in $successRate%
of attempts. This validates the core PATH-B architectural assumption.

$(if ($successRate -lt 90) { "Note: $successRate% success rate means ~$(100-$successRate)% of polls may return no battery reading on first attempt. M3 should include a single retry on failure before reporting unavailable." })

Next step: proceed to M1 (multi-device detection scaffolding).
"@ }
    'PARTIAL' { @"
**H-012 partially confirmed.** Mode A is reachable but not reliably ($successRate% success rate).
The simple ``pnputil /restart-device`` trigger works but requires retry logic.

M3 design MUST include:
- Retry up to 3× with exponential backoff (500ms → 1000ms → 2000ms)
- Storm cap: if >10% failures in 24h window, alert user + disable auto-recycle
- Report battery as unavailable after 3 consecutive failures

Next step: proceed to M1. Update M3 milestone with retry design before implementing.
"@ }
    'FAIL' { @"
**H-012 NOT confirmed.** The simple ``pnputil /restart-device`` trigger does not reliably transition
the device to Mode A ($successRate% success rate — below the 30% PARTIAL threshold, or near it).

The Apple filter (applewirelessmouse.sys) likely loads before the COL02 collection can be
read. Sub-tests M0a–M0d must identify a trigger that provides a long enough filter-load gap.

Do NOT proceed to M1 until a sub-test achieves ≥30% success rate and a revised trigger is
selected and documented in the PRD-26 Decisions table.
"@ }
})

## Raw Data

Full per-attempt JSONL: ``$jsonlPath``

Fields: Attempt, ModeClass, BatteryClass, ModeALatencyMs, ModeBRecoverMs, BatteryPct, RestartExitCode, Note
$subTestSection

## References

- PRD-26: PATH-B Userland Recycler for Magic Mouse Battery + Scroll
- H-009: Mode A → Mode B natural recovery (confirmed)
- H-012: Mode B → Mode A on demand (this test)
- PSN-0001: Magic Mouse HID Battery Reader Driver Binding
"@

Set-Content -Path $outPath -Value $reportContent -Encoding UTF8
L "Report written: $outPath" Green
L ''
L "DONE. Log: $LogFile" Cyan
