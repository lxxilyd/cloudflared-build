#!/usr/bin/env bash
# Build cloudflared for one target from a pristine upstream tarball + the BSD
# patch set. Nothing from upstream is stored in this repository: the source is
# downloaded on every run, patched, compiled and thrown away.
#
#   ./build.sh 2026.10.3                 # host platform
#   GOOS=freebsd GOARCH=arm64 ./build.sh # cross compile
#   ./build.sh                           # latest upstream tag
#
# Environment:
#   GOOS, GOARCH    target platform (default: host)
#   OUTPUT_DIR      where the tarball lands (default: ./output)
#   WORK_DIR        keep the patched tree here instead of a temp dir (debugging)

set -euo pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TAG=""
SNAPSHOT_DIR=""
TARGET_OS="${GOOS:-}"
TARGET_ARCH="${GOARCH:-}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output}"

while [ $# -gt 0 ]; do
	case "$1" in
	--snapshot)
		[ $# -ge 2 ] || { echo "--snapshot needs a directory" >&2; exit 2; }
		SNAPSHOT_DIR=$2
		shift 2
		;;
	--snapshot=*)
		SNAPSHOT_DIR=${1#*=}
		shift
		;;
	-h | --help)
		sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	-*)
		echo "unknown option: $1" >&2
		exit 2
		;;
	*)
		[ -z "$TAG" ] || { echo "unexpected argument: $1" >&2; exit 2; }
		TAG=$1
		shift
		;;
	esac
done

log() { printf '\033[0;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[0;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "$TARGET_OS" ] || TARGET_OS=$(go env GOOS)
[ -n "$TARGET_ARCH" ] || TARGET_ARCH=$(go env GOARCH)

if [ -z "$TAG" ]; then
	log "resolving latest upstream release"
	TAG=$(curl -fsSL https://api.github.com/repos/cloudflare/cloudflared/releases/latest |
		grep -oE '"tag_name": *"[^"]+"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
fi
[ -n "$TAG" ] || die "cannot determine the upstream tag"

case "$TAG" in
[0-9][0-9][0-9][0-9].*) ;;
*) die "unexpected tag: $TAG" ;;
esac

log "tag ${TAG}, target ${TARGET_OS}/${TARGET_ARCH}"

if [ -n "${WORK_DIR:-}" ]; then
	mkdir -p "$WORK_DIR"
	WORK=$WORK_DIR
	KEEP=1
else
	WORK=$(mktemp -d)
	KEEP=0
