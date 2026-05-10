---
title: PATH-A v5 — Windows-side user checklist
type: install-checklist
date: 2026-05-09
status: blocking — must complete before any install attempt
linked_review: .ai/peer-reviews/2026-05-09-pathA-v5-sre-windows-review.yaml
linked_design: docs/PATH-A-V5-INF-INSTALL-DESIGN.md
linked_static_analysis: docs/PATH-A-V5-F2-STATIC-ANALYSIS.md
linked_prd: PRD-184
---

# Windows-side user checklist for PATH-A v5

Linux-side fixes complete (S1 INF rename, S2 startup-repair PID guard, S3-S5 install/uninstall scripts, E_S1 static analysis). The remaining blocking items can only be done by the user on Windows.

## Toolchain (must be present)

| Tool | Source | Verified path |
|---|---|---|
| EWDK 26100 | mounted at `F:\` from `EWDK_ge_release_svc_prod1_26100_250904-1728.iso` | `F:\Program Files\Windows Kits\10\` |
| `InfVerif.exe` | EWDK | `F:\Program Files\Windows Kits\10\Tools\10.0.26100.0\x64\InfVerif.exe` |
| `tracelog.exe` / `tracefmt.exe` / `tracepdb.exe` | EWDK | `F:\Program Files\Windows Kits\10\bin\10.0.26100.0\x64\` |
| `kd.exe` / `windbg.exe` / `gflags.exe` / `symchk.exe` | EWDK | `F:\Program Files\Windows Kits\10\Debuggers\x64\` |
| Sysinternals (`livekd`, `notmyfaultc`, `dbgview`, `procmon`) | Microsoft Store: Sysinternals Suite | `C:\Program Files\WindowsApps\Microsoft.SysinternalsSuite_*_x64_*\Tools\` |
| Symbol path | env var | `_NT_SYMBOL_PATH=SRV*C:\Symbols*https://msdl.microsoft.com/download/symbols` |

## Observability strategy for the v5 install

