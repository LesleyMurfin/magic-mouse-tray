# M13 Binary Patch: applewirelessmouse.sys — Session 2026-04-29

## TL;DR

Patched `applewirelessmouse.sys` at offset `0xA850` (116-byte embedded HID descriptor) to add
Vendor Battery TLC (RID=0x90) alongside the existing Mouse TLC (RID=0x02). Signed with
MagicMouseFix cert. Staged to `C:\Windows\System32\drivers\applewirelessmouse.sys.new` with
`PendingFileRenameOperations` queued. **Reboot required to apply.**

---

## Reconciliation — 2026-05-06 (Session 16)

The Session 16 Ghidra trace (`docs/SESSION-16-GHIDRA-DESCRIPTOR-TRACE.md`, MD5-verified static
disassembly of WHQL stock `applewirelessmouse.sys` `f4ae407c…ed5f20`) confirms this patch
**targeted the correct bytes**. Verdict from Session 16: **PATCH-VIABLE in place at file `0xA850`,
116-byte ceiling**. This supersedes the same-day Session 15 morning BLUF that briefly listed
PATH-A as "invalidated" on a "zero references" finding (the search missed SSE-encoded
RIP-relative loads — see PSN-0001 H-019 and the Session 15 evening retraction).

What was right:
- File offset `0xA850` IS the canonical source. Apple's filter copies these 116 bytes verbatim
  from two write paths in the SDP-completion callback (F3 at VA `0x14000a440`, file ranges
  `0x9611` and `0x96e5`). Both paths emit the same 116 bytes; differences between them are SDP
  DataElement length-encoding paths, not descriptor variants.
- In-place modification within the existing 116-byte slot does NOT require updating any
  RIP-relative offsets — the 16 `movups xmm, [rip+disp]` + 1 `mov eax, [rip+disp]` references
  remain valid because both source bytes and loading instructions stay at their original
  addresses.

What went wrong (re-attribution of the runtime failure):
- The runtime failure (NTSTATUS `0xC00000B9` `STATUS_INVALID_PARAMETER_MIX`, then Problem Code
  22 in Session 15 retry) was NOT a source-location error. The most likely contributors are:
  1. **Descriptor design infeasibility within 116 bytes**: the patched 2-TLC layout (Mouse TLC1
     ~81 bytes + Vendor Battery TLC2 ~35 bytes) forced compromises (the 5→2 button reduction
     was itself a Session 15 transcription error per the Session 16 correction; the actual
     loss was the vendor 1-bit pad TLC + the phantom Feature 0x47, plus restructure into 2
     TLCs) that broke compiled-in assumptions in Apple's gesture engine in the same binary.
  2. **Cert chain runtime trust**: `signtool` re-sign truncated the cert overlay (78424 → 66288
     bytes); Microsoft Code Integrity rejected the self-signed `MagicMouseFix` cert chain on
     Windows 11 24H2 (build 26100) without testsigning enabled or the cert installed into
     `LocalMachine\TrustedPublisher` (per cross-session memory M12 Driver Cert Pattern).
  3. **BTHPORT cache mismatch**: HidBth's kernel-pool cache is the authoritative descriptor
     source for already-paired devices; clearing it forces a fresh SDP exchange that Apple's
     filter intercepts. If cache is not cleared, the patched filter is bypassed.

**Conclusion**: PATH-A in-place patch mechanics are sound. The descriptor design space within
116 bytes that satisfies BOTH (a) `hidclass.sys` parser rules AND (b) Apple's gesture engine's
compiled layout assumptions is the open problem. PATH-B (M13/M14 KMDF clean-room driver) is the
production path; PATH-A remains formally viable but feasibility-constrained pending the
PATH-A design pass referenced in the recent PRD-PATH-B M0 milestone.

---

## Background

Track 1 (confirmed 2026-04-29): Battery reads at cold boot via Apple stock filter. COL02
(RID=0x90) appears after reboot when BTHPORT cache is populated with Descriptor A. `applewireless
mouse.sys` intercepts IOCTL `0x410210` (SDP attribute 0x0206 — HIDDescriptorList) and injects a
single-TLC Mouse-only descriptor, stripping COL02/battery.

