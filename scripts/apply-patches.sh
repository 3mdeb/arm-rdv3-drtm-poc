#!/usr/bin/env bash
# Apply the DRTM PoC patch series (patches/<repo>/*.patch) to the RD-INFRA
# repositories of a repo checkout:
#
#   patches/tf-a            -> tf-a
#   patches/edk2-platforms  -> uefi/edk2/edk2-platforms
#   patches/build-scripts   -> build-scripts
#
# The series are made with git format-patch on top of RD-INFRA-2025.07.03,
# the revision the RD-V3 manifest pins. Each repository gets a local branch
# (default rdv3-drtm-poc) at its current HEAD and the patches are applied
# with git am. Patches whose subject is already in the branch history are
# skipped, so the script can be run again, e.g. after a repo sync.
#
# Usage: apply-patches.sh [options] [top-dir]
#   top-dir      root of the repo checkout (default: the parent of drtm-poc)
#   -b <branch>  local branch to create (default rdv3-drtm-poc)
#   -n           apply to the working trees only (git apply), no commits
#   -c           check only: apply in a temporary worktree, change nothing
#   -h           help
set -euo pipefail

POC=$(cd "$(dirname "$0")/.." && pwd)
BRANCH=rdv3-drtm-poc
MODE=am

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "$0"; }
while getopts "b:nch" o; do
	case $o in
	b) BRANCH=$OPTARG ;;
	n) MODE=apply ;;
	c) MODE=check ;;
	h) usage; exit 0 ;;
	*) usage >&2; exit 1 ;;
	esac
done
shift $((OPTIND - 1))
TOP=$(realpath "${1:-$POC/..}")

# patch directory : repository path relative to TOP
REPOS=(
	"tf-a:tf-a"
	"edk2-platforms:uefi/edk2/edk2-platforms"
	"build-scripts:build-scripts"
)

# git am needs a committer identity (the patch authors are kept): use a
# placeholder in repo checkouts that have none configured
git_am() {
	local repo=$1; shift
	if git -C "$repo" config user.email >/dev/null; then
		git -C "$repo" -c mailinfo.quotedCr=nowarn am "$@"
	else
		GIT_COMMITTER_NAME=${GIT_COMMITTER_NAME:-drtm-poc} \
		GIT_COMMITTER_EMAIL=${GIT_COMMITTER_EMAIL:-drtm-poc@localhost} \
			git -C "$repo" -c mailinfo.quotedCr=nowarn am "$@"
	fi
}

subject() {
	git -c mailinfo.quotedCr=nowarn mailinfo /dev/null /dev/null < "$1" |
		sed -n 's/^Subject: //p'
}

# apply_series <repo> <patch-dir>: git am every patch not yet in the history
apply_series() {
	local repo=$1 pdir=$2 p s applied
	applied=$(git -C "$repo" log --format=%s -n 1000 HEAD)
	for p in "$pdir"/*.patch; do
		s=$(subject "$p")
		if grep -qxF -- "$s" <<<"$applied"; then
			echo "  already applied: $(basename "$p")"
			continue
		fi
		# --keep-cr: the EDK2 sources use CRLF line endings
		if ! git_am "$repo" -q --keep-cr --3way "$p"; then
			echo "  FAILED:          $(basename "$p")" >&2
			echo "  fix it and run 'git -C $repo am --continue', or 'git -C $repo am --abort'" >&2
			return 1
		fi
		echo "  applied:         $(basename "$p")"
	done
}

rc=0
for entry in "${REPOS[@]}"; do
	pdir=$POC/patches/${entry%%:*}
	repo=$TOP/${entry#*:}
	echo "=== ${entry#*:} ($(ls "$pdir"/*.patch | wc -l) patches)"
	if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
		echo "  not a git checkout: $repo" >&2
		rc=1
		continue
	fi
	if [ -d "$(git -C "$repo" rev-parse --git-path rebase-apply)" ]; then
		echo "  a git am or rebase is in progress, finish or abort it first" >&2
		rc=1
		continue
	fi
	if [ "$MODE" != check ] &&
	   [ -n "$(git -C "$repo" status --porcelain --untracked-files=no)" ]; then
		echo "  has uncommitted changes, commit or stash them first" >&2
		rc=1
		continue
	fi

	case $MODE in
	am)
		if [ "$(git -C "$repo" branch --show-current)" != "$BRANCH" ]; then
			git -C "$repo" checkout -q -B "$BRANCH"
			echo "  branch $BRANCH at $(git -C "$repo" rev-parse --short HEAD)"
		fi
		apply_series "$repo" "$pdir" || rc=1
		;;
	apply)
		for p in "$pdir"/*.patch; do
			if ! git -C "$repo" apply --whitespace=nowarn "$p"; then
				echo "  FAILED:          $(basename "$p")" >&2
				rc=1
				break
			fi
			echo "  applied:         $(basename "$p")"
		done
		;;
	check)
		tmp=$(mktemp -d)
		git -C "$repo" worktree add -q --detach "$tmp/wt" HEAD
		apply_series "$tmp/wt" "$pdir" || rc=1
		git -C "$repo" worktree remove --force "$tmp/wt"
		rmdir "$tmp"
		;;
	esac
done

if [ $rc != 0 ]; then
	echo "Some repositories were not patched, see above." >&2
fi
exit $rc
