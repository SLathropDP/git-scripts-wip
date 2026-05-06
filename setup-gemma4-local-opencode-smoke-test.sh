mkdir -p /tmp/oc-smoke
cd /tmp/oc-smoke

time timeout 900 \
  opencode --log-level DEBUG --print-logs \
  run \
  --model ollama/gemma4-js-local \
  --dir /tmp/oc-smoke \
  --title "smoke" \
  "Reply with exactly: OK"
