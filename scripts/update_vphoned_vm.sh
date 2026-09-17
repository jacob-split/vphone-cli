#!/bin/zsh
# Persist the already-signed vphoned cold-boot anchor into a stopped VM.
# Requires local sudo because the raw APFS System volume is mounted by macOS.
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJ="${SCRIPT_DIR:h}"
VM_DIR="${1:-$HOME/.vphone/VMs/codex-semantic}"
BIN="${2:-$PROJ/.build/vphoned.signed}"
IMG="$VM_DIR/Disk.img"
[[ -f "$IMG" ]] || { echo "missing Disk.img: $IMG" >&2; exit 1; }
[[ -f "$BIN" ]] || { echo "missing signed vphoned: $BIN" >&2; exit 1; }
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo -E /bin/zsh "$0" "$VM_DIR" "$BIN"
fi
if lsof "$IMG" >/dev/null 2>&1; then
  echo "VM disk is in use; stop the VM first" >&2
  exit 1
fi
AO=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" 2>/dev/null)
BASEDISK=$(awk 'NR == 1 { print $1; exit }' <<< "$AO")
CONT=$(diskutil info -plist "${BASEDISK}s1" | plutil -extract APFSContainerReference raw -o - - 2>/dev/null)
[[ -n "$CONT" ]] || { hdiutil detach "$BASEDISK"; echo "could not resolve APFS container" >&2; exit 1; }
MNT="/private/tmp/vphonedvm.$$"
mkdir -p "$MNT"
cleanup() { umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; hdiutil detach "$BASEDISK" 2>/dev/null || true; }
trap cleanup EXIT
mount_apfs -o rw "/dev/${CONT}s1" "$MNT"
[[ -f "$MNT/usr/bin/vphoned" ]] || { echo "guest vphoned anchor not found" >&2; exit 1; }
install -o 0 -g 0 -m 0755 "$BIN" "$MNT/usr/bin/vphoned"
cp -f "$BIN" "$VM_DIR/.vphoned.signed"
chown "${SUDO_USER:-root}" "$VM_DIR/.vphoned.signed" 2>/dev/null || true
sync
HASH=$(shasum -a 256 "$MNT/usr/bin/vphoned" | awk '{print $1}')
echo "vphoned cold-boot anchor persisted: $HASH"
cleanup
trap - EXIT
