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

Deliver cursor + scroll + battery for Magic Mouse v3 (and v1/v2 + Magic Keyboard simultaneously) without modifying Apple's stock `applewirelessmouse.sys` driver. Strategy: tray app polls battery on demand by triggering a PnP recycle of the BTHENUM HID device to flip Apple's filter from Mode B (scroll, no battery) into Mode A (battery, no scroll), reads the battery, then flips back. Per H-009, recycle-to-Mode-A is empirically reliable. Acceptable trade-off: ~5 second scroll glitch per battery poll, scheduled adaptively.

Multi-device support shows live battery for any combination of detected: keyboard, v1 mouse (PID 0x030D), v2 mouse (PID 0x0269), v3 mouse (PID 0x0323) — same tray icon, expanding context menu.

---

## Problem & Context

Per PSN-0001 H-010 REVISED + H-007:

- v3 hardware exposes battery only via Input RID=0x90 on a vendor TLC (UP=0xFF00 / Usage=0x14)
- v1 mouse + Magic Keyboard expose battery via standard Feature RID=0x47 (UP=0x06 / Usage=0x20)
- v2 mouse pattern presumed similar to v1 (Feature 0x47); confirm in M2 of this PRD
- v3 with `applewirelessmouse` filter loaded has Mode A (battery readable, scroll broken) and Mode B (scroll synthesized, battery TLC stripped) — mutually exclusive
- PnP recycle of the BTHENUM HID PDO can flip B→A reliably (H-009 confirmed); the inverse (A→B) is the steady state and re-establishes naturally

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
| - schedules recycle via         |
|   MM-Dev-Cycle scheduled task   |
| - waits for COL02 to enumerate  |
| - reads battery                 |
| - allows Mode A→B natural       |
|   recovery (no forced action)   |
+---------------------------------+
```

### State machine for v3 polling

```
[Idle (Mode B)] --user-idle≥30s + poll-due--> [Cycling]
[Cycling]  --recycle complete + Mode A detected--> [Reading]
[Cycling]  --recycle complete + Mode B (still)--> [Idle (Mode B)] (skip poll, retry next interval)
[Reading]  --battery received--> [Recovering]
[Recovering] --Mode B observed--> [Idle (Mode B)]
[Recovering] --60s timeout, still Mode A--> [Forced cycle to B]
```

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

### M1 — Multi-device detection scaffolding
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
