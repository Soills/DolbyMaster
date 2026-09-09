@echo off
cd /d "%~dp0"
taskkill /f /im DolbyMaster.exe 2>nul
echo [build] deleting old exe...
del /q "%~dp0DolbyMaster.exe" 2>nul
echo [build] building (src\build_exe.ps1)...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\build_exe.ps1" -Dst "%~dp0."
if errorlevel 1 ( echo [build] FAILED & pause & exit /b 1 )
echo [build] done: %~dp0DolbyMaster.exe
pause
