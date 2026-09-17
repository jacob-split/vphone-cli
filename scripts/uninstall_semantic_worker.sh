#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
VM="${1:-codex-semantic}"
LABEL="com.split.vphone.${VM}"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
BIN="$ROOT/.build/vphone-cli.app/Contents/MacOS/vphone-cli"
DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || launchctl bootout "$DOMAIN" "$PLIST" >/dev/null 2>&1 || true
[[ -x "$BIN" ]] && "$BIN" vm stop "$VM" >/dev/null 2>&1 || true
rm -f "$PLIST"
echo "semantic worker removed: $LABEL"
