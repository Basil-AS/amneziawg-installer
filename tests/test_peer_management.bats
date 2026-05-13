#!/usr/bin/env bats
# Tests for add_peer_to_server() and remove_peer_from_server() in awg_common.sh

load test_helper

# --- add_peer_to_server ---

@test "add_peer: adds peer to config" {
    create_server_config
    add_peer_to_server "test_client" "PUBKEY123" "10.9.9.2"
    grep -q "#_Name = test_client" "$SERVER_CONF_FILE"
    grep -q "PublicKey = PUBKEY123" "$SERVER_CONF_FILE"
    grep -q "AllowedIPs = 10.9.9.2/32" "$SERVER_CONF_FILE"
}

@test "add_peer: writes IPv6 and P2P metadata when provided" {
    create_server_config
    add_peer_to_server "dual_client" "PUBKEYV6" "10.9.9.9" "fd12:3456:789a:1::9" "20009,20265,20521"
    grep -q "#_Name = dual_client" "$SERVER_CONF_FILE"
    grep -q "#_P2PPorts = 20009,20265,20521" "$SERVER_CONF_FILE"
    grep -q "AllowedIPs = 10.9.9.9/32, fd12:3456:789a:1::9/128" "$SERVER_CONF_FILE"
}

@test "add_peer: rejects duplicate name" {
    create_server_config
    add_test_peer "existing" "10.9.9.2"
    run add_peer_to_server "existing" "NEWKEY" "10.9.9.3"
    [ "$status" -eq 1 ]
}

@test "add_peer: sets permissions 600" {
    # stat format differs across platforms; check on Linux only
    [[ "$(uname -s)" == "Linux" ]] || skip "stat format differs on non-Linux"
    create_server_config
    add_peer_to_server "test_client" "PUBKEY123" "10.9.9.2"
    local perms
    perms=$(stat -c %a "$SERVER_CONF_FILE")
    [ "$perms" = "600" ]
}

@test "add_peer: rejects missing arguments" {
    create_server_config
    run add_peer_to_server "" "PUBKEY" "10.9.9.2"
    [ "$status" -eq 1 ]
    run add_peer_to_server "name" "" "10.9.9.2"
    [ "$status" -eq 1 ]
    run add_peer_to_server "name" "PUBKEY" ""
    [ "$status" -eq 1 ]
}

# --- remove_peer_from_server ---

@test "remove_peer: removes existing peer" {
    require_flock
    create_server_config
    add_test_peer "to_remove" "10.9.9.2"
    remove_peer_from_server "to_remove"
    ! grep -q "#_Name = to_remove" "$SERVER_CONF_FILE"
}

@test "remove_peer: error on non-existent peer" {
    create_server_config
    run remove_peer_from_server "ghost"
    [ "$status" -eq 1 ]
}

@test "remove_peer: preserves other peers" {
    require_flock
    create_server_config
    add_test_peer "keep_me" "10.9.9.2"
    add_test_peer "remove_me" "10.9.9.3"
    add_test_peer "also_keep" "10.9.9.4"
    remove_peer_from_server "remove_me"
    grep -q "#_Name = keep_me" "$SERVER_CONF_FILE"
    grep -q "#_Name = also_keep" "$SERVER_CONF_FILE"
    ! grep -q "#_Name = remove_me" "$SERVER_CONF_FILE"
}

@test "remove_peer: no excessive trailing newlines after removal" {
    require_flock
    create_server_config
    add_test_peer "c1" "10.9.9.2"
    add_test_peer "c2" "10.9.9.3"
    remove_peer_from_server "c2"
    # cat -s should have squeezed multiple blank lines
    local blank_count
    blank_count=$(tail -5 "$SERVER_CONF_FILE" | grep -c '^$' || true)
    [ "$blank_count" -le 2 ]
}
