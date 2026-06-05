#!/usr/bin/env bats
# Tests for MTU resolution priority in render_client_config.
# shellcheck disable=SC1091,SC2317,SC2329

load test_helper

bats_require_minimum_version 1.5.0

setup() {
    TEST_DIR=$(mktemp -d)
    export AWG_DIR="$TEST_DIR"
    export SERVER_CONF_FILE="$TEST_DIR/awg0.conf"
    log()       { :; }
    log_warn()  { :; }
    log_error() { :; }
    log_debug() { :; }
    export -f log log_warn log_error log_debug
    source "$BATS_TEST_DIRNAME/../awg_common.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "_extract_mtu_from_server_conf: returns last MTU from [Interface]" {
    cat > "$SERVER_CONF_FILE" <<'CONF'
[Interface]
PrivateKey = K
MTU = 1280
Address = 10.0.0.1/24
MTU    =   1420

[Peer]
MTU = 9000
CONF
    run _extract_mtu_from_server_conf
    [ "$status" -eq 0 ]
    [ "$output" = "1420" ]
}

@test "_extract_mtu_from_server_conf: invalid or missing MTU returns nonzero empty output" {
    cat > "$SERVER_CONF_FILE" <<'CONF'
[Interface]
PrivateKey = K
MTU = abc
Address = 10.0.0.1/24
CONF
    run _extract_mtu_from_server_conf
    [ "$status" -ne 0 ]
    [ -z "$output" ]

    rm -f "$SERVER_CONF_FILE"
    run _extract_mtu_from_server_conf
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "_validate_mtu: accepts safe range and rejects invalid values" {
    run _validate_mtu 576; [ "$status" -eq 0 ]
    run _validate_mtu 1280; [ "$status" -eq 0 ]
    run _validate_mtu 9100; [ "$status" -eq 0 ]
    run _validate_mtu 575; [ "$status" -ne 0 ]
    run _validate_mtu 9101; [ "$status" -ne 0 ]
    run _validate_mtu abc; [ "$status" -ne 0 ]
}

@test "structural: client configs use dynamic MTU in RU and EN" {
    for f in awg_common.sh awg_common_en.sh; do
        local block
        block=$(awk '/^render_client_config\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../$f")
        run ! grep -qE '^MTU = 1280$' <<<"$block"
        grep -qE 'MTU = \$\{mtu\}' <<<"$block"
        grep -qF '_extract_mtu_from_server_conf' <<<"$block"
    done
}

@test "structural: server config and safe_load_config support AWG_MTU" {
    for f in awg_common.sh awg_common_en.sh; do
        local block
        block=$(awk '/^render_server_config\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../$f")
        grep -qE 'MTU = \$\{AWG_MTU:-1280\}' <<<"$block"
        grep -qE 'AWG_ENDPOINT\|AWG_MTU' "$BATS_TEST_DIRNAME/../$f"
    done
    grep -qE 'AWG_ENDPOINT\|AWG_MTU' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qE 'AWG_ENDPOINT\|AWG_MTU' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -qF 'export AWG_MTU=' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'export AWG_MTU=' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
}

@test "_extract_mtu_from_server_conf: RU and EN bodies stay identical" {
    local ru_block en_block
    ru_block=$(awk '/^_extract_mtu_from_server_conf\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../awg_common.sh" | grep -v '^#')
    en_block=$(awk '/^_extract_mtu_from_server_conf\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../awg_common_en.sh" | grep -v '^#')
    [ -n "$ru_block" ]
    [ "$ru_block" = "$en_block" ]
}
