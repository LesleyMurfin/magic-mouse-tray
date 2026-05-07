---
id: TP-001
title: "MagicMouseTray — Test Plan v1.0"
version: 1.0.0
bcp_ref: BCP-STD-015
component: MagicMouseTray
status: Active
created: 2026-04-22
owner: Lesley Murfin
---

# MagicMouseTray — Test Plan

## What You Need to Do (Read This First)

Three test sessions required before v1.1.0 release. Do them in order.

---

### Session 1 — Does it work on your existing setup? (30 min, Windows, Admin)

Your machine already has the driver partially configured. This session confirms the code works
before you wipe anything.

1. **Fix one code issue first** (agent does this, not you): Add a log line to `MouseBatteryReader.cs`
   that prints the `InputReportByteLength` value. Without this, we can't confirm the battery reader
   will work on a clean install. This is the single highest-risk unknown right now.
2. Rebuild the binary after the fix.
3. **You run**: Copy `\\wsl.localhost\Ubuntu\tmp\mmtray-build\MagicMouseTray.exe` to `C:\Temp\`
4. **You run**: Start the app. Wait 10 seconds.
5. **You check**: Does the tray icon show a battery percentage? (not "disconnected")
6. **You check**: Open `C:\Users\<you>\AppData\Local\MagicMouseTray\debug.log` — look for:
   - `InputReportByteLength=X` — X must be **3 or higher** (if it's 2, stop and report it)
   - `OK path=...col02... battery=NN%`
   - No `READ_FAILED` lines after the first 30 seconds
7. **You test**: Does the mouse still scroll normally while the app runs?
8. **You reboot**: Normal reboot.
9. **You check after reboot**: Battery % still shows in tray without doing anything?
10. **You check**: `C:\ProgramData\MagicMouseTray\startup-repair.log` — last line should say
    `REPAIRED: COL02 present` or `COL02 present — no repair needed`

**Session 1 passes when**: Battery reads in tray + `InputReportByteLength >= 3` in log + scroll works + battery persists after reboot.

---

### Session 2 — Clean-slate install (1 hour, Windows, Admin) — Magic Mouse v3

This simulates a brand new user who just downloaded the software. Everything gets wiped first.

1. **You run the teardown script** (at the bottom of this file, PowerShell as Admin)
2. **You reboot**
3. **You confirm clean**: No `applewirelessmouse` in `pnputil /enum-drivers`. No scheduled task. Mouse scrolls (BT still connected) but no battery.
4. **You run**: `sign-and-install.ps1` as Administrator from the repo folder
5. **You check**: Script completes all 9 steps with no errors
6. **You re-pair**: Remove mouse from Bluetooth Settings → re-add it. Wait for it to reconnect.
7. **You run**: Start the app
8. **You check**: Battery % in tray within 10 seconds
9. **You reboot**
10. **You check**: Battery % shows automatically after reboot, no manual steps

**Session 2 passes when**: Full cycle works from nothing → battery in tray → survives reboot, zero manual steps beyond sign-and-install + re-pair.

---

### Session 3 — Clean-slate install — Magic Mouse v1 (30 min, Windows, Admin)

Same as Session 2 but with your v1 Magic Mouse (PID 030d). Confirms the software works for
older hardware that many users will have.

1. Repeat teardown
2. Pair the v1 mouse
3. Run `sign-and-install.ps1`
4. Re-pair v1 mouse
5. Start app
6. Confirm battery reads (PID 030d device)
7. Reboot → confirm battery persists

**Session 3 passes when**: Same result as Session 2 but on v1 hardware.

---

### Before Sessions 2 and 3 — Code Fixes Required

These issues were found in adversarial peer review and will cause test failures if not fixed first:

| # | What's broken | Who fixes it | Blocks |
|---|--------------|-------------|--------|
| BLK-01 | Battery reader may silently skip COL02 if report is 2 bytes (needs log verification in Session 1) | Agent | Session 1 diagnosis |
| BLK-02 | DriverHealthChecker returns `Ok` when zero devices found (false healthy signal) | Agent | T1 unit tests |
| BLK-03 | Scheduled task points to wherever you ran the script from — if that's Downloads, any user can overwrite it | Agent | Session 2 security |
| BLK-04 | Log directory not locked — privilege escalation possible via symlink | Agent | Session 3 security |

BLK-03 and BLK-04 don't affect whether battery reads work — they affect whether it's safe to ship publicly. Session 1 and 2 can proceed without fixing BLK-03/04, but they must be fixed before the public v1.1.0 release.

---

## BLUF

Seven-tier test plan (BCP-STD-015) for MagicMouseTray v1.1.0 public release. Three test sessions
(incremental, clean v3, clean v1) must pass before release tag. Four code blockers must be resolved
before Sessions 2–3. Goal: a new user runs `sign-and-install.ps1`, re-pairs their mouse, and gets
battery in the tray — no manual registry edits, no debugging, no what I went through.

---

## Device Matrix

| Label | Model | PID | VID | Notes |
|-------|-------|-----|-----|-------|
| **MM-V3** | Magic Mouse 2024 | `0323` | `0001004C` | Lesley's primary device |
| **MM-V1** | Magic Mouse v1 | `030d` | `000205AC` | Older device — verify driver support |

---

## Test Environments

| Environment | Description | When Used |
|------------|-------------|-----------|
| **ENV-A: Incremental** | Existing driver install, existing pairing | T1–T3, initial T4 run |
| **ENV-B: Clean-slate** | Full teardown then fresh install from nothing | T4 E2E golden path, T8 upgrade |

---

## Clean-Slate Teardown Procedure

Run these steps as Administrator to fully reset to pre-install state before ENV-B tests.

```powershell
# 1. Stop any running MagicMouseTray instance
Stop-Process -Name MagicMouseTray* -Force -ErrorAction SilentlyContinue

