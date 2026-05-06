#!/usr/bin/env bash
# setup-gemma4-local.sh
#
# Purpose:
#   Configure a RHEL 9 AWS VM for local Gemma 4 inference using Ollama,
#   then run JavaScript-analysis sanity checks through Ollama's native API
#   and Anthropic-compatible API.
#
# Default target:
#   MODEL=gemma4:e4b-it-q4_K_M
#   CONTEXT=16384
#   LOCAL_MODEL=gemma4-js-local
#   OLLAMA_KEEP_ALIVE=120m
#   INSTALL_CLAUDE_CODE=1
#
# Example install/execute:
#   chmod +x setup-gemma4-local.sh
#   CONTEXT=16384 ./setup-gemma4-local.sh
#
# Proxy-aware examples:
#   HTTPS_PROXY=http://proxy.example.com:8080 CONTEXT=16384 ./setup-gemma4-local.sh
#   OLLAMA_HTTPS_PROXY=http://proxy.example.com:8080 CONTEXT=16384 ./setup-gemma4-local.sh
#   DISABLE_PROXY_CONFIG=1 ./setup-gemma4-local.sh
#
# nvm-safe OpenCode install:
#   - This script does NOT run "npm config set prefix".
#   - OpenCode is installed into an isolated local npm prefix:
#       ~/.local/opencode-npm
#   - Override with:
#       OPENCODE_NPM_PREFIX=/some/path ./setup-gemma4-local.sh
#
# OpenCode/OpenTUI noexec-/tmp workaround:
#   - By default the script creates an exec-capable temp directory for Bun/OpenTUI at:
#       /opt/opencode-bun-tmp-$USER
#   - Override it if your organization requires a different exec-capable path:
#       OPENCODE_BUN_TMPDIR=/path/on/exec/fs ./setup-gemma4-local.sh
#
# Useful variants:
#   INSTALL_OPENCODE=0 ./setup-gemma4-local.sh
#   INSTALL_CLAUDE_CODE=0 ./setup-gemma4-local.sh
#   MODEL=gemma4:e2b-it-q4_K_M LOCAL_MODEL=gemma4-e2b-js CONTEXT=8192 ./setup-gemma4-local.sh
#   MODEL=gemma4:26b-a4b-it-q4_K_M LOCAL_MODEL=gemma4-26b-js CONTEXT=4096 ./setup-gemma4-local.sh
#   OLLAMA_KEEP_ALIVE=30m ./setup-gemma4-local.sh
#   FORCE_PULL=1 ./setup-gemma4-local.sh
#
# Timeout controls:
#   - For script sanity-check inference calls:
#       SANITY_CURL_MAX_TIME=0
#       SANITY_CURL_CONNECT_TIMEOUT=0
#     A value of 0 means this script does not pass a curl timeout option.
#
#   - For OpenCode inference calls:
#       OPENCODE_REQUEST_TIMEOUT_JSON=false
#       OPENCODE_CHUNK_TIMEOUT_MS=2147483647
#     "timeout": false disables OpenCode's total request timeout.
#     chunkTimeout remains numeric, so this uses the max signed 32-bit millisecond value
#     which is about 24.8 days.
#
# Notes:
#   - Local Ollama API calls deliberately use:
#       curl --noproxy '*' -H 'Host: localhost:11434'
#     because some RHEL/AWS/proxy environments return 403 for plain
#     http://127.0.0.1:11434 curl checks.
#   - Model pulls are performed by the Ollama systemd service, so outbound
#     HTTPS proxy configuration must be present in the service environment,
#     not merely in your interactive shell.
#   - OpenCode and Claude Code wrappers remove proxy variables so local
#     http://localhost:11434 traffic does not go to the corporate proxy.
#   - The script is designed to be re-runnable after partial or complete runs.

set -Eeuo pipefail

RUN_USER="$(id -un)"
RUN_GROUP="$(id -gn)"

MODEL="${MODEL:-gemma4:e4b-it-q4_K_M}"
LOCAL_MODEL="${LOCAL_MODEL:-gemma4-js-local}"
CLAUDE_MODEL_ALIAS="${CLAUDE_MODEL_ALIAS:-claude-gemma4-js-local}"
CONTEXT="${CONTEXT:-16384}"

INSTALL_OPENCODE="${INSTALL_OPENCODE:-1}"
INSTALL_CLAUDE_CODE="${INSTALL_CLAUDE_CODE:-1}"
UPDATE_OPENCODE="${UPDATE_OPENCODE:-0}"
UPDATE_CLAUDE_CODE="${UPDATE_CLAUDE_CODE:-0}"

# auto:
#   If nvm exists but no active Node is found, do not install system Node.
#   If nvm does not exist and no Node is found, install system Node.
# 1:
#   Install system Node if needed, even if nvm exists.
# 0:
#   Never install system Node.
INSTALL_SYSTEM_NODE="${INSTALL_SYSTEM_NODE:-auto}"

DISABLE_CLOUD="${DISABLE_CLOUD:-1}"
UPDATE_OLLAMA="${UPDATE_OLLAMA:-0}"
FORCE_PULL="${FORCE_PULL:-0}"
SKIP_PULL="${SKIP_PULL:-0}"
DISABLE_PROXY_CONFIG="${DISABLE_PROXY_CONFIG:-0}"

OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-120m}"

# No curl max-time/connect-timeout by default for inference sanity checks.
SANITY_CURL_MAX_TIME="${SANITY_CURL_MAX_TIME:-0}"
SANITY_CURL_CONNECT_TIMEOUT="${SANITY_CURL_CONNECT_TIMEOUT:-0}"
SANITY_NUM_PREDICT="${SANITY_NUM_PREDICT:-512}"
INFERENCE_THREADS="${INFERENCE_THREADS:-4}"

# Health checks are not inference calls; keep these bounded.
OLLAMA_HEALTH_CURL_MAX_TIME="${OLLAMA_HEALTH_CURL_MAX_TIME:-10}"
OLLAMA_HEALTH_CURL_CONNECT_TIMEOUT="${OLLAMA_HEALTH_CURL_CONNECT_TIMEOUT:-3}"

