#!/usr/bin/env bats
# Fork-delta guards for manual upstream 5.14.x ports.
# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

@test "render_client_config keeps fork IPv6, DNS, WireSock, PSK, and dynamic MTU hooks" {
    local block
    block=$(awk '/^render_client_config\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../awg_common.sh")
    grep -qF 'Address = ${address_line}' <<<"$block"
    grep -qF 'DNS = ${dns_servers}' <<<"$block"
    grep -qF 'ensure_dns_allowedips_routes' <<<"$block"
    grep -qF 'render_wiresock_hints' <<<"$block"
    grep -qF 'MTU = ${mtu}' <<<"$block"
    grep -qF 'PersistentKeepalive = 25' <<<"$block"
    grep -qF 'CLIENT_PSK' <<<"$block"
    grep -qF '#_P2PPorts' "$BATS_TEST_DIRNAME/../awg_common.sh"
}

@test "client regeneration keeps AWG_I1_OVERRIDE and import-token invalidation paths" {
    grep -qF 'AWG_I1_OVERRIDE' "$BATS_TEST_DIRNAME/../awg_common.sh"
    grep -qF 'AWG_I1_OVERRIDE' "$BATS_TEST_DIRNAME/../awg_common_en.sh"
    grep -qF 'AWG_I1_OVERRIDE' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'remove_import_tokens_for_client' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'clear_import_tokens' "$BATS_TEST_DIRNAME/../web/server.py"
}

@test "web panel regenerate action, rotate-profile API, and static allowlist remain present" {
    grep -qF 'data-action="${esc(action)}"' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'data-action="regenerate-config"' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF '/api/server/rotate-profile' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF '/api/server/rotate-profile' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'STATIC_FILES = {' "$BATS_TEST_DIRNAME/../web/server.py"
    run ! grep -qE 'tokens\.json|server_private\.key|\.conf"' < <(sed -n '/STATIC_FILES = {/,/^}/p' "$BATS_TEST_DIRNAME/../web/server.py")
}

@test "AdGuard curated config and INSTALL_SUMMARY secrets block remain protected" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'AdGuardHome.yaml' "$installer"
    grep -qF 'curated_user_rules' "$installer"
    grep -qF 'extract_user_rules(lines)' "$installer"
    grep -qF 'INSTALL_SUMMARY.txt' "$installer"
    grep -qF 'IMPORTANT ACCESS INFO / SECRETS' "$installer"
}

@test "WireSock hints and local DNS route support remain documented in runtime/tests" {
    grep -qF '#@ws:Id' "$BATS_TEST_DIRNAME/../awg_common.sh"
    grep -qF '#@ws:Ip' "$BATS_TEST_DIRNAME/../awg_common.sh"
    grep -qF '#@ws:Ib' "$BATS_TEST_DIRNAME/../awg_common.sh"
    grep -qF 'ensure_dns_allowedips_routes' "$BATS_TEST_DIRNAME/../awg_common.sh"
    grep -qF 'custom AllowedIPs includes tunnel-local DNS route without duplicates' "$BATS_TEST_DIRNAME/../tests/test_adguard_dns.bats"
}

@test "CI keeps web paths, JavaScript syntax checks, and SHA manifest freshness check" {
    local workflow="$BATS_TEST_DIRNAME/../.github/workflows/test.yml"
    grep -qF "web/**" "$workflow"
    grep -qF "python3 -m py_compile web/server.py" "$workflow"
    grep -qF "actions/setup-node" "$workflow"
    grep -qF "node --check web/app.js" "$workflow"
    grep -qF "node --check web/awg_i1.js" "$workflow"
    grep -qF "scripts/update-installer-sha-manifest.sh" "$workflow"
}

@test "ARM workflow keeps MODULE_VERSION validation while allowing blank latest" {
    local workflow="$BATS_TEST_DIRNAME/../.github/workflows/arm-build.yml"
    grep -qF 'MODULE_VERSION: ${{ inputs.module_version }}' "$workflow"
    grep -qF -- '-e MODULE_VERSION' "$workflow"
    grep -qF '[[ -n "${MODULE_VERSION:-}"' "$workflow"
    grep -qF 'Invalid module_version input' "$workflow"
}
