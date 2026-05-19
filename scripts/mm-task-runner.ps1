# mm-task-runner.ps1 - invoked by the SYSTEM scheduled task 'MM-Dev-Cycle'.
#
# Protocol (filesystem queue, ASCII text, pipe-delimited):
#   Request:  C:\mm-dev-queue\request.txt   "PHASE|NONCE[|arg...]"
#   Result:   C:\mm-dev-queue\result.txt    "EXITCODE|NONCE"
#   Lock:     C:\mm-dev-queue\running.lock  (created on enter, removed on exit)
#
# WSL drops a request, triggers `schtasks /run /tn MM-Dev-Cycle`, and polls
# result.txt for a matching nonce. The nonce prevents reading a stale result
# from a previous run.
#
# Phase 3 build routes (pipe-delimited args after PHASE|NONCE):
#   BUILD|<nonce>|<config>|<platform>[|<sln-path>]
#     config:    Release | Debug
#     platform:  x64
#     sln-path:  optional; defaults to driver\M12.sln on WSL path
#     log:       C:\mm-dev-queue\build-<nonce>.log
#
#   SIGN|<nonce>|<sys-path>|<cat-path>|<pfx-path>|<pfx-pass-env-var>
#     sys-path:       full Windows path to .sys file
#     cat-path:       full Windows path to .cat file
#     pfx-path:       full Windows path to .pfx file
#     pfx-pass-env-var: name of env var holding PFX password (avoids plaintext)
#     log:      C:\mm-dev-queue\sign-<nonce>.log
#
#   DV-CHECK|<nonce>|<driver-name>
#     driver-name: e.g. M12.sys (just the filename, no path)
#     log:      C:\mm-dev-queue\dv-<nonce>.log
#     result 0: Driver Verifier configured (reboot required to activate)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$QueueDir   = 'C:\mm-dev-queue'
$ReqFile    = Join-Path $QueueDir 'request.txt'
$ResFile    = Join-Path $QueueDir 'result.txt'
$LockFile   = Join-Path $QueueDir 'running.lock'
$TaskLog    = 'C:\mm-dev-task.log'

function Log {
    param([string]$Msg)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "[$ts] $Msg" | Add-Content -Path $TaskLog -Encoding UTF8
}

if (-not (Test-Path $QueueDir)) { New-Item -ItemType Directory $QueueDir -Force | Out-Null }

# Reject concurrent runs (Settings/MultipleInstances=IgnoreNew should prevent
# this anyway, but belt-and-braces against a stale lock from a crashed run)
if (Test-Path $LockFile) {
    $lockAge = (Get-Date) - (Get-Item $LockFile).LastWriteTime
    if ($lockAge.TotalMinutes -lt 30) {
        Log "Concurrent run detected (lock $($lockAge.TotalSeconds)s old) - exiting"
        exit 75
    } else {
        Log "Stale lock found ($($lockAge.TotalMinutes) min old) - removing"
        Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
    }
}

New-Item -Path $LockFile -ItemType File -Force | Out-Null
Log "===== task started ====="

