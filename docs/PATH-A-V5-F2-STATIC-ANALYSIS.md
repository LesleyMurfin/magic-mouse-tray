---
title: PATH-A v5 — F2 Static Analysis (E_S1 finding from SRE-Windows v5 review)
type: technical-analysis
date: 2026-05-09
status: complete
linked_review: .ai/peer-reviews/2026-05-09-pathA-v5-sre-windows-review.yaml
linked_prd: PRD-184
linked_psn: PSN-0001
---

# E_S1 — F2 Static Analysis: enumerating writers of `[X+0x84]` and `[X+0x88]`

**BLUF:** No writer in `applewirelessmouse.sys` creates the `{len=4, ptr=NULL}` state observed at the BSOD #2 crash site (+0x9f0e). All four populator paths in F2 atomically write both `[rbp+0x84]` (length) AND `[rbp+0x88]` (ptr). The two writes I found inside the crash function's region itself (FX) set `[rsi+0x84]=7` (a state-transition marker) and never touch `[rsi+0x88]`. Therefore the NULL pointer must originate **outside this binary** — from an asynchronous buffer-free path in the Bluetooth stack, BRB cancellation, or a use-after-free where the buffer is freed but the struct's ptr field is not nulled.

This means: **the v5 INF rename + service isolation fix (S1) is necessary but not sufficient to prevent BSOD reproduction**. If the descriptor patch causes the device to expose new BRB sequencing (e.g., extra SDP queries triggered by the multi-TLC device class), the underlying NULL-deref capability remains.

## Method

Source: `.ai/rev-eng/08f33d7e3ece/disasm.txt` (full applewirelessmouse.sys disassembly, MD5 `f4ae407c…`, 78,424 bytes).

Regex search for every instruction that writes to `[reg+0x84]` or `[reg+0x88]`:

```python
re_write_84 = r'mov\s+(BYTE|WORD|DWORD|QWORD)\s+PTR\s+\[(r[a-z0-9]+|[a-z]+)\+0x84\]'
re_write_88 = r'mov\s+(BYTE|WORD|DWORD|QWORD)\s+PTR\s+\[(r[a-z0-9]+|[a-z]+)\+0x88\]'
re_zero_84  = r'(and|xor)\s+(BYTE|WORD|DWORD|QWORD)\s+PTR\s+\[(r[a-z0-9]+|[a-z]+)\+0x84\]'
re_zero_88  = r'(and|xor)\s+(BYTE|WORD|DWORD|QWORD)\s+PTR\s+\[(r[a-z0-9]+|[a-z]+)\+0x88\]'
```

Region buckets:

| Region | VA range | File range | Source |
|---|---|---|---|
| F2 (IOCTL 0x410003 dispatcher) | 0x1400097e0 — 0x140009c36 | 0x081e0 — 0x08636 | Session 16 boundaries |
| FX (crash function — IOCTL 0x410003 completion callback) | 0x140009e60 — 0x14000a440 | 0x08860 — 0x08e3f | BSOD-RCA + this analysis |
| F3 (SDP descriptor injection) | 0x14000a440 — 0x14000ad93 | 0x08e40 — 0x09793 | Session 16 |

## Results

### Writers of `[reg+0x84]` (length field)

| VA | Region | Instruction | Writes |
|---|---|---|---|
| 0x140002152 | OTHER (populator A) | `mov DWORD PTR [rbp+0x84], 0x4` | length = 4 |
| 0x1400024c1 | OTHER (populator B) | `mov DWORD PTR [rbp+0x84], 0x2` | length = 2 |
| 0x1400027a3 | OTHER (populator C) | `mov DWORD PTR [rbp+0x84], eax` | length = 3 or 4 (flag-dependent) |
| 0x140002a6c | OTHER (populator D) | `mov DWORD PTR [rbp+0x84], 0x5` | length = 5 |
| 0x14000a124 | **FX (crash region)** | `mov DWORD PTR [rsi+0x84], 0x7` | length = 7 (state marker) |
| 0x14000a3e3 | **FX (crash region)** | `mov DWORD PTR [rsi+0x84], 0x7` | length = 7 (state marker) |

