#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031
# Tests for get_next_client_ip() in awg_common.sh

load test_helper

@test "get_next_client_ip: returns .2 for empty config" {
    require_grep_P
    export AWG_TUNNEL_SUBNET="10.9.9.1/24"
    create_server_config
    run get_next_client_ip
    [ "$status" -eq 0 ]
    [ "$output" = "10.9.9.2" ]
}

@test "get_next_client_ip: returns .3 when .2 taken" {
    require_grep_P
    export AWG_TUNNEL_SUBNET="10.9.9.1/24"
    create_server_config
    add_test_peer "client1" "10.9.9.2"
    run get_next_client_ip
    [ "$status" -eq 0 ]
    [ "$output" = "10.9.9.3" ]
}

@test "get_next_client_ip: skips .1 (server)" {
    export AWG_TUNNEL_SUBNET="10.9.9.1/24"
    create_server_config
    run get_next_client_ip
    [ "$status" -eq 0 ]
    [ "$output" != "10.9.9.1" ]
}

@test "get_next_client_ip: finds gap in sequence" {
    require_grep_P
    export AWG_TUNNEL_SUBNET="10.9.9.1/24"
    create_server_config
    add_test_peer "c1" "10.9.9.2"
    add_test_peer "c2" "10.9.9.3"
    # skip .4
    add_test_peer "c3" "10.9.9.5"
    run get_next_client_ip
    [ "$status" -eq 0 ]
    [ "$output" = "10.9.9.4" ]
}

@test "get_next_client_ip: reuses fully free deleted slot" {
    require_grep_P
    export AWG_TUNNEL_SUBNET="10.9.9.1/24"
    create_server_config
    for i in $(seq 2 24); do
        add_test_peer "c$i" "10.9.9.$i"
    done
    add_test_peer "after" "10.9.9.26"
    run get_next_client_ip
    [ "$status" -eq 0 ]
    [ "$output" = "10.9.9.25" ]
}

@test "get_next_client_ip: skips slot reserved by leftover client config" {
    require_grep_P
    export AWG_TUNNEL_SUBNET="10.9.9.1/24"
    create_server_config
    for i in $(seq 2 24); do
        add_test_peer "c$i" "10.9.9.$i"
    done
    add_test_peer "after" "10.9.9.26"
    printf 'Address = 10.9.9.25/32\n' > "$AWG_DIR/orphan.conf"
    run get_next_client_ip
    [ "$status" -eq 0 ]
    [ "$output" = "10.9.9.27" ]
}

@test "get_next_client_ip: custom subnet" {
    require_grep_P
    export AWG_TUNNEL_SUBNET="172.16.0.1/24"
    create_server_config
    run get_next_client_ip
    [ "$status" -eq 0 ]
    [ "$output" = "172.16.0.2" ]
}

@test "get_next_client_ip: works without config file" {
    export AWG_TUNNEL_SUBNET="10.9.9.1/24"
    rm -f "$SERVER_CONF_FILE"
    run get_next_client_ip
    [ "$status" -eq 0 ]
    [ "$output" = "10.9.9.2" ]
}

@test "get_next_client_ipv6: returns ::2 for empty dual-stack config" {
    command -v python3 &>/dev/null || skip "python3 not available"
    export AWG_IPV6_ENABLED=1
    export AWG_IPV6_SUBNET="fd12:3456:789a:1::/64"
    create_server_config
    run get_next_client_ipv6
    [ "$status" -eq 0 ]
    [ "$output" = "fd12:3456:789a:1::2" ]
}

@test "get_next_client_ipv6: skips used IPv6 addresses" {
    command -v python3 &>/dev/null || skip "python3 not available"
    export AWG_IPV6_ENABLED=1
    export AWG_IPV6_SUBNET="fd12:3456:789a:1::/64"
    create_server_config
    cat >> "$SERVER_CONF_FILE" <<'EOF'

[Peer]
#_Name = v6used
PublicKey = PUB
AllowedIPs = 10.9.9.2/32, fd12:3456:789a:1::2/128
EOF
    run get_next_client_ipv6
    [ "$status" -eq 0 ]
    [ "$output" = "fd12:3456:789a:1::3" ]
}

