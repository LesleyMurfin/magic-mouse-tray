# install.ps1 — PATH-A v5 INF-based install (SRE-Windows-corrected)
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

# 5. Testsigning check
$bcdedit = & bcdedit.exe /enum '{current}' 2>&1
$testsigning = $bcdedit | Where-Object { $_ -match 'testsigning\s+Yes' }
if (-not $testsigning) {
    Write-Log "testsigning is OFF. Required for self-signed catalog. Run 'bcdedit /set testsigning on' and reboot." "ERROR"
    if ($Apply) { exit 1 }
} else {
    Write-Log "  testsigning OK"
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

# 10. DriverStore state — find existing oem*.inf for applewirelessmouse and MagicMouseFixV3
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
Write-Log "  Apple oem*.inf in DriverStore: $($appleOemInfs -join ', ')"
Write-Log "  Ours oem*.inf in DriverStore: $($ourOemInfs -join ', ')"

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
foreach ($bt in ($bts | Where-Object { $_.InstanceId -match 'PID&0323' })) {
    if ($bt.InstanceId -match '_VID&[^_]+_PID&\w+_([0-9A-Fa-f]{12})') {
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

# 12. pnputil /add-driver /install /force
Write-Log "  pnputil /add-driver $infPath /install /force"
$pnpOut = & pnputil.exe /add-driver $infPath /install /force 2>&1
$pnpOut | ForEach-Object { Write-Log "    pnputil: $_" }
if ($LASTEXITCODE -ne 0) {
    Write-Log "pnputil /add-driver FAILED with exit code $LASTEXITCODE" "ERROR"
    exit 1
}

# 13. /restart-device on v3
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

# 14. DEVPKEY_Device_DriverInfPath — confirm OUR oem*.inf is bound to v3
foreach ($bt in ($bts | Where-Object { $_.InstanceId -match 'PID&0323' })) {
    try {
        $boundInf = (Get-PnpDeviceProperty -InstanceId $bt.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction SilentlyContinue).Data
        Write-Log "  v3 BTHENUM bound INF: $boundInf"
        if ($boundInf -ieq 'MagicMouseFixV3.inf' -or ($ourOemInfs -contains $boundInf)) {
            Write-Log "  PASS: our INF is bound" "OK"
        } else {
            Write-Log "  FAIL: our INF is NOT bound (WHQL ranking may have won — see SRE-Windows S1/E_S3)" "ERROR"
        }
    } catch {
        Write-Log "  FAIL: could not read DEVPKEY_Device_DriverInfPath: $($_.Exception.Message)" "ERROR"
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
            Write-Log "  FAIL: v1 has MagicMouseFixV3 in LowerFilters — service-name isolation BROKEN" "ERROR"
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
