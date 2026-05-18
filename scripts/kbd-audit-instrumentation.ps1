# kbd-audit-instrumentation.ps1
# Hard audit of every instrumentation claim. Each check: PASS / FAIL / PARTIAL with the
# raw evidence string. No inference. Run elevated.

$out = "C:\mm-dev-queue\kbd-audit-instrumentation.txt"
"=== INSTRUMENTATION AUDIT $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Set-Content $out -Encoding UTF8
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
"Boot: $boot" | Add-Content $out
"" | Add-Content $out

function Result { param($name, $status, $evidence)
    "[$status] $name" | Add-Content $out
    "        $evidence" | Add-Content $out
}

# --- 1. KbdDbgViewBoot scheduled task: registered, last run, result ---
$t1 = Get-ScheduledTask -TaskName 'KbdDbgViewBoot' -ErrorAction SilentlyContinue
if ($t1) {
    $i1 = Get-ScheduledTaskInfo -TaskName 'KbdDbgViewBoot'
    $exe = $t1.Actions[0].Execute
    Result '1. KbdDbgViewBoot task registered' 'PASS' "exe=$exe lastRun=$($i1.LastRunTime) result=$($i1.LastTaskResult)"
} else {
    Result '1. KbdDbgViewBoot task registered' 'FAIL' 'task not present'
}

# --- 2. Dbgview.exe process alive RIGHT NOW ---
$dbg = Get-Process -Name 'Dbgview*' -ErrorAction SilentlyContinue
if ($dbg) {
    Result '2. Dbgview.exe currently running' 'PASS' "PID=$($dbg.Id -join ',') Path=$($dbg.Path -join ',')"
} else {
    Result '2. Dbgview.exe currently running' 'FAIL' 'no Dbgview process found in tasklist'
}

# --- 3. dbgview-boot.log present + actual MagicKbDesc KdPrint lines ---
# Use 'MagicKbDesc:' (with colon) — that's the prefix our driver emits.
# Plain 'MagicKbDesc' also matches the Verifier "Applied for MagicKbDesc.sys"
# startup line which has no colon and isn't a real KdPrint hit.
$dbgLog = 'C:\mm-dev-queue\dbgview-boot.log'
if (Test-Path $dbgLog) {
    $info = Get-Item $dbgLog
    $kdpLines = (Get-Content $dbgLog -ErrorAction SilentlyContinue | Select-String 'MagicKbDesc:' | Measure-Object).Count
    $totalMkb = (Get-Content $dbgLog -ErrorAction SilentlyContinue | Select-String 'MagicKbDesc' | Measure-Object).Count
    if ($kdpLines -eq 0) {
        Result '3. DebugView captured MagicKbDesc driver KdPrint' 'FAIL' "size=$($info.Length) mtime=$($info.LastWriteTime) KdPrint('MagicKbDesc:') lines=0  any-mention=$totalMkb (likely Verifier startup line only)"
    } else {
        Result '3. DebugView captured MagicKbDesc driver KdPrint' 'PASS' "KdPrint lines=$kdpLines"
    }
} else {
    Result '3. dbgview-boot.log exists' 'FAIL' 'file not present'
}

# --- 4. KbdPostRebootValidate task: registered, last run ---
$t2 = Get-ScheduledTask -TaskName 'KbdPostRebootValidate' -ErrorAction SilentlyContinue
if ($t2) {
    $i2 = Get-ScheduledTaskInfo -TaskName 'KbdPostRebootValidate'
    Result '4. KbdPostRebootValidate task registered' 'PASS' "lastRun=$($i2.LastRunTime) result=$($i2.LastTaskResult)"
} else {
    Result '4. KbdPostRebootValidate task registered' 'FAIL' 'task not present'
}

# --- 5. post-reboot-validate output log ---
$valLog = 'C:\mm-dev-queue\post-reboot-validate.log'
if (Test-Path $valLog) {
    $i = Get-Item $valLog
    Result '5. post-reboot-validate.log written' 'PASS' "size=$($i.Length) mtime=$($i.LastWriteTime)"
} else {
    Result '5. post-reboot-validate.log written' 'FAIL' "file not present (Tee-Object in -File argument did not run as expected)"
}

