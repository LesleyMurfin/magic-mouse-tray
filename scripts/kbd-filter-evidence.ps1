# kbd-filter-evidence.ps1 - read-only evidence dump for diagnosing why
# MagicKbDesc (or any HID lower filter on the Apple keyboard) isn't loading.
#
# Captures: PnP state, driver stack, registry filter chain, INF content,
# setupapi install timeline, system events, CodeIntegrity, certs, minidumps.
# Output: C:\mm-dev-queue\kbd-evidence-YYYYMMDD-HHMMSS.txt (single file).
#
# Run elevated for full coverage. From WSL, route via mm-task-runner queue
# or run directly:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File kbd-filter-evidence.ps1
#
# Originally written 2026-05-09 to RCA the post-install veto issue
# (PNP_VetoOutstandingOpen on HID Col02). See docs/RCA-FILTER-NOT-LOADING.md.

$kbId = 'BTHENUM\{00001124-0000-1000-8000-00805f9b34fb}_VID&000205ac_PID&0239\9&73b8b28&0&E806884B0741_C00000000'
$evidence = "C:\mm-dev-queue\kbd-evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
$log = { param($s) Add-Content -Path $evidence -Value $s -Encoding UTF8 }

Set-Content -Path $evidence -Value "=== KBD FILTER EVIDENCE ===" -Encoding UTF8
& $log "Captured: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
& $log "Hostname: $env:COMPUTERNAME"
& $log "User: $env:USERNAME"
& $log ''

# ============================================================================
& $log '======================================================================'
& $log '## 1. CURRENT STATE'
& $log '======================================================================'

& $log ''
& $log '### 1.1 Apple kb PnP device (parent BTHENUM)'
$kb = Get-PnpDevice -InstanceId $kbId -ErrorAction SilentlyContinue
if ($kb) {
    $kb | Format-List | Out-String | ForEach-Object { & $log $_ }
}

& $log ''
& $log '### 1.2 Driver stack (DEVPKEY_Device_Stack)'
$stack = (Get-PnpDeviceProperty -InstanceId $kbId -KeyName 'DEVPKEY_Device_Stack' -ErrorAction SilentlyContinue).Data
$stack | ForEach-Object { & $log "  $_" }

& $log ''
& $log '### 1.3 All DEVPKEY_Device_Driver* properties'
$pdProps = @(
    'DEVPKEY_Device_Driver',
    'DEVPKEY_Device_DriverInfPath',
    'DEVPKEY_Device_DriverInfSection',
    'DEVPKEY_Device_DriverDate',
    'DEVPKEY_Device_DriverVersion',
    'DEVPKEY_Device_DriverProvider',
    'DEVPKEY_Device_DriverRank',
    'DEVPKEY_Device_DriverProblemDesc',
    'DEVPKEY_Device_FirstInstallDate',
    'DEVPKEY_Device_LastArrivalDate',
    'DEVPKEY_Device_LastRemovalDate',
    'DEVPKEY_Device_DriverLogoLevel',
    'DEVPKEY_Device_Service',
    'DEVPKEY_Device_LowerFilters',
    'DEVPKEY_Device_UpperFilters',
    'DEVPKEY_Device_HardwareIds',
    'DEVPKEY_Device_CompatibleIds',
    'DEVPKEY_Device_ConfigFlags',
    'DEVPKEY_Device_Capabilities',
    'DEVPKEY_Device_PhysicalDeviceLocation',
    'DEVPKEY_Device_DevNodeStatus',
    'DEVPKEY_Device_ProblemCode'
)
foreach ($p in $pdProps) {
    $v = (Get-PnpDeviceProperty -InstanceId $kbId -KeyName $p -ErrorAction SilentlyContinue).Data
    if ($null -ne $v) {
        & $log ("  {0}: {1}" -f $p, ($v -join ', '))
    }
}

& $log ''
& $log '### 1.4 Registry: BTHENUM kb instance + Device Parameters'
$enumKey = "HKLM:\SYSTEM\CurrentControlSet\Enum\$kbId"
$dpKey   = "$enumKey\Device Parameters"
& $log "Path: $enumKey"
$ek = Get-ItemProperty -Path $enumKey -ErrorAction SilentlyContinue
if ($ek) { $ek.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object { & $log "  $($_.Name) = $($_.Value)" } }
& $log "Path: $dpKey"
$dpk = Get-ItemProperty -Path $dpKey -ErrorAction SilentlyContinue
if ($dpk) { $dpk.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object { & $log "  $($_.Name) = $(($_.Value -join ','))" } }

& $log ''
& $log '### 1.5 Registry: Class \0003 (HidBth class instance)'
$clsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{745a17a0-74d3-11d0-b6fe-00a0c90f57da}\0003'
$ck = Get-ItemProperty -Path $clsKey -ErrorAction SilentlyContinue
if ($ck) { $ck.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object { & $log "  $($_.Name) = $($_.Value)" } }

