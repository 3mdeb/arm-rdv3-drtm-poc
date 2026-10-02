#!/usr/bin/env bash
# Build a Debian 13 nocloud arm64 disk image with a DRTM-capable kernel:
#
#   1. download the Debian 13 nocloud arm64 image (checksum verified)
#   2. extract the installed kernel config and vmlinuz from its root file system
#      and detect the kernel release / Debian source version
#   3. extract the Debian build-time module signing certificate from vmlinuz
#   4. download the matching Debian kernel source package
#   5. apply the patches (default: kernel/drtm-patches) and rebuild the kernel
#      Image in a debian:trixie container (build-debian-kernel.sh)
#   6. check that the exported symbol CRCs match Debian's Module.symvers, so
#      the installed Debian modules and initrd keep working
#   7. inject the kernel (and the guest scripts) into the downloaded image
#   8. preseed the first boot (configure-image.sh): root password, keymap
#      and timezone, so systemd-firstboot does not prompt
#
# Needs: curl, python3, sfdisk, debugfs (e2fsprogs), xz, openssl, docker. No root: the
# image is modified with debugfs -w, no loop device or mount is used.
#
# Usage: build-drtm-debian-image.sh [work-dir]      (default: ./drtm-image)
# Env:
#   IMAGE_VERSION=<YYYYMMDD-NNNN>|latest  cloud image build. The default
#                      20260914-2601 ships 6.12.107+deb13-arm64, the kernel the
#                      PoC patches were made for; newer builds ship newer 6.12.y
#                      kernels on which the patches may need a refresh.
#   IMAGE=<file.raw>   use this raw image instead of downloading one (it is
#                      modified in place)
#   PATCHES=<dir>      patch directory (default: <poc>/kernel/drtm-patches),
#                      PATCHES= (empty) for a plain rebuild
#   EXTRA_CONFIG="..." options on top of the Debian config (default: DRTM)
#   OUT_SUFFIX=<s>     kernel image suffix (default .drtm)
#   INSTALL=poc|default
#       poc     (default) copy the kernel and guest scripts to /root/drtm-poc;
#               in the guest run
#               /root/drtm-poc/install-rebuilt-kernel.sh \
#                   /root/drtm-poc/vmlinuz-<krel><suffix> drtm
#               which adds a GRUB entry and boots it once
#       default also replace /boot/vmlinuz-<krel>, so the image boots the
#               rebuilt kernel by default; the Debian one is kept as
#               /boot/vmlinuz-<krel>.debian. A Debian kernel package update
#               overwrites it again.
#   JOBS=<n>           build parallelism (default nproc)
#   SKIP_CRC_CHECK=1   skip step 6
#   ROOT_PASSWORD=<pw> root password set in step 8 (default "debian";
#                      ROOT_PASSWORD= leaves it locked, systemd-firstboot
#                      then asks for it on the first boot)
#   KEYMAP, TIMEZONE   see configure-image.sh (default us, Etc/UTC)
set -euo pipefail

POC=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(realpath -m "${1:-drtm-image}")
IMAGE_VERSION=${IMAGE_VERSION:-20260914-2601}
PATCHES=${PATCHES-$POC/kernel/drtm-patches}
EXTRA_CONFIG=${EXTRA_CONFIG-ARM64_DRTM=y EFI_STUB_DRTM_DEFAULT_OFF=n EFI_STUB_DRTM_DEFAULT_AUTO=y}
OUT_SUFFIX=${OUT_SUFFIX-.drtm}
INSTALL=${INSTALL:-poc}
KDIR=$WORK/debian-kernel

case "$INSTALL" in poc|default) ;; *) echo "INSTALL must be poc or default" >&2; exit 1 ;; esac
for t in curl python3 sfdisk debugfs xz openssl docker; do
	command -v "$t" >/dev/null || PATH=$PATH:/sbin:/usr/sbin command -v "$t" >/dev/null ||
		{ echo "missing tool: $t" >&2; exit 1; }
done
export PATH=$PATH:/sbin:/usr/sbin
mkdir -p "$WORK" "$KDIR"

step() { printf '\n=== %s\n' "$*"; }

