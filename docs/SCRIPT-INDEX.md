# Script Index - Magic Mouse + Apple Keyboard Battery Monitor

Last updated: 2026-05-18 Calgary time

## Overview

Magic Mouse Tray and Apple Keyboard Windows battery monitor accumulates script artifacts across three primary locations over 3 weeks of RCA/diagnosis work. This index consolidates:

1. **Canonical (refactored)** keyboard probe suite - reusable, parameterized, production-ready
2. **Session probe scripts** - dated May 7-8 RCA probes, now renamed to clean undated names
3. **Keyboard Battery (PATH-C)** - canonical kbd-*.ps1 + postpatch-*.ps1 from mm3-driver
4. **Mouse PATH-A** scripts for install/test pipeline
5. **Keyboard kernel filter** driver build/sign/install scripts
6. **Task runner** phases orchestrating the full driver lifecycle

---

## Canonical - Use These

### Refactored Keyboard Probe Suite
Location: `/home/lesley/projects/Personal/magic-mouse-tray/scripts/refactored/`

All scripts here:
- Accept `-OutputDir` (defaults `C:\mm-dev-queue\kbd-runs`) and `-Label` parameters
- Create unique run directories per invocation: `<yyyyMMdd-HHmmss>-<Label>`
- Generate `manifest.json` with run metadata + `stdout.txt` tee
- Have full comment-based help: `Get-Help <script> -Full`
- Use ASCII hyphens only (no em-dashes)
- Reference canonical test fixture defaults from `Get-KbdDefaults` helper

| Script | Replaces | Purpose |
|--------|----------|---------|
| `_kbd-run-helpers.ps1` | (new shared module) | Common functions: `New-KbdRunDir`, `Add-KbdManifest`, `Write-KbdLog`, `Get-KbdDefaults`, `Test-KbdAdmin` |
| `kbd-stack-snapshot.ps1` | `postpatch-stack-snapshot.ps1` | Driver stack, service state, BTHENUM LowerFilters for v1/v3 mouse + keyboards |
| `kbd-battery-smoke.ps1` | `postpatch-quick-smoke.ps1` | 30-second admin smoke test: `HidD_GetFeature(0x47)` on col02, exit 0/1/2 |
| `kbd-rid-matrix-probe.ps1` | `postpatch-probe-all.ps1` | GetFeature/GetInputReport across all collections, structured JSON output |
| `kbd-feature-probe.ps1` | `kbd-feature-probe.ps1` | Single GetFeature(RID) per col, GENERIC_READ then GENERIC_RW fallback |
| `kbd-battery-descriptor-and-rid-sweep.ps1` | `kbd-battery-probe.ps1` | Phase 1 descriptor dump + Phase 2 RID sweep 0x01-0xFF + Phase 3 MAGICKEYBOARDRAEPDO IOCTL |
| `kbd-battery-alt-paths.ps1` | `kbd-battery-probe2.ps1` | SetupDi DEVPKEY + WinRT DeviceContainer + sync ReadFile paths |
| `kbd-battery-safe-readonly.ps1` | `kbd-battery-safe-probe.ps1` | Safe read-only: Get-PnpDeviceProperty DEVPKEY + WinRT DeviceContainer |
| `kbd-allcol-overlapped-read.ps1` | `kbd-allcol-probe.ps1` | Overlapped ReadFile col02+col03 with timeout + WinRT BluetoothDevice BatteryLife |
| `kbd-ble-aep-and-gatt.ps1` | `kbd-ble-only.ps1` + `kbd-ble-gatt.ps1` | Consolidates BLE AEP/GATT/DeviceContainer/registry-cache |
| `kbd-col03-feature-caps.ps1` | `kbd-col03-feature-caps.ps1` | HidP_GetValueCaps col03 Feature + GetFeature per RID |
| `kbd-getfeature-access-variants.ps1` | `kbd-getfeature-access0.ps1` | GetFeature(RID) col01/col02/col03 with `access=0` + multiple buffer sizes |
| `kbd-ioctl-getfeature.ps1` | `kbd-ioctl-getfeature.ps1` | Direct `IOCTL_HID_GET_FEATURE` / `..._INPUT_REPORT` (bypasses HidD wrapper FeatLen=0 reject) |
| `kbd-admin-getfeature-matrix.ps1` | `kbd-admin-getfeature.ps1` | Admin-required matrix: 3 paths x 3 access modes x N buffer sizes |
| `kbd-filter-evidence.ps1` | `kbd-filter-evidence.ps1` (in-place refactor) | Read-only RCA evidence dump for filter-not-loading diagnosis |

