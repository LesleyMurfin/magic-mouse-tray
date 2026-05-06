# Investigation Prompt — Ghidra Descriptor Source Trace for applewirelessmouse.sys

**Type**: autonomous background investigation
**Goal**: locate the actual code path through which `applewirelessmouse.sys` injects a HID Report Descriptor in response to `IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE` (`0x00410210`), so a future patch can either modify the source bytes or hook the injection routine.
**Outcome**: a written report. NO BINARY PATCHING during this investigation.

---

## Prompt to give the new session

```
You are running an autonomous Ghidra-driven reverse-engineering investigation
on Apple's applewirelessmouse.sys (Windows kernel HID lower-filter driver).
The goal is read-only: produce a written report. DO NOT modify any binary,
do not install anything, do not touch the live device.

Hardware/OS context:
- Magic Mouse v3 (PID 0x0323) on Windows 11 build 26100
- Apple's stock WHQL-signed driver: 78424 bytes
  Path: C:\Windows\System32\DriverStore\FileRepository\applewirelessmouse.inf_amd64_ac34ebceaaf7324c\applewirelessmouse.sys
  MD5: f4ae407c228c3db6147d9e3307ed5f20

Background (read these first):
- /home/lesley/projects/Personal/magic-mouse-tray/PSN-0001-hid-battery-driver.yaml
  (full hypothesis log H-001 .. H-018)
- /home/lesley/projects/Personal/magic-mouse-tray/docs/SESSION-15-EMPIRICAL-TEST-RESULTS-2026-05-05.md
  (Session 15 findings — PATH-A invalidated)
- /home/lesley/projects/Personal/magic-mouse-tray/docs/M12-APPLEWIRELESSMOUSE-FINDINGS.md
  (existing initial Ghidra notes, light-touch)
- /home/lesley/projects/Personal/magic-mouse-tray/docs/M13-V3-BINARY-PATCH-APPLE-SYS-2026-04-29.md
  (the failed patch attempt and its incorrect assumptions)

CRITICAL FINDING from Session 15:
The 116-byte HID descriptor at file offset 0xA850 has ZERO references in the
binary code. No LEA RIP-rel, no `mov rax, imm64`, no PE relocations, no
32-bit immediate constants point to it. It is most likely inert build-leftover
data. Patching it does nothing.

Your job: find the REAL source of the descriptor that Apple's filter injects
in response to IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE.

==================================================================
STEP 1 — Confirm the IOCTL handler dispatch path
==================================================================
The IOCTL constant 0x00410210 appears at file offsets 0x80AB and 0x8F72
(both in the .text section). At 0x80AB we have:
    cmp esi, 0x00410210   (81 FE 10 02 41 00)
    jz +0x57              (74 57)
which jumps to the handler at 0x810A.

The handler at 0x810A consists of a chain of indirect calls:
    mov rax, [rip+0x58D9]
    mov rdx, rbx
    mov rcx, [rip+0x58D7]
    mov rax, [rax+0x7D8]
    call [rip+0x191A]
    ...

These are WDF dispatch helpers (WdfRequestComplete*, WdfMemoryCreate*,
WdfRequestRetrieveOutputBuffer, etc.). Identify which WDF helper each
indirect call resolves to, by following the [rip+offset] reference into
the .data import table and resolving the symbol name. Use `analyzeHeadless`
non-interactively with the Ghidra script in
/home/lesley/projects/Personal/magic-mouse-tray/scripts/ghidra-applewirelessmouse-analysis.py
as a starting point — extend it.

==================================================================
STEP 2 — Find what data is written to the IOCTL output buffer
==================================================================
The handler MUST eventually copy bytes into the IRP output buffer
(`Irp->AssociatedIrp.SystemBuffer` or via WdfRequestRetrieveOutputBuffer).
That copy operation is the "smoking gun" — whatever source pointer is
passed to RtlCopyMemory / memcpy / WdfMemoryCopy* IS the descriptor source.

Trace forwards from 0x810A. Look for:
    a. Direct memcpy/RtlCopyMemory calls with a source pointer
    b. WdfMemoryCreate* + WdfMemoryCopyFromBuffer
    c. RtlInitUnicodeString-like patterns (less likely for binary blob)

If a source pointer is identified, compute its file offset and report
the bytes. If those bytes look like an SDP attribute response containing
a HID descriptor sequence (UsagePage 0x05 0x01, etc.), you've found it.

==================================================================
STEP 3 — Check for dynamic descriptor construction
==================================================================
If no static source is found, the descriptor may be CONSTRUCTED at runtime.
Look for:
    - Stack-allocated buffer being filled with literal byte stores
      (mov [rsp+N], 0x05 / mov byte ptr [rsp+M], 0x01 / etc.)
    - Pool allocations (ExAllocatePoolWithTag) followed by population
    - Multiple descriptor variants chosen via if/else (Mode A vs Mode B)

If construction is dynamic, identify:
    - the variant-selection criterion (registry key? device state? IOCTL
      sub-function?)
    - the byte sequence that constructs each variant
    - whether one variant could be patched into the byte stores

==================================================================
STEP 4 — Map the relationship to Mode A / Mode B
==================================================================
PSN-0001 H-010 REVISED: HidBth's descriptor cache has two states.
Mode A: vendor 0xFF00 TLC enumerated as separate COL02 child PDO
        (battery readable via Input RID=0x90)
Mode B: single Mouse TLC, COL02 stripped, phantom Feature 0x47
        (scroll synthesized by Apple's filter, battery NOT readable)

Determine: is the mode selected by Apple's filter (i.e., the filter
chooses which descriptor to inject), or is it driven by HidBth's
caching of device-supplied SDP responses (filter is passive)?

If the filter is the source of mode selection, the variant-selection
condition is patchable.

==================================================================
STEP 5 — Look for IOCTL 0x00410210 second occurrence
==================================================================
The IOCTL constant also appears at 0x8F72. That's a DIFFERENT handler
(or fall-through). Trace it independently. It might be the other branch
(Mode A vs Mode B) or a related IOCTL handler.

==================================================================
STEP 6 — Output report
==================================================================
Write findings to:
    /home/lesley/projects/Personal/magic-mouse-tray/docs/SESSION-16-GHIDRA-DESCRIPTOR-TRACE.md

Format:

    # Session 16 — Ghidra Descriptor Trace Findings
    ## BLUF
    [1-2 sentences: did you find the descriptor source? Y/N. If Y, where.]

    ## Method
    [Tools, scripts run, time spent]

    ## Findings
    ### F1: IOCTL handler call graph
    ### F2: Buffer-write site(s)
    ### F3: Source pointer identification
    ### F4: Static vs dynamic descriptor construction
    ### F5: Mode A/B variant selection mechanism

    ## Verdict
    [One of:]
    - PATCH-VIABLE: source bytes at file offset 0xXXXX, patch path is to
      change those bytes + re-sign. Length-field references at 0xYYYY.
    - PATCH-DIFFICULT: dynamic construction with N byte-store sites.
      Patching requires modifying instructions, not data.
    - PATCH-NOT-VIABLE: descriptor sourced from device SDP response
      pass-through; binary patching gives no leverage.

    ## Recommended Next Steps
    [If PATCH-VIABLE: write the precise patch operations.
     If PATCH-DIFFICULT: estimate effort and risk.
     If PATCH-NOT-VIABLE: confirm PATH-B is the right call.]

    ## Evidence
    [Function signatures, instruction sequences, bytes-on-disk excerpts
     supporting the verdict.]

==================================================================
RULES
==================================================================
- Read-only: NO writes to System32, registry, scheduled tasks, BTHPORT,
  or any kernel-modifying state.
- Do NOT install or replace any driver binary.
- Do NOT modify the binary on disk; copy it to a tmp location for any
  Ghidra analysis if needed (preserve checksums).
- Use Ghidra in headless mode (analyzeHeadless) for repeatability.
- If you reach a dead-end after 4 hours of focused work, stop and
  write the report with PATCH-NOT-VIABLE verdict and rationale.
- Do not delegate sub-questions back to the user; figure them out.
- When in doubt, prefer reproducible scripted steps over interactive
  Ghidra GUI sessions.

==================================================================
GUARDRAILS / SAFETY CHECKS
==================================================================
- After every analysis pass, verify md5 of the live driver binary still
  matches f4ae407c228c3db6147d9e3307ed5f20. If not, abort.
- DO NOT push commits to ai/* or main without explicit user approval.
  Commits to a new ai/m14-ghidra-descriptor-trace branch are fine for
  artifact preservation, but DO NOT open a PR.
- DO NOT touch /mnt/c/mm-dev-queue/ — that's where the live driver
  install pipeline operates.

==================================================================
EXIT CRITERIA
==================================================================
- Report written at the path above.
- Verdict is one of PATCH-VIABLE / PATCH-DIFFICULT / PATCH-NOT-VIABLE.
- Evidence section contains at minimum: 1 disassembly excerpt of the
  IOCTL handler, 1 import-symbol resolution, 1 byte-stream sample if
  any descriptor-shaped data is identified.
- Notify the user via SMS (use the existing /sms or email skill if
  available) with a 2-line summary and a link to the report file.
```

---

## Optional automation

If you want this to run unattended via a scheduler, add a `cron` or `at`
entry that invokes the agent with the prompt above. The session should
complete within 4 hours; longer than that and the agent should self-abort
per the rules.

Suggested invocation (for reference, do not run from here):

```bash
# To dispatch from another Claude Code session:
# - Create a new background agent (general-purpose, large model preferred for RE)
# - Pass the prompt block from above verbatim
# - Foreground the agent only after the report file exists
```

## Estimated cost
- Time: 2-4 hours of focused autonomous work
- API spend: ~$5-15 in Gemini Pro / Claude Opus tokens for Ghidra script generation, decompilation review, and report writing
- Risk: zero — investigation is read-only

## Pre-check before starting (one-shot)

```bash
md5sum /mnt/c/Windows/System32/DriverStore/FileRepository/applewirelessmouse.inf_amd64_ac34ebceaaf7324c/applewirelessmouse.sys
# Expected: f4ae407c228c3db6147d9e3307ed5f20
```

If the MD5 differs, the binary has been modified since this prompt was
written — STOP and reconcile state before launching the investigation.
