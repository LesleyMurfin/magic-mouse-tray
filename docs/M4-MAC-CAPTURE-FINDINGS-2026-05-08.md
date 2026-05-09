# M4 Keyboard — macOS Bluetooth Capture Findings (2026-05-08)

> **Status update (HCI capture):** As of the second pass with the Apple
> Bluetooth Debug Logging Profile installed, we have **byte-exact wire
> traces** in `/Users/lesley/Documents/BT_Keyboard_Trace.pklg`. The bytes
> overturn the original "Hypothesis C′" plan — macOS uses **undocumented
> Report IDs** that don't appear in the public HID descriptor, so Windows
> `HidD_*` APIs (which validate against the descriptor) cannot replicate
> the wire flow. See "Byte-exact findings" below. The earlier sections
> ("Two-tier architecture", "Connect-time init sequence", etc.) are
> correct in shape but list the wrong RID for the init Set Feature; treat
> the Byte-exact section as canonical.


## Goal

Apple Wireless Keyboard (PID `0x0239`) battery is read successfully by macOS but
[KeyboardBatteryDevice.cs](../MagicMouseTray/KeyboardBatteryDevice.cs) documents
that all active read paths on Windows fail (`HidD_GetInputReport` err=87 for
all 255 RIDs, `HidD_GetFeature` empty/err=1, etc.). We captured macOS BT
subsystem behaviour to determine **how** macOS gets the value and whether the
Windows code can be made to do the same.

## Setup

- Mac: Apple Silicon, BT chipset BCM\_4388C2 (PCIe transport), macOS 26 (Sequoia).
- Keyboard: `Lesley's Keyboard`, BD\_ADDR `E8:06:88:4B:07:41`, VID `0x05AC` PID `0x0239`,
  Bluetooth Classic (BR/EDR), HID profile only — no BLE counterpart.
- Tools (no kernel debug profile required):
  - [scripts/kbd-mac-battery-capture-trigger.sh](../scripts/kbd-mac-battery-capture-trigger.sh) — disconnect/reconnect via `blueutil`.
  - [scripts/kbd-mac-battery-logstream.sh](../scripts/kbd-mac-battery-logstream.sh) — `sudo log stream` of `com.apple.bluetooth` subsystem around the reconnect.
- Capture artifact: [docs/kbd-mac-logstream.txt](kbd-mac-logstream.txt) (~9k lines, ~1.6 MB).

## Confirmed: HID descriptor matches the existing Windows finding

Dumped from `ioreg -l -w0 -r -c AppleBluetoothHIDKeyboard`. The
`ReportDescriptor` is identical to what the Windows side parsed:

- **Report ID `0x47` (71)** — Input, 1-byte payload, Generic Device Controls / Battery
  Strength, lives in **Collection 2** (= Windows `col02`).
- **Report ID `0x09`** — Feature, 1 data byte + 2 const padding bytes (4 bytes total
  including RID), Vendor page `0xFF01` Usage `0x0B`, lives in **Collection 3**
  (= Windows `col03`). This is the only Feature report on the device.
- `MaxFeatureReportSize = 4`, `MaxInputReportSize = 9`, `SetReportTimeoutMS = 3500`.

So the descriptor is not the missing piece. The wire protocol is.

## Connect-time init sequence (two steps)

A second capture at 00:31:43–.44 with `log config --mode 'private_data:on'`
revealed that the SCO Link State Set Report is preceded by a **Set Protocol**
transaction. **The RIDs and types in this table were corrected after the HCI
capture — see "Byte-exact findings" for the actual wire bytes:**

| Step | Originator | Transaction | Size | Notes |
|---|---|---|---|---|
| 1 | **Kernel** (`enqueueKernelSpaceHIDDataForDevice`) | `0x07` Set Protocol | 1 byte | Wire: `71` = Set Protocol, Protocol bit=1 (Report mode). Windows' HID class driver issues this automatically; **not** the missing piece. |
| 2 | **Userspace** (`enqueueUserSpaceHIDDataForDevice`, `bluetoothd`) | `0x05` Set Report | 3 bytes | Wire: `53 4A 03` = SET_REPORT Feature, **RID `0x4A` (undocumented)**, value `0x03`. Apple-specific. **This is the step Windows can't replicate via `HidD_*`.** |
| 3 | (60 s later, kernel) | `0x04` Get Report | 2 bytes | Wire: `43 47` = GET_REPORT **Feature**, RID `0x47`. Response `A3 47 ??` where `??` is battery percent. |

