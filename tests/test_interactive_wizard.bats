#!/usr/bin/env bats
# shellcheck disable=SC2016

@test "interactive wizard contains prompts for key deployment choices" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"

    grep -qF 'Введите имя сервера [${AWG_SERVER_NAME:-MyVPN}]:' "$installer"
    grep -qF 'Введите внешний IP/домен сервера или Enter для автоопределения:' "$installer"
    grep -qF 'Выберите preset параметров AWG:' "$installer"
    grep -qF 'Доступ к Web Panel:' "$installer"
    grep -qF 'VPN-only, 10.9.9.1 — безопасно по умолчанию, порт 8443' "$installer"
    grep -qF 'public, 0.0.0.0 — доступ из интернета, домен + HTTPS, порт 443' "$installer"
    grep -qF 'Настройка HTTPS для публичной Web Panel:' "$installer"
    grep -qF 'Свой домен + Let' "$installer"
    grep -qF 'рекомендуется для доверенного HTTPS' "$installer"
    grep -qF 'Автоматический IP-домен sslip.io/nip.io + Let' "$installer"
    grep -qF 'экспериментально' "$installer"
    grep -qF 'лимиты Let' "$installer"
    grep -qF 'AWG_WEB_CERT_MODE="ip-domain"' "$installer"
    grep -qF 'AWG_WEB_CERT_PROVIDER="sslip.io"' "$installer"
    grep -qF 'AWG_WEB_PORT=443' "$installer"
    grep -qF 'Введите HTTPS порт Web Panel' "$installer"
    grep -qF 'Выберите IPv6 mode:' "$installer"
    grep -qF '1) auto — автоопределение:' "$installer"
    run grep -qE 'Ваш выбор \[(auto)\]:' "$installer"
    [ "$status" -ne 0 ]
    grep -qF 'отдельный routed IPv6 prefix' "$installer"
    grep -qF 'текущую публичную /64 на eth0' "$installer"
    grep -qF 'Введите IPv6 subnet для клиентов' "$installer"
    grep -qF 'Установить AdGuard Home для DNS?' "$installer"
    grep -qF 'Настроить P2P ports для клиентов?' "$installer"
    grep -qF 'Продолжить установку? [Y/n]:' "$installer"
}

@test "interactive preset choice 2 maps to mobile and is used for generation" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"

    grep -qF '2) AWG_PRESET="mobile"' "$installer"
    grep -qF 'local preset="${CLI_PRESET:-${AWG_PRESET:-default}}"' "$installer"
    grep -qF "export AWG_PRESET='\${AWG_PRESET:-default}'" "$installer"
}

@test "CLI preset mobile is persisted to config and summary" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"

    grep -qF '[[ -n "$CLI_PRESET" ]] && AWG_PRESET="$CLI_PRESET"' "$installer"
    grep -qF "export AWG_PRESET='\${AWG_PRESET:-default}'" "$installer"
    grep -qF 'Preset: ${AWG_PRESET:-default}' "$installer"
}

@test "interactive web exposure choices map to expected bind addresses and warn on public" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"

    grep -qF '1) AWG_WEB_BIND="10.9.9.1"' "$installer"
    grep -qF '2) AWG_WEB_BIND="127.0.0.1"' "$installer"
    grep -qF '3) AWG_WEB_BIND="0.0.0.0"' "$installer"
    grep -qF 'Вы открываете Web Panel в интернет. Продолжить? type YES:' "$installer"
    grep -qF 'ВНИМАНИЕ: Web Panel будет доступна из интернета' "$installer"
}

