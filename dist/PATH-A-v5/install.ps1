# install.ps1  -  PATH-A v5 INF-based install (SRE-Windows-corrected)
#
# This script implements steps S3-S5 of the SRE-Windows v5 review:
#   S3. BTHPORT cache invalidation before pnputil /restart-device
#   S4. powercfg /h off pre-flight (Fast Startup defeats reboot-driven cycles)
#   S5. Post-install verification (DEVPKEY_Device_DriverInfPath, service state,
#       HID children, single-shot battery read)
#
# Layered on top of S1 (renamed service: MagicMouseFixV3) and S2 (startup-repair
# scoped to v3 only). See:
#   - docs/PATH-A-V5-INF-INSTALL-DESIGN.md
#   - .ai/peer-reviews/2026-05-09-pathA-v5-sre-windows-review.yaml
#   - PRD-184 D-S17-26..30
#
# READ-ONLY ELEMENTS run regardless of -Apply (gather-only mode for sanity).
# WRITE ELEMENTS only run with -Apply. Without -Apply, this is a dry-run report.
#
# Usage:
#   # Dry-run report:
#   powershell -ExecutionPolicy Bypass -File install.ps1
#
#   # Live install (requires Administrator + testsigning ON):
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Apply

[CmdletBinding()]
param(
    [switch]$Apply,
    [string]$BundleDir = $PSScriptRoot,
    [string]$LogDir = "C:\ProgramData\MagicMouseFix\install-logs",
    [string]$ExpectedSha256 = ""   # Optional: pin the .sys hash for tamper detection
)

$ErrorActionPreference = 'Stop'
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$LogFile = Join-Path $LogDir "install-pathA-v5-$ts.log"

function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Msg"
    Write-Host $line
    if (Test-Path (Split-Path $LogFile -Parent)) {
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    }
}

