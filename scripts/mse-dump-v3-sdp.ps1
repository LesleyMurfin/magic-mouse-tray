#Requires -RunAsAdministrator
# Dump v3 Magic Mouse (MAC D0C050CC8C4D) CachedServices SDP records and
# locate all Report ID declarations + their Input/Feature main-item flags.
# Goal: pick the right patch strategy.

$mac = 'd0c050cc8c4d'
$base = "HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices\$mac"
$out  = 'C:\mm-dev-queue\mse-v3-sdp-dump.txt'

"=== v3 Magic Mouse SDP DUMP $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Set-Content $out -Encoding UTF8
"MAC: $mac" | Add-Content $out

foreach ($subkey in 'CachedServices','DynamicCachedServices') {
    $path = "$base\$subkey"
    "" | Add-Content $out
    "===== $path =====" | Add-Content $out
    if (-not (Test-Path $path)) { "  not present" | Add-Content $out; continue }
    $key = Get-ItemProperty $path
    foreach ($prop in $key.PSObject.Properties) {
        if ($prop.Name -match '^PS') { continue }
        $val = $prop.Value
        if ($val -isnot [byte[]]) { continue }
        $len = $val.Length
        "  $($prop.Name)  ($len bytes):" | Add-Content $out
        $bin = "C:\mm-dev-queue\mse-v3-$subkey-$($prop.Name).bin"
        [IO.File]::WriteAllBytes($bin, $val)
        "    saved -> $bin" | Add-Content $out

        # Find HIDDescriptorList attr id (09 02 06)
        $attrIdOffset = -1
        for ($i = 0; $i -lt $len - 2; $i++) {
            if ($val[$i] -eq 0x09 -and $val[$i+1] -eq 0x02 -and $val[$i+2] -eq 0x06) {
                $attrIdOffset = $i; break
            }
        }
        if ($attrIdOffset -lt 0) {
            "    (no HIDDescriptorList attr 0x0206 found)" | Add-Content $out
            continue
        }
        "    HIDDescriptorList attr at offset $attrIdOffset" | Add-Content $out

        # Find Report ID markers (85 XX) inside the descriptor area
        # Scan from descriptor start (a few bytes after attrIdOffset) to end
        $descStart = $attrIdOffset + 11   # past 09 02 06 35 LL 35 LL 08 22 25 LL
        "" | Add-Content $out
        "    Report IDs declared (offset relative to blob, byte after 0x85):" | Add-Content $out
        for ($i = $descStart; $i -lt $len - 1; $i++) {
            if ($val[$i] -eq 0x85) {
                $rid = $val[$i+1]
                # Show 16-byte context after the RID
                $ctxEnd = [Math]::Min($len, $i + 24)
                $ctx = ($val[$i..($ctxEnd-1)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
                "      offset ${i}: 85 $('{0:X2}' -f $rid)   ctx: $ctx" | Add-Content $out
            }
        }

        "" | Add-Content $out
        "    Looking for COL close patterns (81 02 c0 [c0]) and (b1 02 c0 [c0]):" | Add-Content $out
        for ($i = $descStart; $i -lt $len - 3; $i++) {
            if ($val[$i] -eq 0x81 -and $val[$i+1] -eq 0x02 -and $val[$i+2] -eq 0xC0 -and $val[$i+3] -eq 0xC0) {
                "      offset ${i}: 81 02 C0 C0  (Input + double EndCollection)" | Add-Content $out
            }
            if ($val[$i] -eq 0xB1 -and $val[$i+1] -eq 0x02 -and $val[$i+2] -eq 0xC0 -and $val[$i+3] -eq 0xC0) {
                "      offset ${i}: B1 02 C0 C0  (Feature + double EndCollection)" | Add-Content $out
            }
        }

        "" | Add-Content $out
        "    Full descriptor bytes hex dump (32 bytes/row):" | Add-Content $out
        # Determine descriptor length from string-length byte at attrIdOffset+10
        $strLen = $val[$attrIdOffset + 10]
        $descLen = $strLen
        $descBegin = $attrIdOffset + 11
        $descEnd = [Math]::Min($len, $descBegin + $descLen)
        for ($i = $descBegin; $i -lt $descEnd; $i += 32) {
            $rowEnd = [Math]::Min($descEnd, $i + 32)
            $row = ($val[$i..($rowEnd-1)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            "      [{0,4}]: {1}" -f ($i - $descBegin), $row | Add-Content $out
        }
    }
}

"" | Add-Content $out
"=== DONE - file: $out ===" | Add-Content $out
Write-Host "Wrote $out"
