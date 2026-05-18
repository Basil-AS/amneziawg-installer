#!/usr/bin/env bats

load test_helper

@test "client configs use safe voice defaults" {
    create_init_config
    create_server_config
    run render_client_config "voiceclient" "10.9.9.9" "CLIENT_PRIV" "SERVER_PUB" "vpn.example.com" "39743"
    [ "$status" -eq 0 ]
    grep -q '^MTU = 1280$' "$AWG_DIR/voiceclient.conf"
    grep -q '^PersistentKeepalive = 25$' "$AWG_DIR/voiceclient.conf"
}

@test "voice optimization and diagnostics are exposed without changing NAT model" {
    grep -q 'setup_voice_udp_optimization' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'setup_voice_udp_optimization' "$BATS_TEST_DIRNAME/../awg_common.sh"
    grep -q 'nf_conntrack_udp_timeout=120' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'nf_conntrack_udp_timeout_stream=300' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'target_max=262144' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'voice-check' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    grep -q 'Mapped address = VPS public IP' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    grep -q 'MASQUERADE' "$BATS_TEST_DIRNAME/../awg_common.sh"
}


@test "voice optimization writes idempotent sysctl drop-ins from common helper" {
    local proc_root="$TEST_DIR/proc"
    local sysctl_dir="$TEST_DIR/sysctl.d"
    mkdir -p "$proc_root/net/netfilter" "$sysctl_dir"
    printf '30\n' > "$proc_root/net/netfilter/nf_conntrack_udp_timeout"
    printf '65536\n' > "$proc_root/net/netfilter/nf_conntrack_max"
    export AWG_PROC_SYS_ROOT="$proc_root"
    export AWG_SYSCTL_DIR="$sysctl_dir"
    sysctl() { :; }
    modprobe() { :; }

    run setup_voice_udp_optimization
    [ "$status" -eq 0 ]
    grep -q '^net.netfilter.nf_conntrack_udp_timeout=120$' "$sysctl_dir/99-awg-udp.conf"
    grep -q '^net.netfilter.nf_conntrack_udp_timeout_stream=300$' "$sysctl_dir/99-awg-udp.conf"
    grep -q '^net.netfilter.nf_conntrack_max=262144$' "$sysctl_dir/99-awg-conntrack.conf"

    run setup_voice_udp_optimization
    [ "$status" -eq 0 ]
    [ "$(grep -c '^net.netfilter.nf_conntrack_udp_timeout=120$' "$sysctl_dir/99-awg-udp.conf")" -eq 1 ]
    [ "$(grep -c '^net.netfilter.nf_conntrack_max=262144$' "$sysctl_dir/99-awg-conntrack.conf")" -eq 1 ]
}