@test "wizard persists server endpoint web IPv6 AdGuard and P2P choices" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"

    grep -qF "export AWG_ENDPOINT='\${AWG_ENDPOINT}'" "$installer"
    grep -qF 'export AWG_SERVER_NAME=${quoted_server_name}' "$installer"
    grep -qF "export AWG_IPV6_MODE='\${AWG_IPV6_MODE}'" "$installer"
    grep -qF "export AWG_IPV6_MODE_REQUESTED='\${AWG_IPV6_MODE_REQUESTED}'" "$installer"
    grep -qF "export AWG_IPV6_MODE_EFFECTIVE='\${AWG_IPV6_MODE_EFFECTIVE:-\${AWG_IPV6_MODE}}'" "$installer"
    grep -qF "export AWG_IPV6_MODE_REASON='\${AWG_IPV6_MODE_REASON}'" "$installer"
    grep -qF "export AWG_IPV6_SUBNET='\${AWG_IPV6_SUBNET}'" "$installer"
    grep -qF "export AWG_WEB_BIND='\${AWG_WEB_BIND}'" "$installer"
    grep -qF 'export AWG_WEB_PORT=${AWG_WEB_PORT}' "$installer"
    grep -qF "export AWG_WEB_CERT_MODE='\${AWG_WEB_CERT_MODE}'" "$installer"
    grep -qF "export AWG_WEB_CERT_PROVIDER='\${AWG_WEB_CERT_PROVIDER}'" "$installer"
    grep -qF "export AWG_WEB_DOMAIN='\${AWG_WEB_DOMAIN}'" "$installer"
    grep -qF "export AWG_WEB_LE_EMAIL='\${AWG_WEB_LE_EMAIL}'" "$installer"
    grep -qF "export AWG_WEB_PUBLIC_URL='\${AWG_WEB_PUBLIC_URL}'" "$installer"
    grep -qF "export AWG_WEB_CERT_FALLBACK='\${AWG_WEB_CERT_FALLBACK}'" "$installer"
    grep -qF "export AWG_WEB_CERT_FAILURE_REASON='\${AWG_WEB_CERT_FAILURE_REASON}'" "$installer"
    grep -qF 'export AWG_ADGUARD_ENABLED=${AWG_ADGUARD_ENABLED}' "$installer"
    grep -qF 'export AWG_ADGUARD_PORT=${AWG_ADGUARD_PORT}' "$installer"
    grep -qF 'export AWG_P2P_ENABLED=${AWG_P2P_ENABLED}' "$installer"
    grep -qF 'export AWG_P2P_BASE_PORT=${AWG_P2P_BASE_PORT}' "$installer"
    grep -qF 'export AWG_P2P_PORTS_PER_CLIENT=${AWG_P2P_PORTS_PER_CLIENT}' "$installer"
}

@test "resume loads config and does not rerun first-run wizard defaults" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"

    grep -qF 'if [[ "$config_exists" -eq 0 ]]; then' "$installer"
    grep -qF 'log "Используются настройки из $CONFIG_FILE."' "$installer"
    grep -qF 'safe_load_config "$CONFIG_FILE"' "$installer"
    grep -qF 'AWG_PRESET=${AWG_PRESET:-default}' "$installer"
    grep -qF 'AWG_IPV6_MODE_REQUESTED=$(normalize_ipv6_mode_installer "${AWG_IPV6_MODE_REQUESTED:-${AWG_IPV6_MODE}}"' "$installer"
}

@test "EN installer mirrors interactive wizard persistence and public warning" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"

    grep -qF 'Enter server name [${AWG_SERVER_NAME:-MyVPN}]:' "$installer"
    grep -qF 'Enter server public IP/domain or press Enter for auto-detect:' "$installer"
    grep -qF 'Choose AWG parameter preset:' "$installer"
    grep -qF 'Web Panel access:' "$installer"
    grep -qF 'VPN-only, 10.9.9.1 - safe default, port 8443' "$installer"
    grep -qF 'public, 0.0.0.0 - Internet access, domain + HTTPS, port 443' "$installer"
    grep -qF 'HTTPS setup for public Web Panel:' "$installer"
    grep -qF 'Your domain + Let' "$installer"
    grep -qF 'recommended for trusted HTTPS' "$installer"
    grep -qF 'Automatic IP domain sslip.io/nip.io + Let' "$installer"
    grep -qF 'experimental' "$installer"
    grep -qF 'rate limits' "$installer"
    grep -qF 'AWG_WEB_CERT_MODE="ip-domain"' "$installer"
    grep -qF 'AWG_WEB_CERT_PROVIDER="sslip.io"' "$installer"
    grep -qF 'AWG_WEB_PORT=443' "$installer"
    grep -qF 'Enter HTTPS Web Panel port' "$installer"
    grep -qF 'Choose IPv6 mode:' "$installer"
    grep -qF '1) auto - auto-detect:' "$installer"
    run grep -qE 'Your choice \[(auto)\]:' "$installer"
    [ "$status" -ne 0 ]
    grep -qF 'dedicated routed IPv6 prefix' "$installer"
    grep -qF 'current public /64 on eth0' "$installer"
    grep -qF 'Enter IPv6 subnet for clients' "$installer"
    grep -qF 'Install AdGuard Home for DNS?' "$installer"
    grep -qF 'Configure P2P ports for clients?' "$installer"
    grep -qF 'WARNING: Web Panel will be reachable from the Internet' "$installer"
    grep -qF 'export AWG_SERVER_NAME=${quoted_server_name}' "$installer"
}

