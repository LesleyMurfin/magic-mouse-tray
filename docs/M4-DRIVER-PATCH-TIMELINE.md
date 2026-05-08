---
title: M4 — Apple Keyboard Descriptor Patcher Engineering Timeline
type: engineering-log
status: in-progress
linked_prd: PRD-185
linked_psn: PSN-0002
created: 2026-05-08
last_updated: 2026-05-08
---

# M4 — MagicKbDesc Engineering Timeline

> Engineering log for the kernel-mode HID descriptor patcher that unblocks `HidD_GetFeature(0x47)` for Apple Wireless Keyboards on Windows. Compact, dated, end-to-end. Used as the ground truth for PRD-185 release notes (M5).

---

## 2026-05-07 — Empirical phase

### Userland Python attempt — failed

Plan `/home/lesley/.claude/plans/i-want-you-to-snug-papert.md` originally treated the userland Python port of `litteulapi/apple-kb-monitor` as M0–M3 and the kernel path as M8 contingency.

Discovery on first hardware run:

- `hid.enumerate(0x05AC, 0x0239)` returns the keyboard with collections `Col01..Col04`. Discovery works.
- `HidD_GetFeature(Col02, RID=0x47, len=2)` returns `ERROR_INVALID_FUNCTION (1)` — the call is rejected by `hidclass.sys` before ever hitting the wire. Reason: the stock Apple HID descriptor declares RID `0x47` only as `Input` (`81 02`); `hidclass.sys` refuses `Feature` GET_REPORT for an Input-only RID.
- `HidD_GetFeature(Col03, RID=0x09, len=4)` succeeds with `[92 12 02 02]`. RID `0x09` *is* declared as `Feature` in Col03. This proves the Windows BT HID stack *can* issue Feature GET_REPORTs over the BT HID-Control PSM — the firmware is reachable; only the parse classification is in the way.

### macOS L2CAP capture — proves the firmware

