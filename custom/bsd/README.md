# custom/bsd — FreeBSD / OpenBSD / NetBSD port of cloudflared

Upstream cloudflared only builds for linux, darwin and windows. This directory
carries the minimum patch needed to build (and package) it for the BSDs.

It is applied by `build.sh` to a freshly downloaded upstream tarball, so it never
touches a checked out branch. `--root` selects the tree to patch; `manifest.txt`
lists the only files the patch is allowed to change, and `build.sh` verifies that
before compiling.

## Patch inventory

| Step | Target | What it does |
| --- | --- | --- |
| overlay | `diagnostic/system_collector_unix.go` | New file. Upstream ships linux/darwin/windows collectors only; `cloudflared tunnel diag` needs one for the BSDs. Uses `sysctl -n` plus the shared parsers in `system_collector_utils.go`. |
| overlay | `cmd/cloudflared/service_token_bsd.go` | New file. Upstream wires `createTokenFile` only in `linux_service.go`, `macos_service.go` and `windows_service.go`, so the token-file code in `common_service.go` fails to compile on the BSDs with `undefined: createTokenFile`. |
| build tag | `diagnostic/network/collector_unix.go` | `traceroute` based network collector — the code is already POSIX, only the tag excludes the BSDs. |
| build tag | `diagnostic/network/collector_unix_test.go` | Pure output-parsing tests, safe on the BSDs. |
| build tag | `ingress/icmp_posix.go` | Shared ICMP proxy helpers. Kept for parity; note that real ICMP proxying still resolves to `icmp_generic.go` on the BSDs because `icmp_linux.go` / `icmp_darwin.go` are OS specific. |
| Makefile | `LOCAL_OS` mapping | Upstream dropped `netbsd` (freebsd/openbsd are still mapped). Without it `make cloudflared` aborts with *"This system's OS netbsd isn't supported"*. |

Deliberately **not** patched:

* `ingress/icmp_posix_test.go` — it needs a working ICMP proxy, which the BSDs
  do not have (see above), so it would only fail.
* The `Makefile` is no longer carried as a whole file. Only the `netbsd` branch
  is injected; everything else stays upstream's (`-mod=readonly`, `GOFIPS140`,
  `ci-*` targets, ...).

## Usage

```sh
git fetch upstream --depth=1 tag 2026.10.3
git checkout -B release/2026.10.3 FETCH_HEAD
sh ./custom/bsd/apply.sh     # idempotent, fails loudly on upstream renames
CGO_ENABLED=0 GOOS=freebsd go build ./cmd/cloudflared
```

`sync-cloudflared.yaml` runs exactly this, then cross-compiles for
`freebsd/amd64`, `openbsd/amd64`, `netbsd/amd64` and `freebsd/arm64` **before**
pushing the release branch, so a broken patch can never reach a release.

## Upgrading after an upstream change

`apply.sh` fails instead of guessing. Two failure modes and what to do:

* `overlay target ... upstream now ships` — upstream added its own BSD/deeper
  implementation. Drop the overlay and adapt.
* `could not inject the netbsd branch` / `expected a //go:build line` — the
  Makefile or a build-tag line was reformatted upstream. Update the pattern in
  `apply.sh`.

Toolchain: upstream's `go.mod` pins a full version (currently `go 1.27.3`), and
the go command refuses to build with anything older. `GO_VERSION` in both
workflows must be bumped together with the patch set. The distro `go` package on
the BSDs is always too old, which is why the workflows download the official
tarballs from go.dev instead.
