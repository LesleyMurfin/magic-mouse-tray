# Design-Pass Prompt — PATH-A Binary Patch of applewirelessmouse.sys

**Type**: autonomous background design session
**Goal**: produce a complete, peer-reviewed, ready-to-execute binary-patch design for `applewirelessmouse.sys` that delivers cursor + scroll + battery on Magic Mouse v3, without ever installing the candidate during this session.
**Outcome**: a design doc + a candidate signed `.sys` file staged for review + an install MOP. NO INSTALL.

---

## Prompt to give the new session

```
You are running an autonomous design session for a binary patch of Apple's
applewirelessmouse.sys (Windows kernel HID lower-filter driver) on
Magic Mouse v3 / Windows 11 26100.

This session DESIGNS the patch and validates it offline + via expert peer
review. It does NOT install or modify any system state. The deliverable is
a design doc + candidate signed binary + install MOP — all reviewable, all
reversible.

==================================================================
HARDWARE / OS CONTEXT
==================================================================
- Apple Magic Mouse 2024 v3 (Bluetooth Classic BR/EDR), VID 0x004C PID 0x0323,
  MAC D0:C0:50:CC:8C:4D
- Windows 11 build 26100
- Apple's stock WHQL-signed driver: 78424 bytes
  Path: C:\Windows\System32\DriverStore\FileRepository\applewirelessmouse.inf_amd64_ac34ebceaaf7324c\applewirelessmouse.sys
  MD5: f4ae407c228c3db6147d9e3307ed5f20
- Self-signing: cert thumbprint 16940C0F937D569363560D5FEC5CD8FA6D6D9BCE
  (CN=MagicMouseFix) installed in LocalMachine\TrustedPublisher; testsigning on
- Existing PATH-A failed candidate: applewirelessmouse-fixed.sys (66288 bytes,
  MD5 74756dc8...) at /mnt/c/mm-dev-queue/. Studied; failed with NTSTATUS
  0xC00000B9 STATUS_INVALID_PARAMETER_MIX. Don't repeat its mistakes.

==================================================================
REQUIRED READING (in order)
==================================================================
1. /home/lesley/projects/Personal/magic-mouse-tray/PSN-0001-hid-battery-driver.yaml
   - Full hypothesis log H-001 .. H-019
   - Pay close attention to:
     * H-008 (phantom Feature 0x47 — v3 doesn't back it; safe to remove)
     * H-010 RE-REVISED (filter is passive; Mode A/B is HidBth caching)
     * H-016 (Apple's gesture engine has compiled-in TLC1 byte-layout assumptions
       — produced spurious left-clicks when descriptor changed)
     * H-019 (the Session 16 Ghidra finding: descriptor at 0xA850 IS used
       via SSE 128-bit movups at file 0x9611 + 0x96e5)

2. /home/lesley/projects/Personal/magic-mouse-tray/docs/SESSION-16-GHIDRA-DESCRIPTOR-TRACE.md
   - The Session 16 verdict and patch-site analysis

3. /home/lesley/projects/Personal/magic-mouse-tray/docs/SESSION-15-EMPIRICAL-TEST-RESULTS-2026-05-05.md
   - Tests 1-4 results, with retraction note for the morning "zero references" claim

4. /home/lesley/projects/Personal/magic-mouse-tray/docs/M13-V3-BINARY-PATCH-APPLE-SYS-2026-04-29.md
   - Documents the failed 04-30 patch attempt: what bytes it changed, how it
     was signed, why it FAILED_STARTed
   - Use this as the "what NOT to do" baseline

==================================================================
DESIGN CONSTRAINTS
==================================================================

C1. **Total descriptor length must be exactly 116 bytes** unless the SSE-load
    count + DWORD load at file offsets 0x9611 and 0x96e5 are also patched.
    Default to 116 bytes — keeps the patch surface minimal.

C2. **Preserve Apple's TLC1 mouse-report byte layout** exactly per H-016.
    Specifically: do NOT change the structure of bytes that produce mouse
    Input report fields (Buttons, X, Y, AC Pan, Wheel) at RID 0x02. Apple's
    gesture engine writes output reports against this exact layout.

C3. **Preserve RID 0x27 input declaration** with its byte length (46) and
    Constant flag — Apple's filter receives RID=0x27 reports from the mouse
    and forwards them up. The descriptor must declare this report so HidBth
    accepts it. (This was one of the things the 04-30 patch broke — the
    UsagePage=6/Usage=1 association was dropped.)

C4. **Available bytes to sacrifice for vendor battery TLC2**:
    - Phantom Feature 0x47 (UsagePage 0x06, Usage 0x20, RID 0x47, 1-byte feature)
      = 15 bytes. H-008 confirms v3 hardware does NOT back this Feature read.
      Removing it is safe.
    - Vendor pad UsagePage 0xFF02 + Usage 0x20 + 1-bit padding (~10 bytes
      starting around offset +030). Purpose unclear; may or may not be
      required. Investigate before removing.

C5. **Required new content**: a vendor battery TLC2 declaring:
    - UsagePage 0xFF00 (3 bytes: 06 00 FF)
    - Usage 0x14 (2 bytes: 09 14)
    - Application Collection (2 bytes: A1 01)
    - ReportID 0x90 (2 bytes: 85 90)
    - Usage 0x01 or similar (2 bytes: 09 01)
    - LogicalMin / LogicalMax (range that holds 0..100 battery percent)
    - ReportSize 8 / ReportCount 2 (or 1 — battery + flags vs battery only)
    - Input flags (0x02 = Var)
    - EndCollection (1 byte: C0)
    Minimum viable: ~17-22 bytes.

C6. **The candidate binary MUST keep Apple's PE structure intact except
    for**: the descriptor data bytes at 0xA850 (and the cert overlay,
    which signtool replaces). No section-header rewrites, no relocation
    table modifications.

C7. **Re-sign with the existing CN=MagicMouseFix cert** (already trusted on
    the target machine via TrustedPublisher install).

==================================================================
DESIGN STEPS
==================================================================

STEP 1 — Confirm the patch sites empirically
    Re-verify Session 16's findings by re-running the SSE-load scan against
    the binary. Confirm:
    a. Two patch sites at file 0x9611 and 0x96e5 in F3 SDP completion callback
       at VA 0x14000a440
    b. Each site copies exactly 116 bytes via 7 movups + 1 DWORD load
    c. Source operand for each load resolves to file offset 0xA850 (RVA 0xC050)
    Document the actual disassembly bytes and instruction encodings for
    audit trail.

STEP 2 — Test C4 assumptions empirically
    a. Phantom Feature 0x47: re-confirm by attempting HidD_GetFeature(0x47)
       on the live device with stock Apple driver. Expect err=87 (per H-008).
       If it succeeds, abort — the 14 bytes can't be sacrificed.
    b. Vendor pad UsagePage 0xFF02: search Linux hid-magicmouse.c source +
       Apple WHQL driver disassembly for any code that processes RID=0x02
       data assuming this 1-bit field. If found, mark as REQUIRED. If not
       found, mark as POTENTIALLY-REMOVABLE but keep it (low-risk default).

STEP 3 — Design the new 116-byte descriptor
    Produce a complete byte-by-byte specification:
    - Show the original 116 bytes annotated with item meaning
    - Show the proposed 116 bytes annotated, with clear DELTA markers
    - Show the budget arithmetic: bytes-removed = bytes-added
    - Decode the proposed descriptor through the existing structural
      validator at scripts/decode-hid-descriptor.py and scripts/decode-hid-detailed.py
      (must pass both)
    - Manually check: does TLC2 declare proper Usage + LogicalMin/Max
      such that hidclass.sys will accept it?
    - Manually check: does TLC1 still produce identical mouse report
      byte layout?
    - Show what Mode A vs Mode B looks like to HidBth post-patch (since
      filter is passive, the mode mutual exclusion still exists in HidBth's
      cache layer — but with COL02 declared, Mode A becomes the natural
      enumeration outcome)

STEP 4 — Diagnose the 04-30 failure mode (so we don't repeat it)
    The 2026-04-30 patch was structurally valid (Test 1 + Test 3 confirmed)
    but FAILED_STARTed with STATUS_INVALID_PARAMETER_MIX. Explain why. Hypotheses
    to investigate:
    - H-A: re-signing damaged WDF metadata or PE checksums (test: signtool
      with --verbose or compare PE headers byte-by-byte)
    - H-B: hidclass.sys validation rule we missed (e.g., RID 0x91 'dummy
      feature padding' is an orphan declaration — RID without proper Usage)
    - H-C: Apple's gesture engine internally validates the descriptor against
      its expected layout and refuses to start if mismatched (would trigger
      via DriverEntry, not hidclass)
    - H-D: testsigning + WHQL chain conflict (binary signed with our self
      cert can't load while Apple's removed cert was actually being used
      in some way for verification)
    Pick the most likely; design the new patch to AVOID it. Document
    contingency plan.

STEP 5 — Build the candidate binary OFFLINE
    a. Copy the stock Apple binary to /tmp/applewirelessmouse-pathA.sys
    b. Compute the patched 116 bytes per Step 3 design
    c. Write the patched bytes at file offset 0xA850 in the candidate
    d. Verify file offset 0x9611 and 0x96e5 instructions are unchanged
    e. Verify all bytes outside [0xA850, 0xA8C4) are unchanged
    f. Verify md5 of [0, 0xA850) matches stock
    g. Verify md5 of [0xA8C4, end-of-cert) matches stock
    h. Sign with MagicMouseFix cert via Set-AuthenticodeSignature (works as
       SYSTEM per AP-28)
    i. Verify the signature is valid (Get-AuthenticodeSignature)
    j. Final candidate: /tmp/applewirelessmouse-pathA-signed.sys

STEP 6 — Decode the candidate's descriptor live
    Re-run scripts/decode-hid-descriptor.py and scripts/decode-hid-detailed.py
    against the candidate's 0xA850..0xA8C4 region.
    All output MUST match the design spec from Step 3.

STEP 7 — *** GATING PEER REVIEW ***
    BEFORE finalising the design doc, run BOTH peer reviews:

    7a. NotebookLM adversarial query against PRD-184 notebook
        (e789e5e9-da23-4607-9a62-bbfd94bb789b) using the /notebooklm or
        /peer-review skill. Use an adversarial prompt that:
        - Presents the patch design as HYPOTHESIS to verify
        - Explicitly lists what was NOT tested
        - Asks for the WEAKEST ASSUMPTION
        Get a verdict: APPROVE / CHANGES-NEEDED / REJECT.

    7b. Expert peer review via riley delegate --model t3 (Gemini Pro).
        Same adversarial prompt format. Get verdict.

    7c. If EITHER returns CHANGES-NEEDED or REJECT: address the findings
        (revise design Step 3, rebuild candidate Step 5, re-decode Step 6)
        and re-run peer review until both APPROVE.

    7d. Document both peer-review responses verbatim in the design doc
        under a "Peer Review Outcomes" section. Include the full prompts
        used so the audit trail is complete.

STEP 8 — Write the install MOP
    The MOP should be a fully scripted PowerShell file (do not execute):
    /mnt/c/mm-dev-queue/install-pathA-candidate.ps1

    Required sections:
    - Pre-flight checks (cert in TrustedPublisher, testsigning on, Apple
      stock binary currently loaded, BTHENUM device present, mouse paired)
    - Backup current state (System32 + DriverStore both)
    - Install via PendingFileRenameOperations (kernel driver is locked
      while running; reboot required) — see existing PATCH-APPLE-SYS route
      in scripts/mm-task-runner.ps1 line 364 area
    - Post-reboot validation hook: clear BTHPORT cache, restart-device,
      wait for COL02 to enumerate, read battery
    - Rollback (`scripts/restore-apple-driver.ps1` already exists)

STEP 9 — Final design doc
    Write to:
    /home/lesley/projects/Personal/magic-mouse-tray/docs/PATH-A-PATCH-DESIGN.md

    Required sections:
    1. BLUF (1-2 sentences: ready / not ready, with verdict from 7a+7b)
    2. Design constraints (C1-C7, with proof of compliance for each)
    3. Original vs proposed descriptor (annotated byte-by-byte)
    4. 04-30 failure-mode diagnosis (Step 4 finding)
    5. Candidate binary metadata (md5, size, signature status, file path)
    6. Peer review outcomes (7d)
    7. Install MOP path
    8. Rollback procedure
    9. Post-install verification checklist

==================================================================
RULES
==================================================================
- Read-only on the live system EXCEPT for offline file creation in /tmp
  and /mnt/c/mm-dev-queue/install-pathA-candidate.ps1
- DO NOT modify C:\Windows\System32, registry, scheduled tasks, BTHPORT,
  or any kernel-modifying state
- DO NOT install or replace any driver binary
- DO NOT push commits without explicit user approval (commits to a new
  ai/m14-path-a-design branch are fine for artifact preservation; PR is fine)
- DO NOT touch /mnt/c/mm-dev-queue/applewirelessmouse-fixed.sys (the
  failed 04-30 candidate — preserve as evidence)
- Use the existing MM-Dev-Cycle scheduled task ROUTES if you need
  privileged ops (RUN-AS-SYSTEM); do NOT register new scheduled tasks

==================================================================
GUARDRAILS / SAFETY CHECKS
==================================================================
- After every analysis pass, verify md5 of the live driver still equals
  f4ae407c228c3db6147d9e3307ed5f20. If not, abort.
- DO NOT skip Step 7. Both peer reviews are required gates. If NLM is
  401 (known stale-token bug), call refresh_auth then retry. If still
  401, document the failure in the doc and proceed with riley delegate
  alone but flag NLM-skipped.
- If Step 4 (failure-mode diagnosis) reveals a fundamental blocker
  (e.g., re-signing genuinely breaks the WDF integrity check no matter
  what we do), write a PATCH-NOT-VIABLE verdict to the design doc and
  stop. Do NOT produce a candidate binary.
- Time budget: 4 hours. If you exceed without a complete deliverable,
  write a partial-progress report and stop.

==================================================================
EXIT CRITERIA
==================================================================
- Design doc written at the path above with all 9 sections
- Candidate binary at /tmp/applewirelessmouse-pathA-signed.sys (md5
  recorded in design doc) — IF design verdict is GO
- Install MOP at /mnt/c/mm-dev-queue/install-pathA-candidate.ps1 — IF
  design verdict is GO
- Both peer-review responses captured verbatim in the design doc
- Notify the user via SMS (use the existing /sms or email skill if
  available) with: "PATH-A design pass complete. Verdict: <GO|NO-GO>.
  Doc at <path>." — keep under 160 chars
- Driver MD5 still f4ae407c... (read-only invariant proven)

==================================================================
ESTIMATED COST
==================================================================
- Time: 2-4 hours of focused autonomous work
- API spend: ~$10-25 in tokens (Ghidra-equivalent disasm + 2× peer
  review delegations)
- Risk: zero — all work is offline; install requires user approval
- Optional: launch Step 7 peer reviews in parallel to halve wall-clock
```

---

## How to dispatch

When the user is ready to launch this session:

```
# In a fresh Claude Code session (Opus preferred for binary work):
# Paste the entire prompt block above as the first user message.
# The agent will run Step 1 through Step 9 autonomously.
# Expect 2-4 hour completion; final notification via SMS.
```

## Pre-check before launching

```bash
md5sum /mnt/c/Windows/System32/DriverStore/FileRepository/applewirelessmouse.inf_amd64_ac34ebceaaf7324c/applewirelessmouse.sys
# Must equal: f4ae407c228c3db6147d9e3307ed5f20
```

## What gets reviewed before install (the next gate after this design pass)

The user reviews the produced `docs/PATH-A-PATCH-DESIGN.md`, the candidate
binary, and the install MOP. If they approve, a separate session executes
the install (with its own APEX gate). This design pass produces evidence
for that decision; it does NOT short-circuit the install gate.