The split between kernel and userspace originators matters: it tells us
exactly which step is Apple's vendor logic (step 2) versus standard HID
behaviour the Windows HID stack already replicates (step 1).

## Note on un-redaction

Running `sudo log config --mode 'private_data:on'` before the capture
**partially** un-redacts: BD addresses and string fields that were `<private>`
become visible, but raw HID payload arrays are still suppressed. macOS marks
byte arrays under a separate redaction class that this toggle does not affect.

To obtain the **exact wire bytes** for the SCO Link State Set Report, two
options remain:

1. Install Apple's **Bluetooth Debug Logging Profile** (gated behind Apple
   Developer login, reboot required), then capture HCI in PacketLogger.
2. Pair the keyboard to a Linux box / VM and use `btmon` from BlueZ
   (re-pairing un-pairs the keyboard from the Mac).

Both yield the same data. Recommendation: **defer until the Windows-side
hypothesis-C′ test fails**. The inferred init payload `[0x09, 0x03, 0x00,
0x00]` is constrained tightly enough by the descriptor (RID 0x09 is the
only Feature; report length is 1 data + 2 const padding = 3 bytes) and the
log (`packetDataSize = 3`, "SCO Link State: 3" = `0x03`) that there's
little room for it to be wrong.

## Original finding: macOS sends an init Set Report, then polls Get Report

Reconstructed from the `bluetoothd` log around the reconnect:

| Time (UTC-7) | What happened |
|---|---|
| 00:05:57.242 | "Received outgoing connection attempt for HID Host profile on E8:06:88:4B:07:41" |
| 00:05:57.405 | "Received connection result for HID Host profile … result was 0" |
| 00:05:57.432 | "Received all connection results for device" |
| **00:05:57.436** | **`enqueueUserSpaceHIDDataForDevice … transactionType = 0x05 (Set Report), HID_Host_Handle = 0x7808, packetDataSize = 3`** — userspace `bluetoothd` injects a vendor "SCO Link State" Set Report (sniff-interval coordination) on the **HID Control L2CAP channel** of the new connection. |
| 00:05:57.445 | Keyboard ACKs with `HID Handshake` (transType `0x00`). |
| 00:05:57.464 | Second `HID Handshake` from keyboard. |
| **00:06:57.446** (≈60 s later) | **`enqueueKernelSpaceHIDDataForDevice … transactionType = 0x04 (Get Report), HID_Host_Handle = 0x7808, dataSize = 2`** — the macOS *kernel* (not bluetoothd) sends a 2-byte HID Get Report PDU. The 2 bytes are `[THdr=0x41, RID=0x47]` ("Get Report, type=Input, RID=0x47"). |
| **00:06:57.474** (28 ms later) | **Keyboard responds: `HIDShimIncomingControlData … type 0x0A (HID DATA) and length 2`** — payload `[0x47, battery_byte]`. |
| 00:06:57.474 | Kernel immediately issues another Get Report (same shape) — pattern is "poll, ack, poll." |

Key observations:

1. **macOS does send HID Get Report and the keyboard firmware responds** —
   directly contradicting the Windows-side conclusion that the firmware refuses
   GET_REPORT. The previous Windows tests must have hit a different barrier.
2. The kernel issues the Get Report from `enqueueKernelSpaceHIDDataForDevice`,
   not from `bluetoothd` userspace — i.e. it's the AppleBluetoothHIDKeyboard.kext
   driving it, not an app.
3. The first Get Report fires **\~60 seconds after HID Host connect**, suggesting
   a periodic poll cadence (60 s would be the steady-state battery refresh on
   macOS — consistent with Apple's Bluetooth menulet showing battery without
   manual refresh). Not a single connect-time push as the Windows code assumes.
