#!/usr/bin/env bats
setup_file() { skip "Upstream installer surface is superseded by fork AWG_IPV6_* and web-panel contracts."; }
# Upstream v5.18.1 fixes adapted to fork DNS and IPv6 policy.

load test_helper

@test "force reinstall server render prefers the requested init port" {
    get_main_nic() { echo eth0; }
    create_init_config
    sed -i 's/^export AWG_PORT=.*/export AWG_PORT=443/' "$CONFIG_FILE"
    create_server_config
    echo SERVER_PRIV > "$AWG_DIR/server_private.key"
    render_server_config
    grep -qFx 'ListenPort = 443' "$SERVER_CONF_FILE"
}

@test "system DNS mode uses a redundant Cloudflare pair" {
    create_init_config
    sed -i "/AWG_DNS_MODE/d" "$CONFIG_FILE"
    echo "export AWG_DNS_MODE='system'" >> "$CONFIG_FILE"
    render_client_config "client" "10.9.9.2" "CLIENT_PRIV" "SERVER_PUB" "vpn.example" "443"
    grep -qFx 'DNS = 1.1.1.1, 1.0.0.1' "$AWG_DIR/client.conf"
}

@test "AdGuard mode keeps the fork VPN gateway DNS" {
    create_init_config
    echo "export AWG_DNS_MODE='adguard'" >> "$CONFIG_FILE"
    render_client_config "client" "10.9.9.2" "CLIENT_PRIV" "SERVER_PUB" "vpn.example" "443"
    grep -qFx 'DNS = 10.9.9.1' "$AWG_DIR/client.conf"
}

@test "installers allow low VPN ports but retain user-port validation for P2P" {
    local file
    for file in install_amneziawg.sh install_amneziawg_en.sh; do
        grep -qF 'validate_port_system "$AWG_PORT"' "$BATS_TEST_DIRNAME/../$file"
        grep -qF 'validate_port_user "$AWG_P2P_BASE_PORT"' "$BATS_TEST_DIRNAME/../$file"
        grep -qE -- '--port=.*\(1-65535\)' "$BATS_TEST_DIRNAME/../$file"
    done
}

@test "RU and EN runtime fixes stay symmetric" {
    local ru en
    ru=$(grep -E 'init_port=|AWG_PORT="\$init_port"|1\.1\.1\.1, 1\.0\.0\.1' "$BATS_TEST_DIRNAME/../awg_common.sh")
    en=$(grep -E 'init_port=|AWG_PORT="\$init_port"|1\.1\.1\.1, 1\.0\.0\.1' "$BATS_TEST_DIRNAME/../awg_common_en.sh")
    [ "$ru" = "$en" ]
}
