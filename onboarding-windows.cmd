@echo off
REM ================================================================================
REM onboarding-windows.cmd
REM
REM Windows Command Prompt wrapper for PowerShell-based onboarding
REM
REM This wrapper performs TWO key onboarding tasks:
REM
REM   1. RUN THE POWERSHELL ONBOARDING SCRIPT
REM      - The PowerShell script installs Node.js and Pandoc (if missing),
REM        downloads the Nexus CA file, configures npm, and writes HTTP_PROXY
REM        and HTTPS_PROXY into the Windows Registry under:
REM
REM             HKCU\Environment
REM
REM      These registry entries define the *permanent, user-level* env vars
REM      that will be applied to NEW shells opened in the future
REM
REM   2. UPDATE THE CURRENT CMD SESSION
REM      The registry is persistent, but Windows does NOT automatically update
REM      the environment variables of the CURRENT cmd.exe process. Therefore:
REM
REM         - This wrapper explicitly reloads the updated PATH from the registry
REM         - It also loads HTTP_PROXY and HTTPS_PROXY into THIS cmd session
REM
REM      This means that right after running this wrapper:
REM
REM           node --version
REM           pandoc --version
REM           npm config list
REM
REM      will all work IMMEDIATELY without opening a new Command Prompt
REM
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
    ENDLOCAL
    EXIT /B 1
  )
)

ECHO [INFO] Running onboarding-windows.ps1 via %PWSH_CMD% ...
%PWSH_CMD% -NoLogo -ExecutionPolicy Bypass -File "%ONBOARDING_PS1%" %*
IF ERRORLEVEL 1 (
  ECHO [ERROR] Onboarding script returned a non-zero exit code.
  ENDLOCAL
  EXIT /B 1
)

REM ================================================================================
REM Reload PATH from HKCU\Environment so THIS cmd.exe session sees node/pandoc
REM
REM Important:
REM   - PATH in registry defines what new terminals see
REM   - PATH in *this cmd session* must be updated manually
REM ================================================================================
SET "USERPATH="
FOR /F "tokens=2,* skip=2" %%A IN ('reg query HKCU\Environment /v PATH 2^>NUL') DO (
  SET "USERPATH=%%B"
)

IF DEFINED USERPATH (
  ECHO [INFO] Refreshing PATH for this cmd session...
  SET "PATH=%PATH%;%USERPATH%"
)

REM ================================================================================
REM Reload HTTP_PROXY and HTTPS_PROXY from HKCU\Environment
REM
REM The PowerShell script writes proxy settings to the registry for future shells.
REM This wrapper loads them into THIS cmd session as well.
REM ================================================================================
SET "USER_HTTP_PROXY="

FOR /F "tokens=2,* skip=2" %%A IN ('reg query HKCU\Environment /v HTTP_PROXY 2^>NUL') DO (
  SET "USER_HTTP_PROXY=%%B"
)

IF DEFINED USER_HTTP_PROXY (
  ECHO [INFO] Loading HTTP_PROXY into this session...
  SET "HTTP_PROXY=%USER_HTTP_PROXY%"
)

SET "USER_HTTPS_PROXY="

FOR /F "tokens=2,* skip=2" %%A IN ('reg query HKCU\Environment /v HTTPS_PROXY 2^>NUL') DO (
  SET "USER_HTTPS_PROXY=%%B"
)

IF DEFINED USER_HTTPS_PROXY (
  ECHO [INFO] Loading HTTPS_PROXY into this session...
  SET "HTTPS_PROXY=%USER_HTTPS_PROXY%"
)

REM ================================================================================
REM Complete
REM ================================================================================
ECHO [INFO] Onboarding tasks in this cmd session completed
ECHO [INFO] PATH and proxy variables updated for THIS cmd session
ECHO [INFO] Node, Pandoc, and npm should work immediately

EXIT /B 0