**Goal**: Instead of replacing the Apple driver with M13 KMDF driver, patch the descriptor
embedded in `applewirelessmouse.sys` at offset `0xA850` to include both TLCs.

---

## Descriptor Layout at 0xA850

Original: 116 bytes — Mouse TLC (RID=0x02) + phantom Feature 0x47 + RID=0x27 input.

Patched: 116 bytes (same size, no length field changes needed):
- **TLC1** (81 bytes): Mouse RID=0x02 — 5 buttons + X/Y + AC Pan + Wheel
- **TLC2** (35 bytes): Vendor Battery RID=0x90 (flags + battery%) + dummy Feature RID=0x91 (10-byte padding)

Key offsets within the 116-byte block:
| Offset | Value | Meaning |
|--------|-------|---------|
| +7     | 0x02  | RID for TLC1 (Mouse) |
| +80    | 0xC0  | End Collection (end of TLC1) |
| +81    | 0x06  | Start of TLC2 (UsagePage vendor) |
| +89    | 0x90  | RID for TLC2 (Battery) |

---

## Signing Behavior

Original `applewirelessmouse.sys`: **78424 bytes** (includes Apple's ~12KB PE authenticode cert).

After `signtool sign` with MagicMouseFix cert: **66288 bytes**. Signtool replaces the entire
certificate table. Apple's large cert is removed; our smaller self-signed cert is added. This is
expected — the cert is a PE overlay, not part of any section. The data section containing offset
`0xA850` is unaffected.

Verified: `data[0xA850+7] == 0x02`, `data[0xA850+89] == 0x90` in the signed binary.

---

## Installation Method: PendingFileRenameOperations

The SYS file is locked by the kernel driver while Windows is running. Even disabling the BTHENUM
device does not unload the module from kernel memory. Solution: queue a boot-time rename.

**Staged file**: `C:\Windows\System32\drivers\applewirelessmouse.sys.new`
**Registry entry**: `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations`
```
\??\C:\Windows\System32\drivers\applewirelessmouse.sys.new  →  \??\C:\Windows\System32\drivers\applewirelessmouse.sys
```

SMSS.exe processes this before any drivers load on the next boot.

---

## PATCH-APPLE-SYS Task Runner Route

Added to `mm-task-runner.ps1`:

```
PATCH-APPLE-SYS|<nonce>|<patched-sys-path>
```

1. Finds BTHENUM HID device instance ID (regex `{00001124...}...004c...0323`)
2. Copies patched sys to `applewirelessmouse.sys.new` in System32\drivers
3. Queues `PendingFileRenameOperations` for atomic boot-time replace
4. Returns 0 on success; log at `C:\mm-dev-queue\patch-apple-<nonce>.log`

Also used: existing `SIGN-FILE|<nonce>|<file-path>|<thumbprint>` route (uses `/sm /sha1` against
`LocalMachine\My`).

---

## Current State (2026-04-29)

| Item | State |
|------|-------|
| Backup (original) | `D:\Backups\AppleWirelessMouse-RECOVERY\AppleWirelessMouse.sys` — 78424 bytes |
| Patched + signed | `D:\Backups\AppleWirelessMouse-RECOVERY\AppleWirelessMouse-patched.sys` — 66288 bytes |
| Staged | `C:\Windows\System32\drivers\applewirelessmouse.sys.new` — 66288 bytes ✅ |
| PendingFileRenameOperations | Queued ✅ |
| **Action required** | **Reboot Windows** |

---

## Post-Reboot Verification

After reboot, run `mm-accept-test.sh` (or `mm-accept-test.ps1`). Key checks:

1. `applewirelessmouse.sys` file size = 66288 bytes (confirms rename applied)
2. COL02 device shows as Started in Device Manager
3. `HidD_GetInputReport(0x90)` returns 0-100% battery
4. Scroll (AC Pan + Wheel) working on COL01

---

## Rollback

If the patched driver causes issues:
1. Boot into Safe Mode
2. Replace `C:\Windows\System32\drivers\applewirelessmouse.sys` with
   `D:\Backups\AppleWirelessMouse-RECOVERY\AppleWirelessMouse.sys`
3. Or use the `ROLLBACK-M12` task runner route (reinstalls from Apple INF backup)
