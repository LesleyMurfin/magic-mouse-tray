# troubleshoot.ps1 -- comprehensive diagnostic dump for the MagicKbDesc descriptor patcher.
# Run anytime to capture the full state. If `.\test.ps1` fails, run this and share the output.
#
# Captures:
#   1. driver state (oem44.inf installed? in store?)
#   2. PnP stack on the keyboard's BTHENUM device
#   3. all 3 HID collections, their caps (Input/Output/FeatureReportByteLength)
#   4. raw HID Report Descriptor bytes from each collection (to see if the patch landed)
#   5. Authenticode signature + cert chain on installed .sys
#   6. DbgView buffer (last KdPrint output if the in-kernel debugger sink is enabled)
#   7. system event log: any errors mentioning the driver
#   8. summary verdict at the end

param(
    [string]$KbInstanceId = 'BTHENUM\{00001124-0000-1000-8000-00805F9B34FB}_VID&000205AC_PID&0239\9&73B8B28&0&E806884B0741_C00000000',
    [switch]$NoEventLog
)

$banner = { param($s) Write-Host ''; Write-Host "===== $s =====" -ForegroundColor Cyan }

& $banner '1. driver-store status'
$drvList = pnputil /enum-drivers 2>&1 | Out-String
$ourMatch = ($drvList -split "`n") | Select-String -Pattern 'magickbdesc' -SimpleMatch -CaseSensitive:$false -Context 0,4
if ($ourMatch) { $ourMatch.Context.PostContext + $ourMatch.Line | ForEach-Object { Write-Host $_ } }
else { Write-Host '  MagicKbDesc NOT in driver store. Run .\install.ps1 first.' -ForegroundColor Yellow }

& $banner '2. keyboard PnP stack + INF in use'
$stack = Get-PnpDeviceProperty -InstanceId $KbInstanceId -KeyName 'DEVPKEY_Device_Stack' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Data
$inf   = (Get-PnpDeviceProperty -InstanceId $KbInstanceId -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction SilentlyContinue).Data
$desc  = (Get-PnpDeviceProperty -InstanceId $KbInstanceId -KeyName 'DEVPKEY_Device_DriverDesc'    -ErrorAction SilentlyContinue).Data
Write-Host "  InstanceId: $KbInstanceId"
Write-Host "  Stack:      $($stack -join ', ')"
Write-Host "  INF:        $inf"
Write-Host "  Desc:       $desc"
$haveFilter = $stack -contains '\Driver\MagicKbDesc'
if ($haveFilter) { Write-Host '  ✓ MagicKbDesc filter IS in stack' -ForegroundColor Green }
else { Write-Host '  ✗ MagicKbDesc filter NOT in stack -- re-run .\restart-device.ps1 or toggle BT' -ForegroundColor Yellow }

& $banner '3. HID collection caps (Input/Output/Feature byte length)'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HidDiag {
  [StructLayout(LayoutKind.Sequential)]
  public struct HIDP_CAPS {
    public ushort Usage; public ushort UsagePage;
    public ushort InputReportByteLength;
    public ushort OutputReportByteLength;
    public ushort FeatureReportByteLength;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst=17)] public ushort[] Reserved;
    public ushort NumberLinkCollectionNodes;
    public ushort NumberInputButtonCaps;
    public ushort NumberInputValueCaps;
    public ushort NumberInputDataIndices;
    public ushort NumberOutputButtonCaps;
    public ushort NumberOutputValueCaps;
    public ushort NumberOutputDataIndices;
    public ushort NumberFeatureButtonCaps;
    public ushort NumberFeatureValueCaps;
    public ushort NumberFeatureDataIndices;
  }
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr CreateFileW(string p, uint a, uint s, IntPtr sa, uint d, uint f, IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
  [DllImport("hid.dll")] public static extern bool HidD_GetPreparsedData(IntPtr h, out IntPtr ppd);
  [DllImport("hid.dll")] public static extern bool HidD_FreePreparsedData(IntPtr ppd);
  [DllImport("hid.dll")] public static extern int  HidP_GetCaps(IntPtr ppd, out HIDP_CAPS caps);
}
'@ -ErrorAction SilentlyContinue | Out-Null