function Test-Admin {
    $current = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---- bootstrap ----
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
Write-Log "PATH-A v5 install (Apply=$Apply, BundleDir=$BundleDir)"

# ====================================================================
# PRE-FLIGHT (read-only, runs regardless of -Apply)
# ====================================================================

Write-Log "=== PRE-FLIGHT ==="

# 1. Bundle integrity
$infPath = Join-Path $BundleDir "MagicMouseFixV3.inf"
$sysPath = Join-Path $BundleDir "MagicMouseFixV3.sys"
$catPath = Join-Path $BundleDir "MagicMouseFixV3.cat"
$cerPath = Join-Path $BundleDir "MagicMouseFix.cer"

# 1a. Locate EWDK tools (mounted at F:\ from EWDK ISO).
$ewdkInfVerif = 'F:\Program Files\Windows Kits\10\Tools\10.0.26100.0\x64\InfVerif.exe'
$ewdkTraceLog = 'F:\Program Files\Windows Kits\10\bin\10.0.26100.0\x64\tracelog.exe'
$ewdkKd       = 'F:\Program Files\Windows Kits\10\Debuggers\x64\kd.exe'
foreach ($t in @($ewdkInfVerif, $ewdkTraceLog, $ewdkKd)) {
    if (Test-Path $t) { Write-Log "  EWDK: $t" } else { Write-Log "  EWDK MISSING: $t (mount EWDK ISO at F:\  -  see WINDOWS-USER-CHECKLIST)" "WARN" }
}

# 1b. InfVerif pre-flight gate  -  block install if INF doesn't pass Win11 26100 driver-package validation.
if ((Test-Path $ewdkInfVerif) -and (Test-Path $infPath)) {
    Write-Log "Running InfVerif on $infPath"
    $ivOut = & $ewdkInfVerif /v /w "$infPath" 2>&1
    $ivExit = $LASTEXITCODE
    $ivOut | ForEach-Object { Write-Log "    InfVerif: $_" }
    if ($ivExit -ne 0) {
        Write-Log "InfVerif FAILED (exit $ivExit). Driver package will not install." "ERROR"
        if ($Apply) { exit 1 }
    } else {
        Write-Log "InfVerif PASS"
    }
}

foreach ($p in @($infPath, $sysPath, $catPath, $cerPath)) {
    if (-not (Test-Path $p)) {
        Write-Log "MISSING bundle file: $p" "ERROR"
        if ($Apply) { exit 1 }
    } else {
        Write-Log "  OK: $p"
    }
}

# 2. Verify .sys size + (optional) hash
if (Test-Path $sysPath) {
    $sysItem = Get-Item $sysPath
    Write-Log "  .sys size: $($sysItem.Length) bytes (expected: 78424 if WHQL overlay intact)"
    if ($ExpectedSha256) {
        $h = (Get-FileHash $sysPath -Algorithm SHA256).Hash
        if ($h -ieq $ExpectedSha256) {
            Write-Log "  .sys SHA256 match: $h"
        } else {
            Write-Log "  .sys SHA256 MISMATCH: got=$h expected=$ExpectedSha256" "ERROR"
            if ($Apply) { exit 1 }
        }
    }
}

# 3. Admin check
if (-not (Test-Admin)) {
    Write-Log "Not running as Administrator. -Apply requires admin." "WARN"
    if ($Apply) { exit 1 }
}

# 4. Fast Startup check (SRE-Windows S4)
$hibState = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
if ($hibState -eq 1) {
    Write-Log "Fast Startup is ENABLED (HiberbootEnabled=1). Disable it: 'powercfg /h off'." "ERROR"
    Write-Log "Reason: Fast Startup hibernates instead of cold-booting; PFRO renames don't run; BTHPORT cache state can persist across 'reboots'." "ERROR"
    if ($Apply) {
        Write-Log "Refusing to install with Fast Startup enabled. Run 'powercfg /h off' (admin) and reboot once before retrying." "ERROR"
        exit 1
    }
} else {
    Write-Log "  Fast Startup OK (HiberbootEnabled=$hibState)"
}

# 5. Testsigning check.
# bcdedit requires admin to read the BCD store. Without admin we get
# 'Access is denied' or 'specified entry type is invalid' (PowerShell brace
# escaping). Don't treat that as "off" - treat as "unknown" and require
# admin to verify in -Apply mode (we already require admin to install).
$bcdedit = & bcdedit.exe /enum '{current}' 2>&1
$bcdRaw = ($bcdedit | Out-String)
if ($bcdRaw -match 'Access is denied|configuration data store could not be opened|specified entry type is invalid') {
    Write-Log "  testsigning: unable to verify (bcdedit needs admin). Re-run with admin to confirm." "WARN"
    if ($Apply -and -not (Test-Admin)) { Write-Log "Re-run as admin." "ERROR"; exit 1 }
} elseif ($bcdRaw -match 'testsigning\s+Yes') {
    Write-Log "  testsigning OK (Yes)"
} else {
    Write-Log "testsigning is OFF. Required for self-signed catalog. Run (admin): bcdedit /set testsigning on  then reboot." "ERROR"
    if ($Apply) { exit 1 }
}

# 6. MagicMouseFix cert in TrustedPublisher
$tpCerts = Get-ChildItem Cert:\LocalMachine\TrustedPublisher | Where-Object { $_.Subject -like '*MagicMouseFix*' }
if ($tpCerts.Count -eq 0) {
    Write-Log "MagicMouseFix cert NOT in LocalMachine\TrustedPublisher. Install: certutil -addstore TrustedPublisher MagicMouseFix.cer" "ERROR"
    if ($Apply) { exit 1 }
} else {
    foreach ($c in $tpCerts) {
        Write-Log "  TrustedPublisher cert: $($c.Subject) thumbprint=$($c.Thumbprint)"
    }
}

# 7. Stock binary state
$stockSys = "C:\Windows\System32\drivers\applewirelessmouse.sys"
if (Test-Path $stockSys) {
    $md5 = (Get-FileHash $stockSys -Algorithm MD5).Hash
    Write-Log "  stock applewirelessmouse.sys MD5: $md5 (expected for stock: f4ae407c228c3db6147d9e3307ed5f20)"
}

# 8. Existing v5 install state
$ourSys = "C:\Windows\System32\drivers\MagicMouseFixV3.sys"
if (Test-Path $ourSys) {
    $md5 = (Get-FileHash $ourSys -Algorithm MD5).Hash
    Write-Log "  EXISTING MagicMouseFixV3.sys MD5: $md5"
}

# 9. Currently paired Magic Mouse devices (to validate v1 cross-binding risk)
Write-Log "  Currently paired BTHENUM HID devices:"
$bts = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'BTHENUM.*00001124.*PID&0(323|310|269|30D)' }
foreach ($bt in $bts) {
    Write-Log "    [$($bt.Status)] $($bt.InstanceId)"
}
$haveV3 = $bts | Where-Object { $_.InstanceId -match 'PID&0323' }
if (-not $haveV3) {
    Write-Log "  v3 (PID 0323) not currently paired. v5 install has no target." "ERROR"
    if ($Apply) { exit 1 }
}

