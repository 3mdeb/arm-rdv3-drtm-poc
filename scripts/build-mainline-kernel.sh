#!/usr/bin/env bash
# Build a mainline (kernel.org) kernel as a Debian package, with the
# configuration of the Debian kernel installed in the image, and copy it into
# the Debian raw disk image next to the PoC guest scripts:
#
#   1. download linux-$KVER.tar.xz from cdn.kernel.org (sha256 verified)
#   2. take the Debian kernel config from the image (/boot/config-*)
#   3. build linux-image-<krel>_<ver>_arm64.deb (kernel + modules) in a
#      debian:trixie container: Debian config + olddefconfig, debug info off,
#      modules signed with a key generated at build time
#   4. write the .deb and guest/*.sh to /root/drtm-poc in the image
#
# Unlike build-debian-kernel.sh, the kernel brings its own modules (a 7.x
# kernel cannot load the installed 6.12 modules), so it is a package and the
# guest installs it with dpkg, which also creates its initrd.
#
# In the guest:  /root/drtm-poc/install-kernel-deb.sh
# then reboot. That boots the new kernel once; the next reboot (or killing the
# FVP) goes back to the Debian kernel.
#
# Needs: curl, python3, sfdisk, debugfs (e2fsprogs), docker. No root.
# Build on the host, in a work directory on a local file system (not a
# virtiofs/9p share).
#
# Usage: build-mainline-kernel.sh <debian.raw> [work-dir]   (default ./mainline-kernel)
#
# On a separate build machine (no image needed there):
#   builder:  CONFIG=config.debian NO_INJECT=1 build-mainline-kernel.sh - <work-dir>
#   laptop:   DEB=linux-image-<krel>_*.deb build-mainline-kernel.sh <debian.raw>
# Env:
#   KVER=<x.y.z>       kernel.org release (default 7.2.11)
#   PATCHES=<dir>      *.patch applied with patch -p1 on top (default: none,
#                      plain mainline)
#   EXTRA_CONFIG="A=y B=n C=m D=val"  options on top of the Debian config
#   LOCALVERSION=<s>   appended to the release (default -poc); the release is
#                      then e.g. 7.2.11-poc
#   CONFIG=<file>      use this config instead of the one in the image
#   JOBS=<n>           build parallelism (default nproc)
#   NO_INJECT=1        only build, leave the image alone; with CONFIG= the
#                      image argument can be "-"
#   DEB=<file.deb>     skip the build, only inject this package
set -euo pipefail

POC=$(cd "$(dirname "$0")/.." && pwd)
IMG=${1:?usage: build-mainline-kernel.sh <debian.raw>|- [work-dir]}
[ "$IMG" = - ] || IMG=$(realpath "$IMG")
WORK=$(realpath -m "${2:-mainline-kernel}")
KVER=${KVER:-7.2.11}
PATCHES=${PATCHES:+$(realpath "$PATCHES")}
LOCALVERSION=${LOCALVERSION--poc}
KREL=$KVER$LOCALVERSION

tools="curl docker"
[ -n "${DEB:-}" ] && tools=
[ "$IMG" = - ] || tools="$tools python3 sfdisk debugfs"
for t in $tools; do
	command -v "$t" >/dev/null || PATH=$PATH:/sbin:/usr/sbin command -v "$t" >/dev/null ||
		{ echo "missing tool: $t" >&2; exit 1; }
done
export PATH=$PATH:/sbin:/usr/sbin
mkdir -p "$WORK"

step() { printf '\n=== %s\n' "$*"; }

if [ "$IMG" = - ]; then
	[ "${NO_INJECT:-0}" = 1 ] && [ -n "${CONFIG:-}" ] ||
		{ echo "without an image, set CONFIG= and NO_INJECT=1" >&2; exit 1; }
