mkdir -p "$HOME/.config/opencode" "$HOME/.local/share/opencode"

cp -a "$HOME/.config/opencode/opencode.json" \
  "$HOME/.config/opencode/opencode.json.bak.$(date +%Y%m%d-%H%M%S)" \
  2>/dev/null || true

cat > "$HOME/.config/opencode/opencode.json" <<'JSON'
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