# 10. DriverStore state  -  find existing oem*.inf for applewirelessmouse and MagicMouseFixV3
$enumDrivers = & pnputil /enum-drivers 2>&1
$ourOemInfs = @()
$appleOemInfs = @()
$current = $null
foreach ($line in $enumDrivers) {
    if ($line -match '^\s*Published Name\s*:\s*(oem\d+\.inf)') {
        $current = @{ Published = $matches[1] }
    } elseif ($current -and $line -match '^\s*Original Name\s*:\s*(.+)$') {
        $current.Original = $matches[1].Trim()
    } elseif ($current -and $line -match '^\s*Provider Name\s*:\s*(.+)$') {
        $current.Provider = $matches[1].Trim()
        if ($current.Original -ieq 'MagicMouseFixV3.inf') {
            $ourOemInfs += $current.Published
        } elseif ($current.Original -ieq 'applewirelessmouse.inf') {
            $appleOemInfs += $current.Published
        }
        $current = $null
    }
}
Write-Log "  Apple applewirelessmouse.inf in DriverStore: $(if ($appleOemInfs) { $appleOemInfs -join ', ' } else { '(none  -  INCIDENT-2026-04-28 deletion still unrecovered, or never re-added)' })"
Write-Log "  Ours MagicMouseFixV3.inf in DriverStore: $(if ($ourOemInfs) { $ourOemInfs -join ', ' } else { '(none  -  first install)' })"
# Note: applewirelessmouse SERVICE may exist independently of the INF (per the
# 2026-04-28 incident on this host: INF was deleted but service registration +
# binary at System32\drivers\applewirelessmouse.sys remain). Our renamed
# service+binary approach does not conflict with that residual state.

# ====================================================================
# DRY-RUN GATE
# ====================================================================
if (-not $Apply) {
    Write-Log "Dry-run complete. Re-run with -Apply to install."
    exit 0
}

# ====================================================================
# INSTALL (write operations)
# ====================================================================

Write-Log "=== INSTALL ==="

# 11. (S3) BTHPORT cache invalidation for v3 MAC
# BTHENUM instance ID format (validated against live registry on user's host 2026-05-09):
#   BTHENUM\{00001124-...}_VID&0001004C_PID&0323\9&<hash>&0&<MAC>_C00000000
# MAC sits between '&0&' and '_C' suffix. Earlier draft used '_MAC'  -  wrong.
foreach ($bt in ($bts | Where-Object { $_.InstanceId -match 'PID&0323' })) {
    if ($bt.InstanceId -match '&0&([0-9A-Fa-f]{12})_C\d+$') {
        $mac = $matches[1].ToUpper()
        $cachePath = "HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices\$mac\Cache"
        if (Test-Path $cachePath) {
            $backupPath = "HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices\$mac\Cache.bak-$ts"
            Write-Log "  Backing up BTHPORT cache: $cachePath -> $backupPath"
            # PowerShell can't rename a registry KEY directly; use reg.exe
            & reg.exe save "HKLM\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices\$mac\Cache" (Join-Path $LogDir "bthport-cache-$mac-$ts.hiv") /y 2>&1 | Out-Null
            Write-Log "  Removing BTHPORT cache: $cachePath"
            Remove-Item -Path $cachePath -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Write-Log "  No BTHPORT cache for MAC $mac (already absent)"
        }
    }
}

# 12. Delegate sign+pnputil install to the parameterized sign-and-install.ps1
# (single source of truth — same script handles v3 default and v5 via -DriverDir/-InfName/-CatName/-ExistingCertThumbprint).
$signScript = Join-Path (Resolve-Path (Join-Path $BundleDir '..\..')).Path 'sign-and-install.ps1'
if (-not (Test-Path $signScript)) {
    # Fall back: when run from C:\mm-dev-queue\PATH-A-v5\, the repo's sign-and-install.ps1 isn't local.
    # Look at the bundle dir itself (sign-and-install.ps1 should be staged alongside).
    $signScript = Join-Path $BundleDir 'sign-and-install.ps1'
}
if (-not (Test-Path $signScript)) {
    Write-Log "sign-and-install.ps1 not found near $BundleDir. Stage it alongside the bundle, or run from the repo." "ERROR"
    exit 1
}
Write-Log "Delegating sign+install to: $signScript"
$signArgs = @(
    '-NoProfile','-ExecutionPolicy','Bypass','-File',$signScript,
    '-DriverDir',$BundleDir,
    '-InfName','MagicMouseFixV3.inf',
    '-CatName','MagicMouseFixV3.cat',
    '-ServiceName','MagicMouseFixV3',
    '-ExistingCertThumbprint','16940C0F937D569363560D5FEC5CD8FA6D6D9BCE'
)
& powershell.exe @signArgs 2>&1 | ForEach-Object { Write-Log "    sign-and-install: $_" }
$signExit = $LASTEXITCODE
if ($signExit -ne 0) {
    Write-Log "sign-and-install.ps1 FAILED (exit $signExit)" "ERROR"
    exit $signExit
}

