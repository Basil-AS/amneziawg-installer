#!/usr/bin/env bats
# shellcheck disable=SC2329
# Tests for _try_local_ip fallback (v5.11.1 Phase B).
#
# When curl to external IP services fails (LXC without egress, outbound
# firewall, etc.), installer/manage falls back to the first non-loopback
# IPv4 on a network interface. This keeps generate_client / regen working
# in egress-restricted environments — the user gets a best-effort
# Endpoint which they can hand-edit if the server is behind NAT.

load test_helper

@test "_try_local_ip: returns IPv4 when global-scope iface is present" {
    # Mock `ip -4 -o addr show scope global` to return a deterministic line.
    # The real ip(8) output format we parse:
    #   1: lo    inet 127.0.0.1/8 ...
    #   2: eth0  inet 10.0.0.42/24 brd ... scope global ...
    # shellcheck disable=SC2317
    ip() {
        if [[ "$1" == "-4" && "$2" == "-o" && "$3" == "addr" ]]; then
            echo "2: eth0    inet 10.0.0.42/24 brd 10.0.0.255 scope global eth0       valid_lft forever preferred_lft forever"
            return 0
        fi
        command ip "$@"
    }
    export -f ip

    run _try_local_ip
    [ "$status" -eq 0 ]
    [ "$output" = "10.0.0.42" ]
}

@test "_try_local_ip: returns 1 when no global-scope iface" {
    # shellcheck disable=SC2317
    ip() {
        if [[ "$1" == "-4" ]]; then
            echo ""
            return 0
        fi
        command ip "$@"
    }
    export -f ip

    run _try_local_ip
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "_try_local_ip: skips loopback (127.0.0.0/8)" {
    # shellcheck disable=SC2317
    ip() {
        if [[ "$1" == "-4" && "$2" == "-o" ]]; then
            # Only lo — should yield empty, not 127.0.0.1
            echo "1: lo    inet 127.0.0.1/8 scope host lo       valid_lft forever preferred_lft forever"
            return 0
        fi
        command ip "$@"
    }
    export -f ip

    run _try_local_ip
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "_try_local_ip: picks first global-scope among many ifaces" {
    # shellcheck disable=SC2317
    ip() {
        if [[ "$1" == "-4" && "$2" == "-o" ]]; then
            cat <<'EOF'
2: eth0    inet 192.168.1.10/24 brd 192.168.1.255 scope global eth0       valid_lft forever preferred_lft forever
3: awg0    inet 10.9.9.1/24 scope global awg0       valid_lft forever preferred_lft forever
EOF
            return 0
        fi
        command ip "$@"
    }
    export -f ip

    run _try_local_ip
    [ "$status" -eq 0 ]
    [ "$output" = "192.168.1.10" ]
}

@test "_try_local_ip: RU and EN define the helper identically" {
    local RU_FILE="${BATS_TEST_DIRNAME}/../awg_common.sh"
    local EN_FILE="${BATS_TEST_DIRNAME}/../awg_common_en.sh"
    grep -qE '^_try_local_ip\(\)' "$RU_FILE"
    grep -qE '^_try_local_ip\(\)' "$EN_FILE"
    # Both must use `ip -4 -o addr show scope global` pattern
    awk '/^_try_local_ip\(\) \{$/,/^}$/' "$RU_FILE" | grep -qE 'ip -4 -o addr show scope global'
    awk '/^_try_local_ip\(\) \{$/,/^}$/' "$EN_FILE" | grep -qE 'ip -4 -o addr show scope global'
}
