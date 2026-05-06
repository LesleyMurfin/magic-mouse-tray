---
title: "PRD-PATH-B — Phase 4-Omega Userland Recycler + Multi-Device Battery Tray"
type: product-requirements
parent_prd: PRD-184
parent_psn: PSN-0001
status: draft
version: 0.1.0
created: 2026-05-06
target_release: TBD
linked_repo: ReviveBusiness/magic-mouse-tray
---

# PRD-PATH-B — Phase 4-Omega Userland Recycler + Multi-Device Battery Tray

## BLUF

Deliver cursor + scroll + battery for Magic Mouse v3 (and v1/v2 + Magic Keyboard simultaneously) without modifying Apple's stock `applewirelessmouse.sys` driver. Strategy: tray app polls battery on demand via a two-phase PnP flip: (1) FLIP:NoFilter — detach `applewirelessmouse` from LowerFilters + disable/enable BTHENUM to expose Mode A (COL02 present, battery readable, scroll broken); (2) read battery via HidD_GetInputReport(RID=0x90); (3) FLIP:AppleFilter — re-attach filter + disable/enable to force Mode B restore (scroll restored, COL02 gone). Per M0a (Session 15 empirical), FLIP:NoFilter reliably flips Mode B → Mode A within ~1s. Acceptable trade-off: ~5 second scroll glitch per battery poll, scheduled adaptively.

Multi-device support shows live battery for any combination of detected: keyboard, v1 mouse (PID 0x030D), v2 mouse (PID 0x0269), v3 mouse (PID 0x0323) — same tray icon, expanding context menu.

---

## Problem & Context

Per PSN-0001 H-010 REVISED + H-007:

- v3 hardware exposes battery only via Input RID=0x90 on a vendor TLC (UP=0xFF00 / Usage=0x14)
- v1 mouse + Magic Keyboard expose battery via standard Feature RID=0x47 (UP=0x06 / Usage=0x20)
- v2 mouse pattern presumed similar to v1 (Feature 0x47); confirm in M2 of this PRD
- v3 with `applewirelessmouse` filter loaded has Mode A (battery readable, scroll broken) and Mode B (scroll synthesized, battery TLC stripped) — mutually exclusive
- **M0a CONFIRMED (Session 15)**: FLIP:NoFilter (remove `applewirelessmouse` from `LowerFilters` + `Disable-PnpDevice` + `Enable-PnpDevice` via MM-Dev-Cycle queue) flips B→A within ~1 s. Bare `pnputil /restart-device` FAILS even as SYSTEM (H-012 bare pnputil CONFIRMED FAIL)
- **Mode A→B restoration is FORCED** — removing the filter leaves device in Mode A indefinitely; explicit FLIP:AppleFilter (re-add + disable/enable) required to restore Mode B after every battery read

PATH-A (binary-patch Apple driver) was invalidated 2026-05-06 — the embedded descriptor at 0xA850 has zero code references.

M14 (clean-room kernel filter with in-IRP gesture translation) is out of scope per user direction.

---

## Goals

| Goal | Acceptance Criterion |
|---|---|
| **G1** | v3 mouse battery readable in tray within 5 s of icon hover, with scroll auto-restored within 10 s after read completes |
| **G2** | v1 mouse battery readable concurrently with v3 (no recycle dependency for v1) |
| **G3** | v2 mouse battery readable concurrently with v1 + v3 (validate channel in M2) |
| **G4** | Magic Keyboard battery readable concurrently with all mice (Feature 0x47) |
| **G5** | Tray UI shows all detected devices simultaneously with per-device % and last-poll timestamp |
| **G6** | Adaptive polling: more frequent when low (<20%), less frequent when high (>80%); default 15 min cadence per Magic Utilities pattern |
| **G7** | Battery poll for v3 only fires when user is **idle for ≥30 s** to minimise scroll-glitch impact |
| **G8** | Manual "refresh now" option in tray menu for explicit battery query |
| **G9** | Mode A→B recovery is observed and reported in tray status; if recovery fails, alert user |
| **G10** | Telemetry log of every recycle (timestamp, pre-state, post-state, success/fail, battery read result) |

---

## Non-Goals

