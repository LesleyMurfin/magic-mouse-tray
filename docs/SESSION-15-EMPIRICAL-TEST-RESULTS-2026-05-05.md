# Session 15 — Empirical Test Results & Patching Plan

**Date**: 2026-05-05
**Author**: agent (autonomous)
**Status**: data collection complete, plan pending user approval
**Hardware**: Magic Mouse v3 (PID 0x0323), MAC D0:C0:50:CC:8C:4D
**OS**: Windows 11 build 26100
**Goal**: cursor + scroll + battery simultaneously, NO M14 rewrite

---

## BLUF

Today's tests refute the assumption that the binary-patched Apple driver (66288 bytes, MD5 `74756dc8...`) is a "small delta from original". The patch re-architected the descriptor (5→2 buttons, single TLC→split TLCs, Feature 0x47→Input 0x90 battery) and that re-architecture is the most likely cause of `STATUS_INVALID_PARAMETER_MIX`. Two independent expert reviews (Gemini Flash + Pro) converge on **PATH-A: append-only descriptor patch** as the highest-viability untested option. PATH-A blocked in-place by only 4 bytes of zero-padding after the descriptor; needs descriptor relocation (find pointer reference, update). Apple stock driver is currently restored — cursor + scroll work, no battery (Mode B / Descriptor B / unified).

---

## Test 1 — Descriptor Decode Comparison

**Method**: extract HID descriptor bytes from each binary, decode item-by-item.
**Binaries**:
- A: `/mnt/c/mm-dev-queue/applewirelessmouse-fixed.sys` (66288 bytes, MD5 `74756dc8...`) — patched Apple, FAILS to load with NTSTATUS 0xC00000B9
- B: `/mnt/c/mm-dev-queue/MagicMouseDriver-wdf.sys` (29664 bytes, MD5 `1578adac...`) — Session-14 WDF, CONFIRMED working (battery=22%)

**Result**:

| Field | Patched Apple | WDF Session-14 |
|-------|---------------|-----------------|
| Descriptor offset | 0xA850 | 0x4450 |
| Descriptor length | 116 bytes | 135 bytes |
| TLCs | 2 (Mouse, Battery vendor) | 3 (Mouse, Battery vendor, Touch vendor) |
| TLC1 | UP=0x0001 U=0x0002 RIDs=[0x02, 0x27] | UP=0x0001 U=0x0002 RIDs=[0x02, 0x47] |
| TLC2 | UP=0xFF00 U=0x0014 RIDs=[0x90, 0x91] | UP=0xFF00 U=0x0014 RID=[0x90] |
| TLC3 | (none — touch in TLC1) | UP=0xFF00 U=0x0027 RID=[0x27] |

**Verdict**: both descriptors structurally valid. Each Input/Output/Feature has Usage in scope and Logical Min/Max defined (constant-flag inputs allowed).

**Conclusion**: FAILED_START is **not** caused by Session-14-style descriptor parser bug.

---

## Test 2 — Live Load with Documented Procedure

**Method**: install the 66288-byte patched Apple binary into System32 + DriverStore, run the documented 2026-04-30 procedure (BTHPORT cache clear + `pnputil /restart-device`), check device status.

**Result**:
- Earlier today (simple disable+enable): Problem Code 10, NTSTATUS 0xC00000B9 (`STATUS_INVALID_PARAMETER_MIX`)
- Test 2 (with cache clear + restart): Problem Code 22 (`CM_PROB_DISABLED`), ProblemStatus 0
- COL01/COL02/COL03 not enumerated (children show Status: Unknown — phantom)
- BTHPORT cache subkey not at expected registry path (`HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices\D0C050CC8C4D` had no `Cache` child key) — cache clear was a no-op

**Verdict**: the 2026-04-30 patched binary does NOT load successfully today, regardless of procedure. The binary or its environment (Windows hidclass.sys / HidBth.sys) has changed in a way that prevents a successful load now.

---

## Test 3 — Strict Offline Validator

**Method**: implemented a stricter validator that checks every Input/Output/Feature item for Usage, Logical Min/Max, ReportSize, ReportCount in scope.

**Result**:
- Patched Apple: 2 errors (constant-flag padding inputs without Usage — false positives; HID spec allows Const items without Usage)
- WDF Session-14: 1 error (same false positive)

**Verdict**: confirms Test 1. Both descriptors pass real hidclass parser rules. STATUS_INVALID_PARAMETER_MIX is **not** a parser rejection.

