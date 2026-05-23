#!/usr/bin/env bats
# Regression tests for token UX, installer input sanitation, WireSock defaults, and HTTPS wizard defaults.
# shellcheck disable=SC2016

@test "installer writes raw Web super token to summary and never the unavailable placeholder" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'AWG_WEB_SUPER_TOKEN_ONCE="$(python3 - "$web_dir/tokens.json"' "$installer"
    grep -qF 'Сгенерированный Web super token не проходит проверку' "$installer"
    grep -qF 'Super token: ${AWG_WEB_SUPER_TOKEN_ONCE}' "$installer"
    run grep -qF 'Web Super Token: ${AWG_WEB_SUPER_TOKEN_ONCE:-not available here' "$installer"
    [ "$status" -ne 0 ]
}

@test "final output contains framed summary path block and no-color has no required escape dependency" {
    local ru="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    local en="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -qF 'print_summary_notice_block()' "$ru"
    grep -qF 'ВАЖНО: ВСЯ ИНФОРМАЦИЯ ДЛЯ ДОСТУПА СОХРАНЕНА В ФАЙЛЕ' "$ru"
    grep -qF '/INSTALL_SUMMARY.txt' "$ru"
    grep -qF 'if [[ "$NO_COLOR" -eq 0 ]]' "$ru"
    grep -qF 'IMPORTANT: ALL ACCESS INFO IS SAVED IN THIS FILE' "$en"
}

@test "input sanitation helpers strip control sequences and invalid choices reprompt" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'sanitize_prompt_input()' "$installer"
    grep -qF 'read_clean_input()' "$installer"
    grep -qF 'ask_choice()' "$installer"
    grep -qF 'ask_port()' "$installer"
    grep -qF 'ask_yes_no()' "$installer"
    grep -qF 'ask_domain()' "$installer"
    grep -qF 'ask_client_name()' "$installer"
    grep -qF "tr -d '\\000-\\010\\013\\014\\016-\\037'" "$installer"
    grep -qF "log_warn \"Некорректный выбор" "$installer"
}

@test "WireSock hints default ON and explicit off is available" {
    local ru="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    local en="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -qF -- '--disable-wiresock-hints)' "$ru"
    grep -qF 'AWG_WIRESOCK_HINTS="${AWG_WIRESOCK_HINTS:-quic}"' "$ru"
    grep -qF 'Добавить WireSock compatibility hints в клиентские конфиги? [Y/n]:' "$ru"
    grep -qF 'Add WireSock compatibility hints to client configs? [Y/n]:' "$en"
    grep -qF '#@ws:Id' "$BATS_TEST_DIRNAME/../awg_common.sh"
}

@test "HTTPS wizard defaults to IP-domain option 2 and interactive ip-domain failure self-signs" {
    local ru="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    local en="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -qF 'ask_choice cert_choice "Ваш выбор [2]: " "2"' "$ru"
    grep -qF 'ask_choice cert_choice "Your choice [2]: " "2"' "$en"
    grep -qF 'AWG_CERT_FALLBACK_SELFSIGNED=1' "$ru"
    grep -qF 'AWG_WEB_CERT_FALLBACK_USED="selfsigned"' "$ru"
    grep -qF 'Certificate attempted mode: ${AWG_WEB_CERT_ATTEMPTED_MODE:-none}' "$ru"
}

@test "summary top block includes domain-only access and corrected AdGuardHome service command" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'IMPORTANT ACCESS INFO / SECRETS' "$installer"
    grep -qF 'Domain-only access: ${domain_only_access}' "$installer"
    grep -qF 'IP access: $(if [[ "$domain_only_access" == "yes" ]]; then echo "blocked by Host header validation"' "$installer"
    grep -qF 'systemctl status AdGuardHome.service --no-pager' "$installer"
}