- M14 / kernel filter rewrite
- Binary patching of `applewirelessmouse.sys`
- AirPods / non-mouse-or-keyboard Apple devices
- Replacing Apple's driver — keep the WHQL-signed 78424-byte stock binary intact

---

## Architecture

### Component overview

```
+---------------------------------+
|         TrayApp (WPF)           |
|---------------------------------|
| - DeviceRegistry (multi-device) |
| - PerDevicePoller (adaptive)    |
| - V3RecycleManager (Mode A/B)   |
| - BatteryDisplay (multi-row UI) |
+---------------+-----------------+
                |
                v
+---------------------------------+
|    Per-Device Battery Reader    |
|---------------------------------|
| Keyboard (PID 0x0239)  -> 0x47  |  Feature read, no recycle needed
| v1 mouse (PID 0x030D)  -> 0x47  |  Feature read, no recycle needed
| v2 mouse (PID 0x0269)  -> 0x47* |  TBD M2 — confirm channel
| v3 mouse (PID 0x0323)  -> 0x90  |  Input read, recycle needed for COL02
+---------------+-----------------+
                |
                v
+---------------------------------+
|    PnpRecycler (v3 only)        |
|---------------------------------|
| FLIP:NoFilter phase:            |
| - remove applewirelessmouse     |
|   from LowerFilters registry    |
| - Disable+Enable BTHENUM PDO   |
| - wait for COL02 to enumerate  |
|   (typically ~1 s)              |
| - read battery RID=0x90 buf[2] |
| FLIP:AppleFilter phase:         |
| - re-add applewirelessmouse     |
|   to LowerFilters registry      |
| - Disable+Enable BTHENUM PDO   |
| - FORCED Mode B restore         |
| All via MM-Dev-Cycle queue      |
+---------------------------------+
```

### State machine for v3 polling

```
[Idle (Mode B)] --user-idle≥30s + poll-due--> [FlipToA]
[FlipToA]  --FLIP:NoFilter complete + COL02 detected--> [Reading]
[FlipToA]  --FLIP:NoFilter complete + COL02 absent--> [Idle (Mode B)] (skip poll, retry next interval)
[Reading]  --battery received (buf[2] in 0..100)--> [FlipToB]
[Reading]  --HidD_GetInputReport error--> [FlipToB] (still must restore Mode B)
[FlipToB]  --FLIP:AppleFilter complete + COL02 gone--> [Idle (Mode B)]
[FlipToB]  --60s timeout, COL02 still present--> [FlipToB retry] then [Alert: Mode B unrecoverable]
```

**Note**: Mode A→B recovery is ALWAYS forced via FLIP:AppleFilter — there is no natural recovery.

### Multi-device tray UI

```
+--------------------------------+
|  ⌨  Magic Keyboard       82%   |
|  🖱  Magic Mouse v1      67%   |
|  🖱  Magic Mouse v2      54%*  |  * = polled 14 min ago
|  🖱  Magic Mouse 2024    38%*  |  * = recycle-required device
|--------------------------------|
|  ⟳  Refresh All                |
|  ⚙  Settings                   |
+--------------------------------+
```

### Multi-device detection logic

| Device | Detection signal | Battery channel | Recycle? |
|---|---|---|---|
| Magic Keyboard | BTHENUM with VID=05AC PID=0239 (or Apple BT VID 004C variant) | `HidD_GetFeature(RID=0x47)` on COL01 | No |
| Magic Mouse v1 | BTHENUM with VID=05AC PID=030D | `HidD_GetFeature(RID=0x47)` on COL01 | No |
| Magic Mouse v2 | BTHENUM with VID=05AC PID=0269 | TBD M2 — try Feature 0x47 first, fall back to Input 0x90 | TBD |
| Magic Mouse v3 | BTHENUM with VID=004C/05AC PID=0323 | `HidD_GetInputReport(RID=0x90)` on COL02 | **YES — only when COL02 missing** |

A device is "detected" if its BTHENUM PDO is enumerated and Status=OK. Detection runs on tray app startup + every 60 s + on `WTSSESSION_CHANGE` / `DEVICECHANGE` events.

---

## Milestones

