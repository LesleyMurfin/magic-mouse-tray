# PATH-A v3 Test Plan

**Status:** v1.1 — DRAFT (post NLM T3 peer review CHANGES-NEEDED, 2026-05-08)
**Date:** 2026-05-08
**Linked PRD:** `Personal/prd/184-magic-mouse-windows-tray-battery-monitor.md` (PRD-184 v1.28.x)
**Linked PSN:** `Personal/magic-mouse-tray/PSN-0001-hid-battery-driver.yaml` v2.2.0
**Linked design:** `.claude/plans/rippling-mixing-jellyfish.md` (PATH-A descriptor design, NLM T3 APPROVE `9a96fef1`)
**Linked signing-debt:** `docs/PATH-A-SIGNING-DIVERGENCE.md`
**Linked decisions:** D-S17-01 through D-S17-15 in PRD-184
**Latest peer review:** NLM T3 against notebook `e789e5e9-da23-4607-9a62-bbfd94bb789b` (2026-05-08) — verdict CHANGES-NEEDED, 5 findings F1-F5 addressed in v1.1

## BLUF

Acceptance test gauntlet for the PATH-A binary descriptor patch on `applewirelessmouse.sys`. Two parallel tracks: **Track A** (canonical catalog-based bundle, redistributable — must pass before sharing) and **Track B** (current direct-resigned binary, in-session validation only — disposable scaffold). Each track has the same survival criteria. Pass means: patched descriptor live in kernel, COL01+COL02 enumerated, scroll + click + battery all functional, state survives reboot, hibernation, sleep, idle disconnect, PnP rescan, and a 24h soak.

## Acceptance criteria (per track)

| ID | Criterion | Pass condition |
|---|---|---|
| AC-A1 | Patched binary loaded | `MD5 C:\Windows\System32\drivers\applewirelessmouse.sys` matches expected (Track A: TBD after canonical re-sign; Track B: `c881c04113033420cda9d3efe55f9461`) |
| AC-A2 | Driver service active | `Get-Service applewirelessmouse` Status=Running OR PnP-loaded as filter (`DEVPKEY_Device_Stack` shows `applewirelessmouse` in BTHENUM stack) |
| AC-A3 | BT COL02 enumerated | `Get-PnpDevice` shows `HID\{00001124-...}_VID&0001004C_PID&0323&COL02\...` Status=OK |
| AC-A4 | BT COL01 enumerated | `Get-PnpDevice` shows `HID\{00001124-...}_VID&0001004C_PID&0323&COL01\...` Status=OK |
| AC-A5 | Patched descriptor live | `dump-descriptor.ps1` on BT COL02 reports UsagePage=0xFF00, Usage=0x0014, RID=0x90, Input=3B, InputValueCaps=2 |
| AC-A6 | Battery readable | `HidD_GetInputReport(0x90)` returns `buf[2]` in [1..100] within 5×500ms retry budget |
| AC-A7 | Cursor functional | Manual: pointer tracks normally during 30s of mouse movement |
| AC-A8 | Click functional | Manual: left-click and right-click both register correctly |
| AC-A9 | Scroll functional | Manual: two-finger vertical AND horizontal (AC Pan) scroll register WM_MOUSEWHEEL events. **Critical PATH-A vs Mode A delta** — Mode A without filter has no scroll; PATH-A keeps filter in stack so gesture engine fires |
| AC-A10 | No spurious clicks | Manual: 30s of cursor movement with no surface contact produces zero phantom click events |

## Test classes

