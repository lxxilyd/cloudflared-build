#!/bin/sh
# Apply the BSD patch set to a pristine upstream cloudflared tree.
#
# The tree is passed in with --root (or BSD_PATCH_ROOT), so this script can
# patch a temporary directory that carries no other trace of this repository.
# Keeping `custom/` out of the patched tree is what makes the manifest check in
# build.sh exact: after patching, the tree must differ from pristine upstream
# only in the files listed in manifest.txt.
#
# Every edit is explicit and idempotent, and the script fails loudly if upstream
# renamed or removed something it depends on.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OVERLAY="$SCRIPT_DIR/overlay"
ROOT="${BSD_PATCH_ROOT:-}"

while [ $# -gt 0 ]; do
	case "$1" in
	--root)
		[ $# -ge 2 ] || { echo "--root needs a directory" >&2; exit 2; }
		ROOT=$2
		shift 2
		;;
	*)
		echo "unknown argument: $1" >&2
		exit 2
		;;
	esac
done

if [ -z "$ROOT" ]; then
	ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
fi
[ -d "$ROOT" ] || { echo "no such directory: $ROOT" >&2; exit 2; }
[ -f "$ROOT/cmd/cloudflared/main.go" ] || {
	echo "$ROOT does not look like a cloudflared tree" >&2
	exit 2
}

cd "$ROOT"

log() { printf '  [bsd-patch] %s\n' "$*"; }
die() { printf '  [bsd-patch] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Whole-file overlays: files that only exist because of the BSD port.
#    If upstream ever ships the same path itself, we stop and let a human
#    decide instead of silently shadowing upstream code.
# ---------------------------------------------------------------------------
for src in $(cd "$OVERLAY" && find . -type f -name '*.go' | sed 's|^\./||' | sort); do
	dst="$ROOT/$src"
	if [ -f "$dst" ]; then
		if cmp -s "$OVERLAY/$src" "$dst"; then
			log "already applied $src"
			continue
		fi
		# A stale copy of our own overlay (older patch revision): replace it.
		if grep -q 'custom/bsd overlay' "$dst"; then
			cp "$OVERLAY/$src" "$dst"
			log "updated stale overlay $src"
			continue
		fi
		die "upstream now ships $src itself - drop it from custom/bsd/overlay/ and adapt the patch"
	fi
	mkdir -p "$(dirname "$dst")"
	cp "$OVERLAY/$src" "$dst"
	log "add $src"
done

# ---------------------------------------------------------------------------
# 2. Extend //go:build lines of shared POSIX files to the BSDs.
# ---------------------------------------------------------------------------
add_bsd_tags() {
	file=$1
	[ -f "$file" ] || die "file not found: $file"

	if head -n 1 "$file" | grep -q 'freebsd'; then
		log "build tag already covers BSD: $file"
		return 0
	fi

	first=$(head -n 1 "$file")
	case "$first" in
	'//go:build '*) ;;
	*) die "expected a //go:build line on line 1 of $file, got: $first" ;;
	esac

	tag=$(printf '%s' "$first" | sed 's|^//go:build ||')
	work=$(mktemp)
	{
		printf '//go:build %s || freebsd || openbsd || netbsd\n' "$tag"
		tail -n +2 "$file"
	} >"$work"
	cat "$work" >"$file"
	rm -f "$work"
	log "build tag += freebsd/openbsd/netbsd: $file"
}

add_bsd_tags diagnostic/network/collector_unix.go
add_bsd_tags diagnostic/network/collector_unix_test.go
add_bsd_tags ingress/icmp_posix.go
# ingress/icmp_posix_test.go is intentionally NOT extended: it exercises a real
# ICMP proxy over sockets, and on the BSDs ingress falls back to icmp_generic.go
# (the "not implemented" stub - icmp_linux.go/icmp_darwin.go are OS specific).

# ---------------------------------------------------------------------------
# 3. Makefile: re-add netbsd to the LOCAL_OS -> TARGET_OS mapping.
#    Upstream dropped it (only freebsd/openbsd are still mapped) and without it
#    `make cloudflared` aborts with "This system's OS netbsd isn't supported".
# ---------------------------------------------------------------------------
[ -f Makefile ] || die "Makefile not found"

if grep -q 'netbsd' Makefile; then
	log "Makefile already maps netbsd"
else
	work=$(mktemp)
	awk '
		/^else ifeq \(\$\(LOCAL_OS\),openbsd\)$/ { in_openbsd = 1; print; next }
		in_openbsd && /TARGET_OS \?= openbsd/ {
			print
			print "else ifeq ($(LOCAL_OS),netbsd)"
			print "    TARGET_OS ?= netbsd"
			in_openbsd = 0
			next
		}
		{ print }
	' Makefile >"$work"

	mv "$work" Makefile

	if ! grep -q 'TARGET_OS ?= netbsd' Makefile; then
		die "could not inject the netbsd branch into the Makefile (LOCAL_OS mapping changed upstream?)"
	fi
	log "Makefile: netbsd mapped to TARGET_OS"
fi

for os in freebsd openbsd netbsd; do
	grep -q "$os" Makefile || die "Makefile does not mention $os after patching"
done

log "BSD patch applied to $ROOT"