# OpenCode provider timeout behavior.
OPENCODE_REQUEST_TIMEOUT_JSON="${OPENCODE_REQUEST_TIMEOUT_JSON:-false}"
OPENCODE_CHUNK_TIMEOUT_MS="${OPENCODE_CHUNK_TIMEOUT_MS:-2147483647}"

# Isolated npm prefix for OpenCode. This avoids npm config set prefix and is nvm-safe.
OPENCODE_NPM_PREFIX="${OPENCODE_NPM_PREFIX:-$HOME/.local/opencode-npm}"
OPENCODE_BIN="${OPENCODE_BIN:-$OPENCODE_NPM_PREFIX/node_modules/.bin/opencode}"

# Preserve whether these were explicitly supplied by the caller.
REQUESTED_OLLAMA_HTTPS_PROXY="${OLLAMA_HTTPS_PROXY:-}"
REQUESTED_OPENCODE_BUN_TMPDIR="${OPENCODE_BUN_TMPDIR:-}"

# OpenCode/OpenTUI workaround for hardened systems where /tmp is mounted noexec.
OPENCODE_BUN_TMPDIR="${OPENCODE_BUN_TMPDIR:-/opt/opencode-bun-tmp-${RUN_USER}}"

# Service bind address. Keep this local-only unless you know exactly why you need otherwise.
OLLAMA_BIND="${OLLAMA_BIND:-127.0.0.1:11434}"

# API endpoint used by this script for local curl checks.
OLLAMA_API_BASE="${OLLAMA_API_BASE:-http://127.0.0.1:11434}"

# Base URL used by OpenCode/Claude Code. localhost generally produces the accepted Host header.
OLLAMA_CLIENT_BASE="${OLLAMA_CLIENT_BASE:-http://localhost:11434}"
OLLAMA_CLI_HOST="${OLLAMA_CLI_HOST:-localhost:11434}"
OLLAMA_HOST_HEADER="${OLLAMA_HOST_HEADER:-localhost:11434}"

SCRIPT_OLLAMA_DROPIN_DIR="/etc/systemd/system/ollama.service.d"
SCRIPT_MAIN_DROPIN="${SCRIPT_OLLAMA_DROPIN_DIR}/10-local-gemma4.conf"
SCRIPT_PROXY_DROPIN="${SCRIPT_OLLAMA_DROPIN_DIR}/20-outbound-proxy.conf"

# Make user-local binaries visible during reruns.
export PATH="$HOME/bin:$HOME/.local/bin:$OPENCODE_NPM_PREFIX/node_modules/.bin:$PATH"

log()  { printf "\n\033[1;32m==> %s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33mWARN: %s\033[0m\n" "$*" >&2; }
die()  { printf "\nERROR: %s\n" "$*" >&2; exit 1; }

systemd_escape_env_value() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//%/%%}"
  printf '%s' "$s"
}

shell_single_quote() {
  local s="${1:-}"
  printf "'"
  printf '%s' "$s" | sed "s/'/'\\\\''/g"
  printf "'"
}

now_ns() {
  date +%s%N
}

elapsed_seconds() {
  local start_ns="$1"
  local end_ns="$2"

  awk -v s="$start_ns" -v e="$end_ns" 'BEGIN { printf "%.3f", (e - s) / 1000000000 }'
}

validate_numeric_int() {
  local name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    die "${name} must be a non-negative integer, got: ${value}"
  fi
}

validate_opencode_timeout_config() {
  validate_numeric_int OPENCODE_CHUNK_TIMEOUT_MS "$OPENCODE_CHUNK_TIMEOUT_MS"

  if ! printf '{"timeout":%s,"chunkTimeout":%s}\n' \
      "$OPENCODE_REQUEST_TIMEOUT_JSON" \
      "$OPENCODE_CHUNK_TIMEOUT_MS" \
      | jq empty >/dev/null 2>&1; then
    die "Invalid OPENCODE_REQUEST_TIMEOUT_JSON=${OPENCODE_REQUEST_TIMEOUT_JSON}. Use false, null, or a number such as 900000."
  fi
}

source_nvm_if_available() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

  if [ -s "$NVM_DIR/nvm.sh" ]; then
    # shellcheck disable=SC1090
    . "$NVM_DIR/nvm.sh"

    # Use the user's default nvm Node if configured.
    nvm use --silent default >/dev/null 2>&1 || true
  fi
}

cleanup_script_npm_settings_for_nvm() {
  local npmrc="$HOME/.npmrc"
  local script_prefix="$HOME/.npm-global"
  local bashrc="$HOME/.bashrc"

  if [ -f "$npmrc" ]; then
    python3 - "$npmrc" "$script_prefix" <<'PY_NPMRC_CLEANUP'
from pathlib import Path
import shutil
import sys
import time

npmrc = Path(sys.argv[1])
script_prefix = sys.argv[2]

try:
    original = npmrc.read_text()
except FileNotFoundError:
    raise SystemExit(0)

lines = original.splitlines()
out = []
changed = False

for line in lines:
    stripped = line.strip()
    key, sep, val = stripped.partition("=")
    if sep and key.strip() == "prefix":
        cleaned = val.strip().strip('"').strip("'")
        if cleaned == script_prefix:
            changed = True
            continue
    out.append(line)

if changed:
    backup = npmrc.with_name(npmrc.name + ".bak." + time.strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(npmrc, backup)
    npmrc.write_text("\n".join(out) + ("\n" if out else ""))
    print(f"Removed script-created npm prefix from {npmrc}; backup={backup}")
PY_NPMRC_CLEANUP
  fi

  if [ -f "$bashrc" ]; then
    python3 - "$bashrc" <<'PY_BASHRC_CLEANUP'
from pathlib import Path
import shutil
import sys
import time

bashrc = Path(sys.argv[1])

try:
    original = bashrc.read_text()
except FileNotFoundError:
    raise SystemExit(0)

remove_exact = {
    'export PATH="$HOME/.npm-global/bin:$PATH"',
    "export PATH='$HOME/.npm-global/bin:$PATH'",
    "export PATH=$HOME/.npm-global/bin:$PATH",
}

lines = original.splitlines()
out = []
changed = False

for line in lines:
    if line.strip() in remove_exact:
        changed = True
        continue
    out.append(line)

if changed:
    backup = bashrc.with_name(bashrc.name + ".bak." + time.strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(bashrc, backup)
    bashrc.write_text("\n".join(out) + ("\n" if out else ""))
    print(f"Removed old ~/.npm-global PATH line from {bashrc}; backup={backup}")
PY_BASHRC_CLEANUP
  fi
}

ensure_node_for_opencode() {
  cleanup_script_npm_settings_for_nvm
  source_nvm_if_available

  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    log "Using Node/npm from PATH"
    node --version || true
    npm --version || true
    return 0
  fi

  local nvm_present=0
  [ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ] && nvm_present=1

  if [ "$nvm_present" = "1" ] && [ "$INSTALL_SYSTEM_NODE" != "1" ] && [ "$INSTALL_SYSTEM_NODE" != "true" ] && [ "$INSTALL_SYSTEM_NODE" != "yes" ]; then
    warn "nvm is installed, but no active Node/npm was found."
    warn "To keep nvm safe, this script will not install system Node in INSTALL_SYSTEM_NODE=auto mode."
    warn "Run: nvm install --lts && nvm alias default 'lts/*'"
    return 1
  fi

  case "$INSTALL_SYSTEM_NODE" in
    0|false|no)
      warn "INSTALL_SYSTEM_NODE=0 and no Node/npm found; skipping OpenCode install."
      return 1
      ;;
    auto|1|true|yes)
      log "Installing system Node.js/npm because no usable Node/npm was found"
      sudo dnf module reset -y nodejs || true
      sudo dnf module enable -y nodejs:20 || true
      sudo dnf -y install nodejs npm || return 1
      node --version || true
      npm --version || true
      return 0
      ;;
    *)
      die "Invalid INSTALL_SYSTEM_NODE=${INSTALL_SYSTEM_NODE}; use auto, 1, or 0."
      ;;
  esac
}

