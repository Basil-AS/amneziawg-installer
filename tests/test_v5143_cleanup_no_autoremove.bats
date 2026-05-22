#!/usr/bin/env bats
# Tests for cleanup_system network-safety hardening.
# shellcheck disable=SC2030,SC2031

bats_require_minimum_version 1.5.0

setup() {
    TEST_DIR=$(mktemp -d)
    TRACE="$TEST_DIR/trace"
    : > "$TRACE"
    BIN="$TEST_DIR/bin"
    mkdir -p "$BIN"
    export TRACE BIN
    export MOCK_PRE_ROUTE="default via 10.0.0.1 dev eth0"
    export MOCK_POST_ROUTE="default via 10.0.0.1 dev eth0"
    export MOCK_RECOVERY_ROUTE="default via 10.0.0.1 dev eth0"
    export MOCK_LASTDITCH_ROUTE=""
    export MOCK_LASTDITCH_ROUTE_AFTER_DHCLIENT=""
    export MOCK_PREEXISTING_HOLDS=""
    export MOCK_NETPLAN_GENERATOR_AVAILABLE=1
    export MOCK_CLOUD_INIT_INSTALLED=1

    cat > "$BIN/dpkg-query" <<'SHIM'
#!/bin/bash
echo "dpkg-query $*" >> "$TRACE"
pkg="${*: -1}"
case "$pkg" in
    cloud-init)
        [[ "${MOCK_CLOUD_INIT_INSTALLED:-1}" -eq 1 ]] && { echo "install ok installed"; exit 0; }
        exit 1
        ;;
    netplan.io|netplan-generator|systemd-resolved|netcfg|ifupdown)
        echo "install ok installed"
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
SHIM
    chmod +x "$BIN/dpkg-query"

    cat > "$BIN/ip" <<'SHIM'
#!/bin/bash
echo "ip $*" >> "$TRACE"
if [[ "$*" =~ route\ show\ default ]]; then
    count_file="$TRACE.ipcount"
    n=0
    [[ -f "$count_file" ]] && n=$(cat "$count_file")
    n=$((n + 1))
    echo "$n" > "$count_file"
    case "$n" in
        1) echo "$MOCK_PRE_ROUTE" ;;
        2) echo "$MOCK_POST_ROUTE" ;;
        10) echo "$MOCK_LASTDITCH_ROUTE" ;;
        11) echo "$MOCK_LASTDITCH_ROUTE_AFTER_DHCLIENT" ;;
        *) echo "$MOCK_RECOVERY_ROUTE" ;;
    esac
fi
exit 0
SHIM
    chmod +x "$BIN/ip"

    cat > "$BIN/apt-mark" <<'SHIM'
#!/bin/bash
echo "apt-mark $*" >> "$TRACE"
case "$1" in
    showhold) printf '%s\n' "${MOCK_PREEXISTING_HOLDS:-}" ;;
esac
exit 0
SHIM
    chmod +x "$BIN/apt-mark"

    cat > "$BIN/apt-cache" <<'SHIM'
#!/bin/bash
echo "apt-cache $*" >> "$TRACE"
if [[ "$1 $2" == "show netplan-generator" ]]; then
    [[ "${MOCK_NETPLAN_GENERATOR_AVAILABLE:-1}" -eq 1 ]] && exit 0 || exit 100
fi
exit 0
SHIM
    chmod +x "$BIN/apt-cache"

    for cmd in apt-get systemctl netplan networkctl dhclient sleep rm grep ls; do
        case "$cmd" in
            grep)
                cat > "$BIN/grep" <<'SHIM'
#!/bin/bash
echo "grep $*" >> "$TRACE"
exec /usr/bin/grep "$@"
SHIM
                ;;
            ls)
                cat > "$BIN/ls" <<'SHIM'
#!/bin/bash
echo "ls $*" >> "$TRACE"
case "$*" in
    *cloud-init*) exit 1 ;;
esac
exec /usr/bin/ls "$@"
SHIM
                ;;
            *)
                cat > "$BIN/$cmd" <<SHIM
#!/bin/bash
echo "$cmd \$*" >> "\$TRACE"
exit 0
SHIM
                ;;
        esac
        chmod +x "$BIN/$cmd"
    done

    export PATH="$BIN:$PATH"
    awk '/^cleanup_system\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh" > "$TEST_DIR/cleanup_system.bash"
    cat > "$TEST_DIR/loader.bash" <<'LOADER'
