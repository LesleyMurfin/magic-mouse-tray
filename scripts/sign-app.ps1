#Requires -Version 5
# Authenticode-sign the published MagicMouseTray.exe (post-publish step).
# Honest note: a self-signed cert does NOT clear SmartScreen reputation — only a publicly
# trusted OV/EV code-signing cert builds reputation. Until one is procured, signing reduces
# but does not eliminate the SmartScreen prompt the README documents.
param(
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][string]$PfxPath,
    [Parameter(Mandatory)][string]$PfxPassword,
    [string]$TimestampUrl = 'http://timestamp.digicert.com')

# signtool.exe is NOT on PATH on windows-latest runners or typical shells — resolve it
# explicitly from the Windows 10 SDK bin directory (newest version wins).
$signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
if (-not $signtool) { throw "signtool.exe not found — install the Windows 10 SDK (or add a setup step in CI)." }

& $signtool.FullName sign /f $PfxPath /p $PfxPassword /fd SHA256 /tr $TimestampUrl /td SHA256 $Exe
if ($LASTEXITCODE -ne 0) { throw "signtool sign failed ($LASTEXITCODE)" }

& $signtool.FullName verify /pa $Exe
if ($LASTEXITCODE -ne 0) { throw "signtool verify failed ($LASTEXITCODE)" }
