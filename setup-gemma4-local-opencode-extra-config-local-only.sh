cat > "$HOME/bin/opencode-local-gemma4" <<'EOF'
#!/usr/bin/env bash
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$HOME/bin:$PATH"

# Keep localhost traffic away from your corporate/AWS proxy.
export NO_PROXY="127.0.0.1,localhost,::1${NO_PROXY:+,$NO_PROXY}"
export no_proxy="$NO_PROXY"

# Avoid startup/network surprises.
export OPENCODE_DISABLE_AUTOUPDATE=1
export OPENCODE_DISABLE_MODELS_FETCH=1
export OPENCODE_DISABLE_LSP_DOWNLOAD=1
export OPENCODE_DISABLE_DEFAULT_PLUGINS=1

# Important now that Claude Code is installed: do not import Claude Code prompt/skills.
export OPENCODE_DISABLE_CLAUDE_CODE=1
export OPENCODE_DISABLE_CLAUDE_CODE_PROMPT=1
export OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1

# Sometimes helpful over SSH/TUI sessions.
export OPENCODE_DISABLE_MOUSE=1

exec opencode --model "ollama/gemma4-js-local" "$@"
EOF

chmod +x "$HOME/bin/opencode-local-gemma4"

