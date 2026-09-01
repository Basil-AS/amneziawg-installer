#!/usr/bin/env bats

load test_helper

setup_family_fixture() {
    create_server_config
    cat >> "$SERVER_CONF_FILE" <<'CONF'

[Peer]
#_Name = phone
PublicKey = TESTPUBKEY_phone
AllowedIPs = 10.9.9.2/32, fd00::2/128
CONF
    cat > "$AWG_DIR/phone.conf" <<'CONF'
[Interface]
PrivateKey = TESTCLIENTPRIVKEY
Address = 10.9.9.2/32, fd00::2/128

[Peer]
PublicKey = TESTSERVERPUBKEY
AllowedIPs = 0.0.0.0/0, ::/0
CONF
    export AWG_SKIP_APPLY=1
}

@test "client family permissions preserve both addresses and disable IPv4" {
    setup_family_fixture
    run set_client_ip_family phone ipv4 off
    [ "$status" -eq 0 ]
    grep -q '^#_IPv4 = off$' "$SERVER_CONF_FILE"
    grep -q '^#_IPv4Address = 10.9.9.2/32$' "$SERVER_CONF_FILE"
    grep -q '^AllowedIPs = fd00::2/128$' "$SERVER_CONF_FILE"
    grep -q '^Address = fd00::2/128$' "$AWG_DIR/phone.conf"
}

@test "client family permissions re-enable IPv4 from saved metadata" {
    setup_family_fixture
    set_client_ip_family phone ipv4 off
    run set_client_ip_family phone ipv4 on
    [ "$status" -eq 0 ]
    grep -q '^#_IPv4 = on$' "$SERVER_CONF_FILE"
    grep -q '^AllowedIPs = 10.9.9.2/32, fd00::2/128$' "$SERVER_CONF_FILE"
    grep -q '^Address = 10.9.9.2/32, fd00::2/128$' "$AWG_DIR/phone.conf"
}

@test "client family permissions reject disabling the last family atomically" {
    setup_family_fixture
    run set_client_ip_family phone ipv4 off
    [ "$status" -eq 0 ]
    before_server=$(cat "$SERVER_CONF_FILE")
    before_client=$(cat "$AWG_DIR/phone.conf")
    run set_client_ip_family phone ipv6 off
    [ "$status" -ne 0 ]
    [ "$(cat "$SERVER_CONF_FILE")" = "$before_server" ]
    [ "$(cat "$AWG_DIR/phone.conf")" = "$before_client" ]
}

@test "legacy peers infer enabled families and RU/EN expose the command" {
    grep -q 'set_client_ip_family()' "$BATS_TEST_DIRNAME/../awg_common.sh"
    grep -q 'set_client_ip_family()' "$BATS_TEST_DIRNAME/../awg_common_en.sh"
    grep -q 'set-ip-family|family' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    grep -q 'set-ip-family|family' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
}
