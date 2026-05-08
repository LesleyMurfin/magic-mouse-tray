---
title: Peer Review — ai/m4-kbd-inf-fix-final (MagicKbDesc kernel filter)
type: peer-review
status: blocking
date: 2026-05-08
branch: ai/m4-kbd-inf-fix-final
linked_prd: PRD-185
linked_psn: PSN-0002
reviewer: claude-opus-4-7-1m (static)
notebooklm_status: blocked-on-server-side-401-bug-in-GenerateFreeFormStreamed-endpoint
---

# Peer Review — `ai/m4-kbd-inf-fix-final`

**Scope:** `driver-keyboard/Driver.c`, `driver-keyboard/Descriptor.c`, `driver-keyboard/MagicKbDesc.h`, `driver-keyboard/MagicKbDesc.inx`, plus the supporting docs (`PSN-0002`, `M4-DRIVER-PATCH-TIMELINE.md`, root vault `Personal/prd/185-...md`).

**Reviewer note:** NotebookLM independent review attempted but blocked by a server-side 401 bug on `GenerateFreeFormStreamed` (the query endpoint). `notebook_describe` succeeded on the same notebook with the same auth token, confirming the bug is specific to the chat endpoint, not auth state. Source `bf5a7750-6bc8-4ff3-bb2b-49967ba910ae` was successfully uploaded to notebook `4d48e863-...` and remains there for retry once the endpoint recovers. This review is therefore a single-reviewer static pass; NLM corroboration to be added in a follow-up.

---

## VERDICT: **REJECT — blocking bug B1, must fix before install**

The driver as written **does nothing on the happy path**. Bug B1 below means the descriptor passes through unpatched whenever `WdfRequestSend` succeeds on the first try, which is the normal case. Installing this build would not change behavior even if INF binding worked — `HidD_GetFeature(0x47)` would still fail.

Three additional bugs (B2, B3, B4) are HIGH and need fixing in the same change before the next install attempt.

---

## SEVERITY-CRITICAL

### B1 — Double-`WdfRequestSend` pattern means the descriptor is never patched on the happy path

**Location:** `driver-keyboard/Descriptor.c:173-195` (`MagicKbDescEvtIoInternalDeviceControl`).

**Code:**

```c
if (IoControlCode == IOCTL_HID_GET_REPORT_DESCRIPTOR) {
    WDF_REQUEST_SEND_OPTIONS opts;
    WDF_REQUEST_SEND_OPTIONS_INIT(&opts, 0);

    if (!WdfRequestSend(Request, target, &opts)) {           // [A] no completion routine attached
        // Default-send failed — fall through to manual format-and-send.
    } else {
        return;                                              // happy path returns here
    }

    WdfRequestFormatRequestUsingCurrentType(Request);
    WdfRequestSetCompletionRoutine(Request, MagicKbDescDescriptorCompletion, NULL);
    if (!WdfRequestSend(Request, target, WDF_NO_SEND_OPTIONS)) { // [B] only reached if [A] failed
        ...
    }
    return;
}
```

**Bug:** The first `WdfRequestSend` at `[A]` is sent **without** a completion routine. If it succeeds (the normal case), the IRP is forwarded down to hidbth and completed back up the stack without ever calling our `MagicKbDescDescriptorCompletion`. The `else { return; }` exits before the second send block. The descriptor passes through hidbth → MagicKbDesc → up unmodified.

The path that DOES set the completion routine `[B]` only fires if the first `WdfRequestSend` returns FALSE — i.e. only on send failure, which is the abnormal case.

**Impact:** Filter is a no-op on every happy-path `IOCTL_HID_GET_REPORT_DESCRIPTOR`. `hidclass.sys` parses the original (unpatched) descriptor; RID `0x47` remains classified as Input only; `HidD_GetFeature(0x47)` continues to return `ERROR_INVALID_FUNCTION (1)`.

This is the root reason the filter would appear "installed but doing nothing" even with correct INF binding.

**Fix (canonical WDF lower-filter pattern for completion-routine intercept):**

