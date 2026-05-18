#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

load test_helper

@test "dns helpers: adguard returns VPN IPv4 only without IPv6" {
    export AWG_DNS_MODE=adguard
    export AWG_IPV6_ENABLED=0
    run awg_dns_servers
    [ "$status" -eq 0 ]
    [ "$output" = "10.9.9.1" ]
}

@test "dns helpers: adguard includes server IPv6 when dual-stack is enabled" {
    export AWG_DNS_MODE=adguard
    export AWG_IPV6_ENABLED=1
    export AWG_IPV6_SUBNET="fd12:3456:789a:1::/64"
    run awg_dns_servers
    [ "$status" -eq 0 ]
    [ "$output" = "10.9.9.1, fd12:3456:789a:1::1" ]
}

@test "render_client_config writes AdGuard DNS into client config" {
    create_init_config
    create_server_config
    export AWG_DNS_MODE=adguard
    run render_client_config "dnsclient" "10.9.9.9" "CLIENT_PRIV" "SERVER_PUB" "vpn.example.com" "39743"
    [ "$status" -eq 0 ]
    grep -q '^DNS = 10\.9\.9\.1$' "$AWG_DIR/dnsclient.conf"
}

@test "safe_load_config accepts DNS and AdGuard fork keys" {
    create_init_config
    cat >> "$CONFIG_FILE" <<'CONF'
export AWG_DNS_MODE='adguard'
export AWG_CUSTOM_DNS='9.9.9.9, 149.112.112.112'
export AWG_ADGUARD_ENABLED=1
export AWG_ADGUARD_PORT=3000
export AWG_ADGUARD_DIR='/opt/AdGuardHome'
CONF
    safe_load_config "$CONFIG_FILE"
    [ "$AWG_DNS_MODE" = "adguard" ]
    [ "$AWG_ADGUARD_ENABLED" = "1" ]
    [ "$AWG_ADGUARD_PORT" = "3000" ]
}

@test "installer and manage expose AdGuard DNS controls" {
    grep -q -- '--enable-adguard' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q -- '--disable-adguard' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q -- '--dns-mode=MODE' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'deploy_adguard_home' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'dns set-mode' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    grep -q 'AdGuardHome.service' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
}

@test "web panel exposes DNS API and card" {
    grep -q 'api/dns' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -q 'metricDns' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -q '/api/dns' "$BATS_TEST_DIRNAME/../web/app.js"
}

@test "client hosts sync writes and removes names for AdGuard visibility" {
    create_server_config
    cat >> "$SERVER_CONF_FILE" <<'CONF'

[Peer]
#_Name = my_phone
PublicKey = TESTPHONE
AllowedIPs = 10.9.9.2/32, fd12:3456:789a:1::2/128
CONF
    run sync_clients_hosts
    [ "$status" -eq 0 ]
    grep -q '^10\.9\.9\.2 my_phone my-phone\.awg$' "$AWG_HOSTS_FILE"
    grep -q '^fd12:3456:789a:1::2 my_phone my-phone\.awg$' "$AWG_HOSTS_FILE"

    run remove_peer_from_server my_phone
    [ "$status" -eq 0 ]
    if grep -q 'my-phone\.awg' "$AWG_HOSTS_FILE"; then
        fail "client host aliases must be removed from hosts file"
    fi
}

@test "adguard client sync writes persistent clients and DNS rewrites" {
    create_server_config
    export AWG_ADGUARD_DIR="$TEST_DIR/AdGuardHome"
    mkdir -p "$AWG_ADGUARD_DIR"
    cat > "$AWG_ADGUARD_DIR/AdGuardHome.yaml" <<'CONF'
http:
  address: 10.9.9.1:3000
filtering:
  protection_enabled: true
  rewrites: []
clients:
  persistent: []
  runtime_sources:
    hosts: false
log:
  enabled: true
schema_version: 34
CONF
    cat >> "$SERVER_CONF_FILE" <<'CONF'

[Peer]
#_Name = my_phone
PublicKey = TESTPHONE
AllowedIPs = 10.9.9.2/32, fd12:3456:789a:1::2/128
CONF

    run sync_adguard_clients
    [ "$status" -eq 0 ]
    grep -q 'name: "my_phone"' "$AWG_ADGUARD_DIR/AdGuardHome.yaml"
    grep -q '        - "10.9.9.2"' "$AWG_ADGUARD_DIR/AdGuardHome.yaml"
    grep -q '        - "fd12:3456:789a:1::2"' "$AWG_ADGUARD_DIR/AdGuardHome.yaml"
    grep -q 'domain: "my-phone.awg"' "$AWG_ADGUARD_DIR/AdGuardHome.yaml"
    grep -q 'answer: "10.9.9.2"' "$AWG_ADGUARD_DIR/AdGuardHome.yaml"
    grep -q 'runtime_sources:' "$AWG_ADGUARD_DIR/AdGuardHome.yaml"
    grep -q 'hosts: true' "$AWG_ADGUARD_DIR/AdGuardHome.yaml"
}
