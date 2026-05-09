# uninstall.ps1 — PATH-A v5 INF-based rollback (SRE-Windows-corrected)
#
# Removes our INF binding and restores stock applewirelessmouse for v3. This
# does NOT touch Apple's stock oem10.inf (which still binds applewirelessmouse
# for v1/v2/0310/0323 if our INF is removed).
#
# Steps:
#   1. pnputil /delete-driver <our-oem>.inf /uninstall /force
#   2. pnputil /restart-device on v3 BTHENUM (rebinds to stock oem10.inf)
#   3. Verify stock f4ae407c is loaded
#   4. Optionally restore BTHPORT cache backup (--RestoreCache)
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1 -RestoreCache

[CmdletBinding()]
param(
    [string]$LogDir = "C:\ProgramData\MagicMouseFix\install-logs",
    [switch]$RestoreCache,
    [string]$CacheBackupHive = ""    # path to .hiv from install.ps1 (optional)
)

$ErrorActionPreference = 'Stop'
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile = Join-Path $LogDir "uninstall-pathA-v5-$ts.log"

function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Msg"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Test-Admin {
    $current = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Log "Must run as Administrator" "ERROR"
    exit 1
}

Write-Log "PATH-A v5 uninstall (start)"

# 1. Find our oem*.inf in DriverStore
$enumDrivers = & pnputil /enum-drivers 2>&1
$ourOemInfs = @()
$current = $null
foreach ($line in $enumDrivers) {
    if ($line -match '^\s*Published Name\s*:\s*(oem\d+\.inf)') {
        $current = @{ Published = $matches[1] }
    } elseif ($current -and $line -match '^\s*Original Name\s*:\s*(.+)$') {
        $current.Original = $matches[1].Trim()
    } elseif ($current -and $line -match '^\s*Provider Name\s*:\s*(.+)$') {
        if ($current.Original -ieq 'MagicMouseFixV3.inf') {
            $ourOemInfs += $current.Published
        }
        $current = $null
    }
}
Write-Log "Our oem*.inf entries: $($ourOemInfs -join ', ')"

if ($ourOemInfs.Count -eq 0) {
    Write-Log "No MagicMouseFixV3.inf in DriverStore. Nothing to remove." "WARN"
} else {
    foreach ($oem in $ourOemInfs) {
        Write-Log "pnputil /delete-driver $oem /uninstall /force"
        $out = & pnputil.exe /delete-driver $oem /uninstall /force 2>&1
        $out | ForEach-Object { Write-Log "  pnputil: $_" }
    }
}

# 2. Stop & remove the service if it's still registered
$svc = Get-Service MagicMouseFixV3 -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -eq 'Running') {
        Write-Log "Stopping service MagicMouseFixV3"
        Stop-Service MagicMouseFixV3 -Force -ErrorAction SilentlyContinue
    }
    Write-Log "Removing service MagicMouseFixV3 (sc.exe delete)"
    & sc.exe delete MagicMouseFixV3 2>&1 | ForEach-Object { Write-Log "  sc: $_" }
}

# 3. Remove our binary if present
$ourSys = "C:\Windows\System32\drivers\MagicMouseFixV3.sys"
if (Test-Path $ourSys) {
    Write-Log "Removing $ourSys"
    Remove-Item $ourSys -Force -ErrorAction SilentlyContinue
}

# 4. Restart v3 BTHENUM device so it rebinds to stock oem10.inf
$v3 = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'BTHENUM.*00001124.*PID&0323' } | Select-Object -First 1
if ($v3) {
    Write-Log "pnputil /restart-device $($v3.InstanceId)"
    $out = & pnputil.exe /restart-device "$($v3.InstanceId)" 2>&1
    $out | ForEach-Object { Write-Log "  pnputil: $_" }
    Start-Sleep -Seconds 8
}

# 5. Optional BTHPORT cache restore
if ($RestoreCache -and $CacheBackupHive -and (Test-Path $CacheBackupHive)) {
    # BTHENUM instance ID MAC: between '&0&' and '_C' suffix (validated 2026-05-09).
    if ($v3 -and $v3.InstanceId -match '&0&([0-9A-Fa-f]{12})_C\d+$') {
        $mac = $matches[1].ToUpper()
        Write-Log "Restoring BTHPORT cache for MAC $mac from $CacheBackupHive"
        & reg.exe restore "HKLM\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices\$mac\Cache" $CacheBackupHive 2>&1 |
            ForEach-Object { Write-Log "  reg: $_" }
    }
}

# 6. Verify stock binary
$stockSys = "C:\Windows\System32\drivers\applewirelessmouse.sys"
if (Test-Path $stockSys) {
    $md5 = (Get-FileHash $stockSys -Algorithm MD5).Hash
    Write-Log "stock applewirelessmouse.sys MD5: $md5"
    if ($md5 -ieq 'f4ae407c228c3db6147d9e3307ed5f20') {
        Write-Log "PASS: stock f4ae407c restored" "OK"
    } else {
        Write-Log "WARN: stock binary MD5 differs from f4ae407c — may need full restore-apple-driver.ps1" "WARN"
    }
}

Write-Log "PATH-A v5 uninstall (complete)"
Write-Log "Full log: $LogFile"