Note: the four "OTHER" callsites are inside the BTH BRB submit path (range 0x140002000..0x140002b00) which Session 16 maps to F2's caller chain (the IOCTL 0x410003 sender). They are populators in the sense the SRE-Windows review used; the F2 boundary in Session 16 (0x97e0..0x9c36) is for the dispatcher entry point only, and these callsites are downstream helpers.

### Writers of `[reg+0x88]` (buffer ptr field)

| VA | Region | Instruction | Writes |
|---|---|---|---|
| 0x14000214b | OTHER (populator A) | `mov QWORD PTR [rbp+0x88], r12` | ptr = r12 (just-alloc'd buf) |
| 0x1400024ba | OTHER (populator B) | `mov QWORD PTR [rbp+0x88], r15` | ptr = r15 (just-alloc'd buf) |
| 0x1400027b9 | OTHER (populator C) | `mov QWORD PTR [rbp+0x88], r14` | ptr = r14 (just-alloc'd buf) |
| 0x140002a81 | OTHER (populator D) | `mov QWORD PTR [rbp+0x88], r12` | ptr = r12 (just-alloc'd buf) |

**Total: 4 writes. All in populator paths. None inside FX. None elsewhere.**

### `[reg+0x80]` (preceding flag/state field)

The populators also each write `and DWORD PTR [rbp+0x80], 0` (zeroing a flag/state field at offset +0x80) just before the BRB submit. This rules out the SSE 16-byte write hit at line 236 (`movaps [rbp+0x80], xmm1` at VA 0x14000136e, inside an unrelated function that uses rbp for a local stack frame `lea rbp,[rsp-0xb0]`).

## Pairwise atomicity proof

Each of the four populators executes the writes as a single straight-line sequence with no intervening syscalls or yields. Sample (populator A, VA 0x140002143..0x140002167):

```asm
0x140002143: mov rax, [r15+0x8]
0x140002147: mov [rbp+0x70], rax
0x14000214b: mov [rbp+0x88], r12       ; ptr write
0x140002152: mov [rbp+0x84], 0x4       ; length write
0x14000215c: mov rax, [r15+0x18]
0x140002160: and DWORD [rbp+0x80], 0   ; flag clear
0x140002167: mov [rbp+0x78], rax
```

The two writes are 7 bytes apart in the instruction stream, no branch or call between them. Identical pattern in B/C/D. **The populator pattern cannot create `{len=4, ptr=NULL}` on a successful path.**

The alloc-failure paths in each populator (jne to cleanup) skip both writes; they don't write len without ptr.

## FX self-mutation: state=7 marker, ptr untouched

The two writes inside FX:

**VA 0x14000a124 (post-call):**
```asm
0x14000a11e: call [rip+0x101c]              ; some helper
0x14000a124: mov DWORD [rsi+0x84], 0x7      ; state = 7
0x14000a12e: jmp 0x14000a3f6                ; merge with success path
```

**VA 0x14000a3e3 (after writing buffer contents):**
```asm
0x14000a3d3: mov rax, [rsi+0x88]            ; load buffer ptr
0x14000a3da: mov [rax+r12], ecx             ; write data into buffer
0x14000a3de: mov [rax+r12+4], cl            ; write more data
0x14000a3e3: mov DWORD [rsi+0x84], 0x7      ; state = 7
```

Both sites mark "state=7" as an end-of-processing flag. Neither modifies `[rsi+0x88]`. The buffer ptr remains the value the populator wrote (or NULL if the buffer was already freed asynchronously).

## What this rules out

- Single-thread state-machine bug where one branch writes len without ptr in this binary: **ruled out** — no such writer exists.
- Race between populator and FX self-mutation: **partially ruled out** — populators and FX writes are in different code paths but same struct could exhibit a race; but neither path writes ptr=NULL with len=4.

## What this leaves on the table

- **Asynchronous buffer free in BT stack**: BRB completion could free the buffer (e.g., `ExFreePoolWithTag` on the response data) without nulling `[rsi+0x88]`. If a second/spurious callback runs, ptr is stale (could be NULL after pool free, or just pointing at freed memory).
- **BRB cancellation path**: if a BRB is cancelled, the request blob might be torn down differently from the success path. Cancellation typically zeroes some BRB fields; if it zeros `[rsi+0x88]` while the IRP still pends a completion that reads `[rsi+0x84]`, we get the crash state.
- **Use-after-free where the struct itself is freed**: if `(*(call2_result + 0xb8) + 8)` is reused / reallocated, rsi could point at fresh-allocated zeroed memory with `[rsi+0x84]==0` (would be skipped by `jb` check) OR at LFH-recycled memory with stale length 4 + freed ptr.
- **Different writer class**: code paths using indirect addressing modes that my regex didn't catch:
  - `mov [rax], 0` where rax was computed as `lea rax, [rsi+0x88]` — would zero ptr without showing as `[rsi+0x88]` in disasm
  - SSE writes spanning the field (16-byte writes at lower offsets)
  - REP STOS / memset patterns inside larger functions

## Recommended next investigation steps (still pre-install)

1. **Search for `lea X, [reg+0x88]`** patterns where X is later dereferenced and written. Same for `lea X, [reg+0x84]`.
2. **Search for memset/RtlZeroMemory calls** with sizes that could span +0x84 and +0x88 of the relevant struct. Look at how big the struct is (offsets +0x70..+0x88 are populated, so it's at least 0x90 bytes).
3. **Identify what `[rip+0x905d]` returns** in the helper called at populator entry (e.g., line 1078: `call [rip+0x905d]` returning a struct that gets used as rbp). Is this an Apple-internal pool allocator? A WdfObjectAllocateContext call? If it's an arena/pool with reuse semantics, NULL-on-recycle is plausible.
4. **Identify the IOCTL 0x410003 BRB type** — is this a Microsoft-public BRB code or Apple-internal? If Apple-internal, the BT stack treats it differently from standard BRBs and the cancel/teardown semantics may not match Microsoft's documented WdfRequestComplete behavior.
5. **Trace the lifetime of `*(call2_result + 0xb8)`** — the array/list at offset 0xb8 of the device-ext object. If entries are freed individually but the slot is reused, that could be the use-after-free vector.

## Implication for the v5 install plan

Even with all the structural fixes from the SRE-Windows review (S1 service rename, S2 startup-repair scope, S3 BTHPORT cache, S4 Fast Startup off, S5 verify):

- v3 alone with the patched descriptor will still issue IOCTL 0x410003 BRBs through the same code paths.
- The patched descriptor changes what HidBth queries via SDP (multi-TLC enumeration triggers more child opens), which can alter the BRB sequencing on the BTHENUM parent, exposing the NULL-deref window.
- We have not identified the specific code path that creates the NULL state, so we cannot guarantee it doesn't fire on v5 install.

**Conclusion**: structural fixes prevent v1 cross-fire (a known trigger), but the underlying capability to BSOD on the F2/FX path remains until the NULL-creation path is identified and either (a) avoided in our descriptor patch, or (b) documented as an acceptable risk for non-stress workloads.

The 5% "plan works" outcome estimate from the SRE-Windows review remains the realistic upper bound for "patched bundle works without ever BSOD'ing".

## Recommendation

If proceeding with PATH-A v5 install on the user's daily driver:
- Apply ALL structural fixes (S1-S5)
- Run E_S1 follow-up steps 1-5 above first to push confidence higher
- Treat first 72h post-install as observation period; have rollback ready (uninstall.ps1 in this bundle)

If user's risk tolerance is low (one machine, ~30 min recovery per BSOD):
- Park PATH-A v5 as a Phase 2 R&D activity
- Continue PATH-B (PRD-26 userland recycler) as production path