log()       { echo "LOG: $*" >> "$TRACE"; }
log_debug() { echo "DEBUG: $*" >> "$TRACE"; }
log_warn()  { echo "WARN: $*" >> "$TRACE"; }
log_error() { echo "ERROR: $*" >> "$TRACE"; }
die()       { echo "DIE: $*" >> "$TRACE"; exit 1; }
OS_ID="ubuntu"
LOADER
}

teardown() {
    rm -rf "$TEST_DIR"
}

call_cleanup() {
    bash -c "source '$TEST_DIR/loader.bash'; source '$TEST_DIR/cleanup_system.bash'; cleanup_system"
}

@test "cleanup_system does not call apt-get autoremove" {
    call_cleanup
    run ! grep -qE '^apt-get autoremove' "$TRACE"
}

@test "cleanup_system holds critical network packages before purge and releases own holds" {
    call_cleanup
    grep -qE '^apt-mark hold netplan\.io$' "$TRACE"
    grep -qE '^apt-mark hold netplan-generator$' "$TRACE"
    grep -qE '^apt-mark hold systemd-resolved$' "$TRACE"
    grep -qE '^apt-mark hold netcfg$' "$TRACE"
    grep -qE '^apt-mark hold ifupdown$' "$TRACE"
    grep -qE '^apt-mark unhold netplan\.io$' "$TRACE"
    grep -qE '^apt-mark unhold netplan-generator$' "$TRACE"
    run ! grep -qE '^apt-mark hold systemd-networkd$' "$TRACE"
}

@test "cleanup_system preserves pre-existing user holds" {
    export MOCK_PREEXISTING_HOLDS=$'netplan.io\nsystemd-resolved'
    call_cleanup
    run ! grep -qE '^apt-mark hold netplan\.io$' "$TRACE"
    run ! grep -qE '^apt-mark unhold netplan\.io$' "$TRACE"
    run ! grep -qE '^apt-mark hold systemd-resolved$' "$TRACE"
    run ! grep -qE '^apt-mark unhold systemd-resolved$' "$TRACE"
    grep -qE '^apt-mark hold netplan-generator$' "$TRACE"
}

@test "cleanup_system route loss triggers netplan recovery" {
    export MOCK_POST_ROUTE=""
    export MOCK_RECOVERY_ROUTE="default via 10.0.0.1 dev eth0"
    call_cleanup
    grep -qE '^apt-get install -y --no-install-recommends netplan\.io$' "$TRACE"
    grep -qE '^apt-cache show netplan-generator$' "$TRACE"
    grep -qE '^apt-get install -y --no-install-recommends netplan-generator$' "$TRACE"
    grep -qE '^systemctl restart systemd-networkd$' "$TRACE"
    grep -qE '^netplan apply$' "$TRACE"
    run ! grep -qE '^DIE:' "$TRACE"
}

@test "cleanup_system route loss falls back to networkctl and dhclient" {
    export MOCK_POST_ROUTE=""
    export MOCK_RECOVERY_ROUTE=""
    export MOCK_LASTDITCH_ROUTE=""
    export MOCK_LASTDITCH_ROUTE_AFTER_DHCLIENT="default via 10.0.0.1 dev eth0"
    call_cleanup
    grep -qE '^ip link set eth0 up$' "$TRACE"
    grep -qE '^networkctl renew eth0$' "$TRACE"
    grep -qE '^dhclient -4 eth0$' "$TRACE"
}

@test "cleanup_system unrecovered route loss dies with --no-tweaks advice" {
    export MOCK_POST_ROUTE=""
    export MOCK_RECOVERY_ROUTE=""
    export MOCK_LASTDITCH_ROUTE=""
    export MOCK_LASTDITCH_ROUTE_AFTER_DHCLIENT=""
    run call_cleanup
    [ "$status" -ne 0 ]
    grep -qE '^DIE:.*--no-tweaks' "$TRACE"
}

@test "structural: cleanup_system has safety markers in RU and EN" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        local block
        block=$(awk '/^cleanup_system\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../$f" | grep -vE '^[[:space:]]*#')
        grep -qF 'apt-mark hold' <<<"$block"
        grep -qF 'apt-mark unhold' <<<"$block"
        grep -qF 'netplan apply' <<<"$block"
        grep -qF 'dhclient -4' <<<"$block"
        grep -qF 'die ' <<<"$block"
        run ! grep -qE 'apt-get autoremove' <<<"$block"
    done
}
