@echo off
rem ============================================================
rem  Zion CRM — document agent, one-step install
rem
rem  Right-click this file and choose "Run as administrator".
rem
rem  It asks for the secret, writes the configuration beside itself,
rem  registers a scheduled task that runs every 15 minutes, and does
rem  one run straight away so you can see it work.
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