# Use this wrapper for local Ollama HTTP API calls only.
# It bypasses proxy interception and supplies the Host header that worked in testing.
ollama_api_curl() {
  env \
    -u HTTP_PROXY -u http_proxy \
    -u HTTPS_PROXY -u https_proxy \
    -u ALL_PROXY -u all_proxy \
    NO_PROXY="127.0.0.1,localhost,::1${NO_PROXY:+,$NO_PROXY}" \
    no_proxy="127.0.0.1,localhost,::1${no_proxy:+,$no_proxy}" \
    curl --noproxy '*' \
      -H "Host: ${OLLAMA_HOST_HEADER}" \
      "$@"
}

ollama_api_curl_health() {
  ollama_api_curl \
    --connect-timeout "$OLLAMA_HEALTH_CURL_CONNECT_TIMEOUT" \
    --max-time "$OLLAMA_HEALTH_CURL_MAX_TIME" \
    "$@"
}

# Use this for slow local inference sanity checks.
# SANITY_CURL_* value of 0 means do not pass the corresponding curl timeout option.
ollama_api_curl_sanity() {
  local curl_args=()

  if [ "$SANITY_CURL_CONNECT_TIMEOUT" != "0" ]; then
    curl_args+=(--connect-timeout "$SANITY_CURL_CONNECT_TIMEOUT")
  fi

  if [ "$SANITY_CURL_MAX_TIME" != "0" ]; then
    curl_args+=(--max-time "$SANITY_CURL_MAX_TIME")
  fi

  ollama_api_curl "${curl_args[@]}" "$@"
}

# Use this wrapper for local Ollama CLI calls.
# The CLI talks to the local daemon; the daemon handles outbound model downloads.
ollama_cli() {
  env \
    -u HTTP_PROXY -u http_proxy \
    -u HTTPS_PROXY -u https_proxy \
    -u ALL_PROXY -u all_proxy \
    NO_PROXY="127.0.0.1,localhost,::1${NO_PROXY:+,$NO_PROXY}" \
    no_proxy="127.0.0.1,localhost,::1${no_proxy:+,$no_proxy}" \
    OLLAMA_HOST="${OLLAMA_CLI_HOST}" \
    ollama "$@"
}

model_exists() {
  local model_name="$1"
  ollama_cli show "$model_name" >/dev/null 2>&1
}

unload_ollama_model() {
  local model_name="$1"
  [ -n "$model_name" ] || return 0

  ollama_api_curl_sanity -fsS \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg model "$model_name" '{model:$model, prompt:"", keep_alive:0}')" \
    "${OLLAMA_API_BASE}/api/generate" \
    >/dev/null 2>&1 || true
}

detect_existing_ollama_https_proxy() {
  local envline
  envline="$(systemctl show ollama -p Environment --value 2>/dev/null || true)"
  printf '%s\n' "$envline" \
    | tr ' ' '\n' \
    | awk -F= 'tolower($1)=="https_proxy" { sub(/^[^=]*=/, ""); print; exit }'
}

select_ollama_https_proxy() {
  if [ "$DISABLE_PROXY_CONFIG" = "1" ]; then
    printf ''
    return 0
  fi

  if [ -n "$REQUESTED_OLLAMA_HTTPS_PROXY" ]; then
    printf '%s' "$REQUESTED_OLLAMA_HTTPS_PROXY"
    return 0
  fi

  if [ -n "${HTTPS_PROXY:-}" ]; then
    printf '%s' "$HTTPS_PROXY"
    return 0
  fi

  if [ -n "${https_proxy:-}" ]; then
    printf '%s' "$https_proxy"
    return 0
  fi

  local existing_proxy
  existing_proxy="$(detect_existing_ollama_https_proxy || true)"
  if [ -n "$existing_proxy" ]; then
    printf '%s' "$existing_proxy"
    return 0
  fi

  if [ -n "${ALL_PROXY:-}" ]; then
    printf '%s' "$ALL_PROXY"
    return 0
  fi

  if [ -n "${all_proxy:-}" ]; then
    printf '%s' "$all_proxy"
    return 0
  fi

  printf ''
}

mount_has_noexec() {
  local path="$1"
  findmnt -no OPTIONS -T "$path" 2>/dev/null | tr ',' '\n' | grep -qx noexec
}

ensure_user_owned_private_dir() {
  local dir="$1"

  if sudo install -d -m 700 -o "$RUN_USER" -g "$RUN_GROUP" "$dir" 2>/dev/null; then
    return 0
  fi

  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
}

