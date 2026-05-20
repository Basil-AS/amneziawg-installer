#!/usr/bin/env bats
# shellcheck disable=SC2016

@test "interactive wizard contains prompts for key deployment choices" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"

    grep -qF 'Введите имя сервера [${AWG_SERVER_NAME:-MyVPN}]:' "$installer"
    grep -qF 'Введите внешний IP/домен сервера или Enter для автоопределения:' "$installer"
    grep -qF 'Выберите preset параметров AWG:' "$installer"
    grep -qF 'Доступ к Web Panel:' "$installer"
    grep -qF 'Настройка HTTPS для публичной Web Panel:' "$installer"
    grep -qF 'Автоматический домен по IP через sslip.io + Let' "$installer"
    grep -qF 'AWG_WEB_CERT_MODE="ip-domain"' "$installer"
    grep -qF 'AWG_WEB_CERT_PROVIDER="sslip.io"' "$installer"
    grep -qF 'AWG_WEB_PORT=443' "$installer"
    grep -qF 'Введите HTTPS порт Web Panel' "$installer"
    grep -qF 'Выберите IPv6 mode:' "$installer"
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
    grep -qF "export AWG_IPV6_SUBNET='\${AWG_IPV6_SUBNET}'" "$installer"
    grep -qF "export AWG_WEB_BIND='\${AWG_WEB_BIND}'" "$installer"
    grep -qF 'export AWG_WEB_PORT=${AWG_WEB_PORT}' "$installer"
    grep -qF "export AWG_WEB_CERT_MODE='\${AWG_WEB_CERT_MODE}'" "$installer"
    grep -qF "export AWG_WEB_CERT_PROVIDER='\${AWG_WEB_CERT_PROVIDER}'" "$installer"
    grep -qF "export AWG_WEB_DOMAIN='\${AWG_WEB_DOMAIN}'" "$installer"
    grep -qF "export AWG_WEB_LE_EMAIL='\${AWG_WEB_LE_EMAIL}'" "$installer"
    grep -qF "export AWG_WEB_PUBLIC_URL='\${AWG_WEB_PUBLIC_URL}'" "$installer"
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
}

@test "EN installer mirrors interactive wizard persistence and public warning" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"

    grep -qF 'Enter server name [${AWG_SERVER_NAME:-MyVPN}]:' "$installer"
    grep -qF 'Enter server public IP/domain or press Enter for auto-detect:' "$installer"
    grep -qF 'Choose AWG parameter preset:' "$installer"
    grep -qF 'Web Panel access:' "$installer"
    grep -qF 'HTTPS setup for public Web Panel:' "$installer"
    grep -qF 'Automatic IP domain via sslip.io + Let' "$installer"
    grep -qF 'AWG_WEB_CERT_MODE="ip-domain"' "$installer"
    grep -qF 'AWG_WEB_CERT_PROVIDER="sslip.io"' "$installer"
    grep -qF 'AWG_WEB_PORT=443' "$installer"
    grep -qF 'Enter HTTPS Web Panel port' "$installer"
    grep -qF 'Choose IPv6 mode:' "$installer"
    grep -qF 'Enter IPv6 subnet for clients' "$installer"
    grep -qF 'Install AdGuard Home for DNS?' "$installer"
    grep -qF 'Configure P2P ports for clients?' "$installer"
    grep -qF 'WARNING: Web Panel will be reachable from the Internet' "$installer"
    grep -qF 'export AWG_SERVER_NAME=${quoted_server_name}' "$installer"
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
    grep -qF 'AWG_CERT_FALLBACK_SELFSIGNED' "$ru"
    grep -qF 'ufw delete allow 80/tcp' "$ru"
    grep -qF 'sslip.io' "$BATS_TEST_DIRNAME/../README.md"
    grep -qF 'self-signed' "$BATS_TEST_DIRNAME/../README.en.md"
    grep -qF 'ip-domain' "$en"
}
