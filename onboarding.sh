#!/usr/bin/env bash
#
# onboarding.sh
#
# Cross-platform wrapper for onboarding:
#
#   - On Linux: runs scripts/onboarding-linux.sh
#   - On Windows (Git Bash / MSYS / Cygwin): runs scripts/onboarding-windows.ps1 via PowerShell
#
# Usage (from Git Bash in repo root):
#
#   chmod +x scripts/onboarding.sh && ./scripts/onboarding.sh
#
# Any arguments are forwarded to the underlying platform-specific script.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LINUX_SCRIPT="$SCRIPT_DIR/onboarding-linux.sh"
WINDOWS_SCRIPT="$SCRIPT_DIR/onboarding-windows.ps1"

log_info()  { printf '\033[36m[INFO]\033[0m %s\n' "$*"; }
log_warn()  { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
log_error() { printf '\033[31m[ERROR]\033[0m %s\n' "$*"; }

detect_os() {
  local uname_out
  uname_out="$(uname -s 2>/dev/null || echo unknown)"

  case "$uname_out" in
    Linux)   echo "linux" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *)
      log_warn "Unknown OS from uname: $uname_out"
      echo "unknown"
      ;;
  esac
}

run_linux_onboarding() {
  if [[ ! -x "$LINUX_SCRIPT" ]]; then
    if [[ -f "$LINUX_SCRIPT" ]]; then
      chmod +x "$LINUX_SCRIPT"
    else
      log_error "Linux onboarding script not found at: $LINUX_SCRIPT"
      exit 1
    fi
  fi

  log_info "Detected Linux; running $LINUX_SCRIPT ..."
  (cd "$REPO_ROOT" && "$LINUX_SCRIPT" "$@")
}

run_windows_onboarding() {
  if [[ ! -f "$WINDOWS_SCRIPT" ]]; then
    log_error "Windows onboarding script not found at: $WINDOWS_SCRIPT"
    exit 1
  fi

  # Pick a PowerShell executable
  local pwsh_cmd=""
  if command -v pwsh >/dev/null 2>&1; then
    pwsh_cmd="pwsh"
  elif command -v powershell.exe >/dev/null 2>&1; then
    pwsh_cmd="powershell.exe"
  elif command -v powershell >/dev/null 2>&1; then
    pwsh_cmd="powershell"
  else
    log_error "No PowerShell executable found (pwsh / powershell.exe). Cannot run Windows onboarding."
    exit 1
  fi

  log_info "Detected Windows (Bash environment); running $WINDOWS_SCRIPT via $pwsh_cmd ..."
  (
    cd "$REPO_ROOT"
    "$pwsh_cmd" -NoLogo -ExecutionPolicy Bypass -File "$WINDOWS_SCRIPT" "$@"
  )
}

main() {
  local os
  os="$(detect_os)"

  case "$os" in
    linux)
      run_linux_onboarding "$@"
      ;;
    windows)
      run_windows_onboarding "$@"
      ;;
    *)
      log_error "Unsupported or unknown OS."
      exit 1
      ;;
  esac
}

main "$@"
