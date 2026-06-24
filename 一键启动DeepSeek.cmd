@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0OneClick-DeepSeek.ps1"
set "exitcode=%ERRORLEVEL%"
if not "%exitcode%"=="0" (
  echo.
  echo One-click run failed with exit code %exitcode%.
  pause
)
exit /b %exitcode%