verify_shared_object_load_from_dir() {
  local dir="$1"
  local c_file="${dir}/opencode-dlopen-test.c"
  local so_file="${dir}/opencode-dlopen-test.so"

  rm -f "$c_file" "$so_file"

  cat > "$c_file" <<'EOF_C_TEST'
int opencode_test_symbol(void) { return 42; }
EOF_C_TEST

  if ! gcc -shared -fPIC -o "$so_file" "$c_file" >/dev/null 2>&1; then
    rm -f "$c_file" "$so_file"
    return 1
  fi

  if ! python3 - "$so_file" >/dev/null 2>&1 <<'PY_DLOPEN_TEST'
import ctypes
import sys
lib = ctypes.CDLL(sys.argv[1])
assert lib.opencode_test_symbol() == 42
PY_DLOPEN_TEST
  then
    rm -f "$c_file" "$so_file"
    return 1
  fi

  rm -f "$c_file" "$so_file"
  return 0
}

ensure_opencode_bun_tmpdir() {
  log "Preparing OpenCode/OpenTUI exec-capable temp directory"

  local candidates=()

  if [ -n "$REQUESTED_OPENCODE_BUN_TMPDIR" ]; then
    candidates+=("$REQUESTED_OPENCODE_BUN_TMPDIR")
  else
    candidates+=("$OPENCODE_BUN_TMPDIR")
    candidates+=("$HOME/.cache/opencode-bun-tmp")
    candidates+=("$HOME/opencode-bun-tmp")
  fi

  local candidate
  for candidate in "${candidates[@]}"; do
    [ -n "$candidate" ] || continue

    ensure_user_owned_private_dir "$candidate"

    if mount_has_noexec "$candidate"; then
      warn "Candidate OpenCode temp directory is on a noexec filesystem: ${candidate}"
      continue
    fi

    if verify_shared_object_load_from_dir "$candidate"; then
      OPENCODE_BUN_TMPDIR="$candidate"
      log "Using OpenCode/OpenTUI temp directory: ${OPENCODE_BUN_TMPDIR}"
      return 0
    fi

    warn "Candidate OpenCode temp directory could not load a test shared object: ${candidate}"
  done

  die "Could not find an exec-capable OpenCode temp directory. Set OPENCODE_BUN_TMPDIR to a path on a filesystem that is not mounted noexec."
}

ensure_ollama_service_unit() {
  if systemctl cat ollama >/dev/null 2>&1; then
    return 0
  fi

  warn "ollama.service was not found. Creating a minimal systemd unit."

  local ollama_bin
  ollama_bin="$(command -v ollama || true)"
  [ -n "$ollama_bin" ] || die "ollama binary not found; cannot create systemd service."

  sudo useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama 2>/dev/null || true
  sudo mkdir -p /usr/share/ollama
  sudo chown -R ollama:ollama /usr/share/ollama

  sudo tee /etc/systemd/system/ollama.service >/dev/null <<EOF_SERVICE
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=${ollama_bin} serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=multi-user.target
EOF_SERVICE
}

configure_ollama_service() {
  local outbound_proxy="$1"

  log "Configuring Ollama for local-only, CPU-friendly operation"
  sudo mkdir -p "$SCRIPT_OLLAMA_DROPIN_DIR"

  sudo tee "$SCRIPT_MAIN_DROPIN" >/dev/null <<EOF_MAIN
[Service]
Environment="OLLAMA_HOST=${OLLAMA_BIND}"
Environment="OLLAMA_CONTEXT_LENGTH=${CONTEXT}"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}"
Environment="OLLAMA_NO_CLOUD=${DISABLE_CLOUD}"

# Keep local client-to-Ollama traffic out of proxies.
Environment="NO_PROXY=127.0.0.1,localhost,::1"
Environment="no_proxy=127.0.0.1,localhost,::1"

# Avoid HTTP/ALL proxy interference with local Ollama API traffic.
# For outbound model downloads behind a proxy, this script writes HTTPS_PROXY
# into ${SCRIPT_PROXY_DROPIN}.
Environment="HTTP_PROXY="
Environment="http_proxy="
Environment="ALL_PROXY="
Environment="all_proxy="
UnsetEnvironment=HTTP_PROXY http_proxy ALL_PROXY all_proxy
EOF_MAIN

  if [ -n "$outbound_proxy" ]; then
    local proxy_escaped
    proxy_escaped="$(systemd_escape_env_value "$outbound_proxy")"

    log "Configuring outbound HTTPS proxy for Ollama model pulls"
    sudo tee "$SCRIPT_PROXY_DROPIN" >/dev/null <<EOF_PROXY
[Service]
# Outbound model pulls use HTTPS. The proxy URL may itself start with http://.
Environment="HTTPS_PROXY=${proxy_escaped}"
Environment="https_proxy=${proxy_escaped}"
EOF_PROXY
  else
    log "No Ollama outbound HTTPS proxy configured by this script"
    sudo rm -f "$SCRIPT_PROXY_DROPIN"
  fi

  sudo systemctl daemon-reload
  sudo systemctl enable --now ollama
  sudo systemctl restart ollama
}

write_opencode_auth() {
  log "Writing OpenCode local Ollama auth entry"
  mkdir -p "$HOME/.local/share/opencode"

  python3 - <<'PY_OPENCODE_AUTH'
import json
from pathlib import Path

path = Path.home() / ".local/share/opencode/auth.json"
path.parent.mkdir(parents=True, exist_ok=True)

data = {}
if path.exists():
    try:
        data = json.loads(path.read_text())
    except Exception:
        backup = path.with_name(path.name + ".bak")
        backup.write_text(path.read_text())
        data = {}

data["ollama"] = {
    "type": "api",
    "key": "ollama"
}

path.write_text(json.dumps(data, indent=2) + "\n")
print(path)
PY_OPENCODE_AUTH
}

if [ "${EUID}" -eq 0 ]; then
  warn "You are running as root. User-level OpenCode/Claude helpers will be written under ${HOME}."
fi

if ! command -v sudo >/dev/null 2>&1; then
  die "sudo is required."
fi

if [ "$LOCAL_MODEL" = "$MODEL" ]; then
  die "LOCAL_MODEL must not equal MODEL. Use a separate local model name, e.g. LOCAL_MODEL=gemma4-js-local."
