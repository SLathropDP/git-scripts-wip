#!/usr/bin/env bash
#
# onboarding-linux.sh
#
# Minimal Linux onboarding:
#
#   - Verifies Node.js is installed (required for JS tooling)
#   - Installs Pandoc (via dnf or yum) and enables EPEL if needed
#
# Usage (from repo root):
#
#   chmod +x scripts/onboarding-linux.sh && ./scripts/onboarding-linux.sh
#

set -euo pipefail

log_info()  { printf '\033[36m[INFO]\033[0m %s\n' "$*"; }
log_warn()  { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
log_error() { printf '\033[31m[ERROR]\033[0m %s\n' "$*"; }

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    log_error "Required command '$name' not found on PATH."
    exit 1
  fi
}

detect_pkg_manager() {
  if command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  else
    log_error "Neither 'dnf' nor 'yum' detected; cannot install packages automatically."
    exit 1
  fi
}

ensure_pandoc_installed() {
  if command -v pandoc >/dev/null 2>&1; then
    log_info "pandoc already installed: $(pandoc --version | head -n1)"
    return
  fi

  log_info "pandoc not found; attempting installation..."

  local pm
  pm="$(detect_pkg_manager)"

  # Install EPEL if on RHEL and not already enabled.
  if ! "$pm" repolist epel >/dev/null 2>&1; then
    log_info "EPEL repository not detected; installing epel-release..."
    if ! sudo "$pm" -y install epel-release; then
      log_warn "Unable to install epel-release. pandoc installation may fail."
    fi
  fi

  log_info "Installing pandoc via $pm..."
  if ! sudo "$pm" -y install pandoc; then
    log_error "Failed to install pandoc. Please install manually from https://pandoc.org/installing.html"
    exit 1
  fi

  log_info "pandoc installation complete: $(pandoc --version | head -n1)"
}

main() {
  log_info "=== Linux onboarding ==="
  log_info "Repository root: $(pwd)"

  # Node.js is assumed installed, but we verify
  require_command node
  log_info "Node.js found: $(node --version)"

  ensure_pandoc_installed

  log_info "Onboarding complete. Environment is ready."
}

main "$@"