# Download a Debian package file: current archive, security archive, then
# snapshot.debian.org (old versions are removed from the archives).
# fetch_deb <file> <source|binary> <package> <version> <dest-dir>
fetch_deb() {
	local f=$1 kind=$2 pkg=$3 ver=$4 dst=$5 url
	[ -s "$dst/$f" ] && return 0
	for url in https://deb.debian.org/debian/pool/main/l/linux/$f \
		   https://security.debian.org/debian-security/pool/updates/main/l/linux/$f; do
		curl -fsSL -o "$dst/$f.part" "$url" && mv "$dst/$f.part" "$dst/$f" && return 0
	done
	local api
	if [ "$kind" = source ]; then
		api="https://snapshot.debian.org/mr/package/$pkg/$ver/srcfiles?fileinfo=1"
	else
		api="https://snapshot.debian.org/mr/binary/$pkg/$ver/binfiles?fileinfo=1"
	fi
	local hash
	hash=$(curl -fsSL "$api" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for h, infos in d["fileinfo"].items():
    if any(i["name"] == sys.argv[1] for i in infos):
        print(h); break
' "$f")
	[ -n "$hash" ] || { echo "cannot find $f" >&2; return 1; }
	curl -fsSL -o "$dst/$f.part" "https://snapshot.debian.org/file/$hash" && mv "$dst/$f.part" "$dst/$f"
}

# ---------------------------------------------------------------------------
step "1. Debian 13 nocloud arm64 image ($IMAGE_VERSION)"
if [ -n "${IMAGE:-}" ]; then
	IMG=$(realpath "$IMAGE")
else
	if [ "$IMAGE_VERSION" = latest ]; then
		BASE=https://cloud.debian.org/images/cloud/trixie/latest
		NAME=debian-13-nocloud-arm64
	else
		BASE=https://cloud.debian.org/images/cloud/trixie/$IMAGE_VERSION
		NAME=debian-13-nocloud-arm64-$IMAGE_VERSION
	fi
	IMG=$WORK/$NAME.raw
	if [ ! -f "$IMG" ]; then
		curl -fSL -o "$WORK/$NAME.tar.xz" -C - "$BASE/$NAME.tar.xz"
		curl -fsSL -o "$WORK/SHA512SUMS" "$BASE/SHA512SUMS"
		(cd "$WORK" && grep " $NAME.tar.xz\$" SHA512SUMS | sha512sum -c -)
		# The tarball holds a sparse disk.raw
		tar -C "$WORK" -xSJf "$WORK/$NAME.tar.xz" disk.raw
		mv "$WORK/disk.raw" "$IMG"
		rm -f "$WORK/$NAME.tar.xz"
	fi
fi
if command -v fuser >/dev/null && fuser "$IMG" >/dev/null 2>&1; then
	echo "$IMG is in use, stop the FVP first" >&2
	exit 1
fi
echo "image: $IMG"

# Root file system, journal recovered if the image was not shut down cleanly
# shellcheck source=lib-rootfs.sh
. "$POC/scripts/lib-rootfs.sh"
rootfs_open "$IMG"
dfs() { debugfs -R "$1" "$ROOTFS" 2>/dev/null; }

# ---------------------------------------------------------------------------
step "2. Installed kernel"
KREL=$(dfs "ls /boot" | tr -s ' \t' '\n' | sed -n 's/^config-//p' | sort -V | tail -1)
[ -n "$KREL" ] || { echo "no /boot/config-* in the image" >&2; exit 1; }
DEB_VER=$(dfs "cat /var/lib/dpkg/status" | awk -v p="linux-image-$KREL" \
	'$1 == "Package:" { cur = $2 } cur == p && $1 == "Version:" && v == "" { v = $2 } END { print v }')
[ -n "$DEB_VER" ] || { echo "linux-image-$KREL not found in dpkg status" >&2; exit 1; }
echo "kernel release $KREL, Debian source linux $DEB_VER"
dfs "dump /boot/config-$KREL $KDIR/config-$KREL.debian"
dfs "dump /boot/vmlinuz-$KREL $KDIR/vmlinuz-$KREL.debian"
[ -s "$KDIR/config-$KREL.debian" ] && [ -s "$KDIR/vmlinuz-$KREL.debian" ]
# The Debian arm64 vmlinuz is a plain (uncompressed) Image
[ "$(dd if="$KDIR/vmlinuz-$KREL.debian" bs=1 skip=56 count=4 status=none)" = $'ARM\x64' ] ||
	{ echo "vmlinuz-$KREL is not an arm64 Image (EFI zboot?), not supported" >&2; exit 1; }

# ---------------------------------------------------------------------------
step "3. Debian module signing certificate"
"$POC/scripts/extract-debian-kernel-cert.sh" "$KDIR/vmlinuz-$KREL.debian" "$KDIR/debian-builtin-certs.pem"

# ---------------------------------------------------------------------------
step "4. Debian kernel source linux $DEB_VER"
for f in "linux_$DEB_VER.dsc" "linux_${DEB_VER%-*}.orig.tar.xz" "linux_$DEB_VER.debian.tar.xz"; do
	fetch_deb "$f" source linux "$DEB_VER" "$KDIR"
	ls -l "$KDIR/$f"
done

# ---------------------------------------------------------------------------
step "5. Rebuild ${PATCHES:+with $(ls "$PATCHES"/*.patch | wc -l) patches from $PATCHES}"
SRC=linux-$DEB_VER${OUT_SUFFIX:-.rebuilt}
SRC=$SRC DEB_VER=$DEB_VER KREL=$KREL EXTRA_CONFIG=$EXTRA_CONFIG OUT_SUFFIX=$OUT_SUFFIX JOBS=${JOBS:-} \
	"$POC/scripts/build-debian-kernel.sh" "$KDIR" "$KDIR/config-$KREL.debian" ${PATCHES:+"$PATCHES"}
KIMG=$KDIR/vmlinuz-$KREL$OUT_SUFFIX

# ---------------------------------------------------------------------------
if [ "${SKIP_CRC_CHECK:-0}" != 1 ]; then
	step "6. Symbol CRCs against Debian's Module.symvers"
	HDR=linux-headers-${KREL}_${DEB_VER}_arm64.deb
	fetch_deb "$HDR" binary "linux-headers-$KREL" "$DEB_VER" "$KDIR"
	python3 - "$KDIR/$HDR" "$KREL" "$KDIR/vmlinux$OUT_SUFFIX.symvers" <<'PY'
import io, lzma, sys, tarfile
deb, krel, ours_path = sys.argv[1:]
# .deb = ar archive with data.tar.*
d = open(deb, 'rb').read()
pos, data = 8, None
while pos < len(d):
    name = d[pos:pos + 16].decode().strip().rstrip('/')
    size = int(d[pos + 48:pos + 58])
    if name.startswith('data.tar'):
        data = d[pos + 60:pos + 60 + size]
    pos += 60 + size + (size & 1)
if data[:6] == b'\xfd7zXZ\x00':
    data = lzma.decompress(data)
tar = tarfile.open(fileobj=io.BytesIO(data))
m = tar.extractfile(f'./usr/src/linux-headers-{krel}/Module.symvers').read().decode()
def load(text, only_vmlinux):
    r = {}
    for l in text.splitlines():
        f = l.split('\t')
        if len(f) >= 3 and (not only_vmlinux or f[2] == 'vmlinux'):
            r[f[1]] = f[0]
    return r
deb_syms = load(m, True)
ours = load(open(ours_path).read(), False)
bad = sorted(s for s in deb_syms if s in ours and ours[s] != deb_syms[s])
missing = sorted(set(deb_syms) - set(ours))
print(f"Debian vmlinux exports: {len(deb_syms)}, rebuilt: {len(ours)}, "
      f"CRC mismatches: {len(bad)}, missing: {len(missing)}")
if bad or missing:
    print("mismatch:", bad[:10], "missing:", missing[:10])
    sys.exit("the installed Debian modules would not load with this kernel")
PY
else
	step "6. Symbol CRC check skipped"
fi

# ---------------------------------------------------------------------------
step "7. Inject into $IMG (INSTALL=$INSTALL)"
CMDS=$KDIR/inject.debugfs
{
	echo "mkdir /root/drtm-poc"
	echo "sif /root/drtm-poc mode 040755"
	echo "sif /root/drtm-poc uid 0"
	echo "sif /root/drtm-poc gid 0"
	add() {	# add <host-file> <image-path> <mode>
		echo "rm $2"
		echo "write $1 $2"
		echo "sif $2 mode 0100$3"
		echo "sif $2 uid 0"
		echo "sif $2 gid 0"
	}
	add "$KIMG" "/root/drtm-poc/$(basename "$KIMG")" 644
	for g in "$POC"/guest/*.sh; do
		add "$g" "/root/drtm-poc/$(basename "$g")" 755
	done
	if [ "$INSTALL" = default ]; then
		# Keep the Debian kernel once, even when run again
		if ! dfs "stat /boot/vmlinuz-$KREL.debian" | grep '^Inode:' >/dev/null; then
			add "$KDIR/vmlinuz-$KREL.debian" "/boot/vmlinuz-$KREL.debian" 644
		fi
		add "$KIMG" "/boot/vmlinuz-$KREL" 644
	fi
} > "$CMDS"
# rm of a file that does not exist yet only prints an error
debugfs -w -f "$CMDS" "$ROOTFS" >/dev/null 2>"$KDIR/inject.log" || { cat "$KDIR/inject.log"; exit 1; }
grep -v 'File not found by ext2_lookup\|while trying to resolve filename\|^debugfs ' "$KDIR/inject.log" || true
rootfs_check
dfs "ls -l /root/drtm-poc"
[ "$INSTALL" = default ] && dfs "ls -l /boot" | grep vmlinuz

# ---------------------------------------------------------------------------
step "8. First boot configuration"
"$POC/scripts/configure-image.sh" "$IMG"

cat <<EOF

Done: $IMG
  kernel: $KREL ($(cat "$KDIR/linux-version$OUT_SUFFIX.txt"))
EOF
[ -n "${ROOT_PASSWORD-debian}" ] && echo "  login: root / ${ROOT_PASSWORD-debian}"
if [ "$INSTALL" = poc ]; then
	echo "  in the guest: /root/drtm-poc/install-rebuilt-kernel.sh /root/drtm-poc/$(basename "$KIMG") ${OUT_SUFFIX#.}"
else
	echo "  the image boots the rebuilt kernel by default (Debian kernel: /boot/vmlinuz-$KREL.debian)"
fi
