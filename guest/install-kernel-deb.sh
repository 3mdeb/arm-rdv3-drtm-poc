#!/bin/bash
# Run as root inside the Debian 13 guest. Installs kernel packages (kernel,
# modules, initrd via dpkg) and makes the new kernel the default for the next
# boot only (grub-reboot). The permanent default stays on the kernel that is
# running now, so a reboot after that, or killing the FVP when the new kernel
# hangs, comes back to it.
#
# Takes the packages written by fetch-backports-kernel.sh (a directory) or by
# build-mainline-kernel.sh (one linux-image-*.deb).
#
# Usage: install-kernel-deb.sh [dir | pkg.deb...]
#   default: the newest /root/drtm-poc/linux-image-*.deb
# Env:
#   EARLYCON=1  also add "earlycon" to the kernel command line of all entries
#               (early boot messages on the console, for a kernel that hangs
#               before its console driver is up)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
if [ $# -eq 0 ]; then
	set -- "$(ls -t "$HERE"/linux-image-*.deb | head -1)"
elif [ $# -eq 1 ] && [ -d "$1" ]; then
	set -- "$1"/*.deb
fi
# The kernel release, from the package that ships the kernel image:
# /boot/vmlinuz-<release> (bindeb-pkg) or /usr/lib/modules/<release>/vmlinuz
# (Debian 7.x split packages, linux-binary-<release>)
KREL=
for deb in "$@"; do
	[ -f "$deb" ] || { echo "no such package: $deb" >&2; exit 1; }
	v=$(dpkg-deb -c "$deb" | sed -n -e 's|.* \./boot/vmlinuz-\(.*\)$|\1|p' \
		-e 's|.* \./usr/lib/modules/\([^/]*\)/vmlinuz$|\1|p' | head -1)
	[ -n "$v" ] && KREL=$v
done
[ -n "$KREL" ] || { echo "none of the packages ships a kernel image" >&2; exit 1; }
FALLBACK=$(uname -r)

# Fallback = the entry of the running kernel, saved as the permanent default
if ! grep -q '^GRUB_DEFAULT=saved' /etc/default/grub; then
	sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
	grep -q '^GRUB_DEFAULT=' /etc/default/grub || echo 'GRUB_DEFAULT=saved' >> /etc/default/grub
fi
if [ "${EARLYCON:-0}" = 1 ] && ! grep -q '^GRUB_CMDLINE_LINUX=.*earlycon' /etc/default/grub; then
	sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 earlycon"/' /etc/default/grub
fi

# linux-base first: the kernel image package Pre-Depends on it, so it must be
# configured before that one is unpacked (one dpkg -i only unpacks it first).
# Their postinst creates the initrd and runs update-grub.
first=() rest=()
for deb in "$@"; do
	if [ "$(dpkg-deb -f "$deb" Package)" = linux-base ]; then first+=("$deb"); else rest+=("$deb"); fi
done
[ ${#first[@]} -eq 0 ] || dpkg -i "${first[@]}"
dpkg -i "${rest[@]}"
# GRUB only looks in /boot. If the packages left the image in
# /usr/lib/modules only, put it there and run the kernel hooks (initrd,
# update-grub) by hand.
if [ ! -f "/boot/vmlinuz-$KREL" ] && [ -f "/usr/lib/modules/$KREL/vmlinuz" ]; then
	install -m 0644 "/usr/lib/modules/$KREL/vmlinuz" "/boot/vmlinuz-$KREL"
	[ -f "/usr/lib/modules/$KREL/config" ] && install -m 0644 "/usr/lib/modules/$KREL/config" "/boot/config-$KREL"
	[ -f "/usr/lib/modules/$KREL/System.map" ] && install -m 0644 "/usr/lib/modules/$KREL/System.map" "/boot/System.map-$KREL"
	run-parts --report --exit-on-error --arg="$KREL" --arg="/boot/vmlinuz-$KREL" /etc/kernel/postinst.d
fi
[ -f "/boot/initrd.img-$KREL" ] || update-initramfs -c -k "$KREL"
update-grub

entry_id() {	# entry_id <kernel release>: "<submenu id>><entry id>"
	local sub ent
	sub=$(grep -o "submenu .*[$]menuentry_id_option '[^']*'" /boot/grub/grub.cfg | head -1 | sed "s/.*'\(.*\)'/\1/")
	ent=$(grep -o "[$]menuentry_id_option 'gnulinux-$1-advanced-[^']*'" /boot/grub/grub.cfg | head -1 | sed "s/.*'\(.*\)'/\1/")
	[ -n "$ent" ] || return 1
	echo "${sub:+$sub>}$ent"
}
new=$(entry_id "$KREL") || { echo "no GRUB entry for $KREL" >&2; exit 1; }
old=$(entry_id "$FALLBACK") || { echo "no GRUB entry for $FALLBACK" >&2; exit 1; }
grub-set-default "$old"
grub-reboot "$new"
grub-editenv list
echo "Next boot: $KREL (once), then back to $FALLBACK. Reboot with: reboot -f"
echo "After the reboot check: uname -r"
