@echo off
REM ================================================================================
REM onboarding-windows.cmd
REM
REM Windows Command Prompt wrapper for PowerShell-based onboarding.
REM
REM Responsibilities:
REM   1. Locate and run onboarding-windows.ps1 via PowerShell.
REM   2. Let the PowerShell script handle:
REM        - Installing Node.js / Pandoc
REM        - Downloading Nexus CA
REM        - Configuring npm
REM        - Writing HTTP_PROXY / HTTPS_PROXY and PATH at the *user* level
REM
REM Note:
REM   - Because a child process (PowerShell) cannot modify the environment of
REM     this cmd.exe session, any changes to PATH/proxy from the onboarding
REM     script will only appear automatically in NEW terminals.
REM   - After running this script, you should open a new Command Prompt and run:
REM         node --version
REM         pandoc --version
REM         npm config get registry
REM         npm config get cafile
REM     to verify everything is configured.
REM ================================================================================

REM Resolve directory where this script lives
SET "SCRIPT_DIR=%~dp0"
IF "%SCRIPT_DIR:~-1%"=="\" SET "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

SET "ONBOARDING_PS1=%SCRIPT_DIR%\onboarding-windows.ps1"

IF NOT EXIST "%ONBOARDING_PS1%" (
  ECHO [ERROR] Could not find onboarding-windows.ps1 at: "%ONBOARDING_PS1%"
  EXIT /B 1
)

REM ================================================================================
REM Choose PowerShell host:
REM   - pwsh (PowerShell 7+) preferred
REM   - powershell.exe fallback (Windows PowerShell)
REM ================================================================================
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
%PWSH_CMD% -NoLogo -ExecutionPolicy Bypass -File "%ONBOARDING_PS1%" %*
IF ERRORLEVEL 1 (
  ECHO [ERROR] Onboarding script returned a non-zero exit code.
  EXIT /B 1
)

ECHO [INFO] Onboarding script completed successfully.
ECHO [INFO] Open a NEW Command Prompt to pick up updated PATH and proxy settings.
ECHO [INFO] Then run:
ECHO          node --version
ECHO          pandoc --version
ECHO          npm config get registry
ECHO          npm config get cafile

EXIT /B 0