### M0 — **GATING VALIDATION** (must pass before M1+ work begins) — added 2026-05-06

**Problem**: PATH-B's core assumption — that we can flip the v3 mouse from Mode B (current steady state, scroll works, no battery) into Mode A (battery readable, scroll broken) on demand — has **NOT been empirically validated**.

What HAS been confirmed:
- H-009 (2026-04-27, Phase 4-Omega): a `pnputil /restart-device` cycle of the BTHENUM HID PDO reliably flips Phase-4-Omega "State B → State A". **Per Phase 4-Omega's reversed naming convention vs current PSN**, that translates to `Mode A (split, battery readable, scroll broken) → Mode B (unified, scroll works, no battery)` in current PSN terms. This is the *natural recovery direction* — PATH-B does NOT need this.

What M0 found (Session 15, 2026-05-06):
- **H-012 bare pnputil: CONFIRMED FAIL** — `pnputil /restart-device` on BTHENUM HID PDO as SYSTEM. COL02 never appeared across 15 attempts. HidBth re-serves Mode B cache regardless.
- **M0a: CONFIRMED PASS** — FLIP:NoFilter (remove `applewirelessmouse` from `LowerFilters` + `Disable-PnpDevice` + `Enable-PnpDevice` via MM-Dev-Cycle queue) → COL02 within ~1 s. Battery confirmed 17% (RID=0x90, buf[2]=0x11). This is sub-test M0a from the original plan — it passed on first attempt.
- **Mode B restoration is FORCED** — removing the filter leaves device in Mode A indefinitely. Explicit FLIP:AppleFilter (re-add + disable/enable) required. The "natural recovery" assumption in the original design was incorrect.
- **N=20 full harness run pending** to confirm P50/P95 timing, success rate over repeated cycles, and generate the validation report.

**M0 deliverables** (updated 2026-05-06):
- [x] Standalone test harness (`scripts/m0-validate-recycle-to-modeA.ps1`) built using MM-Dev-Cycle queue protocol — FLIP:NoFilter / FLIP:AppleFilter phases; N=20 default
- [x] Each attempt:
  1. Capture pre-state: COL01/COL02 enumeration via `Get-PnpDevice`
  2. Send FLIP:NoFilter to MM-Dev-Cycle queue (remove filter + disable/enable BTHENUM)
  3. Wait up to 30 s for COL02 to appear
  4. Battery probe: `HidD_GetInputReport(RID=0x90)` on dynamic COL02 path; verify buf[2] in 0..100
  5. Send FLIP:AppleFilter to MM-Dev-Cycle queue (re-add filter + disable/enable, forced Mode B restore)
  6. Wait 10 s for COL02 to disappear before next attempt
- [x] Classify each attempt: `MODE_A_REACHED`, `MODE_B_LOCKED`, `BATTERY_READ_OK`, `BATTERY_READ_FAIL`, `ERROR_OTHER`
- [~] Aggregate report: `docs/M0-MODE-B-TO-A-VALIDATION.md` — harness generates automatically; N=20 run pending
- [x] Verdict thresholds implemented in harness:
  - **success rate ≥ 70%**: M0 PASS — continue to M1
  - **30% ≤ success rate < 70%**: M0 PARTIAL — design retry / exponential backoff in M3
  - **success rate < 30%**: M0 FAIL — escalate (though empirical evidence strongly suggests PASS)

**Exit criteria**:
- M0 report file at `docs/M0-MODE-B-TO-A-VALIDATION.md` with success rate, recommended trigger, raw data, and PASS/PARTIAL/FAIL verdict
- PR review of M0 report before M1 begins

**Estimated effort**: 2-4 hours (test harness + 100 recycle samples + analysis). Fully scriptable via the existing `MM-Dev-Cycle` SYSTEM scheduled task; no manual mouse interaction required for the recycle itself (mouse must be paired and powered).

**Risk if skipped**: PRD M1-M6 builds the entire tray UX on a primitive that may not work reliably. The 2-4 hour upfront cost saves potential weeks of M3 rework.

