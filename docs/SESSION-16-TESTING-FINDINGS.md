# Session 16 — Testing Findings (Companion to Ghidra Descriptor Trace)

**Date**: 2026-05-06
**Author**: agent (autonomous orchestration)
**Companion to**: `docs/SESSION-16-GHIDRA-DESCRIPTOR-TRACE.md` (the RE/disassembly report)
**Binary under test**: `applewirelessmouse.sys`, MD5 `f4ae407c228c3db6147d9e3307ed5f20` (78424 bytes, WHQL)

---

## BLUF

The Session 16 Ghidra trace produced three test-affecting outcomes that the empirical track needs to absorb before any further patch attempt: (a) the in-place 116-byte patch target at file `0xA850` is **confirmed correct**, refuting Session 15's morning "ZERO references / PATH-A invalidated" finding; (b) `applewirelessmouse.sys` is a **passive descriptor-replacer** in the SDP path — Mode A vs Mode B is HidBth caching state, not filter logic; (c) the upstream Session 15 evening BLUF correctly noted the "5→2 button" diff was wrong, but the Test 4 table still shows it; that table needs a follow-up annotation if revisited. Net effect on the test plan: PATH-A in-place mechanics are sound but the descriptor-design space within 116 bytes that preserves Apple's gesture-engine layout AND adds a usable battery channel is empirically narrow; PATH-B (M13/M14 KMDF clean-room driver) remains the production path.

---

## Source artefacts referenced by this document

- `docs/SESSION-16-GHIDRA-DESCRIPTOR-TRACE.md` — RE/disassembly report (verdict: PATCH-VIABLE)
- `docs/SESSION-15-EMPIRICAL-TEST-RESULTS-2026-05-05.md` — earlier empirical pass (already annotated upstream with the Session 16 retraction of the PATH-A invalidation)
- `docs/M13-V3-BINARY-PATCH-APPLE-SYS-2026-04-29.md` — earlier binary-patch attempt (now annotated with Session 16 reconciliation)
- `PSN-0001-hid-battery-driver.yaml` — hypothesis log; H-010 re-revised + H-019 added (filter is passive; SDP IOCTL handler at VA 0x14000a440)
- Production binary (untouched, MD5-verified before/after): `/mnt/c/Windows/System32/DriverStore/FileRepository/applewirelessmouse.inf_amd64_ac34ebceaaf7324c/applewirelessmouse.sys`

---

## Findings that change the test plan

### TF1 — In-place 116-byte patch target is correct (PATH-A mechanics validated)

The 16 RIP-relative references that bind file `0xA850` to F3's two write paths means an in-place edit of the 116-byte slot requires **zero offset fixups**. Both write paths copy the same 116 bytes; both remain valid as long as the source slot is exactly 116 bytes long.

