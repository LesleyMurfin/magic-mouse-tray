---
title: M14 - v3 Gesture Engine Plan (Linux MOUSE2_REPORT_ID port)
type: design
date: 2026-05-10
version: 1.1.0
status: planned
linked_prd: PRD-184
linked_psn: PSN-0001
depends_on: M13 (descriptor injection - DONE per Session 13)
---

# M14 - v3 Gesture Engine

**BLUF**: v3 (PID 0x0323, Magic Mouse 2024) over Bluetooth uses **RID 0x12 = MOUSE2_REPORT_ID** — same RID Linux master `drivers/hid/hid-magicmouse.c` already handles. Linux's MOUSE2_REPORT_ID dispatch in `magicmouse_raw_event()` plus `magicmouse_emit_touch()` and `magicmouse_emit_buttons()` are the gesture engine. **~200 LOC port from Linux GPL'd C to our WDF kernel filter.** No protocol research needed — Linux is the spec.

Confirmed 2026-05-10 by user observation: "RID 0x12 matches exactly what Linux's hid-magicmouse.c calls MOUSE2_REPORT_ID = 0x12". Linux master USBC variant `USB_DEVICE_ID_APPLE_MAGICMOUSE2_USBC` references confirm v3 uses MOUSE2_REPORT_ID parsing path.

Revised estimate: **~16-20 hrs / 3-4 sessions / ~1 week** for shippable 2-finger scroll. (Prior PSN-0001 H-014 / D-017 stated "RID 0x27" — that note was wrong; v3 sends 0x12 like v2.)

## References available

| Source | Coverage | Quality |
|---|---|---|
| **Linux `drivers/hid/hid-magicmouse.c` master** | **MOUSE2_REPORT_ID (RID 0x12) handler covers v3.** Byte layout, finger touch parsing (`magicmouse_emit_touch`), button emission (`magicmouse_emit_buttons`), scroll/pan synthesis with REL_WHEEL/REL_HWHEEL/HI_RES variants. ~200 LOC of GPL'd C. | **Authoritative.** Battle-tested upstream. v3 USBC explicitly referenced (`USB_DEVICE_ID_APPLE_MAGICMOUSE2_USBC`). |
| Ghidra'd `MagicMouse.sys` (Magic Utilities, captured 2026-04-28) | Cross-verification only - confirm Linux's MOUSE2 byte layout matches what MU does in their kernel filter. | At `.ai/M12-MagicMouse.gpr` |
| MacBook + PacketLogger | Optional sanity check - capture one 2-finger scroll, confirm RID 0x12 size = 14+8N pattern matches Linux spec. ~5 min. | Confirmation only, not discovery |
| M13 codebase (`driver/MagicMouseDriver.*`) | WDF filter scaffolding in place. Descriptor injection working. EvtIoDeviceControl pattern established. EvtIoDefault pass-through verified. | ~60% of plumbing done |
| Existing M13 build pipeline | `mm-task-runner.ps1 BUILD` route auto-mounts EWDK, calls mm-dev.ps1 -Phase Build. SIGN phase signs .sys+.cat. | Tested (Session 14 H-026 + earlier sessions) |

## MOUSE2_REPORT_ID byte layout (per Linux master, lines 461-490)

```
Total report size: 8 (no touches) OR 14 + 8*N (where N = touch count, max 15)

Header (bytes 0..13, 14 bytes):
  [0]      = 0x12                  (RID, MOUSE2_REPORT_ID)
  [1]      = clicks                (button state)
  [2..3]   = X movement            (signed 16-bit BE: (data[3]<<24 | data[2]<<16) >> 16)
  [4..5]   = Y movement            (signed 16-bit BE: (data[5]<<24 | data[4]<<16) >> 16)
  [6..10]  = (other state)
  [11..13] = device timestamp      (Linux ignores)

Touch points (bytes 14..14+8*N, 8 bytes each):
  Parsed by magicmouse_emit_touch() — extracts finger position, pressure, contact area.
  Touch tracking math + scroll synthesis in lines 214..360 of hid-magicmouse.c.
```

