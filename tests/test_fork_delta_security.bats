#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

load test_helper

@test "safe_load_config accepts fork server name" {
    create_init_config
    cat >> "$CONFIG_FILE" <<'CONF'
export AWG_SERVER_NAME='Новое Имя'
CONF
    safe_load_config "$CONFIG_FILE"
    [ "$AWG_SERVER_NAME" = "Новое Имя" ]
}

@test "render_client_config writes server name after Interface" {
    create_init_config
    create_server_config
    export AWG_SERVER_NAME="MyVPN"
    run render_client_config "named" "10.9.9.9" "CLIENT_PRIV" "SERVER_PUB" "vpn.example.com" "39743"
    [ "$status" -eq 0 ]
    sed -n '1,2p' "$AWG_DIR/named.conf" | grep -q '^# Name = MyVPN$'
}

@test "generate_firewall_scripts supports routed ndp and nat66 modes" {
    create_server_config
    export AWG_IPV6_ENABLED=1
    export AWG_IPV6_SUBNET="fd12:3456:789a:1::/64"

    export AWG_IPV6_MODE="nat66"
    run generate_firewall_scripts "eth0"
    [ "$status" -eq 0 ]
    grep -q 'IPV6_MODE="nat66"' "$AWG_DIR/postup.sh"
    grep -q 'MASQUERADE' "$AWG_DIR/postup.sh"

    export AWG_IPV6_MODE="ndp"
    run generate_firewall_scripts "eth0"
    [ "$status" -eq 0 ]
    grep -q 'IPV6_MODE="ndp"' "$AWG_DIR/postup.sh"
    grep -q 'IPV6_MODE" == "nat66"' "$AWG_DIR/postup.sh"

    export AWG_IPV6_MODE="routed"
    run generate_firewall_scripts "eth0"
    [ "$status" -eq 0 ]
    grep -q 'IPV6_MODE="routed"' "$AWG_DIR/postup.sh"
    grep -q 'IPV6_MODE" == "nat66"' "$AWG_DIR/postup.sh"
}

@test "installer ndppd config is managed only for effective ndp mode with awg iface rule" {
    local ru="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    local en="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -qF 'installer_ipv6_effective_mode_is_ndp' "$ru"
    grep -qF 'installer_ipv6_effective_mode_is_ndp' "$en"
    grep -qF 'Managed by AmneziaWG installer' "$ru"
    grep -qF 'Managed by AmneziaWG installer' "$en"
    grep -qF "rule \${AWG_IPV6_SUBNET}" "$ru"
    grep -qF "rule \${AWG_IPV6_SUBNET}" "$en"
    grep -qF "        iface \${vpn}" "$ru"
    grep -qF "        iface \${vpn}" "$en"
    if grep -qF 'AWG_IPV6_MODE:-}" == "native"' "$en"; then
        fail "EN installer must not use obsolete native mode for ndppd"
    fi
}

@test "generate_vpn_uri writes server name and defaultName" {
    command -v python3 &>/dev/null || skip "python3 not available"
    perl -MCompress::Zlib -MMIME::Base64 -e '1' 2>/dev/null || skip "perl Compress::Zlib/MIME::Base64 not available"
    create_init_config
    create_server_config
    export AWG_SERVER_NAME="MyVPN"
    echo "TESTSERVERPUBKEY_PLACEHOLDER" > "$AWG_DIR/server_public.key"
    cat > "$AWG_DIR/nameduri.conf" <<'CONF'
[Interface]
PrivateKey = TESTCLIENTPRIVKEY
Address = 10.9.9.2/32
DNS = 10.9.9.1

[Peer]
PublicKey = TESTSERVERPUBKEY_PLACEHOLDER
Endpoint = 1.2.3.4:39743
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 33
CONF
    run generate_vpn_uri "nameduri"
    [ "$status" -eq 0 ]
    python3 - "$AWG_DIR/nameduri.vpnuri" <<'PY'
import base64, json, struct, sys, zlib
uri = open(sys.argv[1], encoding="utf-8").read().strip().replace("vpn://", "")
raw = base64.urlsafe_b64decode(uri + "=" * (-len(uri) % 4))
struct.unpack(">I", raw[:4])[0]
outer = json.loads(zlib.decompress(raw[4:]))
assert outer["name"] == "MyVPN"
assert outer["defaultName"] == "MyVPN"
PY
}
