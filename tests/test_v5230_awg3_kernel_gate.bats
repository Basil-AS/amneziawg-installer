#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# This file intentionally replaces the old kernel-version gate.  AWG 3.1 is
# selected by capability (setconf plus read-back), never by uname -r.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/probe-awg31.sh"
}

@test "AWG 3.1 probe uses a temporary interface and mandatory read-back" {
    grep -q 'ip link add "\$probe_if" type amneziawg' "$SCRIPT"
    grep -q 'awg setconf "\$probe_if"' "$SCRIPT"
    grep -q 'WG_HIDE_KEYS=never awg show "\$probe_if"' "$SCRIPT"
}

@test "AWG 3.1 probe contains no kernel version gate" {
    ! grep -qE 'uname|6\.7|kernel.*version' "$SCRIPT"
}