@test "IPv6 wizard exposes real auto mode and no longer uses bracket-only auto default" {
    local ru="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    local en="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"

    grep -qF 'Ваш выбор [1]:' "$ru"
    grep -qF 'Your choice [1]:' "$en"
    grep -qF 'AWG_IPV6_MODE_REQUESTED=$(resolve_ipv6_mode_choice "$ipv6_choice")' "$ru"
    grep -qF 'AWG_IPV6_MODE_REQUESTED=$(resolve_ipv6_mode_choice "$ipv6_choice")' "$en"
    grep -qF 'Выберите 1, 2, 3 или 4' "$ru"
    grep -qF 'Choose 1, 2, 3 or 4' "$en"
    grep -qF 'IPv6: $(ipv6_summary_line)' "$ru"
    grep -qF 'IPv6: $(ipv6_summary_line)' "$en"
    grep -qF 'requested auto, effective' "$ru"
    grep -qF 'requested auto, effective' "$en"
    grep -qF 'IPv6 requested mode: ${AWG_IPV6_MODE_REQUESTED:-${AWG_IPV6_MODE:-legacy}}' "$ru"
    grep -qF 'IPv6 effective mode: ${AWG_IPV6_MODE_EFFECTIVE:-${AWG_IPV6_MODE:-legacy}}' "$en"
    grep -qF 'IPv6 selection reason: ${AWG_IPV6_MODE_REASON:-none}' "$ru"
}

@test "IPv6 choice helper maps empty input and numbered choices" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"

    run bash -c '
        source <(awk "/^resolve_ipv6_mode_choice\\(\\) \\{/{flag=1} flag{print} /^}/{if(flag) exit}" "$1")
        [ "$(resolve_ipv6_mode_choice "")" = "auto" ]
        [ "$(resolve_ipv6_mode_choice 1)" = "auto" ]
        [ "$(resolve_ipv6_mode_choice 2)" = "routed" ]
        [ "$(resolve_ipv6_mode_choice 3)" = "ndp" ]
        [ "$(resolve_ipv6_mode_choice 4)" = "nat66" ]
        if resolve_ipv6_mode_choice bad; then exit 1; fi
    ' _ "$installer"
    [ "$status" -eq 0 ]
}

@test "IPv6 auto effective mode selection follows routed ndp nat66 rules" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"

    run bash -c '
        source <(awk "/^select_effective_ipv6_mode\\(\\) \\{/{flag=1} flag{print} /^}/{if(flag) exit}" "$1")
        detect_ipv6_64_subnet(){ printf "%s\n" "2001:db8:1::/64"; }
        generate_ula_subnet(){ printf "%s\n" "fd12:3456:789a:1::/64"; }

        select_effective_ipv6_mode auto ""
        [ "$AWG_IPV6_MODE" = "ndp" ]
        [ "$AWG_IPV6_MODE_EFFECTIVE" = "ndp" ]
        [ "$AWG_IPV6_SUBNET" = "2001:db8:1::/64" ]

        select_effective_ipv6_mode auto "2001:db8:9::/64"
        [ "$AWG_IPV6_MODE" = "routed" ]

        select_effective_ipv6_mode auto "fd12:3456:789a:2::/64"
        [ "$AWG_IPV6_MODE" = "nat66" ]

        unset -f detect_ipv6_64_subnet
        detect_ipv6_64_subnet(){ return 1; }
        select_effective_ipv6_mode auto ""
        [ "$AWG_IPV6_MODE" = "nat66" ]
        [ "$AWG_IPV6_SUBNET" = "fd12:3456:789a:1::/64" ]

        if select_effective_ipv6_mode routed ""; then exit 1; fi
    ' _ "$installer"
    [ "$status" -eq 0 ]
}