fi

if [ "$CLAUDE_MODEL_ALIAS" = "$MODEL" ]; then
  die "CLAUDE_MODEL_ALIAS must not equal MODEL. Use a separate alias, e.g. CLAUDE_MODEL_ALIAS=claude-gemma4-js-local."
fi

validate_numeric_int SANITY_CURL_MAX_TIME "$SANITY_CURL_MAX_TIME"
validate_numeric_int SANITY_CURL_CONNECT_TIMEOUT "$SANITY_CURL_CONNECT_TIMEOUT"
validate_numeric_int SANITY_NUM_PREDICT "$SANITY_NUM_PREDICT"
validate_numeric_int INFERENCE_THREADS "$INFERENCE_THREADS"
validate_numeric_int OLLAMA_HEALTH_CURL_MAX_TIME "$OLLAMA_HEALTH_CURL_MAX_TIME"
validate_numeric_int OLLAMA_HEALTH_CURL_CONNECT_TIMEOUT "$OLLAMA_HEALTH_CURL_CONNECT_TIMEOUT"

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID_LIKE:-$ID}" in
    *rhel*|*fedora*|*centos*) ;;
    *) warn "This script assumes RHEL/Rocky/Alma/CentOS-like Linux. Continuing anyway." ;;
  esac
fi

log "Hardware summary"
lscpu | egrep 'Model name|Socket|Core|Thread|CPU\(s\)|Flags|NUMA' || true
free -h || true
df -h / /usr/share /opt "$HOME" 2>/dev/null || true

if ! lscpu | grep -qw avx2; then
  warn "AVX2 was not detected. CPU inference may be very slow. Consider E2B instead of E4B."
fi

if lscpu | grep -qw avx512f; then
  log "AVX-512 detected. The CPU runner may be able to use it."
else
  warn "AVX-512 not detected. AVX2 is still acceptable for E4B sanity/dev use."
fi

log "Installing base packages"
sudo dnf -y install \
  curl ca-certificates jq git tar zstd lsof procps-ng findutils which util-linux \
  gcc gcc-c++ make cmake python3 \
  || die "Base package installation failed."

sudo update-ca-trust || true

validate_opencode_timeout_config
ensure_opencode_bun_tmpdir

log "Preparing Node.js/npm for OpenCode without disturbing nvm"
if [ "$INSTALL_OPENCODE" = "1" ]; then
  ensure_node_for_opencode || warn "Node/npm is not available; OpenCode install may be skipped."
else
  cleanup_script_npm_settings_for_nvm
  source_nvm_if_available || true
  log "Skipping Node/OpenCode preparation because INSTALL_OPENCODE=0"
fi

log "Installing or checking Ollama"
if command -v ollama >/dev/null 2>&1 && [ "$UPDATE_OLLAMA" != "1" ]; then
  ollama -v || true
  log "Ollama already installed. Set UPDATE_OLLAMA=1 to run the upstream installer again."
else
  curl -fsSL https://ollama.com/install.sh | sh
fi

ensure_ollama_service_unit

OLLAMA_HTTPS_PROXY_EFFECTIVE="$(select_ollama_https_proxy)"
configure_ollama_service "$OLLAMA_HTTPS_PROXY_EFFECTIVE"

log "Waiting for Ollama API"
for i in $(seq 1 60); do
  if ollama_api_curl_health -fsS "${OLLAMA_API_BASE}/api/version" >/tmp/ollama-version.json; then
    jq . /tmp/ollama-version.json || cat /tmp/ollama-version.json
    break
  fi

  sleep 1

  if [ "$i" -eq 60 ]; then
    echo
    echo "Last direct local probe:"
    ollama_api_curl_health -sv "${OLLAMA_API_BASE}/api/version" || true

    echo
    echo "Port listener:"
    sudo ss -ltnp | grep ':11434' || true

    echo
    echo "Ollama service status:"
    sudo systemctl status ollama --no-pager || true

    echo
    echo "Ollama logs:"
    sudo journalctl -u ollama --no-pager -n 200 || true

    die "Ollama did not start or local health check was blocked."
  fi
done

log "Model pull policy"
if [ "$SKIP_PULL" = "1" ]; then
  warn "SKIP_PULL=1 set; skipping ollama pull for ${MODEL}."
elif model_exists "$MODEL" && [ "$FORCE_PULL" != "1" ]; then
  log "Model already present locally: ${MODEL}. Set FORCE_PULL=1 to refresh it."
else
  log "Pulling model: ${MODEL}"
  if ! ollama_cli pull "$MODEL"; then
    echo
    echo "Ollama daemon logs related to the failed pull:"
    sudo journalctl -u ollama --no-pager -n 200 \
      | grep -Ei 'pull|manifest|registry|proxy|timeout|error|cloud|tls|certificate|connect' || true

    die "Model pull failed. If this VM uses a proxy, set OLLAMA_HTTPS_PROXY=http://proxy:port and rerun."
  fi
fi

log "Unloading stale local model handles, if any"
unload_ollama_model "$LOCAL_MODEL"
if [ "$CLAUDE_MODEL_ALIAS" != "$LOCAL_MODEL" ]; then
  unload_ollama_model "$CLAUDE_MODEL_ALIAS"
fi

log "Creating or updating local model profile: ${LOCAL_MODEL} with context ${CONTEXT}"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

cat > "${workdir}/Modelfile" <<EOF_MODEL
FROM ${MODEL}
PARAMETER num_ctx ${CONTEXT}
PARAMETER temperature 0.2
PARAMETER top_p 0.95
PARAMETER repeat_penalty 1.05
SYSTEM """
You are a local JavaScript coding assistant. Be precise, concise, and security-minded.
When asked to modify code, explain risky assumptions and return complete runnable snippets.
"""
EOF_MODEL

ollama_cli create "$LOCAL_MODEL" -f "${workdir}/Modelfile"

if [ "$CLAUDE_MODEL_ALIAS" = "$LOCAL_MODEL" ]; then
  warn "CLAUDE_MODEL_ALIAS equals LOCAL_MODEL; skipping separate alias creation."
else
  log "Creating or updating Claude-compatible model alias: ${CLAUDE_MODEL_ALIAS}"
  cat > "${workdir}/ClaudeAlias.Modelfile" <<EOF_ALIAS
