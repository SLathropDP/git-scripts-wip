echo "=== configured isolated prefix ==="
echo "$HOME/.local/opencode-npm"

echo
echo "=== possible OpenCode binaries ==="
find "$HOME/.local/opencode-npm" -type f -o -type l 2>/dev/null | grep '/opencode$' || true

echo
echo "=== npm global bin for isolated prefix ==="
npm --prefix "$HOME/.local/opencode-npm" bin -g 2>/dev/null || true

echo
echo "=== installed opencode package under isolated prefix ==="
npm --prefix "$HOME/.local/opencode-npm" list -g --depth=0 2>/dev/null || true
npm --prefix "$HOME/.local/opencode-npm" list --depth=0 2>/dev/null || true

echo
echo "=== normal shell opencode ==="
command -v opencode || true
opencode --version 2>/dev/null || true