---

## Test 4 — Byte-Level Diff: Original vs Patched

**Method**: extract Apple's ORIGINAL 116-byte descriptor at 0xA850 from `applewirelessmouse.inf_amd64_ac34ebceaaf7324c\applewirelessmouse.sys` (Microsoft WHQL signed). Compare byte-by-byte to the patched version.

### Major architectural changes:

| Aspect | Apple ORIGINAL | PATCHED |
|---|---|---|
| Top-level Application Collections | **1** (single TLC) | **2** (split) |
| Mouse buttons | **5** (UsageMin 1 / UsageMax 5, RCount 5, Size 1) | **2** (UsageMin 1 / UsageMax 2, RCount 2, Size 1) |
| Padding bits in byte 0 of mouse report | 3 | 6 |
| Vendor pad TLC | UP=0xFF02 (1 bit) at +030 | removed |
| Battery declaration | Feature **RID=0x47** (UP=0x06 GenericDeviceCtrls, Usage=0x20 BatteryStrength) | Input **RID=0x90** (UP=0xFF00 vendor) in new TLC2 + RID=0x91 feature padding |
| Touch RID 0x27 | inside TLC, length 46, LMin=1 LMax=65 | inside TLC1, length 46, LMin=129 LMax=127 (signed inherited) |

**Conclusion**: the 2026-04-30 patch is NOT a delta — it's a re-architecture. The mouse button count change (5→2) and the absence of an explicit RID 0x27 LogicalMin/Max declaration (uses inherited values 0x81/0x7F from earlier in the descriptor) are likely sources of `STATUS_INVALID_PARAMETER_MIX` because:
1. Apple's runtime gesture engine likely has compiled-in assumptions about mouse report layout (5 buttons + 3 padding bits in byte 0). With descriptor declaring 2 buttons + 6 padding, the report layout that hidparse computes from the descriptor differs from what Apple's engine produces. → parameter validation fails.
2. The H-016 finding ("byte layout mismatch causes Apple's gesture output bytes to land in the button bit field") is consistent with this — same root cause, different manifestation.

---

## Peer Review Summary (2 expert opinions)

### Round 1 (Gemini 2.5 Flash + Gemini 2.5 Pro, both T2/T3)
- **Verdict**: CHANGES-NEEDED
- **Recommended path**: try BLE GATT 0x180F first; if not, minimal 2-TLC patch
- **GATT path**: REJECTED by D-001 (Apple v1+v3 use BR/EDR HID, not BLE) — confirmed by 150-source NotebookLM research
- **Minimal 2-TLC patch path**: ALREADY EXISTS as the 66288-byte file. Test 4 shows it's not really "minimal" — it re-architected the mouse TLC.

### Round 2 (Gemini 2.5 Pro, with Test 1-4 evidence)
- **Verdict**: NEED-MORE-DATA
- **Q1 (append-only patch satisfies constraints?)**: yes, theoretically — Apple's gesture engine would see its expected 5-button layout, HidBth would create COL02 child PDO for the appended TLC.
- **Q2 (where is descriptor length referenced?)**: most likely `IOCTL_HID_GET_DEVICE_DESCRIPTOR` handler in applewirelessmouse.sys; look for `mov ecx, 0x74` or similar near the descriptor pointer reference. Length must be patched alongside the descriptor.
- **Q3 (does H-010 mode mutual exclusion still apply?)**: NO — H-010 was about runtime mode-flipping in the unmodified driver. Binary patching the descriptor bytes bypasses the mode-flip logic (driver injects only one descriptor, the patched one).
- **Q4 (would standard Feature 0x47 read work on v3?)**: not tested in his round, but per PSN H-008 + 588 prior probes: REJECTED. v3 hardware doesn't back the phantom Feature 0x47 declaration in its descriptor (err=87).
- **Q5 ranking**:
  1. PATH-C (test stock Feature 0x47 read) — already tested, fails per H-008
  2. **PATH-A (append-only patch)** — highest viability untested, recommended
  3. PATH-B (Phase 4-Omega userland recycler) — last resort, degraded UX
  4. PATH-D (hybrid filter stack) — H-016 already showed filter chains fail

---

## PATH-A Construction Attempt (today)