FROM ${LOCAL_MODEL}
EOF_ALIAS
  ollama_cli create "$CLAUDE_MODEL_ALIAS" -f "${workdir}/ClaudeAlias.Modelfile"
fi

log "Preloading model"
ollama_api_curl_sanity -fsS \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg model "$LOCAL_MODEL" --arg keep_alive "$OLLAMA_KEEP_ALIVE" '{model:$model, prompt:"", keep_alive:$keep_alive}')" \
  "${OLLAMA_API_BASE}/api/generate" \
  >/dev/null || true

log "Running JavaScript analysis/generation sanity check through Ollama native chat API"
PROMPT=$(cat <<'EOF_PROMPT'
Analyze this JavaScript for correctness and security. Then provide a safer rewrite.

function login(req, res, db) {
  const sql = "SELECT * FROM users WHERE name = '" + req.query.user + "'";
  db.query(sql, (err, rows) => {
    if (rows.length && rows[0].password == req.query.password) {
      res.send("ok");
    } else {
      res.status(401).send("nope");
    }
  });
}
EOF_PROMPT
)

payload="$(jq -nc \
  --arg model "$LOCAL_MODEL" \
  --arg prompt "$PROMPT" \
  --arg keep_alive "$OLLAMA_KEEP_ALIVE" \
  --argjson ctx "$CONTEXT" \
  --argjson threads "$INFERENCE_THREADS" \
  --argjson predict "$SANITY_NUM_PREDICT" \
  '{
    model:$model,
    stream:false,
    keep_alive:$keep_alive,
    options:{
      num_ctx:$ctx,
      temperature:0.2,
      num_thread:$threads,
      num_predict:$predict
    },
    messages:[{role:"user", content:$prompt}]
  }'
)"

native_start_ns="$(now_ns)"

if ! native_out="$(ollama_api_curl_sanity -fsS \
  -H 'Content-Type: application/json' \
  -d "$payload" \
  "${OLLAMA_API_BASE}/api/chat")"; then

  native_end_ns="$(now_ns)"
  native_elapsed_sec="$(elapsed_seconds "$native_start_ns" "$native_end_ns")"

  echo
  echo "----- Ollama native API request failed -----"
  echo "Elapsed wall-clock time: ${native_elapsed_sec}s"
  echo "Curl max-time: ${SANITY_CURL_MAX_TIME} 0 means no curl max-time"
  die "JavaScript analysis/generation sanity check failed."
fi

native_end_ns="$(now_ns)"
native_elapsed_sec="$(elapsed_seconds "$native_start_ns" "$native_end_ns")"

native_reported_total_sec="$(echo "$native_out" | jq -r '
  if .total_duration then
    (.total_duration / 1000000000 | tostring)
  else
    "n/a"
  end
')"

native_prompt_tps="$(echo "$native_out" | jq -r '
  if .prompt_eval_count and .prompt_eval_duration and .prompt_eval_duration > 0 then
    (.prompt_eval_count / (.prompt_eval_duration / 1000000000) | tostring)
  else
    "n/a"
  end
')"

native_output_tps="$(echo "$native_out" | jq -r '
  if .eval_count and .eval_duration and .eval_duration > 0 then
    (.eval_count / (.eval_duration / 1000000000) | tostring)
  else
    "n/a"
  end
')"

native_prompt_tokens="$(echo "$native_out" | jq -r '.prompt_eval_count // "n/a"')"
native_output_tokens="$(echo "$native_out" | jq -r '.eval_count // "n/a"')"

echo
echo "----- Ollama native API response -----"
echo "Elapsed wall-clock time: ${native_elapsed_sec}s"
echo "Ollama-reported total time: ${native_reported_total_sec}s"
echo "Prompt tokens: ${native_prompt_tokens}"
echo "Output tokens: ${native_output_tokens}"
echo "Prompt eval speed: ${native_prompt_tps} tokens/sec"
echo "Output eval speed: ${native_output_tps} tokens/sec"
echo "Curl max-time: ${SANITY_CURL_MAX_TIME} 0 means no curl max-time"
echo "Keep alive: ${OLLAMA_KEEP_ALIVE}"
echo
echo "$native_out" | jq -r '.message.content'

log "Running Anthropic Messages API sanity check for Claude Code compatibility"
anthropic_payload="$(jq -nc \
  --arg model "$CLAUDE_MODEL_ALIAS" \
  --arg prompt "In one paragraph, explain what a closure is in JavaScript and include a 5-line example." \
  --argjson max_tokens "$SANITY_NUM_PREDICT" \
  '{
    model:$model,
    max_tokens:$max_tokens,
    system:"You are a terse JavaScript tutor.",
    messages:[{role:"user", content:$prompt}]
  }'
)"

anthropic_start_ns="$(now_ns)"

if ! anthropic_out="$(ollama_api_curl_sanity -fsS \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer ollama' \
  -d "$anthropic_payload" \
  "${OLLAMA_API_BASE}/v1/messages")"; then

  anthropic_end_ns="$(now_ns)"
  anthropic_elapsed_sec="$(elapsed_seconds "$anthropic_start_ns" "$anthropic_end_ns")"

  echo
  echo "----- Anthropic-compatible API request failed -----"
  echo "Elapsed wall-clock time: ${anthropic_elapsed_sec}s"
  echo "Curl max-time: ${SANITY_CURL_MAX_TIME} 0 means no curl max-time"
  die "Anthropic-compatible API sanity check failed."
fi

anthropic_end_ns="$(now_ns)"
anthropic_elapsed_sec="$(elapsed_seconds "$anthropic_start_ns" "$anthropic_end_ns")"

echo
echo "----- Anthropic-compatible API response -----"
echo "Elapsed wall-clock time: ${anthropic_elapsed_sec}s"
echo "Curl max-time: ${SANITY_CURL_MAX_TIME} 0 means no curl max-time"
echo
echo "$anthropic_out" | jq -r '.content[0].text // .content // .'

log "Writing OpenCode config"
mkdir -p "$HOME/.config/opencode"

