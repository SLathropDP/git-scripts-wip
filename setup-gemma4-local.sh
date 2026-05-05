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
#   # Auto-detect HTTPS_PROXY/https_proxy from your shell and pass it to the Ollama daemon:
#   HTTPS_PROXY=http://proxy.example.com:8080 CONTEXT=16384 ./setup-gemma4-local.sh
#
#   # Explicitly set the proxy used by the Ollama daemon for model pulls:
#   OLLAMA_HTTPS_PROXY=http://proxy.example.com:8080 CONTEXT=16384 ./setup-gemma4-local.sh
#
#   # Remove this script's Ollama daemon proxy drop-in:
#   DISABLE_PROXY_CONFIG=1 ./setup-gemma4-local.sh
#
# Useful variants:
#   INSTALL_OPENCODE=0 ./setup-gemma4-local.sh
#   INSTALL_CLAUDE_CODE=0 ./setup-gemma4-local.sh
#   MODEL=gemma4:e2b-it-q4_K_M LOCAL_MODEL=gemma4-e2b-js CONTEXT=8192 ./setup-gemma4-local.sh
#   MODEL=gemma4:26b-a4b-it-q4_K_M LOCAL_MODEL=gemma4-26b-js CONTEXT=4096 ./setup-gemma4-local.sh
#   OLLAMA_KEEP_ALIVE=30m ./setup-gemma4-local.sh
#   FORCE_PULL=1 ./setup-gemma4-local.sh
#
# Timing / sanity-check controls:
#   SANITY_CURL_MAX_TIME=600        # 10 minutes by default
#   SANITY_CURL_CONNECT_TIMEOUT=30
#   SANITY_NUM_PREDICT=512
#   INFERENCE_THREADS=4
#
# Notes:
#   - Local Ollama API calls deliberately use:
#       curl --noproxy '*' -H 'Host: localhost:11434'
#     because some RHEL/AWS/proxy environments return 403 for plain
#     http://127.0.0.1:11434 curl checks.
#   - Model pulls are performed by the Ollama systemd service, so outbound
#     HTTPS proxy configuration must be present in the service environment,
#     not merely in your interactive shell.
#   - The script is designed to be re-runnable after partial or complete runs.

set -Eeuo pipefail

MODEL="${MODEL:-gemma4:e4b-it-q4_K_M}"
LOCAL_MODEL="${LOCAL_MODEL:-gemma4-js-local}"
CLAUDE_MODEL_ALIAS="${CLAUDE_MODEL_ALIAS:-claude-gemma4-js-local}"
CONTEXT="${CONTEXT:-16384}"

INSTALL_OPENCODE="${INSTALL_OPENCODE:-1}"
INSTALL_CLAUDE_CODE="${INSTALL_CLAUDE_CODE:-1}"
UPDATE_OPENCODE="${UPDATE_OPENCODE:-0}"
UPDATE_CLAUDE_CODE="${UPDATE_CLAUDE_CODE:-0}"

DISABLE_CLOUD="${DISABLE_CLOUD:-1}"
UPDATE_OLLAMA="${UPDATE_OLLAMA:-0}"
FORCE_PULL="${FORCE_PULL:-0}"
SKIP_PULL="${SKIP_PULL:-0}"
DISABLE_PROXY_CONFIG="${DISABLE_PROXY_CONFIG:-0}"

OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-120m}"

SANITY_CURL_MAX_TIME="${SANITY_CURL_MAX_TIME:-600}"
SANITY_CURL_CONNECT_TIMEOUT="${SANITY_CURL_CONNECT_TIMEOUT:-30}"
SANITY_NUM_PREDICT="${SANITY_NUM_PREDICT:-512}"
INFERENCE_THREADS="${INFERENCE_THREADS:-4}"

# Preserve whether OLLAMA_HTTPS_PROXY was explicitly supplied by the caller.
REQUESTED_OLLAMA_HTTPS_PROXY="${OLLAMA_HTTPS_PROXY:-}"

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
export PATH="$HOME/bin:$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

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

now_ns() {
  date +%s%N
}

