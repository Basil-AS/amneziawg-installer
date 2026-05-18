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
    grep -q 'nf_conntrack_udp_timeout=120' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'nf_conntrack_udp_timeout_stream=300' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'target_max=262144' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'voice-check' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    grep -q 'Mapped address = VPS public IP' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    grep -q 'MASQUERADE' "$BATS_TEST_DIRNAME/../awg_common.sh"
}