& $log ''
& $log '### 1.6 ALL HidClass class instances + their LowerFilters'
$classRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{745a17a0-74d3-11d0-b6fe-00a0c90f57da}'
Get-ChildItem $classRoot -ErrorAction SilentlyContinue | ForEach-Object {
    $svc = (Get-ItemProperty -Path $_.PSPath -Name Service -ErrorAction SilentlyContinue).Service
    $lf  = (Get-ItemProperty -Path $_.PSPath -Name LowerFilters -ErrorAction SilentlyContinue).LowerFilters
    $mdi = (Get-ItemProperty -Path $_.PSPath -Name MatchingDeviceId -ErrorAction SilentlyContinue).MatchingDeviceId
    $infpath = (Get-ItemProperty -Path $_.PSPath -Name InfPath -ErrorAction SilentlyContinue).InfPath
    $infsec = (Get-ItemProperty -Path $_.PSPath -Name InfSection -ErrorAction SilentlyContinue).InfSection
    & $log "  $($_.PSChildName): Service=$svc  Match=$mdi  Inf=${infpath}:${infsec}  LowerFilters=$($lf -join ',')"
}

# ============================================================================
& $log ''
& $log '======================================================================'
& $log '## 2. MAGICKBDESC SERVICE + FILE'
& $log '======================================================================'

& $log ''
& $log '### 2.1 sc query / qc'
& $log (sc.exe query MagicKbDesc 2>&1 | Out-String)
& $log (sc.exe qc MagicKbDesc 2>&1 | Out-String)

& $log ''
& $log '### 2.2 driverquery'
driverquery /v /fo csv 2>&1 | Select-String 'MagicKbDesc' | ForEach-Object { & $log $_.Line }

& $log ''
& $log '### 2.3 .sys file on disk'
$sys1 = 'C:\WINDOWS\System32\drivers\MagicKbDesc.sys'
$sys2 = 'C:\WINDOWS\System32\DriverStore\FileRepository\magickbdesc.inf_amd64_19830858ec72e2ad\MagicKbDesc.sys'
foreach ($p in $sys1, $sys2) {
    if (Test-Path $p) {
        $h = (Get-FileHash -Algorithm MD5 $p).Hash.ToLower()
        $sz = (Get-Item $p).Length
        $mt = (Get-Item $p).LastWriteTime
        & $log "  $p  size=$sz  mtime=$mt  md5=$h"
    } else {
        & $log "  $p  ABSENT"
    }
}

& $log ''
& $log '### 2.4 Service registry block'
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\MagicKbDesc' -ErrorAction SilentlyContinue |
    Format-List | Out-String | ForEach-Object { & $log $_ }

& $log ''
& $log '### 2.5 Driver-store package state'
$pkgRoot = 'C:\Windows\System32\DriverStore\FileRepository\magickbdesc.inf_amd64_19830858ec72e2ad'
if (Test-Path $pkgRoot) {
    Get-ChildItem $pkgRoot | Format-Table Name, Length, LastWriteTime -AutoSize | Out-String | ForEach-Object { & $log $_ }
}
& $log "pnputil enum entry:"
pnputil /enum-drivers 2>&1 | Select-String -Pattern 'magickbdesc|oem0' -Context 0,8 | ForEach-Object { & $log $_.Line }

# ============================================================================
& $log ''
& $log '======================================================================'
& $log '## 3. SETUPAPI INSTALL TIMELINE'
& $log '======================================================================'
& $log ''
& $log '### 3.1 setupapi.dev.log entries since most recent boot'
$bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
& $log "Boot: $bootTime"
$bootDate = $bootTime.ToString('yyyy/MM/dd')
$content = Get-Content C:\Windows\inf\setupapi.dev.log -ErrorAction SilentlyContinue
if ($content) {
    # Pull entries since boot date that mention our keyboard or our INF
    $matches = $content | Select-String -Pattern "$bootDate|MagicKbDesc|magickbdesc|oem0|oem57|BTHENUM.*0239|VID_05AC.PID_0239|VID&000205ac.PID&0239" -SimpleMatch:$false
    $matches | Select-Object -Last 200 | ForEach-Object { & $log $_.Line }
}

# ============================================================================
& $log ''
& $log '======================================================================'
& $log '## 4. SYSTEM + CODEINTEGRITY EVENTS (last 30 min)'
& $log '======================================================================'

$since = (Get-Date).AddMinutes(-30)

