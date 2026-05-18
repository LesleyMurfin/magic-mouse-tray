#Requires -RunAsAdministrator
# Patch CachedServices SDP record to expose RID 0x47 as Feature on COL02.
#
# Inserts `09 20 B1 02` at the COL02 close inside the HID Report Descriptor
# stored in the BTHPORT cache, and increments 4 SDP length fields.
#
# Run elevated. Modifies HKLM. Backs up original blobs first.

[CmdletBinding()]
param(
    [string]$Mac = 'e806884b0741',
    [switch]$DryRun
)

$base = "HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices\$Mac"
$insertBytes = [byte[]](0x09, 0x20, 0xB1, 0x02)

function Patch-Blob {
    param([byte[]]$Blob, [string]$Source)
    $len = $Blob.Length
    Write-Host "[$Source] original length: $len bytes"

    # Find COL02 close: `85 47` then later `81 02 c0 c0`
    $rid47 = -1
    for ($i = 0; $i -lt $len - 1; $i++) {
        if ($Blob[$i] -eq 0x85 -and $Blob[$i+1] -eq 0x47) { $rid47 = $i; break }
    }
    if ($rid47 -lt 0) { throw "RID 0x47 marker not found in $Source" }

    $col02Close = -1
    $end = [Math]::Min($rid47 + 64, $len - 3)
    for ($j = $rid47 + 2; $j -lt $end; $j++) {
        if ($Blob[$j]   -eq 0x81 -and $Blob[$j+1] -eq 0x02 -and
            $Blob[$j+2] -eq 0xC0 -and $Blob[$j+3] -eq 0xC0) {
            $col02Close = $j
            break
        }
    }
    if ($col02Close -lt 0) { throw "COL02 close pattern '81 02 c0 c0' not found in $Source" }

    $insertOffset = $col02Close + 2     # between '81 02' and 'c0 c0'
    Write-Host "[$Source] RID 0x47 at $rid47, COL02 close at $col02Close, insert at $insertOffset"

    # Find the SDP length fields by parsing back from the descriptor.
    # Structure ahead of descriptor:
    #   <descriptor-string-tag> 25 <len8>  <descriptor bytes...>
    #   <inner-seq-tag>         35 <len8>  <descriptor-string-tag> ...
    #   <outer-seq-tag>         35 <len8>  <inner-seq-tag> ...
    #   <attr-id 0x0206>        09 02 06   <outer-seq-tag> ...
    #   <top-record-tag>        36 <hi> <lo>  ...

    # Find `09 02 06` (HIDDescriptorList attr id) before the descriptor.
    $attrIdOffset = -1
    for ($i = 0; $i -lt $rid47; $i++) {
        if ($Blob[$i] -eq 0x09 -and $Blob[$i+1] -eq 0x02 -and $Blob[$i+2] -eq 0x06) {
            $attrIdOffset = $i
            break
        }
    }
    if ($attrIdOffset -lt 0) { throw "HIDDescriptorList attr id 0x0206 (09 02 06) not found in $Source" }

    # Sequence of length fields immediately after `09 02 06`:
    #  byte[attrIdOffset+3] = 0x35 (outer seq)
    #  byte[attrIdOffset+4] = outer length (uint8)
    #  byte[attrIdOffset+5] = 0x35 (inner seq)
    #  byte[attrIdOffset+6] = inner length (uint8)
    #  byte[attrIdOffset+7] = 0x08 (UINT_8 marker for descriptor type)
    #  byte[attrIdOffset+8] = 0x22
    #  byte[attrIdOffset+9] = 0x25 (String 8-bit length marker)
    #  byte[attrIdOffset+10] = string length (uint8)
    $outerLenOffset  = $attrIdOffset + 4
    $innerLenOffset  = $attrIdOffset + 6
    $strLenOffset    = $attrIdOffset + 10
    if ($Blob[$attrIdOffset + 3]  -ne 0x35) { throw "Expected outer 0x35 at $($attrIdOffset + 3)" }
    if ($Blob[$attrIdOffset + 5]  -ne 0x35) { throw "Expected inner 0x35 at $($attrIdOffset + 5)" }
    if ($Blob[$attrIdOffset + 7]  -ne 0x08) { throw "Expected 0x08 at $($attrIdOffset + 7)" }
    if ($Blob[$attrIdOffset + 9]  -ne 0x25) { throw "Expected 0x25 at $($attrIdOffset + 9)" }

    Write-Host "[$Source] length offsets: outer=$outerLenOffset(=$($Blob[$outerLenOffset])) inner=$innerLenOffset(=$($Blob[$innerLenOffset])) str=$strLenOffset(=$($Blob[$strLenOffset]))"

    # Top record `36 hi lo`
    if ($Blob[0] -ne 0x36) { throw "Expected top record tag 0x36 at offset 0, got 0x$('{0:X2}' -f $Blob[0])" }
    $topLenHigh = 1
    $topLenLow  = 2
    $topLen = ($Blob[$topLenHigh] * 256) + $Blob[$topLenLow]
    Write-Host "[$Source] top record length 16-bit at offsets 1..2 = $topLen"

    # Build patched blob: insert 4 bytes at $insertOffset, +4 to each length field
    $newLen = $len + 4
    $new = New-Object byte[] $newLen
    [Array]::Copy($Blob, 0, $new, 0, $insertOffset)
    [Array]::Copy($insertBytes, 0, $new, $insertOffset, 4)
    [Array]::Copy($Blob, $insertOffset, $new, $insertOffset + 4, $len - $insertOffset)

    $new[$strLenOffset]    = [byte]($Blob[$strLenOffset]   + 4)
    $new[$innerLenOffset]  = [byte]($Blob[$innerLenOffset] + 4)
    $new[$outerLenOffset]  = [byte]($Blob[$outerLenOffset] + 4)
    $newTopLen = $topLen + 4
    $new[$topLenHigh] = [byte](($newTopLen -shr 8) -band 0xFF)
    $new[$topLenLow]  = [byte]( $newTopLen        -band 0xFF)

    Write-Host "[$Source] new lengths: outer=$($new[$outerLenOffset]) inner=$($new[$innerLenOffset]) str=$($new[$strLenOffset]) top=$newTopLen"

    return $new
}

