@echo off
REM kbd-magickbdesc-build-2026-05-08.cmd
REM Build MagicKbDesc.sys via EWDK at F:\.
REM
REM Designed to be invoked from a parent .ps1 wrapper (cmd.exe can't cwd to UNC,
REM so the wrapper must be on a local drive or the wrapper must `cd` to a local
REM drive before invoking us).
REM
REM Output: <repo>\driver-keyboard\x64\Release\MagicKbDesc.sys (recovered from
REM C:\mm3-presign\ if SIGNTASK deletes it on the known /fd sha256 fail).

pushd C:\Windows\Temp
call F:\BuildEnv\SetupBuildEnv.cmd
if errorlevel 1 ( echo [build] SetupBuildEnv failed & popd & exit /b 1 )

if "%~1"=="" (
    echo [build] usage: %~nx0 ^<sln-path^>
    popd
    exit /b 2
)
set SLN=%~1

echo [build] msbuild %SLN%
msbuild "%SLN%" /p:Configuration=Release /p:Platform=x64 /t:Rebuild /nologo /v:minimal /p:SignFiles=false /p:EnableCodeSigning=false
set RC=%ERRORLEVEL%
echo [build] msbuild exit=%RC%
popd
exit /b %RC%
