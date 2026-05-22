#!/usr/bin/env bats
# Tests for ARM kernel version resolver in scripts/build-arm-deb.sh.
# shellcheck disable=SC1091,SC2016,SC2034

bats_require_minimum_version 1.5.0

setup() {
    TEST_DIR=$(mktemp -d)
    MODULES_ROOT="$TEST_DIR/lib/modules"
    mkdir -p "$MODULES_ROOT"
    unset KERNEL_VERSION
    source "$BATS_TEST_DIRNAME/../scripts/build-arm-deb.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
    unset KERNEL_VERSION
}

@test "_resolve_kernel_version: returns single candidate" {
    mkdir -p "$MODULES_ROOT/6.12.5-rpi/build"

    run _resolve_kernel_version "$MODULES_ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = "6.12.5-rpi" ]
}

@test "_resolve_kernel_version: fails with no candidates" {
    run _resolve_kernel_version "$MODULES_ROOT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"No kernel build directory found"* ]]
}

@test "_resolve_kernel_version: fails on multiple candidates and lists them" {
    mkdir -p "$MODULES_ROOT/6.1.0-rpi/build"
    mkdir -p "$MODULES_ROOT/6.12.5-rpi/build"

    run _resolve_kernel_version "$MODULES_ROOT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Multiple kernel build directories"* ]]
    [[ "$output" == *"6.1.0-rpi"* ]]
    [[ "$output" == *"6.12.5-rpi"* ]]
    [[ "$output" == *"Set KERNEL_VERSION env"* ]]
}

@test "_resolve_kernel_version: KERNEL_VERSION disambiguates or fails clearly" {
    mkdir -p "$MODULES_ROOT/6.1.0-rpi/build"
    mkdir -p "$MODULES_ROOT/6.12.5-rpi/build"
    KERNEL_VERSION="6.12.5-rpi"

    run _resolve_kernel_version "$MODULES_ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = "6.12.5-rpi" ]

    KERNEL_VERSION="6.99.0-missing"
    run _resolve_kernel_version "$MODULES_ROOT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"KERNEL_VERSION='6.99.0-missing'"* ]]
}

@test "structural: build script uses resolver and source guard" {
    local file="$BATS_TEST_DIRNAME/../scripts/build-arm-deb.sh"
    grep -qE '^_resolve_kernel_version\(\) \{' "$file"
    grep -qE '\(return 0 2>/dev/null\) && return 0' "$file"
    run ! grep -qE '^for _d in /lib/modules/\*/build' "$file"
    grep -qE 'KERNEL_VERSION="\$\(_resolve_kernel_version /lib/modules\)"' "$file"
}

@test "structural: fork xz hardening remains atomic and non-destructive" {
    local file="$BATS_TEST_DIRNAME/../scripts/build-arm-deb.sh"
    grep -qF 'KO_TMP_XZ="${KO_FILE}.tmp.xz"' "$file"
    grep -qF 'xz -t "$KO_TMP_XZ"' "$file"
    grep -qF 'xz -d -c "$KO_TMP_XZ"' "$file"
    grep -qF 'mv -f "$KO_TMP_XZ" "$KO_XZ"' "$file"
    run ! grep -qF 'xz --check=crc32 --lzma2=dict=1MiB -f "$KO_FILE"' "$file"
}
