# V3 Magic Mouse — macOS HCI Capture Findings (2026-05-10)

> **Companion to:** [`M4-MAC-CAPTURE-FINDINGS-2026-05-08.md`](M4-MAC-CAPTURE-FINDINGS-2026-05-08.md)
> (Apple keyboard + V1 Magic Mouse). The V3 mouse uses a **different**
> battery protocol from the keyboard / V1 mouse, so it gets its own write-up.
>
> **Companion to:** [`M13-V3-BATTERY-AUDIT-2026-04-30.md`](M13-V3-BATTERY-AUDIT-2026-04-30.md)
> (Windows-side V3 battery audit). The macOS HCI bytes here corroborate the
> existing Windows analysis — same RID, same byte layout, same percent in
> `buf[2]`. No new wire protocol; what's new is the device-side push pattern,
> the multi-touch RID confirmation, and the cross-OS reconciliation.

## TL;DR

| What | V3 Magic Mouse (PID `0x0323`) | Keyboard / V1 Mouse (for contrast) |
|---|---|---|
| Battery protocol | **Device-pushed** Input report on **RID `0x90`** | Host-issued GET_REPORT Feature on RID `0x47` |
| Battery wire bytes | `a1 90 04 NN` (3-byte HID payload after THdr) | `43 47` query → `A3 47 NN` response |
| `buf[2]` value | battery percent (0–100) | battery percent (0–100) |
| Pushed when | At every reconnect; ~6 times in a 19-min capture spanning 3 reconnects | N/A — query-driven, ~60 s cadence |
| Multi-touch / pointer | **RID `0x12`** (Linux: `MOUSE2_REPORT_ID`) | N/A — keyboard has its own RIDs |
| Windows blocker | HidBth descriptor cache non-determinism (M3/M13 territory) | HidD_* RID validation against missing descriptor entries (M4 territory; raw L2CAP fix in PR #35) |

**The Windows-side reader code in [`MouseBatteryReader.cs`](../MagicMouseTray/MouseBatteryReader.cs)
is already correct.** This capture confirms it — `buf[2]` is the battery
percent for V3, exactly as the existing code assumes.

## Source capture

- **File:** `/Users/lesley/Documents/Magic_mouse_v3.pklg` (PacketLogger, ~2 MB,
  43,786 frames, ~19 min span). Not committed (contains BD addresses of
  unrelated nearby devices).
- **Tool:** PacketLogger.app with the Apple Bluetooth Debug Logging Profile
  installed (see prior M4 doc for install instructions).
- **Mouse:** "Magic Mouse", BD addr `D0:C0:50:CC:8C:4D`, VID `0x004C` /
  PID `0x0323`, firmware `3.1.4`. Note the OUI: VID `0x004C` (newer Apple
  range) vs the V1 mouse's `0x05AC` and the keyboard's `0x05AC`.
- **Decoder:** `tshark` (Wireshark CLI), reads `.pklg` directly.

## Full HID RID inventory observed

### Input reports (THdr `0xa1` — device → host)

| RID | Count | Sample wire bytes (HID payload) | Identity |
|---|---|---|---|
| **`0x12`** | **27,669** | `a1 12 00 f2 ff 2b 00` (length 7), `a1 12 00 00 00 00 00 …` (length 7–15) | **Multi-touch / pointer** (Linux `MOUSE2_REPORT_ID`). Variable-length per-touch encoding decoded in `magicmouse_raw_event()`. |
| `0xf0` | 6 | `a1 f0 90 04 2a` | Vendor channel **wrapping** a RID-`0x90` battery payload. Identical battery byte (`buf[2]`) inside. |
| `0x90` | 6 | `a1 90 04 2a` | **Battery push.** Layout: `[RID][flags?][pct]`. Pushed twice per reconnect in our capture (3 reconnects × 2 = 6). |
| `0x60` | 3 | `a1 60 02` | One per reconnect — likely a wake/state notify. Single payload byte `0x02`. |
| `0x13` | 1 | (variant of `0x12`) | Possibly extended-touch report; only one observed. |

### Feature responses (THdr `0xa3` — answers to host `43 ??` queries)

| RID | Count | Sample wire bytes | Notes |
|---|---|---|---|
| `0xf0` | 36 | `a3 f0 BB 01 00 20 04`, `a3 f0 34 03 14 03 d0`, `a3 f0 e0 00 00 00 00`, `a3 f0 14 22`, `a3 f0 c5 01`, `a3 f0 b8 48 00`, `a3 f0 bc 02 00` | Multiplexed vendor channel. Sub-command set first via `53 ff <subcmd>`, then read with `43 f0`. The first byte after the RID echoes the sub-command index. **None match a 0–100 battery shape.** |
| `0xf1` | 9 | `a3 f1 00 01`, `a3 f1 01 db 00 3c 00`, `a3 f1 db 01 02 00 d1` | Vendor configuration / acks. |
| `0x4a` | 3 | `a3 4a 01 01` | 2-byte status flags. Seen 3 times, identical bytes — likely a static device-info field. |

### Connect-time host transactions observed (THdr `0x53`/`0x43`/`0x71` etc., host → device)

These are host-issued vendor configuration. **None of them match the
keyboard's `53 4A 03` init or the keyboard/V1's `43 47` battery query.**
The V3 protocol family is entirely separate.

```
71                       SET_PROTOCOL Report mode (universal across Apple BT HID)
53 c6 01 12 02 2c        SET_REPORT Feature, vendor configuration A
53 c6 01 18 02 20        SET_REPORT Feature, vendor configuration A (variant)
53 ff <subcmd>           SET_REPORT Feature, multiplexed vendor sub-command
                         observed sub-cmds: 00 01 14 34 90 b8 bb bc c5 db e0
43 f0                    GET_REPORT Feature, multiplexed vendor read
43 f1                    GET_REPORT Feature, vendor config
43 4a                    GET_REPORT Feature, 2-byte status
41 f0                    GET_REPORT Input,   vendor read (Input variant)
53 f1 06 01 37           SET_REPORT Feature, RID 0xF1 sub-write
53 f1 02 01              SET_REPORT Feature, RID 0xF1 sub-write
53 f1 01 db              SET_REPORT Feature, RID 0xF1 sub-write
```

## Battery report — byte layout (cross-OS confirmation)

The 3-byte RID-`0x90` battery report has been observed identically in
three independent contexts:

| Source | Bytes | `buf[2]` (decoded) |
|---|---|---|
| Repo audit, 2026-04-29 ([`M13-V3-BATTERY-AUDIT-2026-04-30.md`](M13-V3-BATTERY-AUDIT-2026-04-30.md)) | `90 04 22` | `0x22` = **34 %** |
| This Mac PacketLogger capture (2026-05-10) | `a1 90 04 2a` | `0x2a` = **42 %** |
| Windows `HidD_GetInputReport(0x90)` probe (this session) | `90 04 28 00 00 00 00 00` | `0x28` = **40 %** |
| Repo `mm3-pre-validation-baseline-2026-04-26.md:60` | `90 04 31` | `0x31` = **49 %** |

```
buf[0] = 0x90    Report ID (always)
buf[1] = 0x04    constant — observed in EVERY capture across both OSes
buf[2] = pct     battery 0–100 (0x00–0x64)
buf[3..N] = 0    zero pad when caller's buffer > 3 bytes
```

The "8-byte buffer" form on Windows (`90 04 28 00 00 00 00 00`) is just
`MaxInputReportSize` zero-padding — col02 has other RIDs that need 8 bytes,
so HID class returns 8 even for the 3-byte RID `0x90`.

## Open question: what is `buf[1] = 0x04`?

**Status:** unresolved. `mm3-pre-validation-baseline-2026-04-26.md:63`
labels it "(flags)" but no capture has shown it taking any other value.

**Evidence so far:**

- Repo's 2026-04-29 probe: `0x04` (mouse at 34 %)
- Repo's 2026-04-26 baseline: `0x04` (mouse at 49 %)
- Mac capture, 2026-05-10: `0x04` (mouse at 42 %)
- Windows probe, 2026-05-10: `0x04` (mouse at 40 %)

Two independent OSes, four different battery percentages, weeks apart — same
constant `0x04`. Most likely explanations:

1. **Static format/version byte** — `0x04` is the "this is a battery v1
   payload" marker. Easy to imagine Apple firmware re-using a stable
   identifier here.
2. **Status flags byte where every observed state has bit 2 set** — would
   require seeing it flip during a state we haven't captured (charging,
   critical-low, paired-but-asleep) to know the bit-meanings.