### M1 — Multi-device detection scaffolding
- [ ] **Gated by M0 PASS or PARTIAL**
- [ ] Refactor `MouseBatteryReader.cs` into per-device readers behind a common `IBatteryDevice` interface
- [ ] Add `KeyboardBatteryReader.cs` (Feature 0x47 path)
- [ ] Add device registry that scans BTHENUM children every 60 s and on PnP change events
- [ ] Tray menu rendered from registry; one row per detected device
- **Exit criteria**: tray shows v1 + v3 with current static read paths working as today; keyboard appears if paired

### M2 — v2 mouse channel confirmation
- [ ] Pair v2 mouse, capture HID descriptor dump
- [ ] Determine whether v2 uses Feature 0x47 (like v1/keyboard) or Input 0x90 (like v3)
- [ ] Update `v2BatteryReader` to use confirmed channel
- **Exit criteria**: v2 battery reads correctly when paired

### M3 — v3 PnP recycler integration
- [ ] Port C# prototype (commit e323df6 per PSN-0001 Session 10) into `V3RecycleManager.cs`
- [ ] Wire to existing `MM-Dev-Cycle` scheduled task (`scripts/mm-task-runner.ps1`)
- [ ] Add idle-detection (`GetLastInputInfo` Win32) — only recycle when idle ≥ 30 s
- [ ] State machine implementation (Idle → Cycling → Reading → Recovering → Idle)
- [ ] Cap recycle attempts (3 retries) with exponential backoff
- **Exit criteria**: v3 battery readable in tray; scroll auto-recovers within 10 s of read complete

### M4 — Adaptive polling
- [ ] Per-device interval tracking
- [ ] Default 15 min cadence (per research-findings.md guidance)
- [ ] Reduce to 5 min when battery <20%
- [ ] Increase to 60 min when battery >80% AND on AC (pass-through; not relevant for BT mice)
- [ ] Manual "Refresh now" command in tray
- **Exit criteria**: cadence correctly auto-adjusts, no thrash on boundaries

### M5 — Telemetry + observability
- [ ] Log every recycle attempt to `C:\ProgramData\MagicMouseTray\recycle-events.jsonl`
- [ ] Log every battery read (success/failure, value, latency)
- [ ] Tray menu "Show diagnostics" shows last 10 events
- [ ] Optional: send anomaly alerts via existing `CriticalAlert.cs` + `ToastNotifier.cs` channels
- **Exit criteria**: 7-day soak test produces clean event log with zero unexpected state-machine transitions

### M6 — UX polish + Settings
- [ ] Settings dialog: enable/disable v3 recycle (default off until first user request); polling intervals; idle-time threshold
- [ ] Per-device colour-coded battery indicator (green >50%, yellow 20-50%, red <20%)
- [ ] Tooltip with last-poll timestamp + manual refresh option
- **Exit criteria**: settings persisted to `Config.cs`; user can disable v3 recycler if scroll glitch is unacceptable

---

## Open Questions

1. **Q1 — recycle race conditions**: if user starts scrolling exactly when a recycle is in progress, does scroll get permanently broken until next cycle? → Need test in M3.
2. **Q2 — v2 channel**: assumption is Feature 0x47 (matches v1+keyboard). If v2 actually uses RID 0x90 like v3, M2 will discover and we'll need an additional recycle path.
3. **Q3 — keyboard descriptor cache**: does the keyboard have an analogous Mode A/B issue, or does Feature 0x47 work consistently? Per research-findings.md "kbdhid lock makes Feature 0x47 wedge" — needs M1 validation.
4. **Q4 — multiple v3 mice**: edge case if user has two v3 mice paired. Each has its own BTHENUM and each needs its own recycle. Race-condition during simultaneous recycles.
5. **Q5 — battery telemetry retention**: how much history to keep? Default 30 days?
6. **Q6 — recycle-to-Mode-A reliability**: **ANSWERED by M0 (Session 15, 2026-05-06)**. Bare `pnputil /restart-device` (RESTART-DEVICE queue phase) FAILS even as SYSTEM — COL02 never appeared in 15 attempts. **M0a (FLIP:NoFilter: remove `applewirelessmouse` LowerFilters + disable/enable BTHENUM via MM-Dev-Cycle) PASSES** — COL02 within ~1 s, battery 17% confirmed (RID=0x90, buf[2]=0x11). **Mode B restoration is FORCED** — explicit FLIP:AppleFilter required; natural recovery does NOT occur. N=20 full harness run pending to establish P50/P95 timing and confirm success rate. PATH-B is viable with M0a as the trigger. H-009 naming-convention gap is now resolved — "State B → State A" in Phase 4-Omega = "Mode B → Mode A" in current PSN = what FLIP:NoFilter achieves.