The previous BSODs (#1 0x13A heap, #2 0xD1 NULL deref at applewirelessmouse+0x9f0e) were diagnosed post-mortem from minidumps. For v5 we add **live tracing** using EWDK's `tracelog` against the KMDF runtime WPP provider — this captures every WDF callback dispatch even though `applewirelessmouse.sys` itself never calls TraceEvents.

- **KMDF V1 runtime provider GUID:** `544D4C25-942C-46C5-BD06-5BBCBA7C7906`
- **WDF In-Flight Recorder (IFR):** automatic, per-driver circular buffer captured in any kernel dump. Extract via `!wdfkd.wdflogdump applewirelessmouse` in kd.

The orchestrator script `dist/PATH-A-v5/instrumented-test.ps1` chains all of this together:
1. EWDK detection + InfVerif gate
2. Pre-state snapshot via `scripts/mm-bt-stack-snapshot.ps1`
3. Minidump baseline (so we know which dumps are NEW)
4. `tracelog -start` against KMDF provider
5. Run `install.ps1 -Apply`
6. Soak window with periodic state snapshots + minidump watchdog
7. `tracelog -stop` + `tracefmt` convert
8. Post-state snapshot
9. Summary report

If a new minidump appears in `C:\Windows\Minidump\` during the soak: orchestrator copies it to the run dir, stops tracelog, and prints the post-mortem `kd.exe` recipe.

## Phase A — local file work (run on Windows host, no system mutation)

These are safe — they produce files in `/mnt/c/mm-dev-queue/` (or equivalent staging dir), they do not modify System32, DriverStore, or any kernel state.

### A1. Stage the renamed bundle

```powershell
# From WSL or PowerShell, copy the v5 bundle from repo to staging:
Copy-Item -Path "<repo>\dist\PATH-A-v5\*" -Destination "C:\mm-dev-queue\PATH-A-v5\" -Force

# Rename the patched .sys to match the new service name:
# Source: applewirelessmouse-pathA-unsigned.sys (78,424 B, MD5 0d9a89d0..., overlay-intact)
# Target: MagicMouseFixV3.sys (same content, renamed file)
Copy-Item "C:\mm-dev-queue\applewirelessmouse-pathA-unsigned.sys" `
          "C:\mm-dev-queue\PATH-A-v5\MagicMouseFixV3.sys"
```

Do NOT copy the divergent c881c041 binary (the WHQL-overlay-stripped variant) — that's the BSOD'd version per D-S17-03.

### A2. Regenerate the catalog file

The cat covers MagicMouseFixV3.sys (renamed) — it is NOT compatible with the old applewirelessmouse.sys cat.

**Run on Windows host** (PowerShell as Administrator, NOT in WSL):

```powershell
$bundle = "C:\mm-dev-queue\PATH-A-v5"

# Build the catalog file from the bundle directory
New-FileCatalog -Path $bundle `
                -CatalogFilePath "$bundle\MagicMouseFixV3.cat" `
                -CatalogVersion 2

# Sign the cat with MagicMouseFix M14 cert (16940C0F...)
$cert = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { $_.Thumbprint -eq '16940C0F937D569363560D5FEC5CD8FA6D6D9BCE' }
Set-AuthenticodeSignature -FilePath "$bundle\MagicMouseFixV3.cat" `
                          -Certificate $cert `
                          -HashAlgorithm SHA256

# Verify
Get-AuthenticodeSignature "$bundle\MagicMouseFixV3.cat"
```

Note: signtool.exe is NOT used here — Set-AuthenticodeSignature is the cross-session-known reliable path (per AP-28 in PSN-0001 Session 14). The `.sys` file itself is NOT re-signed (overlay-intact strategy per the SRE-Windows review and D-S17-04).

### A3. Read-only system query — confirm what's currently paired

This is read-only and safe. Run as your normal user (no admin needed):

```powershell
Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match 'BTHENUM.*00001124.*PID&0(323|310|269|30D)' } |
    Format-Table Status, FriendlyName, InstanceId -AutoSize
```

Expected output for the v5 plan to make sense:
- v3 (PID 0323) MUST be present and Status=OK
- v1 (PID 030D) presence determines whether the service-name isolation matters in practice. If v1 is paired, it MUST end up bound to stock applewirelessmouse.sys (NOT MagicMouseFixV3.sys) after install.

Save the output. If only v3 is paired, OQ2 is moot (no v1 to cross-fire) — the plan still benefits from the rename (defense in depth) but doesn't require it for safety.

## Phase A4. Validate the dump pipeline (controlled BSOD)

Before risking the v5 driver, prove on THIS host that a forced BSOD produces an analyzable minidump:

```powershell
# Run as admin. WILL BSOD the machine. Auto-reboots.
powershell -ExecutionPolicy Bypass -File C:\mm-dev-queue\PATH-A-v5\notmyfault-validate.ps1 -Phase Trigger

# After the auto-reboot:
powershell -ExecutionPolicy Bypass -File C:\mm-dev-queue\PATH-A-v5\notmyfault-validate.ps1 -Phase Analyze
```

Phase=Analyze runs `kd.exe -z` with `!analyze -v` against the new minidump. If it produces a clean BUGCHECK_CODE + FAILURE_BUCKET_ID, the pipeline is proven and we can proceed to install. If no minidump appears: investigate before continuing (Fast Startup, dump config, pagefile size).

## Phase B — empirical pre-tests on a probe machine (NOT the user's daily driver)

If you don't have a probe machine, **stop here**. The remaining tests on the daily driver are too risky given the BSOD recovery time.

### B1. Gate-zero CI-probe test (E_S2)

Build a single-byte-patched no-op variant to isolate the CI behavior axis from the descriptor-patch axis:

```powershell
# 1. Copy stock f4ae407c.sys (78424 B) to working file
Copy-Item C:\Windows\System32\drivers\applewirelessmouse.sys `
          C:\mm-probe\stock-untouched.sys
Copy-Item C:\mm-probe\stock-untouched.sys C:\mm-probe\probe.sys

# 2. Patch a single benign byte (NOT in the descriptor at file 0xA850)
# Pick a byte at file offset 0xD800 (.pdata padding region) and bump it by 1.
# This breaks Authenticode hash but doesn't change behavior.
$bytes = [System.IO.File]::ReadAllBytes("C:\mm-probe\probe.sys")
$bytes[0xD800] = [byte]($bytes[0xD800] + 1)
[System.IO.File]::WriteAllBytes("C:\mm-probe\probe.sys", $bytes)

# 3. Build a probe INF (copy MagicMouseFixV3.inf, change file references to probe.sys)
# 4. Build + sign cat for probe.sys
# 5. pnputil /add-driver probe.inf /install /force
# 6. Observe outcome:
#    - Loads cleanly with cat → CI accepts overlay-intact + cat fallback (overlay-intact strategy works)
#    - STATUS_INVALID_IMAGE_HASH → CI hard-blocks before cat fallback (must strip overlay; pivot to A2 variant)
#    - Other failure → diagnose
```

This test does NOT install our actual descriptor patch — it isolates the CI behavior. Run it on a Windows 11 24H2 probe machine that mirrors the daily-driver config.

### B2. Driver-rank empirical test (E_S3)

After the Linux-side bundle is staged AND the cat is regenerated AND testsigning is on AND MagicMouseFix cert is in TrustedPublisher:

```powershell
# Install our INF on the probe machine (admin):
pnputil /add-driver C:\mm-probe\PATH-A-v5\MagicMouseFixV3.inf /install /force

# Restart the v3 BTHENUM device:
$v3 = Get-PnpDevice | Where-Object { $_.InstanceId -match 'BTHENUM.*00001124.*PID&0323' } |
      Select-Object -First 1
pnputil /restart-device "$($v3.InstanceId)"
Start-Sleep -Seconds 12

# Verify which INF actually bound:
Get-PnpDeviceProperty -InstanceId $v3.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath'
```

Expected: Data = `MagicMouseFixV3.inf` (or oem<NN>.inf where the published name corresponds to ours per `pnputil /enum-drivers`).

If Data shows `oem10.inf` (Apple's stock), then **WHQL won the ranking** — our INF installed but did not bind. That confirms OQ1 of the SRE-Windows review and means we need a different binding strategy (e.g., direct LowerFilters override post-install, or stronger signing).

## Phase C - install via instrumented orchestrator (only after A4 passes; B1+B2 ideally also)

```powershell
# 1. Disable Fast Startup (S4) - one-time
powercfg /h off

# 2. Enable testsigning - one-time, requires reboot
bcdedit /set testsigning on
# Reboot the host once after both 1 and 2 are set.

# 3. Stage the bundle to C:\ (must be on C: drive, not WSL UNC, for pnputil)
# Already done in Phase A1+A2.

# 4. Run the orchestrator in dry-run first to confirm pre-flight is green:
powershell -ExecutionPolicy Bypass -File C:\mm-dev-queue\PATH-A-v5\instrumented-test.ps1 -SoakSeconds 30

# 5. If green, run live (admin):
powershell -ExecutionPolicy Bypass -File C:\mm-dev-queue\PATH-A-v5\instrumented-test.ps1 -Apply -SoakSeconds 1800

# Orchestrator output is at C:\mm-dev-queue\PATH-A-v5\runs\run-<ts>\:
#   - orchestrator.log         (full timeline)
#   - pre-state.txt            (BTHENUM/services/HID children before)
#   - install-output.log       (install.ps1 child output, includes InfVerif)
#   - kmdf-trace.etl + .txt    (every WDF callback during install + soak)
#   - state-cycle-<n>.txt      (periodic during soak)
#   - post-state.txt           (state after soak completes or BSOD detected)
#   - bsod-*.dmp               (any new minidumps captured during soak)
```

## Phase D — soak + rollback readiness

```powershell
# Run the existing telemetry script every 4 hours during the soak period:
powershell -ExecutionPolicy Bypass -File <repo>\scripts\gather-telemetry.ps1 `
           -Label "post-install-+04h"

# Acceptance criteria for soak:
#   - Cursor + scroll continue working on v3
#   - Battery readable via HidD_GetInputReport(0x90), buf[2] in 0..100 range
#   - v1 mouse still works via Feature 0x47 (control test)
#   - Zero BSOD (0xD1 or 0x13A) over 24h, then 72h

# Rollback at any point:
powershell -ExecutionPolicy Bypass -File C:\mm-dev-queue\PATH-A-v5\uninstall.ps1
```

## Phase E - if BSOD reproduces

If a BSOD occurs during the orchestrator soak, the watchdog already copied the minidump(s) into the run dir (`C:\mm-dev-queue\PATH-A-v5\runs\run-<ts>\bsod-*.dmp`) and stopped tracelog. Post-mortem recipe:

```powershell
$kd  = 'F:\Program Files\Windows Kits\10\Debuggers\x64\kd.exe'
$run = 'C:\mm-dev-queue\PATH-A-v5\runs\run-<ts>'
$env:_NT_SYMBOL_PATH = 'SRV*C:\Symbols*https://msdl.microsoft.com/download/symbols'

# Single-pass analysis with WDF IFR extraction:
& $kd -z "$run\bsod-*.dmp" -c '.sympath '+$env:_NT_SYMBOL_PATH+';.reload /f;!analyze -v;!wdfkd.wdflogdump applewirelessmouse;!wdfkd.wdfdriverinfo applewirelessmouse;q' -logo "$run\kd-analyze.txt"

# Cross-check crash signature against prior BSODs:
#   BSOD #2 2026-05-08: applewirelessmouse+0x9f0e cmp byte ptr [rax],0xa1 with rax=NULL (0xD1)
#   BSOD #1 2026-05-07: 0x13A KERNEL_MODE_HEAP_CORRUPTION type 0x17 LFH delay-free list
```

Compare:
1. `BUGCHECK_CODE`, `FAILURE_BUCKET_ID`, `MODULE_NAME` from `kd-analyze.txt`
2. WDF IFR last few thousand events from `!wdfkd.wdflogdump` - this shows every WDF callback applewirelessmouse.sys received before the crash
3. `kmdf-trace.etl.txt` from the orchestrator run for the system-wide KMDF event timeline
4. `state-cycle-*.txt` snapshots for the LowerFilters/Stack progression

Save findings to `docs/PATH-A-V5-BSOD-<date>.md`. Update PSN-0001 with new H/D entries. Run `uninstall.ps1` to restore stock.

At that point, PATH-A v5 is empirically confirmed to have unresolved BSOD risk and the strategic call (PATH-A vs PATH-B) becomes the user's to make.

## Reference

- Linux-side fixes (this branch): `ai/pathA-v5-sre-windows-fixes`
- SRE-Windows verdict: `.ai/peer-reviews/2026-05-09-pathA-v5-sre-windows-review.yaml`
- F2 static analysis: `docs/PATH-A-V5-F2-STATIC-ANALYSIS.md`
- Bundle: `dist/PATH-A-v5/`
- BSOD #1 (heap): `docs/PATH-A-V3-BSOD-RCA.md` (covers BSOD #2 0xD1, BSOD #1 referenced)
- Reference project: `D:\Users\Lesley\Downloads\MagicMouse2DriversWin11x64-master\`
