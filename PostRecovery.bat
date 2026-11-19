@echo off
title Post-Recovery Checklist
net session >nul 2>&1
if %errorlevel%==0 goto run
echo Requesting Administrator permission...
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:run
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0PostRecovery.ps1"
echo.
pause
