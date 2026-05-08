---
title: Post-Reboot Recipe — MagicKbDesc Install Validation
type: runbook
status: active
date: 2026-05-08
---

# Post-Reboot Recipe — MagicKbDesc Install Validation

**Why we're here:** SCM marked the `MagicKbDesc` service for deletion mid-session (`sc create FAILED 1072`). Reboot flushes the kernel SCM state.

## Two scripts. That's it.

### Before reboot — sanity check

```powershell
powershell.exe -ExecutionPolicy Bypass -File "<repo>\driver-keyboard\pre-reboot-checkpoint.ps1"
```

Walks the staging dir, driver-store, pnputil enum, service state, device LowerFilters, and worktree branch. Prints `[OK]` / `[FAIL]` per row. Green-light = safe to reboot.

### Reboot.

### After reboot — full validation

```powershell
powershell.exe -ExecutionPolicy Bypass -File "<repo>\driver-keyboard\post-reboot-validate.ps1"
```

Runs end-to-end:
1. SCM clean check
2. INSTALL-DRIVER (with auto-fallback to UNINSTALL+reinstall if pnputil reports `Added: 0`)
3. Verify service ImagePath
4. Force-load driver, confirm `driverquery` lists it
5. **Pauses for you to toggle BT off/on in Settings**
6. Reads `DEVPKEY_Device_Stack` — `MagicKbDesc` should appear in chain
7. Runs `test.ps1` — expects `*** SUCCESS *** [47 NN] BATTERY = NN%`

If step 6 fails: B3 architectural premise falsified. Script writes a diagnosis log to `C:\mm-dev-queue\diag-postrb-*.log` (setupapi entries + system events) and exits non-zero.

## State that survives the reboot (no rebuild needed)

| Asset | Location |
|---|---|
| Code-fix commit | branch `ai/m4-kbd-inf-fix-final`, HEAD `8a1f4af` |
| PR | https://github.com/ReviveBusiness/magic-mouse-tray/pull/41 |
| Built `.sys` | `\\wsl.localhost\Ubuntu\home\lesley\.claude\worktrees\ai-m4-kbd-inf-fix-final\driver-keyboard\x64\Release\MagicKbDesc.sys` (MD5 `e11d8b97660d6b9324e82225c37201c0`) |
| Signed catalog staging | `C:\mm-dev-queue\kbd-stage-kbd-stage-1778263483\` |
| Driver-store published | `C:\Windows\System32\DriverStore\FileRepository\magickbdesc.inf_amd64_19830858ec72e2ad\` (oem57.inf, MagicMouseFix M14 cert) |
| Runner phases (used by validate script) | `D:\mm3-driver\scripts\mm-task-runner.ps1` (canonical at `Personal/magic-mouse-tray/scripts/mm-task-runner.ps1`, uncommitted) |

## Memory-cached facts

- Apple A1314 keyboard instance ID: `BTHENUM\{00001124-0000-1000-8000-00805F9B34FB}_VID&000205AC_PID&0239\9&73B8B28&0&E806884B0741_C00000000`
- HidBth driver class instance: `{745A17A0-74D3-11D0-B6FE-00A0C90F57DA}\0003`
- M14 cert thumbprint: `16940C0F937D569363560D5FEC5CD8FA6D6D9BCE`

## What success looks like

`post-reboot-validate.ps1` prints `*** SUCCESS *** [47 NN] BATTERY = NN%` at the end. M2 closes. After that:
1. Update PSN-0002 with the empirical evidence
2. Update PRD-185 M2 status → DONE
3. Open separate PR for runner-helper phases (`ai/m4-runner-build-kbd-helpers`)
4. Comment test result on PR #41 + `merge-pr --gate`
5. Move to M4 (24h soak with DRIVER_VERIFIER)

## Activity Log

| Date | Update |
|---|---|
| 2026-05-08 | Hit SCM-marked-for-deletion block during install iteration; pre/post-reboot scripts written; reboot pending. |
