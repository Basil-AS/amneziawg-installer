#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

@test "RU and EN installers expose the four protocol versions" {
    for file in install_amneziawg.sh install_amneziawg_en.sh; do
        grep -q -- '--awg-version=' "$BATS_TEST_DIRNAME/../$file"
        grep -q '1.5|2.0|3.0|3.1' "$BATS_TEST_DIRNAME/../$file"
        grep -q 'AWG_PROTOCOL_VERSION.*3.1' "$BATS_TEST_DIRNAME/../$file"
    done
}

@test "3.1 rendering is fail-closed and includes protected fields" {
    for file in awg_common.sh awg_common_en.sh; do
        grep -q '_awg31_render_extra_fields' "$BATS_TEST_DIRNAME/../$file"
        grep -q 'HeaderProtectionKey' "$BATS_TEST_DIRNAME/../$file"
        grep -q 'AWG_PROTOCOL_VERSION.*3.1' "$BATS_TEST_DIRNAME/../$file"
    done
}

@test "runtime renderers contain explicit compatibility branches for 1.5 and 3.0" {
    for file in awg_common.sh awg_common_en.sh; do
        grep -q '_awg_protocol_has_s34' "$BATS_TEST_DIRNAME/../$file"
        grep -q 'protocol_version.*== "1.5"' "$BATS_TEST_DIRNAME/../$file"
        grep -q 'protocol_version.*== "3.0"' "$BATS_TEST_DIRNAME/../$file"
    done
}

@test "installers deploy the pinned canonical profile renderer" {
    for file in install_amneziawg.sh install_amneziawg_en.sh; do
        grep -q 'scripts/awg_profile.py' "$BATS_TEST_DIRNAME/../$file"
        grep -q 'scripts/probe-awg31.sh' "$BATS_TEST_DIRNAME/../$file"
    done
}