---

## Naming Convention Note (avoid future confusion)

`PHASE4-OMEGA-PLAN.md` (Session 10) and current PSN-0001 (post-AP-21 H-010 revised) use **opposite** State A/B labels:

| Reference | "State A" | "State B" |
|---|---|---|
| Phase 4-Omega Session 10 doc | scroll works, no battery (= unified) | scroll broken, battery readable (= split) |
| PSN-0001 current (post-AP-21) | **Mode A = split / battery readable** | **Mode B = unified / scroll works** |

**This PRD uses the current PSN convention throughout** (Mode A = battery, Mode B = scroll).

---

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| User scrolls during recycle window | Adaptive: only recycle on user idle ≥ 30 s. State machine cancels in-flight recycle if user input detected. |
| Mode A→B recovery fails | Detect after 60 s timeout; force a second recycle; if still stuck, alert user with manual recovery option. |
| Magic Utilities residual filter conflicts | Detection on startup: if `LowerFilters` includes `MagicMouse` or other 3rd-party kernel filters, warn user and disable v3 recycler (we don't own the descriptor cache behaviour). |
| Recycle scheduled task disabled | Check `MM-Dev-Cycle` task health on startup; if missing, regenerate from `scripts/install-driver.ps1`. |
| Driver instability after many recycles | Track failure rate; if >10% recycles fail in a 24h window, alert user + open issue. |

---

## Dependencies

- `applewirelessmouse.sys` Apple WHQL stock driver (already restored 2026-05-05)
- `MM-Dev-Cycle` scheduled SYSTEM task + `scripts/mm-task-runner.ps1` (already implemented; existing routes `RESTART-DEVICE` + `CLEAR-BT-SDP-CACHE` cover the recycle path)
- C# tray app (`MagicMouseTray/*.cs`) — extension via M1-M6 above
- Existing `MouseBatteryReader.cs` Feature/Input read code paths (refactor in M1)
- HID descriptor dumps for v1, v2, v3, keyboard (already captured in `.ai/test-runs/2026-04-27-154930-T-V3-AF/`)

---

## Out of Scope (deferred)

- Deeper Ghidra investigation of `applewirelessmouse.sys` to enable proper binary patching (separate session — see `docs/INVESTIGATION-PROMPT-GHIDRA-DESCRIPTOR-TRACE.md`)
- M14 kernel filter rewrite
- Power management integration (charging/AC detection — not applicable to Bluetooth peripherals)
- AirPods battery via BLE manufacturer data (separate subsystem; see `docs/research-findings.md`)
- Battery-low system notifications via Windows Action Center (defer to v2)

---

## Success Metrics

- v3 battery read success rate ≥ 95% over 7-day soak
- v3 scroll glitch duration ≤ 10 s per poll (P95)
- Battery polls per day per v3 mouse ≤ 100 (default 15 min cadence ≈ 96/day)
- Zero unrecovered Mode A states across 7 days
- All 4 device types polled correctly when paired simultaneously

---

## References

- PSN-0001 hypothesis log: H-007 (battery-only without filter), H-009 (recycle reliability), H-010 revised (mode mutual exclusion)
- Phase 4-Omega plan: `.ai/test-runs/2026-04-27-154930-T-V3-AF/PHASE4-OMEGA-PLAN.md`
- Research synthesis: `docs/research-findings.md` (three battery channels + cadence guidance)
- C# recycle prototype: commit `e323df6` (per PSN-0001 Session 10)
- Magic Utilities cadence reference: 15 min poll interval, avoids 10–50 ms scroll stutter
- Session 15 empirical results: `docs/SESSION-15-EMPIRICAL-TEST-RESULTS-2026-05-05.md`
