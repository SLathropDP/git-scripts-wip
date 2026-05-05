PROXY="${HTTPS_PROXY:-${https_proxy:-}}"

if [ -z "$PROXY" ]; then
  echo "No HTTPS_PROXY/https_proxy found in your shell."
  echo "Set it manually, for example:"
  echo "  PROXY='http://proxy.example.com:8080'"
  exit 1
fi

echo "Using proxy: $PROXY"

sudo mkdir -p /etc/systemd/system/ollama.service.d

sudo tee /etc/systemd/system/ollama.service.d/20-outbound-proxy.conf >/dev/null <<EOF
[Service]
# Outbound model pulls use HTTPS.
Environment="HTTPS_PROXY=${PROXY}"
Environment="https_proxy=${PROXY}"

# Keep local client-to-Ollama traffic out of the proxy.
Environment="NO_PROXY=127.0.0.1,localhost,::1"
Environment="no_proxy=127.0.0.1,localhost,::1"

# Avoid HTTP/ALL proxy interference with the local Ollama API.
Environment="HTTP_PROXY="
Environment="http_proxy="
Environment="ALL_PROXY="
Environment="all_proxy="
UnsetEnvironment=HTTP_PROXY http_proxy ALL_PROXY all_proxy
EOF

sudo systemctl daemon-reload
sudo systemctl restart ollama

curl -fsS --noproxy '*' \
  -H 'Host: localhost:11434' \
  http://127.0.0.1:11434/api/version

OLLAMA_HOST=localhost:11434 \
NO_PROXY="127.0.0.1,localhost,::1" \
no_proxy="127.0.0.1,localhost,::1" \
ollama pull gemma4:e4b-it-q4_K_M
