@echo off
REM kbd-magickbdesc-postbuild-2026-05-08.cmd
REM Post-build: stage SYS+INX, stampinf, Inf2Cat, into a clean Windows-local dir.
REM Signing happens in the .ps1 wrapper (kbd-magickbdesc-sign-2026-05-08.ps1)
REM via the SYSTEM scheduler — keeps cert handling out of this layer.
REM
REM Args: %1 = repo-side driver-keyboard dir (UNC ok, e.g. \\wsl.localhost\Ubuntu\...\driver-keyboard)

pushd C:\Windows\Temp
call F:\BuildEnv\SetupBuildEnv.cmd
if errorlevel 1 ( echo [postbuild] SetupBuildEnv failed & popd & exit /b 1 )

if "%~1"=="" (
    echo [postbuild] usage: %~nx0 ^<driver-keyboard-dir^>
    popd
    exit /b 2
)
set DRVDIR=%~1
set OUTDIR=%DRVDIR%\x64\Release
set INX=%DRVDIR%\MagicKbDesc.inx
set SYS_SRC=%OUTDIR%\MagicKbDesc.sys
set STAGE=C:\Windows\Temp\MagicKbDescStage

if exist "%STAGE%" rd /s /q "%STAGE%"
mkdir "%STAGE%"

echo [postbuild] copying sys + inf to stage...
copy /Y "%SYS_SRC%" "%STAGE%\MagicKbDesc.sys" >nul
copy /Y "%INX%" "%STAGE%\MagicKbDesc.inf" >nul

echo [postbuild] stampinf...
stampinf -d "*" -v "1.0.0.0" -a "amd64" -k "1.33" -f "%STAGE%\MagicKbDesc.inf"

echo [postbuild] Inf2Cat...
"%WDKContentRoot%\bin\10.0.26100.0\x86\Inf2Cat.exe" /driver:"%STAGE%" /os:10_x64
if errorlevel 1 ( echo [postbuild] Inf2Cat failed & popd & exit /b 1 )

echo [postbuild] Stage contents:
dir "%STAGE%"
popd
exit /b 0
