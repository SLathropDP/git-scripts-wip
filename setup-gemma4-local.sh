#!/usr/bin/env bash
set -Eeuo pipefail

MODEL="${MODEL:-gemma4:e4b-it-q4_K_M}"
LOCAL_MODEL="${LOCAL_MODEL:-gemma4-js-local}"
CLAUDE_MODEL_ALIAS="${CLAUDE_MODEL_ALIAS:-claude-gemma4-js-local}"
CONTEXT="${CONTEXT:-8192}"
INSTALL_OPENCODE="${INSTALL_OPENCODE:-1}"
INSTALL_CLAUDE_CODE="${INSTALL_CLAUDE_CODE:-0}"
DISABLE_CLOUD="${DISABLE_CLOUD:-1}"

log()  { printf "\n\033[1;32m==> %s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33mWARN: %s\033[0m\n" "$*" >&2; }
die()  { printf "\nERROR: %s\n" "$*" >&2; exit 1; }

if ! command -v sudo >/dev/null 2>&1; then
  die "sudo is required."
fi

if [ -r /etc/os-release ]; then
  . /etc/os-release
  case "${ID_LIKE:-$ID}" in
    *rhel*|*fedora*|*centos*) ;;
    *) warn "This script assumes RHEL/Rocky/Alma/CentOS-like Linux. Continuing anyway." ;;
  esac
fi

log "Hardware summary"
lscpu | egrep 'Model name|Socket|Core|Thread|CPU\(s\)|Flags' || true
free -h || true
df -h / /usr/share 2>/dev/null || true

if ! lscpu | grep -qw avx2; then
  warn "AVX2 was not detected. CPU inference may be very slow. Use the E2B model if E4B is painful."
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

log "Installing or updating Ollama"
if command -v ollama >/dev/null 2>&1; then
  ollama -v || true
else
  curl -fsSL https://ollama.com/install.sh | sh
fi

log "Configuring Ollama for local-only, CPU-friendly operation"
sudo mkdir -p /etc/systemd/system/ollama.service.d

sudo tee /etc/systemd/system/ollama.service.d/10-local-gemma4.conf >/dev/null <<EOF
[Service]
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_CONTEXT_LENGTH=${CONTEXT}"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_KEEP_ALIVE=10m"
Environment="OLLAMA_NO_CLOUD=${DISABLE_CLOUD}"
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now ollama
sudo systemctl restart ollama

log "Waiting for Ollama API"
for i in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:11434/api/version >/tmp/ollama-version.json; then
    jq . /tmp/ollama-version.json || cat /tmp/ollama-version.json
    break
  fi

  sleep 1

  if [ "$i" -eq 60 ]; then
    sudo journalctl -u ollama --no-pager -n 200 || true
    die "Ollama did not start."
  fi
done

log "Pulling model: ${MODEL}"
ollama pull "$MODEL"

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

ollama create "$LOCAL_MODEL" -f "${workdir}/Modelfile"

log "Creating Claude-compatible model alias: ${CLAUDE_MODEL_ALIAS}"
if ollama show "$CLAUDE_MODEL_ALIAS" >/dev/null 2>&1; then
  ollama rm "$CLAUDE_MODEL_ALIAS" >/dev/null 2>&1 || true
fi
ollama cp "$LOCAL_MODEL" "$CLAUDE_MODEL_ALIAS" || true

log "Preloading model"
curl -fsS http://127.0.0.1:11434/api/generate \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg model "$LOCAL_MODEL" '{model:$model, prompt:"", keep_alive:"10m"}')" \
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
    options:{num_ctx:$ctx, temperature:0.2},
    messages:[{role:"user", content:$prompt}]
  }'
)"

native_out="$(curl -fsS http://127.0.0.1:11434/api/chat \
  -H 'Content-Type: application/json' \
  -d "$payload")"

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

anthropic_out="$(curl -fsS http://127.0.0.1:11434/v1/messages \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer ollama' \
  -d "$anthropic_payload")"

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
        "baseURL": "http://127.0.0.1:11434/v1"
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

    npm install -g opencode-ai
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
exec opencode --model "ollama/${LOCAL_MODEL}" "\$@"
EOF
chmod +x "$HOME/bin/opencode-local-gemma4"

cat > "$HOME/bin/claude-local-gemma4" <<EOF
#!/usr/bin/env bash
export ANTHROPIC_AUTH_TOKEN=ollama
export ANTHROPIC_BASE_URL=http://127.0.0.1:11434
export CLAUDE_CODE_ATTRIBUTION_HEADER=0
exec claude --model "${CLAUDE_MODEL_ALIAS}" "\$@"
EOF
chmod +x "$HOME/bin/claude-local-gemma4"

if ! grep -q 'export PATH="$HOME/bin:$PATH"' "$HOME/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"
fi

log "Current Ollama loaded models"
ollama ps || true

log "Setup complete"
cat <<EOF

Use OpenCode:
  opencode-local-gemma4 /path/to/project

Or one-shot:
  opencode run --model ollama/${LOCAL_MODEL} "Review src/foo.js for bugs"

Use Claude Code after installing it:
  INSTALL_CLAUDE_CODE=1 ./setup-gemma4-local.sh
  claude-local-gemma4 /path/to/project

Manual Claude Code environment:
  export ANTHROPIC_AUTH_TOKEN=ollama
  export ANTHROPIC_BASE_URL=http://127.0.0.1:11434
  claude --model ${CLAUDE_MODEL_ALIAS}

Try 26B only as a slow experiment:
  MODEL=gemma4:26b-a4b-it-q4_K_M LOCAL_MODEL=gemma4-26b-js CONTEXT=4096 ./setup-gemma4-local.sh

EOF