Scroll synthesis: `magicmouse_emit_touch` calls `input_report_rel(REL_WHEEL/REL_HWHEEL/...)` based on finger Y/X deltas, with HI_RES variants for smooth scrolling.

## Phased plan

### M14a - Confirm RID + size pattern (1 session, ~1 hr)

Goal: verify v3 over Bluetooth actually emits RID 0x12 with the `14 + 8*N` size pattern Linux expects.

- Capture one 2-finger scroll on MacBook with PacketLogger
- Confirm: first byte 0x12, total size matches `14 + 8*N` for N>0
- Save the capture to `.ai/captures/M14-confirm-rid-<date>/` for archival

If confirmed: proceed directly to M14b. If RID is something else (e.g., 0x27 like PSN H-014 noted), we revert to discovery-mode but Linux's MOUSE2 algorithm still applies as a starting point.

### M14b - Port Linux MOUSE2 handler to C/WDF (1 session, ~6 hrs)

Goal: re-implement Linux's MOUSE2_REPORT_ID code path in our `driver/MagicMouseDriver.c`.

Functions to port (from `drivers/hid/hid-magicmouse.c`):
- `magicmouse_raw_event()` MOUSE2 case — header parsing (lines 461-490)
- `magicmouse_emit_touch()` — finger touch decoding + scroll math (lines 214-360)
- `magicmouse_emit_buttons()` — button emission (lines 177-213)

Output: pure C function `TranslateMouse2ToHid(BYTE* in, ULONG inLen, BYTE* out, ULONG* outLen)` that takes a RID 0x12 buffer and produces a standard RID 0x02 mouse report with Wheel/HWheel set.

Unit-test in user-mode harness against bytes captured in M14a. Confirm scroll direction + magnitude-reasonable output before kernel test.

### M14c - Kernel wiring (1 session, ~6 hrs)

Goal: hook `TranslateMouse2ToHid` into M13's existing WDF filter via EvtIoRead completion callback.

### M14c - Kernel wiring (1-2 sessions)

Goal: hook TranslateRid27ToWheel into M13's existing WDF filter via EvtIoRead completion callback.

Pattern (from PSN H-018 - WDF filter parallel queue requires explicit EvtIoDefault pass-through):
- Existing: EvtIoDeviceControl intercepts SDP IOCTL, EvtIoDefault forwards everything else
- Add: EvtIoRead completion routine that intercepts read completions from HidBth, checks RID byte, calls TranslateRid27ToWheel if RID==0x27, replaces the IRP output buffer with the translated RID 0x02 buffer, completes upward to mouclass

Sketch:
```c
EVT_WDF_IO_QUEUE_IO_READ MagicMouseDriverEvtIoRead;
VOID MagicMouseDriverEvtIoRead(WDFQUEUE Queue, WDFREQUEST Request, size_t Length)
{
    // forward request, set completion routine
    WdfRequestFormatRequestUsingCurrentType(Request);
    WdfRequestSetCompletionRoutine(Request, OnReadComplete, NULL);
    if (!WdfRequestSend(Request, IoTarget, NULL)) {
        WdfRequestComplete(Request, STATUS_UNSUCCESSFUL);
    }
}

VOID OnReadComplete(WDFREQUEST Request, WDFIOTARGET Target, PWDF_REQUEST_COMPLETION_PARAMS Params, WDFCONTEXT Context)
{
    PUCHAR buf;
    size_t len;
    WdfRequestRetrieveOutputBuffer(Request, 0, &buf, &len);
    if (buf[0] == 0x27 && len >= 46) {
        UCHAR translated[5];
        ULONG translatedLen = sizeof(translated);
        if (NT_SUCCESS(TranslateRid27ToWheel(buf, len, translated, &translatedLen))) {
            RtlCopyMemory(buf, translated, translatedLen);
            // Adjust IoStatus.Information to translatedLen
            WdfRequestSetInformation(Request, translatedLen);
        }
    }
    WdfRequestComplete(Request, Params->IoStatus.Status);
}
```