@test "reboot prompt defaults to yes and parses explicit no" {
    local ru="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    local en="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"

    grep -qF 'Перезагрузить сейчас? [Y/n]:' "$ru"
    grep -qF 'Reboot now? [Y/n]:' "$en"

    run bash -c '
        source <(awk "/^parse_reboot_choice\\(\\) \\{/{flag=1} flag{print} /^}/{if(flag) exit}" "$1")
        parse_reboot_choice ""
        parse_reboot_choice y
        parse_reboot_choice yes
        parse_reboot_choice n
        [ "$?" -eq 1 ]
        parse_reboot_choice no
        [ "$?" -eq 1 ]
        parse_reboot_choice maybe
        [ "$?" -eq 2 ]
    ' _ "$ru"
    [ "$status" -eq 0 ]
}

@test "web certificate wizard defaults and persistence cover trusted public HTTPS" {
    local ru="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    local en="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"

    grep -qF 'generate_ip_domain()' "$ru"
    grep -qF 'printf '\''%s.%s\n'\'' "${endpoint//./-}" "$provider"' "$ru"
    grep -qF 'format_https_url()' "$ru"
    grep -qF 'if [[ "$port" == "443" ]]; then' "$ru"
    grep -qF 'apply_web_port_default "$config_exists"' "$ru"
    grep -qF 'update_web_public_url' "$ru"
    grep -qF 'AWG_WEB_DOMAIN="$(generate_ip_domain "${AWG_ENDPOINT:-}" "${AWG_WEB_CERT_PROVIDER:-sslip.io}")"' "$ru"
    grep -qF 'AWG_WEB_PUBLIC_URL="$(format_https_url "$host" "${AWG_WEB_PORT:-8443}")"' "$ru"
    grep -qF 'check_web_port_availability' "$ru"
    grep -qF 'Port 443/tcp' "$en"
    grep -qF 'Certificate mode: ${AWG_WEB_CERT_MODE:-selfsigned}' "$ru"
    grep -qF 'Certificate provider: ${AWG_WEB_CERT_PROVIDER:-none}' "$ru"
    grep -qF 'Trusted HTTPS: ${trusted_https}' "$ru"
    grep -qF 'AWG_WEB_CERT_FALLBACK' "$ru"
    grep -qF 'Certificate fallback: ${AWG_WEB_CERT_FALLBACK_USED:-none}' "$ru"
    grep -qF 'ufw_remove_http01_temporary_rule' "$ru"
    grep -qF 'sslip.io' "$BATS_TEST_DIRNAME/../README.md"
    grep -qF 'self-signed' "$BATS_TEST_DIRNAME/../README.en.md"
    grep -qF 'ip-domain' "$en"
}

@test "web certificate flow has robust UFW 80 helper preflight classification and fallback" {
    local ru="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    local en="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"

    grep -qF 'ufw_allow_http01_temporarily()' "$ru"
    grep -qF 'ufw allow 80/tcp comment "Temporary Let' "$ru"
    grep -qF 'elif ufw allow 80/tcp >/dev/null 2>&1; then' "$ru"
    grep -qF 'Проверьте внешний firewall/security group' "$ru"
    grep -qF 'AWG_CERTBOT_UFW80_ADDED="$added"' "$ru"
    grep -qF '[[ "${AWG_CERTBOT_UFW80_ADDED:-0}" == "1" ]] || return 0' "$ru"
    grep -qF 'ufw delete allow 80/tcp' "$ru"
    grep -qF 'resolve_domain_ipv4()' "$ru"
    grep -qF 'preflight_letsencrypt_domain()' "$ru"
    grep -qF 'Port 80 is already in use; standalone certbot cannot run' "$ru"
    grep -qF 'classify_certbot_failure()' "$ru"
    grep -qF 'handle_letsencrypt_failure()' "$ru"
    grep -qF 'Switch to self-signed and continue' "$en"
}

@test "certbot failure classifier maps rate limit timeout and DNS failures" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    local tmp
    tmp="$(mktemp)"
    run bash -c '
        source <(sed -n "/^classify_certbot_failure() {$/,/^certbot_failure_reason_text() {$/p" "$1" | head -n -1)
        printf "%s\n" "too many certificates already issued for sslip.io" > "$2"
        [ "$(classify_certbot_failure "$2")" = "rate_limit" ]
        printf "%s\n" "Timeout during connect (likely firewall problem)" > "$2"
        [ "$(classify_certbot_failure "$2")" = "http01_timeout" ]
        printf "%s\n" "DNS problem: NXDOMAIN looking up A" > "$2"
        [ "$(classify_certbot_failure "$2")" = "dns" ]
    ' _ "$installer" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 0 ]
}