else
	if command -v fuser >/dev/null && fuser "$IMG" >/dev/null 2>&1; then
		echo "$IMG is in use, stop the FVP first" >&2
		exit 1
	fi
	# shellcheck source=lib-rootfs.sh
	. "$POC/scripts/lib-rootfs.sh"
	rootfs_open "$IMG"
fi
dfs() { debugfs -R "$1" "$ROOTFS" 2>/dev/null; }

if [ -n "${DEB:-}" ]; then
	DEB=$(realpath "$DEB")
	[ "$IMG" != - ] || { echo "DEB= needs the image" >&2; exit 1; }
else

# ---------------------------------------------------------------------------
step "1. linux-$KVER from kernel.org"
TARBALL=linux-$KVER.tar.xz
BASE=https://cdn.kernel.org/pub/linux/kernel/v${KVER%%.*}.x
if [ ! -s "$WORK/$TARBALL" ]; then
	curl -fSL -o "$WORK/$TARBALL.part" "$BASE/$TARBALL"
	mv "$WORK/$TARBALL.part" "$WORK/$TARBALL"
fi
curl -fsSL "$BASE/sha256sums.asc" | grep " $TARBALL\$" > "$WORK/$TARBALL.sha256"
[ -s "$WORK/$TARBALL.sha256" ] || { echo "$TARBALL not in sha256sums.asc" >&2; exit 1; }
(cd "$WORK" && sha256sum -c "$TARBALL.sha256")

# ---------------------------------------------------------------------------
step "2. Debian kernel config"
if [ -n "${CONFIG:-}" ]; then
	cp "$CONFIG" "$WORK/config.debian"
else
	# The Debian kernel: /boot/config-* without a suffix of ours
	DEBKREL=$(dfs "ls /boot" | tr -s ' \t' '\n' | sed -n 's/^config-//p' | grep 'deb[0-9]*-arm64$' | sort -V | tail -1)
	[ -n "$DEBKREL" ] || { echo "no Debian /boot/config-* in the image, set CONFIG=" >&2; exit 1; }
	rm -f "$WORK/config.debian"
	rm -f "$WORK/config.debian"
	dfs "dump /boot/config-$DEBKREL $WORK/config.debian"
	echo "config of $DEBKREL"
fi
[ -s "$WORK/config.debian" ]

