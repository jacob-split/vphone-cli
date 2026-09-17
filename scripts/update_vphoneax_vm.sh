#!/bin/zsh
# Persist a signed VPhoneAX dylib directly into an offline JB VM's Preboot volume.
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJ="${SCRIPT_DIR:h}"
VM_DIR="${1:-$HOME/.vphone/VMs/codex-semantic}"
BROKER="${2:-$PROJ/scripts/vphoneax/VPhoneAX.dylib}"
IMG="$VM_DIR/Disk.img"
PLIST="$PROJ/scripts/vphoneax/VPhoneAX.plist"
CERT="$PROJ/scripts/vphoned/signcert.p12"
LDID="$PROJ/.build/vphone-cli.app/Contents/MacOS/ldid"
[[ -x "$LDID" ]] || LDID="/opt/homebrew/bin/ldid"

[[ -f "$IMG" ]] || { echo "missing Disk.img: $IMG" >&2; exit 1; }
[[ -f "$BROKER" ]] || { echo "missing broker: $BROKER" >&2; exit 1; }
[[ -f "$PLIST" ]] || { echo "missing filter plist: $PLIST" >&2; exit 1; }
[[ -f "$CERT" ]] || { echo "missing signing certificate: $CERT" >&2; exit 1; }
[[ -x "$LDID" ]] || { echo "missing ldid: $LDID" >&2; exit 1; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo -E /bin/zsh "$0" "$VM_DIR" "$BROKER"
fi
if lsof "$IMG" >/dev/null 2>&1; then
  echo "VM disk is in use; stop the VM first" >&2
  exit 1
fi

AO=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" 2>/dev/null)
BASEDISK=$(awk 'NR == 1 { print $1; exit }' <<< "$AO")
CONT=$(diskutil info -plist "${BASEDISK}s1" | plutil -extract APFSContainerReference raw -o - - 2>/dev/null)
[[ -n "$CONT" ]] || { echo "could not resolve APFS container" >&2; hdiutil detach "$BASEDISK"; exit 1; }

MNT="/private/tmp/vphoneaxvm.$$"
SIGNED="/private/tmp/VPhoneAX.signed.$$.$RANDOM.dylib"
cp "$BROKER" "$SIGNED"
"$LDID" -S -M "-K$CERT" "$SIGNED"
mkdir -p "$MNT"
cleanup() {
  rm -f "$SIGNED" 2>/dev/null || true
  umount "$MNT" 2>/dev/null || true
  rmdir "$MNT" 2>/dev/null || true
  hdiutil detach "$BASEDISK" 2>/dev/null || diskutil eject "$BASEDISK" 2>/dev/null || true
}
trap cleanup EXIT

PREBOOT="/dev/${CONT}s5"
mount_apfs -o rw "$PREBOOT" "$MNT"
BOOT_HASH=$(find "$MNT" -maxdepth 1 -mindepth 1 -type d -print | awk -F/ 'length($NF)==96 {print $NF; exit}')
[[ -n "$BOOT_HASH" ]] || { echo "boot manifest hash not found on Preboot" >&2; exit 1; }

DEST="$MNT/$BOOT_HASH/jb-vphone/procursus/Library/MobileSubstrate/DynamicLibraries"
[[ -d "$DEST" ]] || { echo "VPhone tweak directory not found: $DEST" >&2; exit 1; }

install -o 0 -g 0 -m 0755 "$SIGNED" "$DEST/VPhoneAX.dylib"
install -o 0 -g 0 -m 0644 "$PLIST" "$DEST/VPhoneAX.plist"
sync

HASH=$(shasum -a 256 "$DEST/VPhoneAX.dylib" | awk '{print $1}')
echo "VPhoneAX persisted: $DEST/VPhoneAX.dylib"
echo "sha256=$HASH"
cleanup
trap - EXIT