cat > "$HOME/.config/opencode/opencode.json" <<EOF_OPENCODE
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "ollama/${LOCAL_MODEL}",
  "small_model": "ollama/${LOCAL_MODEL}",
  "default_agent": "plan",
  "autoupdate": false,
  "share": "disabled",
  "snapshot": false,
  "enabled_providers": ["ollama"],
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (local)",
      "options": {
        "baseURL": "${OLLAMA_CLIENT_BASE}/v1",
        "apiKey": "ollama",
        "timeout": ${OPENCODE_REQUEST_TIMEOUT_JSON},
        "chunkTimeout": ${OPENCODE_CHUNK_TIMEOUT_MS}
      },
      "models": {
        "${LOCAL_MODEL}": {
          "name": "Gemma 4 local (${LOCAL_MODEL})",
          "limit": {
            "context": ${CONTEXT},
            "output": ${SANITY_NUM_PREDICT}
          }
        },
        "${CLAUDE_MODEL_ALIAS}": {
          "name": "Gemma 4 local Claude alias",
          "limit": {
            "context": ${CONTEXT},
            "output": ${SANITY_NUM_PREDICT}
          }
        }
      }
    }
  }
}
EOF_OPENCODE

cat "$HOME/.config/opencode/opencode.json"

write_opencode_auth

if [ "$INSTALL_OPENCODE" = "1" ]; then
  log "Installing or checking OpenCode in isolated npm prefix: ${OPENCODE_NPM_PREFIX}"

  if ensure_node_for_opencode && command -v npm >/dev/null 2>&1; then
    mkdir -p "$OPENCODE_NPM_PREFIX"

    if [ -x "$OPENCODE_BIN" ] && [ "$UPDATE_OPENCODE" != "1" ]; then
      log "OpenCode already installed in isolated prefix. Set UPDATE_OPENCODE=1 to reinstall/update."
      "$OPENCODE_BIN" --version || true
    else
      npm --prefix "$OPENCODE_NPM_PREFIX" install --no-save opencode-ai \
        || warn "npm install of opencode-ai failed. Check proxy/npm access."
      "$OPENCODE_BIN" --version || true
    fi
  else
    warn "npm not found. Skipping OpenCode install."
  fi
fi

if [ "$INSTALL_CLAUDE_CODE" = "1" ]; then
  log "Installing or checking Claude Code"
  if command -v claude >/dev/null 2>&1 && [ "$UPDATE_CLAUDE_CODE" != "1" ]; then
    log "Claude Code already installed. Set UPDATE_CLAUDE_CODE=1 to reinstall/update."
    claude --version || true
  else
    curl -fsSL https://claude.ai/install.sh | bash
    export PATH="$HOME/.local/bin:$HOME/bin:$PATH"
    claude --version || true
  fi
else
  log "Skipping Claude Code install because INSTALL_CLAUDE_CODE=0"
fi

log "Creating helper launchers in ~/bin"
mkdir -p "$HOME/bin"

opencode_bun_tmpdir_quoted="$(shell_single_quote "$OPENCODE_BUN_TMPDIR")"
opencode_bin_quoted="$(shell_single_quote "$OPENCODE_BIN")"

cat > "$HOME/bin/opencode-local-gemma4" <<EOF_OPENCODE_HELPER
#!/usr/bin/env bash
set -Eeuo pipefail

# nvm-safe launcher. It loads nvm if available but does not modify npm prefix.
export PATH="\$HOME/.local/bin:\$HOME/bin:\$PATH"
export NVM_DIR="\${NVM_DIR:-\$HOME/.nvm}"

if [ -s "\$NVM_DIR/nvm.sh" ]; then
  # shellcheck disable=SC1090
  . "\$NVM_DIR/nvm.sh"
  nvm use --silent default >/dev/null 2>&1 || true
fi

DEFAULT_OPENCODE_BIN=${opencode_bin_quoted}
OPENCODE_BIN="\${OPENCODE_BIN:-\$DEFAULT_OPENCODE_BIN}"

if [ ! -x "\$OPENCODE_BIN" ]; then
  echo "ERROR: OpenCode binary not found at: \$OPENCODE_BIN" >&2
  echo "Rerun setup with INSTALL_OPENCODE=1, or set OPENCODE_BIN manually." >&2
  exit 1
fi

# OpenCode talks to local Ollama only. Do not let enterprise proxy variables
# intercept http://localhost:11434.
unset HTTP_PROXY http_proxy
unset HTTPS_PROXY https_proxy
unset ALL_PROXY all_proxy

# Extra Node/npm/global-agent proxy variables sometimes found in enterprise shells.
unset GLOBAL_AGENT_HTTP_PROXY GLOBAL_AGENT_HTTPS_PROXY GLOBAL_AGENT_NO_PROXY
unset npm_config_proxy npm_config_https_proxy
unset NODE_OPTIONS

export NO_PROXY="127.0.0.1,localhost,::1,localhost:11434,127.0.0.1:11434\${NO_PROXY:+,\$NO_PROXY}"
export no_proxy="\$NO_PROXY"
export npm_config_noproxy="\$NO_PROXY"

# Work around OpenTUI native-library extraction into /tmp on noexec systems.
# This directory must be on a filesystem that is NOT mounted noexec.
DEFAULT_OPENCODE_BUN_TMPDIR=${opencode_bun_tmpdir_quoted}
export BUN_TMPDIR="\${OPENCODE_BUN_TMPDIR:-\$DEFAULT_OPENCODE_BUN_TMPDIR}"
export TMPDIR="\$BUN_TMPDIR"
export TMP="\$BUN_TMPDIR"
export TEMP="\$BUN_TMPDIR"

mkdir -p "\$BUN_TMPDIR"
chmod 700 "\$BUN_TMPDIR" 2>/dev/null || true

if findmnt -no OPTIONS -T "\$BUN_TMPDIR" 2>/dev/null | tr ',' '\n' | grep -qx noexec; then
  echo "ERROR: BUN_TMPDIR=\$BUN_TMPDIR is on a noexec filesystem." >&2
  echo "Choose an exec-capable directory and rerun setup, for example:" >&2
  echo "  OPENCODE_BUN_TMPDIR=/path/on/exec/fs ./setup-gemma4-local.sh" >&2
  exit 1
fi

