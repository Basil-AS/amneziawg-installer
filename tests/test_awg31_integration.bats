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

@test "shared runtime defaults to AWG 3.1 when no version is configured" {
    for file in awg_common.sh awg_common_en.sh; do
        run bash -c 'unset AWG_PROTOCOL_VERSION; source "$1"; _awg_protocol_version' _ "$BATS_TEST_DIRNAME/../$file"
        [ "$status" -eq 0 ]
        [ "$output" = "3.1" ]
    done
}

@test "runtime renderers contain explicit compatibility branches for 1.5 and 3.0" {
    for file in awg_common.sh awg_common_en.sh; do
        grep -q '_awg_protocol_has_s34' "$BATS_TEST_DIRNAME/../$file"
        grep -q 'protocol_version.*== "1.5"' "$BATS_TEST_DIRNAME/../$file"
        grep -q 'protocol_version.*== "3.0"' "$BATS_TEST_DIRNAME/../$file"
    done
}

@test "AWG 1.5 live config loads without S3/S4 while AWG 2.0 still requires them" {
    local conf="$BATS_TEST_TMPDIR/awg15.conf"
    cat >"$conf" <<'EOF'
[Interface]
Jc = 4
Jmin = 10
Jmax = 50
S1 = 32
S2 = 48
H1 = 1
H2 = 2
H3 = 3
H4 = 4
EOF
    run bash -c 'source "$1"; AWG_PROTOCOL_VERSION=1.5; load_awg_params_from_server_conf "$2"; printf "%s|%s|%s" "$AWG_H1" "${AWG_S3:-}" "${AWG_S4:-}"' _ "$BATS_TEST_DIRNAME/../awg_common.sh" "$conf"
    [ "$status" -eq 0 ]
    [ "$output" = "1||" ]

    run bash -c 'source "$1"; AWG_PROTOCOL_VERSION=2.0; load_awg_params_from_server_conf "$2"' _ "$BATS_TEST_DIRNAME/../awg_common.sh" "$conf"
    [ "$status" -ne 0 ]
}

@test "installers deploy the pinned canonical profile renderer" {
    for file in install_amneziawg.sh install_amneziawg_en.sh; do
        grep -q 'scripts/awg_profile.py' "$BATS_TEST_DIRNAME/../$file"
        grep -q 'scripts/probe-awg31.sh' "$BATS_TEST_DIRNAME/../$file"
    done
}