& $log ''
& $log '### 4.1 System Event Log: Critical/Error/Warning + filter relevant'
Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$since} -ErrorAction SilentlyContinue |
    Where-Object { $_.LevelDisplayName -in 'Critical','Error','Warning' -or $_.Message -match 'MagicKbDesc|HidBth|BTHENUM|oem0|filter' } |
    Select-Object -First 50 TimeCreated, Id, LevelDisplayName, ProviderName, @{n='Msg';e={if($_.Message){$_.Message.Substring(0,[Math]::Min(280,$_.Message.Length))}}} |
    Format-List | Out-String | ForEach-Object { & $log $_ }

& $log ''
& $log '### 4.2 CodeIntegrity Operational log (driver-load denials)'
Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -ErrorAction SilentlyContinue |
    Where-Object { $_.TimeCreated -gt $since } |
    Select-Object -First 20 TimeCreated, Id, LevelDisplayName, @{n='Msg';e={if($_.Message){$_.Message.Substring(0,[Math]::Min(280,$_.Message.Length))}}} |
    Format-List | Out-String | ForEach-Object { & $log $_ }

& $log ''
& $log '### 4.3 Kernel-PnP log (filter chain build, device-start)'
$pnpLogs = @('Microsoft-Windows-Kernel-PnP/Configuration','Microsoft-Windows-Kernel-PnP/Device Configuration')
foreach ($ln in $pnpLogs) {
    & $log "--- $ln ---"
    Get-WinEvent -LogName $ln -ErrorAction SilentlyContinue |
        Where-Object { $_.TimeCreated -gt $since -and ($_.Message -match 'MagicKbDesc|BTHENUM.*0239|HidBth|filter') } |
        Select-Object -First 30 TimeCreated, Id, LevelDisplayName, @{n='Msg';e={if($_.Message){$_.Message.Substring(0,[Math]::Min(280,$_.Message.Length))}}} |
        Format-List | Out-String | ForEach-Object { & $log $_ }
}

& $log ''
& $log '### 4.4 Driver lifecycle events (Service-Control-Manager, etc.)'
Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$since; ProviderName='Service Control Manager','Microsoft-Windows-Service-Control-Manager','Microsoft-Windows-Kernel-PnP'} -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match 'MagicKbDesc|HidBth' } |
    Select-Object -First 30 TimeCreated, Id, ProviderName, @{n='Msg';e={if($_.Message){$_.Message.Substring(0,[Math]::Min(280,$_.Message.Length))}}} |
    Format-List | Out-String | ForEach-Object { & $log $_ }

# ============================================================================
& $log ''
& $log '======================================================================'
& $log '## 5. INF + DRIVER SIGNATURE'
& $log '======================================================================'

& $log ''
& $log '### 5.1 MagicKbDesc.inf full content'
$infs = @(
    'C:\mm-dev-queue\kbd-stage-kbd-stage-1778263483\MagicKbDesc.inf',
    'C:\Windows\System32\DriverStore\FileRepository\magickbdesc.inf_amd64_19830858ec72e2ad\MagicKbDesc.inf'
)
foreach ($inf in $infs) {
    if (Test-Path $inf) {
        & $log "--- $inf ---"
        Get-Content $inf | ForEach-Object { & $log $_ }
        & $log ''
    }
}

& $log ''
& $log '### 5.2 .sys signature (signtool verify)'
$signtool = 'F:\Program Files\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe'
if (-not (Test-Path $signtool)) { $signtool = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe' }
if (Test-Path $signtool) {
    foreach ($p in 'C:\WINDOWS\System32\drivers\MagicKbDesc.sys','C:\WINDOWS\System32\DriverStore\FileRepository\magickbdesc.inf_amd64_19830858ec72e2ad\MagicKbDesc.sys') {
        if (Test-Path $p) {
            & $log "--- $p ---"
            & $signtool verify /v /pa /kp $p 2>&1 | ForEach-Object { & $log $_ }
        }
    }
}

# ============================================================================
& $log ''
& $log '======================================================================'
& $log '## 6. CERT TRUST CHAIN'
& $log '======================================================================'
Get-ChildItem Cert:\LocalMachine\TrustedPublisher | Where-Object { $_.Subject -match 'MagicMouseFix|MagicKb' } |
    Format-List Subject, Thumbprint, NotBefore, NotAfter, Issuer | Out-String | ForEach-Object { & $log $_ }

Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -match 'MagicMouseFix|MagicKb' } |
    Format-List Subject, Thumbprint, NotBefore, NotAfter, Issuer | Out-String | ForEach-Object { & $log $_ }

# ============================================================================
& $log ''
& $log '======================================================================'
& $log '## 7. RECENT MINIDUMPS'
& $log '======================================================================'
Get-ChildItem C:\Windows\Minidump -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object Name, Length, LastWriteTime |
    Format-Table -AutoSize | Out-String | ForEach-Object { & $log $_ }

& $log ''
& $log "=== DONE  evidence at $evidence ==="
$sz = (Get-Item $evidence).Length
Write-Host "Evidence file: $evidence"
Write-Host "Size: $sz bytes"
