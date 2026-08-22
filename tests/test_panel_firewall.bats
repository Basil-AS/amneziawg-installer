#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

@test "RU and EN firewall generators keep panel reachable from VPN clients" {
    for f in awg_common.sh awg_common_en.sh; do
        local path="$BATS_TEST_DIRNAME/../$f"
        ! grep -qF 'ipt_ins FORWARD -i "\$AWG_IFACE" -d "\$panel_addr" -p tcp --dport "\$panel_port" -j REJECT' "$path"
        ! grep -qF 'ip6t_ins FORWARD -i "\$AWG_IFACE" -d "\$panel_addr" -p tcp --dport "\$panel_port" -j REJECT' "$path"
        ! grep -qF 'del_ipt FORWARD -i "\$AWG_IFACE" -d "\$panel_addr" -p tcp --dport "\$panel_port" -j REJECT' "$path"
        ! grep -qF 'del_ip6t FORWARD -i "\$AWG_IFACE" -d "\$panel_addr" -p tcp --dport "\$panel_port" -j REJECT' "$path"
        grep -qF 'ipt_ins FORWARD -i "\$AWG_IFACE" -j ACCEPT' "$path"
        grep -qF 'ip6t_ins FORWARD -i "\$AWG_IFACE" -j ACCEPT' "$path"
    done
}

@test "broad VPN forwarding remains available without panel-specific rejects" {
    for f in awg_common.sh awg_common_en.sh; do
        local path="$BATS_TEST_DIRNAME/../$f"
        run awk '
            /panel_addr.*REJECT/ { reject=1 }
            /ipt_ins FORWARD -i/ && /-j ACCEPT/ { accept=1 }
            END { exit !(accept && !reject) }
        ' "$path"
        [ "$status" -eq 0 ]
    done
}

@test "installer rejects reusing the panel domain as the VPN endpoint" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        grep -qF 'Web Panel domain must be separate from the VPN endpoint' "$BATS_TEST_DIRNAME/../$f"
        grep -qF '"${AWG_WEB_DOMAIN}" == "${AWG_ENDPOINT:-}"' "$BATS_TEST_DIRNAME/../$f"
    done
}

@test "firewall still keeps VPN NAT and IPv6 routing enabled" {
    for f in awg_common.sh awg_common_en.sh; do
        local path="$BATS_TEST_DIRNAME/../$f"
        grep -qF 'ipt_add nat POSTROUTING -o "\$NIC" -j MASQUERADE' "$path"
        grep -qF 'ip6t_ins FORWARD -o "\$AWG_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT' "$path"
    done
    grep -qF 'ufw route allow in on awg0 out on' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'ufw route allow in on awg0 out on' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
}

@test "client rendering keeps panel domain out of generated VPN endpoints" {
    for f in awg_common.sh awg_common_en.sh; do
        local path="$BATS_TEST_DIRNAME/../$f"
        grep -qF 'is_panel_domain_endpoint()' "$path"
        grep -qF 'VPN endpoint cannot use the web panel domain' "$path"
        grep -qF 'is_panel_domain_endpoint "$endpoint"' "$path"
    done
}