# 2. Remove scheduled startup repair task
Unregister-ScheduledTask -TaskName "MagicMouseTray-StartupRepair" -Confirm:$false -ErrorAction SilentlyContinue

# 3. Remove applewirelessmouse driver package(s)
$pnpRaw = (pnputil /enum-drivers 2>$null) | Out-String
$slots = ($pnpRaw -split '(?=Published Name:)') |
    Where-Object { $_ -match 'applewirelessmouse' } |
    ForEach-Object { if ($_ -match 'Published Name:\s+(oem\d+\.inf)') { $Matches[1] } }
if ($slots) {
    $slots | ForEach-Object { pnputil /delete-driver $_ /uninstall /force }
} else { Write-Host "No applewirelessmouse driver found" }

# 4. Remove LowerFilters from BTHENUM device key (for both known PIDs if present)
@("0323","030d","0269","0310") | ForEach-Object {
    $pid = $_
    Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Enum\BTHENUM" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "_PID&$pid" } |
        ForEach-Object { Remove-ItemProperty -Path $_.PSPath -Name LowerFilters -ErrorAction SilentlyContinue }
}

# 5. Remove MagicMouseFix cert from TrustedPublisher and Root stores
Get-ChildItem Cert:\LocalMachine\TrustedPublisher | Where-Object { $_.Subject -match "MagicMouseFix" } |
    Remove-Item -ErrorAction SilentlyContinue
Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -match "MagicMouseFix" } |
    Remove-Item -ErrorAction SilentlyContinue

# 6. Disable test signing
bcdedit /set testsigning off

# 7. Clean up temp files and log directory
Remove-Item "C:\Temp\MagicMouseFix.cer" -Force -ErrorAction SilentlyContinue
Remove-Item "C:\ProgramData\MagicMouseTray" -Recurse -Force -ErrorAction SilentlyContinue

# 8. Unpair the Magic Mouse from Bluetooth Settings (manual — do in Settings > Bluetooth)

