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
#
# Example install/execute:
#   chmod +x setup-gemma4-local.sh
#   CONTEXT=16384 ./setup-gemma4-local.sh
#
# Useful variants:
#   INSTALL_OPENCODE=0 ./setup-gemma4-local.sh
#   INSTALL_CLAUDE_CODE=1 ./setup-gemma4-local.sh
#   MODEL=gemma4:e2b-it-q4_K_M LOCAL_MODEL=gemma4-e2b-js CONTEXT=8192 ./setup-gemma4-local.sh
#   MODEL=gemma4:26b-a4b-it-q4_K_M LOCAL_MODEL=gemma4-26b-js CONTEXT=4096 ./setup-gemma4-local.sh
#
# Notes:
#   - Local Ollama API calls deliberately use:
#       curl --noproxy '*' -H 'Host: localhost:11434'
#     because some RHEL/AWS/proxy environments return 403 for plain
#     http://127.0.0.1:11434 curl checks.
#   - Outbound installer/model-download traffic is not forced through --noproxy.

set -Eeuo pipefail

MODEL="${MODEL:-gemma4:e4b-it-q4_K_M}"
LOCAL_MODEL="${LOCAL_MODEL:-gemma4-js-local}"
CLAUDE_MODEL_ALIAS="${CLAUDE_MODEL_ALIAS:-claude-gemma4-js-local}"
CONTEXT="${CONTEXT:-16384}"
INSTALL_OPENCODE="${INSTALL_OPENCODE:-1}"
INSTALL_CLAUDE_CODE="${INSTALL_CLAUDE_CODE:-0}"
DISABLE_CLOUD="${DISABLE_CLOUD:-1}"
UPDATE_OLLAMA="${UPDATE_OLLAMA:-0}"

# Service bind address. Keep this local-only unless you know exactly why you need otherwise.
OLLAMA_BIND="${OLLAMA_BIND:-127.0.0.1:11434}"

# API endpoint used by this script for local curl checks.
OLLAMA_API_BASE="${OLLAMA_API_BASE:-http://127.0.0.1:11434}"

# Base URL used by OpenCode/Claude Code. localhost generally produces the accepted Host header.
OLLAMA_CLIENT_BASE="${OLLAMA_CLIENT_BASE:-http://localhost:11434}"
OLLAMA_CLI_HOST="${OLLAMA_CLI_HOST:-localhost:11434}"
OLLAMA_HOST_HEADER="${OLLAMA_HOST_HEADER:-localhost:11434}"

log()  { printf "\n\033[1;32m==> %s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33mWARN: %s\033[0m\n" "$*" >&2; }
die()  { printf "\nERROR: %s\n" "$*" >&2; exit 1; }

# Use this wrapper for local Ollama HTTP API calls only.
# It bypasses proxy interception and supplies the Host header that worked in testing.
ollama_api_curl() {
  env \
    NO_PROXY="127.0.0.1,localhost,::1${NO_PROXY:+,$NO_PROXY}" \
    no_proxy="127.0.0.1,localhost,::1${no_proxy:+,$no_proxy}" \
    curl --noproxy '*' \
      -H "Host: ${OLLAMA_HOST_HEADER}" \
      "$@"
}

# Use this wrapper for local Ollama CLI calls.
ollama_cli() {
  env \
    NO_PROXY="127.0.0.1,localhost,::1${NO_PROXY:+,$NO_PROXY}" \
    no_proxy="127.0.0.1,localhost,::1${no_proxy:+,$no_proxy}" \
    OLLAMA_HOST="${OLLAMA_CLI_HOST}" \
    ollama "$@"
}

if ! command -v sudo >/dev/null 2>&1; then
  die "sudo is required."
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

log "Configuring Ollama for local-only, CPU-friendly operation"
sudo mkdir -p /etc/systemd/system/ollama.service.d

sudo tee /etc/systemd/system/ollama.service.d/10-local-gemma4.conf >/dev/null <<EOF
[Service]
Environment="OLLAMA_HOST=${OLLAMA_BIND}"
Environment="OLLAMA_CONTEXT_LENGTH=${CONTEXT}"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_KEEP_ALIVE=10m"
Environment="OLLAMA_NO_CLOUD=${DISABLE_CLOUD}"

