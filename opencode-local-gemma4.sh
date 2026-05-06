cat > "$HOME/bin/opencode-local-gemma4" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$HOME/bin:$PATH"

# OpenCode is talking to local Ollama only. Do not let corporate proxy
# variables intercept http://localhost:11434.
unset HTTP_PROXY http_proxy
unset HTTPS_PROXY https_proxy
unset ALL_PROXY all_proxy

# Extra Node/npm/global-agent proxy variables sometimes found in enterprise shells.
unset GLOBAL_AGENT_HTTP_PROXY GLOBAL_AGENT_HTTPS_PROXY GLOBAL_AGENT_NO_PROXY
unset npm_config_proxy npm_config_https_proxy
unset NODE_OPTIONS

export NO_PROXY="127.0.0.1,localhost,::1,localhost:11434,127.0.0.1:11434${NO_PROXY:+,$NO_PROXY}"
export no_proxy="$NO_PROXY"
export npm_config_noproxy="$NO_PROXY"

# Keep OpenCode local and lightweight.
export OPENCODE_DISABLE_AUTOUPDATE=1
export OPENCODE_DISABLE_MODELS_FETCH=1
export OPENCODE_DISABLE_LSP_DOWNLOAD=1
export OPENCODE_DISABLE_DEFAULT_PLUGINS=1
export OPENCODE_DISABLE_CLAUDE_CODE=1
export OPENCODE_DISABLE_CLAUDE_CODE_PROMPT=1
export OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1
export OPENCODE_DISABLE_MOUSE=1

# Force local config at runtime so project/global configs are less likely to
# redirect OpenCode to a remote provider.
export OPENCODE_CONFIG_CONTENT="$(cat <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "ollama/gemma4-js-local",
  "small_model": "ollama/gemma4-js-local",
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
        "baseURL": "http://localhost:11434/v1",
        "apiKey": "ollama",
        "timeout": 900000,
        "chunkTimeout": 600000
      },
      "models": {
        "gemma4-js-local": {
          "name": "Gemma 4 local",
          "limit": {
            "context": 16384,
            "output": 512
          }
        }
      }
    }
  }
}
JSON
)"

if [ "${1:-}" = "run" ]; then
  shift
  exec opencode --pure run --model "ollama/gemma4-js-local" "$@"
else
  exec opencode --pure --model "ollama/gemma4-js-local" "$@"
fi
EOF

chmod +x "$HOME/bin/opencode-local-gemma4"