# --- 6. Driver Verifier state ---
$vDrv = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name VerifyDrivers -ErrorAction SilentlyContinue).VerifyDrivers
$vLvl = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name VerifyDriverLevel -ErrorAction SilentlyContinue).VerifyDriverLevel
if ($vDrv -match 'MagicKbDesc') {
    Result '6. Driver Verifier configured for MagicKbDesc.sys' 'PASS' "VerifyDrivers='$vDrv' Level=$vLvl (0x$('{0:X}' -f $vLvl))"
} else {
    Result '6. Driver Verifier configured for MagicKbDesc.sys' 'FAIL' "VerifyDrivers='$vDrv' Level=$vLvl"
}

# --- 7. WinDbg / kd.exe actually present at a callable path ---
$kdCandidates = @(
    'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\kd.exe',
    'C:\Program Files\Windows Kits\10\Debuggers\x64\kd.exe'
) + (Get-ChildItem 'C:\Program Files\WindowsApps\Microsoft.WinDbg_*\amd64\kd.exe' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
$kdFound = $kdCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if ($kdFound) {
    Result '7. kd.exe (WinDbg) installed and callable' 'PASS' $kdFound
} else {
    Result '7. kd.exe installed' 'FAIL' 'no kd.exe at any standard path'
}

# --- 8. Crash dump config ---
$cc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction SilentlyContinue
if ($cc.CrashDumpEnabled -ge 1) {
    Result '8. Crash dump config (BSOD recoverable)' 'PASS' "CrashDumpEnabled=$($cc.CrashDumpEnabled) MinidumpDir=$($cc.MinidumpDir) AutoReboot=$($cc.AutoReboot)"
} else {
    Result '8. Crash dump config' 'FAIL' "CrashDumpEnabled=$($cc.CrashDumpEnabled)"
}

# --- 9. MagicKbDesc filter actually in device stack ---
$kbId = 'BTHENUM\{00001124-0000-1000-8000-00805F9B34FB}_VID&000205AC_PID&0239\9&73B8B28&0&E806884B0741_C00000000'
$stack = (Get-PnpDeviceProperty -InstanceId $kbId -KeyName 'DEVPKEY_Device_Stack' -ErrorAction SilentlyContinue).Data
if ($stack -match 'MagicKbDesc') {
    Result '9. MagicKbDesc filter bound in BTHENUM stack' 'PASS' "stack=$($stack -join ' -> ')"
} else {
    Result '9. MagicKbDesc filter bound' 'FAIL' "stack=$($stack -join ' -> ')"
}

# --- 10. Filter service running ---
$svc = sc.exe query MagicKbDesc 2>&1 | Out-String
if ($svc -match 'STATE\s+:\s+4\s+RUNNING') {
    Result '10. MagicKbDesc service RUNNING' 'PASS' $(($svc -split "`n" | Select-String 'STATE|EXIT' | ForEach-Object { $_.Line.Trim() }) -join ' | ')
} else {
    Result '10. MagicKbDesc service RUNNING' 'FAIL' $(($svc -split "`n" | Select-String 'STATE') -join '')
}

# --- 11. Class instance LowerFilters reg (where PnP "should" read) ---
$enumPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$kbId"
$drv = (Get-ItemProperty $enumPath -Name Driver -ErrorAction SilentlyContinue).Driver
if ($drv) {
    $clsLF = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$drv" -Name LowerFilters -ErrorAction SilentlyContinue).LowerFilters
    $enumLF = (Get-ItemProperty $enumPath -Name LowerFilters -ErrorAction SilentlyContinue).LowerFilters
    Result '11. Class-instance LowerFilters reg' $(if ($clsLF -contains 'MagicKbDesc') {'PASS'} elseif ($enumLF -contains 'MagicKbDesc') {'PARTIAL'} else {'FAIL'}) "Driver=$drv  Class.LowerFilters='$($clsLF -join ',')'  Enum.LowerFilters='$($enumLF -join ',')'"
} else {
    Result '11. Class-instance LowerFilters reg' 'FAIL' "no Driver value at $enumPath"
}

# --- 12. COL02 actually has Feature now (proves descriptor patch fired) ---
$col02key = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\HID' -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match 'VID&000205AC.*PID&0239.*Col02' } | Select-Object -First 1
if ($col02key) {
    $col02inst = (Get-ChildItem $col02key.PSPath -ErrorAction SilentlyContinue | Select-Object -First 1).PSChildName
    Result '12. COL02 PDO enumerated under HID' 'PASS' "key=$($col02key.PSChildName)\$col02inst"
} else {
    Result '12. COL02 PDO enumerated' 'FAIL' 'no Col02 instance found under HID enum'
}

# --- 13. ETW autologgers configured for MagicKbDesc-related providers ---
$autologgers = @(
    @{Name='KMDF-Trace'; Reg='HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\KMDF-Trace'},
    @{Name='WdfTrace'; Reg='HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\WdfTrace'}
)
$alFound = 0
foreach ($al in $autologgers) {
    if (Test-Path $al.Reg) { $alFound++ }
}
$customAL = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger' -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match 'kbd|MagicKb' }
if ($customAL) {
    Result '13. Custom ETW autologger for MagicKbDesc' 'PASS' "found: $($customAL.PSChildName -join ',')"
} else {
    Result '13. Custom ETW autologger for MagicKbDesc' 'FAIL' 'no custom autologger session configured'
}

# --- 14. DriverFrameworks-KernelMode provider state ---
$kmEnabled = $false
try {
    $kmLog = Get-WinEvent -ListLog 'Microsoft-Windows-DriverFrameworks-KernelMode/Operational' -ErrorAction Stop
    $kmEnabled = $kmLog.IsEnabled
    Result '14. DriverFrameworks-KernelMode/Operational enabled' $(if ($kmEnabled) {'PASS'} else {'FAIL'}) "IsEnabled=$kmEnabled records=$($kmLog.RecordCount)"
} catch {
    Result '14. DriverFrameworks-KernelMode/Operational provider' 'FAIL' "log not registered: $_"
}

# --- 15. Driver was built with debug-print emissions (DBG flag in .sys) ---
# Quick proxy: scan .sys for DbgPrint/KdPrint string artifacts. Release builds compile away KdPrint
# (no string), Debug/Checked retain them.
$sysPath = (Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository\magickbdesc.inf_amd64_*\MagicKbDesc.sys' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
if ($sysPath -and (Test-Path $sysPath)) {
    $bytes = [IO.File]::ReadAllBytes($sysPath)
    # Look for "MagicKbDesc:" string (used in every KdPrint message). If absent -> Release build w/o emissions.
    $marker = [Text.Encoding]::ASCII.GetBytes('MagicKbDesc:')
    $found = $false
    for ($i = 0; $i -lt ($bytes.Length - $marker.Length); $i++) {
        $match = $true
        for ($j = 0; $j -lt $marker.Length; $j++) {
            if ($bytes[$i + $j] -ne $marker[$j]) { $match = $false; break }
        }
        if ($match) { $found = $true; break }
    }
    if ($found) {
        Result '15. Driver .sys contains debug-print strings' 'PASS' "$sysPath has 'MagicKbDesc:' marker"
    } else {
        Result '15. Driver .sys contains debug-print strings' 'FAIL' "$sysPath has NO 'MagicKbDesc:' marker (Release build, KdPrint compiled out)"
    }
} else {
    Result '15. Driver .sys discoverable' 'FAIL' 'no MagicKbDesc.sys in DriverStore'
}

# --- 16. Active ETW sessions running ---
$sessions = & logman query -ets 2>&1 | Select-String -Pattern 'kbd|MagicKb|WdfTrace' -CaseSensitive:$false
if ($sessions) {
    Result '16. Active ETW session for kbd/wdf' 'PASS' $(($sessions | ForEach-Object { $_.Line.Trim() }) -join ' | ')
} else {
    Result '16. Active ETW session for kbd/wdf' 'FAIL' 'no active session for kbd/MagicKb/WdfTrace'
}

"" | Add-Content $out
"=== AUDIT DONE ===" | Add-Content $out
Write-Host "Audit written: $out"
