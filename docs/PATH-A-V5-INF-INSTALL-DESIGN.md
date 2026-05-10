---
title: PATH-A v5 — INF-Based Install Refactor (SUPERSEDED — INF path empirically dead, pivoted to direct-copy)
type: design
date: 2026-05-09
version: 1.2.0
status: SUPERSEDED — pnputil INF install path failed CI HashMismatch on Win11 26200 (2026-05-09 21:15:48). Forward path is Session 19's signtool re-sign + PATCH-APPLE-SYS direct-copy. See docs/PATH-A-V5-CI-HASHMISMATCH-FINDING.md.
linked_prd: PRD-184 v1.31.0
linked_psn: PSN-0001 v2.4.0
linked_review: .ai/peer-reviews/2026-05-09-pathA-v5-sre-windows-review.yaml
linked_static_analysis: docs/PATH-A-V5-F2-STATIC-ANALYSIS.md
linked_user_checklist: docs/PATH-A-V5-WINDOWS-USER-CHECKLIST.md
supersedes: PATH-A-V3-BSOD-RCA.md (root cause), PATH-A-SIGNING-DIVERGENCE.md (resolves divergence)
---

> **CRITICAL UPDATE 2026-05-09 (SRE-Windows independent review):** the v1.0.0 plan
> below proposed installing via INF with v3-only Hardware ID binding while reusing
> Apple's stock service name `applewirelessmouse`. Independent /sre-windows review
> verdict: **REJECT** as written. Reason: service-name reuse means v1's stack
> still loads our patched binary via Apple's stock LowerFilter service spec —
> Hardware ID binding does NOT isolate the binary that the LowerFilter service
> resolves to. Plus WHQL ranking favors stock over our TrustedPublisher catalog.
>
> Structural fixes applied in this v1.1.0:
> - **S1**: rename our service to `MagicMouseFixV3` and binary to `MagicMouseFixV3.sys`
>   (separate from Apple's `applewirelessmouse` service — true v1 isolation).
> - **S2**: `startup-repair.ps1` updated to skip non-v3 PIDs (BSOD #2 trigger).
> - **S3**: install procedure now invalidates BTHPORT cache before /restart-device.
> - **S4**: install pre-flight refuses to proceed with Fast Startup enabled.
> - **S5**: post-install verification block confirms our INF actually bound, v1
>   actually isolated, service running, HID children OK.
>
> Windows-side empirical pre-tests REMAIN BLOCKING before any install attempt:
> see `docs/PATH-A-V5-WINDOWS-USER-CHECKLIST.md`.
>
> Static analysis E_S1 was completed: `docs/PATH-A-V5-F2-STATIC-ANALYSIS.md`. Key
> finding: no writer in this binary creates the {len=4, ptr=NULL} crash state, so
> the NULL must originate from BT-stack-side asynchronous buffer free or
> use-after-free. Structural fixes prevent v1 cross-fire (a known trigger) but
> do not eliminate the BSOD capability on v3 alone.
---

# PATH-A v5 — INF-Based Install Refactor

**BLUF**: Two BSODs (0x13A heap corruption 2026-05-07, 0xD1 NULL deref 2026-05-08) were NOT caused by the descriptor patch itself. PATH-A delivered battery successfully (Session 19 PacketLogger: `[90 04 28 ...]` = 40% buf[2] single-shot). The crash function `+0x9e60` is byte-identical between stock and patched binaries. Root cause is **install-mechanism + lifecycle disruption + cross-binding to v1 hardware**. Three independent reviewers (NLM fresh, general-purpose Sonnet, Gemini Pro 2.5) converged on the same fix from different causal stories.

## Empirical facts

| Fact | Source |
|---|---|
| Patched driver delivered battery 40% single-shot | Session 19 PacketLogger 2026-05-08 |
| Crash function `+0x9e60`..`+0x9f33` is byte-identical between stock and patched | Patch only modified `.data` at offset 0xA850; crash is in `NONPAGE` section |
| 4-byte magic `A1 13 00 83` checked at +0x9f0e is NOT in our descriptor | Existing rev-eng byte search |
| Crash function is registered as IOCTL 0x410003 completion callback (NOT SDP injection) | Disasm line 8629 + Session 16 F2 trace |
| `[rsi+0x88]` is BRB payload buffer ptr, paired with length at `[rsi+0x84]` | Existing rev-eng + multiple populator paths in F2 |
| Stock Apple code defensively null-checks `rsi` but NOT `[rsi+0x88]` | `+0x9eec`..`+0x9f0e` in disasm |
| Apple's stock OEM `oem10.inf` binds applewirelessmouse to ALL Apple Magic Mouse PIDs (030D, 0310, 0269, 0323) | DriverStore enum |
| Patched binary was deployed via DIRECT FILE COPY, not pnputil INF install | patch-apple-* logs |
| Magic Mouse Tray startup-repair ran v3-only LowerFilter dance on v1 (PID 030D) at 16:01:57 — failed | MMT startup-repair.log |
| BSOD #2 fired 14 minutes after that failed v1 repair | Event Log 41 + 1001 |

## Three-reviewer convergent fix recommendations

| Step | NLM | Sonnet | Gemini |
|---|---|---|---|
| Install via INF (not direct copy) | ✓ | ✓ | ✓ |
| v3-only Hardware ID binding | ✓ | ✓ | ✓ |
| v1 stays on stock filter or none | ✓ | ✓ | ✓ |
| Fix startup-repair to skip v1 | implied | ✓ | implied |
| Preserve WHQL Authenticode overlay | implied | ✓ | implied |

## Design — PATH-A v5 Bundle

Mirrors `MagicMouse2DriversWin11x64-master` reference project structure exactly.

### Bundle artifacts

```
dist/PATH-A-v5/
├── AppleWirelessMouse.inf      # v3-only Hardware ID binding (PID 0x0323)
├── AppleWirelessMouse.sys      # 78,424 B with WHQL overlay INTACT, descriptor patched at 0xA850
├── applewirelessmouse.cat      # Regenerated to hash patched .sys, signed with M14 cert
├── MagicMouseFix.cer           # M14 public cert for recipients to install in TrustedPublisher
├── install.ps1                 # pnputil-driven install with pre-flight checks
├── uninstall.ps1               # Clean rollback
└── README.md                   # User-facing install instructions
```

### Critical file integrity

| File | MD5 | Size | Notes |
|---|---|---|---|
| Source unsigned (already exists) | `0d9a89d08ccc89f46f47775e72c80d7b` | 78,424 B | At `/mnt/c/mm-dev-queue/AppleWirelessMouse.sys` — descriptor patched, WHQL overlay intact |
| Stock | `f4ae407c228c3db6147d9e3307ed5f20` | 78,424 B | Apple WHQL — must NEVER be in production-mismatch |
| **DO NOT USE**: c881c041 (66,288 B) | direct-resigned, WHQL stripped | — | Per D-S17-03; this was the BSOD'd variant |

### INF binding — v3-only

```ini
[Manufacturer]
%Apple%=Apple,NTamd64.10.0...26100

[Apple.NTamd64.10.0...26100]
; ONLY v3 — explicitly NOT v1 (030D), NOT 0310, NOT v2 (0269)
%AppleWirelessMouse.DeviceDesc%=AppleWirelessMouse, BTHENUM\{00001124-0000-1000-8000-00805f9b34fb}_VID&0001004c_PID&0323
```

(Existing INF at `/mnt/c/mm-dev-queue/AppleWirelessMouse.inf` already has v3-only binding — verified.)

### Install procedure

1. **Pre-flight (T0 read-only)**:
   - `gather-telemetry.ps1 -Label "pre-pathA-v5"` — full state snapshot
   - Verify stock binary in System32: MD5 = f4ae407c
   - Verify no patched binary already in DriverStore (check `applewirelessmouse.inf_amd64_*` folders)
   - Verify MagicMouseFix cert in TrustedPublisher

2. **DriverStore cleanup (T1, requires admin)**:
   - `pnputil /enum-drivers | grep applewirelessmouse` — identify ALL existing oem*.inf for applewirelessmouse
   - Delete stale ones (e.g., 556b5cec8 from 04-30 failed patch per D-S17-08)
   - **Decision pending /sre-windows review**: should we delete `oem10.inf` (Apple's stock OEM) entirely, or leave it active for v1?

3. **Install (T2, requires admin)**:
   - `pnputil /add-driver C:\dist\PATH-A-v5\AppleWirelessMouse.inf /install`
   - Verify oem<NN>.inf published name in DriverStore
   - `pnputil /enum-drivers | grep MagicMouseFix` — confirm signer is M14 cert

4. **Bind to v3 device**:
   - On the BTHENUM v3 instance, set LowerFilters = applewirelessmouse via INF (automatic from /install)
   - `pnputil /restart-device <BTHENUM v3 instance ID>`
   - Verify COL01 + COL02 enumerate
   - `HidD_GetInputReport(0x90)` returns battery in buf[2]

5. **Patch startup-repair.ps1 to detect v1 and skip**:
   - Read PID from BTHENUM Hardware ID at entry
   - If PID == 0x030D (v1) or 0x0269 (v2): log "v1/v2 already works via stock filter, skipping repair" and return
   - Only run the LowerFilter dance for v3 (PID 0x0323)
   - Commit on `ai/m4-startup-repair-pid-detect` branch

6. **Post-install verification**:
   - `gather-telemetry.ps1 -Label "post-install-immediate"`
   - Cursor + scroll + battery test (3 acceptance criteria)
   - 24h soak: `gather-telemetry.ps1` every 4h
   - Stress: BT idle disconnect + reconnect cycle, sleep+wake, hibernate+wake

### Rollback (any failure)

1. `pnputil /delete-driver <oem<NN>>.inf /uninstall /force` — removes our INF binding
2. `pnputil /restart-device <BTHENUM v3 instance ID>` — rebinds to stock oem10.inf
3. `gather-telemetry.ps1 -Label "post-rollback"` — verify stock f4ae407c is loaded
4. If kernel-locked: `RESTORE-STOCK` task runner route + reboot

## Open questions for /sre-windows independent review

1. **DriverStore precedence**: when both `oem10.inf` (Apple's stock, binds 030D/0310/0269/0323) and our v3-only INF exist in DriverStore, which one wins for PID 0x0323? Driver ranking? Date-based? Should we delete `oem10.inf`?

2. **v1 isolation**: with our v3-only INF + stock `oem10.inf` both present, will v1 (PID 030D) bind to the patched filter via `oem10.inf`? Or does PnP's "best match" mean v3 takes our INF and v1 takes oem10? Need empirical confirmation before install.

3. **WHQL overlay corruption tolerance**: NLM-F3 prior finding (2026-05-08) flagged that an Authenticode-signed PE with mismatched bytes (descriptor patched but Microsoft WHQL signature still attached) might trigger Windows Code Integrity to hard-block before falling back to our `.cat`. Has the reference project (`MagicMouse2DriversWin11x64-master`) actually shipped a binary in this state without issue, or do they patch the cat differently? Empirical CI behavior on this combination is the gate-zero question.

4. **BTHPORT SDP cache**: when v3 mouse re-pairs after install, does `HKLM\SYSTEM\...\BTHPORT\Parameters\Devices\<MAC>\Cache` need explicit invalidation, or does fresh SDP exchange overwrite it cleanly? Prior tests showed cached descriptors can outlive driver replacement.

5. **Race condition concern**: NLM said multi-TLC concurrency exposes a race in Apple's filter; Sonnet said the bug is latent NULL-deref in stock code triggered by lifecycle events. Both can be true. Even with v3-only INF install, restart-device cycles still trigger the same code paths. Is there empirical evidence that v3 alone (with proper INF install, no v1 cross-fire) does NOT BSOD over a 72h soak?

6. **startup-repair.ps1 v1-detection logic**: the simplest v1-detection branches on PID. Are there edge cases (re-pair, MAC reuse, device replacement) where PID detection would fail or misroute? Should we use Hardware ID matching instead?

7. **Reference-project behavior**: when MagicMouse2DriversWin11x64-master is installed on a system with v1+v3 mice present, does it cleanly bind only to its target hardware, or does it cause issues on non-target Magic Mouse variants? Their INF claims which PIDs?

## Acceptance criteria (must pass before public distribution)

- [ ] Pre-install gather-telemetry produces baseline snapshot
- [ ] `pnputil /add-driver` succeeds, oem published name recorded
- [ ] v3 mouse: cursor + scroll + battery (40-100% range, single-shot read, no GLE=121 retry)
- [ ] v1 mouse (paired alongside v3): cursor + scroll + battery via Feature 0x47 still works (control test)
- [ ] startup-repair.ps1 with v1 detection: PID 030D → skip, PID 0323 → run
- [ ] BT idle disconnect + reconnect: battery readable on next read attempt, no BSOD
- [ ] Sleep + wake: cursor/scroll/battery survive
- [ ] Hibernate + wake: cursor/scroll/battery survive
- [ ] Full restart (Fast Startup OFF): cursor/scroll/battery survive
- [ ] 24h soak: zero BSODs, telemetry log clean
- [ ] 72h soak: zero BSODs, no heap-corruption-prone state
- [ ] Rollback procedure validates clean recovery to stock
- [ ] User-facing README + install.ps1 + uninstall.ps1 produce correct end-state

## References

- `Personal/prd/184-magic-mouse-windows-tray-battery-monitor.md` v1.31.0 (D-S17-21..25)
- `Personal/magic-mouse-tray/PSN-0001-hid-battery-driver.yaml` (H-029 — to be added)
- `Personal/magic-mouse-tray/.ai/peer-reviews/2026-05-09-*.yaml` (3 peer reviews)
- `Personal/magic-mouse-tray/docs/PATH-A-V3-BSOD-RCA.md` (original RCA, scope superseded)
- `Personal/magic-mouse-tray/docs/PATH-A-SIGNING-DIVERGENCE.md` (resolved by v5 — sign only .cat)
- `Personal/magic-mouse-tray/docs/SESSION-19-V3-BUF2-CONFIRMED-2026-05-08.md` (PATH-A working evidence)
- `Personal/magic-mouse-tray/.ai/rev-eng/08f33d7e3ece/disasm.txt` (full applewirelessmouse.sys disasm)
- `Personal/magic-mouse-tray/scripts/gather-telemetry.ps1` (single-shot evidence collector)
- `Personal/magic-mouse-tray/scripts/correlate-timeline.py` (timeline unifier)
- Reference project: `D:\Users\Lesley\Downloads\MagicMouse2DriversWin11x64-master\AppleWirelessMouse\` (canonical INF/cat pattern, .sys MD5 f4ae407c — IDENTICAL to stock)