Ran macOS PacketLogger (Bluetooth Explorer in Apple's Additional Tools) while reading battery from System Information.app:

```
host → kbd : 43 47          # GET_REPORT(Feature, RID=0x47), L2CAP PSM 0x11
kbd → host : A3 47 C2       # DATA(Feature, RID=0x47, payload=0xC2)
                            # 0xC2 = 194 / 255 ≈ 0.76; ranged 0..100 = 65%
```

`0xC2` matches the known battery state at capture time (≈65%). Wire decoded; firmware confirmed.

### Userland L2CAP attempt on Windows — rejected

Tried `WSAConnect` to PSM `0x11` from userland against the keyboard's BT MAC `E8:06:88:4B:07:41`. `connect()` returned `-1`, both error sources `0` (no `WSAGetLastError` and no `getaddrinfo` error). Windows BT stack holds exclusive ownership of HID PSMs once a device is paired. Userland L2CAP path is closed.

### Decision: kernel filter

Original M8 contingency becomes the only path. Plan's M0–M3 Python milestones are skipped entirely. Driver named `MagicKbDesc`. Lives in `driver-keyboard/`.

---

## 2026-05-07 — KMDF scaffold (PR #38)

`Driver.c`, `Descriptor.c`, `MagicKbDesc.h`. KMDF lower filter:

- `EvtDriverDeviceAdd` calls `WdfFdoInitSetFilter` — registers as filter, not function driver.
- Default IO queue routes `IOCTL_HID_GET_REPORT_DESCRIPTOR` to `Descriptor.c`.
- Implementation pending — scaffold-only commit.

---

## 2026-05-07 — Patch logic (later same day)

`Descriptor.c`:

```
1. Forward IOCTL_HID_GET_REPORT_DESCRIPTOR down the stack.
2. On completion (set completion routine):
   a. If status != STATUS_SUCCESS, pass through.
   b. Search the returned descriptor for the Col02 tail signature
      "... 81 02 c0 c0" (Input main item, then close logical, then close
      application).
   c. Allocate a new buffer with len + 4.
   d. Copy bytes [0 .. tail_offset).
   e. Insert "09 20 B1 02" — re-emit Battery Strength Usage + Feature Main
      with current Global state.
   f. Copy bytes [tail_offset .. end).
   g. Replace SystemBuffer pointer; update IoStatus.Information.
   h. Free the old buffer; complete the IRP.
```

Why `09 20 B1 02`:

- `09 20` — Local item: re-emit Usage `0x20` (Battery Strength) so the Feature Main below it carries the same Usage as the Input Main above.
- `B1 02` — Main item: `Feature` (`B1`), Data/Var/Abs (`02`). Same Logical Min/Max + Report Size + Report Count are inherited from Global state established before the original `81 02`. Net effect: RID `0x47` is now classified as both Input AND Feature without changing any byte counts elsewhere in the descriptor.

---

## 2026-05-08 — Build pipeline + INF + signing (PR #40)

### EWDK build via `mm-task-runner.ps1 BUILD`

The existing M12 EWDK pipeline at `mm-task-runner.ps1` already auto-mounts the EWDK ISO from `F:\BuildEnv\` and runs `msbuild MagicKbDesc.sln /p:Configuration=Release /p:Platform=x64`. Reused as-is. Output: `driver-keyboard\x64\Release\MagicKbDesc.{sys,cat,inf}`.

### INF (initial — function-driver-with-filter format)

```ini
[Manufacturer]
%ManufacturerName% = Standard,NTamd64.10.0...17763

[Standard.NTamd64.10.0...17763]
%DeviceDesc% = MagicKbDesc_Inst, BTHENUM\{...}_VID&000205AC_PID&0239
... (full Apple keyboard PID census 0x022C..0x0322)

[MagicKbDesc_Inst.NT]
Include      = input.inf, hidbth.inf
Needs        = HIDBTH_Inst.NT
CopyFiles    = MagicKbDesc_Files
LowerFilters = MagicKbDesc

[MagicKbDesc_Inst.NT.Services]
Include    = input.inf, hidbth.inf
Needs      = HIDBTH_Inst.NT.Services
AddService = MagicKbDesc, , MagicKbDesc_Service
```

Pattern matches the reference project `MagicMouse2DriversWin11x64-master` (canonical, empirically known to work).

### Signing — catalog only

Per `docs/PATH-A-SIGNING-DIVERGENCE.md`:

- Run `Inf2Cat /driver:<dir> /os:10_X64,Server10_X64` to generate `MagicKbDesc.cat` covering the `.sys` and `.inf` hashes.
- Sign the catalog with `signtool sign /sm /sha1 16940C0F937D569363560D5FEC5CD8FA6D6D9BCE /fd SHA256 /tr digicert /td SHA256 MagicKbDesc.cat`.
- Cert `CN=MagicMouseFix` (M14, created 2026-05-02) is in `LocalMachine\TrustedPublisher`.
- The `.sys` keeps its build-time signature; we never re-sign the `.sys` directly.

Service load proven on the same day: `sc start MagicKbDesc` returned `STATE: 4 RUNNING`. Kernel CI accepted the catalog. Signing is **not** the blocker.

---

## 2026-05-08 — Extension INF detour (rejected)

Mid-day attempt to convert the INF to an Extension INF:

```ini
[Version]
Class       = Extension
ClassGuid   = {e2f84ce7-8efa-411c-aa69-97454ca4cb57}
ExtensionId = {dc8e1bbf-1c8b-4d8a-8d3e-6dab4e7d9b41}
...

[MagicKbDesc_Inst.NT.HW]
AddReg = MagicKbDesc_HwAddReg

[MagicKbDesc_HwAddReg]
HKR,,"LowerFilters",0x00010008,"MagicKbDesc"
```

Rationale: Extension INFs are the modern PnP idiom and do not collide with Microsoft INFs in the driver-store rank.

Result: `pnputil /add-driver` succeeds, service registers, but `Get-PnpDeviceProperty -KeyName DEVPKEY_Device_Stack` does not list `\Driver\MagicKbDesc` after BT cycle. Setupapi log:

```
inf:    {Configure Driver Configuration: MagicKbDesc_Inst.NT}
inf:        No associated service.
```

Diagnosis: Extension INFs need an existing function-driver INF that exposes a binding contract on the device. `hidbth.inf` does not. Without that, the Extension's `LowerFilters` AddReg writes the value but PnP has no driver-package relationship to honor it during enumeration.

Reverted to canonical function-driver-with-filter format. INF in `driver-keyboard/MagicKbDesc.inx` on the worktree is back to the PR #40 / `main` shape (canonical pattern shown above).

Two stale driver-store entries to clear:
- `oem44.inf` (HIDClass-format, original PR #40) — uninstalled successfully.
- `oem57.inf` (Extension-format, mid-day attempt) — `pnputil /delete-driver oem57.inf /uninstall /force` returned `0x00000BC2` (reboot required). Reboot taken.

---

## 2026-05-08 — In progress: install on the canonical INF

Current state at end of session:

- Both stale entries cleared (`oem44` removed; `oem57` removed post-reboot).
- Manually-injected `LowerFilters` registry value at the device's `Device Parameters` key removed (so PnP starts from a clean state).
- Worktree `ai-m4-kbd-inf-fix-final` checked out with the canonical INF.
- Build artefacts at `C:\Windows\Temp\MagicKbDescStage\` from the PR #40 build are reusable for re-install (INF and `.sys` are unchanged from `main`).

Next steps (continuing this session):

1. `mm-task-runner.ps1 INSTALL-DRIVER` — `pnputil /add-driver MagicKbDesc.inf /install /force`.
2. BT toggle off/on in Settings (or `pnputil /disable-device` + `/enable-device` on the BTHENUM PDO if BT toggle does not trigger descriptor re-issue — H-006).
3. `Get-PnpDeviceProperty -KeyName DEVPKEY_Device_Stack` — expect `\Driver\HidBth, \Driver\MagicKbDesc, \Driver\BthEnum`.
4. `driver-keyboard/test.ps1` — expect `*** SUCCESS *** [47 NN]   BATTERY = NN%`.

---

## Open Items

- **H-006 — BT toggle vs PnP disable/enable**: don't yet know which is sufficient to force `IOCTL_HID_GET_REPORT_DESCRIPTOR` re-issue on this BT_Classic device. Trying BT toggle first.
- **DRIVER_VERIFIER soak**: M4 deliverable per PRD-185. Not yet run.
- **Tray client stack — A. C# vs B. Python**: M3 decision deferred until after M2 close-out (this session).
- **24h soak**: M4 in PRD-185. Pending M2 close.

---

## Files

| File | Purpose |
|---|---|
| `driver-keyboard/Driver.c` | KMDF entry, filter registration |
| `driver-keyboard/Descriptor.c` | Patch logic + IRP completion routine |
| `driver-keyboard/MagicKbDesc.h` | IOCTL constants + types |
| `driver-keyboard/MagicKbDesc.inx` | INF source (canonical function-driver-with-filter pattern) |
| `driver-keyboard/MagicKbDesc.vcxproj` + `.sln` | EWDK 10.0.26100 build |
| `driver-keyboard/build.ps1` | Wraps `mm-task-runner.ps1 BUILD` |
| `driver-keyboard/sign.ps1` | Wraps `mm-task-runner.ps1 SIGN-FILE` |
| `driver-keyboard/install.ps1` | `pnputil /add-driver /install` |
| `driver-keyboard/test.ps1` | `HidD_GetFeature(Col02, 0x47)` smoke test |
| `driver-keyboard/restart-device.ps1` | BT toggle / disable+enable helper |
| `driver-keyboard/troubleshoot.ps1` | Setupapi log + driver state capture |
| `Personal/prd/185-...md` | PRD |
| `PSN-0002-keyboard-descriptor-patcher.yaml` | Problem-Solution Note |
| `docs/PATH-A-SIGNING-DIVERGENCE.md` | Signing doctrine (catalog-only) |
| `docs/m4-bt-capture-findings.md` | macOS L2CAP wire decode |
