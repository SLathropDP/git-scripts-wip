python3 - <<'PY'
import json
from pathlib import Path

path = Path.home() / ".local/share/opencode/auth.json"
path.parent.mkdir(parents=True, exist_ok=True)

data = {}
if path.exists():
    try:
        data = json.loads(path.read_text())
    except Exception:
        backup = path.with_suffix(".json.bak")
        backup.write_text(path.read_text())
        data = {}

data["ollama"] = {
    "type": "api",
    "key": "ollama"
}

path.write_text(json.dumps(data, indent=2) + "\n")
print(path)
PY

opencode auth list || true
