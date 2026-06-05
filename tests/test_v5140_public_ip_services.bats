#!/usr/bin/env bats
# Tests for get_server_public_ip extended fallback list.
# shellcheck disable=SC1091,SC2317,SC2329

load test_helper

setup() {
    TEST_DIR=$(mktemp -d)
    export AWG_DIR="$TEST_DIR"
    export LOG_FILE="$TEST_DIR/awg.log"
    log()       { :; }
    log_warn()  { :; }
    log_error() { :; }
    log_debug() { :; }
    export -f log log_warn log_error log_debug
    source "$BATS_TEST_DIRNAME/../awg_common.sh"
    _CACHED_PUBLIC_IP=""
}

teardown() {
    rm -rf "$TEST_DIR"
    unset -f curl 2>/dev/null || true
}

_extract_urls() {
    awk '/^get_server_public_ip\(\) \{$/,/^}$/' "$1" \
        | grep -oE 'https://[^ \\]+' \
        | sed 's/[[:space:]]*$//'
}

@test "get_server_public_ip: RU and EN service lists contain 6 matching endpoints" {
    local ru_urls en_urls
    ru_urls=$(_extract_urls "$BATS_TEST_DIRNAME/../awg_common.sh")
    en_urls=$(_extract_urls "$BATS_TEST_DIRNAME/../awg_common_en.sh")
    [ "$ru_urls" = "$en_urls" ]
    [ "$(printf '%s\n' "$ru_urls" | wc -l)" -eq 6 ]
    grep -qxF "https://api.ipify.org" <<<"$ru_urls"
    grep -qxF "https://checkip.amazonaws.com" <<<"$ru_urls"
    grep -qxF "https://icanhazip.com" <<<"$ru_urls"
    grep -qxF "https://ifconfig.io" <<<"$ru_urls"
    grep -qxF "https://ifconfig.me" <<<"$ru_urls"
    grep -qxF "https://ipinfo.io/ip" <<<"$ru_urls"
}

@test "get_server_public_ip: first valid service wins and stdout is only IP" {
    curl() {
        local url="${*: -1}"
        case "$url" in
            https://api.ipify.org) echo "not-an-ip"; return 0 ;;
            https://checkip.amazonaws.com) echo "198.51.100.7"; return 0 ;;
            *) return 1 ;;
        esac
    }
    export -f curl

    run get_server_public_ip
    [ "$status" -eq 0 ]
    [ "$output" = "198.51.100.7" ]
}

@test "get_server_public_ip: all services fail returns empty stdout and nonzero" {
    curl() { return 1; }
    export -f curl

    run get_server_public_ip
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "get_server_public_ip: cached value avoids curl" {
    _CACHED_PUBLIC_IP="203.0.113.44"
    curl() { echo "curl should not run" >&2; return 1; }
    export -f curl

    run get_server_public_ip
    [ "$status" -eq 0 ]
    [ "$output" = "203.0.113.44" ]
}
