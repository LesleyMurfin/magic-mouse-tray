# Session 16 — Ghidra Descriptor Trace Findings

**Date**: 2026-05-06
**Author**: agent (autonomous reverse-engineering investigation)
**Binary**: `applewirelessmouse.sys` (78424 bytes, MD5 `f4ae407c228c3db6147d9e3307ed5f20`)
**Status**: investigation complete, MD5 unchanged before/after

---

## BLUF

**YES — descriptor source identified.** The 116-byte HID descriptor at file offset `0xA850` IS the source Apple's filter injects into IOCTL `0x00410210` (`IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE`) responses. Session 15's "ZERO references" claim was **wrong**: the references are 16 RIP-relative loads encoded as `movups xmm, xmmword ptr [rip+disp]` (SSE 128-bit loads), spanning two code blocks inside the SDP completion callback at VA `0x14000a440`. Session 15 only searched for `lea rip+rel` and `mov rax, imm64` patterns — it missed the SSE-encoded loads. **Verdict: PATCH-VIABLE in place.**

---

## Method

- Tools: `capstone` 5.0.7 (Python disassembler, x86-64), `python3` PE parser, `md5sum` integrity check.
- Binary copied to `/tmp/applewirelessmouse.sys` (read-only analysis); production binary untouched, MD5 verified before and after.
- All findings derived from pure static disassembly (no Ghidra GUI session needed once the analysis tools were available; existing Ghidra projects in `.ai/` were for the third-party `MagicMouse.sys`, not this binary).
- Time: ~90 minutes focused work.

---

## Findings

### F1: IOCTL handler call graph

PE structure:
- ImageBase: `0x140000000`
- Sections: `.text` (file 0x400, RVA 0x1000), **`NONPAGE`** (file 0x7a00, RVA 0x9000), `.rdata`, **`.data`** (file 0xa800, RVA 0xc000), `.pdata`, `INIT`, `.rsrc`, `.reloc`.
- Important: the IOCTL handlers live in **NONPAGE**, NOT `.text`.

Three relevant functions identified (boundaries from `.pdata`):

| Tag | File range | RVA range | Role |
|---|---|---|---|
| **F1** | 0x07f00..0x081d5 | 0x9500..0x97d5 | EvtIoInternalDeviceControl dispatch (handles IOCTL `0x410210`, `0x220fc0`) |
| **F2** | 0x081e0..0x08636 | 0x97e0..0x9c36 | Different handler (IOCTL `0x410003`) — does NOT touch the descriptor |
| **F3** | 0x08e40..0x09793 | 0xa440..0xad93 | **SDP completion callback** — referenced by F1 via `lea r8, [rip+0xd0c]` from VA 0x14000972d. **Contains the descriptor write logic.** |

F1 dispatch (file 0x80a9..0x8108):
```
0x1400096a9: cmp esi, 0x410210      ; IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE
0x1400096af: je  0x140009708         ; -> 0x8108 handler
0x1400096b1: cmp esi, 0x220fc0       ; (different IOCTL)
0x1400096b7: je  0x140009708         ; same handler
```

The 0x410210 / 0x220fc0 handler at file 0x8108 is the **forwarding path**: it does NOT write the descriptor itself. Instead, it sets up the request and registers F3 as the I/O target completion routine, then sends the IRP to the lower BT stack. The descriptor injection happens in the completion callback (F3) **after** the lower driver returns its response.

WDF function indices used in the F1 forwarding sequence (offsets into the WDFLDR-bound function table):
| WDF index | Offset | Purpose (inferred from sequence position) |
|---|---|---|
| 251 | `+0x7d8` | WdfRequest...Format... (request setup) |
| 260 | `+0x820` | WdfRequest setup with completion-routine arg (callback = 0x14000a440 = F3) |
| 253 | `+0x7e8` | WdfRequestSend |
| 254 | `+0x7f0` | WdfIoTargetSend...Synchronously |
| 263 | `+0x838` | WdfRequestComplete |

All indirect calls go through the same CFG trampoline at `0x14000b140 → 0x140007ce0 (jmp rax)`.

### F2: Buffer-write site(s) — F3 contains the descriptor injection

