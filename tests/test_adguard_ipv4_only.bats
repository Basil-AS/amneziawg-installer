#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

bats_require_minimum_version 1.5.0

SCRIPT="$BATS_TEST_DIRNAME/../scripts/adguard_ipv4_only.py"

setup() {
    command -v python3 &>/dev/null || skip "python3 not available"
    CFG="$BATS_TEST_TMPDIR/AdGuardHome.yaml"
    cat > "$CFG" <<'YAML'
bind_host: 0.0.0.0
bind_port: 3000
users: []
http_proxy: ""
language: en
theme: auto
debug_pprof: false
dns:
  bind_hosts:
    - 10.9.9.1
  port: 53
  anonymize_client_ip: false
  ratelimit: 0
  refuse_any: true
  upstream_dns:
    - https://dns.adguard-dns.com/dns-query
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
  upstream_dns_file: ""
  bootstrap_dns:
    - 1.1.1.1
    - 1.0.0.1
    - 2606:4700:4700::1111
    - 2606:4700:4700::1001
    - 9.9.9.10
    - 2620:fe::10
    - 8.8.8.8
    - 8.8.4.4
    - 2001:4860:4860::8888
    - '2a09::'
    - '2a11::'
    - 119.29.29.29
    - '2402:4e00::'
  fallback_dns: []
  upstream_mode: parallel
  trusted_proxies:
    - 127.0.0.0/8
    - ::1/128
  cache_enabled: true
  bogus_nxdomain: []
  aaaa_disabled: false
  enable_dnssec: true
  edns_client_subnet:
    custom_ip: ""
    enabled: false
    use_custom: false
  bootstrap_prefer_ipv6: false
  use_dns64: false
  dns64_prefixes: []
  serve_plain_dns: true
clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: true
    dhcp: true
    hosts: true
  persistent: []
YAML

    # IPv6-not-usable fixture: kernel IPv6 disabled, no global addresses
    NOV6_DISABLE="$BATS_TEST_TMPDIR/disable_ipv6_1"
    printf '1\n' > "$NOV6_DISABLE"
    NOV6_IFINET6="$BATS_TEST_TMPDIR/if_inet6_empty"
    : > "$NOV6_IFINET6"

    # IPv6-usable fixture: kernel IPv6 enabled, one global address present
    V6_DISABLE="$BATS_TEST_TMPDIR/disable_ipv6_0"
    printf '0\n' > "$V6_DISABLE"
    V6_IFINET6="$BATS_TEST_TMPDIR/if_inet6_global"
    printf '20010db8000000000000000000000001 02 40 00 80       eth0\n' > "$V6_IFINET6"

    export ADGUARD_IPV4_ONLY_DISABLE_IPV6_PATH="$NOV6_DISABLE"
    export ADGUARD_IPV4_ONLY_IF_INET6_PATH="$NOV6_IFINET6"
}

@test "adguard_ipv4_only: dry run does not modify the file" {
    cp "$CFG" "$CFG.orig"
    run python3 "$SCRIPT" "$CFG"
    [ "$status" -eq 0 ]
    diff "$CFG" "$CFG.orig"
}

@test "adguard_ipv4_only: --apply sets the four dns keys for IPv4-only" {
    run python3 "$SCRIPT" "$CFG" --apply
    [ "$status" -eq 0 ]
    grep -qF '  aaaa_disabled: true' "$CFG"
    grep -qF '  bootstrap_prefer_ipv6: false' "$CFG"
    grep -qF '  use_dns64: false' "$CFG"
    grep -qF '  dns64_prefixes: []' "$CFG"
}

@test "adguard_ipv4_only: --apply removes IPv6 bootstrap entries and keeps IPv4 ones" {
    run python3 "$SCRIPT" "$CFG" --apply
    [ "$status" -eq 0 ]
    for v6 in '2606:4700:4700::1111' '2606:4700:4700::1001' '2620:fe::10' '2001:4860:4860::8888' "'2a09::'" "'2a11::'" "'2402:4e00::'"; do
        if grep -qF "$v6" "$CFG"; then
            fail "IPv6 bootstrap entry $v6 was not removed"
        fi
    done
    for v4 in 1.1.1.1 1.0.0.1 9.9.9.10 8.8.8.8 8.8.4.4 119.29.29.29; do
        grep -qF "    - $v4" "$CFG"
    done
}

@test "adguard_ipv4_only: --apply does not touch upstream_dns DoH list or trusted_proxies" {
    run python3 "$SCRIPT" "$CFG" --apply
    [ "$status" -eq 0 ]
    grep -qF '    - https://dns.adguard-dns.com/dns-query' "$CFG"
    grep -qF '    - https://dns.cloudflare.com/dns-query' "$CFG"
    grep -qF '    - https://dns.google/dns-query' "$CFG"
    grep -qF '    - ::1/128' "$CFG"
}

@test "adguard_ipv4_only: --apply preserves unrelated top-level sections" {
    run python3 "$SCRIPT" "$CFG" --apply
    [ "$status" -eq 0 ]
    grep -qF 'bind_port: 3000' "$CFG"
    grep -qF 'persistent: []' "$CFG"
}

@test "adguard_ipv4_only: re-running after --apply reports no further changes" {
    python3 "$SCRIPT" "$CFG" --apply
    cp "$CFG" "$CFG.applied"
    run python3 "$SCRIPT" "$CFG" --apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"No changes needed"* ]]
    diff "$CFG" "$CFG.applied"
}

@test "adguard_ipv4_only: refuses to run without --force when IPv6 looks usable" {
    export ADGUARD_IPV4_ONLY_DISABLE_IPV6_PATH="$V6_DISABLE"
    export ADGUARD_IPV4_ONLY_IF_INET6_PATH="$V6_IFINET6"
    cp "$CFG" "$CFG.orig"
    run python3 "$SCRIPT" "$CFG" --apply
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing"* ]]
    diff "$CFG" "$CFG.orig"
}

@test "adguard_ipv4_only: --force applies changes even when IPv6 looks usable" {
    export ADGUARD_IPV4_ONLY_DISABLE_IPV6_PATH="$V6_DISABLE"
    export ADGUARD_IPV4_ONLY_IF_INET6_PATH="$V6_IFINET6"
    run python3 "$SCRIPT" "$CFG" --apply --force
    [ "$status" -eq 0 ]
    grep -qF '  aaaa_disabled: true' "$CFG"
}
