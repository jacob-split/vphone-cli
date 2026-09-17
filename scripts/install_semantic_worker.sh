#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VM="${1:-codex-semantic}"
LABEL="com.split.vphone.${VM}"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
BIN="$ROOT/.build/vphone-cli.app/Contents/MacOS/vphone-cli"
LOG_DIR="$HOME/.vphone/logs"
LOG="$LOG_DIR/${VM}-worker.log"
DOMAIN="gui/$(id -u)"

[[ -x "$BIN" ]] || { echo "missing signed vphone binary: $BIN" >&2; exit 1; }
"$BIN" vm info "$VM" >/dev/null
mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"

# Replace any existing registration, then stop an ad-hoc copy so the LaunchAgent
# becomes the single owner of the worker VM.
launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
"$BIN" vm stop "$VM" >/dev/null 2>&1 || true

# `vm launch` hands execution to an inner `--config ...` process. If a prior
# launcher is killed during a restart that inner process can become orphaned
# under launchd and keep owning vphone.sock. Explicitly terminate every process
# bound to this VM config before registering the new single owner.
VM_DIR="$HOME/.vphone/VMs/$VM"
VM_CONFIG="$VM_DIR/config.plist"
VARIANT=$(/usr/bin/python3 - "$VM_DIR/restore-info.json" <<'PYVAR'
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(json.load(f).get("variant") or "jb")
except Exception:
    print("jb")
PYVAR
)
# Keep the VM-local daemon staging file synchronized with the signed runtime
# bundled beside the worker binary. Direct worker launch intentionally skips
# the `vm launch` wrapper/preflight process.
if [[ -f "$ROOT/.build/vphoned.signed" ]]; then
  cp -f "$ROOT/.build/vphoned.signed" "$VM_DIR/.vphoned.signed"
fi
for pid in $(pgrep -f "$VM_CONFIG" 2>/dev/null || true); do
  kill -TERM "$pid" 2>/dev/null || true
done
for _ in {1..40}; do
  pgrep -f "$VM_CONFIG" >/dev/null || break
  sleep 0.25
done
for pid in $(pgrep -f "$VM_CONFIG" 2>/dev/null || true); do
  kill -KILL "$pid" 2>/dev/null || true
done
for _ in {1..20}; do
  pgrep -f "$VM_CONFIG" >/dev/null || break
  sleep 0.1
done

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$BIN</string>
    <string>--config</string><string>$VM_CONFIG</string>
    <string>--headless</string>
    <string>--variant</string><string>$VARIANT</string>
  </array>
  <key>WorkingDirectory</key><string>$VM_DIR</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PLIST
chmod 644 "$PLIST"
plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl enable "$DOMAIN/$LABEL"
launchctl kickstart -k "$DOMAIN/$LABEL"

echo "semantic worker installed: $LABEL"
echo "vm: $VM"
echo "log: $LOG"