4. **A vendor Set Report (transType 0x05, 3-byte payload) is sent immediately
   after HID Host profile connect**, on the same L2CAP handle that later carries
   the Get Report. The bluetoothd subsystem labels this
   `setSniffIntervalForOneSniffAttemptAppleHID … SCO Link State: 3`. This
   maps to **RID `0x09` Feature** (the only Feature RID in the descriptor),
   payload byte = `0x03`, padded to 3 bytes.

## Two-tier architecture observed

The `bluetoothd` log shows a clear two-layer split between **how often macOS
*reports* battery to apps** and **how often it actually *asks the device*** over
the air:

| Layer | Cadence (observed) | What it does | Crosses BT? |
|---|---|---|---|
| App / menu-bar UI | every **2–3 s** | Calls `IOBluetoothDevice batteryPercent` → bluetoothd `getBatteryLevel` → reads bluetoothd's in-memory cache | No |
| `bluetoothd` cache | served on demand | Returns the last cached value (`status 0x0` if fresh, `status 0x1` if invalid) | No |
| Kernel HID driver | every **~60 s** | Issues HID `Get Report` over L2CAP to refresh the cache | **Yes** |

Evidence in [docs/kbd-mac-logstream.txt](kbd-mac-logstream.txt):

- Bursts of `getBatteryLevel - battery fetch beginning` lines from multiple
  bluetoothd worker threads (`22a354`, `22a356`, `229a58`, `2238de`) every
  2–3 seconds whether the keyboard is connected or not. All cached reads;
  none touch the wire.
- Exactly **one** `enqueueKernelSpaceHIDDataForDevice transactionType = 0x04
  (Get Report)` 60 seconds after the HID Host profile finishes connecting.
  This is the only event that produced a wire round-trip in our window.

**Caveat:** with only one wire poll observed, we cannot distinguish whether the
kernel polls **autonomously every 60 s** or only **lazily on cache expiry when
userspace asks**. Both produce the same observed cadence under the constant
userspace polling that's always happening on macOS. A 5-minute capture (see
"Open questions" below) would resolve it.

## Hypotheses for why GET_REPORT failed on Windows

**C′ (most likely): firmware requires the SCO Link State Set Feature as a prerequisite.**
macOS sends Set Feature RID `0x09` `[0x03, 0x00, 0x00]` immediately on connect.
Windows opens col02/col03 and goes straight to `HidD_GetInputReport` —
keyboard silently drops the request, Windows times out and surfaces err=87.
Easy to test: send the Set Feature first on col03, then call
`HidD_GetInputReport(0x47)` on col02.

**C″: Windows HID stack rewrites the GET_REPORT PDU encoding** in a way the
firmware rejects, while macOS sends the raw `[0x41, 0x47]` directly via the
kernel BT stack. Would need a raw L2CAP socket on PSM `0x11` to confirm —
much heavier; defer until C′ is ruled out.

**A/B (now eliminated):** the previous "macOS just receives the connect-time
push and caches it" story does not hold up. The capture proves macOS actively
polls.

## ~~Implications for the Windows implementation~~ (SUPERSEDED)

> **This section is wrong.** It was based on the inferred RID `0x09` from
> redacted logs. The HCI capture proved the actual init RID is `0x4A`, which
> is **not in the descriptor** — `HidD_SetFeature` will reject it before
> sending. See "Byte-exact findings → What this means for Windows" below
> for the correct guidance (raw L2CAP via `BTHPROTO_L2CAP`).

## Open questions a longer Mac capture could answer

Worth running if hypothesis C′ doesn't pan out on Windows, or before committing
to a 60 s constant:

1. **Is the 60 s wire poll autonomous or lazy?** Capture for 5 minutes with the
   keyboard connected. If we see exactly 5 Get Reports at 60 s intervals
   regardless of userspace activity → autonomous timer. If the cadence varies
   with userspace polling load → lazy refresh on cache expiry.
2. **Is the SCO Link State Set Report sent on every connect, or only the first
   one in a session?** Disconnect/reconnect 3–4 times in the capture window
   and check whether the `transactionType = 0x05, packetDataSize = 3` line
   appears every time.