@test "get_server_ipv6_address: ndp mode uses ::100 instead of gateway-like ::1" {
    command -v python3 &>/dev/null || skip "python3 not available"
    export AWG_IPV6_ENABLED=1
    export AWG_IPV6_MODE="ndp"
    export AWG_IPV6_MODE_EFFECTIVE="ndp"
    export AWG_IPV6_SUBNET="2a09:9340:808:4::/64"
    run get_server_ipv6_address
    [ "$status" -eq 0 ]
    [ "$output" = "2a09:9340:808:4::100" ]
}

@test "get_next_client_ipv6: ndp mode starts after server ::100 and skips WAN/gateway/existing clients" {
    command -v python3 &>/dev/null || skip "python3 not available"
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/ip" <<'EOF'
#!/bin/bash
if [[ "$*" == "-6 -o addr show dev ens18 scope global" ]]; then
    echo "2: ens18 inet6 2a09:9340:808:4::2/64 scope global"
    exit 0
fi
if [[ "$*" == "-6 route show default" ]]; then
    echo "default via 2a09:9340:808:4::1 dev ens18"
    exit 0
fi
exit 0
EOF
    chmod +x "$TEST_DIR/bin/ip"
    export PATH="$TEST_DIR/bin:$PATH"
    get_main_nic(){ echo ens18; }
    export -f get_main_nic
    export AWG_IPV6_ENABLED=1
    export AWG_IPV6_MODE="ndp"
    export AWG_IPV6_MODE_EFFECTIVE="ndp"
    export AWG_IPV6_SUBNET="2a09:9340:808:4::/64"
    create_server_config
    cat >> "$SERVER_CONF_FILE" <<'EOF'

[Peer]
#_Name = existing
PublicKey = PUB
AllowedIPs = 10.9.9.2/32, 2a09:9340:808:4::101/128
EOF
    run get_next_client_ipv6
    [ "$status" -eq 0 ]
    [ "$output" = "2a09:9340:808:4::102" ]
}

@test "allocate_p2p_ports_for_ipv4: allocates three deterministic ports" {
    export AWG_P2P_BASE_PORT=20000
    export AWG_P2P_PORTS_PER_CLIENT=3
    create_server_config
    run allocate_p2p_ports_for_ipv4 "10.9.9.5" 3
    [ "$status" -eq 0 ]
    [ "$output" = "20005,20261,20517" ]
}

@test "allocate_p2p_ports_for_ipv4: reuses deterministic ports for free .25 slot" {
    export AWG_P2P_BASE_PORT=20000
    export AWG_P2P_PORTS_PER_CLIENT=3
    create_server_config
    run allocate_p2p_ports_for_ipv4 "10.9.9.25" 3
    [ "$status" -eq 0 ]
    [ "$output" = "20025,20281,20537" ]
}

@test "allocate_p2p_ports_for_ipv4: skips stale P2P hook ports" {
    export AWG_P2P_BASE_PORT=20000
    export AWG_P2P_PORTS_PER_CLIENT=3
    create_server_config
    cat > "$AWG_DIR/p2p_rules.sh" <<'EOF'
iptables -t nat -A PREROUTING -p tcp --dport 20025 -j DNAT --to-destination 10.9.9.25:20025
iptables -t nat -A PREROUTING -p tcp --dport 20281 -j DNAT --to-destination 10.9.9.25:20281
iptables -t nat -A PREROUTING -p tcp --dport 20537 -j DNAT --to-destination 10.9.9.25:20537
EOF
    run allocate_p2p_ports_for_ipv4 "10.9.9.25" 3
    [ "$status" -eq 0 ]
    [ "$output" != "20025,20281,20537" ]
}

@test "validate_p2p_port: limits ports to managed P2P range" {
    export AWG_P2P_BASE_PORT=20000
    validate_p2p_port 20001
    validate_p2p_port 21024
    run validate_p2p_port 21025
    [ "$status" -eq 1 ]
}
