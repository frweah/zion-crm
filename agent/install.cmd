@echo off
rem ============================================================
rem  Zion CRM — document agent, one-step install
rem
rem  Right-click this file and choose "Run as administrator".
rem
rem  It writes the configuration beside itself - or keeps the one that is
rem  already there, secret and all - registers two scheduled tasks, and
rem  does one full run straight away so you can see it work.
rem
rem    the client folders and the warrants   10:00 and 19:00
rem    phone photos, and any extra pass      every 15 minutes
rem
rem  Run it again whenever the schedule changes. It asks nothing when a
rem  configuration is already there.
rem
rem  It never touches the watched folder. Uninstalling is one line,
rem  printed at the end.
rem ============================================================

setlocal
cd /d "%~dp0"

echo.
echo   Zion CRM document agent
echo   =======================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"

if errorlevel 1 (
  echo.
  echo   Install did not finish. Nothing has been changed.
  echo.
)

echo.
pause
endlocal
