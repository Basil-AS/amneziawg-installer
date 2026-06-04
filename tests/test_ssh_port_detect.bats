#!/usr/bin/env bats
# SSH lockout guard: detect real SSH ports before enabling/updating UFW.

bats_require_minimum_version 1.5.0

RU_SCRIPT="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
EN_SCRIPT="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"

_load_function() {
    local script="$1" name="$2"
    local out="$BATS_TEST_TMPDIR/${name}.bash"
    awk "/^${name}\\(\\) \\{/,/^\\}/" "$script" > "$out"
    # shellcheck disable=SC1090
    source "$out"
}

_load_firewall_functions() {
    local script="$1"
    _load_function "$script" detect_ssh_ports
    _load_function "$script" setup_improved_firewall
    export -f detect_ssh_ports setup_improved_firewall
}

setup() {
    log() { :; }
    log_warn() { :; }
    log_error() { :; }
    log_debug() { :; }
    log ""
    log_warn ""
    log_error ""
    log_debug ""
    export -f log log_warn log_error log_debug
    unset CLI_SSH_PORT SSH_CONNECTION
}

@test "RU detect_ssh_ports accepts a single --ssh-port override" {
    _load_function "$RU_SCRIPT" detect_ssh_ports
    CLI_SSH_PORT=2222
    run detect_ssh_ports
    [ "$output" = "2222" ]
}

@test "RU detect_ssh_ports accepts comma-separated ports and removes duplicates" {
    _load_function "$RU_SCRIPT" detect_ssh_ports
    CLI_SSH_PORT="2222,22,2222"
    run detect_ssh_ports
    [ "$output" = "2222 22" ]
}

@test "RU detect_ssh_ports falls back to 22 on invalid override" {
    _load_function "$RU_SCRIPT" detect_ssh_ports
    CLI_SSH_PORT="0,65536,abc"
    run detect_ssh_ports
    [ "$output" = "22" ]
}

@test "RU detect_ssh_ports reads sshd -T ports and listenaddress ports" {
    _load_function "$RU_SCRIPT" detect_ssh_ports
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/sshd" <<'EOF'
#!/usr/bin/env bash
printf 'port 22\nlistenaddress 0.0.0.0:2222\nlistenaddress [::]:2200\n'
EOF
    cat > "$BATS_TEST_TMPDIR/bin/ss" <<'EOF'
#!/usr/bin/env bash
:
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/sshd" "$BATS_TEST_TMPDIR/bin/ss"
    export -f detect_ssh_ports
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c detect_ssh_ports
    [ "$output" = "22 2222 2200" ]
}

@test "RU detect_ssh_ports merges ss socket and current SSH session port" {
    _load_function "$RU_SCRIPT" detect_ssh_ports
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/sshd" <<'EOF'
#!/usr/bin/env bash
printf 'port 22\n'
EOF
    cat > "$BATS_TEST_TMPDIR/bin/ss" <<'EOF'
#!/usr/bin/env bash
printf 'LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=1,fd=3))\n'
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/sshd" "$BATS_TEST_TMPDIR/bin/ss"
    export -f detect_ssh_ports
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" SSH_CONNECTION="198.51.100.10 50000 203.0.113.20 2022" bash -c detect_ssh_ports
    [ "$output" = "22 2222 2022" ]
}

@test "EN detect_ssh_ports mirrors RU override behavior" {
    _load_function "$EN_SCRIPT" detect_ssh_ports
    CLI_SSH_PORT="2222,22"
    run detect_ssh_ports
    [ "$output" = "2222 22" ]
}

_firewall_mocks() {
    UFW_CALLS="$BATS_TEST_TMPDIR/ufw_calls"
    : > "$UFW_CALLS"
    UFW_STATE="${1:-inactive}"
    ufw() {
        echo "$*" >> "$UFW_CALLS"
        case "$1" in
            status)
                if [[ "$UFW_STATE" == "active" ]]; then
                    echo "Status: active"
                else
                    echo "Status: inactive"
                fi
                ;;
            *) return 0 ;;
        esac
    }
    ip() { echo "1.1.1.1 dev eth0 src 10.0.0.1 uid 0"; }
    command() { return 0; }
    install_packages() { return 0; }
    touch() { return 0; }
    sleep() { return 0; }
    export -f ufw ip command install_packages touch sleep
    AWG_PORT=39743
    AWG_DIR="$BATS_TEST_TMPDIR"
    AUTO_YES=1
    AWG_WEB_ENABLED=0
    AWG_ADGUARD_ENABLED=0
    export UFW_CALLS UFW_STATE AWG_PORT AWG_DIR AUTO_YES AWG_WEB_ENABLED AWG_ADGUARD_ENABLED
}

@test "RU firewall setup opens custom SSH port when UFW is inactive" {
    _load_firewall_functions "$RU_SCRIPT"
    _firewall_mocks inactive
    CLI_SSH_PORT=2222
    export CLI_SSH_PORT
    run bash -c 'setup_improved_firewall'
    [ "$status" -eq 0 ]
    grep -q 'limit 2222/tcp' "$UFW_CALLS"
    run grep -q 'limit 22/tcp' "$UFW_CALLS"
    [ "$status" -ne 0 ]
}

@test "RU firewall setup opens detected SSH ports when UFW is already active" {
    _load_firewall_functions "$RU_SCRIPT"
    _firewall_mocks active
    CLI_SSH_PORT="2222,2022"
    export CLI_SSH_PORT
    run bash -c 'setup_improved_firewall'
    [ "$status" -eq 0 ]
    grep -q 'limit 2222/tcp' "$UFW_CALLS"
    grep -q 'limit 2022/tcp' "$UFW_CALLS"
}

@test "EN firewall setup opens custom SSH port when UFW is inactive" {
    _load_firewall_functions "$EN_SCRIPT"
    _firewall_mocks inactive
    CLI_SSH_PORT=2222
    export CLI_SSH_PORT
    run bash -c 'setup_improved_firewall'
    [ "$status" -eq 0 ]
    grep -q 'limit 2222/tcp' "$UFW_CALLS"
    run grep -q 'limit 22/tcp' "$UFW_CALLS"
    [ "$status" -ne 0 ]
}

@test "structural: both installers expose --ssh-port help and parser" {
    grep -q -- '--ssh-port=' "$RU_SCRIPT"
    grep -q -- '--ssh-port=' "$EN_SCRIPT"
    grep -qF "CLI_SSH_PORT=\"\${1#*=}\"" "$RU_SCRIPT"
    grep -qF "CLI_SSH_PORT=\"\${1#*=}\"" "$EN_SCRIPT"
}

@test "structural: both installers inspect sshd_config.d drop-ins" {
    grep -q 'sshd_config.d/\*.conf' "$RU_SCRIPT"
    grep -q 'sshd_config.d/\*.conf' "$EN_SCRIPT"
}

@test "structural: no hardcoded ufw limit 22 command remains" {
    run grep -cE '^[[:space:]]*ufw limit 22/tcp' "$RU_SCRIPT"
    [ "$output" -eq 0 ]
    run grep -cE '^[[:space:]]*ufw limit 22/tcp' "$EN_SCRIPT"
    [ "$output" -eq 0 ]
}

@test "structural: both installers loop ufw limit over detected ports" {
    grep -q "ufw limit \"\${_sp}/tcp\"" "$RU_SCRIPT"
    grep -q "ufw limit \"\${_sp}/tcp\"" "$EN_SCRIPT"
}