$cols = Get-PnpDevice -Class HIDClass -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'PID&0239&Col0[123]' -and $_.InstanceId -match '00001124' }
foreach ($col in $cols) {
    $ifKey = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\{4d1e55b2-f16f-11cf-88cb-001111000030}"
    $ent = Get-ChildItem $ifKey -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match ($col.InstanceId -replace '\\','#') } | Select-Object -First 1
    if (-not $ent) { Write-Host "  $($col.InstanceId) -- no interface path"; continue }
    $path = $ent.PSChildName -replace '^##\?#','\\?\' -replace '#\{','#{'
    $h = [HidDiag]::CreateFileW($path, 0, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($h -eq [IntPtr]::new(-1)) { Write-Host "  CreateFile failed for $path"; continue }
    $ppd = [IntPtr]::Zero
    if ([HidDiag]::HidD_GetPreparsedData($h, [ref]$ppd)) {
        $caps = New-Object HidDiag+HIDP_CAPS
        [HidDiag]::HidP_GetCaps($ppd, [ref]$caps) | Out-Null
        $colNum = if ($col.InstanceId -match 'Col(\d+)') { $Matches[1] } else { '?' }
        Write-Host ("  Col{0}  UsagePage=0x{1:X4} Usage=0x{2:X4}  Input={3,3}  Output={4,3}  Feature={5,3}  FeatValueCaps={6}" -f `
            $colNum, $caps.UsagePage, $caps.Usage, $caps.InputReportByteLength, $caps.OutputReportByteLength, $caps.FeatureReportByteLength, $caps.NumberFeatureValueCaps)
        [HidDiag]::HidD_FreePreparsedData($ppd) | Out-Null
    }
    [HidDiag]::CloseHandle($h) | Out-Null
}
Write-Host '  (Patcher target: Col02 Feature should become >= 2 after patch lands)'

& $banner '4. raw HID Report Descriptor -- Col02 (looking for 09 20 B1 02 patch)'
$col02 = $cols | Where-Object { $_.InstanceId -match 'Col02' } | Select-Object -First 1
if ($col02) {
    $ent = Get-ChildItem $ifKey -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match ($col02.InstanceId -replace '\\','#') } | Select-Object -First 1
    $path = $ent.PSChildName -replace '^##\?#','\\?\' -replace '#\{','#{'
    # Use python+hidapi-style read via Win32 -- falls back to "raw not avail" message if not supported
    Write-Host "  Col02 path: $path"
    Write-Host '  (Fetching raw descriptor requires HidD_GetReportDescriptor which is Win10+ only.)'
    try {
        Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class HidDescGet {
  [DllImport("hid.dll", SetLastError=true)] public static extern bool HidD_GetReportDescriptor(IntPtr h, byte[] buf, uint bufLen);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr CreateFileW(string p, uint a, uint s, IntPtr sa, uint d, uint f, IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
}
'@ -ErrorAction SilentlyContinue | Out-Null
        $h = [HidDescGet]::CreateFileW($path, 0, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
        if ($h -ne [IntPtr]::new(-1)) {
            $rd = New-Object byte[] 4096
            $ok = [HidDescGet]::HidD_GetReportDescriptor($h, $rd, 4096)
            [HidDescGet]::CloseHandle($h) | Out-Null
            if ($ok) {
                $hex = ($rd[0..63] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
                Write-Host "  first 64 bytes: $hex"
                $hexAll = ($rd | ForEach-Object { '{0:X2}' -f $_ }) -join ''
                if ($hexAll -match '8147[0-9A-F]*?09 ?20 ?B1 ?02') {
                    Write-Host '  ✓ patch sequence (09 20 B1 02) FOUND after RID 0x47' -ForegroundColor Green
                } elseif ($hexAll -match '8147') {
                    Write-Host '  ✗ RID 0x47 present but patch sequence (09 20 B1 02) NOT found -- descriptor was NOT patched' -ForegroundColor Yellow
                } else {
                    Write-Host '  ? RID 0x47 not seen in first 4KB -- unusual'
                }
            } else {
                Write-Host "  HidD_GetReportDescriptor failed err=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            }
        }
    } catch { Write-Host "  descriptor read error: $_" }
}

& $banner '5. signature on installed .sys'
$sysPaths = @(
    'C:\Windows\System32\drivers\MagicKbDesc.sys',
    'C:\Windows\Temp\MagicKbDescStage\MagicKbDesc.sys'
)
foreach ($p in $sysPaths) {
    if (Test-Path $p) {
        $sig = Get-AuthenticodeSignature $p
        Write-Host ("  {0}  Status={1}  Signer={2}" -f $p, $sig.Status, ($sig.SignerCertificate.Subject))
    }
}

& $banner '6. recent kernel-mode debug output (DbgView circular buffer if Boot/PERSISTENT enabled)'
Write-Host '  KdPrint() output goes to the kernel debugger. Capture with DbgView.exe or'
Write-Host '  enable KDPRINT logging to %SystemRoot%\Logs\WMI\trace.etl. Out of band -- not here.'

if (-not $NoEventLog) {
    & $banner '7. recent System event log entries mentioning MagicKbDesc / hidbth (last 50)'
    Get-WinEvent -LogName System -MaxEvents 200 -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'MagicKbDesc|hidbth|HidBth|0239' -or $_.ProviderName -match 'PnP' } |
        Select-Object -First 15 TimeCreated,LevelDisplayName,Id,Message |
        Format-Table -AutoSize -Wrap
}

& $banner '8. summary verdict'
if ($haveFilter) {
    Write-Host '  Filter is bound -- if .\test.ps1 still fails, dump (4) above and check the descriptor section: did 09 20 B1 02 land?'
} else {
    Write-Host '  Filter NOT bound. Sequence: .\install.ps1 → .\restart-device.ps1 → .\test.ps1.'
    Write-Host '  If install.ps1 says "up-to-date" but the filter isnt in the stack, the INF needs ExtensionId -- see PR conversation.'
}
Write-Host ''