```c
if (IoControlCode == IOCTL_HID_GET_REPORT_DESCRIPTOR) {
    WdfRequestFormatRequestUsingCurrentType(Request);
    WdfRequestSetCompletionRoutine(Request,
                                   MagicKbDescDescriptorCompletion,
                                   NULL);
    if (!WdfRequestSend(Request, target, WDF_NO_SEND_OPTIONS)) {
        NTSTATUS status = WdfRequestGetStatus(Request);
        KdPrint(("MagicKbDesc: WdfRequestSend(GET_REPORT_DESCRIPTOR) failed 0x%X\n", status));
        WdfRequestComplete(Request, status);
    }
    return;
}
```

ONE `WdfRequestSend` with the completion routine attached. Not two. The completion routine MUST be set BEFORE the send.

WDF docs: completion routine must be set before `WdfRequestSend`; once `WdfRequestSend` returns the request ownership is transferred to the I/O target and you cannot subsequently modify it.

---

## SEVERITY-HIGH

### B2 — `STATUS_BUFFER_OVERFLOW` on the patched IRP will fail device start

**Location:** `driver-keyboard/Descriptor.c:138-148` (`MagicKbDescDescriptorCompletion`).

**Code:**

```c
if (patchedLength > bufferLength) {
    KdPrint(("MagicKbDesc: descriptor buf too small: have=%Iu need=%Iu\n",
             bufferLength, patchedLength));
    WdfRequestComplete(Request, STATUS_BUFFER_OVERFLOW);
    return;
}
```

**Bug:** `hidclass.sys` issues `IOCTL_HID_GET_REPORT_DESCRIPTOR` with a buffer sized to whatever it received from a prior `IOCTL_HID_GET_REPORT_DESCRIPTOR_LENGTH` call. The descriptor returned by hidbth fills that exact buffer (`OriginalLength == buffer capacity`). Our 4-byte expansion always exceeds the buffer.

`STATUS_BUFFER_OVERFLOW` does NOT prompt hidclass to retry with a larger buffer for `IOCTL_HID_GET_REPORT_DESCRIPTOR`. The device fails to start; the filter is loaded but the HID device never reaches `DN_STARTED`.

**Fix:** Intercept `IOCTL_HID_GET_REPORT_DESCRIPTOR_LENGTH` in `MagicKbDescEvtIoInternalDeviceControl` too. Forward to hidbth, on completion add 4 to `IoStatus.Information`. Then the buffer hidclass allocates for the subsequent `IOCTL_HID_GET_REPORT_DESCRIPTOR` is already 4 bytes larger and the patch fits.

```c
// New IOCTL constant (hidport.h):
#define IOCTL_HID_GET_REPORT_DESCRIPTOR_LENGTH ...

// In EvtIoInternalDeviceControl:
case IOCTL_HID_GET_REPORT_DESCRIPTOR_LENGTH:
    // Format + completion routine that adds sizeof(g_FeatureInsertBytes) to Information
    ...

// New completion routine:
VOID MagicKbDescLengthCompletion(...) {
    // After hidbth returns the length, add 4 and complete back up.
    if (NT_SUCCESS(Params->IoStatus.Status)) {
        SIZE_T newLen = Params->IoStatus.Information + sizeof(g_FeatureInsertBytes);
        // Write newLen back into the OUTPUT buffer hidclass provided
        WdfRequestRetrieveOutputBuffer(...);
        *(ULONG*)buffer = (ULONG)newLen;
        WdfRequestCompleteWithInformation(Request, STATUS_SUCCESS, sizeof(ULONG));
    }
}
```

(Exact IOCTL constant + buffer layout to be confirmed against `hidport.h` in EWDK 10.0.26100.)

### B3 — Architecture: confirm `IOCTL_HID_GET_REPORT_DESCRIPTOR` actually reaches a lower filter

**Concern:** The driver assumes hidclass dispatches `IOCTL_HID_GET_REPORT_DESCRIPTOR` (an `IRP_MJ_INTERNAL_DEVICE_CONTROL`) DOWN to hidbth, and that lower filters between hidbth and BthEnum see it.

In standard WDF: `IRP_MJ_INTERNAL_DEVICE_CONTROL` IRPs from hidclass are dispatched to the top of the device stack (hidbth as FDO) and stop there if hidbth handles them locally. Hidbth IS the HID minidriver — it owns the descriptor query response and may not forward the IRP further down.