foreach ($subkey in 'CachedServices','DynamicCachedServices') {
    $path = "$base\$subkey"
    if (-not (Test-Path $path)) { Write-Host "$path not present, skipping"; continue }
    $key = Get-ItemProperty $path
    foreach ($prop in $key.PSObject.Properties) {
        if ($prop.Name -match '^PS') { continue }
        $val = $prop.Value
        if ($val -isnot [byte[]]) { continue }
        # Skip blobs without RID 0x47
        $hasRid = $false
        for ($i = 0; $i -lt $val.Length - 1; $i++) {
            if ($val[$i] -eq 0x85 -and $val[$i+1] -eq 0x47) { $hasRid = $true; break }
        }
        if (-not $hasRid) { Write-Host "[$subkey\$($prop.Name)] no RID 0x47 - skip"; continue }

        # Backup
        $backup = "C:\mm-dev-queue\backup-$subkey-$($prop.Name)-$(Get-Date -Format yyyyMMdd-HHmmss).bin"
        [IO.File]::WriteAllBytes($backup, $val)
        Write-Host "[$subkey\$($prop.Name)] backed up -> $backup"

        $patched = Patch-Blob -Blob $val -Source "$subkey\$($prop.Name)"

        if ($DryRun) {
            $patchedFile = "C:\mm-dev-queue\patched-$subkey-$($prop.Name).bin"
            [IO.File]::WriteAllBytes($patchedFile, $patched)
            Write-Host "[DRY-RUN] patched bytes saved -> $patchedFile (registry NOT modified)"
        } else {
            Set-ItemProperty -Path $path -Name $prop.Name -Value $patched -Type Binary
            Write-Host "[$subkey\$($prop.Name)] WRITTEN to registry. New length: $($patched.Length) bytes"
        }
    }
}

Write-Host ""
Write-Host "DONE. Toggle BT off/on for hidbth to re-read CachedServices."
