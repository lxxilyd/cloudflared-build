//go:build freebsd || openbsd || netbsd

// custom/bsd overlay: managed by custom/bsd/apply.sh, do not edit by hand.

package diagnostic

// BSD implementation of the system information collector.
//
// Upstream only ships system_collector_{linux,darwin,windows}.go, so the
// `cloudflared tunnel diag` command does not build for FreeBSD/OpenBSD/NetBSD.
// This file fills that gap using the sysctl(8) interface of the BSDs and the
// parsing helpers that live in system_collector_utils.go (shared, no build tag).
//
// Collection errors are recorded in SystemInformationGeneralError rather than
// failing the whole diagnostic dump, so a missing sysctl node (they differ
// slightly between FreeBSD, OpenBSD and NetBSD) only degrades one section.

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
)

type SystemCollectorImpl struct {
	version string
}

func NewSystemCollectorImpl(
	version string,
) *SystemCollectorImpl {
	return &SystemCollectorImpl{
		version: version,
	}
}

func (collector *SystemCollectorImpl) Collect(ctx context.Context) (*SystemInformation, error) {
	memoryInfo, memoryInfoRaw, memoryInfoErr := collectMemoryInformation(ctx)
	fdInfo, fdInfoRaw, fdInfoErr := collectFileDescriptorInformation(ctx)
	disks, disksRaw, diskErr := collectDiskVolumeInformationUnix(ctx)
	osInfo, osInfoRaw, osInfoErr := collectOSInformationUnix(ctx)

	var memoryMaximum, memoryCurrent, fileDescriptorMaximum, fileDescriptorCurrent uint64
	var osSystem, name, osVersion, osRelease, architecture string

	err := SystemInformationGeneralError{
		OperatingSystemInformationError: nil,
		MemoryInformationError:          nil,
		FileDescriptorsInformationError: nil,
		DiskVolumeInformationError:      nil,
	}

	if memoryInfoErr != nil {
		err.MemoryInformationError = SystemInformationError{
			Err:     memoryInfoErr,
			RawInfo: memoryInfoRaw,
		}
	} else {
		memoryMaximum = memoryInfo.MemoryMaximum
		memoryCurrent = memoryInfo.MemoryCurrent
	}

	if fdInfoErr != nil {
		err.FileDescriptorsInformationError = SystemInformationError{
			Err:     fdInfoErr,
			RawInfo: fdInfoRaw,
		}
	} else {
		fileDescriptorMaximum = fdInfo.FileDescriptorMaximum
		fileDescriptorCurrent = fdInfo.FileDescriptorCurrent
	}

	if diskErr != nil {
		err.DiskVolumeInformationError = SystemInformationError{
			Err:     diskErr,
			RawInfo: disksRaw,
		}
	}

	if osInfoErr != nil {
		err.OperatingSystemInformationError = SystemInformationError{
			Err:     osInfoErr,
			RawInfo: osInfoRaw,
		}
	} else {
		osSystem = osInfo.OsSystem
		name = osInfo.Name
		osVersion = osInfo.OsVersion
		osRelease = osInfo.OsRelease
		architecture = osInfo.Architecture
	}

	cloudflaredVersion := collector.version
	info := NewSystemInformation(
		memoryMaximum,
		memoryCurrent,
		fileDescriptorMaximum,
		fileDescriptorCurrent,
		osSystem,
		name,
		osVersion,
		osRelease,
		architecture,
		cloudflaredVersion,
		runtime.Version(),
		runtime.GOARCH,
		disks,
	)

	return info, err
}

// sysctlValue runs `sysctl -n <key>` and returns the trimmed value.
func sysctlValue(ctx context.Context, key string) (string, error) {
	command := exec.CommandContext(ctx, "sysctl", "-n", key)

	stdout, err := command.Output()
	if err != nil {
		return "", fmt.Errorf("error retrieving output from command '%s': %w", command.String(), err)
	}

	return strings.TrimSpace(string(stdout)), nil
}

func sysctlUint64(ctx context.Context, key string) (uint64, error) {
	value, err := sysctlValue(ctx, key)
	if err != nil {
		return 0, err
	}

	parsed, err := strconv.ParseUint(value, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("error parsing sysctl %s: %w", key, err)
	}

	return parsed, nil
}

func collectMemoryInformation(ctx context.Context) (*MemoryInformation, string, error) {
	// hw.physmem is the total amount of physical memory in bytes on FreeBSD,
	// OpenBSD and NetBSD. vm.stats.vm.v_free_count is the number of free pages
	// (4K on amd64, 16K on arm64), hence the page size lookup instead of a
	// hardcoded 4096.
	const (
		memoryMaximumKey   = "hw.physmem"
		memoryAvailableKey = "vm.stats.vm.v_free_count"
	)

	totalBytes, err := sysctlUint64(ctx, memoryMaximumKey)
	if err != nil {
		return nil, "", err
	}

	freePages, err := sysctlUint64(ctx, memoryAvailableKey)
	if err != nil {
		return nil, "", err
	}

	const kiloBytes = 1024

	memoryMaximum := totalBytes / kiloBytes
	freeKB := freePages * uint64(os.Getpagesize()) / kiloBytes
	if freeKB > memoryMaximum {
		freeKB = memoryMaximum
	}

	memoryInfo := &MemoryInformation{
		MemoryMaximum: memoryMaximum,
		MemoryCurrent: memoryMaximum - freeKB,
	}

	raw := fmt.Sprintf("total: %d kB, free: %d kB", memoryMaximum, freeKB)

	return memoryInfo, raw, nil
}

func collectFileDescriptorInformation(ctx context.Context) (*FileDescriptorInformation, string, error) {
	// `sysctl -n` prints one value per line for the requested nodes.
	const (
		fileDescriptorMaximumKey = "kern.maxfiles"
		fileDescriptorCurrentKey = "kern.num_files"
	)

	command := exec.CommandContext(ctx, "sysctl", "-n", fileDescriptorMaximumKey, fileDescriptorCurrentKey)

	stdout, err := command.Output()
	if err != nil {
		return nil, "", fmt.Errorf("error retrieving output from command '%s': %w", command.String(), err)
	}

	output := string(stdout)
	fields := strings.Fields(output)
	if len(fields) != 2 {
		return nil, output, fmt.Errorf(
			"expected 2 file descriptor values, got %d: %w", len(fields), ErrInsuficientFields,
		)
	}

	maximum, err := strconv.ParseUint(fields[0], 10, 64)
	if err != nil {
		return nil, output, fmt.Errorf("error parsing max file descriptors '%s': %w", fields[0], err)
	}

	current, err := strconv.ParseUint(fields[1], 10, 64)
	if err != nil {
		return nil, output, fmt.Errorf("error parsing current file descriptors '%s': %w", fields[1], err)
	}

	fileDescriptorInfo := &FileDescriptorInformation{
		FileDescriptorMaximum: maximum,
		FileDescriptorCurrent: current,
	}

	return fileDescriptorInfo, output, nil
}
