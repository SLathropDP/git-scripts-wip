mkdir -p /tmp/oc-smoke
cd /tmp/oc-smoke

env \
  -u HTTP_PROXY -u http_proxy \
  -u HTTPS_PROXY -u https_proxy \
  -u ALL_PROXY -u all_proxy \
  -u GLOBAL_AGENT_HTTP_PROXY -u GLOBAL_AGENT_HTTPS_PROXY -u GLOBAL_AGENT_NO_PROXY \
  -u npm_config_proxy -u npm_config_https_proxy \
  -u NODE_OPTIONS \
  NO_PROXY="127.0.0.1,localhost,::1,localhost:11434,127.0.0.1:11434" \
  no_proxy="127.0.0.1,localhost,::1,localhost:11434,127.0.0.1:11434" \
  OPENCODE_DISABLE_AUTOUPDATE=1 \
  OPENCODE_DISABLE_MODELS_FETCH=1 \
  OPENCODE_DISABLE_LSP_DOWNLOAD=1 \
  OPENCODE_DISABLE_DEFAULT_PLUGINS=1 \
  OPENCODE_DISABLE_CLAUDE_CODE=1 \
  OPENCODE_DISABLE_CLAUDE_CODE_PROMPT=1 \
  OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1 \
  OPENCODE_DISABLE_MOUSE=1 \
  timeout 900 \
  opencode --log-level DEBUG --print-logs --pure run \
    --model ollama/gemma4-js-local \
    --dir /tmp/oc-smoke \
    --title smoke \
    "Reply with exactly: OK"
