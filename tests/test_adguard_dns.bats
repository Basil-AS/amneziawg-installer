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
    grep -q '^AllowedIPs = .*10\.9\.9\.1/32' "$AWG_DIR/dnsclient.conf"
}

@test "render_client_config keeps route-all unchanged for AdGuard DNS" {
    create_init_config
    cat >> "$CONFIG_FILE" <<'CONF'
export ALLOWED_IPS_MODE=1
export ALLOWED_IPS='0.0.0.0/0'
export AWG_DNS_MODE='adguard'
CONF
    create_server_config
    run render_client_config "allroute" "10.9.9.10" "CLIENT_PRIV" "SERVER_PUB" "vpn.example.com" "39743"
    [ "$status" -eq 0 ]
    grep -q '^AllowedIPs = 0\.0\.0\.0/0$' "$AWG_DIR/allroute.conf"
}

@test "custom AllowedIPs includes tunnel-local DNS route without duplicates" {
    create_init_config
    create_server_config
    export AWG_DNS_MODE=custom
    export AWG_CUSTOM_DNS="10.9.9.1, 1.1.1.1"
    export ALLOWED_IPS_MODE=3
    export ALLOWED_IPS="203.0.113.0/24, 10.9.9.1/32"
    run render_client_config "customdns" "10.9.9.11" "CLIENT_PRIV" "SERVER_PUB" "vpn.example.com" "39743"
    [ "$status" -eq 0 ]
    [ "$(grep -o '10\.9\.9\.1/32' "$AWG_DIR/customdns.conf" | wc -l)" -eq 1 ]
}

@test "IPv6 tunnel-local DNS route is added when needed" {
    create_init_config
    cat >> "$CONFIG_FILE" <<'CONF'
export AWG_DNS_MODE='custom'
export AWG_CUSTOM_DNS='fd12:3456:789a:1::1'
export AWG_IPV6_ENABLED=1
export AWG_IPV6_SUBNET='fd12:3456:789a:1::/64'
export ALLOWED_IPS_MODE=3
export ALLOWED_IPS='203.0.113.0/24'
CONF
    create_server_config
    run render_client_config "v6dns" "10.9.9.12" "CLIENT_PRIV" "SERVER_PUB" "vpn.example.com" "39743" "fd12:3456:789a:1::12"
    [ "$status" -eq 0 ]
    grep -q 'fd12:3456:789a:1::1/128' "$AWG_DIR/v6dns.conf"
}

@test "WireSock hints are comments and default off" {
    create_init_config
    create_server_config
    run render_client_config "plain" "10.9.9.13" "CLIENT_PRIV" "SERVER_PUB" "vpn.example.com" "39743"
    [ "$status" -eq 0 ]
    if grep -q '#@ws:' "$AWG_DIR/plain.conf"; then
        fail "WireSock hints must be off by default"
    fi
    export AWG_WIRESOCK_HINTS=mobile
    run render_client_config "wiresock" "10.9.9.14" "CLIENT_PRIV" "SERVER_PUB" "vpn.example.com" "39743"
    [ "$status" -eq 0 ]
    grep -q '^# WireSock compatibility hints' "$AWG_DIR/wiresock.conf"
    grep -q '^#@ws:Id = bag\.itunes\.apple\.com$' "$AWG_DIR/wiresock.conf"
    grep -q '^#@ws:Ip = quic$' "$AWG_DIR/wiresock.conf"
    grep -q '^#@ws:Ib = curl$' "$AWG_DIR/wiresock.conf"
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

@test "installer renders curated AdGuard Home config and validates it with binary" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"

    grep -qF '/opt/AdGuardHome' "$installer"
    grep -qF 'AdGuardHome.yaml' "$installer"
    grep -qF 'AdGuardHome.service' "$installer"
    grep -qF "\"\$ag_bin\" --check-config -c \"\$tmp_conf\" -w \"\$ag_dir\"" "$installer"
    grep -qF 'upstream_mode: parallel' "$installer"
    grep -qF 'https://dns.adguard-dns.com/dns-query' "$installer"
    grep -qF 'https://dns.alidns.com/dns-query' "$installer"
    grep -qF 'https://dns.cloudflare.com/dns-query' "$installer"
    grep -qF 'https://security.cloudflare-dns.com/dns-query' "$installer"
    grep -qF 'https://doh.dns.sb/dns-query' "$installer"
    grep -qF 'https://dns.pub/dns-query' "$installer"
    grep -qF 'https://dns.google/dns-query' "$installer"
    grep -qF 'https://dns.quad9.net/dns-query' "$installer"
    grep -qF 'https://wikimedia-dns.org/dns-query' "$installer"
    grep -qF '1.1.1.1' "$installer"
    grep -qF '2606:4700:4700::1111' "$installer"
    grep -qF '9.9.9.10' "$installer"
    grep -qF '2620:fe::10' "$installer"
    grep -qF '94.140.14.14' "$installer"
    grep -qF '2a10:50c0::ad1:ff' "$installer"
    grep -qF '223.5.5.5' "$installer"
    grep -qF '2400:3200::1' "$installer"
    grep -qF '2001:4860:4860::8888' "$installer"
    grep -qF '2a09::' "$installer"
    grep -qF '2402:4e00::' "$installer"
    grep -qF 'aaaa_disabled: false' "$installer"
    grep -qF 'enable_dnssec: true' "$installer"
    grep -qF 'cache_size: 83886080' "$installer"
    grep -qF 'cache_optimistic: true' "$installer"
    grep -qF 'refuse_any: true' "$installer"
    grep -qF 'version.bind' "$installer"
    grep -qF 'id.server' "$installer"
    grep -qF 'hostname.bind' "$installer"
    grep -qF 'ipaddress.ip_interface(os.environ.get("AWG_TUNNEL_SUBNET", "10.9.9.1/24"))' "$installer"
    grep -qF 'allowed_clients = [str(tunnel.network)]' "$installer"
    grep -qF 'bind_hosts.append(str(v6_net.network_address + 1))' "$installer"
    grep -qF 'allowed_clients.append(str(v6_net))' "$installer"
    grep -qF '"||doubleclick.net^"' "$installer"
    grep -qF '"||smetrics.samsung.com^"' "$installer"
    grep -qF 'extract_user_rules(lines)' "$installer"
}