**Cheap experiment that would close this question:** capture a fresh RID
`0x90` push while the mouse is charging via USB-C. If `buf[1]` flips, it's
flags; if it stays `0x04`, it's a constant. Worth one minute next time the
mouse is being charged anyway.

For now, **the safe call in [`MouseBatteryReader.cs`](../MagicMouseTray/MouseBatteryReader.cs)
is to ignore `buf[1]` and use `buf[2]` directly as the battery percent**,
which is what the existing code does. If `buf[1]` later turns out to encode
a charging flag, that becomes a UI enhancement, not a correctness fix.

## Multi-touch RID `0x12` — what's in it

Linux `drivers/hid/hid-magicmouse.c` (`magicmouse_raw_event()`) decodes
RID `0x12` byte-by-byte. Summary of the per-frame structure:

- **Length:** variable, 7–15 bytes depending on touch count.
- **Byte 0:** number of active touches (0 = pointer-only, 1+ = trackpad-style).
- **Subsequent bytes:** mouse motion (`dx`, `dy` as signed shorts) when no
  touches; or per-touch (finger ID, X, Y, pressure, contact size encoded
  across multiple bytes per touch) when 1+ touches.

For the V3 (USB-C, PID `0x0323`), the report layout is the same as the
V2 `MOUSE2_REPORT_ID = 0x12` — Linux added the V3 PID under the existing
device-ID table and reuses the V2 parsing path:

```
USB_DEVICE_ID_APPLE_MAGICMOUSE2_USBC → MOUSE2_REPORT_ID (0x12)
```

This is the canonical reference. Anyone porting multi-touch handling on
Windows should mirror Linux's `magicmouse_emit_touch()` decoding.

## Implications for the Windows port

| Concern | Status |
|---|---|
| Battery byte layout | **Solved.** `buf[2]` = pct, confirmed across OSes and probes. Existing [`MouseBatteryReader.cs:178-204`](../MagicMouseTray/MouseBatteryReader.cs) reads it correctly when col02 is enumerated. |
| `HidD_GetInputReport(0x90)` works | **Conditional.** Works under Descriptor A (col02 enumerates the vendor TLC); fails under Descriptor B (col02 orphaned). See [`v3-BATTERY-EMPIRICAL-PROOF-AND-PATHS.md`](v3-BATTERY-EMPIRICAL-PROOF-AND-PATHS.md). |
| Windows blocker | **Descriptor-cache non-determinism in HidBth.** Not a wire-protocol problem — purely a Windows kernel-layer issue. M3/M13 territory; tracked in those docs. |
| Multi-touch port | Out of scope for the M4 battery work. RID `0x12` decoded by Linux source — straightforward to port if/when needed. |
| Charging-flag UI | Open question pending the `buf[1]` experiment. Low-priority enhancement. |

**Net:** the V3 work doesn't need a new mac-side investigation. The remaining
problem is on the Windows kernel side and is being tracked under M3/M13.

## Reproducibility

To re-derive the V3 macOS findings on a different machine:

```bash
# Mac side: install the Bluetooth Debug Logging Profile from Apple Developer,
# reboot, then with a paired V3 mouse:
#  1. Open PacketLogger.app, hit the red Start button.
#  2. Disconnect/reconnect the mouse via blueutil to capture init + push:
brew install blueutil
KBD=d0-c0-50-cc-8c-4d
blueutil --disconnect $KBD; sleep 4; blueutil --connect $KBD; sleep 30
#  3. PacketLogger > File > Stop, Save As ~/Documents/v3.pklg

# Then dissect:
brew install wireshark
FILE=~/Documents/v3.pklg

# Battery push (RID 0x90):
tshark -r "$FILE" -Y "bthid && bthid.transaction_type == 0xa" -x \
  | grep -E '^0000' | grep ' a1 90 ' | head

# Multi-touch (RID 0x12):
tshark -r "$FILE" -Y "bthid && bthid.transaction_type == 0xa" -x \
  | grep -E '^0000' | grep ' a1 12 ' | head

# Full RID histogram:
tshark -r "$FILE" -Y "bthid && bthid.transaction_type == 0xa" -x \
  | grep -E '^0000' | awk '$11=="a1"{c[$12]++} END{for(r in c)printf "RID 0x%s %d\n",r,c[r]}' \
  | sort -k3 -rn
```

Expected: `a1 90 04 NN` somewhere in the output, where `NN` is the current
battery percent in hex; tens of thousands of `a1 12 …` multi-touch frames
if the mouse was being used during the capture.
