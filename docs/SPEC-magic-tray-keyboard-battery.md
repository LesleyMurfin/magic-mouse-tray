# Spec: magic_tray — Keyboard Battery + Public Deployment

> Status: **DRAFT — Phase 1 (Specify), awaiting human review.** Do not advance to PLAN/TASKS/IMPLEMENT until approved.
> Authored: 2026-06-25. Source of truth verified against `projects/apple-peripherals/magic-mouse-tray` @ `main` (25e6a7a).
> **Update 2026-06-25:** M-KB1 hardware gate **CLOSED** — keyboard battery read live on Windows (see Empirical Verification below).

## Empirical Verification — M-KB1 (2026-06-25)

The patch + reboot-free re-read mechanism is now proven end-to-end on the live PC (`LESLEYS-PC`, Win 10.0.26200), with byte evidence (RULE #2):

1. **Patch applied & persists:** `HKLM\...\BTHPORT\Parameters\Devices\e806884b0741\{CachedServices,DynamicCachedServices}\00010000` = **458 bytes, contains `09 20 B1 02`**.
2. **Reboot-free re-read mechanism (the crux of "forever"):** `Disable-PnpDevice` returns `Not supported` on both the keyboard and radio nodes, but **`pnputil /remove-device "<HID node>"` + `pnputil /scan-devices`** (elevated) rebuilds the node and forces BTHPORT to re-read the patched cache. HID node = `BTHENUM\{00001124-0000-1000-8000-00805F9B34FB}_VID&000205AC_PID&0239\9&73B8B28&0&E806884B0741_C00000000`.
3. **Remove/scan does NOT un-pair or erase the patch:** POST-state still 458 bytes with marker present; keyboard re-enumerated (Status OK).
4. **col02 became readable:** `FeatureLen` flipped `0 → 2`; `Feature ValueCap[0]: RID=0x47 UP=0x0006 U=0x0020 BitSize=8`.
5. **Live battery read:** `HidD_GetFeature(0x47)` returned `[47 0E]` (raw value `0x0E`). Before the patch, RID 0x47 returned nothing across 6,859 attempts.

**Open calibration item:** raw `0x0E = 14`. Likely 14%, but the value cap declares `LogMax=255` — cross-check against a second/macOS reading before hardcoding `pct = fbuf[1]`.

## Objective

Make the tray app reliably display **Apple Wireless Keyboard (A1314, PID 0x0239)** battery on Windows 11, alongside the already-working Magic Mouse, and rebrand the unified product to **magic_tray**, packaged for public download.

**Why:** The keyboard battery report (RID `0x47`, Usage Page `0x0006` / Usage `0x0020` "Battery Strength") is declared on COL02 but is **Input-only and unreadable** in the device's native descriptor — verified empirically this session: 2.5 days / 6,859 consecutive `KB_MONITOR_TIMEOUT`, zero reads, and a full 255-RID active sweep returned no battery hit. The battery becomes readable **only after** the BTHPORT `CachedServices` SDP cache is patched to expose RID `0x47` as a **Feature** report (`kbd-patch-cachedservices.ps1` inserts `09 20 B1 02` at the COL02 close). That patch is erased by any un-pair/re-pair (safety-review Finding 6), so it must be auto-detected and re-applied.

**User:** Windows 11 owner of an Apple Magic Mouse and/or Apple Wireless Keyboard who wants a free battery indicator without a paid subscription.

**Success looks like:** After a one-time elevated install, the tray shows a live keyboard battery % that survives reboot and re-pair (auto-re-patched), with no recurring UAC prompts.

## Tech Stack

- **App:** C# / .NET 8 (`net8.0-windows10.0.17763.0`), WPF + WinForms `NotifyIcon`, single-file self-contained `win-x64` publish. NuGet: `HidLibrary 3.3.40`.
- **Patch mechanism:** PowerShell (`kbd-patch-cachedservices.ps1`) writing `REG_BINARY` under `HKLM\SYSTEM\...\BTHPORT\Parameters\Devices\<mac>\CachedServices` + `DynamicCachedServices`, then BT disable/enable to force re-read.
- **Elevation model (DECIDED):** One-time elevated installer registers a **SYSTEM-level Scheduled Task** that runs the patch-check at logon and on BT-device-connect. The tray itself runs **non-elevated**.
- **Rebrand (DECIDED, IN SCOPE):** `magic-mouse-tray` → `magic_tray` (assembly name, namespace, README, icon, `%APPDATA%` log path, GitHub repo references).

## Commands

```powershell
# Build (single exe)
dotnet publish -c Release
#   Output: bin\Release\net8.0-windows10.0.17763.0\win-x64\publish\magic_tray.exe   (post-rename)

# Restore-only on WSL/Linux (EnableWindowsTargeting=true allows this)
dotnet restore

# Patch verify (read-only / dry-run, no registry writes)
powershell -ExecutionPolicy Bypass -File scripts\kbd-patch-cachedservices.ps1 -DryRun

# Probe live battery state (read-only descriptor dump + RID sweep)
powershell -ExecutionPolicy Bypass -File scripts\kbd-battery-probe.ps1
```

## Project Structure

```
MagicMouseTray/        → C# app source (to be renamed magic_tray/ per rebrand)
  IBatteryDevice.cs       → device abstraction (already has DeviceKind.MagicKeyboard)
  KeyboardBatteryDevice.cs→ REWRITE: active GetFeature read (currently passive ReadFile)
  MouseBatteryReader.cs   → reference implementation for the active read path
  DeviceRegistry.cs       → already discovers keyboards on COL02
  TrayApp.cs              → already multi-device (per-device alerts/menu/icon)
  Config.cs / AdaptivePoller.cs / ToastNotifier.cs / CriticalAlert.cs
scripts/
  kbd-patch-cachedservices.ps1 → the CachedServices SDP patch (wrap, don't rewrite)
  kbd-battery-probe.ps1        → read-only verification probe
docs/
  SPEC-magic-tray-keyboard-battery.md → this file
  bthport-patch-safety.md (.ai/code-reviews/) → safety review; constraints below
```

## Code Style

Match existing `MouseBatteryReader.cs`: SPDX header, P/Invoke shims at the bottom, structured single-line logs, sentinel returns. The keyboard read collapses to the mouse's already-proven "unified Feature" branch:

```csharp
// KeyboardBatteryDevice — active read after CachedServices patch exposes RID 0x47 as Feature.
const ushort UP_GENDEV_BATTERY = 0x0006;   // Generic Device Controls
const ushort USG_BATT_STRENGTH = 0x0020;   // Battery Strength

// On COL02: detect Feature value cap (UP=0x0006, U=0x0020); read it.
var fbuf = new byte[Math.Max(featureLen, 2)];
fbuf[0] = batteryReportId;                  // 0x47
if (HidD_GetFeature(handle, fbuf, fbuf.Length) && fbuf[1] is >= 0 and <= 100)
{
    Logger.Log($"KB_BATTERY_OK pct={fbuf[1]}% (Feature 0x{batteryReportId:X2})");
    return fbuf[1];
}
return -2;  // present but blocked → "patch needed" state (distinct from -1 not found)
```

Sentinels (keep existing convention): `-1` = device not found, `-2` = present but battery blocked (→ triggers patch-check), `0–100` = battery %.

## Testing Strategy

- **Unit (`tests/`, existing xUnit-style C#):** SDP TLV patch arithmetic — given a known `CachedServices` blob, assert the 4 length fields increment by 4 and `09 20 B1 02` lands between `81 02` and `c0 c0`. Use the captured real blob as a fixture.
- **PowerShell `-DryRun`:** patch script must produce a byte-correct patched blob without touching the registry; diff against an expected fixture.
- **Manual hardware acceptance (the gate):** on the live PC — patch applied → BT toggle → `kbd-battery-probe.ps1` shows `HIT GetFeature RID=0x47` with a plausible % → tray displays it. Recorded with the actual byte evidence (RULE #2).
- **Re-pair regression:** un-pair/re-pair keyboard → confirm patch is detected gone and re-applied by the Scheduled Task → battery returns without manual steps.

## Boundaries

- **Always:** back up the original `CachedServices` blob before any write (script already does); record empirical byte evidence for every "it works" claim; keep the rename mechanical and separate-commit from logic changes; follow `/change-management` for the registry write.
- **Ask first:** applying the registry patch on the live machine (it mutates `HKLM\SYSTEM` — RULE #21); adding NuGet/driver dependencies; changing the SDP TLV parser to handle 2-byte inner lengths; choosing the distribution/signing approach.
- **Never:** ship a fixed-offset patcher that can't validate the blob structure (safety Finding 2); write the patch without an elevation/preflight check (Finding 4); silently truncate or skip the backup; commit to `main` of any repo without an explicit go-ahead.

## Success Criteria

1. On a clean machine, one elevated install → reboot → tray shows keyboard battery % within 60s, no UAC prompt at login.
2. Un-pair + re-pair the keyboard → battery reappears automatically (auto-re-patch) within one logon/connect cycle, no manual script run.
3. `KeyboardBatteryDevice.cs` performs an **active** `HidD_GetFeature(0x47)` read; `KB_BATTERY_OK` appears in the log with a real %.
4. App, exe, README, icon, and log path all read **magic_tray** (no "Magic Mouse" branding in keyboard-facing UI).
5. Patch path passes the safety-review conditions: backup-first, TLV-aware length updates, elevation preflight, re-pair re-patch detection.
6. Distributable artifact (GitHub Release `.exe` + installer) runs on Win10 1809+ / Win11 x64.

## Open Questions

1. **Canonical working copy** — three `magic-mouse-tray` checkouts exist (`projects/apple-peripherals`, `projects/Revive_Labs`, `orca/workspaces`). Which is the source of truth for implementation + the GitHub repo to publish?
2. **Keyboard model scope** — battery read is verified only for A1314 (0x0239). Ship keyboard battery for the verified model only, or attempt the other `KnownKeyboards` (Magic Keyboard A1644 / Touch ID) untested?
3. **MAC discovery** — patch script defaults to the hardcoded MAC `e806884b0741`. Production must discover the paired keyboard's MAC dynamically; confirm the discovery source (BTHENUM instance path parse).
4. **Distribution/signing** — GitHub Releases Win32 installer assumed (MS Store ruled out by `HKLM\SYSTEM` writes). Code-signing cert: reuse `CN=MagicMouseFix`, or acquire a real OV/EV cert to reduce SmartScreen/AV friction (safety Finding 8)?
5. **Driver fallback** — keep the registry-patch approach only, or note `driver-keyboard/MagicKbDesc` as the migration target if AV-flagging proves fatal for distribution?

## Plan / Tasks (DRAFT — not active until spec approved)

- **M-KB1 — On-PC verification (change-managed): ✅ DONE 2026-06-25.** Patch applied (458 bytes, marker present) → re-read forced via `pnputil /remove-device` + `/scan-devices` (NOT `Disable-PnpDevice`, which is `Not supported` here) → `GetFeature RID=0x47` returned `[47 0E]`. See Empirical Verification above.
- **M-KB2 — Active read rewrite: 🟡 CODE COMPLETE 2026-06-26 (live-run pending).** `KeyboardBatteryDevice.cs` rewritten: passive monitor removed; now does a synchronous `HidD_GetFeature(0x47)` on col02 (detect Feature ValueCap UP=0x0006/U=0x0020 → read → `pct=fbuf[1]`), reusing shared `HidNative`. Returns `-2` ("present but blocked → patch needed") when the Feature cap is absent. `dotnet build -c Release` → 0 warnings/0 errors. **Remaining:** publish + run on the live PC to capture `KB_BATTERY_OK` from the new code (Success Criterion 3); unit-test patch arithmetic.
  - Branch: `LesleyMurfin/magic-tray-keyboard-battery` in `orca/workspaces/magic-mouse-tray/magic-mouse-tray` (worktree off `projects/apple-peripherals/magic-mouse-tray` @ main 25e6a7a).
- **M-KB3 — Auto-re-patch + reboot-free re-read:** SYSTEM Scheduled Task + non-elevated tray detection of `-2` state → trigger re-patch (backup-first, TLV-aware, elevation preflight) then force re-read via the proven `pnputil /remove-device "<HID node>"` + `/scan-devices` sequence.
- **M-KB4 — Installer + Scheduled Task registration:** one-time elevated install path.
- **M-RB1 — Rebrand magic_tray:** mechanical rename (assembly, namespace, README, icon, log paths, repo refs) — separate commit.
- **M-DEP1 — Deployment hardening:** signing, SmartScreen guidance, GitHub Release, install/uninstall + rollback docs.