# Keep local client-to-Ollama traffic out of proxies.
Environment="NO_PROXY=127.0.0.1,localhost,::1"
Environment="no_proxy=127.0.0.1,localhost,::1"

# Avoid HTTP/ALL proxy interference with local Ollama API traffic.
# For outbound model downloads behind a corporate proxy, prefer OLLAMA_HTTPS_PROXY.
Environment="HTTP_PROXY="
Environment="http_proxy="
Environment="ALL_PROXY="
Environment="all_proxy="
UnsetEnvironment=HTTP_PROXY http_proxy ALL_PROXY all_proxy
EOF

if [ -n "${OLLAMA_HTTPS_PROXY:-}" ]; then
  sudo tee -a /etc/systemd/system/ollama.service.d/10-local-gemma4.conf >/dev/null <<EOF
Environment="HTTPS_PROXY=${OLLAMA_HTTPS_PROXY}"
Environment="https_proxy=${OLLAMA_HTTPS_PROXY}"
EOF
fi

sudo systemctl daemon-reload
sudo systemctl enable --now ollama
sudo systemctl restart ollama

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

log "Pulling model: ${MODEL}"
ollama_cli pull "$MODEL"

log "Creating local model profile: ${LOCAL_MODEL} with context ${CONTEXT}"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

cat > "${workdir}/Modelfile" <<EOF
FROM ${MODEL}
PARAMETER num_ctx ${CONTEXT}
PARAMETER temperature 0.2
PARAMETER top_p 0.95
PARAMETER repeat_penalty 1.05
SYSTEM """
You are a local JavaScript coding assistant. Be precise, concise, and security-minded.
When asked to modify code, explain risky assumptions and return complete runnable snippets.
"""
EOF

ollama_cli create "$LOCAL_MODEL" -f "${workdir}/Modelfile"

log "Creating Claude-compatible model alias: ${CLAUDE_MODEL_ALIAS}"
if ollama_cli show "$CLAUDE_MODEL_ALIAS" >/dev/null 2>&1; then
  ollama_cli rm "$CLAUDE_MODEL_ALIAS" >/dev/null 2>&1 || true
fi
ollama_cli cp "$LOCAL_MODEL" "$CLAUDE_MODEL_ALIAS" || true

log "Preloading model"
ollama_api_curl -fsS \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg model "$LOCAL_MODEL" '{model:$model, prompt:"", keep_alive:"10m"}')" \
  "${OLLAMA_API_BASE}/api/generate" \
  >/dev/null || true

log "Running JavaScript analysis/generation sanity check through Ollama native chat API"
PROMPT=$(cat <<'EOF'
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
EOF
)

payload="$(jq -nc \
  --arg model "$LOCAL_MODEL" \
  --arg prompt "$PROMPT" \
  --argjson ctx "$CONTEXT" \
  '{
    model:$model,
    stream:false,
    options:{num_ctx:$ctx, temperature:0.2, num_thread:4},
    messages:[{role:"user", content:$prompt}]
  }'
)"

native_out="$(ollama_api_curl -fsS \
  -H 'Content-Type: application/json' \
  -d "$payload" \
  "${OLLAMA_API_BASE}/api/chat")"

echo
echo "----- Ollama native API response -----"
echo "$native_out" | jq -r '.message.content'

log "Running Anthropic Messages API sanity check for Claude Code compatibility"
anthropic_payload="$(jq -nc \
  --arg model "$CLAUDE_MODEL_ALIAS" \
  --arg prompt "In one paragraph, explain what a closure is in JavaScript and include a 5-line example." \
  '{
    model:$model,
    max_tokens:512,
    system:"You are a terse JavaScript tutor.",
    messages:[{role:"user", content:$prompt}]
  }'
)"

anthropic_out="$(ollama_api_curl -fsS \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer ollama' \
  -d "$anthropic_payload" \
  "${OLLAMA_API_BASE}/v1/messages")"

