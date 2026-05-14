#!/usr/bin/env bats

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
    grep -q 'dns-panel' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -q 'restartDns' "$BATS_TEST_DIRNAME/../web/app.js"
}
