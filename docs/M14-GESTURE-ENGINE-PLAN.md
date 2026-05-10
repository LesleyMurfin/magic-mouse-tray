---
title: M14 - v3 Gesture Engine Plan (with PacketLogger ground-truth)
type: design
date: 2026-05-09
status: planned
linked_prd: PRD-184
linked_psn: PSN-0001
depends_on: M13 (descriptor injection - DONE per Session 13)
---

# M14 - v3 Gesture Engine

**BLUF**: M13 already does SDP descriptor injection successfully (COL01+COL02+COL03 enumerate, SdpPatchSuccess=1, IoctlInterceptCount=2 per PSN H-017/H-018). M14 adds the gesture translation: intercept RID 0x27 multi-touch reports on read-completion, parse Apple's proprietary 46-byte format, synthesize standard HID Wheel (0x38) + AC-Pan (0x238B) values into the IRP buffer before completing upward.

PacketLogger access on the MacBook is the **unlock** that turns this from research project into translation exercise. Estimated **4-7 sessions / 1-2 weeks** for shippable 2-finger scroll.

## References available

| Source | Coverage | Quality |
|---|---|---|
| Linux `drivers/hid/hid-magicmouse.c` master | Gesture translation logic for RID 0x29/0x12/0x28 (v1, v2, trackpad). Documented byte layouts, scroll/pan synthesis, finger tracking. | Open-source, battle-tested. RID 0x27 (v3 specific) NOT covered upstream - but the Linux code structure transfers. |
| Ghidra'd `MagicMouse.sys` (Magic Utilities, captured 2026-04-28) | Closed-source but RE'd. Has the actual v3 RID 0x27 byte layout + translation code Apple/MU figured out. | At `.ai/M12-MagicMouse.gpr` |
| **MacBook + Apple PacketLogger + paired v3** | Wire-level ground truth - exact bytes macOS sees during real gestures | **Game-changer**. Eliminates the "guess at byte semantics" phase. |
| M13 codebase (`driver/MagicMouseDriver.*`) | WDF filter scaffolding in place. Descriptor injection working. EvtIoDeviceControl pattern established. EvtIoDefault pass-through verified. | ~60% of plumbing done |
| Existing M13 build pipeline | `mm-task-runner.ps1 BUILD` route auto-mounts EWDK, calls mm-dev.ps1 -Phase Build. SIGN phase signs .sys+.cat. | Tested (Session 14 H-026 + earlier sessions) |

## Phased plan

### M14a - Discovery via PacketLogger (1 session, ~4 hrs)

Goal: characterize v3's RID 0x27 multi-touch byte format from real gestures.

Setup:
- Pair v3 mouse to MacBook
- Open Apple Bluetooth Explorer or PacketLogger
- Confirm reception of RID 0x27 reports during touch

Capture protocol (~30-60 captures total):
| Gesture | Iterations | Purpose |
|---|---|---|
| No touch (idle) | 5 sec baseline | Identify zero-state byte pattern |
| Single finger contact (no movement) | 5 captures | Identify contact-presence bits |
| Single finger Y-movement up 10px | 10 captures | Map Y-delta encoding |
| Single finger Y-movement down 10px | 10 captures | Confirm signed Y-delta |
| Single finger X-movement | 10 captures | Map X-delta encoding |
| Two-finger scroll up | 10 captures | Map multi-finger encoding |
| Two-finger scroll down | 10 captures | Confirm direction |
| Two-finger horizontal | 5 captures | Pan direction |
| Three-finger swipe (deferred) | 0 - scope creep | Skip for v1 |

Decode each capture against the prior — diff the bytes. Build a byte-position-to-meaning map. Save to `docs/M14-V3-RID27-BYTE-LAYOUT.md`.

Cross-reference against:
- Ghidra'd MagicMouse.sys — find the RID 0x27 parsing function, confirm byte interpretations
- Linux hid-magicmouse.c MOUSE_REPORT_ID / MOUSE2_REPORT_ID parsing — see if any structure transfers

Output: byte-layout reference doc + sanity-checked finger/X/Y/pressure decoder.

