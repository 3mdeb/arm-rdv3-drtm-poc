#!/usr/bin/env bash
# Download Debian's prebuilt trixie-backports kernel (7.2.x) for arm64 with the
# packages it needs that trixie does not have, and copy them into the Debian
# raw disk image next to the PoC guest scripts. No kernel build.
#
# The guest has no network on the FVP by default (it needs a TAP bridge), so
# the packages are fetched on the host and written into the image.
#
# In the guest:  /root/drtm-poc/install-kernel-deb.sh /root/drtm-poc/bpo
# then reboot -f. That boots the new kernel once; the next reboot (or killing
# the FVP) goes back to the Debian kernel.
#
# Needs: curl, python3, xz, sfdisk, debugfs (e2fsprogs). No root, no docker.
#
# Usage: fetch-backports-kernel.sh <debian.raw> [work-dir]   (default ./bpo-kernel)
# Env:
#   SUITE=<suite>   default trixie-backports
set -euo pipefail

POC=$(cd "$(dirname "$0")/.." && pwd)
IMG=$(realpath "${1:?usage: fetch-backports-kernel.sh <debian.raw> [work-dir]}")
WORK=$(realpath -m "${2:-bpo-kernel}")
SUITE=${SUITE:-trixie-backports}
MIRROR=https://deb.debian.org/debian
export PATH=$PATH:/sbin:/usr/sbin

step() { printf '\n=== %s\n' "$*"; }
mkdir -p "$WORK/debs"

step "1. $SUITE package index"
for a in arm64 all; do
	curl -fsSL "$MIRROR/dists/$SUITE/main/binary-$a/Packages.xz" | xz -d > "$WORK/Packages.$a"
done

step "2. Resolve the kernel packages"
# Start from the linux-image-arm64 meta package and follow the linux-*
# dependencies that come from $SUITE (the rest is in trixie already)
python3 - "$WORK" > "$WORK/debs.list" <<'PY'
import re, sys
work = sys.argv[1]
pkgs = {}
for a in ("arm64", "all"):
    for block in open(f"{work}/Packages.{a}").read().split("\n\n"):
        f = dict(re.findall(r"^([\w-]+): (.*)$", block, re.M))
        if "Package" in f:
            pkgs.setdefault(f["Package"], f)
todo, seen = ["linux-image-arm64"], []
while todo:
    p = todo.pop()
    if p in seen or p not in pkgs:
        continue
    seen.append(p)
    for field in ("Pre-Depends", "Depends"):
        for alt in pkgs[p].get(field, "").split(","):
            name = alt.split("|")[0].split("(")[0].strip()
            if name.startswith("linux-"):
                todo.append(name)
# Not the meta packages themselves: they would make 7.2 the kernel that
# apt keeps up to date, and the guest has no network anyway
for p in seen:
    if p in ("linux-image-arm64", "linux-base-arm64"):
        continue
    f = pkgs[p]
    print(f["Filename"], f["SHA256"], f["Version"])
PY
cat "$WORK/debs.list"
KREL=$(sed -n 's|.*/linux-image-\([0-9][^_]*\)_.*|\1|p' "$WORK/debs.list" | grep -v '^arm64' | head -1)
[ -n "$KREL" ] || { echo "no linux-image-<release> in the list" >&2; exit 1; }

step "3. Download linux $KREL"
rm -f "$WORK"/debs/*.deb
while read -r fn sha ver; do
	f=$WORK/debs/$(basename "$fn")
	curl -fsSL -o "$f" "$MIRROR/$fn"
	echo "$sha  $f" | sha256sum -c --quiet -
	ls -l "$f"
done < "$WORK/debs.list"

step "4. Inject into $IMG"
if command -v fuser >/dev/null && fuser "$IMG" >/dev/null 2>&1; then
	echo "$IMG is in use, stop the FVP first" >&2
	exit 1
fi
# shellcheck source=lib-rootfs.sh
. "$POC/scripts/lib-rootfs.sh"
rootfs_open "$IMG"
dfs() { debugfs -R "$1" "$ROOTFS" 2>/dev/null; }
FREE=$(dfs stats | awk -F: '/^Free blocks/ { f = $2 } /^Block size/ { b = $2 } END { print int(f * b) }')
NEED=$(( $(du -cb "$WORK"/debs/*.deb | tail -1 | cut -f1) * 5 ))
if [ "$FREE" -lt "$NEED" ]; then
	echo "root file system has $((FREE >> 20)) MB free, about $((NEED >> 20)) MB needed" >&2
	exit 1
fi
CMDS=$WORK/inject.debugfs
{
	add() {	# add <host-file> <image-path> <mode>
		echo "rm $2"
		echo "write $1 $2"
		echo "sif $2 mode 0100$3"
		echo "sif $2 uid 0"
		echo "sif $2 gid 0"
	}
	echo "mkdir /root/drtm-poc"
	echo "sif /root/drtm-poc mode 040755"
	# Fresh directory: no packages of an earlier run
	for old in $(dfs "ls /root/drtm-poc/bpo" | tr -s ' \t' '\n' | grep '\.deb$'); do
		echo "rm /root/drtm-poc/bpo/$old"
	done
	echo "mkdir /root/drtm-poc/bpo"
	echo "sif /root/drtm-poc/bpo mode 040755"
	for d in "$WORK"/debs/*.deb; do
		add "$d" "/root/drtm-poc/bpo/$(basename "$d")" 644
	done
	for g in "$POC"/guest/*.sh; do
		add "$g" "/root/drtm-poc/$(basename "$g")" 755
	done
} > "$CMDS"
debugfs -w -f "$CMDS" "$ROOTFS" >/dev/null 2>"$WORK/inject.log" || { cat "$WORK/inject.log"; exit 1; }
grep -v 'File not found by ext2_lookup\|while trying to resolve filename\|File exists\|already exists\|^debugfs ' "$WORK/inject.log" || true
rootfs_check
dfs "ls -l /root/drtm-poc/bpo"

cat <<EOF

Done: $IMG
  kernel: $KREL ($SUITE)
  in the guest: /root/drtm-poc/install-kernel-deb.sh /root/drtm-poc/bpo && reboot -f
EOF