try {
    if (-not (Test-Path $ReqFile)) {
        Log "No request file - exiting cleanly"
        exit 0
    }

    $raw = (Get-Content $ReqFile -Raw -Encoding ASCII).Trim()
    if (-not $raw) {
        Log "Empty request - exiting"
        exit 0
    }

    $parts = $raw -split '\|'
    $phase = $parts[0].Trim()
    $nonce = if ($parts.Count -gt 1) { $parts[1].Trim() } else { 'no-nonce' }
    Log "Request parsed: phase='$phase' nonce='$nonce' args=$($parts.Count - 2)"

    $rc = 0

    # BUILD route: ensure EWDK ISO is mounted, then delegate to mm-dev.ps1 -Phase Build.
    # mm-dev.ps1 uses a temp .bat to avoid PowerShell→cmd quoting bugs and writes
    # to the session log. Task runner handles mount so mm-dev.ps1 stays simple.
    if ($phase -eq 'BUILD') {
        $isoPath  = 'D:\Users\Lesley\Downloads\EWDK_ge_release_svc_prod1_26100_250904-1728.iso'
        $ewdkSetup = $null
        foreach ($drv in [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady }) {
            $c = Join-Path $drv.RootDirectory.FullName 'BuildEnv\SetupBuildEnv.cmd'
            if (Test-Path $c) { $ewdkSetup = $c; break }
        }
        if (-not $ewdkSetup) {
            Log "EWDK not on any drive - mounting ISO $isoPath"
            try {
                $disk = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
                Start-Sleep -Milliseconds 1500  # let Windows assign the drive letter
                foreach ($drv in [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady }) {
                    $c = Join-Path $drv.RootDirectory.FullName 'BuildEnv\SetupBuildEnv.cmd'
                    if (Test-Path $c) { $ewdkSetup = $c; break }
                }
                if ($ewdkSetup) { Log "EWDK mounted, found at $ewdkSetup" }
                else { Log "ERROR: mounted ISO but SetupBuildEnv.cmd not found"; $rc = 1 }
            } catch {
                Log "Mount-DiskImage failed: $_"
                $rc = 1
            }
        } else {
            Log "EWDK already mounted at $ewdkSetup"
        }

        if ($rc -eq 0) {
            $candidates = @('D:\mm3-driver\scripts\mm-dev.ps1', 'C:\mm3-pkg\scripts\mm-dev.ps1')
            $devScript  = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
            Log "BUILD → delegating to $devScript"
            if (-not $devScript) {
                Log "ERROR: mm-dev.ps1 not found"
                $rc = 127
            } else {
                try {
                    & $devScript -Phase Build -NoElevate
                    $rc = $LASTEXITCODE
                    if ($null -eq $rc) { $rc = 0 }
                } catch {
                    Log "Exception in BUILD delegate: $_"
                    $rc = 99
                }
            }
        }
        Log "BUILD exited $rc"
    }
    # SIGN route: signtool sign .sys + .cat with a PFX cert, OR delegate to mm-dev.ps1.
    # With no args → delegates to mm-dev.ps1 -Phase Sign (uses thumbprint cert).
    # With args → SIGN|<nonce>|<sys-path>|<cat-path>|<pfx-path>|<pfx-pass-env-var>
    elseif ($phase -eq 'SIGN') {
        $sysPath    = if ($parts.Count -gt 2) { $parts[2].Trim() } else { '' }
        $catPath    = if ($parts.Count -gt 3) { $parts[3].Trim() } else { '' }
        $pfxPath    = if ($parts.Count -gt 4) { $parts[4].Trim() } else { '' }
        $pfxPassVar = if ($parts.Count -gt 5) { $parts[5].Trim() } else { '' }

        if (-not $sysPath) {
            # No args: delegate to mm-dev.ps1 Sign phase (thumbprint-based signing)
            $candidates = @('D:\mm3-driver\scripts\mm-dev.ps1', 'C:\mm3-pkg\scripts\mm-dev.ps1')
            $devScript  = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
            Log "SIGN (no args) → delegating to $devScript"
            if (-not $devScript) { Log "ERROR: mm-dev.ps1 not found"; $rc = 127 }
            else {
                try {
                    & $devScript -Phase Sign -NoElevate
                    $rc = $LASTEXITCODE
                    if ($null -eq $rc) { $rc = 0 }
                } catch { Log "Exception in SIGN delegate: $_"; $rc = 99 }
            }
            Log "SIGN exited $rc"
        } else {

        $signLog    = Join-Path $QueueDir "sign-$nonce.log"
        $signtool   = 'F:\Program Files\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe'
        $tsUrl      = 'http://timestamp.digicert.com'

        Log "SIGN sys=$sysPath cat=$catPath pfx=$pfxPath passvar=$pfxPassVar"

        if (-not (Test-Path $signtool)) {
            $msg = "ERROR: signtool not found at $signtool"
            Log $msg
            $msg | Set-Content $signLog -Encoding ASCII
            $rc = 1
        } elseif (-not $sysPath -or -not $catPath -or -not $pfxPath) {
            $msg = "ERROR: SIGN requires sys-path, cat-path, and pfx-path args"
            Log $msg
            $msg | Set-Content $signLog -Encoding ASCII
            $rc = 2
        } else {
            $pfxPass = if ($pfxPassVar) { [Environment]::GetEnvironmentVariable($pfxPassVar) } else { '' }
            $passArgs = if ($pfxPass) { @('/p', $pfxPass) } else { @() }
            try {
                "=== Sign $sysPath ===" | Set-Content $signLog -Encoding ASCII
                & $signtool sign /fd sha256 /tr $tsUrl /td sha256 /f $pfxPath @passArgs $sysPath 2>&1 | Add-Content $signLog -Encoding ASCII
                $rc = $LASTEXITCODE
                if ($null -eq $rc) { $rc = 0 }
                "=== Sign $catPath ===" | Add-Content $signLog -Encoding ASCII
                & $signtool sign /fd sha256 /tr $tsUrl /td sha256 /f $pfxPath @passArgs $catPath 2>&1 | Add-Content $signLog -Encoding ASCII
                $rc2 = $LASTEXITCODE
                if ($null -eq $rc2) { $rc2 = 0 }
                if ($rc -eq 0) { $rc = $rc2 }
            } catch {
                "Exception: $_" | Add-Content $signLog -Encoding ASCII
                Log "Exception in SIGN: $_"
                $rc = 99
            }
        }
        Log "SIGN exited $rc; log at $signLog"
        }  # end else (has args)
    }
    # DV-CHECK route: configure Driver Verifier for a named driver
    # Request format: DV-CHECK|<nonce>|<driver-name>
    # Result 0 = verifier configured; actual enforcement requires reboot
    elseif ($phase -eq 'DV-CHECK') {
        $driverName = if ($parts.Count -gt 2) { $parts[2].Trim() } else { '' }
        $dvLog      = Join-Path $QueueDir "dv-$nonce.log"
        $dvFlags    = '0x49bb'

        Log "DV-CHECK driver=$driverName flags=$dvFlags"

        if (-not $driverName) {
            $msg = "ERROR: DV-CHECK requires driver-name arg (e.g. M12.sys)"
            Log $msg
            $msg | Set-Content $dvLog -Encoding ASCII
            $rc = 2
        } else {
            try {
                "=== verifier /flags $dvFlags /driver $driverName ===" | Set-Content $dvLog -Encoding ASCII
                & verifier /flags $dvFlags /driver $driverName /standard /reset 2>&1 | Add-Content $dvLog -Encoding ASCII
                $rc = $LASTEXITCODE
                if ($null -eq $rc) { $rc = 0 }
                "=== verifier /query ===" | Add-Content $dvLog -Encoding ASCII
                & verifier /query 2>&1 | Add-Content $dvLog -Encoding ASCII
            } catch {
                "Exception: $_" | Add-Content $dvLog -Encoding ASCII
                Log "Exception in DV-CHECK: $_"
                $rc = 99
            }
        }
        Log "DV-CHECK exited $rc; log at $dvLog"
    }
    # ROLLBACK-M12: uninstall M12 driver + reinstall Apple's INF from backup.
    # Request format: ROLLBACK-M12|<nonce>
    elseif ($phase -eq 'ROLLBACK-M12') {
        $rbLog = Join-Path $QueueDir "rollback-$nonce.log"
        try {
            "=== ROLLBACK-M12 start $(Get-Date) ===" | Set-Content $rbLog -Encoding ASCII
            $enum = & pnputil /enum-drivers 2>&1 | Out-String
            $rx = [regex]'(?ms)Published Name:\s*(oem\d+\.inf)\s*\nOriginal Name:\s*magicmousedriver\.inf'
            $m = $rx.Match($enum)
            if ($m.Success) {
                $oem = $m.Groups[1].Value
                "Removing $oem ..." | Add-Content $rbLog -Encoding ASCII
                & pnputil /delete-driver $oem /uninstall /force 2>&1 | Add-Content $rbLog -Encoding ASCII
            } else {
                "M12 not registered (or pnputil format unexpected)" | Add-Content $rbLog -Encoding ASCII
            }
            $apple = 'D:\Backups\AppleWirelessMouse-RECOVERY\applewirelessmouse.inf'
            if (Test-Path $apple) {
                "Restoring Apple driver from $apple ..." | Add-Content $rbLog -Encoding ASCII
                & pnputil /add-driver $apple /install 2>&1 | Add-Content $rbLog -Encoding ASCII
                $rc = 0
            } else {
                "ERROR: Apple INF backup not found at $apple" | Add-Content $rbLog -Encoding ASCII
                $rc = 3
            }
            "=== ROLLBACK-M12 end $(Get-Date) ===" | Add-Content $rbLog -Encoding ASCII
        } catch {
            "Exception: $_" | Add-Content $rbLog -Encoding ASCII
            $rc = 99
        }
        Log "ROLLBACK-M12 exited $rc; log at $rbLog"
    }
    # INSTALL-DRIVER: pnputil /add-driver <inf> /install. Format: INSTALL-DRIVER|<nonce>|<inf-path>
    elseif ($phase -eq 'INSTALL-DRIVER') {
        $infPath = if ($parts.Count -gt 2) { $parts[2].Trim() } else { '' }
        $instLog = Join-Path $QueueDir "install-$nonce.log"
        if (-not $infPath -or -not (Test-Path $infPath)) {
            "ERROR: INF path missing or not found: $infPath" | Set-Content $instLog -Encoding ASCII
            $rc = 2
        } else {
            try {
                "=== pnputil /add-driver $infPath /install ===" | Set-Content $instLog -Encoding ASCII
                & pnputil /add-driver $infPath /install 2>&1 | Add-Content $instLog -Encoding ASCII
                $rc = $LASTEXITCODE
                if ($null -eq $rc) { $rc = 0 }
            } catch {
                "Exception: $_" | Add-Content $instLog -Encoding ASCII
                $rc = 99
            }
        }
        Log "INSTALL-DRIVER exited $rc; log at $instLog"
    }
    # UNINSTALL-DRIVER: pnputil /delete-driver <oemNN.inf> /uninstall /force.
    # Format: UNINSTALL-DRIVER|<nonce>|<oemNN.inf>
    elseif ($phase -eq 'UNINSTALL-DRIVER') {
        $oem = if ($parts.Count -gt 2) { $parts[2].Trim() } else { '' }
        $unLog = Join-Path $QueueDir "uninstall-$nonce.log"
        if (-not $oem) {
            "ERROR: oemNN.inf name required" | Set-Content $unLog -Encoding ASCII
            $rc = 2
        } else {
            try {
                "=== pnputil /delete-driver $oem /uninstall /force ===" | Set-Content $unLog -Encoding ASCII
                & pnputil /delete-driver $oem /uninstall /force 2>&1 | Add-Content $unLog -Encoding ASCII
                $rc = $LASTEXITCODE
                if ($null -eq $rc) { $rc = 0 }
            } catch {
                "Exception: $_" | Add-Content $unLog -Encoding ASCII
                $rc = 99
            }
        }
        Log "UNINSTALL-DRIVER exited $rc; log at $unLog"
    }
    # CLEAR-BT-SDP-CACHE: delete CachedServices/DynamicCachedServices for a BT MAC.
    # Format: CLEAR-BT-SDP-CACHE|<nonce>|<MAC-12-hex-no-colons>
    elseif ($phase -eq 'CLEAR-BT-SDP-CACHE') {
        $mac = if ($parts.Count -gt 2) { $parts[2].Trim() } else { '' }
        $cbLog = Join-Path $QueueDir "bthcache-$nonce.log"
        if (-not $mac) {
            "ERROR: MAC required" | Set-Content $cbLog -Encoding ASCII
            $rc = 2
        } else {
            try {
                $base = "HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices\$mac"
                "=== clearing $base CachedServices + DynamicCachedServices ===" | Set-Content $cbLog -Encoding ASCII
                foreach ($sub in 'CachedServices','DynamicCachedServices') {
                    $p = "$base\$sub"
                    if (Test-Path $p) {
                        Remove-Item -Path $p -Recurse -Force -ErrorAction Stop
                        "removed $p" | Add-Content $cbLog -Encoding ASCII
                    } else {
                        "$p not present" | Add-Content $cbLog -Encoding ASCII
                    }
                }
                $rc = 0
            } catch {
                "Exception: $_" | Add-Content $cbLog -Encoding ASCII
                $rc = 99
            }
        }
        Log "CLEAR-BT-SDP-CACHE exited $rc; log at $cbLog"
    }
    # RESTART-DEVICE: pnputil /restart-device <instanceId> (requires SYSTEM/admin)
    elseif ($phase -eq 'RESTART-DEVICE') {
        $iid = if ($parts.Count -gt 2) { $parts[2..($parts.Count-1)] -join '|' } else { '' }
        $rdLog = Join-Path $QueueDir "restart-$nonce.log"
        if (-not $iid) {
            "ERROR: instance ID required" | Set-Content $rdLog -Encoding ASCII
            $rc = 2
        } else {
            try {
                "=== pnputil /restart-device $iid ===" | Set-Content $rdLog -Encoding ASCII
                & pnputil /restart-device $iid 2>&1 | Add-Content $rdLog -Encoding ASCII
                $rc = $LASTEXITCODE
                if ($null -eq $rc) { $rc = 0 }
            } catch {
                "Exception: $_" | Add-Content $rdLog -Encoding ASCII
                $rc = 99
            }
        }
        Log "RESTART-DEVICE exited $rc; log at $rdLog"
    }
    # DISABLE-ENABLE-DEVICE: pnputil /disable-device + sleep + /enable-device.
    # Forces full PnP re-enumeration; clears CM_PROB_FAILED_START state that
    # /restart-device alone won't lift.
    # Format: DISABLE-ENABLE-DEVICE|<nonce>|<instanceId>
    elseif ($phase -eq 'DISABLE-ENABLE-DEVICE') {
        $iid = if ($parts.Count -gt 2) { $parts[2..($parts.Count-1)] -join '|' } else { '' }
        $deLog = Join-Path $QueueDir "disable-enable-$nonce.log"
        if (-not $iid) {
            "ERROR: instance ID required" | Set-Content $deLog -Encoding ASCII
            $rc = 2
        } else {
            try {
                "=== pnputil /disable-device $iid ===" | Set-Content $deLog -Encoding ASCII
                & pnputil /disable-device $iid 2>&1 | Add-Content $deLog -Encoding ASCII
                Start-Sleep -Seconds 3
                "=== pnputil /enable-device $iid ===" | Add-Content $deLog -Encoding ASCII
                & pnputil /enable-device $iid 2>&1 | Add-Content $deLog -Encoding ASCII
                Start-Sleep -Seconds 12
                $dev = Get-PnpDevice -InstanceId $iid -EA SilentlyContinue
                "POST Status: $($dev.Status) Problem: $($dev.Problem)" | Add-Content $deLog -Encoding ASCII
                $rc = if ($dev.Status -eq 'OK') { 0 } else { 1 }
            } catch {
                "Exception: $_" | Add-Content $deLog -Encoding ASCII
                $rc = 99
            }
        }
        Log "DISABLE-ENABLE-DEVICE exited $rc; log at $deLog"
    }
    # SET-LOWERFILTERS: write LowerFilters value on a device's Enum key + restart-device.
    # Format: SET-LOWERFILTERS|<nonce>|<instanceId>|<filter1,filter2,...>
    # Pass empty filter list to clear (e.g., "SET-LOWERFILTERS|n|<id>|"). Backs up
    # the device's full Enum key to a .reg file before write.
    elseif ($phase -eq 'SET-LOWERFILTERS') {
        $iid     = if ($parts.Count -gt 2) { $parts[2].Trim() } else { '' }
        $filters = if ($parts.Count -gt 3) { $parts[3].Trim() } else { '' }
        $sfLog = Join-Path $QueueDir "setlf-$nonce.log"
        if (-not $iid) {
            "ERROR: instance ID required" | Set-Content $sfLog -Encoding ASCII
            $rc = 2
        } else {
            try {
                $regKey = "HKLM\SYSTEM\CurrentControlSet\Enum\$iid"
                $psPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$iid"
                $backupReg = Join-Path $QueueDir "setlf-backup-$nonce.reg"
                "=== SET-LOWERFILTERS iid=$iid filters=$filters ===" | Set-Content $sfLog -Encoding ASCII
                & reg.exe export $regKey $backupReg /y 2>&1 | Add-Content $sfLog -Encoding ASCII
                $pre = (Get-ItemProperty -Path $psPath -Name LowerFilters -EA SilentlyContinue).LowerFilters
                "PRE LowerFilters: $($pre -join ', ')" | Add-Content $sfLog -Encoding ASCII
                $newVal = if ($filters) { @($filters -split ',' | ForEach-Object { $_.Trim() }) } else { @() }
                if ($newVal.Count -eq 0) {
                    Remove-ItemProperty -Path $psPath -Name LowerFilters -EA SilentlyContinue
                } else {
                    Set-ItemProperty -Path $psPath -Name LowerFilters -Value $newVal -Type MultiString
                }
                "Set LowerFilters = $($newVal -join ', ')" | Add-Content $sfLog -Encoding ASCII
                "=== pnputil /restart-device ===" | Add-Content $sfLog -Encoding ASCII
                & pnputil /restart-device $iid 2>&1 | Add-Content $sfLog -Encoding ASCII
                Start-Sleep -Seconds 10
                $post = (Get-ItemProperty -Path $psPath -Name LowerFilters -EA SilentlyContinue).LowerFilters
                "POST LowerFilters: $($post -join ', ')" | Add-Content $sfLog -Encoding ASCII
                "Backup: $backupReg" | Add-Content $sfLog -Encoding ASCII
                $rc = 0
            } catch {
                "Exception: $_" | Add-Content $sfLog -Encoding ASCII
                $rc = 99
            }
        }
        Log "SET-LOWERFILTERS exited $rc; log at $sfLog"
    }
    # SIGN-FILE: signtool sign /sm /sha1 ... /fd sha256 /tr ... /td sha256 <file>
    # Format: SIGN-FILE|<nonce>|<file-path>|<thumbprint>
    elseif ($phase -eq 'SIGN-FILE') {
        $sf  = if ($parts.Count -gt 2) { $parts[2].Trim() } else { '' }
        $thb = if ($parts.Count -gt 3) { $parts[3].Trim() } else { 'B902C2864315E2DE359450024768CE7D01715C38' }
        $sfLog = Join-Path $QueueDir "signfile-$nonce.log"
        $signtool = 'F:\Program Files\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe'
        if (-not (Test-Path $sf)) {
            "ERROR: file not found: $sf" | Set-Content $sfLog -Encoding ASCII
            $rc = 2
        } else {
            try {
                "=== sign $sf with $thb ===" | Set-Content $sfLog -Encoding ASCII
                & $signtool sign /sm /sha1 $thb /fd sha256 /tr 'http://timestamp.digicert.com' /td sha256 /v $sf 2>&1 | Add-Content $sfLog -Encoding ASCII
                $rc = $LASTEXITCODE
                if ($null -eq $rc) { $rc = 0 }
            } catch {
                "Exception: $_" | Add-Content $sfLog -Encoding ASCII
                $rc = 99
            }
        }
        Log "SIGN-FILE exited $rc; log at $sfLog"
    }
    # PATCH-APPLE-SYS: stop service, copy patched .sys to System32\drivers, restart device.
    # Format: PATCH-APPLE-SYS|<nonce>|<patched-sys-path>
    elseif ($phase -eq 'PATCH-APPLE-SYS') {
        $src   = if ($parts.Count -gt 2) { $parts[2].Trim() } else { '' }
        $dest  = 'C:\Windows\System32\drivers\applewirelessmouse.sys'
        $btId  = 'BTHENUM\{00001124-0000-1000-8000-00805F9B34FB}_VID&0001004C_PID&0323'
        $paLog = Join-Path $QueueDir "patch-apple-$nonce.log"

        if (-not $src -or -not (Test-Path $src)) {
            "ERROR: patched sys not found: $src" | Set-Content $paLog -Encoding ASCII
            $rc = 2
        } else {
            try {
                "=== PATCH-APPLE-SYS $src -> $dest ===" | Set-Content $paLog -Encoding ASCII

                # Find the BTHENUM 00001124 (HID) device instance ID for the Magic Mouse
                $devEnum = & pnputil /enum-devices 2>&1 | Out-String
                $rxId = [regex]'(?i)Instance ID:\s+(BTHENUM\\{00001124[^\r\n]*004c[^\r\n]*0323[^\r\n]*)'
                $mId = $rxId.Match($devEnum)
                $devId = if ($mId.Success) { $mId.Groups[1].Value.Trim() } else { '' }
                "Device instance: '$devId'" | Add-Content $paLog -Encoding ASCII

                # Re-enable device if it was previously disabled (in case a prior attempt disabled it)
                if ($devId) {
                    "Re-enabling device (precautionary)..." | Add-Content $paLog -Encoding ASCII
                    & pnputil /enable-device "$devId" 2>&1 | Add-Content $paLog -Encoding ASCII
                }

                # Stage patched sys under a temp name in System32\drivers (no file lock on .new)
                $staged = $dest + '.new'
                "Staging to $staged ..." | Add-Content $paLog -Encoding ASCII
                Copy-Item -Path $src -Destination $staged -Force -ErrorAction Stop
                "Stage copy: OK" | Add-Content $paLog -Encoding ASCII

                # Queue PendingFileRenameOperations: on next boot, rename .new -> .sys (atomic replace)
                # Format: REG_MULTI_SZ, pairs of [src, dest] (NtMoveFile semantics at boot)
                # Pair 1: delete/rename original -> to nothing is not needed; MoveFileEx replaces
                # Use [System.IO.Path] NT prefix: \??\<path>
                $ntNew  = '\??\' + $staged
                $ntDest = '\??\' + $dest
                $regKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
                $existing = (Get-ItemProperty $regKey -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
                $newEntry = @($ntNew, $ntDest)
                if ($existing) {
                    # Remove any previous entry for this file to avoid duplicates
                    $cleaned = $existing | Where-Object { $_ -notlike "*applewirelessmouse*" }
                    $merged = [string[]]($cleaned + $newEntry)
                } else {
                    $merged = [string[]]$newEntry
                }
                Set-ItemProperty -Path $regKey -Name PendingFileRenameOperations -Value $merged -Type MultiString
                "PendingFileRenameOperations queued: $ntNew -> $ntDest" | Add-Content $paLog -Encoding ASCII
                "REBOOT REQUIRED to apply patch." | Add-Content $paLog -Encoding ASCII
                $rc = 0
            } catch {
                "Exception: $_" | Add-Content $paLog -Encoding ASCII
                Log "Exception in PATCH-APPLE-SYS: $_"
                $rc = 99
            }
        }
        Log "PATCH-APPLE-SYS exited $rc; log at $paLog"
    }
    # Special phase prefix "SNAPSHOT:Stack" routes to mm-bt-stack-snapshot.ps1
    elseif ($phase -like 'SNAPSHOT:*') {
        $snapScript = 'D:\mm3-driver\scripts\mm-bt-stack-snapshot.ps1'
        if (-not (Test-Path $snapScript)) {
            Log "ERROR: mm-bt-stack-snapshot.ps1 not found at $snapScript"
            "127|$nonce" | Set-Content $ResFile -Encoding ASCII
            exit 127
        }
        Log "Using $snapScript"
        try {
            & $snapScript
            $rc = $LASTEXITCODE
            if ($null -eq $rc) { $rc = 0 }
        } catch {
            Log "Exception running mm-bt-stack-snapshot.ps1: $_"
            $rc = 99
        }
    }
    # Special phase prefix "WPPDECODE:*" routes to mm-test-A3-wpp-decode.ps1
    elseif ($phase -like 'WPPDECODE:*') {
        $wppScript = 'D:\mm3-driver\scripts\mm-test-A3-wpp-decode.ps1'
        if (-not (Test-Path $wppScript)) {
            Log "ERROR: mm-test-A3-wpp-decode.ps1 not found at $wppScript"
            "127|$nonce" | Set-Content $ResFile -Encoding ASCII
            exit 127
        }
        Log "Using $wppScript"
        try {
            & $wppScript
            $rc = $LASTEXITCODE
            if ($null -eq $rc) { $rc = 0 }
        } catch {
            Log "Exception running mm-test-A3-wpp-decode.ps1: $_"
            $rc = 99
        }
    }
    # Special phase prefix "ETWBTH:*" routes to mm-test-A2-etw-bth-hid.ps1
    elseif ($phase -like 'ETWBTH:*') {
        $eScript = 'D:\mm3-driver\scripts\mm-test-A2-etw-bth-hid.ps1'
        if (-not (Test-Path $eScript)) {
            Log "ERROR: mm-test-A2-etw-bth-hid.ps1 not found at $eScript"
            "127|$nonce" | Set-Content $ResFile -Encoding ASCII
            exit 127
        }
        Log "Using $eScript"
        try {
            & $eScript
            $rc = $LASTEXITCODE
            if ($null -eq $rc) { $rc = 0 }
        } catch {
            Log "Exception running mm-test-A2-etw-bth-hid.ps1: $_"
            $rc = 99
        }
    }
    # Special phase prefix "PROCMONIO:*" routes to mm-test-C-procmon-iotest.ps1
    elseif ($phase -like 'PROCMONIO:*') {
        $pmScript = 'D:\mm3-driver\scripts\mm-test-C-procmon-iotest.ps1'
        if (-not (Test-Path $pmScript)) {
            Log "ERROR: mm-test-C-procmon-iotest.ps1 not found at $pmScript"
            "127|$nonce" | Set-Content $ResFile -Encoding ASCII
            exit 127
        }
        Log "Using $pmScript"
        try {
            & $pmScript
            $rc = $LASTEXITCODE
            if ($null -eq $rc) { $rc = 0 }
        } catch {
            Log "Exception running mm-test-C-procmon-iotest.ps1: $_"
            $rc = 99
        }
    }
    # Special phase prefix "CTRDUMP:*" routes to mm-container-dump.ps1
    elseif ($phase -like 'CTRDUMP:*') {
        $cdScript = 'D:\mm3-driver\scripts\mm-container-dump.ps1'
        if (-not (Test-Path $cdScript)) {
            Log "ERROR: mm-container-dump.ps1 not found at $cdScript"
            "127|$nonce" | Set-Content $ResFile -Encoding ASCII
            exit 127
        }
        Log "Using $cdScript"
        try {
            & $cdScript
            $rc = $LASTEXITCODE
            if ($null -eq $rc) { $rc = 0 }
        } catch {
            Log "Exception running mm-container-dump.ps1: $_"
            $rc = 99
        }
    }
    # Special phase prefix "DEVMGR:*" routes to mm-devmgr-dump.ps1
    elseif ($phase -like 'DEVMGR:*') {
        $dmScript = 'D:\mm3-driver\scripts\mm-devmgr-dump.ps1'
        if (-not (Test-Path $dmScript)) {
            Log "ERROR: mm-devmgr-dump.ps1 not found at $dmScript"
            "127|$nonce" | Set-Content $ResFile -Encoding ASCII
            exit 127
        }
        Log "Using $dmScript"
        try {
            & $dmScript
            $rc = $LASTEXITCODE
            if ($null -eq $rc) { $rc = 0 }
        } catch {
            Log "Exception running mm-devmgr-dump.ps1: $_"
            $rc = 99
        }
    }
    # Special phase prefix "EVTLOG:*" routes to mm-pnp-eventlog.ps1
    elseif ($phase -like 'EVTLOG:*') {
        $eScript = 'D:\mm3-driver\scripts\mm-pnp-eventlog.ps1'
        if (-not (Test-Path $eScript)) {
            Log "ERROR: mm-pnp-eventlog.ps1 not found at $eScript"
            "127|$nonce" | Set-Content $ResFile -Encoding ASCII
            exit 127
        }
        Log "Using $eScript"
        try {
            & $eScript
            $rc = $LASTEXITCODE
            if ($null -eq $rc) { $rc = 0 }
        } catch {
            Log "Exception running mm-pnp-eventlog.ps1: $_"
            $rc = 99
        }
    }
    # Special phase prefix "SVCCTRL:Action" routes to mm-svc-control.ps1
    elseif ($phase -like 'SVCCTRL:*') {
        $svcAction = ($phase -split ':', 2)[1]
        $svcScript = 'D:\mm3-driver\scripts\mm-svc-control.ps1'
        if (-not (Test-Path $svcScript)) {
            Log "ERROR: mm-svc-control.ps1 not found at $svcScript"
            "127|$nonce" | Set-Content $ResFile -Encoding ASCII
            exit 127
        }
        Log "Using $svcScript Action=$svcAction"
        try {
            & $svcScript -Action $svcAction
            $rc = $LASTEXITCODE
            if ($null -eq $rc) { $rc = 0 }
        } catch {
            Log "Exception running mm-svc-control.ps1: $_"
            $rc = 99
        }
    }
    # Special phase prefix "HIDREAD:*" routes to mm-hid-feature-read.ps1
    elseif ($phase -like 'HIDREAD:*') {
        $hrScript = 'D:\mm3-driver\scripts\mm-hid-feature-read.ps1'
        if (-not (Test-Path $hrScript)) {
            Log "ERROR: mm-hid-feature-read.ps1 not found at $hrScript"
            "127|$nonce" | Set-Content $ResFile -Encoding ASCII
            exit 127
        }
        Log "Using $hrScript"
        try {
            & $hrScript
            $rc = $LASTEXITCODE
            if ($null -eq $rc) { $rc = 0 }
        } catch {
            Log "Exception running mm-hid-feature-read.ps1: $_"
            $rc = 99
        }
    }
    # Special phase prefix "BATPROBE:*" routes to mm-battery-probe-deep.ps1
    elseif ($phase -like 'BATPROBE:*') {
        $bpScript = 'D:\mm3-driver\scripts\mm-battery-probe-deep.ps1'
        if (-not (Test-Path $bpScript)) {
            Log "ERROR: mm-battery-probe-deep.ps1 not found at $bpScript"
            "127|$nonce" | Set-Content $ResFile -Encoding ASCII
            exit 127
        }
        Log "Using $bpScript"
        try {
            & $bpScript
            $rc = $LASTEXITCODE
            if ($null -eq $rc) { $rc = 0 }
        } catch {
            Log "Exception running mm-battery-probe-deep.ps1: $_"
            $rc = 99
        }
    }
    # Special phase prefix "DISCOVER:Target" routes to mm-bthport-discover.ps1
    elseif ($phase -like 'DISCOVER:*') {
        $target = ($phase -split ':', 2)[1]
        $discScript = 'D:\mm3-driver\scripts\mm-bthport-discover.ps1'
        if (-not (Test-Path $discScript)) {
            Log "ERROR: mm-bthport-discover.ps1 not found at $discScript"
            "127|$nonce" | Set-Content $ResFile -Encoding ASCII
            exit 127
        }
        Log "Using $discScript Target=$target"
        try {
            if ($target -eq 'All') {
                & $discScript -AllDevices
            } else {
                & $discScript -Mac $target
            }
            $rc = $LASTEXITCODE
            if ($null -eq $rc) { $rc = 0 }
        } catch {
            Log "Exception running mm-bthport-discover.ps1: $_"
            $rc = 99
        }
    }
    # Special phase prefix "FLIP:Mode" routes to mm-state-flip.ps1 (LowerFilters mutation)
    elseif ($phase -like 'FLIP:*') {
        $mode = ($phase -split ':', 2)[1]
        $flipScript = 'D:\mm3-driver\scripts\mm-state-flip.ps1'
        if (-not (Test-Path $flipScript)) {
            Log "ERROR: mm-state-flip.ps1 not found at $flipScript"
            "127|$nonce" | Set-Content $ResFile -Encoding ASCII
            exit 127
        }
        Log "Using $flipScript Mode=$mode"
        try {
            & $flipScript -Mode $mode
            $rc = $LASTEXITCODE
            if ($null -eq $rc) { $rc = 0 }
        } catch {
            Log "Exception running mm-state-flip.ps1: $_"
            $rc = 99
        }
    }
    # PATHA-V5-INSTALL: full v5 install in one queue submission.
    # Format: PATHA-V5-INSTALL|<nonce>|<bundle-dir>
    # bundle-dir must contain MagicMouseFixV3.{inf,sys} + sign-and-install.ps1.
    # This route auto-mounts EWDK ISO if needed, runs InfVerif, regen+sign cat,
    # clears BTHPORT cache, pnputil add-driver, restart-device, verify LowerFilters.
    elseif ($phase -eq 'PATHA-V5-INSTALL') {
        $bundle = if ($parts.Count -gt 2) { $parts[2].Trim() } else { 'C:\mm-dev-queue\PATH-A-v5' }
        $v5Log  = Join-Path $QueueDir "pathA-v5-install-$nonce.log"
        try {
            "=== PATHA-V5-INSTALL bundle=$bundle ===" | Set-Content $v5Log -Encoding ASCII

            # Step 1: ensure EWDK ISO is mounted (reuse BUILD route's pattern)
            $isoPath = 'D:\Users\Lesley\Downloads\EWDK_ge_release_svc_prod1_26100_250904-1728.iso'
            $ewdkRoot = $null
            foreach ($drv in [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady }) {
                $c = Join-Path $drv.RootDirectory.FullName 'BuildEnv\SetupBuildEnv.cmd'
                if (Test-Path $c) { $ewdkRoot = $drv.RootDirectory.FullName; break }
            }
            if (-not $ewdkRoot) {
                "EWDK not mounted - mounting $isoPath" | Add-Content $v5Log -Encoding ASCII
                Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop | Out-Null
                Start-Sleep -Milliseconds 1500
                foreach ($drv in [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady }) {
                    $c = Join-Path $drv.RootDirectory.FullName 'BuildEnv\SetupBuildEnv.cmd'
                    if (Test-Path $c) { $ewdkRoot = $drv.RootDirectory.FullName; break }
                }
            }
            if (-not $ewdkRoot) { throw "EWDK not available even after mount attempt" }
            $infVerif = Join-Path $ewdkRoot 'Program Files\Windows Kits\10\Tools\10.0.26100.0\x64\InfVerif.exe'
            "EWDK at $ewdkRoot" | Add-Content $v5Log -Encoding ASCII

            # Step 2: bundle integrity
            $infPath = Join-Path $bundle 'MagicMouseFixV3.inf'
            $sysPath = Join-Path $bundle 'MagicMouseFixV3.sys'
            $signSrc = Join-Path $bundle 'sign-and-install.ps1'
            foreach ($p in @($infPath, $sysPath, $signSrc)) {
                if (-not (Test-Path $p)) { throw "Missing bundle file: $p" }
            }

            # Step 3: InfVerif gate
            "Running InfVerif on $infPath" | Add-Content $v5Log -Encoding ASCII
            & $infVerif /v /w "$infPath" 2>&1 | Add-Content $v5Log -Encoding ASCII
            if ($LASTEXITCODE -ne 0) { throw "InfVerif FAILED ($LASTEXITCODE)" }

            # Step 4: clear BTHPORT cache for v3 MAC (find it dynamically)
            $v3 = Get-PnpDevice -EA SilentlyContinue | Where-Object { $_.InstanceId -match 'BTHENUM.*00001124.*PID&0323' } | Select-Object -First 1
            if ($v3 -and $v3.InstanceId -match '&0&([0-9A-Fa-f]{12})_C\d+$') {
                $mac = $matches[1].ToUpper()
                $base = "HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices\$mac"
                foreach ($sub in 'CachedServices','DynamicCachedServices','Cache') {
                    if (Test-Path "$base\$sub") {
                        Remove-Item -Path "$base\$sub" -Recurse -Force -EA SilentlyContinue
                        "cleared $base\$sub" | Add-Content $v5Log -Encoding ASCII
                    }
                }
            }

            # Step 5: delegate sign+install to parameterized sign-and-install.ps1
            "Invoking $signSrc with v5 args" | Add-Content $v5Log -Encoding ASCII
            $signArgs = @(
                '-NoProfile','-ExecutionPolicy','Bypass','-File',$signSrc,
                '-DriverDir',$bundle,
                '-InfName','MagicMouseFixV3.inf',
                '-CatName','MagicMouseFixV3.cat',
                '-ServiceName','MagicMouseFixV3',
                '-ExistingCertThumbprint','16940C0F937D569363560D5FEC5CD8FA6D6D9BCE'
            )
            & powershell.exe @signArgs 2>&1 | Add-Content $v5Log -Encoding ASCII
            if ($LASTEXITCODE -ne 0) { throw "sign-and-install.ps1 FAILED ($LASTEXITCODE)" }

            # Step 6: restart-device on v3
            if ($v3) {
                "pnputil /restart-device $($v3.InstanceId)" | Add-Content $v5Log -Encoding ASCII
                & pnputil /restart-device "$($v3.InstanceId)" 2>&1 | Add-Content $v5Log -Encoding ASCII
                Start-Sleep -Seconds 10
            }

            # Step 7: verify LowerFilters now contains MagicMouseFixV3
            if ($v3) {
                $lf = (Get-PnpDeviceProperty -InstanceId $v3.InstanceId -KeyName 'DEVPKEY_Device_LowerFilters' -EA SilentlyContinue).Data
                $lfStr = if ($lf) { $lf -join ', ' } else { '(none)' }
                "v3 LowerFilters post-install: $lfStr" | Add-Content $v5Log -Encoding ASCII
                if ($lf -contains 'MagicMouseFixV3') {
                    "PASS: MagicMouseFixV3 in v3 LowerFilters" | Add-Content $v5Log -Encoding ASCII
                    $rc = 0
                } else {
                    "FAIL: MagicMouseFixV3 NOT in v3 LowerFilters" | Add-Content $v5Log -Encoding ASCII
                    $rc = 5
                }
            } else {
                "WARN: v3 not paired - skipped post-verify" | Add-Content $v5Log -Encoding ASCII
                $rc = 0
            }
        } catch {
            "Exception: $_" | Add-Content $v5Log -Encoding ASCII
            Log "Exception in PATHA-V5-INSTALL: $_"
            $rc = 99
        }
        Log "PATHA-V5-INSTALL exited $rc; log at $v5Log"
    }
    # PATHA-V5-UNINSTALL: rollback v5 install. Removes oem*.inf for MagicMouseFixV3.inf,
    # stops/deletes service, restarts v3 device, verifies stock applewirelessmouse restored.
    elseif ($phase -eq 'PATHA-V5-UNINSTALL') {
        $unLog = Join-Path $QueueDir "pathA-v5-uninstall-$nonce.log"
        try {
            "=== PATHA-V5-UNINSTALL ===" | Set-Content $unLog -Encoding ASCII
            $enum = & pnputil /enum-drivers 2>&1 | Out-String
            $oems = ($enum -split '(?=Published Name:)') |
                Where-Object { $_ -match 'MagicMouseFixV3\.inf' } |
                ForEach-Object { if ($_ -match 'Published Name:\s+(oem\d+\.inf)') { $Matches[1] } }
            "Our oem entries: $($oems -join ', ')" | Add-Content $unLog -Encoding ASCII
            foreach ($oem in $oems) {
                "pnputil /delete-driver $oem /uninstall /force" | Add-Content $unLog -Encoding ASCII
                & pnputil /delete-driver $oem /uninstall /force 2>&1 | Add-Content $unLog -Encoding ASCII
            }
            $svc = Get-Service MagicMouseFixV3 -EA SilentlyContinue
            if ($svc) {
                if ($svc.Status -eq 'Running') { Stop-Service MagicMouseFixV3 -Force -EA SilentlyContinue }
                & sc.exe delete MagicMouseFixV3 2>&1 | Add-Content $unLog -Encoding ASCII
            }
            $ourSys = 'C:\Windows\System32\drivers\MagicMouseFixV3.sys'
            if (Test-Path $ourSys) { Remove-Item $ourSys -Force -EA SilentlyContinue }
            $v3 = Get-PnpDevice -EA SilentlyContinue | Where-Object { $_.InstanceId -match 'BTHENUM.*00001124.*PID&0323' } | Select-Object -First 1
            if ($v3) {
                & pnputil /restart-device "$($v3.InstanceId)" 2>&1 | Add-Content $unLog -Encoding ASCII
                Start-Sleep -Seconds 8
            }
            $rc = 0
        } catch {
            "Exception: $_" | Add-Content $unLog -Encoding ASCII
            $rc = 99
        }
        Log "PATHA-V5-UNINSTALL exited $rc; log at $unLog"
    }
    # STARTUP-REPAIR: run startup-repair.ps1 to set LowerFilters and restart-device for
    # all known Apple Magic Mouse PIDs. Required after driver install to bind WDF filter.
    # Format: STARTUP-REPAIR|<nonce>
    elseif ($phase -eq 'STARTUP-REPAIR') {
        $srLog = Join-Path $QueueDir "startup-repair-$nonce.log"
        $srScript = $null
        $srCandidates = @(
            'D:\mm3-driver\startup-repair.ps1',
            'C:\mm3-pkg\startup-repair.ps1',
            '\\wsl.localhost\Ubuntu\home\lesley\projects\magic-mouse-tray-sprint\startup-repair-m13.ps1',
            '\\wsl.localhost\Ubuntu\home\lesley\projects\magic-mouse-tray\startup-repair.ps1'
        )
        foreach ($c in $srCandidates) {
            if (Test-Path $c) { $srScript = $c; break }
        }
        if (-not $srScript) {
            "ERROR: startup-repair.ps1 not found in any candidate path" | Set-Content $srLog -Encoding ASCII
            Log "STARTUP-REPAIR: script not found"
            $rc = 127
        } else {
            try {
                "=== STARTUP-REPAIR: $srScript ===" | Set-Content $srLog -Encoding ASCII
                & powershell.exe -ExecutionPolicy Bypass -File $srScript -LogFile (Join-Path $QueueDir "startup-repair-detail-$nonce.log") 2>&1 |
                    Add-Content $srLog -Encoding ASCII
                $rc = $LASTEXITCODE
                if ($null -eq $rc) { $rc = 0 }
            } catch {
                "Exception: $_" | Add-Content $srLog -Encoding ASCII
                Log "Exception in STARTUP-REPAIR: $_"
                $rc = 99
            }
        }
        Log "STARTUP-REPAIR exited $rc; log at $srLog"
    } else {
        # Default: route to mm-dev.ps1 -Phase $phase
        $candidates = @(
            'D:\mm3-driver\scripts\mm-dev.ps1',
            'C:\mm3-pkg\scripts\mm-dev.ps1'
        )
        $devScript = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $devScript) {
            Log "ERROR: mm-dev.ps1 not found in candidates"
            "127|$nonce" | Set-Content $ResFile -Encoding ASCII
            exit 127
        }
        Log "Using $devScript"

        try {
            & $devScript -Phase $phase -NoElevate
            $rc = $LASTEXITCODE
            if ($null -eq $rc) { $rc = 0 }
        } catch {
            Log "Exception running mm-dev.ps1: $_"
            $rc = 99
        }
    }

    Log "Phase '$phase' exited $rc"
    "$rc|$nonce" | Set-Content $ResFile -Encoding ASCII
    exit $rc

} finally {
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
    Log "===== task complete ====="
}