Test: install M13+M14 driver, trigger 2-finger scroll, observe Wheel events in Spy++ or via mouclass debug logging.

### M14d - Polish (1-2 sessions)

- Acceleration curve matching macOS feel (iterative tuning)
- AC-Pan (horizontal scroll) translation
- Dead zones (small jitter shouldn't scroll)
- Smooth-scroll vs tick-scroll handling
- v1 RID 0x29 / v2 RID 0x12 fallback paths if not already covered by Linux reference

### M14 deferred (out of scope for v1 ship)

- Three-finger swipe / mission-control gestures
- Force click / pressure thresholds
- Rotation gestures
- Custom gesture mappings

## Risks

| Risk | Mitigation |
|---|---|
| v3-BT actually uses different RID than 0x12 | M14a 1-hr confirmation capture before M14b |
| Acceleration curve feels wrong on Windows | Iterative tune, Magic Utilities binary as benchmark |
| WDF EvtIoRead vs EvtIoDefault interaction | M13 already has the EvtIoDefault pass-through pattern (H-018) |
| Latent bugs in our parsing causing BSOD | Driver Verifier on during dev; user-mode harness for translation logic before kernel test |
| GPL licensing concerns from porting Linux code | Translating algorithm/spec, not literal copy; standard practice for kernel-driver work. If concerns: derive from the byte layout documentation only and write fresh implementation. |

## Build / sign / install workflow (M14 reuses existing)

- `mm-task-runner.ps1 BUILD` route - auto-mounts EWDK, runs mm-dev.ps1 Build phase, produces MagicMouseDriver.sys
- `mm-task-runner.ps1 SIGN` route - signtool sign sys+cat with M14 cert (Set-AuthenticodeSignature for the cat per AP-28)
- `mm-task-runner.ps1 INSTALL-DRIVER` route - pnputil /add-driver
- v3 binds to MagicMouseDriver via MagicMouseDriver.inf (already specifies v3 PID per D-015)

## Time estimate (Linux MOUSE2 port)

| Phase | Effort | Cumulative |
|---|---|---|
| M14a Confirm RID/size pattern | 1 hr | 1 hr |
| M14b Port Linux MOUSE2 handler to C/WDF | 6 hrs | 7 hrs |
| M14c Kernel wiring on M13 scaffold | 6 hrs | 13 hrs |
| M14d Polish (acceleration, AC-Pan, dead zones) | 4 hrs | 17 hrs |
| Iteration / debug headroom | 4 hrs | 21 hrs |

**~21 hours of focused work / 3-4 sessions / ~1 week calendar time.** Each phase is a clean unit-test-able deliverable. Estimate dropped from 30 hrs because Linux already documents the byte format — no discovery phase needed beyond the 1-hr confirmation capture.

## Strategic position

- **PATH-A descriptor patch + Session 19 install method** = today/tomorrow ship for v3 battery (with operational hygiene per D-S17-27)
- **M14 completion** = clean-IP shippable driver in 1-2 weeks. PATH-A becomes development tool; M14 becomes production.
- Both can run in parallel: PATH-A unblocks user testing now, M14 development happens on a separate branch / different machine

## Activity Log

| Date | Update |
|------|--------|
| 2026-05-09 | Plan written. PacketLogger access reduces estimate from 4-8 weeks to 1-2 weeks. |
| 2026-05-10 | v1.1.0: confirmed v3 over Bluetooth uses **RID 0x12 = MOUSE2_REPORT_ID** (matches Linux master). Linux's MOUSE2 handler IS the v3 gesture engine — ~200 LOC port from GPL'd C to WDF. Estimate dropped to ~21 hrs / ~1 week. PSN-0001 H-014 / D-017 stating "RID 0x27" is corrected. PacketLogger no longer needed for byte-layout discovery — only as 1-hr confirmation. |
