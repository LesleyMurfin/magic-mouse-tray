# MagicKbDesc — Apple Keyboard HID Descriptor Patcher

KMDF lower filter that patches the HID Report Descriptor returned by `hidbth.sys` so Windows' HID class driver knows that RID `0x47` (Battery Strength) on Col02 of an Apple keyboard is **also** a Feature report — not just an Input report. The 4-byte patch unblocks `HidD_GetFeature(0x47)` from userland.

## Why a 4-byte patch is enough

The keyboard firmware happily responds to `GET_REPORT(Feature, RID=0x47)` over L2CAP — proven by:
1. macOS's PacketLogger capture: `host→kbd 43 47` → `kbd→host A3 47 NN` (NN = battery %)
2. Empirical Windows test 2026-05-08: `HidD_GetFeature(Col03, RID=0x09, len=4)` succeeds with real bytes `[92 12 02 02]`. Same L2CAP path; RID `0x09` IS declared as Feature.

The only thing that prevents `HidD_GetFeature(Col02, RID=0x47)` from working today is `hidclass.sys`'s descriptor validation: RID `0x47` is declared in the public Apple descriptor as Input only (`81 02`), so userland callers are rejected with `ERROR_INVALID_FUNCTION (1)` before the bytes ever go on the wire.

This driver intercepts `IOCTL_HID_GET_REPORT_DESCRIPTOR`, finds the `... 81 02 c0 c0` tail of Col02, and inserts `09 20 B1 02` (re-emit Battery Strength Usage + Feature Main item with the same global state). After the patch, `hidclass.sys` parses RID `0x47` as both Input and Feature; `HidD_GetFeature(0x47)` succeeds.

## Files

| File | Purpose |
|------|---------|
| `MagicKbDesc.inx` | INF source — bound to `BTHENUM\{...}_VID&000205AC_PID&{0239,0255,022C,022D,022E,0267,029A,029C,029F,0320,0321,0322}` (whole Apple keyboard whitelist from PRD-185) |
| `Driver.c` | `DriverEntry` + `EvtDriverDeviceAdd` (registers as filter via `WdfFdoInitSetFilter`) |
| `Descriptor.c` | The patch logic + IRP completion routine for `IOCTL_HID_GET_REPORT_DESCRIPTOR` |
| `MagicKbDesc.h` | Common types + IOCTL constants |
| `MagicKbDesc.vcxproj` | MSBuild project for EWDK 10.0.26100 |
| `MagicKbDesc.sln` | Solution wrapper |
| `build.cmd` | EWDK msbuild → recover .sys → stamp INF → Inf2Cat. Stages to `C:\Windows\Temp\MagicKbDescStage\`. |
| `sign.ps1` | Signs `.sys` + `.cat` via mm-task-runner SIGN-FILE route (SYSTEM context, M12 `CN=MagicMouseFix` cert in `LocalMachine\My`). |
| `install.ps1` | `pnputil /add-driver` via mm-task-runner INSTALL-DRIVER route. `-Uninstall` switch removes. |
| `restart-device.ps1` | `pnputil /restart-device` via mm-task-runner RESTART-DEVICE route. Forces PnP to re-evaluate driver bindings without a BT toggle. |
| `test.ps1` | Smoke test — `HidD_GetFeature(Col02, RID=0x47, len=2)`. Expected: `*** SUCCESS *** [47 NN]   BATTERY = NN%`. |
| `troubleshoot.ps1` | Comprehensive diagnostic dump: driver-store status, PnP stack, all HID caps, raw descriptor (looks for the `09 20 B1 02` patch bytes), signature on installed `.sys`, recent System event log. **Run this if `test.ps1` fails.** |

## Build prerequisite

EWDK ISO mounted at `F:\Program Files\Windows Kits\10\` (already configured for the M12 pipeline). The `BUILD` route in `mm-task-runner.ps1` handles ISO mount auto-detection.

## Install (production trust path — no `bcdedit`)

Open Admin PowerShell. From the `driver-keyboard/` directory:

```powershell
.\build.cmd          # EWDK msbuild + stamp + cat → C:\Windows\Temp\MagicKbDescStage\
.\sign.ps1           # SYSTEM-context sign with M12 cert
.\install.ps1        # pnputil /add-driver via SYSTEM
.\restart-device.ps1 # force re-bind (alternative: toggle BT off/on in Settings)
.\test.ps1           # HidD_GetFeature(0x47) — expect SUCCESS with battery %
```

If anything fails:

```powershell
.\troubleshoot.ps1   # full diagnostic dump
```

To uninstall:

```powershell
.\install.ps1 -Uninstall
```

After install, toggle Bluetooth off/on in Settings — the new lower filter binds during re-enumeration. Verify:

```powershell
Get-PnpDeviceProperty -InstanceId 'BTHENUM\{00001124-...}_VID&000205AC_PID&0239\...' `
    -KeyName DEVPKEY_Device_Stack
# Expect: \Driver\HidBth, \Driver\MagicKbDesc, \Driver\BthEnum
```

Then the empirical proof:

```powershell
pwsh -File ..\scripts\Test-HidD-GetFeature-0x47.ps1
# Expect: *** SUCCESS *** bytes: [47 NN]   where NN is battery %
```

## Install (dev — test signing during iteration)

If iterating the driver source, save a build cycle by reusing the M12 `bcdedit /set testsigning on` state from prior driver work. Reverts to production signing once the source stabilises.

## Uninstall

```powershell
pnputil /enum-drivers | findstr /I MagicKbDesc
pnputil /delete-driver oemNN.inf /uninstall /force
```

## Status

**SCAFFOLD ONLY.** Source files compile but the byte-search-and-patch logic is stubbed at `// TODO: patch logic`. Next slice fills in:
1. Searching the descriptor buffer for the `... 81 02 c0 c0` Col02 tail
2. Reallocating the buffer with 4 extra bytes
3. Inserting `09 20 B1 02` at the right offset
4. Updating `Irp->IoStatus.Information` to reflect the new size
5. Forwarding completion up the stack

See PR description + `docs/M4-MAC-CAPTURE-FINDINGS-2026-05-08.md` for the full architectural rationale.
