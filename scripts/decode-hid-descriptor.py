#!/usr/bin/env python3
"""Decode HID Report Descriptors from the candidate binaries.

Compares:
  A) /mnt/c/mm-dev-queue/applewirelessmouse-fixed.sys  (66288 bytes)
     -- Apple's stock binary patched at offset 0xA850 with a 2-TLC descriptor.
     Currently FAILED_STARTing with NTSTATUS 0xC00000B9 (STATUS_INVALID_PARAMETER_MIX).

  B) /mnt/c/mm-dev-queue/MagicMouseDriver-wdf.sys  (29664 bytes)
     -- Session-14 WDF SDP-patcher with known-good 135-byte 3-TLC descriptor at offset 0x4450.
     Empirically confirmed: HID OK = 3, RID=0x90 returns battery%.

Prints the HID descriptor item stream for each, then summarises whether
each Top-Level Collection has the items hidclass.sys requires (Usage,
Logical Min/Max) for any Input/Output/Feature it declares.
"""

from pathlib import Path

# Tag dictionaries (HID 1.11 spec)
MAIN_TAGS  = {0x80:'Input', 0x90:'Output', 0xB0:'Feature',
              0xA0:'Collection', 0xC0:'EndCollection'}
GLOBAL_TAGS= {0x00:'UsagePage', 0x10:'LogicalMin', 0x20:'LogicalMax',
              0x30:'PhysicalMin', 0x40:'PhysicalMax', 0x50:'UnitExp',
              0x60:'Unit', 0x70:'ReportSize', 0x80:'ReportID',
              0x90:'ReportCount', 0xA0:'Push', 0xB0:'Pop'}
LOCAL_TAGS = {0x00:'Usage', 0x10:'UsageMin', 0x20:'UsageMax',
              0x30:'DesignatorIndex', 0x40:'DesignatorMin', 0x50:'DesignatorMax',
              0x70:'StringIndex', 0x80:'StringMin', 0x90:'StringMax',
              0xA0:'Delimiter'}
TYPE_NAME = {0:'M', 1:'G', 2:'L'}  # Main/Global/Local

def decode(buf: bytes):
    """Yield (offset, hex, type, tag_name, value, raw_bytes)."""
    i = 0
    n = len(buf)
    while i < n:
        prefix = buf[i]
        if prefix == 0xFE:
            length = buf[i+1] if i+1 < n else 0
            yield (i, f'{prefix:02X}', 'LONG', f'long-item len={length}', None, buf[i:i+length+3])
            i += length + 3
            continue
        bSize = prefix & 0x03
        if bSize == 3:
            bSize = 4
        bType = (prefix >> 2) & 0x03
        bTag  = prefix & 0xF0
        data  = buf[i+1:i+1+bSize]
        value = int.from_bytes(data, 'little', signed=False) if bSize else None
        type_name = TYPE_NAME.get(bType, '?')
        if bType == 0:
            tag = MAIN_TAGS.get(bTag, f'?Main_{bTag:02X}')
        elif bType == 1:
            tag = GLOBAL_TAGS.get(bTag, f'?Global_{bTag:02X}')
        elif bType == 2:
            tag = LOCAL_TAGS.get(bTag, f'?Local_{bTag:02X}')
        else:
            tag = f'?Reserved_{bTag:02X}'
        raw = buf[i:i+1+bSize]
        yield (i, raw.hex(' ').upper(), type_name, tag, value, raw)
        i += 1 + bSize

