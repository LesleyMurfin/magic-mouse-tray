---
title: PATH-A Signing Divergence (Session 17/18)
type: technical-debt
status: open
created: 2026-05-08
linked_psn: PSN-0001
linked_prd: PRD-184
priority: P2-Urgent
owner: Lesley
---

# PATH-A Signing Divergence — Must Redo

**BLUF:** PATH-A was signed by re-signing the `.sys` directly with `MagicMouseFix` cert
`16940C0F...` (M14 cert), which **stripped the original Microsoft WHQL signature**
(78424 B → 66288 B). This works in testsigning mode but diverges from the canonical
reference-project pattern. **Must be redone correctly before any release.**

---

## Reference projects (canonical pattern)

Two public repos ship the same install structure; PATH-A v5 mirrors it.

| Repo | Notes |
|---|---|
| [`sbagirici/apple-magic-mouse-scroll-fix-windows`](https://github.com/sbagirici/apple-magic-mouse-scroll-fix-windows) | Scroll-only. Ships Apple's WHQL-signed `applewirelessmouse.sys` unmodified; install via PowerShell writing `LowerFilters` directly to the device Enum key (bypasses Apple's INF because it doesn't list MM2 PID `0x0323`). No patch, no test-signing. |
| [`tealtadpole/MagicMouse2DriversWin11x64`](https://github.com/tealtadpole/MagicMouse2DriversWin11x64) (local copy: `D:\Users\Lesley\Downloads\MagicMouse2DriversWin11x64-master`) | Same family. Ships INF + `.cat` + `.sys` bundle; install via `pnputil /add-driver`. |

The shared pattern: `.sys` byte-identical to Apple's stock except (in our case) the `.data` patch at `0xA850`; regenerated `.cat` signed with our cert; INF declares `LowerFilters`; install via `pnputil`. Neither reference project re-signs the `.sys` directly.

## Reference Pattern (Canonical) — `D:\Users\Lesley\Downloads\MagicMouse2DriversWin11x64-master`

| File | Signing |
|---|---|
| `AppleWirelessMouse.sys` | **Untouched** — keeps Microsoft WHQL signature `2BA2AECC...` ("Microsoft Windows Hardware Compatibility Publisher", expires 2020-06-03 — broken-hash because we patched bytes, but signature *table* preserved) |
| `applewirelessmouse.cat` | **Regenerated** to hash the patched `.sys`, then signed with MagicMouseFix `B902C286...` (orig cert, 2026-04-21) |
| Install path | INF + catalog via `pnputil /add-driver applewirelessmouse.inf /install /force` |

In testsigning mode + cert in TrustedPublisher: kernel CI accepts the catalog → driver loads.

---

## What Was Done This Session (Divergent)

**Mechanism:** `SIGN-FILE` task runner route (`scripts/mm-task-runner.ps1:350`) →
`signtool sign /sm /sha1 16940C0F... /fd SHA256 /tr digicert /td SHA256` against
`C:\mm-dev-queue\applewirelessmouse-pathA-signed.sys`.

| Field | Value |
|---|---|
| Source unsigned | `C:\mm-dev-queue\applewirelessmouse-pathA-unsigned.sys` (78424 B, MD5 `0d9a89d08ccc89f46f47775e72c80d7b`) — note: this file inherited the WHQL cert overlay; signtool stripped it during re-sign |
| Signed output | `C:\mm-dev-queue\applewirelessmouse-pathA-signed.sys` (66288 B, MD5 `c881c04113033420cda9d3efe55f9461`, SHA256 `370a5555aebf673c3156ea5b5fbabd8030f2ee7a3a6bd0fcb1b4b6c93fa56a03`) |
| Cert subject | CN=MagicMouseFix |
| Cert thumbprint | `16940C0F937D569363560D5FEC5CD8FA6D6D9BCE` (M14, created 2026-05-02 02:25:15) |
| Cert location | `Cert:\LocalMachine\My` (private key present) |
| Trust install | `TrustedPublisher` only (NOT `Root`) |
| Final signature status | `UnknownError` — expected for self-signed; CI accepts via TrustedPublisher in testsigning mode |
| Install path | Direct copy to `C:\Windows\System32\drivers\applewirelessmouse.sys` via `PATCH-APPLE-SYS` route (no INF, no catalog) |

**Root cert state confirmed unchanged:** `Cert:\LocalMachine\Root` contains ONLY the original
`B902C286...` cert (the reference cert from 2026-04-21). I did NOT replace, displace, or
add any root cert.

**TrustedPublisher state:**
```
B902C286... (original ref cert, 2026-04-21)
A2116A7B... (created 2026-05-02 02:23:43 — origin unclear, likely parallel keyboard session)
16940C0F... (M14 cert, 2026-05-02 02:25:15 — the one I signed with)
```

---

## Why The Divergence Matters

1. **The 12K WHQL cert overlay was stripped.** The PE no longer carries Apple's
   Microsoft Hardware Compatibility Publisher signature. For internal/testsigning use
   this is invisible; for any release path it loses the WHQL provenance trail.

2. **Different signing cert.** The M14 cert `16940C0F...` was created on a different
   day from the reference cert `B902C286...`. Drivers signed with the M14 cert won't
   chain-validate against the reference catalog.

3. **No catalog file.** The reference project's `.cat` is the integrity vehicle. We
   skipped catalog generation entirely. If anything ever does a catalog-based
   verification (Win HCK, future Windows builds tightening CI rules), this fails.

4. **Direct copy bypasses INF.** PnP doesn't get a chance to register the driver
   package properly. DriverStore copies remain stale (`74756dc8...` from prior failed
   attempt is still there). Install/uninstall via `pnputil` won't see this driver.

---

## Why We're Testing Option 2 Anyway

- The signed binary is already on disk (`c881c04113033420cda9d3efe55f9461`)
- testsigning is ON; cert is in TrustedPublisher → kernel CI WILL load it
- Goal of this test: verify the **descriptor patch itself works** (TLC1 + TLC2 in 116 B,
  COL01 mouse + COL02 vendor battery enumerate, `HidD_GetInputReport(0x90)` returns
  battery %)
- Signing path is a separate axis — if descriptor works under Option 2 sig, it'll work
  under Option 1 sig too. The patch design is what's being validated, not the sig method.

---

## NLM T3 peer review caveat (2026-05-08, F3 finding)

**The "canonical pattern" assumption may not hold for our specific case.** The reference project's `.sys` keeps a `Status=Valid` WHQL signature because they don't patch the binary — only the INF/cat. Our scenario patches descriptor bytes at offset `0xA850`, which invalidates the embedded WHQL hash. The behavior of Windows Code Integrity when it sees:
- Embedded WHQL Authenticode signature with `STATUS_INVALID_IMAGE_HASH` (corrupted)
- Plus a valid testsigned catalog covering the patched bytes
- With testsigning ON and MagicMouseFix in TrustedPublisher

…is **not empirically tested**. NLM T3 verdict (peer review against notebook `e789e5e9-...`, 2026-05-08) flagged this as a Track A SHOWSTOPPER candidate.

**Mitigation: dual-variant strategy.** Build BOTH variants and gate via test class 20 (CI-probe pre-test):
- **Variant A1: Overlay-intact** (78424B, patched bytes + corrupted WHQL overlay) — preferred per reference project pattern
- **Variant A2: Overlay-stripped** (78424B - cert table size, patched bytes only, no embedded sig at all) — fallback if CI rejects A1

Both variants ship with the same `.cat` (signed by MagicMouseFix M14 cert) and same INF. The only difference is the embedded sig table on the .sys. Choice is made empirically based on whether `pnputil /add-driver` succeeds and the driver loads on a probe machine.

## Required Follow-Up — REDO SIGNING THE RIGHT WAY

Once the descriptor patch is empirically verified (this session), we MUST:

1. **Restore signing approach to canonical catalog pattern.** Steps:
   - Take the unsigned PATH-A v3 build at 78424 bytes (the version BEFORE my re-sign stripped the WHQL overlay)
   - Generate `applewirelessmouse.cat` via `New-FileCatalog -Path <driver-folder> -CatalogVersion 2`
   - Sign the catalog with `Set-AuthenticodeSignature -FilePath applewirelessmouse.cat -Certificate <MagicMouseFix>` — use the **reference cert `B902C286...`** if its private key can be recovered, otherwise rebuild the catalog with `16940C0F...`
   - Author/edit `applewirelessmouse.inf` to include `CatalogFile=applewirelessmouse.cat`
   - Install via `pnputil /add-driver applewirelessmouse.inf /install /force` (NOT direct copy)

2. **Recover the original 78424-byte v3 binary.** The unsigned candidate at
   `C:\mm-dev-queue\applewirelessmouse-pathA-unsigned.sys` (MD5 `0d9a89d0...`) has
   our patched descriptor + Apple's WHQL cert overlay. That's the correct base.
   `build-pathA-candidate.py` produces this from stock `f4ae407c...`. Re-run the
   build script to get a clean 78424-byte version.

3. **Investigate `B902C286...` private key.** If `Cert:\LocalMachine\My` ever had
   the private key for this cert (used to sign reference `applewirelessmouse.cat`),
   it's gone now — only the public cert remains in TrustedPublisher and Root.
   Check `D:\Backups\` and any earlier session snapshots for a PFX export. If
   unrecoverable, generate a new MagicMouseFix cert and re-issue the catalog
   (matching the original CN but with a fresh keypair).

4. **Clean up the divergent install before redo.** When ready to redo:
   - `C:\mm-dev-queue\restore-apple-driver.ps1` — puts stock `f4ae407c...` back in
     `System32\drivers` AND DriverStore
   - Remove the leftover `C:\Windows\System32\drivers\applewirelessmouse.sys.new`
     (still 66288 B, MD5 `c881c041...`)
   - Then proceed with INF + catalog install path

5. **Document the canonical pattern in PSN-0001.** Add a new decision row:
   - `D-019 | 2026-05-08 | PATH-A drivers MUST be signed via catalog (.cat) — NEVER re-sign the .sys directly | Reference: MagicMouse2DriversWin11x64-master pattern. Re-signing strips Microsoft WHQL overlay and breaks reproducibility against the reference project. | active`

---

## Current State Summary (2026-05-08 ~08:42 MDT)

- **Loaded driver:** `C:\Windows\System32\drivers\applewirelessmouse.sys` MD5
  `c881c04113033420cda9d3efe55f9461` (PATH-A v3, my divergent signing — 66288 B)
- **Service state:** Stopped (PnP loads on demand at next BTHENUM enum)
- **Kernel-loaded instance:** still the stock binary loaded at boot (PnP doesn't
  hot-reload running drivers; needs RESTART-DEVICE to pick up the new file)
- **Validation pending:** RESTART-DEVICE on BTHENUM Magic Mouse instance →
  patched binary loads → SDP injection → COL01+COL02 + battery readable

## Activity Log

| Date | Update |
|------|--------|
| 2026-05-08 | Direct-resigned `.sys` via SIGN-FILE; documented divergence; pending Option 2 validation + canonical redo |
