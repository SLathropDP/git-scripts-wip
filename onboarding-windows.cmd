@echo off
powershell.exe -ExecutionPolicy Bypass -File "%~dp0onboarding-windows.ps1"

REM Reload updated user PATH automatically
for /f "tokens=2* delims= " %%a in ('reg query HKCU\Environment /v PATH') do set "PATH=%PATH%;%%b"

echo Updated PATH loaded into this session.