| # | Test class | Scope | Tool | Gating threshold | Track |
|---|---|---|---|---|---|
| 1 | Pre-install state baseline | Capture System32\drivers MD5, DriverStore folder MD5s, PFRO regkey, PnP topology, BT cache | `scripts/capture-state.ps1 -Label pre-pathA` | JSON written, no errors | Both |
| 2 | Bundle build (canonical) | Generate patched .sys (78424B WHQL-overlay-intact) + .cat + INF + .cer + install.ps1 + uninstall.ps1 | `New-FileCatalog` + SIGN-FILE task runner (M14 cert `16940C0F...`) + reference INF as template | Bundle present at `Personal/magic-mouse-tray/dist/PATH-A-v3/`; `.cat` `Get-AuthenticodeSignature` Status=`UnknownError` (self-signed accepted); `.sys` MD5 starts with patched bytes at offset 0xA850 matching v3 design | Track A only |
| 3 | Install (canonical) | `restore-apple-driver.ps1` (rollback Track B) → `pnputil /add-driver applewirelessmouse.inf /install /force` | Native pnputil | Driver installed in DriverStore + System32; `pnputil /enum-drivers` shows new `oem<NN>.inf` published; AC-A1..A6 pass | Track A only |
| 4 | Direct-resign install | (current state, already done) | PATCH-APPLE-SYS task runner direct-copy branch | Already passed in-session 2026-05-08 | Track B only |
| 5 | Descriptor injection live | Verify our patched 116-byte descriptor in BT COL02 caps | `scripts/probe-hid-caps.ps1` (or `dump-descriptor.ps1` filtered to BTHENUM-rooted) | AC-A5 passes | Both |
| 6 | Battery read happy path | `HidD_GetInputReport(0x90)` on BT COL02 with 5×500ms retry | `read-battery-pathA.ps1` | AC-A6 passes; ideally first attempt (no GLE=121 retry) | Both |
| 7 | Cursor + click smoke test | 30s manual cursor movement + 5 left-clicks + 5 right-clicks | Operator | AC-A7 + AC-A8 + AC-A10 pass | Both |
| 8 | Scroll smoke test | 30s manual two-finger vertical + horizontal scroll over visible-scrollable surface (e.g. notepad with long doc, browser with long page) | Operator + WM_MOUSEWHEEL counter (`scripts/wheel-events.json` capture) | AC-A9: WM_MOUSEWHEEL count > 0 in vertical AND `WM_MOUSEHWHEEL` count > 0 in horizontal during 3s gesture | Both |
| 9 | Full reboot survival | Restart from Start menu (NOT Shut Down — Fast Startup masks) | Operator + post-reboot validation script | Post-reboot: AC-A1..A6 pass within 60s of login. **Critical**: Track B may FAIL this if PnP re-stages from DriverStore (where stock f4ae407c lives). Track A should PASS because patched .sys is in DriverStore | Both — primary differentiator |
| 10 | Hibernation survival | `shutdown /h` → wait 30s → power on → wait 30s → validate | Operator + validation script | Post-resume: AC-A1..A6 pass. Mouse may need wake-on-move | Both |
| 11 | Sleep/wake cycle | Sleep from Start menu (S3/Modern Standby) → wait 60s → wake → validate | Operator + validation script | Post-wake: AC-A1..A6 pass. BT typically reconnects within 5s of mouse movement | Both |
| 12 | Idle disconnect/reconnect | Walk away 5+ min until BT idle disconnect (`Status=Unknown`) → move mouse → wait 5s → validate | Operator + validation script | Post-reconnect: AC-A3..A6 pass. Confirms patched descriptor re-injects on every fresh SDP exchange | Both |
| 13 | PnP rescan stability | `pnputil /scan-devices` (forces PnP re-enumeration) | Native pnputil | Post-scan: AC-A1..A6 pass. **Critical for Track B**: re-stage from DriverStore could overwrite live patched .sys with stock f4ae407c | Both — Track B failure expected |
| 14 | DriverStore stale-folder cleanup | Remove `applewirelessmouse.inf_amd64_556b5cec8ed3b5a3` (74756dc8 — failed 04-30 patch) | `pnputil /delete-driver oem<NN>.inf /force` after enumerating published name | Stale folder gone; remaining DriverStore copies match either stock f4ae407c (Track B baseline) OR patched 78424B (Track A) | Both — pre-flight |
| 15 | Soak (24h) | Mouse in normal use over a full day; periodic battery polls + sleep/wake + reboot | Tray app DrainRateTracker logs + manual checks every few hours | No spurious clicks, no scroll regression, battery readable continuously, no driver crash (`Get-WinEvent System` no `applewirelessmouse` errors) | Track A — pre-release gate |
| 16 | DSM/Selective-Suspend resilience | Watch for any DSM property-write events (PSN-0001 H-011) that historically flipped Mode A→B | `Get-WinEvent Microsoft-Windows-DeviceSetupManager` filter | If DSM event fires AND COL02 still present afterward: PASS. Confirms PATH-A is immune to the original Mode-flip trigger | Both — observation only |
| 17 | Legacy Feature 0x47 IOCTL probe (post NLM-F2) | After PATH-A patch loaded: call `HidD_GetFeature(0x47)` on patched COL01 — verify it returns gracefully (err=87 / err=1 / etc) WITHOUT bugcheck or BSOD. The 0x47 Feature was removed from the descriptor; legacy code in applewirelessmouse.sys may still send IRPs for it | PowerShell P/Invoke harness; capture `Get-WinEvent System -ProviderName 'Microsoft-Windows-Kernel-General'` for any error 0x* events during 60-second probe | Zero kernel error events; HidD_GetFeature returns false with a non-fatal error code; mouse remains functional after probe | **Both — pre-release gate** |
| 18 | Long-form usage wire compatibility (post NLM-F4) | Verify HidBth.sys's BT minidriver correctly parses 3-byte long-form usages (`0a 01 00 0a 02 00`) on the wire. `HidP_GetCaps` only proves hidclass.sys parsed it post-delivery, not BT-stack handling. | Capture HID write trace via `etw-hid.wprp` during a battery push; confirm 3-byte payload arrives intact at the BT minidriver layer; OR: empirically confirm 100 consecutive successful `HidD_GetInputReport(0x90)` calls over 5 minutes (no GLE=87 mid-stream) | All 100 reads return valid `buf[2]` in [0..100]; no parse errors in ETW trace | Both — pre-release gate |
| 19 | Fast Startup explicit survival (post NLM-F5) | Test driver loads correctly with HiberbootEnabled=1 (Win11 default) AND with HiberbootEnabled=0. Two-pass: (a) leave Fast Startup ON, do `Shut Down` from Start menu, power on, validate; (b) `powercfg /h off`, then `Shut Down`, power on, validate | Operator + state capture | Pass (a): If patch survives Fast Startup hibernation resume — best-case. Pass (b): patch survives full boot — required minimum for Track A | **Both — pre-release gate** |
| 20 | Track A CI-probe pre-test (post NLM-F3) | **PRE-FLIGHT for Track A bundle build.** Test whether Windows Code Integrity accepts a patched .sys with a corrupted-hash WHQL overlay + a valid testsigned catalog. If CI rejects (`STATUS_INVALID_IMAGE_HASH` or driver fails to load), the canonical pattern with overlay-intact 78424B is BLOCKED — must strip the WHQL overlay before catalog signing | Build a probe bundle with the 78424B patched .sys (overlay intact) + .cat + INF; install via `pnputil`; check `Get-WinEvent System` for CI rejection events; verify driver loads | If CI accepts: proceed with overlay-intact canonical pattern. If CI rejects: pivot to overlay-strip variant (load WHQL cert table, zero out, recompute file size, re-sign catalog) | **Track A — gate-zero** |
| 21 | BTHPORT cache poison rollback (post NLM finding on rollback) | Rollback procedure must wipe BTHPORT SDP cache for the Magic Mouse MAC, not just restore the .sys. Otherwise stale cached descriptor remains in kernel pool | `Remove-Item HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices\<MAC>\CachedServices` followed by BTHENUM disable+enable. Use existing `CLEAR-BT-SDP-CACHE` task runner route (line 301 of `D:\mm3-driver\scripts\mm-task-runner.ps1`) | Post-rollback: BT COL02 enumerated with stock descriptor caps (UP=0xFF00 if Mode A, OR phantom Feature 0x47 if Mode B) — proves the cached patched descriptor was evicted | **Both — pre-release gate (rollback path)** |

