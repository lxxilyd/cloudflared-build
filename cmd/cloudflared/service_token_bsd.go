//go:build freebsd || openbsd || netbsd

// custom/bsd overlay: managed by custom/bsd/apply.sh, do not edit by hand.

package main

// Upstream wires createTokenFile up per platform: linux_service.go and
// macos_service.go alias it to createTokenFileUnix, windows_service.go provides
// its own ACL based implementation. There is no BSD file, so the (platform
// independent) token handling in common_service.go does not compile there.
//
// The BSDs are POSIX, so aliasing the unix implementation is the correct fix.
var createTokenFile = createTokenFileUnix
