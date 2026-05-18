#!/bin/bash
# shellcheck disable=SC1091,SC2317
# Common test helper for awg_common.sh unit tests
# Sets up isolated temp environment for each test

# Skip helpers for platform-specific tests
require_flock() { command -v flock &>/dev/null || skip "flock not available (not Linux)"; }
require_grep_P() { echo test | grep -P "t" &>/dev/null 2>&1 || skip "grep -P not available"; }

setup() {
    TEST_DIR=$(mktemp -d)
    export AWG_DIR="$TEST_DIR"
    export CONFIG_FILE="$TEST_DIR/awgsetup_cfg.init"
    export SERVER_CONF_FILE="$TEST_DIR/awg0.conf"
    export AWG_HOSTS_FILE="$TEST_DIR/hosts"
    export KEYS_DIR="$TEST_DIR/keys"
    export EXPIRY_DIR="$TEST_DIR/expiry"
    export EXPIRY_CRON="$TEST_DIR/awg-expiry-cron"
    export AWG_IPV6_ENABLED=0
    export AWG_IPV6_MODE="legacy"
    export AWG_IPV6_SUBNET=""
    export AWG_IPV6_NDP_PROXY=0
    export AWG_P2P_ENABLED=0
    export AWG_P2P_BASE_PORT=20000
    export AWG_P2P_PORTS_PER_CLIENT=3
    mkdir -p "$KEYS_DIR" "$EXPIRY_DIR"
    printf '127.0.0.1 localhost\n' > "$AWG_HOSTS_FILE"

    # Silent log stubs
    log()       { :; }
    log_warn()  { :; }
    log_error() { :; }
    log_debug() { :; }
    export -f log log_warn log_error log_debug

    # Source the module under test
    source "$BATS_TEST_DIRNAME/../awg_common.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# Helper: create a minimal valid server config
create_server_config() {
    cat > "$SERVER_CONF_FILE" << 'CONF'
[Interface]
PrivateKey = TESTKEY
Address = 10.9.9.1/24
MTU = 1280
ListenPort = 39743
PostUp = iptables -I FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -i %i -j ACCEPT
Jc = 6
Jmin = 55
Jmax = 380
S1 = 72
S2 = 56
S3 = 32
S4 = 16
H1 = 100000-800000
H2 = 1000000-8000000
H3 = 10000000-80000000
H4 = 100000000-800000000
CONF
}

# Helper: create a minimal valid config file for safe_load_config
create_init_config() {
    cat > "$CONFIG_FILE" << 'CONF'
export AWG_PORT=39743
export AWG_TUNNEL_SUBNET='10.9.9.1/24'
export DISABLE_IPV6=1
export ALLOWED_IPS_MODE=2
export ALLOWED_IPS='0.0.0.0/5, 8.0.0.0/7'
export AWG_IPV6_ENABLED=0
export AWG_IPV6_MODE='legacy'
export AWG_IPV6_SUBNET=''
export AWG_IPV6_NDP_PROXY=0
export AWG_P2P_ENABLED=0
export AWG_P2P_BASE_PORT=20000
export AWG_P2P_PORTS_PER_CLIENT=3
export AWG_FULLCONE_NAT=0
export AWG_WEB_ENABLED=1
export AWG_WEB_PORT=8443
export AWG_WEB_BIND='10.9.9.1'
export AWG_Jc=6
export AWG_Jmin=55
export AWG_Jmax=380
export AWG_S1=72
export AWG_S2=56
export AWG_S3=32
export AWG_S4=16
export AWG_H1='100000-800000'
export AWG_H2='1000000-8000000'
export AWG_H3='10000000-80000000'
export AWG_H4='100000000-800000000'
export AWG_I1='<r 128>'
export NO_TWEAKS=0
export AWG_APPLY_MODE='syncconf'
CONF
}

# Helper: add a peer block to server config
add_test_peer() {
    local name="$1" ip="$2"
    local pubkey="${3:-TESTPUBKEY_${name}}"
    cat >> "$SERVER_CONF_FILE" << EOF

[Peer]
#_Name = ${name}
PublicKey = ${pubkey}
AllowedIPs = ${ip}/32
EOF
}