## Test ordering

### Track A (canonical, redistributable) — pre-release gate
1. **Pre-flight**: 14 (stale-folder cleanup), 1 (state baseline)
2. **Build**: 2 (bundle build) — produces shippable artifacts
3. **Install**: 3 (canonical pnputil install) — rolls back Track B first
4. **Smoke**: 5, 6, 7, 8 — confirms basic functionality matches Track B
5. **Survival**: 9, 10, 11, 12, 13 — confirms patch is permanent (this is what shareability demands)
6. **Soak**: 15 (24h)
7. **Observation**: 16 (DSM resilience — passive throughout soak)
8. **Acceptance**: all AC-A* pass on Track A → safe to redistribute

### Track B (current, in-session validation only)
1. **Already done**: 4 (install via direct copy), 5 (descriptor injection), 6 (battery read at 38%) — passed 2026-05-08
2. **Pending**: 7, 8 (cursor/click/scroll smoke)
3. **Skip**: 9, 13 — Track B will likely fail these due to DriverStore mismatch. Failure is documentation, not blocker
4. **Useful**: 10, 11, 12 — these tell us how Magic Mouse + applewirelessmouse interact across power transitions, useful regardless of signing approach

## NLM T3 peer review findings (2026-05-08, addressed in v1.1)

| Finding | Mitigation |
|---|---|
| F1: Scroll test (AC-A9) hadn't been run | Manual test pending; no doc change — gauntlet test class 8 captures |
| F2: Byte-removal risks (Feature 0x47, vendor pad 0xFF02) untested | New test class 17 (Feature 0x47 IOCTL probe) added |
| F3: WHQL-corrupted-overlay + valid catalog may trigger CI rejection | New test class 20 (CI-probe pre-test) — gate-zero before Track A bundle is shipped. Pivot to overlay-strip variant if CI rejects |
| F4: Long-form usage wire-format untested | New test class 18 (long-form usage wire compatibility) added |
| F5: Rollback doesn't handle Fast Startup PFRO failure | Rollback section below updated; new test class 19 (Fast Startup explicit survival) + 21 (BTHPORT cache wipe) added |

