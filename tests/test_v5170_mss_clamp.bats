#!/usr/bin/env bats
# Upstream v5.17.0 MSS clamp adapted to the fork's generated firewall hooks.

load test_helper

@test "MSS clamp is generated idempotently for IPv4 and removed on PostDown" {
    export AWG_MTU=1280
    run generate_firewall_scripts "eth0"
    [ "$status" -eq 0 ]

    grep -qF 'ipt_add mangle FORWARD -o "$AWG_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS4"' "$AWG_DIR/postup.sh"
    grep -qF 'ipt_add mangle FORWARD -i "$AWG_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS4"' "$AWG_DIR/postup.sh"
    grep -qF 'del_ipt_table mangle FORWARD -o "$AWG_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS4"' "$AWG_DIR/postdown.sh"
    grep -qF 'MSS4="1240"' "$AWG_DIR/postup.sh"
}

@test "MSS clamp derives values from a custom tunnel MTU" {
    export AWG_MTU=1420
    run generate_firewall_scripts "eth0"
    [ "$status" -eq 0 ]

    grep -qF 'MSS4="1380"' "$AWG_DIR/postup.sh"
    grep -qF 'MSS6="1360"' "$AWG_DIR/postup.sh"
}

@test "IPv6 MSS clamp follows the fork IPv6 enable gate" {
    export AWG_IPV6_ENABLED=1
    export AWG_IPV6_MODE=nat66
    export AWG_IPV6_SUBNET='fd12:3456:789a:1::/64'
    run generate_firewall_scripts "eth0"
    [ "$status" -eq 0 ]

    grep -qF 'ip6t_add mangle FORWARD -o "$AWG_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS6"' "$AWG_DIR/postup.sh"
    grep -qF 'del_ip6t_table mangle FORWARD -i "$AWG_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS6"' "$AWG_DIR/postdown.sh"
}

@test "RU and EN generated MSS rule lines stay symmetric" {
    local ru en
    ru=$(awk '/^generate_firewall_scripts\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../awg_common.sh" | grep -E 'MSS[46]|TCPMSS|del_ipt_table|del_ip6t_table' | grep -v '^[[:space:]]*#')
    en=$(awk '/^generate_firewall_scripts\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../awg_common_en.sh" | grep -E 'MSS[46]|TCPMSS|del_ipt_table|del_ip6t_table' | grep -v '^[[:space:]]*#')
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}