# Keep OpenCode local and lightweight.
export OPENCODE_DISABLE_AUTOUPDATE=1
export OPENCODE_DISABLE_MODELS_FETCH=1
export OPENCODE_DISABLE_LSP_DOWNLOAD=1
export OPENCODE_DISABLE_DEFAULT_PLUGINS=1
export OPENCODE_DISABLE_CLAUDE_CODE=1
export OPENCODE_DISABLE_CLAUDE_CODE_PROMPT=1
export OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1
export OPENCODE_DISABLE_MOUSE=1

# Inline config has high precedence and keeps this wrapper local-only even if
# a project-level opencode.json exists.
export OPENCODE_CONFIG_CONTENT="\$(cat <<'JSON'
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "ollama/${LOCAL_MODEL}",
  "small_model": "ollama/${LOCAL_MODEL}",
  "default_agent": "plan",
  "autoupdate": false,
  "share": "disabled",
  "snapshot": false,
  "enabled_providers": ["ollama"],
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (local)",
      "options": {
        "baseURL": "${OLLAMA_CLIENT_BASE}/v1",
        "apiKey": "ollama",
        "timeout": ${OPENCODE_REQUEST_TIMEOUT_JSON},
        "chunkTimeout": ${OPENCODE_CHUNK_TIMEOUT_MS}
      },
      "models": {
        "${LOCAL_MODEL}": {
          "name": "Gemma 4 local",
          "limit": {
            "context": ${CONTEXT},
            "output": ${SANITY_NUM_PREDICT}
          }
        }
      }
    }
  }
}
JSON
)"

if [ "\${1:-}" = "run" ]; then
  shift
  exec "\$OPENCODE_BIN" --pure run --model "ollama/${LOCAL_MODEL}" "\$@"
else
  exec "\$OPENCODE_BIN" --pure --model "ollama/${LOCAL_MODEL}" "\$@"
fi
EOF_OPENCODE_HELPER
chmod +x "$HOME/bin/opencode-local-gemma4"

cat > "$HOME/bin/claude-local-gemma4" <<EOF_CLAUDE_HELPER
#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="\$HOME/.local/bin:\$HOME/bin:\$PATH"

# Claude Code is pointed at local Ollama only. Do not let enterprise proxy
# variables intercept http://localhost:11434.
unset HTTP_PROXY http_proxy
unset HTTPS_PROXY https_proxy
unset ALL_PROXY all_proxy
unset GLOBAL_AGENT_HTTP_PROXY GLOBAL_AGENT_HTTPS_PROXY GLOBAL_AGENT_NO_PROXY
unset NODE_OPTIONS

export ANTHROPIC_AUTH_TOKEN=ollama
export ANTHROPIC_BASE_URL=${OLLAMA_CLIENT_BASE}
export CLAUDE_CODE_ATTRIBUTION_HEADER=0
export NO_PROXY="127.0.0.1,localhost,::1,localhost:11434,127.0.0.1:11434\${NO_PROXY:+,\$NO_PROXY}"
export no_proxy="\$NO_PROXY"

exec claude --model "${CLAUDE_MODEL_ALIAS}" "\$@"
EOF_CLAUDE_HELPER
chmod +x "$HOME/bin/claude-local-gemma4"

if ! grep -q 'export PATH="$HOME/bin:$PATH"' "$HOME/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"
fi

if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
fi

log "Current Ollama models"
ollama_cli list || true

log "Current Ollama loaded models"
ollama_cli ps || true

log "Setup complete"
cat <<EOF_DONE

Local model:
  ${LOCAL_MODEL}

Claude-compatible alias:
  ${CLAUDE_MODEL_ALIAS}

Ollama local API:
  ${OLLAMA_CLIENT_BASE}

Ollama keep-alive:
  ${OLLAMA_KEEP_ALIVE}

OpenCode binary:
  ${OPENCODE_BIN}

OpenCode npm prefix:
  ${OPENCODE_NPM_PREFIX}

OpenCode request timeout:
  ${OPENCODE_REQUEST_TIMEOUT_JSON}

OpenCode chunk timeout:
  ${OPENCODE_CHUNK_TIMEOUT_MS} ms

Sanity-check curl max-time:
  ${SANITY_CURL_MAX_TIME}
  0 means no curl max-time for inference calls.

OpenCode/OpenTUI temp directory:
  ${OPENCODE_BUN_TMPDIR}

Use OpenCode TUI:
  source ~/.bashrc
  cd /path/to/project
  opencode-local-gemma4 .

OpenCode one-shot smoke test:
  mkdir -p /tmp/oc-smoke
  cd /tmp/oc-smoke
  opencode-local-gemma4 run --dir /tmp/oc-smoke --title smoke "Reply with exactly: OK"

Use Claude Code:
  source ~/.bashrc
  cd /path/to/project
  claude-local-gemma4 .

Manual Claude Code environment:
  export ANTHROPIC_AUTH_TOKEN=ollama
  export ANTHROPIC_BASE_URL=${OLLAMA_CLIENT_BASE}
  claude --model ${CLAUDE_MODEL_ALIAS}

Re-test local Ollama health check:
  curl -fsS --noproxy '*' -H 'Host: ${OLLAMA_HOST_HEADER}' ${OLLAMA_API_BASE}/api/version

Refresh the base model on a later rerun:
  FORCE_PULL=1 ./setup-gemma4-local.sh

Set a finite sanity-check timeout:
  SANITY_CURL_MAX_TIME=900 ./setup-gemma4-local.sh

Set a finite OpenCode provider timeout:
  OPENCODE_REQUEST_TIMEOUT_JSON=900000 ./setup-gemma4-local.sh

Change keep-alive on a later rerun:
  OLLAMA_KEEP_ALIVE=30m ./setup-gemma4-local.sh

Keep the Ollama model loaded indefinitely:
  OLLAMA_KEEP_ALIVE=-1 ./setup-gemma4-local.sh

Override OpenCode/OpenTUI temp directory on a later rerun:
  OPENCODE_BUN_TMPDIR=/path/on/exec/fs ./setup-gemma4-local.sh

Skip Claude Code install on a later rerun:
  INSTALL_CLAUDE_CODE=0 ./setup-gemma4-local.sh

Disable this script's proxy drop-in on a later rerun:
  DISABLE_PROXY_CONFIG=1 ./setup-gemma4-local.sh

EOF_DONE