## Rollback procedures

### Pre-reboot rollback (PFRO not yet processed)
```powershell
$existing = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations).PendingFileRenameOperations
$cleaned = $existing | Where-Object { $_ -notlike "*applewirelessmouse*" }
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -Value $cleaned -Type MultiString
Remove-Item 'C:\Windows\System32\drivers\applewirelessmouse.sys.new' -Force
```

### Post-reboot rollback (driver replaced)
```
C:\mm-dev-queue\restore-apple-driver.ps1
```
Restores stock `f4ae407c228c3db6147d9e3307ed5f20` to System32\drivers AND DriverStore active package. Backup created at `C:\mm-dev-queue\backup-restore-apple-<ts>\`.

### Recovery source (all paths fail)
- `D:\Backups\AppleWirelessMouse-RECOVERY\` — staged recovery copy
- `D:\Users\Lesley\Downloads\MagicMouse2DriversWin11x64-master.zip` — original reference project

### Locked-file + Fast Startup combined failure (NLM-F5)
If `restore-apple-driver.ps1` fails to overwrite `applewirelessmouse.sys` because it is kernel-locked, AND `HiberbootEnabled=1` makes PFRO unreliable:
1. **Disable Fast Startup first**: `powercfg /h off` (requires admin)
2. **Stop the driver service** (forces PnP to unload it): `Stop-Service applewirelessmouse -Force`
3. Retry direct copy: `Copy-Item <stock-sys> C:\Windows\System32\drivers\applewirelessmouse.sys -Force`
4. If still locked: full Restart (with Fast Startup disabled, this becomes a real cold boot), then PFRO will execute correctly
5. **Last resort**: boot into WinRE (Windows Recovery Environment), mount the system drive offline, replace the file, exit recovery

### Poisoned BTHPORT SDP cache (NLM-F5)
Restoring the stock `.sys` does NOT clear the BTHPORT cached descriptor for the device's MAC. The cache lives in `HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices\<MAC>\CachedServices`. Clear via existing route:
```
SIGN-FILE-style queue submission:
CLEAR-BT-SDP-CACHE|<nonce>|D0C050CC8C4D
```
(See test class 21 + `D:\mm3-driver\scripts\mm-task-runner.ps1:301`)

## Tooling

| Script | Purpose | Path |
|---|---|---|
| `capture-state.ps1` | JSON snapshot of device + driver state, with `-Compare` mode | `Personal/magic-mouse-tray/scripts/capture-state.ps1` |
| `test-v3-state.ps1` | Mode A/B verifier with full HID battery read + retry | `C:\mm-dev-queue\test-v3-state.ps1` |
| `dump-descriptor.ps1` | HIDP_GetCaps dump (USB MI_01 path — INFORMATIONAL ONLY for Magic Mouse v3, BT path is the real target) | `C:\mm-dev-queue\dump-descriptor.ps1` |
| `probe-hid-caps.ps1` | HIDP_GetCaps + HidP_GetValueCaps + HidD_GetInputReport on BT-rooted COL02 | `C:\mm-dev-queue\probe-hid-caps.ps1` |
| `read-battery-pathA.ps1` | Battery-only read via HidD_GetInputReport(0x90) with 5×500ms retry | `C:\mm-dev-queue\read-battery-pathA.ps1` |
| `verify-reboot.ps1` | Post-reboot static checks (cert, binary, registry, service, HID collections, battery) | `C:\mm-dev-queue\verify-reboot.ps1` |
| `mm-accept-test.ps1` | 8 acceptance criteria (AC-01..AC-08) | `Personal/magic-mouse-tray/scripts/mm-accept-test.ps1` — note AC-01 expects M13 KMDF, NOT applicable to PATH-A; use AC-04, AC-05, AC-06 only |
| `restore-apple-driver.ps1` | Rollback to stock | `C:\mm-dev-queue\restore-apple-driver.ps1` |
| `install-pathA-candidate.ps1` | (Track B) MOP for direct-resign install | `C:\mm-dev-queue\install-pathA-candidate.ps1` |

## Critical PATH-A vs prior Mode A distinction

The earlier Mode A behavior (PSN-0001 H-010) was: `applewirelessmouse` removed from device stack → COL02 vendor TLC visible → battery readable BUT scroll BROKEN (no gesture engine). PATH-A is fundamentally different:

| Property | Mode A (no filter) | Mode B (stock filter) | PATH-A v3 (patched filter) |
|---|---|---|---|
| applewirelessmouse in stack | NO | YES | **YES** |
| Filter gesture engine | dormant | active | **active** |
| HID descriptor type | unmodified Apple base | stock 116B (Feature 0x47, no COL02 vendor) | **patched 116B (TLC1 mouse + RID 0x27 touch + TLC2 vendor RID=0x90)** |
| COL02 enumerated | YES | NO | **YES** |
| Battery readable | YES | NO | **YES** |
| Scroll works | NO | YES | **YES (filter present + RID 0x27 preserved in TLC1)** |
| Click works | YES | YES | **YES (TLC1 declares 2 buttons)** |

AC-A9 (scroll test) is the **definitive PATH-A success indicator** — it differentiates PATH-A from prior Mode A.

## Coverage targets

- Track A all AC-A1..A10 + tests 1, 2, 3, 5-13, 15, 16 PASS = release candidate
- Track B all AC-A1..A8 + AC-A10 PASS in-session = descriptor design validated empirically (AC-A9 pending manual scroll test)

## Exit criteria

### Track A → "shareable"
- All 16 test classes PASS
- All AC-A1..A10 PASS
- 24h soak: zero `Get-WinEvent System` errors mentioning applewirelessmouse, zero BSOD, zero descriptor-related driver crashes
- Bundle published to `Personal/magic-mouse-tray/dist/PATH-A-v3/` with checksums + signed catalog
- `docs/PATH-A-DISTRIBUTION.md` written with install instructions for recipients

### Track B → "internal-only validated"
- AC-A1..A8 + AC-A10 PASS in current session (already met as of 2026-05-08 14:38)
- AC-A9 (scroll) requires manual confirmation
- Reboot survival NOT REQUIRED for Track B exit (Track A is what survives; Track B is throwaway)
- `Personal/magic-mouse-tray/docs/PATH-A-SIGNING-DIVERGENCE.md` documents the redo plan

## Out of scope

- v1 Magic Mouse (PID 0x030D) PATH-A patch — design didn't target v1; v1's stock descriptor differs and would need separate analysis. Defer to future PATH-A-v1 milestone.
- USB-cabled Magic Mouse path — different driver entirely (`HID\VID_05AC&PID_0323&MI_01\...`); battery is reported through different mechanism. Out of PATH-A scope.
- Apple Magic Trackpad — separate device, different patch surface.
- Windows Update resilience — Apple Wireless Mouse driver hasn't been updated in years; Windows Update unlikely to overwrite PATH-A. If it does, restore from `D:\Backups\AppleWirelessMouse-RECOVERY\` and re-install canonical bundle.
- WHQL certification — explicitly not pursued. Test-signed for personal/team use only.

## Activity Log

| Date | Update |
|------|--------|
| 2026-05-08 | v1.0 — initial PATH-A v3 test plan documented post in-session validation success (battery=38% on first attempt). Track A bundle build + survival gauntlet pending. |
