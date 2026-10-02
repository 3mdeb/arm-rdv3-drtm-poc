# Helpers for editing the ext4 root file system of a Debian cloud raw image
# with debugfs, without root. Sourced by build-drtm-debian-image.sh and
# configure-image.sh.
#
# debugfs ignores the ext4 journal. If the image was not shut down cleanly
# (e.g. the FVP was killed), the journal holds changes that the kernel replays
# on the next mount, over the debugfs edits, which corrupts the file system
# ("deleted inode referenced"). rootfs_open therefore recovers the journal
# first. e2fsck cannot recover a journal through debugfs' "?offset=" syntax,
# so the partition is checked in a temporary copy and written back.

# rootfs_open <image>: sets ROOTFS ("<image>?offset=<bytes>"), ROOTFS_IMG,
# ROOTFS_OFFSET and ROOTFS_SIZE, and makes sure the file system is clean
rootfs_open() {
	local img=$1 part
	part=$(sfdisk -J "$img" | python3 -c '
import json, sys
t = json.load(sys.stdin)["partitiontable"]
s = t.get("sectorsize", 512)
p = [p for p in t["partitions"] if p["type"].upper() == "B921B045-1DF0-41C3-AF44-4C6F280D3FAE"]
print(p[0]["start"] * s, p[0]["size"] * s)')
	ROOTFS_IMG=$img
	ROOTFS_OFFSET=${part% *}
	ROOTFS_SIZE=${part#* }
	ROOTFS="$img?offset=$ROOTFS_OFFSET"
	rootfs_recover
}

rootfs_stats() { debugfs -R stats "$ROOTFS" 2>/dev/null; }

rootfs_dirty() {
	local s
	s=$(rootfs_stats)
	grep -q '^Filesystem features:.*needs_recovery' <<<"$s" ||
		! grep -q '^Filesystem state: *clean$' <<<"$s"
}

# Recover the journal and fix what e2fsck -p (preen) can fix safely; abort
# for anything else
rootfs_recover() {
	local tmp rc=0
	rootfs_dirty || return 0
	echo "root file system was not cleanly unmounted: recovering the journal"
	# Next to the image: the partition copy needs up to its full size
	tmp=$(mktemp -d "$(dirname "$ROOTFS_IMG")/.rootfs.XXXXXX")
	dd if="$ROOTFS_IMG" of="$tmp/rootfs.img" bs=4M skip="$ROOTFS_OFFSET" \
	   count="$ROOTFS_SIZE" iflag=skip_bytes,count_bytes,fullblock conv=sparse \
	   status=none
	e2fsck -fp "$tmp/rootfs.img" || rc=$?
	if [ $rc -gt 1 ]; then
		rm -rf "$tmp"
		echo "e2fsck could not repair the root file system (rc $rc), the image" \
		     "was not changed. Run 'e2fsck -f' on it by hand or use a fresh image." >&2
		exit 1
	fi
	# Not sparse: blocks that became zero must be written too
	dd if="$tmp/rootfs.img" of="$ROOTFS_IMG" bs=4M seek="$ROOTFS_OFFSET" \
	   oflag=seek_bytes conv=notrunc status=none
	rm -rf "$tmp"
	if rootfs_dirty; then
		echo "root file system still not clean after e2fsck" >&2
		exit 1
	fi
}

# Check the result of the debugfs edits
rootfs_check() {
	if rootfs_dirty || ! e2fsck -fn "$ROOTFS" >/dev/null 2>&1; then
		echo "e2fsck reports errors on $ROOTFS" >&2
		exit 1
	fi
}