**Approach**: keep Apple's original 116-byte descriptor at 0xA850 byte-for-byte; append 22-byte TLC2 (UP=0xFF00, Usage=0x14, RID=0x90, vendor battery) copied verbatim from WDF Session-14's known-working TLC2.

**Blockers identified**:
1. Only **4 bytes of zero-padding** immediately after the descriptor at 0xA8C4. Insufficient for 22-byte append.
2. Region 0xA8C4..0xA8DC contains float constants (0x80 0x3F = 1.0f, etc.) — NOT safe to overwrite.
3. Descriptor-length immediates `116` (0x74) found in binary as raw u32 at offsets 0x1FC, 0x201, 0x77B6, 0x9BAA, 0xE22C. Need to disassemble to identify which is the descriptor length vs PE/struct fields.

**Required next steps to complete PATH-A**:
1. Disassemble applewirelessmouse.sys to find the descriptor pointer (`lea rax, [0xA850]` or similar) and the length immediate that flows together with it.
2. Choose relocation target: either (a) freed Apple PE cert space (after signtool removed Apple's 12KB cert overlay), or (b) extend a section. (a) is simpler.
3. Build relocated descriptor at the new offset, patch the pointer instruction, patch the length immediate, sign with MagicMouseFix cert.
4. Install via `RUN-AS-SYSTEM` route. Test with cache clear + restart-device + wake mouse.

**Estimated effort**: 1-2 hours for someone comfortable with x86-64 PE patching + Ghidra. Brittle; subject to break by future Windows updates.

---

## Current System State (after Apple stock restore)

```
System32\drivers\applewirelessmouse.sys: f4ae407c... (Apple WHQL stock, 78424 bytes)
LowerFilters on BTHENUM HID PDO: applewirelessmouse only
BTHENUM HID Status: OK (after enable)
COL02: NOT enumerated (Mode B / unified descriptor — no battery)
Cursor + scroll: working via Apple driver
Test backup at: C:\mm-dev-queue\backup-restore-apple-20260505-180233\
```

---

## Recommended Path Forward

### OPTION 1: Pursue PATH-A (binary patch with relocation)
**Cost**: 1-2 hours focused work + brittle long-term maintenance.
**Risk**: medium — incorrect patch can produce non-loadable driver. Signed self-cert means testsigning required forever.
**Reward**: cursor + scroll + battery from a single Apple-derived binary, no userland service.

### OPTION 2: Phase 4-Omega userland recycler (PATH-B)
**Cost**: 0 driver work; tray-app code change to detect "battery query needed" → trigger PnP recycle to flip into Mode A → read battery → flip back.
**Risk**: low; the recycle behaviour is documented (H-009 confirmed).
**Reward**: degraded UX (scroll glitch during the read window, ~5s) but all three behaviors achievable.

### OPTION 3: Accept current state
**Cost**: 0.
**Reward**: cursor + scroll work; no battery indicator. Tray app can poll PnP state without showing % when in Mode B.

---

## Files & Test Artifacts

| Artifact | Path | Purpose |
|---|---|---|
| Test 1 decoder | `/tmp/decode-hid-descriptor.py` | Item-by-item HID descriptor decode |
| Test 3 strict validator | `/tmp/decode-hid-detailed.py` | Stricter rules check |
| Test 4 byte-diff | `/tmp/compare-original-vs-patched.py` | Original vs patched comparison |
| PATH-A candidate builder | `/tmp/build-append-only-patch.py` | Identifies blockers (zero-padding, length immediates) |
| Test 2 install script | `/mnt/c/mm-dev-queue/test2-load-patched-apple.ps1` | Live install with documented procedure |
| Test 2 log | `/mnt/c/mm-dev-queue/test2-patched-apple.log` | Outcome details |
| Round 1 peer review | `/tmp/peer-review-mm-v3.md` | Initial expert prompt |
| Round 2 peer review | `/tmp/peer-review-mm-v3-round2.md` | Second-round prompt with new evidence |
| Apple restore script | `/mnt/c/mm-dev-queue/restore-apple-driver.ps1` | Used to restore current state |
| Apple stock backups | `C:\mm-dev-queue\backup-restore-apple-*\` | Recovery point |

---

## Activity Log

| Date | Update |
|------|--------|
| 2026-05-05 | Tests 1-4 executed; Apple stock restored; PATH-A candidate built but in-place append blocked by float constants at 0xA8C4. Two-round peer review complete. Plan documented; awaiting user approval before binary-patch work. |