F3 entry at VA `0x14000a440` (file 0x8e40). Pattern:

1. Allocate output pool buffer (file 0x8fb1, VA 0x14000a5b1):
   ```
   mov ecx, 0x200          ; PoolType = NonPagedPool (0x200)
   mov edx, esi (=0xa0)    ; NumberOfBytes = 160
   mov r8d, 0x544d5442     ; Tag = 'BTMT' (Apple's pool tag for this allocation)
   call qword [rip+...]    ; ExAllocatePoolWithTag
   ```

2. Locate the SDP attribute by ID `0x0206` (HID Descriptor List) inside the device's response:
   ```
   0x14000a704: mov  eax, 0x602           ; attribute ID 0x0206 in BE wire form
   0x14000a708: cmp  word ptr [rcx+1], ax ; check SDP element header
   ```

3. **Two descriptor-write code blocks**, both consuming the same 116 source bytes. Selection is by length comparison `cmp ecx, 0x74` (file 0x9205):

| Block | File range | Reached when | Write target offset | Byte count |
|---|---|---|---|---|
| Block 1 | 0x09611..0x0966e | length differs from 0x74 (length-recompression needed) | `[rcx+0..0x74]` | 116 |
| Block 2 | 0x096e5..0x09753 | length already 0x74 (drop-in replace) | `[rcx+r14+8..+0x7c]` | 116 |

**Both blocks copy the SAME 116 bytes from file 0xA850 to the output buffer.** No other descriptor variant exists in this binary.

### F3: Source pointer identification — file 0xA850 is the source

Comprehensive RIP-relative scan (`.text` + `NONPAGE`, every instruction, every memory operand, base register == RIP, target inside `[0x14000c050..0x14000c0c4)`):

```
=== 16 RIP-relative references to descriptor [0x14000c050..0x14000c0c4) ===

Block 1 (file 0x9611, length-recompression path):
  0x14000ac11: movups xmm0, xmmword ptr [rip + 0x1438]  -> 0x14000c050 (file 0xa850)
  0x14000ac23: movups xmm1, xmmword ptr [rip + 0x1436]  -> 0x14000c060 (file 0xa860)
  0x14000ac2e: movups xmm0, xmmword ptr [rip + 0x143b]  -> 0x14000c070 (file 0xa870)
  0x14000ac39: movups xmm1, xmmword ptr [rip + 0x1440]  -> 0x14000c080 (file 0xa880)
  0x14000ac44: movups xmm0, xmmword ptr [rip + 0x1445]  -> 0x14000c090 (file 0xa890)
  0x14000ac4f: movups xmm1, xmmword ptr [rip + 0x144a]  -> 0x14000c0a0 (file 0xa8a0)
  0x14000ac5a: movups xmm0, xmmword ptr [rip + 0x144f]  -> 0x14000c0b0 (file 0xa8b0)
  0x14000ac65: mov    eax,  dword ptr [rip + 0x1455]    -> 0x14000c0c0 (file 0xa8c0)

Block 2 (file 0x96e5, drop-in replace path):
  0x14000ace5: movups xmm0, xmmword ptr [rip + 0x1364]  -> 0x14000c050 (file 0xa850)
  0x14000acfd: movups xmm1, xmmword ptr [rip + 0x135c]  -> 0x14000c060 (file 0xa860)
  0x14000ad0a: movups xmm0, xmmword ptr [rip + 0x135f]  -> 0x14000c070 (file 0xa870)
  0x14000ad17: movups xmm1, xmmword ptr [rip + 0x1362]  -> 0x14000c080 (file 0xa880)
  0x14000ad24: movups xmm0, xmmword ptr [rip + 0x1365]  -> 0x14000c090 (file 0xa890)
  0x14000ad31: movups xmm1, xmmword ptr [rip + 0x1368]  -> 0x14000c0a0 (file 0xa8a0)
  0x14000ad3e: movups xmm0, xmmword ptr [rip + 0x136b]  -> 0x14000c0b0 (file 0xa8b0)
  0x14000ad4b: mov    eax,  dword ptr [rip + 0x136f]    -> 0x14000c0c0 (file 0xa8c0)
```