# ---------------------------------------------------------------------------
step "3. Build linux-image-$KREL${PATCHES:+ with $(ls "$PATCHES"/*.patch | wc -l) patches from $PATCHES}"
rm -f "$WORK"/linux-image-"$KREL"_*.deb
docker run --rm -v "$WORK:/work" ${PATCHES:+-v "$PATCHES:/patches:ro"} \
	-e KVER="$KVER" -e LOCALVERSION="$LOCALVERSION" -e HOST_UID="$(id -u)" \
	-e EXTRA_CONFIG="${EXTRA_CONFIG:-}" -e JOBS="${JOBS:-$(nproc)}" \
	debian:trixie bash -euxc '
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y -qq --no-install-recommends crossbuild-essential-arm64 gcc libc6-dev make \
		gcc-arm-linux-gnueabihf bc bison flex libssl-dev libelf-dev dwarves python3 rsync \
		kmod cpio dpkg-dev debhelper xz-utils ca-certificates >/dev/null

	cd /work
	SRC=linux-$KVER${LOCALVERSION}
	if [ ! -d $SRC ]; then
		rm -rf linux-$KVER
		tar -xf linux-$KVER.tar.xz
		mv linux-$KVER $SRC
	fi
	cd $SRC
	if [ -d /patches ] && [ ! -f .extra-patches-applied ]; then
		for p in /patches/*.patch; do patch -p1 < "$p"; done
		touch .extra-patches-applied
	fi

	cp /work/config.debian .config
	# No Debian keys: modules are signed with a key generated by this build.
	# No debug info: a much faster build and no 1 GB -dbg package.
	./scripts/config --set-str SYSTEM_TRUSTED_KEYS "" \
		--set-str SYSTEM_REVOCATION_KEYS "" \
		--set-str MODULE_SIG_KEY certs/signing_key.pem \
		--set-str BUILD_SALT "" \
		--set-str LOCALVERSION "" \
		--disable LOCALVERSION_AUTO \
		--disable DEBUG_INFO --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
		--disable DEBUG_INFO_DWARF4 --disable DEBUG_INFO_DWARF5 \
		--disable DEBUG_INFO_BTF --disable DEBUG_INFO_BTF_MODULES \
		--enable DEBUG_INFO_NONE
	for opt in $EXTRA_CONFIG; do
		case "${opt#*=}" in
		y) ./scripts/config --enable "${opt%%=*}" ;;
		n) ./scripts/config --disable "${opt%%=*}" ;;
		m) ./scripts/config --module "${opt%%=*}" ;;
		*) ./scripts/config --set-val "${opt%%=*}" "${opt#*=}" ;;
		esac
	done
	M="make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_COMPAT=arm-linux-gnueabihf- LOCALVERSION=$LOCALVERSION"
	$M olddefconfig
	./scripts/diffconfig /work/config.debian .config > /work/config-$KVER$LOCALVERSION.diff || true

	# DPKG_FLAGS=-d: build dependencies are installed above for a cross
	# build, dpkg-buildpackage would look for arm64 ones
	# DEB_BUILD_OPTIONS: debian/rules re-runs make under dpkg-buildpackage,
	# make sure that inner make is parallel too
	DEB_BUILD_OPTIONS=parallel=$JOBS $M -j$JOBS KDEB_PKGVERSION=$KVER-1 DPKG_FLAGS=-d bindeb-pkg
	cp .config /work/config-$KVER$LOCALVERSION
	chown -R $HOST_UID:$HOST_UID /work
'
DEB=$(ls "$WORK"/linux-image-"$KREL"_*_arm64.deb)
fi
ls -l "$DEB"

# ---------------------------------------------------------------------------
if [ "${NO_INJECT:-0}" = 1 ]; then
	step "4. Not injected (NO_INJECT=1)"
	exit 0
fi
step "4. Inject into $IMG"
# Installed size is about 4x the .deb (modules, initrd, dpkg's copy)
FREE=$(dfs stats | awk -F: '/^Free blocks/ { f = $2 } /^Block size/ { b = $2 } END { print int(f * b) }')
NEED=$(( $(stat -c %s "$DEB") * 5 ))
if [ "$FREE" -lt "$NEED" ]; then
	echo "root file system has $((FREE >> 20)) MB free, about $((NEED >> 20)) MB needed" \
	     "to install the kernel. Grow the image first." >&2
	exit 1
fi
CMDS=$WORK/inject.debugfs
{
	echo "mkdir /root/drtm-poc"
	echo "sif /root/drtm-poc mode 040755"
	add() {	# add <host-file> <image-path> <mode>
		echo "rm $2"
		echo "write $1 $2"
		echo "sif $2 mode 0100$3"
		echo "sif $2 uid 0"
		echo "sif $2 gid 0"
	}
	add "$DEB" "/root/drtm-poc/$(basename "$DEB")" 644
	for g in "$POC"/guest/*.sh; do
		add "$g" "/root/drtm-poc/$(basename "$g")" 755
	done
} > "$CMDS"
# mkdir/rm of what does (not) exist yet only print errors
debugfs -w -f "$CMDS" "$ROOTFS" >/dev/null 2>"$WORK/inject.log" || { cat "$WORK/inject.log"; exit 1; }
grep -v 'File not found by ext2_lookup\|while trying to resolve filename\|File exists\|already exists\|^debugfs ' "$WORK/inject.log" || true
rootfs_check
dfs "ls -l /root/drtm-poc"

cat <<EOF

Done: $IMG
  package: $(basename "$DEB")  (release $KREL)
  in the guest: /root/drtm-poc/install-kernel-deb.sh && reboot -f
EOF