echo
echo "----- Anthropic-compatible API response -----"
echo "$anthropic_out" | jq -r '.content[0].text // .content // .'

log "Writing OpenCode config"
mkdir -p "$HOME/.config/opencode"

cat > "$HOME/.config/opencode/opencode.json" <<EOF
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
EOF

cat "$HOME/.config/opencode/opencode.json"

if [ "$INSTALL_OPENCODE" = "1" ]; then
  log "Installing OpenCode via user-local npm"
  if command -v npm >/dev/null 2>&1; then
    mkdir -p "$HOME/.npm-global"
    npm config set prefix "$HOME/.npm-global"
    export PATH="$HOME/.npm-global/bin:$PATH"

    if ! grep -q '.npm-global/bin' "$HOME/.bashrc" 2>/dev/null; then
      echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> "$HOME/.bashrc"
    fi

    npm install -g opencode-ai || warn "npm install -g opencode-ai failed. Install OpenCode manually if needed."
    opencode --version || true
  else
    warn "npm not found. Install OpenCode later with: curl -fsSL https://opencode.ai/install | bash"
  fi
fi

if [ "$INSTALL_CLAUDE_CODE" = "1" ]; then
  log "Installing Claude Code"
  curl -fsSL https://claude.ai/install.sh | bash
fi

log "Creating helper launchers in ~/bin"
mkdir -p "$HOME/bin"

cat > "$HOME/bin/opencode-local-gemma4" <<EOF
#!/usr/bin/env bash
export PATH="\$HOME/.npm-global/bin:\$PATH"
export NO_PROXY="127.0.0.1,localhost,::1\${NO_PROXY:+,\$NO_PROXY}"
export no_proxy="\$NO_PROXY"
exec opencode --model "ollama/${LOCAL_MODEL}" "\$@"
EOF
chmod +x "$HOME/bin/opencode-local-gemma4"

cat > "$HOME/bin/claude-local-gemma4" <<EOF
#!/usr/bin/env bash
export ANTHROPIC_AUTH_TOKEN=ollama
export ANTHROPIC_BASE_URL=${OLLAMA_CLIENT_BASE}
export CLAUDE_CODE_ATTRIBUTION_HEADER=0
export NO_PROXY="127.0.0.1,localhost,::1\${NO_PROXY:+,\$NO_PROXY}"
export no_proxy="\$NO_PROXY"
exec claude --model "${CLAUDE_MODEL_ALIAS}" "\$@"
EOF
chmod +x "$HOME/bin/claude-local-gemma4"

if ! grep -q 'export PATH="$HOME/bin:$PATH"' "$HOME/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"
fi

log "Current Ollama loaded models"
ollama_cli ps || true

log "Setup complete"
cat <<EOF

Local model:
  ${LOCAL_MODEL}

Claude-compatible alias:
  ${CLAUDE_MODEL_ALIAS}

Ollama local API:
  ${OLLAMA_CLIENT_BASE}

Use OpenCode:
  source ~/.bashrc
  cd /path/to/project
  opencode-local-gemma4 .

OpenCode one-shot:
  opencode run --model ollama/${LOCAL_MODEL} "Review src/foo.js for bugs"

Use Claude Code after installing it:
  INSTALL_CLAUDE_CODE=1 ./setup-gemma4-local.sh
  source ~/.bashrc
  cd /path/to/project
  claude-local-gemma4 .

Manual Claude Code environment:
  export ANTHROPIC_AUTH_TOKEN=ollama
  export ANTHROPIC_BASE_URL=${OLLAMA_CLIENT_BASE}
  claude --model ${CLAUDE_MODEL_ALIAS}

Re-test local Ollama health check:
  curl -fsS --noproxy '*' -H 'Host: ${OLLAMA_HOST_HEADER}' ${OLLAMA_API_BASE}/api/version

Try 26B only as a slow experiment:
  MODEL=gemma4:26b-a4b-it-q4_K_M LOCAL_MODEL=gemma4-26b-js CONTEXT=4096 ./setup-gemma4-local.sh

EOF