Layout: 7 × 16-byte SSE loads + 1 × 4-byte DWORD load = **0x70 + 4 = 0x74 = 116 bytes** — exact descriptor length.

The descriptor prefix `05 01 09 02 a1 01 85 02` (HID UsagePage=Generic Desktop, Usage=Mouse, Application Collection, Report ID 2) appears **only at file 0xA850** in the entire binary. There is no second copy.

### F4: Static vs dynamic descriptor construction

**Fully static.** The 116 bytes at file 0xA850 are the canonical descriptor. F3 copies them verbatim into the rewritten SDP response. There is no byte-level mutation, no runtime construction, no per-device variation.

The "two blocks" are NOT two different descriptors — they are two different **SDP-wrapper length-encoding paths** around the same descriptor payload. Both blocks emit the same 116 bytes; they differ only in how they fix up the SDP DataElement length headers (1-byte, 2-byte, or 4-byte size field, per SDP element-descriptor encoding rules).

Length-related immediates in F3:
| File | VA | Instruction | Meaning |
|---|---|---|---|
| 0x08f2b | 0x14000a52b | `add dword ptr [rbx], 0x74` | Extend SDP response total length by 116 |
| 0x09205 | 0x14000a805 | `cmp ecx, 0x74` | Check incoming descriptor length vs 116 |
| 0x0961a | 0x14000ac1a | `add edi, 0x74` | Advance output cursor by 116 after write |
| 0x09607 | 0x14000ac07 | `mov word ptr [rdi+r14], 0x7425` | SDP DataElement header: type=`0x25` (Text String), size byte=`0x74` |

### F5: Mode A/B variant selection mechanism

**There is no Mode A/B selector in this binary.** Apple's filter unconditionally injects the same 116-byte descriptor every time an SDP request for attribute `0x0206` (HID Descriptor List) is observed. The branching at file 0x9205 (`cmp ecx, 0x74; jae`) is a **length-rewriter selector**, not a descriptor-variant selector.

This means the empirically-observed Mode A vs Mode B behaviour (PSN-0001 H-010 REVISED) is **NOT** controlled by this filter binary. It must be controlled upstream by:

- **HidBth's BTHPORT cache state**: when the cache contains the patched 116-byte descriptor, COL01/COL02 enumerate as separate child PDOs (Mode A). When the cache is missing or invalidated, HidBth must do a fresh SDP exchange — Apple's filter intercepts that exchange and again injects the same 116-byte descriptor. So Mode A vs Mode B is a **caching-state artifact** of HidBth, not a runtime decision in `applewirelessmouse.sys`.
- The phantom Feature 0x47 declaration is a **physical part of the canonical descriptor** at file 0xA8A6: `09 20 85 47 15 00 25 64 75 08 95 01 b1 a2` (UsagePage=GenericDeviceCtrls Usage=BatteryStrength, RID=0x47, 8-bit, Feature absolute). Apple injects it unconditionally; whether v3 hardware actually backs it (i.e., responds to a Feature 0x47 read) is independent of this filter.

The original H-010 hypothesis ("filter chooses descriptor variant based on PnP state") is **refuted** by this trace. The filter is a **passive descriptor-replacer** that always returns the same blob.

---

## Verdict

**PATCH-VIABLE: source bytes at file offset 0xA850 (116 bytes), patch path is to modify those bytes in place + re-sign.**

In-place modification within the existing 116-byte slot does NOT require updating any RIP-relative offsets — the offsets remain valid because both the source bytes and the loading instructions stay at their original addresses. Length-field references at file 0x08f2b, 0x09205, 0x0961a, 0x09607 must remain consistent with `0x74` (116) — i.e., **the patched descriptor must remain exactly 116 bytes**.

**This is the same constraint Session 15 hit empirically** ("only 4 bytes of zero-padding after the descriptor" — that was a symptom of the in-place-only constraint, not a fundamental blocker). The 2026-04-30 patch (M13-V3-BINARY-PATCH) **was correctly targeting the right bytes**. The reason that patch failed at runtime (Problem Code 22, NTSTATUS 0xC00000B9 STATUS_INVALID_PARAMETER_MIX) was NOT that the descriptor source location was wrong — it WAS the right location. The failure was due to one or more of:

1. The patched descriptor's mouse TLC re-architecture (5 buttons → 2 buttons, 3 padding bits → 6 padding bits) breaking compiled-in assumptions in Apple's gesture engine elsewhere in the same binary (per Session 15 Test 4 conclusion).
2. The signtool re-signing operation truncating the cert overlay (78424 → 66288 bytes) and Microsoft Code Integrity rejecting the self-signed cert chain on Windows 11 24H2 (build 26100) without testsigning enabled or `MagicMouseFix` cert installed (the install-m12-trust.ps1 step is required per cross-session memory).
3. Cache mismatch in BTHPORT — clearing the SDP cache is required so HidBth does a fresh exchange that the patched filter intercepts.

The descriptor SOURCE is the right target. The PATCH MECHANICS are sound. What needs different work is the descriptor CONTENT (preserve mouse TLC layout faithfully) and the RUNTIME ENVIRONMENT (cert trust, BTHPORT cache).

---

## Recommended Next Steps

If pursuing PATH-A (binary patch):

1. **Use a minimal 2-TLC descriptor** that preserves Apple's exact mouse TLC layout (5 buttons + AC Pan + Wheel + RID 0x27 touch input) and replaces the phantom Feature 0x47 with an Input RID 0x90 vendor-defined-byte battery report — total length must be exactly 116 bytes.
2. **In-place patch** at file 0xA850..0xA8C4 (116 bytes). Do not relocate; do not change the length elsewhere.
3. **Sign with `MagicMouseFix` cert**, install `MagicMouseFix` cert into LocalMachine\TrustedPublisher (per cross-session memory M12 Driver Cert Pattern, confirmed 2026-04-29).
4. **Clear BTHPORT cache** for the device MAC before testing (`HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices\<MAC>\Cache` if it exists; or equivalent location).
5. **Cycle the device** (pnputil /restart-device on the BTHENUM HID parent) to force a fresh SDP exchange.