### M14b - Translation logic (1-2 sessions)

Goal: pure C/C++ function that converts a raw RID 0x27 byte buffer into a standard mouse RID 0x02 buffer with Wheel + AC-Pan values.

Reference: Linux `magicmouse_emit_touch()` and `magicmouse_raw_event()` for the math (scroll velocity from finger Y-delta over time, dead-zone, acceleration curve).

```c
// pseudo-code
NTSTATUS TranslateRid27ToWheel(
    PUCHAR rid27Buffer, ULONG rid27Length,
    PUCHAR rid02Buffer, PULONG rid02Length)
{
    if (rid27Buffer[0] != 0x27 || rid27Length < 46) return STATUS_INVALID_PARAMETER;

    // Per M14a byte map (TBD):
    UCHAR fingerCount = rid27Buffer[<offset>];
    if (fingerCount != 2) return STATUS_NOT_FOUND;  // only handle 2-finger scroll for v1.0

    SHORT y0 = ParseSignedY(rid27Buffer, <offsets>);
    SHORT y1 = ParseSignedY(rid27Buffer, <offsets>);
    SHORT yScroll = (y0 + y1) / 2;  // average vertical delta

    SHORT wheelTicks = ApplyAccelCurve(yScroll, prev_yScroll, time_delta);

    // Build RID 0x02 mouse report with Wheel field set
    rid02Buffer[0] = 0x02;
    rid02Buffer[1] = 0;     // buttons
    rid02Buffer[2] = 0;     // X
    rid02Buffer[3] = 0;     // Y
    rid02Buffer[4] = (UCHAR)wheelTicks;  // Wheel
    *rid02Length = 5;
    return STATUS_SUCCESS;
}
```

Unit-test in user-mode test harness with captured byte buffers from M14a. Get scroll-direction-correct + magnitude-reasonable output before touching the kernel.

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
| RID 0x27 byte layout doesn't match Linux/Ghidra reference | PacketLogger ground-truths it |
| Acceleration curve feels wrong on Windows | Iterative tune, Magic Utilities binary as benchmark |
| WDF EvtIoRead vs EvtIoDefault interaction | M13 already has the EvtIoDefault pass-through pattern (H-018) |
| Latent bugs in our parsing causing BSOD | Driver Verifier on during dev; user-mode harness for translation logic before kernel test |

## Build / sign / install workflow (M14 reuses existing)

- `mm-task-runner.ps1 BUILD` route - auto-mounts EWDK, runs mm-dev.ps1 Build phase, produces MagicMouseDriver.sys
- `mm-task-runner.ps1 SIGN` route - signtool sign sys+cat with M14 cert (Set-AuthenticodeSignature for the cat per AP-28)
- `mm-task-runner.ps1 INSTALL-DRIVER` route - pnputil /add-driver
- v3 binds to MagicMouseDriver via MagicMouseDriver.inf (already specifies v3 PID per D-015)

## Time estimate (with MacBook+PacketLogger)

| Phase | Effort | Cumulative |
|---|---|---|
| M14a Discovery | 4 hrs | 4 hrs |
| M14b Translation logic | 8 hrs | 12 hrs |
| M14c Kernel wiring | 6 hrs | 18 hrs |
| M14d Polish (basic) | 4 hrs | 22 hrs |
| Iteration / debug headroom | 8 hrs | 30 hrs |

**~30 hours of focused work / 1-2 weeks calendar time.** Each phase is a clean unit-test-able deliverable.

## Strategic position

- **PATH-A descriptor patch + Session 19 install method** = today/tomorrow ship for v3 battery (with operational hygiene per D-S17-27)
- **M14 completion** = clean-IP shippable driver in 1-2 weeks. PATH-A becomes development tool; M14 becomes production.
- Both can run in parallel: PATH-A unblocks user testing now, M14 development happens on a separate branch / different machine

## Activity Log

| Date | Update |
|------|--------|
| 2026-05-09 | Plan written. PacketLogger access reduces estimate from 4-8 weeks to 1-2 weeks. |