@test "step 6 resume skips AWG config regeneration when cert retry resumes" {
    local ru="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    local en="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"

    grep -qF 'configs_ready_for_step6_resume()' "$ru"
    grep -qF 'resume step 6 продолжит web/cert deploy без пересоздания клиентов' "$ru"
    grep -qF 'configs_ready_for_step6_resume()' "$en"
    grep -qF 'without recreating clients' "$en"
}

@test "installer handles Ctrl-C with explicit interrupt trap and exit 130" {
    local ru="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    local en="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"

    grep -qF 'handle_interrupt()' "$ru"
    grep -qF 'trap handle_interrupt INT TERM' "$ru"
    grep -qF 'exit 130' "$ru"
    grep -qF 'Установка прервана пользователем (Ctrl-C).' "$ru"
    grep -qF 'sudo bash ./install_amneziawg.sh --uninstall' "$ru"

    grep -qF 'handle_interrupt()' "$en"
    grep -qF 'trap handle_interrupt INT TERM' "$en"
    grep -qF 'exit 130' "$en"
    grep -qF 'Installation interrupted by user (Ctrl-C).' "$en"
}

@test "web panel HTTPS port validator allows 443 while VPN UDP port keeps user range" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    run bash -c '
        die(){ echo "$*" >&2; return 97; }
        source <(sed -n "/^validate_port_user() {$/,/^validate_bind_addr() {$/p" "$1" | head -n -1)
        validate_web_port 443
        validate_web_port 1
        validate_web_port 65535
    ' _ "$installer"
    [ "$status" -eq 0 ]

    run bash -c '
        die(){ echo "$*" >&2; return 97; }
        source <(sed -n "/^validate_port_user() {$/,/^validate_bind_addr() {$/p" "$1" | head -n -1)
        validate_port_user 443
    ' _ "$installer"
    [ "$status" -eq 97 ]
    [[ "$output" == *"1024-65535"* ]]

    run bash -c '
        die(){ echo "$*" >&2; return 97; }
        source <(sed -n "/^validate_port_user() {$/,/^validate_bind_addr() {$/p" "$1" | head -n -1)
        validate_web_port 0
    ' _ "$installer"
    [ "$status" -eq 97 ]
    [[ "$output" == *"1-65535"* ]]

    run bash -c '
        die(){ echo "$*" >&2; return 97; }
        source <(sed -n "/^validate_port_user() {$/,/^validate_bind_addr() {$/p" "$1" | head -n -1)
        validate_web_port 65536
    ' _ "$installer"
    [ "$status" -eq 97 ]
    [[ "$output" == *"1-65535"* ]]
}

@test "web panel port defaults follow exposure and certificate mode" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    run bash -c '
        log_warn(){ :; }
        die(){ echo "$*" >&2; return 97; }
        source <(sed -n "/^is_public_web_bind() {$/,/^prompt_web_panel() {$/p" "$1" | head -n -1)

        CLI_WEB_PORT=""; ENV_AWG_WEB_PORT_SET=0; AWG_WEB_ENABLED=1

        AWG_WEB_BIND="10.9.9.1"; AWG_WEB_CERT_MODE="selfsigned"; AWG_WEB_PORT=""
        apply_web_port_default 0
        [ "$AWG_WEB_PORT" = "8443" ]

        AWG_WEB_BIND="127.0.0.1"; AWG_WEB_CERT_MODE="selfsigned"; AWG_WEB_PORT=""
        apply_web_port_default 0
        [ "$AWG_WEB_PORT" = "8443" ]

        AWG_WEB_BIND="0.0.0.0"; AWG_WEB_CERT_MODE="ip-domain"; AWG_WEB_PORT=""
        apply_web_port_default 0
        [ "$AWG_WEB_PORT" = "443" ]

        AWG_WEB_BIND="0.0.0.0"; AWG_WEB_CERT_MODE="letsencrypt"; AWG_WEB_PORT=""
        apply_web_port_default 0
        [ "$AWG_WEB_PORT" = "443" ]

        AWG_WEB_BIND="0.0.0.0"; AWG_WEB_CERT_MODE="custom"; AWG_WEB_PORT=""
        apply_web_port_default 0
        [ "$AWG_WEB_PORT" = "443" ]

        AWG_WEB_BIND="0.0.0.0"; AWG_WEB_CERT_MODE="selfsigned"; AWG_WEB_PORT=""
        apply_web_port_default 0
        [ "$AWG_WEB_PORT" = "8443" ]

        CLI_WEB_PORT="8443"; AWG_WEB_BIND="0.0.0.0"; AWG_WEB_CERT_MODE="ip-domain"; AWG_WEB_PORT="8443"
        apply_web_port_default 0
        [ "$AWG_WEB_PORT" = "8443" ]
    ' _ "$installer"
    [ "$status" -eq 0 ]
}

