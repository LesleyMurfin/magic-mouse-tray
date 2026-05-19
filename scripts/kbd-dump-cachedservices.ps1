#Requires -RunAsAdministrator
# Dump CachedServices binary blobs for the Apple kb (MAC e806884b0741) and
# locate the HID Report Descriptor inside. Markers we expect:
#   85 47           (Report ID 0x47)
#   81 02 c0 c0     (Input main item + double EndCollection - Col02 close)
# Then we know the offset to insert 09 20 B1 02 before c0 c0.

$mac = 'e806884b0741'
$base = "HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices\$mac"
$out  = 'C:\mm-dev-queue\kbd-cachedservices.txt'

"=== KBD CachedServices DUMP $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Set-Content $out -Encoding UTF8
"MAC: $mac" | Add-Content $out

foreach ($subkey in 'CachedServices','DynamicCachedServices') {
    $path = "$base\$subkey"
    "" | Add-Content $out
    "===== $path =====" | Add-Content $out
    if (-not (Test-Path $path)) {
        "  (not present)" | Add-Content $out
        continue
    }
    $key = Get-ItemProperty $path
    foreach ($prop in $key.PSObject.Properties) {
        if ($prop.Name -match '^PS') { continue }
        $val = $prop.Value
        if ($val -isnot [byte[]]) {
            "  $($prop.Name) = $val (type=$($val.GetType().Name))" | Add-Content $out
            continue
        }
        $len = $val.Length
        "  $($prop.Name) (REG_BINARY, $len bytes):" | Add-Content $out
        # Save raw blob to a .bin file for inspection
        $binPath = "C:\mm-dev-queue\cachedsvc-$subkey-$($prop.Name).bin"
        [IO.File]::WriteAllBytes($binPath, $val)
        "    saved -> $binPath" | Add-Content $out

        # Search for `85 47` (Report ID 0x47) - start of Apple kb battery declaration
        $offset85_47 = -1
        for ($i = 0; $i -lt $len - 1; $i++) {
            if ($val[$i] -eq 0x85 -and $val[$i+1] -eq 0x47) { $offset85_47 = $i; break }
        }
        if ($offset85_47 -ge 0) {
            "    *** FOUND '85 47' (RID 0x47) at offset $offset85_47 ***" | Add-Content $out
            # Search forward up to 64 bytes for `81 02 c0 c0` (Input + double EndColl)
            $end = [Math]::Min($offset85_47 + 64, $len - 3)
            for ($j = $offset85_47 + 2; $j -lt $end; $j++) {
                if ($val[$j] -eq 0x81 -and $val[$j+1] -eq 0x02 -and `
                    $val[$j+2] -eq 0xC0 -and $val[$j+3] -eq 0xC0) {
                    "    *** FOUND '81 02 c0 c0' (Col02 close) at offset $j ***" | Add-Content $out
                    "    -> Insertion point for '09 20 B1 02': offset $($j + 2) (between 81 02 and c0 c0)" | Add-Content $out

                    # Dump 32 bytes context around the insertion
                    $ctxStart = [Math]::Max(0, $j - 16)
                    $ctxEnd   = [Math]::Min($len, $j + 8)
                    $hex = ($val[$ctxStart..($ctxEnd-1)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
                    "    Context [$ctxStart..$($ctxEnd-1)]: $hex" | Add-Content $out
                    break
                }
            }
        } else {
            "    (no '85 47' found in blob - may not contain HID descriptor)" | Add-Content $out
        }
    }
}

"" | Add-Content $out
"=== DONE - file: $out ===" | Add-Content $out
Write-Host "Dump written: $out"