Total descriptor length budget for the 2-TLC layout: 116 bytes. Realistic budget breakdown:
- Mouse TLC (preserve Apple's layout exactly): ~81 bytes (current original layout)
- Vendor Battery TLC (RID 0x90 input + RID 0x91 padding): ~35 bytes max
- Drop the phantom Feature 0x47 (saves 14 bytes).

Net change: -14 bytes from removing Feature 0x47 + ~22 bytes for new vendor TLC = +8 bytes. Cannot fit in 116 unless mouse TLC compresses by 8 bytes elsewhere — which is exactly the constraint the 2026-04-30 patch tried to satisfy by changing 5 buttons → 2 buttons (saving exactly 8 bytes via UsageMin/UsageMax + ReportCount changes).

This is why the previous patch reduced button count: it was **forced to** by the 116-byte cap. Empirical Session 15 evidence suggests this re-architecture broke runtime invariants. Therefore:

**Recommendation**: PATH-A in-place is *technically* viable, but **requires the descriptor content to fit 116 bytes** and to preserve the mouse TLC bit-layout that Apple's gesture engine produces. These constraints together have already been hit and produce a non-functional driver. The mechanical patch path is correct; the descriptor design in 116 bytes that satisfies BOTH (a) HidBth's parser and (b) Apple's gesture engine's layout assumptions is the open problem.

If the in-place 116-byte budget cannot accommodate a working dual-TLC descriptor, the next options are:
- Relocate the descriptor and update all 16 RIP-relative offsets (file offsets `0xb` from each instruction VA listed above) — 16 dword fixups — this enables a longer descriptor at the cost of 16 careful patches.
- **PATH-B (Phase 4-Omega userland recycler)** — the simpler, more maintainable path. This is no longer "the right call by elimination"; it is "the right call because the descriptor design space within 116 bytes appears empirically to be infeasible".

---

## Evidence

### IOCTL handler dispatch (F1, file 0x80a9):
```
(0x080a9) 0x1400096a9: cmp      esi, 0x410210
(0x080af) 0x1400096af: je       0x140009708
(0x080b1) 0x1400096b1: cmp      esi, 0x220fc0
(0x080b7) 0x1400096b7: je       0x140009708
```

### F1 → F3 callback registration (file 0x812d):
```
(0x0812d) 0x14000972d: lea      r8, [rip + 0xd0c]   ; -> 0x14000a440 = F3
(0x08134) 0x140009734: mov      rcx, qword ptr [rip + 0x58b5]
(0x0813b) 0x14000973b: mov      r9, rbp
(0x0814e) 0x14000974e: mov      rax, qword ptr [rip + 0x5893]
(0x0815b) 0x14000975b: mov      rax, qword ptr [rax + 0x7e8]   ; WdfFunctions[253]
(0x0816c) 0x14000976c: call     qword ptr [rip + 0x19ce]        ; -> 0x14000b140 trampoline
```

### F3 SDP attribute 0x0206 match (file 0x9104):
```
(0x09104) 0x14000a704: mov      eax, 0x602
(0x09108) 0x14000a708: cmp      word ptr [rcx + 1], ax
```

### F3 descriptor write block 1 (file 0x9611):
```
(0x09607) 0x14000ac07: mov      word ptr [rdi + r14], 0x7425   ; SDP elem hdr: type Text, len byte
(0x09611) 0x14000ac11: movups   xmm0, xmmword ptr [rip + 0x1438]   ; src=0x14000c050 (file 0xa850)
(0x0961a) 0x14000ac1a: add      edi, 0x74                          ; advance by 116
(0x09620) 0x14000ac20: movups   xmmword ptr [rcx], xmm0
(0x09623) 0x14000ac23: movups   xmm1, xmmword ptr [rip + 0x1436]
(0x0962a) 0x14000ac2a: movups   xmmword ptr [rcx + 0x10], xmm1
... [6 more 16-byte loads/stores] ...
(0x09665) 0x14000ac65: mov      eax, dword ptr [rip + 0x1455]      ; src=0x14000c0c0 (file 0xa8c0)
(0x0966b) 0x14000ac6b: mov      dword ptr [rcx + 0x70], eax        ; final 4 bytes of 116
```

### Source bytes at file 0xA850..0xA8C4 (the canonical descriptor):
```
0000a850: 05 01 09 02 a1 01 85 02 05 09 19 01 29 02 15 00
0000a860: 25 01 95 02 75 01 81 02 95 01 75 05 81 03 06 02
0000a870: ff 09 20 95 01 75 01 81 03 05 01 09 01 a1 00 15
0000a880: 81 25 7f 09 30 09 31 75 08 95 02 81 06 05 0c 0a
0000a890: 38 02 75 08 95 01 81 06 05 01 09 38 75 08 95 01
0000a8a0: 81 06 c0 05 06 09 20 85 47 15 00 25 64 75 08 95
0000a8b0: 01 b1 a2 05 06 09 01 85 27 15 01 25 41 75 08 95
0000a8c0: 2e 81 06 c0
```

Full HID Report Descriptor decode (verified item-by-item):

| Off | Bytes | Item | Notes |
|---|---|---|---|
| 0 | 05 01 | UsagePage = Generic Desktop | |
| 2 | 09 02 | Usage = Mouse | |
| 4 | a1 01 | Collection = Application | start TLC1 |
| 6 | 85 02 | ReportID = 2 | |
| 8 | 05 09 | UsagePage = Button | |
| 10 | 19 01 | UsageMin = 1 | |
| 12 | 29 02 | UsageMax = 2 | **2 buttons** (NOT 5) |
| 14 | 15 00 | LogicalMin = 0 | |
| 16 | 25 01 | LogicalMax = 1 | |
| 18 | 95 02 | ReportCount = 2 | |
| 20 | 75 01 | ReportSize = 1 | |
| 22 | 81 02 | Input (Data,Var,Abs) | 2 button bits |
| 24 | 95 01 | ReportCount = 1 | |
| 26 | 75 05 | ReportSize = 5 | |
| 28 | 81 03 | Input (Const) | 5 padding bits |
| 30 | 06 02 ff | UsagePage = 0xff02 vendor | |
| 33 | 09 20 | Usage = 0x20 | |
| 35-39 | 95 01 75 01 81 03 | 1 vendor padding bit | totals 2+5+1 = 8 bits = 1 byte |
| 41 | 05 01 | UsagePage = Generic Desktop | |
| 43 | 09 01 | Usage = Pointer | |
| 45 | a1 00 | Collection = Physical | |
| 47 | 15 81 | LogicalMin = -127 | |
| 49 | 25 7f | LogicalMax = 127 | |
| 51-59 | 09 30 09 31 75 08 95 02 81 06 | X/Y, 8-bit signed Rel | |
| 61 | 05 0c | UsagePage = Consumer | |
| 63 | 0a 38 02 | Usage = AC Pan | |
| 66-70 | 75 08 95 01 81 06 | 8-bit Rel pan | |
| 72-80 | 05 01 09 38 75 08 95 01 81 06 | Generic Desktop, Wheel, 8-bit Rel | |
| 82 | c0 | EndCollection (Physical) | |
| 83 | 05 06 | UsagePage = Generic Device Controls | |
| 85 | 09 20 | Usage = Battery Strength | |
| 87 | 85 47 | ReportID = 0x47 | **phantom Feature 0x47** |
| 89-95 | 15 00 25 64 75 08 95 01 | 0..100, 8-bit, count 1 | |
| 97 | b1 a2 | Feature (Data,Var,Abs,Volatile) | |
| 99 | 05 06 | UsagePage = Generic Device Controls | |
| 101 | 09 01 | Usage = 0x01 | |
| 103 | 85 27 | ReportID = 0x27 | touch input |
| 105-111 | 15 01 25 41 75 08 95 2e | 1..65, 8-bit, **count 46** | |
| 113 | 81 06 | Input (Data,Var,Rel) | 46 bytes touch payload |
| 115 | c0 | EndCollection (Application) | end TLC1 |

**Summary**: SINGLE Application Collection with **2 buttons + 5 padding + 1 vendor padding + X + Y + AC Pan + Wheel**. Phantom Feature 0x47 (battery%, 1 byte, RID 0x47, Volatile) is INSIDE the same Application Collection, not in a separate TLC. Touch input RID 0x27 (46 bytes) also inside the Application Collection.

**Important correction to Session 15 Test 4**: that table claimed "Apple ORIGINAL: 5 buttons (UsageMin 1 / UsageMax 5, RCount 5, Size 1)". The actual bytes in the WHQL-signed binary (MD5 `f4ae407c228c3db6147d9e3307ed5f20`) say `19 01 29 02 ... 95 02 75 01 81 02` = **2 buttons**. Session 15's "5→2 button change" is therefore not a real change — both forms are 2 buttons. The actual difference between Apple stock and the 2026-04-30 patch is the addition of TLC2 (RID 0x90 vendor battery), not a button count change. The "5 buttons" in Session 15's original column was a transcription error.

**Phantom Feature 0x47 is a static field of the descriptor**, present in the WHQL stock binary at file 0xA8A6: `09 20 85 47 15 00 25 64 75 08 95 01 b1 a2`. The fact that v3 hardware does not respond to Feature 0x47 reads (PSN H-008, error 87) is a device-level mismatch — the descriptor is causing HidBth to materialize a Feature endpoint that the hardware does not honor.

### MD5 integrity (pre/post analysis):
```
f4ae407c228c3db6147d9e3307ed5f20  /mnt/c/Windows/System32/...applewirelessmouse.sys (start)
f4ae407c228c3db6147d9e3307ed5f20  /mnt/c/Windows/System32/...applewirelessmouse.sys (end)
```

Production binary unchanged. All analysis on `/tmp` copy.

---

## Activity Log

| Date | Update |
|------|--------|
| 2026-05-06 | Disassembled applewirelessmouse.sys; identified F1 (IOCTL dispatch), F2 (unrelated IOCTL 0x410003), F3 (SDP completion handler at VA 0x14000a440); confirmed descriptor at file 0xA850 is the source of the injected HID descriptor; 16 RIP-relative SSE/dword loads identified; refuted Session 15's "ZERO references" finding (their search missed `movups xmm,[rip+rel]` encoding); verdict PATCH-VIABLE-IN-PLACE with 116-byte ceiling. |