**Empirical test before relying on the design:**
1. Add `KdPrint(("MagicKbDesc: EvtIoInternalDeviceControl ioctl=0x%X\n", IoControlCode));` at the top of `MagicKbDescEvtIoInternalDeviceControl` (already present — confirm KdPrint is enabled in the build).
2. Install + BT-toggle to trigger enumeration.
3. Capture DebugView output during device start.
4. **Expect:** at least one log line with `ioctl=0xb0192` (= `IOCTL_HID_GET_REPORT_DESCRIPTOR`).
5. **If the IOCTL never appears**: the architectural premise is wrong; lower filters do not see it. Pivot needed (e.g., upper class filter on HID class, or different IRP intercept).

This test takes ~5 minutes after the rebuild and tells us whether to invest more time in this design at all.

### B4 — Patch logic does not validate `OriginalLength` against `bufferLength`

**Location:** `driver-keyboard/Descriptor.c:131-136` (and `MagicKbDescPatchDescriptor`).

**Code:**

```c
status = WdfRequestRetrieveOutputBuffer(Request, info, (PVOID*)&buffer, &bufferLength);
...
patchedLength = MagicKbDescPatchDescriptor(buffer, info, bufferLength);
```

`info` is `IoStatus.Information` (bytes hidbth claims to have written). `bufferLength` is the actual buffer capacity. `MagicKbDescPatchDescriptor` then does:

```c
RtlMoveMemory(insertPoint + 4, insertPoint, OriginalLength - insertOffset);
```

If hidbth returns a malicious / corrupt `IoStatus.Information` value where `info > bufferLength`, the read at `Buffer[i]` in `MagicKbDescFindCol02InsertPoint` would walk past valid memory. `RtlMoveMemory` would also read/write past the buffer.

**Fix:** Cap `info` to `bufferLength` before calling `MagicKbDescPatchDescriptor`:

```c
SIZE_T validLen = (info <= bufferLength) ? info : bufferLength;
patchedLength = MagicKbDescPatchDescriptor(buffer, validLen, bufferLength);
```

Probably not exploitable through hidbth (which is trustworthy), but the cost is one line and it removes a class of bugs.

---

## SEVERITY-MEDIUM

### B5 — Pattern matcher is not HID-parser-aware (false-positive risk)

**Location:** `driver-keyboard/Descriptor.c:31-57` (`MagicKbDescFindCol02InsertPoint`).

The matcher anchors on raw byte sequence `85 47` then within 64 bytes `81 02 C0 C0`. In a HID descriptor:
- `85 47` is the literal byte encoding of "Report ID 0x47" Global item — but a 2-byte little-endian value (e.g., a Logical Maximum 0x4785 expressed via `27 85 47 00 00`) coincidentally contains `85 47`.
- `81 02` is "Input (Data,Var,Abs)" — common.
- `C0` is "End Collection" — common.

For Apple keyboard A1314's actual descriptor, the chance of a false positive is low (and we've examined the byte sequence in `docs/m4-bt-capture-findings.md`). For other Apple keyboard PIDs in the whitelist, the risk is unverified.

**Mitigation:** parse the descriptor walking past `_TYPE_GLOBAL_REPORT_ID(0x47)` properly (a small parser, ~30 LOC). Cheaper alternative: verify against actual descriptors from each whitelisted PID before installing, and accept the known-safe assumption for now with a comment.

### B6 — `WdfRequestSetCompletionRoutine` per-IRP context is `NULL` but not commented

**Location:** `driver-keyboard/Descriptor.c:186` — `WdfRequestSetCompletionRoutine(Request, MagicKbDescDescriptorCompletion, NULL);`

