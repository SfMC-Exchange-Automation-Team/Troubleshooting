@echo off
setlocal

REM Launcher for people who should not have to know what an execution policy is.
REM Keep this file next to Invoke-TlcQuickCollect.ps1.

title Microsoft Teams log collection

if not exist "%~dp0Invoke-TlcQuickCollect.ps1" (
    echo.
    echo   Could not find Invoke-TlcQuickCollect.ps1 next to this file.
    echo.
    echo   The usual cause is running this from INSIDE the .zip. Windows copies
    echo   only the file you double-clicked into a temporary folder, leaving the
    echo   rest of the toolbox behind in the archive.
    echo.
    echo   Extract the whole folder first, then run this from the extracted copy.
    echo.
    pause
    exit /b 1
)

REM -ExecutionPolicy Bypass applies to this process only and changes nothing on
REM the machine. It is needed because the script is not yet code signed.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-TlcQuickCollect.ps1" %*
set TLC_EXIT=%ERRORLEVEL%

echo.
pause
REM The collector's own code, 1 when nothing was collected, for anything that runs this
REM unattended; pause would otherwise leave it at 0.
endlocal & exit /b %TLC_EXIT%