3. **Does the keyboard ever push battery without being polled** (e.g., on a
   significant level change)? Watch for `HIDShimIncomingControlData type 0x0A
   (HID DATA), length 2` lines that are NOT preceded by an outbound
   `transactionType = 0x04`. If yes, Windows could keep a `ReadFile` open as
   a backup channel.
4. **Actual byte payload of the request and response.** The current trace
   shows `<private>` for HID data. Resolving this needs either the **Apple
   Bluetooth Debug Logging Profile** (HCI capture in PacketLogger) or a
   Linux box with `btmon`. Only required if C′ fails and we have to debug
   the wire encoding.

## Next step (SUPERSEDED — see Empirical update 2026-05-08 below)

Run [scripts/kbd-setfeature-then-getinput-2026-05-08.ps1](../scripts/kbd-setfeature-then-getinput-2026-05-08.ps1)
on the Windows machine with the keyboard paired and connected.

## Empirical update — 2026-05-08

Three rounds of probe iteration (PR #36 SO_RCVTIMEO, PR #37 dual-error
capture, third run with `BluetoothSetServiceState(DISABLE)` + raw L2CAP)
all produced the same result:

```
connect() returned: -1  (WSAGetLastError=0  Marshal.GetLastWin32Error=0)
```

Both Win32 error sources read 0 immediately after the failure — the
kernel BT stack rejects the connect at a layer below Winsock's
error-propagation surface, even with the HID profile administratively
disabled. Userland `AF_BTH/BTHPROTO_L2CAP` to PSM `0x11` is **not a
supported Windows path** while the device is paired as a HID device.

But then a much smaller test changed the picture entirely. Calling
`HidD_GetFeature(Col03, RID=0x09, len=4)` from userland **SUCCEEDED**
with real bytes `[92 12 02 02]`:

```
[Col03 / RID 0x09 / declared Feature 4 bytes]
  HidD_GetFeature(rid=0x09, len=4)...
  *** SUCCESS *** bytes: [92 12 02 02]

[Col02 / RID 0x47 / declared Input only / control test]
  HidD_GetFeature(rid=0x47, len=2)...
  FAILED (ok=False err=1) -- ERROR_INVALID_FUNCTION
```

This proves **Windows BT HID can issue Feature `GET_REPORT`s to this
firmware over L2CAP without any userland L2CAP work, without a Set
Feature init, and without driver replacement.** The keyboard responds
on the first try.

The only blocker for `HidD_GetFeature(Col02, RID=0x47)` is `hidclass.sys`
descriptor validation: RID `0x47` is declared as Input only (`81 02`)
in Apple's public descriptor, so the userland call is rejected before
the bytes ever reach the L2CAP wire.

### Implication: a 4-byte descriptor patch is the entire fix

Insert `09 20 B1 02` immediately before the `c0 c0` closing Col02:

```
Original Col02 (31 bytes): ... 75 08 95 01 81 02         c0 c0
Patched  Col02 (35 bytes): ... 75 08 95 01 81 02 09 20 B1 02 c0 c0
                                                  ^^^^^^^^^^^
                                                  re-emit Usage(Battery Strength)
                                                  + Feature main item
```

Global items (Report Size 8, Count 1, Logical Min 0, Logical Max 255)
carry across main items per HID 1.11 §6.2.2.7, so only the Usage (a
local item) needs re-emitting. After the patch, `hidclass.sys` parses
RID `0x47` as both Input and Feature; `HidD_GetFeature(0x47)` succeeds;
kernel sends `43 47`; firmware responds `A3 47 NN`; userland gets the
battery byte.

### Why a kernel filter is still required

Patching the descriptor from user-mode is impossible because
`hidclass.sys` parses the descriptor once at attach time and caches the
result. The patch must happen on the IRP path:

- Lower filter on `BTHENUM\{...}_VID&05AC_PID&{Apple kb whitelist}`
- Intercept `IOCTL_HID_GET_REPORT_DESCRIPTOR`
- In the completion routine, locate Col02's tail by scanning for the
  `85 47 ... 81 02 c0 c0` pattern
- Insert the 4 patch bytes; update `Information` to the new size
- Forward up the stack