elapsed_seconds() {
  local start_ns="$1"
  local end_ns="$2"

  awk -v s="$start_ns" -v e="$end_ns" 'BEGIN { printf "%.3f", (e - s) / 1000000000 }'
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

# Use this for slow local inference sanity checks.
ollama_api_curl_sanity() {
  ollama_api_curl \
    --connect-timeout "$SANITY_CURL_CONNECT_TIMEOUT" \
    --max-time "$SANITY_CURL_MAX_TIME" \
    "$@"
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

  ollama_api_curl -fsS \
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

  # Highest priority: explicit script input.
  if [ -n "$REQUESTED_OLLAMA_HTTPS_PROXY" ]; then
    printf '%s' "$REQUESTED_OLLAMA_HTTPS_PROXY"
    return 0
  fi

  # Next: current interactive shell HTTPS proxy.
  if [ -n "${HTTPS_PROXY:-}" ]; then
    printf '%s' "$HTTPS_PROXY"
    return 0
  fi

  if [ -n "${https_proxy:-}" ]; then
    printf '%s' "$https_proxy"
    return 0
  fi

  # Next: preserve a previously configured Ollama service HTTPS proxy.
  local existing_proxy
  existing_proxy="$(detect_existing_ollama_https_proxy || true)"
  if [ -n "$existing_proxy" ]; then
    printf '%s' "$existing_proxy"
    return 0
  fi

  # Last resort: use ALL_PROXY only for the daemon's outbound HTTPS pulls.
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
df -h / /usr/share 2>/dev/null || true

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

log "Installing Node.js/npm if absent"
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  sudo dnf module reset -y nodejs || true
  sudo dnf module enable -y nodejs:20 || true
  sudo dnf -y install nodejs npm || warn "Could not install Node.js/npm from AppStream."
fi

node --version || true
npm --version || true

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
  if ollama_api_curl -fsS "${OLLAMA_API_BASE}/api/version" >/tmp/ollama-version.json; then
    jq . /tmp/ollama-version.json || cat /tmp/ollama-version.json
    break
  fi

  sleep 1

  if [ "$i" -eq 60 ]; then
    echo
    echo "Last direct local probe:"
    ollama_api_curl -sv "${OLLAMA_API_BASE}/api/version" || true

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
  echo "Curl max-time: ${SANITY_CURL_MAX_TIME}s"
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
echo "Curl max-time: ${SANITY_CURL_MAX_TIME}s"
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
  echo "Curl max-time: ${SANITY_CURL_MAX_TIME}s"
  die "Anthropic-compatible API sanity check failed."
fi

anthropic_end_ns="$(now_ns)"
anthropic_elapsed_sec="$(elapsed_seconds "$anthropic_start_ns" "$anthropic_end_ns")"

echo
echo "----- Anthropic-compatible API response -----"
echo "Elapsed wall-clock time: ${anthropic_elapsed_sec}s"
echo "Curl max-time: ${SANITY_CURL_MAX_TIME}s"
echo
echo "$anthropic_out" | jq -r '.content[0].text // .content // .'

log "Writing OpenCode config"
mkdir -p "$HOME/.config/opencode"

cat > "$HOME/.config/opencode/opencode.json" <<EOF_OPENCODE
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (local)",
      "options": {
        "baseURL": "${OLLAMA_CLIENT_BASE}/v1"
      },
      "models": {
        "${LOCAL_MODEL}": {
          "name": "Gemma 4 local (${LOCAL_MODEL})"
        },
        "${CLAUDE_MODEL_ALIAS}": {
          "name": "Gemma 4 local Claude alias"
        }
      }
    }
  }
}
EOF_OPENCODE

cat "$HOME/.config/opencode/opencode.json"

if [ "$INSTALL_OPENCODE" = "1" ]; then
  log "Installing or checking OpenCode via user-local npm"
  if command -v npm >/dev/null 2>&1; then
    mkdir -p "$HOME/.npm-global"
    npm config set prefix "$HOME/.npm-global"
    export PATH="$HOME/.npm-global/bin:$PATH"

    if ! grep -q '.npm-global/bin' "$HOME/.bashrc" 2>/dev/null; then
      echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> "$HOME/.bashrc"
    fi

    if command -v opencode >/dev/null 2>&1 && [ "$UPDATE_OPENCODE" != "1" ]; then
      log "OpenCode already installed. Set UPDATE_OPENCODE=1 to reinstall/update."
      opencode --version || true
    else
      npm install -g opencode-ai || warn "npm install -g opencode-ai failed. Install OpenCode manually if needed."
      opencode --version || true
    fi
  else
    warn "npm not found. Install OpenCode later with: curl -fsSL https://opencode.ai/install | bash"
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

cat > "$HOME/bin/opencode-local-gemma4" <<EOF_OPENCODE_HELPER
#!/usr/bin/env bash
export PATH="\$HOME/.npm-global/bin:\$HOME/.local/bin:\$HOME/bin:\$PATH"
export NO_PROXY="127.0.0.1,localhost,::1\${NO_PROXY:+,\$NO_PROXY}"
export no_proxy="\$NO_PROXY"
exec opencode --model "ollama/${LOCAL_MODEL}" "\$@"
EOF_OPENCODE_HELPER
chmod +x "$HOME/bin/opencode-local-gemma4"

cat > "$HOME/bin/claude-local-gemma4" <<EOF_CLAUDE_HELPER
#!/usr/bin/env bash
export PATH="\$HOME/.local/bin:\$HOME/bin:\$PATH"
export ANTHROPIC_AUTH_TOKEN=ollama
export ANTHROPIC_BASE_URL=${OLLAMA_CLIENT_BASE}
export CLAUDE_CODE_ATTRIBUTION_HEADER=0
export NO_PROXY="127.0.0.1,localhost,::1\${NO_PROXY:+,\$NO_PROXY}"
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

Sanity-check timeout:
  ${SANITY_CURL_MAX_TIME}s

Use OpenCode:
  source ~/.bashrc
  cd /path/to/project
  opencode-local-gemma4 .

OpenCode one-shot:
  opencode run --model ollama/${LOCAL_MODEL} "Review src/foo.js for bugs"

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

Increase sanity-check timeout:
  SANITY_CURL_MAX_TIME=900 ./setup-gemma4-local.sh

Change keep-alive on a later rerun:
  OLLAMA_KEEP_ALIVE=30m ./setup-gemma4-local.sh

Skip Claude Code install on a later rerun:
  INSTALL_CLAUDE_CODE=0 ./setup-gemma4-local.sh

Disable this script's proxy drop-in on a later rerun:
  DISABLE_PROXY_CONFIG=1 ./setup-gemma4-local.sh

EOF_DONE
