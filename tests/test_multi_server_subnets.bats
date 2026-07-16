#!/usr/bin/env bats

load test_helper

@test "fresh-install subnet allocation is deterministic per server and mirrored" {
    local ru="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    local en="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"

    run bash -c '
        source <(sed -n "/^generate_default_tunnel_subnet() {$/,/^}$/p" "$1")
        cat(){ if [[ "$1" == "/etc/machine-id" ]]; then printf "%s\n" "server-a"; else command cat "$@"; fi; }
        hostname(){ printf "%s\n" "vpn-a"; }
        first="$(generate_default_tunnel_subnet)"
        second="$(generate_default_tunnel_subnet)"
        [[ "$first" == "$second" ]]
        python3 - "$first" <<"PY"
import ipaddress
import sys
iface = ipaddress.ip_interface(sys.argv[1])
assert iface.network.subnet_of(ipaddress.ip_network("10.64.0.0/10"))
assert iface.network.prefixlen == 24
assert iface.ip == iface.network.network_address + 1
PY
        printf "%s\n" "$first"
    ' _ "$ru"
    [ "$status" -eq 0 ]
    local first="$output"

    run bash -c '
        source <(sed -n "/^generate_default_tunnel_subnet() {$/,/^}$/p" "$1")
        cat(){ if [[ "$1" == "/etc/machine-id" ]]; then printf "%s\n" "server-b"; else command cat "$@"; fi; }
        hostname(){ printf "%s\n" "vpn-b"; }
        generate_default_tunnel_subnet
    ' _ "$ru"
    [ "$status" -eq 0 ]
    [ "$output" != "$first" ]

    run diff -u <(sed -n '/^generate_default_tunnel_subnet() {$/,/^}$/p' "$ru") \
        <(sed -n '/^generate_default_tunnel_subnet() {$/,/^}$/p' "$en")
    [ "$status" -eq 0 ]
}

@test "custom tunnel subnet drives gateway network and AdGuard DNS" {
    export AWG_TUNNEL_SUBNET="10.9.10.1/24"
    export AWG_DNS_MODE="adguard"
    export AWG_IPV6_ENABLED=0

    [ "$(awg_ipv4_gateway)" = "10.9.10.1" ]
    [ "$(awg_ipv4_network)" = "10.9.10.0/24" ]
    [ "$(awg_dns_servers)" = "10.9.10.1" ]
}

@test "web policy derives the VPN-only gateway and exact network" {
    run python3 - "$BATS_TEST_DIRNAME/../web/server.py" <<'PY'
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location("awg_web_server", sys.argv[1])
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)
server.parse_config = lambda: {"AWG_TUNNEL_SUBNET": "10.9.10.1/24"}
os.environ.pop("AWG_WEB_BIND", None)

assert server.configured_vpn_ipv4() == ("10.9.10.1", "10.9.10.0/24")
policy = server.default_access_policy()
assert policy["bind_mode"] == "vpn_only"
assert policy["bind_host"] == "10.9.10.1"
assert policy["allowed_source_cidrs"] == ["10.9.10.0/24", "127.0.0.0/8"]
PY
    [ "$status" -eq 0 ]
}

@test "migration stages a same-host-offset IPv4 cutover without touching source or IPv6" {
    local fixture="$TEST_DIR/migration"
    mkdir -p "$fixture/awg/web" "$fixture/amnezia" "$fixture/adguard" "$fixture/systemd"
    cat > "$fixture/awg/awgsetup_cfg.init" <<'EOF'
export AWG_TUNNEL_SUBNET='10.9.9.1/24'
export AWG_WEB_BIND='10.9.9.1'
EOF
    cat > "$fixture/amnezia/awg0.conf" <<'EOF'
[Interface]
Address = 10.9.9.1/24, 2a09:9340:808:4::1/64
PrivateKey = preserved-secret
[Peer]
#_Name = linux
AllowedIPs = 10.9.9.4/32, 2a09:9340:808:4::4/128
PublicKey = preserved-public
EOF
    cat > "$fixture/awg/linux.conf" <<'EOF'
[Interface]
Address = 10.9.9.4/32, 2a09:9340:808:4::4/128
PrivateKey = preserved-client-secret
[Peer]
AllowedIPs = 0.0.0.0/0
EOF
    printf '%s\n' '#!/usr/bin/env bash' 'ip route add 10.9.9.0/24 dev awg0' > "$fixture/awg/postup.sh"
    printf '%s\n' '#!/usr/bin/env bash' 'ip route del 10.9.9.0/24 dev awg0' > "$fixture/awg/postdown.sh"
    printf '%s\n' '#!/usr/bin/env bash' > "$fixture/awg/p2p_rules.sh"
    printf '%s\n' '{"bind_host":"10.9.9.1","allowed_source_cidrs":["10.9.9.0/24"]}' > "$fixture/awg/web/access_policy.json"

    local before
    before="$(sha256sum "$fixture/awg/linux.conf")"
    run bash -c '
        AWG_DIR="$1/awg"
        CONFIG_FILE="$1/awg/awgsetup_cfg.init"
        SERVER_CONF_FILE="$1/amnezia/awg0.conf"
        AWG_ADGUARD_DIR="$1/adguard"
        AWG_SYSTEMD_DIR="$1/systemd"
        source "$2"
        OLD_SUBNET="10.9.9.1/24"
        NEW_SUBNET="10.9.10.1/24"
        validate_subnet_pair
        discover_targets
        stage_candidates
        validate_stage
        grep -qF "Address = 10.9.10.4/32, 2a09:9340:808:4::4/128" "$WORK_DIR/stage$AWG_DIR/linux.conf"
        grep -qF "PrivateKey = preserved-client-secret" "$WORK_DIR/stage$AWG_DIR/linux.conf"
        grep -qF "AllowedIPs = 10.9.10.4/32, 2a09:9340:808:4::4/128" "$WORK_DIR/stage$SERVER_CONF_FILE"
        grep -qF "10.9.10.0/24" "$WORK_DIR/stage$AWG_DIR/web/access_policy.json"
        [[ "$(awk -F"\t" "{total += \$2} END {print total}" "$WORK_DIR/replacements.tsv")" -eq 9 ]]
        rm -rf "$WORK_DIR"
    ' _ "$fixture" "$BATS_TEST_DIRNAME/../scripts/migrate-tunnel-subnet.sh"
    [ "$status" -eq 0 ]
    [ "$(sha256sum "$fixture/awg/linux.conf")" = "$before" ]
    grep -qF 'Address = 10.9.9.4/32, 2a09:9340:808:4::4/128' "$fixture/awg/linux.conf"
}

@test "migration is plan-only by default and apply has an exact confirmation lock" {
    local script="$BATS_TEST_DIRNAME/../scripts/migrate-tunnel-subnet.sh"
    grep -qF 'MODE="plan"' "$script"
    grep -qF '[[ "$MODE" != "apply" ]] || apply_migration' "$script"
    grep -qF 'local expected="MIGRATE:${OLD_SUBNET}->${NEW_SUBNET}"' "$script"
    grep -qF '[[ "$CONFIRM" == "$expected" ]] || die' "$script"
    grep -qF 'automatic' <(tr '[:upper:]' '[:lower:]' < "$script")
    grep -qF '0.0.0.0/0' "$script"
}

@test "migration discovery excludes historical telemetry and GeoIP data" {
    local script="$BATS_TEST_DIRNAME/../scripts/migrate-tunnel-subnet.sh"
    grep -qF '"health_history", "geoip"' "$script"
    grep -qF '".jsonl", ".log", ".mmdb"' "$script"
}
