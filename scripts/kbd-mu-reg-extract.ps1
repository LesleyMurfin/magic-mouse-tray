#Requires -RunAsAdministrator
# Extract BTHPORT CachedServices/DynamicCachedServices for kb (e806884b0741) and
# v3 mouse (d0c050cc8c4d) from a registry backup .reg file. Handles UTF-16 LE
# encoding and the multi-line hex(3): format used by REG_BINARY values.
#
# Decodes the binary, looks for:
#   - HID Report Descriptor markers `85 47` (RID 0x47)
#   - COL02 close `81 02 c0 c0`
#   - Magic Utilities patch signature `09 20 B1 02` already inserted
# and writes the raw decoded blob to disk for byte-level diff vs our patched.

param(
    [string]$RegFile = 'D:\Users\Lesley\Documents\Backups\2026 04 03 - Windows11_registry-backup.reg',
    [string]$OutDir  = 'C:\mm-dev-queue\mu-reg-extract'
)

if (-not (Test-Path $RegFile)) { Write-Host "FAIL: $RegFile not found"; exit 1 }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory $OutDir -Force | Out-Null }

$macs = @{
    'kb_e806884b0741'   = 'e806884b0741'
    'v3mouse_d0c050cc8c4d' = 'd0c050cc8c4d'
    'v1mouse_04f13eeede10' = '04f13eeede10'
}

# Read the file as raw bytes, detect BOM, decode as UTF-16 LE
$bytes = [IO.File]::ReadAllBytes($RegFile)
Write-Host "Loaded $($bytes.Length) bytes"
if ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
    $text = [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    Write-Host "Decoded UTF-16 LE"
} else {
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    Write-Host "Decoded UTF-8"
}
Write-Host "Char count: $($text.Length)"

# Split on lines (CRLF)
$lines = $text -split "`r`n"
Write-Host "Line count: $($lines.Length)"

foreach ($macName in $macs.Keys) {
    $mac = $macs[$macName]
    Write-Host ""
    Write-Host "=========================================="
    Write-Host "Searching for MAC $mac ($macName)"
    Write-Host "=========================================="

    foreach ($subkey in 'CachedServices','DynamicCachedServices') {
        $sectionHeader = "[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices\$mac\$subkey]"
        $startIdx = -1
        for ($i = 0; $i -lt $lines.Length; $i++) {
            if ($lines[$i] -ceq $sectionHeader) { $startIdx = $i; break }
        }
        if ($startIdx -lt 0) {
            Write-Host "  ${subkey}: section not found"
            continue
        }
        Write-Host "  ${subkey}: found at line $startIdx"

        # Find the next [section] start to bound the block
        $endIdx = $lines.Length
        for ($i = $startIdx + 1; $i -lt $lines.Length; $i++) {
            if ($lines[$i].StartsWith('[')) { $endIdx = $i; break }
        }
        $block = $lines[$startIdx..($endIdx-1)] -join "`n"

        # Find the 00010000=hex(3): value (multi-line, continuation backslash)
        $valueRegex = [regex]'(?ms)"00010000"=hex\(3\):([^\[]+?)(?=\r?\n("|\[|$))'
        $m = $valueRegex.Match($block)
        if (-not $m.Success) {
            # Try simpler match - sometimes hex(3) lacks newline before next entry
            $valueRegex2 = [regex]'(?ms)"00010000"=hex\(3\):([0-9a-fA-F,\s\\]+)'
            $m = $valueRegex2.Match($block)
        }
        if (-not $m.Success) {
            Write-Host "    no 00010000 hex value found"
            continue
        }

        # Strip continuation backslashes and whitespace, parse hex bytes
        $hexClean = $m.Groups[1].Value -replace '[\\\s]', ''
        $hexParts = $hexClean -split ','
        $hexParts = $hexParts | Where-Object { $_ -match '^[0-9a-fA-F]{2}$' }
        $bytes = New-Object byte[] $hexParts.Count
        for ($i = 0; $i -lt $hexParts.Count; $i++) {
            $bytes[$i] = [Convert]::ToByte($hexParts[$i], 16)
        }
        Write-Host "    00010000 length: $($bytes.Length) bytes"

        # Save raw blob
        $outBin = Join-Path $OutDir "mu-$macName-$subkey-00010000.bin"
        [IO.File]::WriteAllBytes($outBin, $bytes)
        Write-Host "    saved -> $outBin"

        # Markers
        $rid47 = -1
        for ($i = 0; $i -lt $bytes.Length - 1; $i++) {
            if ($bytes[$i] -eq 0x85 -and $bytes[$i+1] -eq 0x47) { $rid47 = $i; break }
        }
        if ($rid47 -ge 0) {
            Write-Host "    *** RID 0x47 marker at offset $rid47 ***"
            $end = [Math]::Min($rid47 + 64, $bytes.Length - 3)
            for ($j = $rid47 + 2; $j -lt $end; $j++) {
                if ($bytes[$j] -eq 0x81 -and $bytes[$j+1] -eq 0x02 -and
                    $bytes[$j+2] -eq 0xC0 -and $bytes[$j+3] -eq 0xC0) {
                    Write-Host "    UNPATCHED: '81 02 c0 c0' (Col02 close, no Feature) at $j"
                    break
                }
                if ($bytes[$j] -eq 0x81 -and $bytes[$j+1] -eq 0x02 -and
                    $bytes[$j+2] -eq 0x09 -and $bytes[$j+3] -eq 0x20 -and
                    $bytes[$j+4] -eq 0xB1 -and $bytes[$j+5] -eq 0x02) {
                    Write-Host "    *** PATCHED *** '81 02 09 20 B1 02' (Feature inserted before Col02 close) at $j"
                    break
                }
            }
            # Context dump 32 bytes around RID 0x47
            $ctxStart = [Math]::Max(0, $rid47 - 8)
            $ctxEnd   = [Math]::Min($bytes.Length, $rid47 + 32)
            $hex = ($bytes[$ctxStart..($ctxEnd-1)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            Write-Host "    Context [$ctxStart..$($ctxEnd-1)]: $hex"
        } else {
            Write-Host "    (no RID 0x47 in blob)"
        }
    }
}

Write-Host ""
Write-Host "DONE. Bins in $OutDir"
