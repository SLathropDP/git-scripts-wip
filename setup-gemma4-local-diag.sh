echo "=== Shell proxy environment ==="
env | grep -iE '^(https_proxy|http_proxy|all_proxy|no_proxy)=' || true

echo
echo "=== Shell can reach Ollama registry? ==="
curl -Iv --connect-timeout 10 --max-time 25 \
  https://registry.ollama.ai/v2/ || true

echo
echo "=== Ollama systemd environment ==="
sudo systemctl show ollama -p Environment

echo
echo "=== Ollama daemon process environment ==="
pid="$(systemctl show --property MainPID --value ollama)"
sudo tr '\0' '\n' < "/proc/${pid}/environ" \
  | sort \
  | grep -iE 'proxy|ollama' || true

echo
echo "=== Ollama logs around pull failure ==="
sudo journalctl -u ollama --no-pager -n 160 \
  | grep -Ei 'pull|manifest|registry|proxy|timeout|error|cloud' || true

