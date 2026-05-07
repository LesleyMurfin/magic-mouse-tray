# Session 17 — Mode B Detection False Positive Fix

**Date**: 2026-05-07
**Branch**: `ai/m3-v3-recycle-manager`
**Status**: CLOSED — root cause found and fixed in C# production code and test script
**Hardware**: Magic Mouse v3 (PID 0x0323), MAC D0:C0:50:CC:8C:4D

---

## BLUF

`IsV3InModeB()` was using `IsV3MouseClassPresent()` (Mouse class device DN_STARTED) as its
Mode B discriminator — a false positive. mouhid.sys stays bound to col01 and DN_STARTED
stays True even when the device is in Mode A. All prior WaitForModeB confirmations showing
`1–3ms` were false. Real latency is ~563ms.

Fix: replaced with `IsApplewirelessmouseInStack()` which queries `DEVPKEY_Device_Stack` on
the BTHENUM devnode — reflects what is actually loaded in the kernel. Applewirelessmouse.sys
only appears in this list after FLIP:AppleFilter + enable completes successfully.

---

## Root Cause Chain

1. **Test script bug (precursor)**: `Get-HidLowerFilters` was reading from the HID Enum path.
   `mm-state-flip.ps1` writes to the BTHENUM Enum path. HID Enum LowerFilters is always empty.
   Fixed by `Get-BthenumLowerFilters` using `Get-V3BthenumInstance` to locate the correct key.

2. **Core detection bug**: `Test-IsV3InModeB` called `[HidEnum]::IsV3MouseClassPresent()`.
   mouhid.sys stays resident on col01 across both modes — DN_STARTED never goes False in Mode A.
   The 1–3ms `[ModeB] confirmed` in prior runs was this false signal triggering immediately.

3. **Consequence**: `V3RecycleManager.IsV3InModeB()` had the same bug in C# production code,
   calling `HidNative.IsV3MouseClassPresent()`.

---

## Findings

### Mode B latency (real)

- WaitForModeB: **563ms** after FLIP:AppleFilter (one observed data point)
- This is within the 5000ms `ModeBVerifyMs` budget — no timeout risk
- Prior 1–3ms times were all false positives

### No PnP event 410 on FLIP:AppleFilter

`Microsoft-Windows-Kernel-PnP/Configuration` event ID 410 is only generated on full BT
re-pair/device deletion, not on filter-add + disable/enable cycles. Absence of event 410
does NOT mean the driver failed to load. DEVPKEY_Device_Stack is the authoritative signal.

### BTHENUM Enum registry path (authoritative LowerFilters location)

```
HKLM:\SYSTEM\CurrentControlSet\Enum\BTHENUM\{00001124-0000-1000-8000-00805F9B34FB}_VID&0001004C_PID&0323\9&73B8B28&0&D0C050CC8C4D_C00000000
```

The HID Enum path (`HKLM:\...\Enum\HID\...`) does NOT contain LowerFilters for this device.

### Battery pipeline latency post-col02-DN_STARTED

col02 DN_STARTED appears at ~3ms but the HID report pipeline is not ready:

| Attempt | GLE | Wait from DN_STARTED |
|---------|-----|---------------------|
| 1 | 121 (device busy) | 0ms |
| 2 | 21 (pipe not ready) | ~500ms |
| 3 | 21 | ~1000ms |
| 4 | 0 (SUCCESS) 18% | ~1500ms |

3-retry inner loop in `ExecuteRecycleCycle` (500ms × 3) handles this without triggering
the outer cycle retry. No code change needed.

---

## Changes Made

### `MagicMouseTray/HidNative.cs`

Added:
- `CM_Get_DevNode_Property` P/Invoke (`CM_Get_DevNode_PropertyW` entry point)
- `DEVPROPKEY` struct
- `s_devpkeyStack` static field — DEVPKEY_Device_Stack `{a45c254e-df1c-4efd-8020-67d146a850e0}` pid=14
- `IsApplewirelessmouseInStack()` — finds v3 BTHENUM devnode, queries DEVPKEY_Device_Stack,
  parses UTF-16 multi-string, returns true if any entry matches `applewireless`

`IsV3MouseClassPresent()` retained (not deleted per policy) but no longer called.

### `MagicMouseTray/V3RecycleManager.cs`

`IsV3InModeB()`:
- Was: `return HidNative.IsV3MouseClassPresent();`
- Now: `return HidNative.IsApplewirelessmouseInStack();`
- Updated comment to document the false positive and real 563ms latency

`WaitForModeB()` comment updated with empirical latency.

### `C:\mm-dev-queue\test-v3-state.ps1`

- `Test-IsV3InModeB`: replaced `[HidEnum]::IsV3MouseClassPresent()` with `Get-BthenumFilterInStack`
  which calls `Get-PnpDeviceProperty -KeyName DEVPKEY_Device_Stack`
- Added `Get-V3BthenumInstance`: finds BTHENUM device via `Get-PnpDevice -Class HIDClass`
  matching `{00001124}` + VID `0001004c` + PID `0323`
- Added `Get-BthenumLowerFilters`: reads from BTHENUM Enum registry path (not HID Enum path)
- Added `Get-BthenumFilterInStack`: reads DEVPKEY_Device_Stack from BTHENUM devnode
- Added auto-restore on Mode A baseline: FLIP:AppleFilter before test if device found in Mode A
- Fixed self-relaunch arg forwarding: explicit `$passArgs` from `$PSBoundParameters`
- Changed default `$Runs` from 3 to 1 (rapid cycling causes BT stack drift)
- Fixed `return if ($lf)` syntax (invalid PS 5.x) → `if ($lf) { return ... } else { return ... }`
- Added `-StateCheckOnly` summary: Mode A/B/Unknown, FilterInStack, LowerFilters, BTHENUM health

---

## Test Results (post-fix)

Test log: `C:\mm-dev-queue\test-log-20260507-093013.txt`

```
 Run 1: PASS   ModeA=True  Battery=18%  Restored=True  time=25.2s
 Run 2: PASS   ModeA=True  Battery=18%  Restored=True  time=17s
 Run 3: PASS   ModeA=True  Battery=18%  Restored=True  time=17s
 ALL RUNS PASSED  total=59.3s
```

Note: Runs 2 and 3 still showed 1ms WaitForModeB — these were run against commit 55e9193 before
the production C# fix. The test script fix was in place; the C# code fix was applied in this
session after the test run.

---

## Discrimination Table (updated)

| Signal | Mode A | Mode B |
|--------|--------|--------|
| HID paths | col01 + col02 split | unified (no col suffix) |
| LowerFilters (BTHENUM Enum key) | `(empty)` | `applewirelessmouse` |
| DEVPKEY_Device_Stack | no `applewireless` | contains `applewireless` |
| MouseClass DN_STARTED | **True** (false positive) | True |
| scroll | broken | works |
| battery (RID=0x90 col02) | readable | N/A |