**Test plan implication**: any future PATH-A attempt does NOT need to "find pointer references and update them" (Session 15 morning's stated blocker). It needs to fit a working dual-TLC descriptor inside the 116-byte ceiling. The "zero references" claim and consequent PATH-A invalidation in the upstream Session 15 morning BLUF are **superseded** by Session 16 (and already reflected in the Session 15 evening retraction).

### TF2 — Apple's filter is passive in the SDP path (Mode A/B is upstream)

Both descriptor-write code blocks (file `0x9611`, `0x96e5`) emit the SAME 116 bytes unconditionally. There is NO Mode A vs Mode B variant selection inside `applewirelessmouse.sys`. The two blocks differ only in how they fix up SDP DataElement length headers (1-byte vs 2-byte / 4-byte size fields), not in the descriptor payload.

**Test plan implication**: the empirically-observed mode-mutual-exclusivity (Mode A: battery yes, scroll no; Mode B: opposite) cannot be controlled by patching this filter. The mode flip mechanism lives in HidBth's kernel-pool descriptor cache and possibly in the upstream BT stack's SDP-cache lifecycle. Tests that try to "force" one mode by altering filter behaviour will not work. This validates the recently re-prioritised PSN-0001 H-012 (BTHENUM Disable+Enable recycle reliability) as the right next empirical question for PRD-PATH-B M0 gating.

### TF3 — Session 15 Test 4 table inconsistent with its own BLUF

The upstream Session 15 BLUF (revised 2026-05-06 evening) correctly notes that the morning button-count claim was wrong: "both descriptors declare 2 buttons identically". The Test 4 table further down still lists Apple ORIGINAL as **5 buttons (UsageMin 1 / UsageMax 5, RCount 5, Size 1)** — a transcription error that the BLUF caught but the table did not. Session 16 confirms via raw bytes at file `0xA858..0xA862` (`19 01 29 02 ... 95 02 75 01 81 02`) that Apple stock declares 2 buttons.

**Test plan implication**: hypotheses that attributed the Session 15 patch failure to "5→2 button re-architecture breaking Apple's gesture engine" need re-evaluation. The button count did not change. The actual structural changes between Apple stock and the M13-V3 patch are:
1. 1 Application Collection → 2 Application Collections (split)
2. Removal of vendor-pad TLC (UP=0xFF02, 1 bit at +030)
3. Replacement of phantom Feature RID=0x47 with Input RID=0x90 + Feature RID=0x91 padding
4. Padding-bit recount inside the mouse byte 0 caused by the vendor-pad removal

Any of (1), (2), (3), (4) — or a combination — could be what breaks Apple's gesture engine; isolating which would require differential testing of patches that change one variable at a time. **This is now the relevant empirical question, not button count.**

### TF4 — Phantom Feature 0x47 is a static field, not a runtime injection

Bytes `09 20 85 47 15 00 25 64 75 08 95 01 b1 a2` live at file `0xA8A6` inside the canonical 116-byte block. They are emitted unconditionally by both write paths. The earlier framing ("Apple driver traps Feature 0x47") — already rejected at Session 11 (AP-19) — is reaffirmed: the filter just declares Feature 0x47 in the descriptor; whether v3 hardware honours a Feature 0x47 read is independent of the filter.

**Test plan implication**: Feature 0x47 reads will continue to error 87 on v3 hardware regardless of any patch we apply, unless the patch removes the Feature 0x47 declaration. Any test that probes Feature 0x47 to "verify" battery-channel state is asking the wrong question.

### TF5 — M13-V3 patch failure re-attributed (not a source-location error)

The 2026-04-30 patch failure (`STATUS_INVALID_PARAMETER_MIX`, then Problem Code 22 in Session 15 retry) was NOT a target-location error. The most likely contributors are:

- **Descriptor design within 116 bytes**: the 2-TLC layout forces compromises that may break compiled-in assumptions in Apple's gesture engine.
- **Cert chain trust**: `signtool` cert-overlay truncation (78424 → 66288 bytes); `MagicMouseFix` self-signed cert needs to be in `LocalMachine\TrustedPublisher` and either testsigning enabled OR the cert chain trusted by Code Integrity. Per cross-session memory (2026-04-29), the trust chain installer (`scripts/install-m12-trust.ps1`) is the one-time fix.
- **BTHPORT cache mismatch**: HidBth's kernel-pool cache must be cleared so the BT stack does a fresh SDP exchange the patched filter can intercept. The Session 15 cache-clear step was a no-op (registry key not at the expected path).

**Test plan implication**: any future PATH-A test must (a) install the cert trust chain BEFORE first load, (b) clear the actual BTHPORT cache (location to be verified empirically — registry path differed from documented), (c) restrict patch scope to one of the four structural variables in TF3 to isolate which one breaks gesture output. The recently merged PRD-PATH-B M0 milestone gates on H-012 reliability; that milestone should also incorporate this design-space framing.

---

## What this means for the M13/M14 path

The Session 16 finding does NOT obsolete the M13 KMDF clean-room driver work (Sessions 13–14, currently functional with battery confirmed at 24% via COL02 RID=0x90). It does the opposite: it confirms that PATH-A's mechanical viability does not translate into PATH-A's design-space viability within 116 bytes. M13 stays the production path; M14 (scroll gesture translation by parsing RID=0x27 multi-touch frames in the WDF filter) remains the next milestone.

Specifically:

- **M13 already works** with descriptor injection at offset `0x4450` (135 bytes, no upstream binary edit required). Battery readable via COL02 RID=0x90. Cursor + click work.
- **M14 scroll work** is independent of this finding — it's a translation problem on the input path (RID=0x27 → RID=0x02 wheel), not a descriptor problem.
- **PATH-A is not formally closed**, but the design-space evidence makes it lower priority than M14 completion.

---

## Anti-patterns (already captured upstream)

The matching anti-pattern (descriptor-search must include SSE-encoded RIP-relative loads) is captured in the Session 15 evening retraction and the new PSN-0001 H-019. No additional AP entry needed from this document.

**Detection signature** (for future reference): if a "no references found" claim is being made about a data blob in `.data` or `.rdata`, the search must explicitly enumerate every instruction whose memory operand has base register `RIP` (capstone: `op.mem.base == X86_REG_RIP`) and resolve the target. Any other approach is incomplete.

---

## Test-readiness ledger

| Item | State | Note |
|---|---|---|
| Production binary integrity | OK | MD5 `f4ae407c…ed5f20` unchanged before/after Session 16 analysis |
| In-place 116-byte target validated | YES | Session 16 RE confirmed file `0xA850` is the source |
| Mode A/B mechanism understood | PARTIAL | Filter is passive; HidBth cache lifecycle still empirically untested (PRD-PATH-B M0 = H-012 recycle reliability) |
| Cert trust chain installer | EXISTS | `scripts/install-m12-trust.ps1` (per cross-session memory 2026-04-29) |
| BTHPORT cache-clear procedure | NEEDS VERIFICATION | Session 15 path was a no-op; actual location must be re-discovered |
| Differential patch isolation framework | NOT BUILT | Required to isolate which of TF3's 4 structural variables breaks Apple's gesture engine |
| M13 production path | LIVE | Session 14 confirmed battery=24% via COL02, install permanent |
| M14 scroll translation | NEXT | RID=0x27 → RID=0x02 in WDF filter, blueprint = Linux `hid-magicmouse.c` |

---

## Activity Log

| Date | Update |
|------|--------|
| 2026-05-06 | Initial authoring. Companion to `SESSION-16-GHIDRA-DESCRIPTOR-TRACE.md`. Folds Session 16 RE findings into the empirical/test plan; reconciles M13-V3 patch attribution; consolidates the Session 15 morning vs evening narrative; lists open empirical questions for any future PATH-A retry. |
