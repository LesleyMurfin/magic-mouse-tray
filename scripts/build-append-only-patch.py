#!/usr/bin/env python3
"""Build an APPEND-ONLY patched applewirelessmouse.sys candidate.

Strategy:
  1. Keep Apple's original 116-byte descriptor at 0xA850 byte-for-byte.
  2. Append ~22 bytes for a new vendor battery TLC2 (UP=0xFF00, Usage=0x14, RID=0x90).
  3. Find and patch any embedded length immediates that reference 116 (0x74).
  4. Output candidate to /mnt/c/mm-dev-queue/applewirelessmouse-append.sys
     for offline analysis. Do NOT install.

The new TLC2 is 22 bytes copied directly from the WDF Session-14 binary's known-working
TLC2 (which empirically returned battery=22% via RID=0x90).
"""

from pathlib import Path
import struct

ORIG = Path('/mnt/c/Windows/System32/DriverStore/FileRepository/applewirelessmouse.inf_amd64_ac34ebceaaf7324c/applewirelessmouse.sys')
WDF  = Path('/mnt/c/mm-dev-queue/MagicMouseDriver-wdf.sys')
OUT  = Path('/mnt/c/mm-dev-queue/applewirelessmouse-append.sys')

orig = bytearray(ORIG.read_bytes())
wdf  = WDF.read_bytes()

print(f'Original Apple binary: {len(orig)} bytes')
print(f'WDF binary:            {len(wdf)} bytes')

# 1. Find original 116-byte descriptor location (0xA850 is the patched location;
#    confirm it's also in the original)
DESC_OFF_PATCHED = 0xA850
prefix = bytes.fromhex('05010902a1018502')
desc_off_orig = orig.find(prefix)
print(f'Descriptor in original: 0x{desc_off_orig:X}')
if desc_off_orig != DESC_OFF_PATCHED:
    print(f'WARN: descriptor offset differs between original (0x{desc_off_orig:X}) and patched (0x{DESC_OFF_PATCHED:X})')

# 2. Get the new TLC2 from the WDF binary (offsets 89..110 within the 135-byte block at 0x4450)
WDF_DESC_OFF = 0x4450
wdf_desc = wdf[WDF_DESC_OFF:WDF_DESC_OFF + 135]
new_tlc2 = wdf_desc[89:111]  # 22 bytes
print(f'New TLC2 ({len(new_tlc2)} bytes): {new_tlc2.hex(" ").upper()}')

# 3. Find the length immediate. Apple's binary is ~78424 bytes and has many places that
#    might reference 0x74 (116). We look for narrow patterns near the descriptor:
#    Pattern 1: `mov ecx, 0x74`     -> b9 74 00 00 00 (5 bytes)
#    Pattern 2: `mov edx, 0x74`     -> ba 74 00 00 00
#    Pattern 3: `cmp <reg>, 0x74`   -> 83 f? 74
#    Pattern 4: `mov ax, 74h`        -> 66 b8 74 00
#    Pattern 5: `74 00 00 00`         -- raw 32-bit value 116 (could be a struct field)
#    Pattern 6: `74` near a ULONG-aligned slot
print()
print('--- searching for descriptor length references (immediate value 0x74 = 116) ---')

patterns = [
    (b'\xb9\x74\x00\x00\x00', 'mov ecx, 116'),
    (b'\xba\x74\x00\x00\x00', 'mov edx, 116'),
    (b'\x41\xb8\x74\x00\x00\x00', 'mov r8d, 116'),
    (b'\x6a\x74', 'push 116 (8-bit)'),
    (b'\x74\x00\x00\x00', 'raw u32 = 116'),
    (b'\x74\x00', 'raw u16 = 116 (also branch byte alas)'),
]
for pat, desc in patterns:
    locations = []
    i = 0
    while True:
        j = orig.find(pat, i)
        if j < 0: break
        locations.append(j)
        i = j + 1
    if locations:
        if len(pat) <= 2:
            # too short, suppress unless near descriptor
            near = [hex(l) for l in locations if 0xA000 < l < 0xC000]
            if near:
                print(f'  {desc:32}  near descriptor offsets: {near[:8]}')
        else:
            print(f'  {desc:32}  at: {[hex(l) for l in locations[:8]]}')

# 4. Build the candidate by appending TLC2 at 0xA850 + 116
new_binary = bytearray(orig)