This is the entire driver. ~150-250 lines of KMDF C. No init injection,
no L2CAP relay, no descriptor replacement, no `bcdedit /set testsigning on`
at runtime — production-signed via the existing M12 `CN=MagicMouseFix`
cert in TrustedPublisher.

Scaffold: [`driver-keyboard/`](../driver-keyboard/) (this PR).

## Byte-exact findings (HCI capture, 2026-05-08 second pass)

Capture file: `/Users/lesley/Documents/BT_Keyboard_Trace.pklg` (PacketLogger,
Apple BT Debug Profile installed). Decoded with `tshark` reading the `.pklg`
directly. All traffic on **L2CAP HID Control** (PSM 0x11, dynamic CIDs
0x0058 host→device, 0x0b08 device→host).

### Connect-time init (t=570.467s → 570.495s)

| Frame | Direction | L2CAP payload | Decoded |
|---|---|---|---|
| 4426 | host→kbd | `71` | SET_PROTOCOL, Protocol=Report (1 byte total — Wireshark labels this "Boot" but the bit value 1 means Report Protocol per BT HID 1.1 §7.4.6) |
| 4429 | kbd→host | `00` | HANDSHAKE, Successful |
| **4430** | **host→kbd** | **`53 4A 03`** | **SET_REPORT Feature, RID `0x4A`, value `0x03`** |
| 4432 | kbd→host | `00` | HANDSHAKE, Successful |
| 4435–4439 | host→kbd | (5×) DATA Output Keyboard LEDs | Standard HID LED state push |

**Critical:** RID `0x4A` is **not present in the public HID descriptor**.
Apple's `bluetoothd` injects it directly via raw L2CAP. The firmware accepts
the Feature SET_REPORT for this undocumented RID; the descriptor
advertises only `0x09` as a Feature.

### Steady-state battery poll (t=630.485s → 631.408s, ~60 s after connect)

| Frame | Direction | L2CAP payload | Decoded |
|---|---|---|---|
| **8022** | **host→kbd** | **`43 47`** | **GET_REPORT, type=Feature, RID `0x47`** |
| **8026** | **kbd→host** | **`A3 47 64`** | **DATA Feature, RID `0x47`, value `0x64` = 100 = battery percent** |
| 8027 | host→kbd | `41 30` | GET_REPORT, type=Input, RID `0x30` (PacketLogger label: `BATTERY LEVEL WARNING`) |
| 8030 | kbd→host | `A1 30 00` | DATA Input, RID `0x30`, value `0x00` (PacketLogger label: `BATTERY STATUS OK`; non-zero presumably indicates a low-battery warning) |

**Critical:** RID `0x47` is declared in the descriptor as **Input only**, yet
the keyboard responds to a Feature GET_REPORT for it just fine — so the
descriptor under-reports the device's capabilities. RID `0x30` is also
absent from the descriptor.

### What this means for Windows

Windows' `HidD_GetFeature` / `HidD_SetFeature` / `HidD_GetInputReport`
validate the requested RID against the parsed report descriptor before
issuing the L2CAP transaction:

- `HidD_GetFeature(col02, [0x47, …])` fails because col02's
  `FeatureReportByteLength = 0` (RID 0x47 is declared Input there).
- `HidD_SetFeature(col03, [0x4A, …])` would fail because RID `0x4A` is
  not in any collection's descriptor at all.
- This explains the "all 255 RIDs return err=87" observation in
  [KeyboardBatteryDevice.cs:11-13](../MagicMouseTray/KeyboardBatteryDevice.cs):
  the firmware *would* respond, but Windows refuses to send the bytes.

The real fix is **raw L2CAP on PSM 0x11**, bypassing the HID class:

1. `socket(AF_BTH, SOCK_STREAM, BTHPROTO_L2CAP)`
2. Connect to keyboard BD addr, PSM `0x11`
3. Send `53 4A 03` once on connect → wait for handshake `00`
4. Every 60 s, send `43 47` → read response `A3 47 ??`; last byte is battery %

Windows complication: by default the in-box HID Profile owns the HID L2CAP
channels for a paired HID device, and a second userland L2CAP connection
on PSM 0x11 is rejected. Two known workarounds:

- **Disable the in-box HID profile for the device** before opening the
  L2CAP socket (registry / `BluetoothSetServiceState`). Re-enable when
  done. Will likely cause a brief HID disconnect.
- **Kernel-mode HID filter driver** that intercepts and forwards traffic on
  the existing channel. Heavier; a real shipping product needs this.

For a probe / proof-of-concept, the first workaround is acceptable.

## Cross-device confirmation: V1 Magic Mouse uses the same battery protocol

Captured `magic-mouse -v1_battery_with_restart.pklg` against the V1 Magic
Mouse (`04:F1:3E:EE:DE:10`, VID `0x05AC` / PID `0x030D`) with the BT Debug
Profile installed. PacketLogger natively decodes the steady-state poll
identically to the keyboard:

| Time (relative) | Direction | Bytes | Decoded |
|---|---|---|---|
| 3979.216 | host→mouse | `43 47` | GET_REPORT Feature, RID `0x47` |
| 3980.173 | mouse→host | `A3 47 0F` | DATA Feature — **`BATTERY LEVEL 15%`** |
| 3980.173 | host→mouse | `41 30` | GET_REPORT Input, RID `0x30` |
| 3980.196 | mouse→host | `A1 30 00` | DATA Input — **`BATTERY STATUS OK`** |

So the **steady-state battery query bytes are universal** across the Apple
BT HID family. Same `0x47` Feature and `0x30` Input RIDs respond on both
the keyboard and the mouse.

The connect-time init differs by device:

| Device | Init transactions (host → device) |
|---|---|
| **Keyboard** (PID `0x0239`) | one Set Feature: `53 4A 03` |
| **V1 Magic Mouse** (PID `0x030D`) | sequence of vendor Set Features at gesture/sensitivity RIDs: `53 C6 01 12 01 2C` *(rejected with HANDSHAKE Error: Invalid Report ID)*, then `53 F1 DB`, `53 F8 01 37`, `53 D7 01`. None of those address battery; the firmware happily answers `43 47` without any host-issued init. The first attempt being **rejected by the firmware** also implies the host is doing some auto-discovery rather than reading from a known table. |

**Implication for the Windows port:** the same probe script
([scripts/kbd-l2cap-with-hid-disable-2026-05-08.ps1](../scripts/kbd-l2cap-with-hid-disable-2026-05-08.ps1))
covers both devices. It now accepts `-BdAddr` and `-Device <keyboard|mouse|none>`
parameters; for the mouse, run with `-Device none` (or `-Device mouse` —
currently equivalent — skip the keyboard's `53 4A 03` init).

```powershell
# keyboard (default)
.\kbd-l2cap-with-hid-disable-2026-05-08.ps1

# V1 magic mouse (skip init; battery query is universal)
.\kbd-l2cap-with-hid-disable-2026-05-08.ps1 -BdAddr 04:F1:3E:EE:DE:10 -Device none
```

**Open question:** does the keyboard *actually* require the `53 4A 03`
init for `43 47` to work, or is it incidental (e.g., sniff-interval
coordination)? The mouse capture suggests the firmware doesn't strictly
require any host-issued init — the auto-discovery probe failed and
battery still works. If true, the Windows port can drop the keyboard
init step entirely. Test by running `-BdAddr E8:06:88:4B:07:41 -Device none`
on Windows and seeing whether `43 47` still gets a valid response.

## Reproducibility

To re-derive the macOS findings:

```bash
# in Terminal.app, with Bluetooth permission granted:
brew install blueutil
./scripts/kbd-mac-battery-logstream.sh   # follow the keyboard wake prompt

# the resulting docs/kbd-mac-logstream.txt should contain:
grep "transactionType = 0x04 (Get Report)" docs/kbd-mac-logstream.txt
grep "HIDShimIncomingControlData: Received incoming control data of type 0x0A" \
     docs/kbd-mac-logstream.txt
```

The `setSniffIntervalForOneSniffAttemptAppleHID` log line — and the matching
`Set Report, packetDataSize = 3` enqueue — appears whenever an Apple HID
reconnects.