@test "curated AdGuard config excludes Yandex DNS and unfiltered AdGuard upstreams" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"

    if grep -qF 'https://unfiltered.adguard-dns.com/dns-query' "$installer"; then
        fail "unfiltered AdGuard upstream must not be enabled"
    fi
    if grep -qF 'common.dot.dns.yandex.net' "$installer"; then
        fail "Yandex DNS must not be used"
    fi
    if grep -qF '77.88.' "$installer"; then
        fail "Yandex IPv4 bootstrap/upstream must not be used"
    fi
    if grep -qF '2a02:6b8::feed' "$installer"; then
        fail "Yandex IPv6 bootstrap/upstream must not be used"
    fi
    if grep -qF '#https://' "$installer"; then
        fail "commented upstreams must not be rendered as string values"
    fi
}

@test "curated AdGuard filters enable baseline blocking and keep aggressive regional lists disabled" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"

    grep -qF 'AdGuard DNS Filter' "$installer"
    grep -qF 'AdGuard Tracking Protection' "$installer"
    grep -qF 'OISD - Big' "$installer"
    grep -qF '1Hosts - Lite' "$installer"
    grep -qF 'CERT Polska - Dangerous Websites' "$installer"
    grep -qF 'Hoshsadiq - NoCoin Adblock List' "$installer"
    grep -qF 'WindowsSpyBlocker - Telemetry' "$installer"
    grep -qF 'Perflyst SmartTV' "$installer"
    grep -qF 'NoADS_RU' "$installer"
    grep -qF 'AdGuard Russian Filter (ru)' "$installer"
    grep -qF 'RU AdList classic' "$installer"
    grep -qF 'RU AdList BitBlock' "$installer"
    grep -qF 'Hagezi - Pro' "$installer"
    grep -qF 'HaGeZi'\''s Ultimate Blocklist' "$installer"
    grep -qF 'hagezi Multi PRO' "$installer"
    grep -qF 'HaGeZi'\''s Anti-Piracy Blocklist' "$installer"
    grep -qF 'AdguardTeam - CNAME Clickthroughs' "$installer"
    grep -qF 'AdguardTeam - CNAME Microsites' "$installer"
    grep -qF 'Kboghdady - YouTube Ads DNS' "$installer"
    grep -qF 'querylog:' "$installer"
    grep -qF 'statistics:' "$installer"
    grep -qF 'interval: 2160h' "$installer"
}

@test "curated AdGuard renderer preserves generated users and persistent clients" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"

    grep -qF "AG_HASH=\$(AG_PASSWORD=\"\$AG_PASSWORD\" python3 - <<" "$installer"
    grep -qF 'bcrypt.hashpw(password, bcrypt.gensalt' "$installer"
    grep -qF 'render_users(lines)' "$installer"
    grep -qF 'extract_clients_persistent(lines)' "$installer"
    grep -qF 'runtime_sources:' "$installer"
    if grep -Eq "password: *\\\\\$2[aby]\\\\\$" "$installer"; then
        fail "installer must not carry a static copied bcrypt hash"
    fi
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
