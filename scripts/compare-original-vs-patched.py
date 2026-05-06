#!/usr/bin/env python3
"""Compare Apple's ORIGINAL embedded descriptor vs the patched one byte-by-byte.

This isolates exactly what the binary patch changed and identifies whether
the patched descriptor is shorter, longer, or differently structured than
what Apple's runtime gesture-engine code was compiled against.
"""

from pathlib import Path

ORIG = Path('/mnt/c/Windows/System32/DriverStore/FileRepository/applewirelessmouse.inf_amd64_ac34ebceaaf7324c/applewirelessmouse.sys')
PATCHED = Path('/mnt/c/mm-dev-queue/applewirelessmouse-fixed.sys')

orig = ORIG.read_bytes()
patch = PATCHED.read_bytes()

print(f'Original Apple binary:  {len(orig)} bytes')
print(f'Patched Apple binary:   {len(patch)} bytes')
print(f'Size delta: {len(orig) - len(patch)} bytes')

# Try to find the descriptor in the original. The patched is at 0xA850.
# Original is bigger (has Apple's WHQL cert overlay). Descriptor offset
# may differ. Search for the well-known mouse descriptor prefix.
prefix = bytes.fromhex('05010902a1018502')  # UsagePage Generic, Usage Mouse, Coll App, RID=0x02
matches_orig = []
i = 0
while True:
    j = orig.find(prefix, i)
    if j < 0: break
    matches_orig.append(j)
    i = j + 1
matches_patch = []
i = 0
while True:
    j = patch.find(prefix, i)
    if j < 0: break
    matches_patch.append(j)
    i = j + 1
print(f'Descriptor prefix matches: original={[hex(x) for x in matches_orig]}, patched={[hex(x) for x in matches_patch]}')

# Use the "data section" descriptor (the embedded one, not the SDP-builder copy)
# The doc says the descriptor used for injection is at 0xA850 in the patched.
# Find the same content in original.
orig_desc_off = matches_orig[0] if matches_orig else 0xA850
patch_desc_off = 0xA850

orig_desc = orig[orig_desc_off:orig_desc_off+116]
patch_desc = patch[patch_desc_off:patch_desc_off+116]

print(f'\nOriginal descriptor at 0x{orig_desc_off:X} (116 bytes):')
print('  ', ' '.join(f'{b:02X}' for b in orig_desc))
print(f'\nPatched descriptor at 0x{patch_desc_off:X} (116 bytes):')
print('  ', ' '.join(f'{b:02X}' for b in patch_desc))

# Byte-by-byte diff
print(f'\nBYTE-LEVEL DIFF:')
n_diffs = 0
runs = []
in_run = False
run_start = None
for i in range(min(len(orig_desc), len(patch_desc))):
    if orig_desc[i] != patch_desc[i]:
        n_diffs += 1
        if not in_run:
            run_start = i
            in_run = True
    else:
        if in_run:
            runs.append((run_start, i-1))
            in_run = False
if in_run:
    runs.append((run_start, len(orig_desc)-1))
print(f'  {n_diffs} differing bytes in {len(runs)} contiguous runs:')
for start, end in runs:
    orig_run = orig_desc[start:end+1]
    patch_run = patch_desc[start:end+1]
    print(f'    bytes [+{start:03d}..+{end:03d}] ({end-start+1} bytes):')
    print(f'      ORIG : {" ".join(f"{b:02X}" for b in orig_run)}')
    print(f'      PATCH: {" ".join(f"{b:02X}" for b in patch_run)}')

# Decode each
MAIN  = {0x80:'Input', 0x90:'Output', 0xB0:'Feature', 0xA0:'Coll', 0xC0:'EndColl'}
GLOB  = {0x00:'UsgPg', 0x10:'LMin', 0x20:'LMax', 0x30:'PMin', 0x40:'PMax',
         0x50:'UExp', 0x60:'Unit', 0x70:'RSize', 0x80:'RID', 0x90:'RCount'}
LOC   = {0x00:'Usg', 0x10:'UsgMin', 0x20:'UsgMax'}

def items(buf):
    i = 0
    while i < len(buf):
        p = buf[i]
        if p == 0xFE:
            n = buf[i+1] if i+1 < len(buf) else 0
            yield (i, p, 'L?', f'long', None)
            i += n + 3; continue
        sz = p & 3
        if sz == 3: sz = 4
        ty = (p >> 2) & 3
        tg = p & 0xF0
        v  = int.from_bytes(buf[i+1:i+1+sz], 'little') if sz else None
        if ty == 0: tag = MAIN.get(tg, f'M{tg:02X}')
        elif ty == 1: tag = GLOB.get(tg, f'G{tg:02X}')
        elif ty == 2: tag = LOC.get(tg, f'L{tg:02X}')
        else: tag = f'R{tg:02X}'
        yield (i, p, ty, tag, v)
        i += 1 + sz

def show(label, buf):
    print(f'\n{label}:')
    for off, prefix, ty, tag, val in items(buf):
        v = '' if val is None else f'={val} (0x{val:X})'
        print(f'  +{off:03d}  {prefix:02X}  {tag:<8}{v}')

show('ORIGINAL (Apple stock embedded)', orig_desc)
show('PATCHED (66288-byte signed)', patch_desc)
