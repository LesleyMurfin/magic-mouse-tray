@echo off
REM build.cmd — full pipeline for MagicKbDesc:
REM   1. EWDK msbuild on MagicKbDesc.sln
REM   2. recover .sys from C:\mm3-presign\ (SIGNTASK delete workaround)
REM   3. stage SYS + INX into clean dir
REM   4. stampinf + Inf2Cat
REM
REM Output:  C:\Windows\Temp\MagicKbDescStage\{MagicKbDesc.sys, .cat, .inf}
REM Sign + install + test happen via the .ps1 siblings.

setlocal
pushd C:\Windows\Temp
call F:\BuildEnv\SetupBuildEnv.cmd
if errorlevel 1 ( echo [build] SetupBuildEnv failed & popd & exit /b 1 )

REM This script lives at <repo>\driver-keyboard\build.cmd. The .sln is its sibling.
REM Use the UNC form so the script works whether the repo is local or via WSL.
set DRVDIR=%~dp0
if "%DRVDIR:~-1%"=="\" set DRVDIR=%DRVDIR:~0,-1%
set SLN=%DRVDIR%\MagicKbDesc.sln
set INX=%DRVDIR%\MagicKbDesc.inx
set OUTDIR=%DRVDIR%\x64\Release
set STAGE=C:\Windows\Temp\MagicKbDescStage

echo [build] msbuild %SLN%
msbuild "%SLN%" /p:Configuration=Release /p:Platform=x64 /t:Rebuild /nologo /v:minimal /p:SignFiles=false /p:EnableCodeSigning=false
REM SIGNTASK fails with /fd sha256 issue — vcxproj's BackupPreSign target
REM saves a copy to C:\mm3-presign\ before SIGNTASK can delete it.
REM Don't trust msbuild's exit code; check artifacts directly.

if exist "C:\mm3-presign\MagicKbDesc.sys" (
    if not exist "%OUTDIR%\MagicKbDesc.sys" (
        echo [build] Restoring .sys from C:\mm3-presign\
        copy /Y "C:\mm3-presign\MagicKbDesc.sys" "%OUTDIR%\MagicKbDesc.sys" >nul
    )
)

if not exist "%OUTDIR%\MagicKbDesc.sys" (
    echo [build] FAILED: %OUTDIR%\MagicKbDesc.sys not produced
    popd
    exit /b 1
)

REM --- Stage for stamp + cat ---
if exist "%STAGE%" rd /s /q "%STAGE%"
mkdir "%STAGE%"
copy /Y "%OUTDIR%\MagicKbDesc.sys" "%STAGE%\MagicKbDesc.sys" >nul
copy /Y "%INX%" "%STAGE%\MagicKbDesc.inf" >nul

echo [build] stampinf...
stampinf -d "*" -v "1.0.0.0" -a "amd64" -k "1.33" -f "%STAGE%\MagicKbDesc.inf"

echo [build] Inf2Cat...
"%WDKContentRoot%\bin\10.0.26100.0\x86\Inf2Cat.exe" /driver:"%STAGE%" /os:10_x64
if errorlevel 1 ( echo [build] Inf2Cat failed & popd & exit /b 1 )

echo.
echo [build] Stage contents (ready to sign):
dir /B "%STAGE%"

popd
endlocal
exit /b 0
