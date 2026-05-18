#!/usr/bin/env bats
# shellcheck disable=SC1091,SC2030,SC2031,SC2317
# Tests for apply_config() modes in awg_common.sh
#
# NOTE: This file uses its own setup() (not just test_helper's) because it
# needs to set up a $MOCK_BIN directory with stub systemctl/awg/awg-quick
# and source awg_common.sh directly. test_helper is still loaded for helper
# functions (require_flock etc.) but its setup() is overridden here.

load test_helper

setup() {
    # Call parent setup
    TEST_DIR=$(mktemp -d)
    export AWG_DIR="$TEST_DIR"
    export CONFIG_FILE="$TEST_DIR/awgsetup_cfg.init"
    export SERVER_CONF_FILE="$TEST_DIR/awg0.conf"
    export KEYS_DIR="$TEST_DIR/keys"
    mkdir -p "$KEYS_DIR"

    # Silent log stubs
    log()       { :; }
    log_warn()  { :; }
    log_error() { :; }
    log_debug() { :; }
    export -f log log_warn log_error log_debug

    # Mock PATH: create stub commands
    MOCK_BIN="$TEST_DIR/mock_bin"
    mkdir -p "$MOCK_BIN"
    export PATH="$MOCK_BIN:$PATH"

    # Stub systemctl
    cat > "$MOCK_BIN/systemctl" << 'STUB'
#!/bin/bash
echo "systemctl $*" >> "${AWG_DIR}/.mock_calls"
exit 0
STUB
    chmod +x "$MOCK_BIN/systemctl"

    # Stub awg-quick
    cat > "$MOCK_BIN/awg-quick" << 'STUB'
#!/bin/bash
echo "awg-quick $*" >> "${AWG_DIR}/.mock_calls"
echo "[Interface]"
echo "PrivateKey = TEST"
exit 0
STUB
    chmod +x "$MOCK_BIN/awg-quick"

    # Stub awg
    cat > "$MOCK_BIN/awg" << 'STUB'
#!/bin/bash
echo "awg $*" >> "${AWG_DIR}/.mock_calls"
exit 0
STUB
    chmod +x "$MOCK_BIN/awg"

    # Stub timeout (pass-through)
    cat > "$MOCK_BIN/timeout" << 'STUB'
#!/bin/bash
shift  # skip timeout value
"$@"
STUB
    chmod +x "$MOCK_BIN/timeout"

    source "$BATS_TEST_DIRNAME/../awg_common.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "apply_config: AWG_SKIP_APPLY=1 returns 0 without calling anything" {
    export AWG_SKIP_APPLY=1
    run apply_config
    [ "$status" -eq 0 ]
    [ ! -f "$AWG_DIR/.mock_calls" ]
}

@test "apply_config: AWG_APPLY_MODE=restart calls systemctl restart" {
    require_flock
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=restart
    run apply_config
    [ "$status" -eq 0 ]
    grep -q "systemctl restart awg-quick@awg0" "$AWG_DIR/.mock_calls"
}

@test "apply_config: default mode calls awg-quick strip + awg syncconf" {
    require_flock
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=syncconf
    run apply_config
    [ "$status" -eq 0 ]
    grep -q "awg-quick strip awg0" "$AWG_DIR/.mock_calls"
    grep -q "awg syncconf" "$AWG_DIR/.mock_calls"
}

@test "apply_config: unknown mode falls through to syncconf" {
    require_flock
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=invalid_mode
    run apply_config
    [ "$status" -eq 0 ]
    grep -q "awg-quick strip" "$AWG_DIR/.mock_calls"
}

@test "apply_config: flock failure returns 1" {
    require_flock
    # Mock flock to always return 1, simulating lock acquisition failure
    # (e.g. timeout waiting for .awg_apply.lock held by another process).
    # Precondition: $AWG_DIR exists (guaranteed by setup's TEST_DIR=$(mktemp -d)),
    # so exec {apply_fd}>"$apply_lockfile" succeeds and the flock binary is called.
    # apply_config() makes exactly one flock call; returning 1 here exercises
    # the "! flock -x -w 120 $apply_fd → return 1" path in awg_common.sh.
    cat > "$MOCK_BIN/flock" << 'STUB'
#!/bin/bash
exit 1
STUB
    chmod +x "$MOCK_BIN/flock"

    export AWG_SKIP_APPLY=0
    run apply_config
    [ "$status" -eq 1 ]
}

@test "apply_config: systemctl restart failure returns non-zero" {
    require_flock
    # Override systemctl stub to exit 1 (simulate restart failure)
    cat > "$MOCK_BIN/systemctl" << 'STUB'
#!/bin/bash
echo "systemctl $*" >> "${AWG_DIR}/.mock_calls"
exit 1
STUB
    chmod +x "$MOCK_BIN/systemctl"

    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=restart
    run apply_config
    [ "$status" -ne 0 ]
}