The `Context` parameter is `NULL` and the completion routine `UNREFERENCED_PARAMETER(Context)`s it. This is fine but makes the design hard to extend (e.g., if you later want to pass the original buffer's allocated copy through). Leave a comment so the next reader doesn't think it was forgotten.

---

## SEVERITY-LOW

### B7 — `KdPrint` in production builds

`KdPrint` only fires in checked builds (or when configured). Production builds will be silent. For early iterations on this driver, consider `DbgPrint` or a WPP trace so DebugView captures messages even on the free build.

### B8 — `MAGICKBDESC_POOL_TAG = 'cDkM'` reversed

The comment says "MkDc reversed (NT pool tags are little-endian)". Pool tags are 4 chars displayed in `!poolused` reversed. The literal `'cDkM'` is `c`, `D`, `k`, `M` in memory. NT shows pool tags as their reversed reading — so `!poolused` will show "MkDc". This is fine but the comment is ambiguous; clarify "MkDc when displayed by `!poolused`".

---

## SEVERITY-NOT-A-BUG (resolved on inspection)

| Concern | Resolution |
|---|---|
| **IRQL on `WdfRequestRetrieveOutputBuffer`** | Documented `<= DISPATCH_LEVEL`; completion routines run at `<= DISPATCH_LEVEL`; OK. |
| **Partial descriptor (`info < expected`)** | If `info <= bufferLength` (which B4 enforces), `RtlMoveMemory` shifts within valid buffer — does not corrupt adjacent memory. |
| **Catalog-only signing accepting service load but failing PnP filter binding** | `sc start MagicKbDesc → STATE: 4 RUNNING` empirically demonstrates kernel CI accepts the catalog. PnP filter binding under HVCI uses the same code-integrity path; if it loads, it loads. The earlier "no associated service" message in setupapi.dev.log was an INF format issue (Extension INF detour), not a signing issue. |
| **`PnpLockDown = 1` in INF** | Correct for filter drivers; prevents inadvertent enable/disable that would split the HID device. |

---

## INF — separate concerns

The INF was reverted to the canonical function-driver-with-filter pattern:

```ini
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

This matches the reference project `MagicMouse2DriversWin11x64-master` empirically known to work for the same Windows version. INF binding is a separate empirical question from the C bugs above; **even if the INF binds correctly, B1 means the descriptor is not patched**.

---

## FOLLOW-UPS (priority order)

1. **Fix B1 — double-WdfRequestSend.** ~5 LOC change. Replace the `if/else { return; }` block with the canonical pattern (set completion routine, then ONE `WdfRequestSend`). This is the single most important change.
2. **Fix B2 — also intercept `IOCTL_HID_GET_REPORT_DESCRIPTOR_LENGTH`.** ~30 LOC. Add a sibling completion routine that adds 4 to the reported length. Validates that hidclass allocates a 4-byte-larger buffer for the subsequent descriptor IOCTL.
3. **Confirm B3 architectural premise.** Add the `KdPrint` at queue entry (already present), capture DebugView output during the next install attempt, look for `IOCTL_HID_GET_REPORT_DESCRIPTOR (0xb0192)`. If it never appears, the design is wrong and a different intercept layer is needed (probably a HID class upper filter, not a per-device lower filter).
4. **Add B4 sanity cap.** One-line `validLen = min(info, bufferLength)`.
5. **B5 worth doing eventually**, not blocking. Run the install + test on the A1314 first; if it works, defer the parser refactor until we add another PID.
6. **Re-run NLM peer review** when `GenerateFreeFormStreamed` recovers — the fixes above should be reviewed by NLM independently before the post-fix install attempt.

---

## WEAKEST ASSUMPTION

**Submitter's most fragile claim:** "the driver service starts (`sc start → RUNNING`), therefore the filter is correctly built and the only remaining issue is INF binding."

**Falsifying test:** the install we were about to run. Even with INF binding fixed, B1 means the descriptor IRP completes back up the stack unpatched. `HidD_GetFeature(Col02, 0x47)` would still return `ERROR_INVALID_FUNCTION`. The test result would be a misleading "install succeeded but battery still doesn't work" — easy to misattribute to a different cause and waste another debug cycle. Catching B1 here saves at least one full install/test/diagnose round.

---

## Activity Log

| Date | Update |
|---|---|
| 2026-05-08 | Static review of `ai/m4-kbd-inf-fix-final` driver-keyboard. CRITICAL bug B1 identified (double-WdfRequestSend); HIGH bugs B2, B3, B4 identified. NLM independent review queued — server-side 401 on query endpoint blocking; will retry. Verdict: REJECT — fix B1, B2, B4 + verify B3 architectural premise before next install. |