Write-Host "Teardown complete. Reboot before clean-slate test."
```

**After teardown**: Reboot, confirm no `MagicMouseTray-StartupRepair` task exists, confirm
`applewirelessmouse` is not in `pnputil /enum-drivers`.

---

## Tier 1 — Unit Tests (C# Logic)

**Scope**: Individual C# functions in isolation, no Windows hardware required.
**When**: On every code change, CI/CD.
**Owner**: Developer.

| Test ID | Component | Test Case | Pass Criteria |
|---------|-----------|-----------|---------------|
| T1-01 | DriverHealthChecker | Zero devices found → returns `NotInstalled` (not `Ok`) | `CheckDriverHealth()` returns `DriverStatus.NotInstalled` when no BTHENUM keys match known PIDs |
| T1-02 | DriverHealthChecker | One Ok device, one UnknownAppleMouse device → returns `UnknownAppleMouse` | Worst-state wins: `UnknownAppleMouse > NotBound > Ok` |
| T1-03 | DriverHealthChecker | One Ok device, one NotBound device → returns `NotBound` | Correct priority ordering |
| T1-04 | DriverHealthChecker | Two Ok devices (same PID) → returns `Ok` | Dual-device same PID handled |
| T1-05 | MouseBatteryReader | `ValidateBattery` with buf[1]=0 → returns -1 | Zero battery value rejected |
| T1-06 | MouseBatteryReader | `ValidateBattery` with buf[1]=101 → returns -1 | Out-of-range value rejected |
| T1-07 | MouseBatteryReader | `ValidateBattery` with buf[1]=75 → returns 75 | Valid value passed through |

**Note**: T1-01 requires code fix before this tier can pass — current `CheckDriverHealth()` returns `Ok`
on zero devices (default initialization bug from adversarial review).

---

## Tier 2 — Section Tests (Component Isolation)

**Scope**: Each system component verified independently before integration.
**When**: After driver install, before running the app.
**Owner**: Developer (Lesley running on Windows).
**Environment**: ENV-A (incremental) first, then ENV-B (clean-slate).

| Test ID | Component | Test Case | Command | Pass Criteria |
|---------|-----------|-----------|---------|---------------|
| T2-01 | Driver install | applewirelessmouse package installed | `pnputil /enum-drivers \| Select-String applewireless` | OEM slot visible with correct provider |
| T2-02 | Driver binding | LowerFilters set on BTHENUM Enum key | `(Get-PnpDevice -Class HIDClass \| Where-Object { $_.InstanceId -imatch '00001124.*0001004C.*0323' }).InstanceId \| ForEach-Object { (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\$_").LowerFilters }` | Value = `applewirelessmouse`. **Note**: reads BTHENUM Enum key, NOT HID Enum key — only the BTHENUM key has LowerFilters |
| T2-03 | HID enumeration | COL01 and COL02 both Status OK | `Get-PnpDevice \| Where-Object { $_.InstanceId -match "0323" -and $_.Status -eq "OK" }` | Count = 2 |
| T2-04 | Scheduled task | `MagicMouseTray-StartupRepair` registered | `Get-ScheduledTask -TaskName MagicMouseTray-StartupRepair` | Task exists, trigger = AtStartup, delay = PT30S, principal = SYSTEM |
| T2-05 | Cert trust | MagicMouseFix in TrustedPublisher | `Get-ChildItem Cert:\LocalMachine\TrustedPublisher \| Where Subject -match MagicMouseFix` | Certificate present |
| T2-06 | Test signing | Test signing mode active | `bcdedit /enum {current} \| Select-String testsigning` | `testsigning Yes` |
| T2-07 | Log directory | Log dir created with correct ACL | `icacls C:\ProgramData\MagicMouseTray` | SYSTEM: Full, Administrators: Full, Users: no write |

**T2-07 is a new requirement** from the adversarial review (TOCTOU symlink mitigation) — sign-and-install.ps1
needs to create and lock the log directory before startup-repair.ps1 first runs.

---

## Tier 3 — Integration Tests (App + HID Stack)

**Scope**: MagicMouseTray binary running, reading from live Windows HID devices.
**When**: After T2 passes.
**Environment**: ENV-A (no reboot needed), mouse already paired and COL02 present.

| Test ID | Test Case | Expected debug.log Output | Pass Criteria |
|---------|-----------|--------------------------|---------------|
| T3-01 | App reads battery on COL02 | `OK path=...col02... battery=NN%` | Battery value 1–100, logged within 10s of app start |
| T3-02 | Tray tooltip shows battery | Hover tray icon | `Magic Mouse — NN%` (not "disconnected") |
| T3-03 | HidP_GetCaps threshold correct | `InputReportByteLength=X` in log | X ≥ 3 (confirms threshold is correct); **ADD THIS LOG LINE BEFORE TESTING** |
| T3-04 | COL01 not producing READ_FAILED spam | Scan debug.log for READ_FAILED | Zero READ_FAILED entries after first 30s of stable operation |
| T3-05 | Mouse disconnect → reconnect | App detects disconnect, then recovery | Log shows "disconnected" then battery % resumes within 30s of BT reconnect |
| T3-06 | DriverHealthChecker status displayed | App tray icon shows correct status | Status icon reflects `Ok` when driver bound; changes to warning if LowerFilters removed |
| T3-07 | Scroll still works | Physical scroll test | Page scrolls normally while app is running |

**Pre-condition for T3-03**: Add `Logger.Log($"HidP_GetCaps InputReportByteLength={caps.InputReportByteLength} path={devicePath}");`
to `MouseBatteryReader.cs` before the threshold check, rebuild, and verify in debug.log.
This is a **blocking gate** — if `InputReportByteLength < 3` for COL02, the battery reader silently
skips the device and battery reads will never work.

---

## Tier 4 — End-to-End Tests (Full User Journey)

**Scope**: Complete install → use → reboot cycle, from the perspective of a new user who just
downloaded the software. Goal: zero manual steps beyond running sign-and-install.ps1 as admin.

**Two scenarios:**

### T4-A: Incremental (current machine state, ENV-A)

| Step | Action | Pass Criteria |
|------|--------|---------------|
| T4-A-01 | Run `sign-and-install.ps1` as Administrator | Script completes with no errors; all 9 steps logged |
| T4-A-02 | Verify T2 section checks all pass | T2-01 through T2-06 pass |
| T4-A-03 | Run binary from `\\wsl.localhost\Ubuntu\tmp\mmtray-build\MagicMouseTray.exe` | App starts, tray icon appears |
| T4-A-04 | Verify battery reading (T3-01 through T3-04) | Battery % in tray within 10s |
| T4-A-05 | Reboot | System reboots normally |
| T4-A-06 | After reboot: check startup-repair.log | Log at `C:\ProgramData\MagicMouseTray\startup-repair.log` shows `REPAIRED: COL02 present` or `COL02 present — no repair needed` |
| T4-A-07 | After reboot: verify COL02 present | `Get-PnpDevice` shows 2 HID devices for PID 0323 |
| T4-A-08 | After reboot: app starts and reads battery | Battery % visible in tray within 30s of desktop load |
| T4-A-09 | Verify scroll works post-reboot | Physical scroll test |

### T4-B: Clean-Slate (new user install, ENV-B) — MM-V3 (PID 0323)

| Step | Action | Pass Criteria |
|------|--------|---------------|
| T4-B-00 | Run teardown procedure | All driver, cert, task, LowerFilters removed. Reboot. |
| T4-B-01 | Confirm baseline: battery reads fail | App (if started now) shows "disconnected" — confirms clean slate |
| T4-B-02 | Pair Magic Mouse | Mouse pairs via Bluetooth Settings. Scroll works. Battery NOT visible yet (expected). |
| T4-B-03 | Run `sign-and-install.ps1` as Administrator | All 9 steps complete without error |
| T4-B-04 | **Do NOT reboot yet** — verify driver installed | `pnputil /enum-drivers` shows applewirelessmouse |
| T4-B-05 | Re-pair Magic Mouse (required after driver install) | Remove mouse from BT, re-pair. Scroll resumes. |
| T4-B-06 | Run binary | Battery % appears in tray |
| T4-B-07 | Reboot | System reboots normally |
| T4-B-08 | Verify startup-repair ran | Log shows COL02 repaired or already present |
| T4-B-09 | Verify battery reads after reboot | Battery % in tray without manual intervention |
| T4-B-10 | Verify scroll after reboot | Physical scroll test |

### T4-C: Clean-Slate — MM-V1 (PID 030d)

Same as T4-B but with Magic Mouse v1. Substitute PID 030d in all verification steps.

| Step | Action | Pass Criteria |
|------|--------|---------------|
| T4-C-01 through T4-C-10 | Repeat T4-B steps with MM-V1 | All steps pass; battery reads via COL02 for PID 030d |

**Note**: MM-V1 uses a different HID descriptor than MM-V3. Confirm startup-repair.ps1 detects
the correct BTHENUM parent for PID 030d and that `MouseBatteryReader` matches the correct
KnownMice entry.

---

## Tier 5 — V3RecycleManager Tests (M3)

**Scope**: End-to-end recycle cycle validation — Mode B→A flip, battery read, Mode A→B restore.
**Prerequisite**: Mouse paired and in Mode B (scroll works, battery not showing). MM-Dev-Cycle scheduled task active.
**Test script**: `C:\mm-dev-queue\test-v3-state.ps1` (run as Administrator).

### Mode B Detection Signals (authoritative, 2026-05-07)

| Signal | Mode A | Mode B | Source |
|--------|--------|--------|--------|
| HID paths | col01 + col02 (split) | unified (no col suffix) | `Get-PnpDeviceInterface` |
| LowerFilters (BTHENUM Enum key) | `(empty)` | `applewirelessmouse` | Registry: `HKLM:\...\Enum\BTHENUM\{00001124...}_VID&0001004C_PID&0323\9&...` |
| DEVPKEY_Device_Stack | no `applewireless` entry | `applewireless` in list | `Get-PnpDeviceProperty -KeyName DEVPKEY_Device_Stack` |
| MouseClass DN_STARTED | **True (false positive)** | True | NOT a discriminator — mouhid stays bound to col01 in Mode A |
| Scroll | broken | works | Physical test |
| Battery (RID=0x90 on col02) | readable | N/A (col02 not present) | `HidD_GetInputReport` |

**MouseClass DN_STARTED must NOT be used as a Mode B indicator** — confirmed false positive 2026-05-07.

### T5 Test Cases

| Test ID | Test Case | Command | Pass Criteria |
|---------|-----------|---------|---------------|
| T5-01 | State check: device in Mode B | `.\test-v3-state.ps1 -StateCheckOnly` | Output: `State: MODE B` + `FilterInStack=True` + `LowerFilters=applewirelessmouse` |
| T5-02 | Single recycle cycle (FLIP:NoFilter → Mode A → battery → FLIP:AppleFilter → Mode B) | `.\test-v3-state.ps1 -Runs 1` | `PASS: ModeA=True Battery=NN% Restored=True` |
| T5-03 | Mode A confirmed via HID paths | Inspect T5-02 output | Two col paths visible: `...col01...` + `...col02...` in Mode A |
| T5-04 | Mode B restored via DEVPKEY_Device_Stack | Inspect T5-02 output | `FilterInStack=True` in post-restore checkpoint |
| T5-05 | WaitForModeB latency within budget | Inspect T5-02 timing | `[ModeB] confirmed at Nms` where N is 400–800ms |
| T5-06 | Battery pipeline retry handled | Inspect T5-02 output | If GLE=121/GLE=21 on attempts 1-2, passes on attempt 3 or 4. No outer cycle retry triggered. |
| T5-07 | BTHENUM parent healthy pre-flip | Inspect T5-02 output | `IsV3BtStackHealthy=True` in baseline |
| T5-08 | No degradation after 1 cycle | Run mouse scroll after T5-02 | Scroll works normally post-restore |

**Note**: Run T5 as a single cycle (`-Runs 1`) only. Multiple rapid cycles risk BT stack drift requiring re-pair.

---

## Tier 7 — Failover / Resilience Tests

**Scope**: System recovers correctly from failure states without manual intervention.

| Test ID | Scenario | Steps | Pass Criteria |
|---------|----------|-------|---------------|
| T7-01 | BT disconnect mid-session | Physically turn mouse off. Wait 60s. Turn on. | App detects disconnect (log), resumes battery reads within 30s of reconnect |
| T7-02 | COL02 missing after cold reboot | Reboot with driver active | startup-repair.log shows REPAIRED; COL02 present before app reads battery |
| T7-03 | Rapid reboot (< 10s uptime) | Force quick reboot | startup-repair.ps1 30s delay gives BT stack time; battery reads correctly |
| T7-04 | App crash and restart | Kill MagicMouseTray.exe; restart | App restarts, reads battery correctly without needing driver re-install |
| T7-05 | startup-repair.log rotation | Grow log to > 512KB (pad with writes), reboot | Log rotated to `.1.log`; no CRITICAL error; new log created |

---

## Tier 8 — Upgrade Tests

**Scope**: Existing installation upgrades to new version without data loss or re-configuration.

| Test ID | Scenario | Steps | Pass Criteria |
|---------|----------|-------|---------------|
| T8-01 | v1.0 → v1.1 binary upgrade | Replace exe only; no re-run of sign-and-install | Battery reads work; scheduled task unchanged; driver unchanged |
| T8-02 | Re-run sign-and-install on existing install | Run script when driver + task already present | Script detects existing task (skips), detects existing driver slot (removes + reinstalls), completes cleanly |
| T8-03 | Sign-and-install idempotency | Run script twice back-to-back | Second run produces same result as first; no duplicate tasks, no orphaned driver slots |

---

## Tier 9 — Security Tests

Mitigations from adversarial peer review (2026-04-22).

| Test ID | Control | Verification | Pass Criteria |
|---------|---------|-------------|---------------|
| T9-01 | Scheduled task path is protected directory | `icacls` on script path | Script lives in a directory where standard users cannot write (`C:\Program Files\...` or locked `C:\ProgramData\MagicMouseTray\`) |
| T9-02 | MagicMouseFix cert private key non-exportable | `Get-ChildItem Cert:\LocalMachine\My \| Where Subject -match MagicMouseFix` after sign | Certificate not present in `My` store (deleted after signing), OR marked non-exportable |
| T9-03 | Log directory ACL locked | `icacls C:\ProgramData\MagicMouseTray` | Standard users have no write access; prevents TOCTOU symlink attack |
| T9-04 | Test signing disabled after install confirmed | After T4-B reboot confirms battery works: `bcdedit /set testsigning off` + reboot | Watermark gone; driver still loads; battery reads continue |
| T9-05 | Driver file integrity | Hash `AppleWirelessMouse.sys` before and after install | SHA256 unchanged; no substitution during install |

**T9-01 and T9-03 require code changes to sign-and-install.ps1** before this tier can pass:
1. Change `$repairScript = Join-Path $PSScriptRoot "startup-repair.ps1"` to copy script to a
   fixed protected path (e.g., `C:\Program Files\MagicMouseTray\`) and register the task pointing there.
2. After creating `C:\ProgramData\MagicMouseTray\`, run `icacls` to remove user write access.

---

## Test Execution Matrix

| Tier | T1 Unit | T2 Section | T3 Integration | T4 E2E | T7 Failover | T8 Upgrade | T9 Security |
|------|---------|-----------|----------------|--------|-------------|-----------|-------------|
| Executable without hardware | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Requires Lesley + Windows machine | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| MM-V3 (0323) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| MM-V1 (030d) | ✅ | ✅ | ✅ | ✅ T4-C | ⬜ v1.1 | ⬜ v1.1 | ⬜ v1.1 |
| Must pass before v1.1.0 release | ✅ | ✅ | ✅ | T4-A + T4-B | T7-01 T7-02 T7-03 | T8-02 T8-03 | T9-01 T9-03 T9-04 |

---

## Blockers That Must Be Fixed Before Testing

These are code issues found in the adversarial peer review that will cause test failures if not fixed first:

| ID | Severity | File | Issue | Fix Required |
|----|----------|------|-------|-------------|
| BLK-01 | **High** | `MouseBatteryReader.cs` | `InputReportByteLength < 3` threshold unverified — if COL02 reports exactly 2 bytes, battery reads silently fail | Add log line for byte length; verify empirically in T3-03 |
| BLK-02 | **Medium** | `DriverHealthChecker.cs` | Zero devices → returns `Ok` (false negative) | Initialize default to `NotInstalled` |
| BLK-03 | **Medium** | `sign-and-install.ps1` | Scheduled task points to `$PSScriptRoot` — LPE if run from writable dir | Copy script to `C:\Program Files\MagicMouseTray\` before registering task |
| BLK-04 | **Medium** | `sign-and-install.ps1` | `C:\ProgramData\MagicMouseTray\` not created/locked at install time | Create dir and lock ACL in Step 9 before task registration |

BLK-01 is the highest priority — it directly determines whether battery reads work at all.

---

## Issue Log

Issues discovered during testing are tracked as GitHub Issues on `ReviveBusiness/magic-mouse-tray`.
Tag with `test-finding` and reference this plan's test ID (e.g., `T3-03 FAIL — InputReportByteLength=2`).

---

*Test Plan v1.0 — Built per BCP-STD-015 9-Tier Testing Framework*
*Created 2026-04-22 by RILEY / Lesley Murfin*
