#!/usr/bin/env bash
# Preseed the first boot configuration of a Debian cloud (nocloud) raw image,
# so that it boots to a login prompt without manual setup.
#
# The nocloud image ships with a locked root account ("!unprovisioned") and
# runs systemd-firstboot on the first boot, which prompts for the keymap,
# timezone and root password when they are not configured. This script sets
# the root password and, if they are missing, the keymap and timezone, so
# systemd-firstboot has nothing to ask. /etc/machine-id is left alone, so the
# rest of the first boot setup still runs.
#
# No root needed: the image is edited with debugfs -w (an unclean root file
# system is recovered first, see lib-rootfs.sh). The FVP must not be running.
#
# Usage: configure-image.sh <image.raw>
# Env:
#   ROOT_PASSWORD=<pw>  root password (default "debian"; empty: leave it)
#   KEYMAP=<map>        console keymap if none is set (default "us")
#   TIMEZONE=<zone>     timezone if none is set (default "Etc/UTC")
set -euo pipefail

IMG=$(realpath "$1")
ROOT_PASSWORD=${ROOT_PASSWORD-debian}
KEYMAP=${KEYMAP:-us}
TIMEZONE=${TIMEZONE:-Etc/UTC}
export PATH=$PATH:/sbin:/usr/sbin

for t in debugfs sfdisk python3 openssl e2fsck; do
	command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }
done
if command -v fuser >/dev/null && fuser "$IMG" >/dev/null 2>&1; then
	echo "$IMG is in use, stop the FVP first" >&2
	exit 1
fi

# shellcheck source=lib-rootfs.sh
. "$(dirname "$0")/lib-rootfs.sh"
rootfs_open "$IMG"
dfs() { debugfs -R "$1" "$ROOTFS" 2>/dev/null; }
exists() { dfs "stat $1" | grep '^Inode:' >/dev/null; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CMDS=$TMP/cmds

# write_file <host-file> <image-path> <mode> <uid> <gid>
write_file() {
	echo "rm $2"
	echo "write $1 $2"
	echo "sif $2 mode 0100$3"
	echo "sif $2 uid $4"
	echo "sif $2 gid $5"
}

: > "$CMDS"
if [ -n "$ROOT_PASSWORD" ]; then
	dfs "dump /etc/shadow $TMP/shadow"
	[ -s "$TMP/shadow" ] || { echo "cannot read /etc/shadow" >&2; exit 1; }
	gid=$(dfs "stat /etc/shadow" | sed -n 's/.*Group: *\([0-9]*\).*/\1/p')
	hash=$(openssl passwd -6 -stdin <<<"$ROOT_PASSWORD")
	# Field 2 is the password hash, field 3 the last change (days since epoch)
	HASH=$hash python3 - "$TMP/shadow" <<'PY'
import os, sys, time
p = sys.argv[1]
lines = open(p).read().splitlines()
for i, l in enumerate(lines):
    f = l.split(':')
    if f[0] == 'root':
        f[1] = os.environ['HASH']
        f[2] = str(int(time.time() // 86400))
        lines[i] = ':'.join(f)
        break
else:
    sys.exit('no root entry in /etc/shadow')
open(p, 'w').write('\n'.join(lines) + '\n')
PY
	write_file "$TMP/shadow" /etc/shadow 640 0 "${gid:-42}" >> "$CMDS"
	echo "root password: set"
fi
if ! exists /etc/vconsole.conf; then
	echo "KEYMAP=$KEYMAP" > "$TMP/vconsole.conf"
	write_file "$TMP/vconsole.conf" /etc/vconsole.conf 644 0 0 >> "$CMDS"
	echo "keymap: $KEYMAP"
fi
if ! exists /etc/localtime; then
	exists "/usr/share/zoneinfo/$TIMEZONE" ||
		{ echo "no /usr/share/zoneinfo/$TIMEZONE in the image" >&2; exit 1; }
	echo "symlink /etc/localtime /usr/share/zoneinfo/$TIMEZONE" >> "$CMDS"
	echo "$TIMEZONE" > "$TMP/timezone"
	write_file "$TMP/timezone" /etc/timezone 644 0 0 >> "$CMDS"
	echo "timezone: $TIMEZONE"
fi

if [ -s "$CMDS" ]; then
	# rm of a file that does not exist yet only prints an error
	debugfs -w -f "$CMDS" "$ROOTFS" >/dev/null 2>"$TMP/log" || { cat "$TMP/log" >&2; exit 1; }
	rootfs_check
fi
echo "first boot configuration done: $IMG"
