#!/bin/bash
# Run as root inside the Debian 13 guest. Installs a kernel image rebuilt from
# the Debian 6.12.107-1 source (same config, same symbol CRCs) next to the
# Debian one and makes it the default for the next boot only (grub-reboot),
# so a plain reboot afterwards falls back to the Debian kernel.
#
# The rebuilt kernel reports the same release (uname -r), so it uses the
# installed modules in /lib/modules/6.12.107+deb13-arm64 and the existing
# initrd.
#
# Usage: install-rebuilt-kernel.sh [image] [suffix]
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
KREL=6.12.107+deb13-arm64
IMAGE=${1:-$HERE/vmlinuz-$KREL}
SUFFIX=${2:-rebuilt}
NAME=$KREL.$SUFFIX

install -m 0644 "$IMAGE" /boot/vmlinuz-$NAME
ln -sf initrd.img-$KREL /boot/initrd.img-$NAME
update-grub

submenu=$(grep -o "submenu .*[$]menuentry_id_option '[^']*'" /boot/grub/grub.cfg | head -1 | sed "s/.*'\(.*\)'/\1/")
entry=$(grep -o "menuentry .*$NAME'.*[$]menuentry_id_option '[^']*'" /boot/grub/grub.cfg | grep -v recovery | head -1 | sed "s/.*'\(.*\)'/\1/")
if [ -z "$entry" ]; then
	echo "Could not find GRUB entry for $NAME" >&2
	exit 1
fi

# One-shot: needs GRUB_DEFAULT=saved
if ! grep -q '^GRUB_DEFAULT=saved' /etc/default/grub; then
	sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
	grep -q '^GRUB_DEFAULT=' /etc/default/grub || echo 'GRUB_DEFAULT=saved' >> /etc/default/grub
	update-grub
	grub-set-default 0
fi
grub-reboot "${submenu:+$submenu>}$entry"
grub-editenv list
echo "Next boot: $NAME. Check with: cat /proc/version; dmesg | grep -i taint"