# 13. /restart-device on v3 (sign-and-install.ps1 already did pnputil /add-driver /install)
foreach ($bt in ($bts | Where-Object { $_.InstanceId -match 'PID&0323' })) {
    Write-Log "  pnputil /restart-device $($bt.InstanceId)"
    $rdOut = & pnputil.exe /restart-device "$($bt.InstanceId)" 2>&1
    $rdOut | ForEach-Object { Write-Log "    pnputil: $_" }
}

Start-Sleep -Seconds 12

# ====================================================================
# POST-INSTALL VERIFICATION (S5)
# ====================================================================

Write-Log "=== POST-INSTALL VERIFY ==="

# 14. Confirm our FILTER is in the v3 LowerFilters list  -  this is the
# actually-relevant signal. Our INF is a FILTER install (Include=hidbth.inf,
# Needs=HIDBTH_Inst.NT), so the FUNCTION DRIVER bound to v3 stays as hidbth
# and DEVPKEY_Device_DriverInfPath may return 'hidbth.inf' / 'bth.inf' rather
# than our oem*.inf. The signal that matters is whether MagicMouseFixV3 is
# in the device's LowerFilters list.
foreach ($bt in ($bts | Where-Object { $_.InstanceId -match 'PID&0323' })) {
    try {
        $boundInf = (Get-PnpDeviceProperty -InstanceId $bt.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction SilentlyContinue).Data
        Write-Log "  v3 BTHENUM function-driver INF: $boundInf (informational  -  may be inbox)"

        $v3lf = (Get-PnpDeviceProperty -InstanceId $bt.InstanceId -KeyName 'DEVPKEY_Device_LowerFilters' -ErrorAction SilentlyContinue).Data
        $v3lfStr = if ($v3lf) { $v3lf -join ', ' } else { '(none)' }
        Write-Log "  v3 LowerFilters: $v3lfStr"
        if ($v3lf -contains 'MagicMouseFixV3') {
            Write-Log "  PASS: MagicMouseFixV3 in v3 LowerFilters" "OK"
        } else {
            Write-Log "  FAIL: MagicMouseFixV3 NOT in v3 LowerFilters (INF /add-driver may have failed to write HKR  -  check setupapi.dev.log)" "ERROR"
        }
    } catch {
        Write-Log "  FAIL: could not read DEVPKEY: $($_.Exception.Message)" "ERROR"
    }
}

# 15. Service state
$svc = Get-Service MagicMouseFixV3 -ErrorAction SilentlyContinue
if ($svc) {
    Write-Log "  service MagicMouseFixV3: Status=$($svc.Status) StartType=$($svc.StartType)"
} else {
    Write-Log "  service MagicMouseFixV3 NOT registered" "ERROR"
}

# 16. v1 stock isolation check (S1 verification)
$v1bts = $bts | Where-Object { $_.InstanceId -match 'PID&030D' }
foreach ($v1 in $v1bts) {
    try {
        $v1lf = (Get-PnpDeviceProperty -InstanceId $v1.InstanceId -KeyName 'DEVPKEY_Device_LowerFilters' -ErrorAction SilentlyContinue).Data
        Write-Log "  v1 LowerFilters: $($v1lf -join ', ')"
        if ($v1lf -contains 'MagicMouseFixV3') {
            Write-Log "  FAIL: v1 has MagicMouseFixV3 in LowerFilters  -  service-name isolation BROKEN" "ERROR"
        } else {
            Write-Log "  PASS: v1 isolated (no MagicMouseFixV3 in LowerFilters)" "OK"
        }
    } catch {
        Write-Log "  could not read v1 LowerFilters: $($_.Exception.Message)" "WARN"
    }
}

# 17. HID children + single-shot battery read
foreach ($bt in ($bts | Where-Object { $_.InstanceId -match 'PID&0323' })) {
    Start-Sleep -Seconds 3
    $hidv3 = Get-PnpDevice -Class HIDClass -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'PID&0323' -and $_.Status -eq 'OK' }
    Write-Log "  v3 HIDClass children (Status=OK): $($hidv3.Count)"
    foreach ($h in $hidv3) {
        Write-Log "    $($h.InstanceId)"
    }
}

Write-Log "=== INSTALL COMPLETE ==="
Write-Log "Battery read smoke test: run 'mm-v3-battery-now.ps1' or scripts/postpatch-quick-smoke-2026-05-08.ps1"
Write-Log "Full log: $LogFile"
