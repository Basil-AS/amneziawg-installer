#!/usr/bin/env bats
# shellcheck disable=SC1091,SC2154,SC2317

load test_helper

setup() {
    TEST_DIR=$(mktemp -d)
    export AWG_DIR="$TEST_DIR"
    export CONFIG_FILE="$TEST_DIR/awgsetup_cfg.init"
    export SERVER_CONF_FILE="$TEST_DIR/awg0.conf"
    export AWG_HOSTS_FILE="$TEST_DIR/hosts"
    export KEYS_DIR="$TEST_DIR/keys"
    export EXPIRY_DIR="$TEST_DIR/expiry"
    export EXPIRY_CRON="$TEST_DIR/awg-expiry-cron"
    export AWG_ENDPOINT="203.0.113.10"
    export AWG_SKIP_APPLY=1
    mkdir -p "$KEYS_DIR" "$EXPIRY_DIR"
    printf '127.0.0.1 localhost\n' > "$AWG_HOSTS_FILE"

    log()       { :; }
    log_warn()  { :; }
    log_error() { :; }
    log_debug() { :; }
    export -f log log_warn log_error log_debug

    source "$BATS_TEST_DIRNAME/../awg_common.sh"
    create_init_config
    create_server_config
    printf 'server-private\n' > "$AWG_DIR/server_private.key"
    printf 'server-public\n' > "$AWG_DIR/server_public.key"
    printf 'client-private\n' > "$KEYS_DIR/phone.private"
    printf 'client-public\n' > "$KEYS_DIR/phone.public"
    chmod 600 "$AWG_DIR/server_private.key" "$AWG_DIR/server_public.key" "$KEYS_DIR/phone.private" "$KEYS_DIR/phone.public"
    add_test_peer "phone" "10.9.9.2" "client-public"
    render_client_config "phone" "10.9.9.2" "client-private" "server-public" "$AWG_ENDPOINT" "39743"
    load_awg_params
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "server rotate-profile helper exists in RU and EN runtime" {
    grep -qF 'server_rotate_profile()' "$BATS_TEST_DIRNAME/../awg_common.sh"
    grep -qF 'server_rotate_profile()' "$BATS_TEST_DIRNAME/../awg_common_en.sh"
    grep -qF 'server rotate-profile --preset mobile|default' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    grep -qF 'server rotate-profile --preset mobile|default' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
}

@test "server_rotate_profile rotates H/S/J and preserves keys/IP/P2P metadata" {
    local old_server_priv old_client_priv old_ip old_h1
    old_server_priv=$(cat "$AWG_DIR/server_private.key")
    old_client_priv=$(cat "$KEYS_DIR/phone.private")
    old_ip=$(get_client_ipv4_from_server phone)
    old_h1="$AWG_H1"
    set_peer_p2p_ports phone "21001,21002"

    run server_rotate_profile mobile
    [ "$status" -eq 0 ]
    [ "$(cat "$AWG_DIR/server_private.key")" = "$old_server_priv" ]
    [ "$(cat "$KEYS_DIR/phone.private")" = "$old_client_priv" ]
    [ "$(get_client_ipv4_from_server phone)" = "$old_ip" ]
    [ "$(get_peer_p2p_ports phone)" = "21001,21002" ]
    load_awg_params_from_server_conf "$SERVER_CONF_FILE"
    [ "$AWG_Jc" = "3" ]
    [ "$AWG_H1" != "$old_h1" ]
    [ "$AWG_S4" -le 32 ]
    [ $((AWG_S1 + 56)) -ne "$AWG_S2" ]
    [ -f "$AWG_DIR/ROTATION_HISTORY.log" ]
}
