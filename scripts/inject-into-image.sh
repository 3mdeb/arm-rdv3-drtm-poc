#!/bin/bash
# Copy the PoC guest files (rebuilt Debian kernel images, scripts) into
# /root/drtm-poc of the Debian raw disk image. The FVP must not be running.
#
# Usage: sudo inject-into-image.sh <debian.raw> [kernel-dir]
#   kernel-dir: holds vmlinuz-6.12.107+deb13-arm64[.suffix] (default: kernel/)
set -euo pipefail

IMG=$(realpath "$1")
POC=$(cd "$(dirname "$0")/.." && pwd)
KDIR=${2:-$POC/kernel}

if fuser "$IMG" >/dev/null 2>&1; then
	echo "$IMG is in use, stop the FVP first" >&2
	exit 1
fi

KIMG=$(ls "$KDIR"/vmlinuz-6.12.107+deb13-arm64 "$KDIR"/vmlinuz-6.12.107+deb13-arm64.* 2>/dev/null || true)
echo "Kernel images: ${KIMG:-none}"

LOOP=$(losetup -P --show -f "$IMG")
MNT=$(mktemp -d)
trap 'umount "$MNT" 2>/dev/null; rmdir "$MNT"; losetup -d "$LOOP"' EXIT

# Debian cloud images: partition 1 is the root file system
mount "${LOOP}p1" "$MNT"
install -d -m 0755 "$MNT"/root/drtm-poc
[ -n "$KIMG" ] && install -m 0644 $KIMG "$MNT"/root/drtm-poc/
install -m 0755 "$POC"/guest/*.sh "$MNT"/root/drtm-poc/
ls -l "$MNT"/root/drtm-poc
sync
echo "Done. In the guest run: /root/drtm-poc/install-rebuilt-kernel.sh <image> <suffix>"