fi
cleanup() { [ "$KEEP" = "1" ] || rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

PRISTINE="$WORK/pristine"
PATCHED="$WORK/patched"

# Download the same tarball twice: one copy stays untouched as the reference for
# the manifest check, the other one gets patched.
fetch_tree() {
	dest=$1
	mkdir -p "$dest"
	log "downloading https://codeload.github.com/cloudflare/cloudflared/tar.gz/refs/tags/${TAG}"
	curl -fsSL "https://codeload.github.com/cloudflare/cloudflared/tar.gz/refs/tags/${TAG}" |
		tar -xz -C "$dest" --strip-components=1
}

fetch_tree "$PRISTINE"
fetch_tree "$PATCHED"

log "applying custom/bsd"
sh "$REPO_ROOT/custom/bsd/apply.sh" --root "$PATCHED"

# ---------------------------------------------------------------------------
# Invariant: the patched tree must differ from pristine upstream only in the
# files listed in custom/bsd/manifest.txt. This is what "release == upstream +
# patch" means, and it is checked on every build instead of being assumed.
# ---------------------------------------------------------------------------
verify_manifest() {
	pristine=$1
	patched=$2
	manifest=$3

	actual=$(mktemp)
	expected=$(mktemp)

	# Added or modified files.
	(
		cd "$patched"
		find . -type f | sed 's|^\./||' | while IFS= read -r f; do
			if [ ! -f "$pristine/$f" ] || ! cmp -s "$pristine/$f" "$patched/$f"; then
				printf '%s\n' "$f"
			fi
		done
	) >"$actual"

	# Removed files.
	(
		cd "$pristine"
		find . -type f | sed 's|^\./||' | while IFS= read -r f; do
			[ -f "$patched/$f" ] || printf '%s\n' "$f"
		done
	) >>"$actual"

	LC_ALL=C sort -u "$actual" -o "$actual"
	LC_ALL=C sort -u "$manifest" -o "$expected"

	if ! diff -u "$expected" "$actual"; then
		rm -f "$actual" "$expected" 2>/dev/null || true
		die "the patch touched files outside custom/bsd/manifest.txt (see diff above)"
	fi

	log "manifest OK: $(wc -l <"$actual" | tr -d ' ') files differ from pristine upstream"
	rm -f "$actual" "$expected" 2>/dev/null || true
}

verify_manifest "$PRISTINE" "$PATCHED" "$REPO_ROOT/custom/bsd/manifest.txt"

# ---------------------------------------------------------------------------
# Snapshot mode: export the patched tree so a release/<tag> branch can carry it
# for reading and diffing. The binaries are still built from this same tree.
# ---------------------------------------------------------------------------
if [ -n "$SNAPSHOT_DIR" ]; then
	mkdir -p "$SNAPSHOT_DIR"
	cp -R "$PATCHED/." "$SNAPSHOT_DIR/"
	log "snapshot exported to $SNAPSHOT_DIR"
	exit 0
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
suffix=""
[ "$TARGET_OS" = "windows" ] && suffix=".exe"

required_go=$(sed -n 's/^go \([0-9][0-9.]*\).*/\1/p' "$PATCHED/go.mod" | head -1)
have_go=$(go env GOVERSION | sed 's/^go//')
if [ -n "$required_go" ]; then
	newest=$(printf '%s\n%s\n' "$required_go" "$have_go" | LC_ALL=C sort -V | tail -1)
	if [ "$newest" != "$have_go" ]; then
		# Not fatal: with GOTOOLCHAIN=auto the go command fetches the required
		# toolchain itself, and with GOTOOLCHAIN=local it fails with a clear
		# message of its own.
		warn "upstream go.mod requires go >= ${required_go}, this toolchain is ${have_go}"
	else
		log "go ${have_go} satisfies upstream's requirement (>= ${required_go})"
	fi
fi

log "building"
(
	cd "$PATCHED"
	export CGO_ENABLED=0 GOOS="$TARGET_OS" GOARCH="$TARGET_ARCH"
	# The tarball has no .git, so `git describe` in the Makefile cannot produce a
	# version. VERSION is a command line assignment, which overrides the
	# Makefile's own `VERSION := $(shell git describe ...)`.
	if command -v make >/dev/null 2>&1; then
		make VERSION="$TAG" cloudflared
	else
		warn "make not found, falling back to go build"
		# No spaces in the value: -ldflags is split on whitespace by the go
		# command, so a "2026-10-26 01:54 UTC" timestamp would break the linker
		# invocation (it would read UTC as a flag).
		build_time=$(date -u '+%Y-%m-%dT%H:%MZ')
		go build -mod=readonly \
			-ldflags "-X main.Version=${TAG} -X main.BuildTime=${build_time}" \
			-o "cloudflared${suffix}" ./cmd/cloudflared
	fi
)

[ -f "$PATCHED/cloudflared${suffix}" ] || die "build produced no binary"

mkdir -p "$OUTPUT_DIR"
asset="cloudflared-${TARGET_OS}-${TARGET_ARCH}"
cp "$PATCHED/cloudflared${suffix}" "$OUTPUT_DIR/${asset}${suffix}"
tar -czf "$OUTPUT_DIR/${asset}.tar.gz" -C "$OUTPUT_DIR" "${asset}${suffix}"
rm -f "$OUTPUT_DIR/${asset}${suffix}"

log "wrote $OUTPUT_DIR/${asset}.tar.gz"