# Verify 0xA850..0xA8C4 region in original:
print(f'Region 0xA850..0xA8C4 (existing descriptor): {bytes(new_binary[0xA850:0xA8C4]).hex(" ").upper()[:80]}...')
print(f'Region 0xA8C4..0xA8DC (where TLC2 would go): {bytes(new_binary[0xA8C4:0xA8DC]).hex(" ").upper()}')

# Check if there are zero bytes (free space) immediately after the descriptor
free_after = 0
for i in range(0xA8C4, min(0xA8C4 + 64, len(new_binary))):
    if new_binary[i] == 0x00:
        free_after += 1
    else:
        break
print(f'Zero bytes immediately after descriptor: {free_after} bytes')
if free_after >= 22:
    print(f'  >> Sufficient zero-padding: can append TLC2 in-place at 0xA8C4')
else:
    print(f'  >> NOT enough zero-padding. Would need to relocate descriptor or find code cave.')

# Try the in-place append if free_after is sufficient
NEW_DESC_LEN = 116 + len(new_tlc2)
print(f'\nNew descriptor length: {NEW_DESC_LEN} bytes (0x{NEW_DESC_LEN:X})')

if free_after >= len(new_tlc2):
    new_binary[0xA8C4:0xA8C4 + len(new_tlc2)] = new_tlc2
    print(f'  Wrote TLC2 in place at 0xA8C4..0x{0xA8C4 + len(new_tlc2):X}')

    # Now patch any 116-immediate references found above. We'll only patch
    # those in code patterns, not raw bytes (too risky).
    patches_applied = 0
    for pat, desc in [
        (b'\xb9\x74\x00\x00\x00', b'\xb9' + NEW_DESC_LEN.to_bytes(4, 'little')),
        (b'\xba\x74\x00\x00\x00', b'\xba' + NEW_DESC_LEN.to_bytes(4, 'little')),
        (b'\x41\xb8\x74\x00\x00\x00', b'\x41\xb8' + NEW_DESC_LEN.to_bytes(4, 'little')),
        (b'\x6a\x74', b'\x6a' + bytes([NEW_DESC_LEN])),
    ]:
        i = 0
        while True:
            j = new_binary.find(pat, i)
            if j < 0: break
            new_binary[j:j+len(pat[0:1])+len(pat)-1] = pat
            new_binary[j:j+len(patches_applied if False else 0)] = b''  # cancel weird write
            # Actually just manually replace
            new_binary[j:j+len(pat)] = pat[:len(pat)-len(NEW_DESC_LEN.to_bytes(4, 'little'))] + NEW_DESC_LEN.to_bytes(4 if pat[0] in (0xb9,0xba) or pat[:2]==b'\x41\xb8' else 1, 'little')
            patches_applied += 1
            i = j + len(pat)
    # Note: my length-replacement logic above is too clever-by-half; rewrite simpler.
    new_binary = bytearray(orig)  # reset
    new_binary[0xA8C4:0xA8C4 + len(new_tlc2)] = new_tlc2
    # Replace immediate 116 (0x74) -> 138 (0x8A) at well-known opcodes:
    replacements = [
        (b'\xb9\x74\x00\x00\x00', b'\xb9\x8a\x00\x00\x00', 'mov ecx,116 -> mov ecx,138'),
        (b'\xba\x74\x00\x00\x00', b'\xba\x8a\x00\x00\x00', 'mov edx,116 -> mov edx,138'),
        (b'\x41\xb8\x74\x00\x00\x00', b'\x41\xb8\x8a\x00\x00\x00', 'mov r8d,116 -> mov r8d,138'),
        (b'\x6a\x74', b'\x6a\x8a', 'push 116 -> push 138'),
    ]
    print('\n--- patching length immediates ---')
    for old, new, desc in replacements:
        i = 0
        while True:
            j = new_binary.find(old, i)
            if j < 0: break
            new_binary[j:j+len(old)] = new
            print(f'  Patched at 0x{j:X}: {desc}')
            i = j + len(new)

    OUT.write_bytes(bytes(new_binary))
    print(f'\nWrote candidate: {OUT} ({len(new_binary)} bytes)')

    # Verify the appended descriptor looks right
    final_desc = new_binary[0xA850:0xA850 + NEW_DESC_LEN]
    print(f'\nFinal descriptor ({NEW_DESC_LEN} bytes):')
    print('  ', final_desc.hex(' ').upper())
else:
    print('\nABORT: not enough zero space to append TLC2 in place.')
    print('Would need to relocate the descriptor to an unused region (PE overlay or .data tail).')
    print('That is more invasive — pause for user review.')
