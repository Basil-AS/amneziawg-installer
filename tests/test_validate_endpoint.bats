#!/usr/bin/env bats
# shellcheck disable=SC2317
# Tests for validate_endpoint() in install_amneziawg.sh
# (audit: prevent injection via --endpoint)
#
# install_amneziawg.sh is not sourceable as a whole (top-level CLI parsing,
# state machine, etc.), so we extract validate_endpoint() via sed and
# eval it into the test shell.

setup() {
    # Silent log stubs (validate_endpoint does not log, but die might
    # if other extracted functions are added later)
    log()       { :; }
    log_warn()  { :; }
    log_error() { :; }
    log_debug() { :; }
    die()       { return 1; }
    export -f log log_warn log_error log_debug die

    # Extract validate_endpoint() definition from install_amneziawg.sh
    # The function spans from "validate_endpoint() {" to the matching closing brace.
    local script="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    local fn_text
    fn_text=$(awk '
        /^validate_endpoint\(\) \{/ { capture=1 }
        capture { print }
        capture && /^\}/ { exit }
    ' "$script")
    [[ -n "$fn_text" ]] || { echo "FAIL: validate_endpoint not found in $script"; return 1; }
    eval "$fn_text"
}

@test "validate_endpoint: accepts simple FQDN" {
    run validate_endpoint "vpn.example.com"
    [ "$status" -eq 0 ]
}

@test "validate_endpoint: accepts subdomain.tld FQDN" {
    run validate_endpoint "my-vpn.test.org"
    [ "$status" -eq 0 ]
}

@test "validate_endpoint: accepts IPv4" {
    run validate_endpoint "1.2.3.4"
    [ "$status" -eq 0 ]
}

@test "validate_endpoint: accepts public IPv4" {
    run validate_endpoint "203.0.113.42"
    [ "$status" -eq 0 ]
}

@test "validate_endpoint: accepts bracketed IPv6" {
    run validate_endpoint "[2001:db8::1]"
    [ "$status" -eq 0 ]
}

@test "validate_endpoint: rejects empty string" {
    run validate_endpoint ""
    [ "$status" -eq 1 ]
}

@test "validate_endpoint: rejects newline injection" {
    run validate_endpoint $'vpn.example.com\nAllowedIPs = 0.0.0.0/0'
    [ "$status" -eq 1 ]
}

@test "validate_endpoint: rejects carriage return" {
    run validate_endpoint $'vpn.example.com\rmalicious'
    [ "$status" -eq 1 ]
}

@test "validate_endpoint: rejects single quote" {
    run validate_endpoint "vpn'example.com"
    [ "$status" -eq 1 ]
}

@test "validate_endpoint: rejects double quote" {
    run validate_endpoint 'vpn"example.com'
    [ "$status" -eq 1 ]
}

@test "validate_endpoint: rejects backslash" {
    run validate_endpoint 'vpn\example.com'
    [ "$status" -eq 1 ]
}

@test "validate_endpoint: rejects space" {
    run validate_endpoint "vpn example.com"
    [ "$status" -eq 1 ]
}

@test "validate_endpoint: rejects tab" {
    run validate_endpoint $'vpn\texample.com'
    [ "$status" -eq 1 ]
}

@test "validate_endpoint: rejects unbracketed IPv6" {
    run validate_endpoint "2001:db8::1"
    [ "$status" -eq 1 ]
}

# --- IPv4 octet bounds tests (Phase 2 hardening: each octet must be 0-255) ---

@test "validate_endpoint: rejects IPv4 with all octets out of range (999.999.999.999)" {
    run validate_endpoint "999.999.999.999"
    [ "$status" -eq 1 ]
}

@test "validate_endpoint: rejects IPv4 with first octet 256 (256.1.1.1)" {
    run validate_endpoint "256.1.1.1"
    [ "$status" -eq 1 ]
}

@test "validate_endpoint: accepts IPv4 with max valid octets (255.255.255.255)" {
    run validate_endpoint "255.255.255.255"
    [ "$status" -eq 0 ]
}

@test "validate_endpoint: accepts IPv4 with all-zero octets (0.0.0.0)" {
    run validate_endpoint "0.0.0.0"
    [ "$status" -eq 0 ]
}

# --- IPv6 edge-case coverage ---

@test "validate_endpoint: accepts full-length bracketed IPv6" {
    run validate_endpoint "[2001:db8:85a3:0:0:8a2e:370:7334]"
    [ "$status" -eq 0 ]
}

@test "validate_endpoint: accepts single-label hostname (e.g. localhost)" {
    # Single-label hosts are accepted — AWG itself validates at runtime
    run validate_endpoint "localhost"
    [ "$status" -eq 0 ]
}

@test "validate_endpoint: rejects empty brackets" {
    run validate_endpoint "[]"
    [ "$status" -eq 1 ]
}
