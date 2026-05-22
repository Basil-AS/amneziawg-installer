#!/usr/bin/env bats
# Structural tests for diagnose command integration.

bats_require_minimum_version 1.5.0

@test "diagnose: RU and EN manage scripts define diagnose helpers" {
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        grep -qE '^diagnose_server\(\) \{' "$BATS_TEST_DIRNAME/../$f"
        grep -qE '^_diagnose_carrier_known\(\) \{' "$BATS_TEST_DIRNAME/../$f"
        grep -qE '^_diagnose_carrier_list\(\) \{' "$BATS_TEST_DIRNAME/../$f"
        grep -qE '^_diag_line\(\) \{' "$BATS_TEST_DIRNAME/../$f"
    done
}

@test "diagnose: carrier parsing and dispatch are wired without breaking fork commands" {
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        grep -qF -- '--carrier=*)' "$BATS_TEST_DIRNAME/../$f"
        grep -qE '^[[:space:]]+diagnose\)' "$BATS_TEST_DIRNAME/../$f"
        grep -qF 'web token list' "$BATS_TEST_DIRNAME/../$f"
        grep -qF 'p2p list' "$BATS_TEST_DIRNAME/../$f"
        grep -qF 'ipv6 status' "$BATS_TEST_DIRNAME/../$f"
        grep -qF 'dns status' "$BATS_TEST_DIRNAME/../$f"
        grep -qF 'client regenerate' "$BATS_TEST_DIRNAME/../$f"
        grep -qF 'server rotate-profile --preset mobile|default' "$BATS_TEST_DIRNAME/../$f"
    done
}

@test "diagnose: RU and EN carrier lists stay aligned and exclude unconfirmed profiles" {
    local ru en
    ru=$(awk '/^_diagnose_carrier_list\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" \
        | grep -oE 'beeline_msk|yota_msk|tele2_msk|tele2_krasnoyarsk|tattelecom|megafon_regions|tmobile_us' \
        | sort -u)
    en=$(awk '/^_diagnose_carrier_list\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh" \
        | grep -oE 'beeline_msk|yota_msk|tele2_msk|tele2_krasnoyarsk|tattelecom|megafon_regions|tmobile_us' \
        | sort -u)
    [ "$ru" = "$en" ]
    [ "$(printf '%s\n' "$ru" | wc -l)" -eq 7 ]
    run ! grep -qE 'mts_msk|megafon_msk' <<<"$ru"
}

@test "diagnose: fork sections are present and sensitive stores are not printed" {
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        local block
        block=$(awk '/^diagnose_server\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../$f")
        grep -qF 'awg-web.service' <<<"$block"
        grep -qF 'AdGuardHome.service' <<<"$block"
        grep -qF 'AWG_IPV6_MODE' <<<"$block"
        grep -qF 'AWG_P2P_ENABLED' <<<"$block"
        grep -qF 'AWG_WIRESOCK_HINTS' <<<"$block"
        run ! grep -qE 'tokens\.json|AdGuard.*password|PrivateKey' <<<"$block"
    done
}

@test "diagnose: usage help mentions command in both languages" {
    awk '/^usage\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" | grep -qF 'diagnose'
    awk '/^usage\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh" | grep -qF 'diagnose'
}
