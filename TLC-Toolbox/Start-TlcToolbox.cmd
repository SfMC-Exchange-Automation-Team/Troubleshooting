@echo off
setlocal

REM Starts the TLC Toolbox with no console window behind it.
REM
REM Two things are needed and both are easy to get wrong by hand:
REM   -STA                  WPF will not run on an MTA thread
REM   -WindowStyle Hidden   otherwise a console sits behind the window
REM
REM Start-TlcToolbox.ps1 deliberately does NOT hide the console when it relaunches
REM itself, so that a developer running it directly can still see errors.

title TLC Toolbox

if not exist "%~dp0Start-TlcToolbox.ps1" (
    echo.
    echo   Could not find Start-TlcToolbox.ps1 next to this file.
    echo.
    echo   The usual cause is running this from INSIDE the .zip. Windows copies
    echo   only the file you double-clicked into a temporary folder, leaving the
    echo   rest of the toolbox behind in the archive - so this file ends up alone
    echo   somewhere it was never meant to run.
    echo.
    echo   Extract the whole folder first, then run this from the extracted copy.
    echo.
    pause
    exit /b 1
)

REM %* forwards whatever was passed - -Scenario, -CaseNumber, -ConfigPath or -OutputRoot,
REM which Start-TlcToolbox.ps1 hands on to the window. Double-clicking passes nothing, so the
REM ordinary path is unchanged. There is no elevation step to skip: the window asks for
REM administrator rights only through its own button, when an operator wants the deeper captures.
REM
REM This is for the WINDOW. A -Stage run started through here runs hidden and in the
REM background, so its output and its exit code are lost; run Start-TlcToolbox.ps1 -Stage or
REM TLC-Toolbox.ps1 directly for that.
start "" powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Start-TlcToolbox.ps1" -NoRelaunch %*

endlocal
