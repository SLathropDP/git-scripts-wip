@echo off
REM onboarding.cmd
REM
REM Windows Command Prompt wrapper for onboarding-windows.ps1.
REM
REM Usage (from repo root in cmd.exe):
REM   scripts\onboarding.cmd
REM   scripts\onboarding.cmd -SkipVerification

SETLOCAL ENABLEDELAYEDEXPANSION

REM Resolve the directory where this .cmd file lives
SET "SCRIPT_DIR=%~dp0"
REM Remove trailing backslash if present
IF "%SCRIPT_DIR:~-1%"=="\" SET "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

SET "ONBOARDING_PS1=%SCRIPT_DIR%\onboarding-windows.ps1"

IF NOT EXIST "%ONBOARDING_PS1%" (
  ECHO [ERROR] Could not find onboarding-windows.ps1 at: "%ONBOARDING_PS1%"
  EXIT /B 1
)

REM Prefer PowerShell 7 (pwsh) if available, otherwise fall back to Windows PowerShell
WHERE pwsh >NUL 2>&1
IF "%ERRORLEVEL%"=="0" (
  SET "PWSH_CMD=pwsh"
) ELSE (
  WHERE powershell.exe >NUL 2>&1
  IF "%ERRORLEVEL%"=="0" (
    SET "PWSH_CMD=powershell.exe"
  ) ELSE (
    ECHO [ERROR] No PowerShell executable found (pwsh / powershell.exe).
    EXIT /B 1
  )
)

ECHO [INFO] Running onboarding-windows.ps1 via %PWSH_CMD% ...
REM /c is not used; -File handles script execution and exits.
%PWSH_CMD% -NoLogo -ExecutionPolicy Bypass -File "%ONBOARDING_PS1%" %*

ENDLOCAL
