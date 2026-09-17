#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
VENV="$PROJECT_ROOT/.mcp-venv"
WRAPPER="$CODEX_HOME/bin/vphone-mcp"
CONFIG="$CODEX_HOME/config.toml"
PYTHON="${VPHONE_MCP_PYTHON:-/opt/homebrew/bin/python3.13}"

[[ -x "$PYTHON" ]] || { print -u2 "error: Python 3.13 not found at $PYTHON"; exit 1; }
mkdir -p "$CODEX_HOME/bin"
"$PYTHON" -m venv "$VENV"
"$VENV/bin/python" -m pip install --upgrade pip >/dev/null
"$VENV/bin/python" -m pip install -e "$PROJECT_ROOT/integrations/vphone-mcp" >/dev/null

cat > "$WRAPPER" <<EOF
#!/bin/zsh
set -euo pipefail
REPO="\${VPHONE_REPO:-$PROJECT_ROOT}"
exec "\$REPO/.mcp-venv/bin/vphone-mcp" "\$@"
EOF
chmod 755 "$WRAPPER"

[[ -f "$CONFIG" ]] || touch "$CONFIG"
python3 - "$CONFIG" "$PROJECT_ROOT" "$WRAPPER" <<'PY'
from pathlib import Path
import sys, tomllib

config = Path(sys.argv[1])
repo = Path(sys.argv[2]).resolve()
wrapper = Path(sys.argv[3]).resolve()
text = config.read_text()
data = tomllib.loads(text or "")
if "vphone" not in data.get("mcp_servers", {}):
    binary = repo / ".build/vphone-cli.app/Contents/MacOS/vphone-cli"
    block = f'''\n\n[mcp_servers.vphone]\ncommand = "{wrapper}"\ncwd = "{repo}"\nrequired = false\nstartup_timeout_sec = 30.0\ntool_timeout_sec = 5400.0\ndefault_tools_approval_mode = "approve"\n\n[mcp_servers.vphone.env]\nVPHONE_REPO = "{repo}"\nVPHONE_BIN = "{binary}"\nVPHONE_DEFAULT_VM = "codex-semantic"\n\n[mcp_servers.vphone.tools.accessibility_tree]\noutput_token_limit = 12000\n\n[mcp_servers.vphone.tools.keychain_list]\noutput_token_limit = 8000\n\n[mcp_servers.vphone.tools.guest_request]\noutput_token_limit = 8000\n'''
    text = text.rstrip() + block + "\n"
    tomllib.loads(text)
    config.write_text(text)
else:
    print("vphone MCP already configured; preserving existing entry")
PY
chmod 600 "$CONFIG"

echo "Installed vphone MCP: $WRAPPER"
echo "Repository: $PROJECT_ROOT"
echo "Codex config: $CONFIG"
