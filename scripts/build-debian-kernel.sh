#!/usr/bin/env bash
# Rebuild the Debian 13 (trixie) arm64 kernel image from the Debian source
# package, with the configuration of the installed kernel, so that the
# installed Debian modules (/lib/modules/6.12.107+deb13-arm64) keep loading.
#
# Runs the build in a debian:trixie container with Debian's cross toolchain.
#
# Usage: build-debian-kernel.sh <work-dir> <debian-kernel-config> [patch-dir]
#   patch-dir: optional directory with *.patch applied on top (e.g. DRTM)
# Env:
#   SRC=<dir>          source tree in <work-dir> (default linux-src, created
#                      from the Debian source package if missing)
#   EXTRA_CONFIG="A=y B=n"  options set on top of the Debian config
#   OUT_SUFFIX=<s>     suffix for the output files (default none)
#   DEB_VER=<v>        Debian source version (default 6.12.107-1)
#   KREL=<r>           kernel release, uname -r (default 6.12.107+deb13-arm64)
set -euo pipefail

WORK=$(realpath "$1")
CONFIG=$(realpath "$2")
PATCHES=${3:+$(realpath "$3")}
DEB_VER=${DEB_VER:-6.12.107-1}
KREL=${KREL:-6.12.107+deb13-arm64}

mkdir -p "$WORK"
cp "$CONFIG" "$WORK/config-$KREL"
# Optional: $WORK/debian-builtin-certs.pem, see extract-debian-kernel-cert.sh

docker run --rm -v "$WORK:/work" ${PATCHES:+-v "$PATCHES:/patches:ro"} \
	-e DEB_VER="$DEB_VER" -e KREL="$KREL" -e HOST_UID="$(id -u)" \
	-e SRC="${SRC:-linux-src}" -e EXTRA_CONFIG="${EXTRA_CONFIG:-}" \
	-e OUT="${OUT_SUFFIX:-}" \
	-e JOBS="${JOBS:-$(nproc)}" debian:trixie bash -euxc '
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y -qq --no-install-recommends crossbuild-essential-arm64 gcc libc6-dev make gcc-arm-linux-gnueabihf \
		gcc-14-aarch64-linux-gnu bc bison flex libssl-dev libelf-dev \
		dwarves python3 rsync kmod cpio dpkg-dev quilt xz-utils curl \
		ca-certificates >/dev/null

	cd /work
	if [ ! -d $SRC ]; then
		for f in linux_${DEB_VER}.dsc linux_${DEB_VER%-*}.orig.tar.xz \
			 linux_${DEB_VER}.debian.tar.xz; do
			[ -f $f ] || curl -fsSLO https://deb.debian.org/debian/pool/main/l/linux/$f
		done
		dpkg-source -x linux_${DEB_VER}.dsc $SRC
	fi
	cd $SRC

	if [ -d /patches ] && [ ! -f .extra-patches-applied ]; then
		for p in /patches/*.patch; do patch -p1 < "$p"; done
		touch .extra-patches-applied
	fi

	cp /work/config-$KREL .config
	# Trust the build-time key that signed the installed Debian modules
	# (extracted from the Debian vmlinuz), so their signatures verify
	if [ -f /work/debian-builtin-certs.pem ]; then
		./scripts/config --set-str SYSTEM_TRUSTED_KEYS /work/debian-builtin-certs.pem
	fi
	for opt in $EXTRA_CONFIG; do
		case "${opt#*=}" in
		y) ./scripts/config --enable "${opt%%=*}" ;;
		n) ./scripts/config --disable "${opt%%=*}" ;;
		m) ./scripts/config --module "${opt%%=*}" ;;
		*) ./scripts/config --set-val "${opt%%=*}" "${opt#*=}" ;;
		esac
	done
	make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=aarch64-linux-gnu-gcc-14 \
		CROSS_COMPILE_COMPAT=arm-linux-gnueabihf- olddefconfig
	./scripts/diffconfig /work/config-$KREL .config > /work/config$OUT.diff || true

	make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=aarch64-linux-gnu-gcc-14 \
		CROSS_COMPILE_COMPAT=arm-linux-gnueabihf- KERNELRELEASE=$KREL KBUILD_BUILD_USER=debian-kernel \
		KBUILD_BUILD_HOST=lists.debian.org \
		KBUILD_BUILD_VERSION="1 SMP Debian $DEB_VER" -j$JOBS Image
	cp arch/arm64/boot/Image /work/vmlinuz-$KREL$OUT
	cp vmlinux.symvers /work/vmlinux$OUT.symvers
	cp .config /work/config$OUT
	strings arch/arm64/boot/Image | grep -m1 "^Linux version" > /work/linux-version$OUT.txt
	chown -R $HOST_UID:$HOST_UID /work
'
ls -l "$WORK/vmlinuz-$KREL${OUT_SUFFIX:-}"
cat "$WORK/linux-version${OUT_SUFFIX:-}.txt" "$WORK/config${OUT_SUFFIX:-}.diff"