@test "pseudo-domain provider prompt sanitizes defaults and control input" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'ask_choice provider_choice "Ваш выбор [1]: " "1" "1 2 sslip.io nip.io"' "$installer"
    grep -qF 'case "${provider_choice:-1}" in' "$installer"
    grep -qF '1|sslip.io) AWG_WEB_CERT_PROVIDER="sslip.io"' "$installer"
    grep -qF '2|nip.io) AWG_WEB_CERT_PROVIDER="nip.io"' "$installer"
    run bash -c '
        log_warn(){ :; }
        die(){ echo "$*" >&2; return 97; }
        source <(sed -n "/^is_public_web_bind() {$/,/^prompt_web_panel() {$/p" "$1" | head -n -1)
        [ "$(sanitize_menu_choice "")" = "" ]
        [ "$(sanitize_menu_choice "1")" = "1" ]
        [ "$(sanitize_menu_choice "2")" = "2" ]
        [ "$(sanitize_menu_choice "sslip.io")" = "sslip.io" ]
        [ "$(sanitize_menu_choice "nip.io")" = "nip.io" ]
        [ "$(sanitize_menu_choice $'"'"'\e[B'"'"')" = "" ]
    ' _ "$installer"
    [ "$status" -eq 0 ]
}

@test "web public URL formatting omits 443 and keeps non-default ports" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    run bash -c '
        log_warn(){ :; }
        die(){ echo "$*" >&2; return 97; }
        source <(sed -n "/^is_public_web_bind() {$/,/^prompt_web_panel() {$/p" "$1" | head -n -1)
        [ "$(format_https_url 77-90-29-231.sslip.io 443)" = "https://77-90-29-231.sslip.io/" ]
        [ "$(format_https_url 77-90-29-231.sslip.io 8443)" = "https://77-90-29-231.sslip.io:8443/" ]
    ' _ "$installer"
    [ "$status" -eq 0 ]
}

@test "README documents clarified IPv6 routed and NDP modes" {
    grep -qF '`auto` | Автовыбор' "$BATS_TEST_DIRNAME/../README.md"
    grep -qF 'отдельный routed IPv6 prefix' "$BATS_TEST_DIRNAME/../README.md"
    grep -qF 'текущая публичная `/64` на `eth0`/внешнем интерфейсе' "$BATS_TEST_DIRNAME/../README.md"
    grep -qF '`auto` | Auto-select' "$BATS_TEST_DIRNAME/../README.en.md"
    grep -qF 'separate routed IPv6 prefix' "$BATS_TEST_DIRNAME/../README.en.md"
    grep -qF 'current public `/64` on `eth0`/the external interface' "$BATS_TEST_DIRNAME/../README.en.md"
}

@test "README documents Web Panel access defaults for Enter, public domains, and port 443 URLs" {
    grep -qF 'Enter на шаге доступа к Web Panel оставляет безопасный VPN-only default `https://10.9.9.1:8443`' "$BATS_TEST_DIRNAME/../README.md"
    grep -qF 'Итоговый URL для port `443` пишется без `:443`' "$BATS_TEST_DIRNAME/../README.md"
    grep -qF 'свой домен + Let' "$BATS_TEST_DIRNAME/../README.md"
    grep -qF 'best-effort из-за общих rate limits Let' "$BATS_TEST_DIRNAME/../README.md"
    grep -qF 'TCP/80 открыт во внешнем firewall/security group' "$BATS_TEST_DIRNAME/../README.md"
    grep -qF 'Pressing Enter at the Web Panel access step keeps the safe VPN-only default `https://10.9.9.1:8443`' "$BATS_TEST_DIRNAME/../README.en.md"
    grep -qF 'The final URL for port `443` is shown without `:443`' "$BATS_TEST_DIRNAME/../README.en.md"
    grep -qF 'your own domain + Let' "$BATS_TEST_DIRNAME/../README.en.md"
    grep -qF 'best-effort because they share Let' "$BATS_TEST_DIRNAME/../README.en.md"
    grep -qF 'provider firewall/security group' "$BATS_TEST_DIRNAME/../README.en.md"
}