**Invocation examples:**
```powershell
# Defaults only
.\kbd-stack-snapshot.ps1

# Custom output + label
.\kbd-battery-smoke.ps1 -OutputDir D:\runs -Label "pre-patch-validation"

# Override device/PID
.\kbd-feature-probe.ps1 -KbdPid 0x029C

# Get help
Get-Help .\kbd-rid-matrix-probe.ps1 -Full
```

**Test fixture defaults** (from `Get-KbdDefaults`):
- PIDs: `0x0239, 0x0255, 0x026C, 0x029C, 0x029A`
- Device ID: `BTHENUM\{...}_VID&000205ac_PID&0239\...E806884B0741_C00000000`
- Col01/02/03 paths: canonical HID interface paths for A1314
- BluetoothAddress: `0xE806884B0741`
- ContainerId: `{49c4a341-7dbd-5fb0-9f4a-84fa5ab58e77}`

**See also:** `/home/lesley/projects/Personal/magic-mouse-tray/scripts/refactored/README.md` for full parameter spec + run-dir layout + manifest schema.

---

## Keyboard Battery (PATH-C) — mm3-driver Canonical Scripts

Location: `scripts/` (in this repo — synced from `D:\mm3-driver\scripts\`)

These are production-quality scripts from the mm3-driver development tree, covering the full Track 6 keyboard SDP cache patch workflow plus ETW instrumentation.

### Track 6 — SDP Cache Patch (kbd-patch-cachedservices.ps1)

| Script | Purpose |
|--------|---------|
| `kbd-patch-cachedservices.ps1` | **KEY: Track 6 SDP patch** — patches `CachedServices` registry blob to inject correct SDP record for keyboard HID battery; requires admin |
| `kbd-dump-cachedservices.ps1` | Dump raw `CachedServices` registry blob for pre/post-patch inspection |
| `kbd-mu-reg-extract.ps1` | Extract MagicUtilities registry entries relevant to keyboard pairing |
| `kbd-mu-reg-inspect.ps1` | Inspect MagicUtilities registry state (service, filter binding, device IDs) |
| `kbd-patch-cachedservices.ps1` | Patch CachedServices blob in HKLM Bluetooth device key |

### ETW / Instrumentation

| Script | Purpose |
|--------|---------|
| `kbd-audit-instrumentation.ps1` | Audit current ETW provider registration + WPP instrumentation for keyboard filter |
| `kbd-instrumentation-setup.ps1` | Set up ETW providers + WPP autologger for keyboard filter driver tracing |
| `kbd-etw-mine.ps1` | Mine existing ETW logs for keyboard HID battery events |
| `kbd-trace-live.ps1` | Start live ETW trace session for keyboard filter (real-time WPP output) |
| `kbd-trace-decode.ps1` | Decode captured ETW .etl to human-readable text via tracefmt |
| `kbd-set-dbgfilter.ps1` | Set kernel debugger filter level for keyboard filter driver |
| `kbd-dbgview-restart.ps1` | Restart DebugView (dbgview.exe) with correct filter for keyboard filter output |

### Filter Driver Operations

| Script | Purpose |
|--------|---------|
| `kbd-force-reload.ps1` | Force unload + reload of MagicKbDesc keyboard filter driver |
| `kbd-create-logon-tasks.ps1` | Create scheduled tasks for post-logon keyboard filter validation |

### Post-Patch Verification

| Script | Purpose |
|--------|---------|
| `postpatch-probe-all.ps1` | Full HID battery probe matrix across v1 mouse, v3 mouse, Apple keyboard — GetFeature + GetInputReport, JSON output |
| `postpatch-quick-smoke.ps1` | 30-second smoke: `HidD_GetFeature(0x47)` on keyboard col02 post-patch, exit 0/1/2 |
| `postpatch-stack-snapshot.ps1` | Driver stack snapshot (BTHENUM LowerFilters, DEVPKEY_Device_Stack, service states) for v1/v3 mouse + keyboard |

### MSE / SDP Dump

| Script | Purpose |
|--------|---------|
| `mse-dump-v3-sdp.ps1` | Dump v3 Magic Mouse SDP record via MSE Bluetooth APIs (reference for SDP patch format) |

---

## Session Probe Scripts (Renamed from Dated)

Location: `scripts/` (in this repo — were dated 2026-05-07/08, now renamed)

These are May 7-8 RCA session probes. Date suffixes removed; all have canonical replacements in `scripts/refactored/`. Keep for reference until full Track 6 regression test passes.

| Script | Replaced by (refactored) | Purpose |
|--------|--------------------------|---------|
| `kbd-admin-getfeature.ps1` | `refactored/kbd-admin-getfeature-matrix.ps1` | Admin matrix: 3 paths x 3 access modes x N buffer sizes |
| `kbd-allcol-probe.ps1` | `refactored/kbd-allcol-overlapped-read.ps1` | Overlapped ReadFile col02+col03 + WinRT BatteryLife |
| `kbd-battery-probe.ps1` | `refactored/kbd-battery-descriptor-and-rid-sweep.ps1` | 3-phase: descriptor + RID sweep + IOCTL |
| `kbd-battery-probe2.ps1` | `refactored/kbd-battery-alt-paths.ps1` | SetupDi + WinRT + ReadFile alt paths |
| `kbd-battery-safe-probe.ps1` | `refactored/kbd-battery-safe-readonly.ps1` | Safe read-only DEVPKEY + WinRT |
| `kbd-ble-gatt.ps1` | `refactored/kbd-ble-aep-and-gatt.ps1` | GATT service enumeration |
| `kbd-ble-only.ps1` | `refactored/kbd-ble-aep-and-gatt.ps1` | BLE AEP DeviceContainer |
| `kbd-col03-feature-caps.ps1` | `refactored/kbd-col03-feature-caps.ps1` | HidP_GetValueCaps col03 Feature |
| `kbd-container-bt.ps1` | (merged into other probes) | BT container enumeration |
| `kbd-etw-bt-hid-trace.ps1` | — | ETW BT+HID combined trace (session capture) |
| `kbd-feature-probe.ps1` | `refactored/kbd-feature-probe.ps1` | Single GetFeature(RID) per col |
| `kbd-getfeature-access0.ps1` | `refactored/kbd-getfeature-access-variants.ps1` | GetFeature with access=0 |
| `kbd-getinput-exact.ps1` | — | GetInputReport exact-size buffer |
| `kbd-hid-attrs.ps1` | — | HID device attributes dump |
| `kbd-ioctl-getfeature.ps1` | `refactored/kbd-ioctl-getfeature.ps1` | Direct IOCTL bypass of HidD wrapper |
| `kbd-l2cap-with-hid-disable.ps1` | — | L2CAP probe with HID service disabled |
| `kbd-raw-l2cap.ps1` | — | Raw L2CAP socket probe |
| `kbd-readfile-bigbuffer.ps1` | — | ReadFile with oversized buffer |
| `kbd-readfile-wait.ps1` | — | ReadFile with wait/timeout loop |
| `kbd-reconnect-battery-test.ps1` | — | Reconnect cycle + battery read |
| `kbd-rid90-probe.ps1` | — | RID 0x90 specific probe |
| `kbd-setfeature-then-getinput.ps1` | — | SetFeature then GetInputReport sequence |
| `kbd-winrt-battery.ps1` | — | WinRT DeviceInformation battery query |
| `kbd-winrt-devcont.ps1` | — | WinRT DeviceContainer enumeration |
| `kbd-filter-evidence.ps1` | `refactored/kbd-filter-evidence.ps1` | RCA evidence dump (filter load state) |

---

## Mouse PATH-A Install/Test Scripts

Location: `/mnt/c/mm-dev-queue/` (Windows-side staging dir)

| Script | Purpose | Notes |
|--------|---------|-------|
| `install-pathA-candidate.ps1` | Install PATH-A driver candidate | 37K, production-ready install orchestrator |
| `pathA-trust-and-install.ps1` | Trust M12 cert, then install | Runs install-m12-trust.ps1, then driver load |
| `install.ps1` | Latest install wrapper | 4.9K, 2026-05-08 |
| `atomic-v4-install.ps1` | Atomic v4 install (deprecated) | Pre-PATH-A, reference only |
| `verify-reboot.ps1` | Post-reboot validation | 12K, comprehensive health check |
| `v3-restore-applefilter-20260509.ps1` | Restore v3 Apple filter after patch | Rollback for testing |
| `restore-apple-driver.ps1` | Restore original Apple driver | 5.5K, full rollback |
| `uninstall.ps1` | Clean uninstall | Removes filter, driver, certs |
| `test-v3-state.ps1` | Validate v3 driver state | 30K, deep property inspection |
| `probe-hid-caps.ps1` | HID capabilities query | 5.4K |
| `read-battery-pathA.ps1` | Read battery via PATH-A driver | 2.1K smoke test |
| `analyze-minidump*.ps1` | Parse BSOD minidump | v1, v2 variants for kernel crash analysis |

---

## Keyboard Kernel Filter Driver Build/Sign/Install

Location: `/home/lesley/.claude/worktrees/ai-m4-kbd-inf-fix-final/driver-keyboard/`

| Script | Purpose | Status |
|--------|---------|--------|
| `build.ps1` | MSBuild MagicKbDesc.sln via EWDK | 2.2K, called by runner via mm-task-runner.ps1:119 |
| `sign.ps1` | Sign .sys/.cat via mm-task-runner | 1.2K, integrates SHA256 catalog |
| `install.ps1` | Install signed filter driver | 1.9K, admin-required |
| `pre-reboot-checkpoint.ps1` | Pre-reboot validation snapshot | 5.5K, RCA evidence capture |
| `post-reboot-validate.ps1` | Post-reboot health check | 11K, comprehensive validation |

These are orchestrated by `mm-task-runner.ps1` phases (see Task Runner Phases section).

---

## Task Runner Phases

Script: `/home/lesley/projects/Personal/magic-mouse-tray/scripts/mm-task-runner.ps1` (51K)

Queue protocol: filesystem (`C:\mm-dev-queue\request.txt` / `result.txt` / `running.lock`)

Phases: (lines 86-700+ in runner)

| Phase | Protocol | Purpose | Log file |
|-------|----------|---------|----------|
| `PATHA-V5-DIRECTCOPY-INSTALL` | `PATHA-V5-DIRECTCOPY-INSTALL\|<nonce>\|<src>\|<thumbprint>\|<SkipSign>` | Direct-copy pre-signed binary (SkipSign=1 for c881c041) — chains SIGN-FILE → CLEAR-BT-SDP-CACHE → PATCH-APPLE-SYS → RESTART-DEVICE → verify | `C:\mm-dev-queue\pathA-v5-install-<nonce>.log` |
| `PATHA-V5-DIRECTCOPY-UNINSTALL` | `PATHA-V5-DIRECTCOPY-UNINSTALL\|<nonce>\|<rollback-src>` | Rollback to stock binary (f4ae407c…) from backup | `C:\mm-dev-queue\pathA-v5-uninstall-<nonce>.log` |
| `SET-HIBERBOOT` | `SET-HIBERBOOT\|<nonce>\|<0 or 1>` | Admin reg write for HiberbootEnabled (Fast Startup gate); 0=cold start, 1=Fast Startup | `C:\mm-dev-queue\hiberboot-<nonce>.log` |
| `PREFLIGHT` | `PREFLIGHT\|<nonce>` | Delegate to check-prereq.ps1 -Assert (test signing ON, M14 cert, v3 paired, binary MD5) | `C:\mm-dev-queue\preflight-<nonce>.log` |
| `POSTPATCH-SMOKE` | `POSTPATCH-SMOKE\|<nonce>` | Battery read via mm-v3-battery-now.ps1 (30-second smoke test) | `C:\mm-dev-queue\postpatch-smoke-<nonce>.log` |
| `STATE-SNAPSHOT` | `STATE-SNAPSHOT\|<nonce>\|<label>` | capture-state.ps1 wrapper with -Label (snapshots driver stack, LowerFilters, service state, filter presence) | `C:\mm-dev-queue\state-snapshot-<nonce>.log` |
| `TRACELOG-START` | `TRACELOG-START\|<nonce>` | ETW trace start via tracelog.exe (SDK or EWDK) against KMDF WPP provider | `C:\mm-dev-queue\tracelog-<nonce>.log` |
| `TRACELOG-STOP` | `TRACELOG-STOP\|<nonce>` | ETW trace stop + convert to text via tracefmt | `C:\mm-dev-queue\tracelog-stop-<nonce>.log` |
| `FORENSICS` | `FORENSICS\|<nonce>` | collect-forensics.ps1 wrapper — bundles event logs, minidumps, driver signatures, registry exports | `C:\mm-dev-queue\forensics-<nonce>.log` |
| `BUILD` | `BUILD\|<nonce>\|<config>\|<platform>\|<sln-path>` | MSBuild via EWDK; calls `driver-keyboard/build.ps1` if sln-path present, else `mm-dev.ps1 -Phase Build` | `C:\mm-dev-queue\build-<nonce>.log` |
| `SIGN` | `SIGN\|<nonce>\|<sys-path>\|<cat-path>\|<pfx-path>\|<pfx-pass-env>` | Sign .sys/.cat via SignTool; /fd sha256 | `C:\mm-dev-queue\sign-<nonce>.log` |
| `DV-CHECK` | `DV-CHECK\|<nonce>\|<driver-name>` | Configure Driver Verifier (reboot required to activate) | `C:\mm-dev-queue\dv-<nonce>.log` |
| `INSTALL-DRIVER` | `INSTALL-DRIVER\|<nonce>\|<sys-path>\|<cat-path>\|<inf-path>` | pnputil /add-driver; blocks until device enumerated | `C:\mm-dev-queue\install-<nonce>.log` |
| `KBDEVID` | `KBDEVID\|<nonce>\|<device-id>` | Diagnostic phase; calls `kbd-filter-evidence.ps1` | `C:\mm-dev-queue\kbdevid-<nonce>.log` |

Runner also supports legacy phases for M12 mouse driver (BUILD→mm-dev.ps1, direct runner phases).

| `scripts/build-driver.ps1` | Standalone M13 KMDF driver build. Queue: `BUILD\|<nonce>\|Release\|x64` |
| `scripts/sign-driver.ps1`  | Sign .sys + .cat with PFX. Queue: `SIGN\|<nonce>\|<sys>\|<cat>\|<pfx>` |
| `scripts/install-driver.ps1` | pnputil /add-driver + /install. Queue: `INSTALL-DRIVER\|<nonce>\|<inf>` |
| Queue: `STARTUP-REPAIR\|<nonce>` | Calls `startup-repair.ps1` to set LowerFilters + restart-device |

---

## Cross-Location References

### Runner references to scripts

File: `/home/lesley/projects/Personal/magic-mouse-tray/scripts/mm-task-runner.ps1`

| Line(s) | Reference | Type | Status |
|---------|-----------|------|--------|
| 1439 | `D:\mm3-driver\scripts\postpatch-quick-smoke.ps1` | Mouse battery smoke test | Canonical `postpatch-quick-smoke.ps1` now in `scripts/`; runner path still hardcoded to D: |
| 1536 | `D:\mm3-driver\scripts\kbd-filter-evidence.ps1` | Keyboard filter RCA | `kbd-filter-evidence.ps1` now in `scripts/`; runner path still hardcoded to D: |
| 1400 | `D:\mm3-driver\scripts\kbd-audit-instrumentation.ps1` | ETW/instrumentation setup | Now in `scripts/` |
| 1419 | `D:\mm3-driver\scripts\kbd-etw-mine.ps1` | ETW trace parsing | Now in `scripts/` |
| 1463 | `D:\mm3-driver\scripts\kbd-create-logon-tasks.ps1` | Create scheduled tasks | Now in `scripts/` |

---

## Organizational Summary

### By Status

| Category | Count | Location(s) |
|----------|-------|-------------|
| **CANONICAL (refactored)** | 15 refactored PS1 + helpers | `scripts/refactored/` |
| **PATH-C kbd canonical (mm3-driver sync)** | 17 scripts | `scripts/` |
| **Session probes (renamed, undated)** | 25 scripts | `scripts/` |
| **Mouse PATH-A install/test** | 13 scripts | `/mnt/c/mm-dev-queue/` |
| **Keyboard kernel filter driver** | 5 scripts | `~/.claude/worktrees/ai-m4-kbd-inf-fix-final/driver-keyboard/` |
| **Runner orchestrator** | 1 script + phases | `scripts/mm-task-runner.ps1` |
| **Total** | 76 scripts across 5 locations | - |

### By Technology

| Tech | Purpose | Canonical | Session probe |
|------|---------|-----------|-------|
| **HID battery read** | GetFeature(0x47/0x90) on col02 | `kbd-battery-smoke.ps1` | 3 probes |
| **RID matrix sweep** | Scan 0x01-0xFF across collections | `kbd-rid-matrix-probe.ps1` | 1 probe |
| **Descriptor dump** | Capture HID descriptor | `kbd-battery-descriptor-and-rid-sweep.ps1` | 1 probe |
| **Driver stack snapshot** | PnP state, service status, filters | `kbd-stack-snapshot.ps1` | 1 probe |
| **SDP cache patch** | Track 6: patch CachedServices registry blob | `kbd-patch-cachedservices.ps1` | — |
| **Filter evidence** | RCA diagnostics (filter load, evidence) | `kbd-filter-evidence.ps1` (refactored) | in-place refactor |
| **BLE/GATT probes** | BluetoothDevice, registry, DeviceContainer | `kbd-ble-aep-and-gatt.ps1` | 2 probes |
| **Alternative access paths** | SetupDi, WinRT, sync ReadFile | `kbd-battery-alt-paths.ps1` | 1 probe |
| **IOCTL bypass** | Direct HID IOCTL (FeatLen workaround) | `kbd-ioctl-getfeature.ps1` | 1 probe |
| **ETW instrumentation** | Live trace, decode, filter | `kbd-trace-live.ps1` / `kbd-trace-decode.ps1` | — |
| **SDP dump** | MSE SDP record inspection | `mse-dump-v3-sdp.ps1` | — |
| **Mouse install/test** | PATH-A driver candidate install + validation | 13 scripts in queue/ | — |
| **Kernel driver build** | EWDK MSBuild, sign, install keyboard filter | 5 scripts in worktree | — |

---

## Action Items

1. **Runner path updates** (medium priority)
   - mm-task-runner.ps1:1439 references `/mnt/d/mm3-driver/scripts/postpatch-quick-smoke.ps1` (hardcoded)
   - Update to call `scripts/postpatch-quick-smoke.ps1` from repo OR keep D: path (both exist now)
   - Same for kbd-filter-evidence.ps1:1536 and other mm3-driver paths

2. **Session probe cleanup** (low priority)
   - 25 renamed session probes in `scripts/` have canonical replacements in `scripts/refactored/`
   - Can be deleted after full Track 6 regression test passes

3. **Windows-side scripts dir**
   - No canonical `/mnt/c/Users/Lesley/scripts/` yet (mentioned in user feedback)
   - Consider populating once refactored set stabilizes

---

## Activity Log

| Date | Update |
|------|--------|
| 2026-05-09 | Created canonical SCRIPT-INDEX.md: audited 63 scripts across 6 locations (refactored, dated, mouse PATH-A, keyboard driver, runner, ETW). Consolidated cross-references, identified 23 throwaway candidates, flagged runner hardcoded paths for update. Index extends refactored/README.md with full landscape view. |
| 2026-05-18 | Synced 17 canonical kbd-*.ps1 + postpatch-*.ps1 + mse-dump-v3-sdp.ps1 from D:\mm3-driver\scripts\ into scripts/. Renamed 25 session probe scripts: stripped date suffixes (2026-05-07/08), no content edits. Added Keyboard Battery (PATH-C) section. Updated runner cross-reference status. PRD-185 / branch ai/magic-mouse-complete-fix. |
| 2026-05-18 | Track 0: added STARTUP-REPAIR phase to mm-task-runner.ps1; extracted scripts/build-driver.ps1, scripts/sign-driver.ps1, scripts/install-driver.ps1 as standalone M13 build/sign/install scripts. PRD-200 Phase B / branch ai/mm-t0-scripts. |