def analyse(buf: bytes, label: str):
    print(f'\n========== {label} ==========')
    print(f'Length: {len(buf)} bytes')
    items = list(decode(buf))
    cur_tlc = 0
    cur_report_id = None
    cur_logmin = None
    cur_logmax = None
    cur_usage_page = None
    cur_usages_in_scope = []
    tlc_summary = []  # list of dicts per top-level collection
    cur_tlc_info = None
    for off, hex_, typ, tag, val, raw in items:
        # human-readable line
        val_str = '' if val is None else f' = {val} (0x{val:X})'
        print(f'  +{off:03d}  [{typ}] {tag:<14}{val_str}   ({hex_})')

        if typ == 'G' and tag == 'UsagePage':
            cur_usage_page = val
        elif typ == 'L' and tag == 'Usage':
            cur_usages_in_scope.append(val)
        elif typ == 'G' and tag == 'ReportID':
            cur_report_id = val
        elif typ == 'G' and tag == 'LogicalMin':
            cur_logmin = val
        elif typ == 'G' and tag == 'LogicalMax':
            cur_logmax = val
        elif typ == 'M' and tag == 'Collection':
            if val == 0x01:  # Application -> top-level
                cur_tlc += 1
                cur_tlc_info = {
                    'tlc': cur_tlc,
                    'usage_page_at_open': cur_usage_page,
                    'usage_at_open': cur_usages_in_scope[-1] if cur_usages_in_scope else None,
                    'report_ids': set(),
                    'inputs_with_usage': 0,
                    'inputs_without_usage': 0,
                    'inputs_with_logminmax': 0,
                    'inputs_without_logminmax': 0,
                    'has_logmin_seen': False,
                    'has_logmax_seen': False,
                }
                tlc_summary.append(cur_tlc_info)
        elif typ == 'M' and tag == 'EndCollection':
            cur_usages_in_scope = []  # locals consumed at end of collection scope
        elif typ == 'M' and tag in ('Input', 'Output', 'Feature'):
            if cur_tlc_info is not None:
                if cur_report_id is not None:
                    cur_tlc_info['report_ids'].add(cur_report_id)
                # for hidclass to accept, the Input/Output/Feature must have
                # Usage range set + Logical Min/Max set in scope at this point
                if cur_usages_in_scope or cur_tlc_info.get('usage_at_open'):
                    cur_tlc_info['inputs_with_usage'] += 1
                else:
                    cur_tlc_info['inputs_without_usage'] += 1
                if cur_logmin is not None and cur_logmax is not None:
                    cur_tlc_info['inputs_with_logminmax'] += 1
                else:
                    cur_tlc_info['inputs_without_logminmax'] += 1
                # tracked
                cur_tlc_info['has_logmin_seen'] = cur_logmin is not None
                cur_tlc_info['has_logmax_seen'] = cur_logmax is not None
                # local usages consumed by Input/Output/Feature
                cur_usages_in_scope = []

    print()
    print(f'------- {label}: TLC summary -------')
    for tlc in tlc_summary:
        print(f'  TLC{tlc["tlc"]}: UP=0x{(tlc["usage_page_at_open"] or 0):04X} '
              f'U=0x{(tlc["usage_at_open"] or 0):04X}  RIDs={sorted(tlc["report_ids"])}')
        print(f'    Input/Output/Feature with Usage in scope: {tlc["inputs_with_usage"]}')
        print(f'    Input/Output/Feature WITHOUT Usage in scope: {tlc["inputs_without_usage"]}')
        print(f'    With Logical Min+Max in scope: {tlc["inputs_with_logminmax"]}')
        print(f'    WITHOUT Logical Min+Max in scope: {tlc["inputs_without_logminmax"]}')
        verdict = 'OK' if (tlc['inputs_without_usage'] == 0
                            and tlc['inputs_without_logminmax'] == 0) else 'REJECTED'
        print(f'    --> hidclass would: {verdict}')
    return tlc_summary

# ---- run ----
PATCHED_APPLE = Path('/mnt/c/mm-dev-queue/applewirelessmouse-fixed.sys')
WDF_BIN       = Path('/mnt/c/mm-dev-queue/MagicMouseDriver-wdf.sys')

# Patched Apple: descriptor at 0xA850, length 116
apple_data = PATCHED_APPLE.read_bytes()
apple_desc = apple_data[0xA850:0xA850 + 116]
print(f'Apple binary size: {len(apple_data)} bytes')
print(f'Apple descriptor first bytes: {apple_desc[:8].hex(" ").upper()}')

# WDF: per Session 14 notes the patched descriptor is at offset 0x4450, length 135
wdf_data = WDF_BIN.read_bytes()
wdf_desc = wdf_data[0x4450:0x4450 + 135]
print(f'WDF binary size: {len(wdf_data)} bytes')
print(f'WDF descriptor first bytes: {wdf_desc[:8].hex(" ").upper()}')

# Sanity: do they look like HID descriptors? First item should be Global UsagePage (0x05 nn)
# 0x05 short = 0b00000101 (bSize=1, bType=01 Global, bTag=0000 UsagePage)
print()
print('Sanity:')
print(f'  Apple desc[0:2] = {apple_desc[:2].hex(" ").upper()}  (expect "05 01" = UsagePage GenericDesktop)')
print(f'  WDF   desc[0:2] = {wdf_desc[:2].hex(" ").upper()}  (expect "05 01" = UsagePage GenericDesktop)')

apple_tlc = analyse(apple_desc, 'A) Patched Apple driver (0xA850, 116 bytes) — currently FAILED_START')
wdf_tlc   = analyse(wdf_desc,   'B) WDF Session-14 driver (0x4450, 135 bytes) — known good (battery=22%)')

# Final comparison
print('\n========== FINAL VERDICT ==========')
def has_bad(tlcs):
    return any(t['inputs_without_usage'] > 0 or t['inputs_without_logminmax'] > 0 for t in tlcs)

apple_bad = has_bad(apple_tlc)
wdf_bad   = has_bad(wdf_tlc)
print(f'  Patched Apple has malformed Input/Output/Feature items: {apple_bad}')
print(f'  WDF Session-14 has malformed Input/Output/Feature items: {wdf_bad}')
if apple_bad and not wdf_bad:
    print('  ==> HYPOTHESIS CONFIRMED: Apple binary patch has the same bug Session 14 fixed.')
    print('       Re-patch with a corrected 2-TLC descriptor and FAILED_START should clear.')
elif not apple_bad:
    print('  ==> HYPOTHESIS REJECTED: Apple binary patch descriptor looks valid.')
    print('       FAILED_START must come from a different cause. Investigate further.')
