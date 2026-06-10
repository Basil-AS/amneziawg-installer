#!/bin/bash
# shellcheck disable=SC1003,SC2012,SC2015,SC2016,SC2004,SC2086,SC2317

# Проверка минимальной версии Bash
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ОШИБКА: Требуется Bash >= 4.0 (текущая: ${BASH_VERSION})" >&2; exit 1
fi

# ==============================================================================
# Скрипт для установки и настройки AmneziaWG 2.0 на Ubuntu/Debian серверах
# Автор: @bivlked
# Версия: 5.13.0
# Дата: 2026-05-13
# Репозиторий: https://github.com/bivlked/amneziawg-installer
# ==============================================================================

# --- Безопасный режим и Константы ---
set -o pipefail

SCRIPT_VERSION="5.13.0"
AWG_DIR="/root/awg"
INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
STATE_FILE="$AWG_DIR/setup_state"
LOG_FILE="$AWG_DIR/install_amneziawg.log"
KEYS_DIR="$AWG_DIR/keys"
SERVER_CONF_FILE="/etc/amnezia/amneziawg/awg0.conf"
AWG_REPO="${AWG_REPO:-Basil-AS/amneziawg-installer}"
AWG_BRANCH="${AWG_BRANCH:-main}"
COMMON_SCRIPT_PATH="$AWG_DIR/awg_common.sh"
MANAGE_SCRIPT_PATH="$AWG_DIR/manage_amneziawg.sh"

# SHA256 manifest для remote bootstrap assets. Local files рядом с installer
# используются первыми; remote download разрешён только с pinned SHA256 либо
# при явном AWG_ALLOW_UNVERIFIED_DOWNLOAD=1 для разработки.
declare -A AWG_ASSET_SHA256=(
    ["awg_common.sh"]="d293c17c2bba29087915e0046e7287548ba11319b2b41d4d5875357ed42d4f6d"
    ["manage_amneziawg.sh"]="4906b48b40ad461d92dc64f91f8753fc0d7c8aff4768c18485c448ca64af154e"
    ["web/server.py"]="fc4b4baee44c02aaf35284bb741a0b3046999d115a397caeac798a5d628176e1"
    ["web/index.html"]="7c07ed1d1991e08c0f9fc31e86ed8eb2bba5fa96387088f1f18918396cf7e662"
    ["web/app.js"]="938c36a7b8cc72a9393cbdaafc7b80ffa4d75f6f2f54b3c0845b785af7ded40c"
    ["web/awg_i1.js"]="c97a6ac6c4e4bd7ab24c37c45f451e364414f276441f8da1c0805d26013aaa03"
    ["web/style.css"]="67d6b505f68bacdabdf1e2519633bf59458fd2dfe617505fe740a089124dd059"
    ["web/favicon.svg"]="ae700ecb12dbf01403d0ed25247bac6b70f11201b094ee6c14b774b7fa533859"
    ["web/vendor/tailwindcss.js"]="176e894661aa9cdc9a5cba6c720044cbbf7b8bd80d1c9a142a7c24b1b6c50d15"
    ["web/vendor/apexcharts.min.js"]="a7400cd48b40b4f39d1c15137ae0cc8cbec31dc2b55a606640f1cd11912416dd"
)

# Флаги CLI
UNINSTALL=0; HELP=0; DIAGNOSTIC=0; VERBOSE=0; NO_COLOR=0; AUTO_YES=0; NO_TWEAKS=0
FORCE_REINSTALL=0
_APT_UPDATED=0
CLI_PORT=""; CLI_SUBNET=""; CLI_DISABLE_IPV6="default"; CLI_SSH_PORT=""
CLI_ROUTING_MODE="default"; CLI_CUSTOM_ROUTES=""; CLI_ENDPOINT=""; CLI_NO_TWEAKS=0; CLI_DISABLE_UFW=0
CLI_ENABLE_NATIVE_IPV6=0; CLI_IPV6_MODE=""; CLI_IPV6_SUBNET=""; CLI_UPGRADE_IPV6=0
CLI_P2P_BASE_PORT=""; CLI_P2P_PORTS_PER_CLIENT=""
CLI_FULLCONE_NAT=0; CLI_WEB_PORT=""; CLI_WEB_BIND=""; CLI_DISABLE_WEB=0
CLI_WEB_CERT_MODE=""; CLI_WEB_DOMAIN=""; CLI_WEB_CERT_FILE=""; CLI_WEB_KEY_FILE=""; CLI_WEB_CERT_PROVIDER=""; CLI_WEB_LE_EMAIL=""; CLI_WEB_CERT_FALLBACK=""
CLI_ENABLE_ADGUARD=0; CLI_DISABLE_ADGUARD=0; CLI_ADGUARD_PORT=""; CLI_DNS_MODE=""
CLI_WIRESOCK_HINTS=""; CLI_WIRESOCK_ID=""; CLI_WIRESOCK_IP=""; CLI_WIRESOCK_IB=""
CLI_SERVER_NAME=""
CLI_PRESET=""; CLI_JC=""; CLI_JMIN=""; CLI_JMAX=""

[[ -n "${AWG_SERVER_NAME+x}" ]] && ENV_AWG_SERVER_NAME_SET=1 || ENV_AWG_SERVER_NAME_SET=0
[[ -n "${AWG_ENDPOINT+x}" ]] && ENV_AWG_ENDPOINT_SET=1 || ENV_AWG_ENDPOINT_SET=0
[[ -n "${AWG_PRESET+x}" ]] && ENV_AWG_PRESET_SET=1 || ENV_AWG_PRESET_SET=0
[[ -n "${AWG_IPV6_MODE+x}" ]] && ENV_AWG_IPV6_MODE_SET=1 || ENV_AWG_IPV6_MODE_SET=0
[[ -n "${AWG_IPV6_SUBNET+x}" ]] && ENV_AWG_IPV6_SUBNET_SET=1 || ENV_AWG_IPV6_SUBNET_SET=0
[[ -n "${AWG_WEB_ENABLED+x}" ]] && ENV_AWG_WEB_ENABLED_SET=1 || ENV_AWG_WEB_ENABLED_SET=0
[[ -n "${AWG_WEB_BIND+x}" ]] && ENV_AWG_WEB_BIND_SET=1 || ENV_AWG_WEB_BIND_SET=0
[[ -n "${AWG_WEB_PORT+x}" ]] && ENV_AWG_WEB_PORT_SET=1 || ENV_AWG_WEB_PORT_SET=0
[[ -n "${AWG_WEB_CERT_MODE+x}" ]] && ENV_AWG_WEB_CERT_MODE_SET=1 || ENV_AWG_WEB_CERT_MODE_SET=0
[[ -n "${AWG_ADGUARD_ENABLED+x}" ]] && ENV_AWG_ADGUARD_ENABLED_SET=1 || ENV_AWG_ADGUARD_ENABLED_SET=0
[[ -n "${AWG_ADGUARD_PORT+x}" ]] && ENV_AWG_ADGUARD_PORT_SET=1 || ENV_AWG_ADGUARD_PORT_SET=0
[[ -n "${AWG_P2P_ENABLED+x}" ]] && ENV_AWG_P2P_ENABLED_SET=1 || ENV_AWG_P2P_ENABLED_SET=0
[[ -n "${AWG_P2P_BASE_PORT+x}" ]] && ENV_AWG_P2P_BASE_PORT_SET=1 || ENV_AWG_P2P_BASE_PORT_SET=0
[[ -n "${AWG_P2P_PORTS_PER_CLIENT+x}" ]] && ENV_AWG_P2P_PORTS_PER_CLIENT_SET=1 || ENV_AWG_P2P_PORTS_PER_CLIENT_SET=0
[[ -n "${AWG_FULLCONE_NAT+x}" ]] && ENV_AWG_FULLCONE_NAT_SET=1 || ENV_AWG_FULLCONE_NAT_SET=0

# --- Автоочистка временных файлов ---
_install_temp_files=()
_install_cleanup() {
    local f
    for f in "${_install_temp_files[@]}"; do [[ -f "$f" ]] && rm -f "$f"; done
    type ufw_remove_http01_temporary_rule &>/dev/null && ufw_remove_http01_temporary_rule
    # Очистка временных файлов из awg_common.sh (если уже подключён через source)
    type _awg_cleanup &>/dev/null && _awg_cleanup
}
handle_interrupt() {
    trap - INT TERM EXIT
    echo >&2
    if declare -F log_msg >/dev/null 2>&1; then
        log_msg "WARN" "Установка прервана пользователем (Ctrl-C)."
        log_msg "WARN" "Частичные файлы могут остаться в $AWG_DIR. Для очистки используйте: sudo bash ./install_amneziawg.sh --uninstall"
    else
        echo "WARN: Установка прервана пользователем (Ctrl-C)." >&2
        echo "WARN: Частичные файлы могут остаться в $AWG_DIR. Для очистки используйте: sudo bash ./install_amneziawg.sh --uninstall" >&2
    fi
    _install_cleanup
    exit 130
}
trap _install_cleanup EXIT
trap handle_interrupt INT TERM

# --- Обработка аргументов ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --uninstall)     UNINSTALL=1 ;;
        --help|-h)       HELP=1 ;;
        --diagnostic)    DIAGNOSTIC=1 ;;
        --verbose|-v)    VERBOSE=1 ;;
        --no-color)      NO_COLOR=1 ;;
        --port=*)        CLI_PORT="${1#*=}" ;;
        --ssh-port=*)    CLI_SSH_PORT="${1#*=}" ;;
        --subnet=*)      CLI_SUBNET="${1#*=}" ;;
        --allow-ipv6)    CLI_DISABLE_IPV6=0 ;;
        --disallow-ipv6) CLI_DISABLE_IPV6=1 ;;
        --enable-native-ipv6) CLI_ENABLE_NATIVE_IPV6=1; CLI_DISABLE_IPV6=0 ;;
        --ipv6-mode=*)  CLI_IPV6_MODE="${1#*=}"; CLI_DISABLE_IPV6=0 ;;
        --ipv6-subnet=*) CLI_IPV6_SUBNET="${1#*=}" ;;
        --upgrade-ipv6)  CLI_UPGRADE_IPV6=1; CLI_DISABLE_IPV6=0 ;;
        --p2p-base-port=*) CLI_P2P_BASE_PORT="${1#*=}" ;;
        --p2p-ports-per-client=*) CLI_P2P_PORTS_PER_CLIENT="${1#*=}" ;;
        --fullcone-nat)  CLI_FULLCONE_NAT=1 ;;
        --web-port=*)    CLI_WEB_PORT="${1#*=}" ;;
        --web-bind=*)    CLI_WEB_BIND="${1#*=}" ;;
        --disable-web)   CLI_DISABLE_WEB=1 ;;
        --web-cert-mode=*) CLI_WEB_CERT_MODE="${1#*=}" ;;
        --web-domain=*)  CLI_WEB_DOMAIN="${1#*=}" ;;
        --web-cert-file=*) CLI_WEB_CERT_FILE="${1#*=}" ;;
        --web-key-file=*) CLI_WEB_KEY_FILE="${1#*=}" ;;
        --web-cert-provider=*) CLI_WEB_CERT_PROVIDER="${1#*=}" ;;
        --web-le-email=*) CLI_WEB_LE_EMAIL="${1#*=}" ;;
        --web-cert-fallback=*) CLI_WEB_CERT_FALLBACK="${1#*=}" ;;
        --allow-ppa-codename-fallback) AWG_ALLOW_PPA_CODENAME_FALLBACK=1 ;;
        --enable-adguard) CLI_ENABLE_ADGUARD=1 ;;
        --disable-adguard) CLI_DISABLE_ADGUARD=1 ;;
        --adguard-port=*) CLI_ADGUARD_PORT="${1#*=}" ;;
        --dns-mode=*)    CLI_DNS_MODE="${1#*=}" ;;
        --wiresock-hints=*) CLI_WIRESOCK_HINTS="${1#*=}" ;;
        --disable-wiresock-hints) CLI_WIRESOCK_HINTS="off" ;;
        --wiresock-id=*) CLI_WIRESOCK_ID="${1#*=}" ;;
        --wiresock-ip=*) CLI_WIRESOCK_IP="${1#*=}" ;;
        --wiresock-ib=*) CLI_WIRESOCK_IB="${1#*=}" ;;
        --server-name=*) CLI_SERVER_NAME="${1#*=}" ;;
        --route-all)     CLI_ROUTING_MODE=1 ;;
        --route-amnezia) CLI_ROUTING_MODE=2 ;;
        --route-custom=*) CLI_ROUTING_MODE=3; CLI_CUSTOM_ROUTES="${1#*=}" ;;
        --endpoint=*)    CLI_ENDPOINT="${1#*=}" ;;
        --yes|-y)        AUTO_YES=1 ;;
        --no-tweaks)     NO_TWEAKS=1; CLI_NO_TWEAKS=1 ;;
        --disable-ufw)   CLI_DISABLE_UFW=1 ;;
        --force|-f)      FORCE_REINSTALL=1 ;;
        --preset=*)      CLI_PRESET="${1#*=}" ;;
        --jc=*)          CLI_JC="${1#*=}" ;;
        --jmin=*)        CLI_JMIN="${1#*=}" ;;
        --jmax=*)        CLI_JMAX="${1#*=}" ;;
        *) echo "Неизвестный аргумент: $1"; HELP=1 ;;
    esac
    shift
done

# ==============================================================================
# Функции логирования
# ==============================================================================

log_msg() {
    local type="$1" msg="$2"
    local ts
    ts=$(date +'%F %T')
    local safe_msg
    safe_msg="${msg//%/%%}"
    local entry="[$ts] $type: $safe_msg"
    local color_start="" color_end=""

    if [[ "$NO_COLOR" -eq 0 ]]; then
        color_end="\033[0m"
        case "$type" in
            INFO)  color_start="\033[0;32m" ;;
            WARN)  color_start="\033[0;33m" ;;
            ERROR) color_start="\033[1;31m" ;;
            DEBUG) color_start="\033[0;36m" ;;
            *)     color_start=""; color_end="" ;;
        esac
    fi

    if ! mkdir -p "$(dirname "$LOG_FILE")" || ! echo "$entry" >> "$LOG_FILE"; then
        echo "[$ts] ERROR: Ошибка записи лога $LOG_FILE" >&2
    fi

    if [[ "$type" == "ERROR" || "$type" == "WARN" ]]; then
        printf "${color_start}%s${color_end}\n" "$entry" >&2
    elif [[ "$type" == "DEBUG" && "$VERBOSE" -eq 1 ]]; then
        printf "${color_start}%s${color_end}\n" "$entry" >&2
    elif [[ "$type" == "INFO" ]]; then
        printf "${color_start}%s${color_end}\n" "$entry"
    elif [[ "$type" != "DEBUG" ]]; then
        printf "${color_start}%s${color_end}\n" "$entry"
    fi
}

log()       { log_msg "INFO" "$1"; }
log_warn()  { log_msg "WARN" "$1"; }
log_error() { log_msg "ERROR" "$1"; }
log_debug() { if [[ "$VERBOSE" -eq 1 ]]; then log_msg "DEBUG" "$1"; fi; }
die()       { log_error "КРИТИЧЕСКАЯ ОШИБКА: $1"; log_error "Установка прервана. Лог: $LOG_FILE"; exit 1; }

# ==============================================================================
# apt-get update wrapper, игнорирующий 404 только на source packages (deb-src).
# INLINE: нужна в шагах 1-2 до скачивания awg_common.sh (Step 5).
# Некоторые зеркала (Hetzner, AWS) не раздают source, но дефолтный ubuntu.sources
# содержит 'Types: deb deb-src'. Source не нужен (DKMS + бинарные headers).
# Возвращает 0 если update прошёл ИЛИ если все ошибки — только на source-маркерах.
# Любая другая ошибка (GPG, сетевая на binary, silent crash/OOM/SIGKILL) → non-zero.
# ==============================================================================
apt_update_tolerant() {
    # --ppa-amnezia-tolerant: дополнительно игнорируем ошибки от PPA Amnezia.
    # Используется на step 2 — там apt_wait_for_ppa_package сам делает retry
    # для outage'а ppa.launchpadcontent.net (issue #68). Без этого флага мы
    # должны fall-fail на любых non-source ошибках, иначе скрипт продолжит
    # установку на stale apt-cache (PR #69 review finding).
    local ppa_tolerant=0
    if [[ "${1:-}" == "--ppa-amnezia-tolerant" ]]; then
        ppa_tolerant=1
        shift
    fi

    local err_output rc non_src_errors raw_had_non_src_errors=0
    err_output=$(LANG=C LC_ALL=C apt-get update -y 2>&1)
    rc=$?
    echo "$err_output"

    if [[ $rc -eq 0 ]]; then
        return 0
    fi

    # Фильтруем строки ошибок. Игнорируем:
    #   1. Строки про source-пакеты (deb-src / /source/ / Sources)
    #   2. Generic 'Some index files failed to download' — симптом, не причина
    non_src_errors=$(printf '%s\n' "$err_output" \
        | grep -E '^(E:|Err:|W:)' \
        | grep -vE '(deb-src|/source/|Sources([^[:alpha:]]|$))' \
        | grep -vE 'Some index files failed to download' || true)

    # Запоминаем pre-PPA filter состояние: нужно различать «были реальные APT-ошибки,
    # но все на PPA Amnezia» (tolerant OK) от «классифицируемых ошибок не было
    # вообще» (OOM / silent crash — НЕ tolerant даже если в выводе мелькает PPA URL).
    [[ -n "$non_src_errors" ]] && raw_had_non_src_errors=1

    # Опционально (step 2): убираем ошибки только на PPA Amnezia — они будут
    # повторно проверены через apt_wait_for_ppa_package по apt-cache (issue #68).
    if [[ $ppa_tolerant -eq 1 && -n "$non_src_errors" ]]; then
        non_src_errors=$(printf '%s\n' "$non_src_errors" \
            | grep -vE 'ppa\.launchpadcontent\.net.*amnezia' || true)
    fi

    if [[ -z "$non_src_errors" ]]; then
        # Граничный случай: rc != 0, но ни одной классифицируемой строки E:/Err:/W:
        # не найдено (SIGKILL от OOM, silent crash, неизвестный формат вывода apt).
        # Игнорировать можно ТОЛЬКО если в выводе есть явные source-маркеры,
        # либо ppa-tolerant + были реальные APT-строки и все они — на PPA Amnezia.
        if printf '%s\n' "$err_output" | grep -qE '(deb-src|/source/|Sources([^[:alpha:]]|$))'; then
            log_warn "apt update: source packages недоступны в зеркале (ожидаемо, игнорируется)"
            return 0
        fi
        if [[ $ppa_tolerant -eq 1 && $raw_had_non_src_errors -eq 1 ]] \
            && printf '%s\n' "$err_output" | grep -qE 'ppa\.launchpadcontent\.net.*amnezia'; then
            log_warn "apt update: ошибки только на PPA Amnezia (issue #68), продолжаем с retry."
            return 0
        fi
        log_error "apt update завершился с rc=$rc без классифицируемых APT-строк — возможен silent crash / OOM / SIGKILL"
        return "$rc"
    fi

    log_error "apt update завершился с non-source ошибками:"
    printf '%s\n' "$non_src_errors" | while IFS= read -r line; do
        log_error "  $line"
    done
    return "$rc"
}

# ==============================================================================
# apt_wait_for_ppa_package <package> [max_attempts] [initial_delay_seconds]
#   Ждёт, пока пакет станет видимым в apt-cache, с экспоненциальным
#   backoff между попытками. Нужно на шаге 2 после добавления PPA
#   Amnezia: ppa.launchpadcontent.net иногда коротко лежит (issue #68),
#   и без ретрая первая холодная установка валится, хотя через минуту
#   PPA уже доступен.
#
#   ВАЖНО: проверяется именно apt-cache show, а не rc от apt-get update.
#   apt-get update toлerantно возвращает 0 даже когда какой-то InRelease
#   не скачался — поэтому простого retry на rc недостаточно для outage
#   PPA. Видимость пакета в apt-cache — единственный надёжный сигнал,
#   что PPA реально проиндексировался.
#
#   С дефолтами (3 попытки × initial=30с) сценарий такой: попытка 1 →
#   sleep 30с → apt update + попытка 2 → sleep 60с → apt update +
#   попытка 3 (последняя). После третьего fail возвращаем 1.
#   Итого ожидание между попытками ≈1.5 минуты.
#
#   Cap на delay (1800с) защищает от арифметического переполнения, если
#   кто-то вызовет helper с очень большим max.
# ==============================================================================
apt_wait_for_ppa_package() {
    local pkg="$1" max="${2:-3}" delay="${3:-30}" attempt
    for ((attempt = 1; attempt <= max; attempt++)); do
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            return 0
        fi
        if (( attempt == max )); then
            return 1
        fi
        log_warn "Пакет '${pkg}' не появился в apt-cache (попытка ${attempt}/${max}, PPA пока недоступен), повтор через ${delay}с..."
        sleep "$delay"
        apt_update_tolerant >/dev/null 2>&1 || true
        delay=$(( delay * 2 > 1800 ? 1800 : delay * 2 ))
    done
    return 1
}

# ==============================================================================
# Справка
# ==============================================================================

show_help() {
    cat << 'EOF'
Использование: sudo bash install_amneziawg.sh [ОПЦИИ]
Скрипт для установки и настройки AmneziaWG 2.0 на Ubuntu (24.04 / 25.10) и Debian (12 / 13).

Опции:
  -h, --help            Показать эту справку и выйти
  --uninstall           Удалить AmneziaWG и все его конфигурации
  --diagnostic          Создать диагностический отчет и выйти
  -v, --verbose         Расширенный вывод для отладки (включая DEBUG)
  --no-color            Отключить цветной вывод в терминале
  --port=НОМЕР          Установить UDP порт (1024-65535) неинтерактивно
  --subnet=ПОДСЕТЬ      Установить подсеть туннеля (x.x.x.x/yy) неинтерактивно
  --allow-ipv6          Оставить IPv6 включенным неинтерактивно
  --disallow-ipv6       Принудительно отключить IPv6 неинтерактивно
  --enable-native-ipv6  Совместимый алиас: включить IPv6 для клиентов
  --ipv6-mode=MODE      IPv6 режим клиентов: auto, routed, ndp, nat66, block или legacy
  --ipv6-subnet=CIDR    Задать IPv6 /48../64 для клиентов (например 2001:db8:1::/64)
  --upgrade-ipv6        Мигрировать существующих клиентов на IPv6/P2P metadata
  --p2p-base-port=PORT  Базовый P2P порт (умолч. 20000; диапазон base+1..base+1024)
  --p2p-ports-per-client=N
                        Количество P2P портов для нового клиента (умолч. 3)
  --fullcone-nat        Пробовать FULLCONENAT вместо MASQUERADE для IPv4
  --web-port=PORT       Порт веб-панели HTTPS (умолч. 8443)
  --web-bind=ADDR       Адрес bind веб-панели (умолч. 10.9.9.1, внутри VPN)
                        0.0.0.0 открывает панель наружу; используйте только осознанно
  --web-cert-mode=MODE  TLS mode: selfsigned, custom, letsencrypt, ip-domain
  --web-domain=DOMAIN   Домен для letsencrypt/custom summary
  --web-cert-file=PATH  fullchain.pem для --web-cert-mode=custom
  --web-key-file=PATH   privkey.pem для --web-cert-mode=custom
  --web-cert-provider=sslip.io|nip.io  Провайдер ip-domain (умолч. sslip.io)
  --web-le-email=EMAIL  Email для Let's Encrypt уведомлений (опционально)
  --web-cert-fallback=selfsigned|abort
                        Поведение при ошибке Let's Encrypt (default: abort в --yes, prompt в wizard)
  --allow-ppa-codename-fallback
                        Явно разрешить fallback Ubuntu non-LTS PPA codename на noble
  --disable-web         Не устанавливать и не запускать веб-панель
  --enable-adguard      Установить AdGuard Home (по умолчанию включено)
  --disable-adguard     Не устанавливать AdGuard Home и использовать системный DNS
  --adguard-port=PORT   HTTP-порт AdGuard Home на localhost/VPN (умолч. 3000)
  --dns-mode=MODE       DNS для клиентов: adguard, system или custom
  --wiresock-hints=MODE WireSock hints: off, auto, mobile, quic или dns (умолч. quic)
  --disable-wiresock-hints
  --wiresock-id=DOMAIN  Домен для #@ws:Id
  --wiresock-ip=quic|dns Значение #@ws:Ip
  --wiresock-ib=curl|chrome Значение #@ws:Ib
  --server-name=NAME    Имя сервера в .conf и vpn:// (умолч. MyVPN)
  --route-all           Использовать режим 'Весь трафик' неинтерактивно
  --route-amnezia       Использовать режим 'Amnezia' неинтерактивно
  --route-custom=СЕТИ   Использовать режим 'Пользовательский' неинтерактивно
  --endpoint=IP         Указать внешний IP сервера (для серверов за NAT)
  --ssh-port=PORT[,PORT]
                        Явно открыть SSH-порт(ы) в UFW; иначе autodetect
  -y, --yes             Автоматическое подтверждение (перезагрузки, UFW и т.д.)
  -f, --force           Принудительная переустановка поверх уже работающего AmneziaWG
                        (по умолчанию запуск на сконфигурированном сервере прерывается;
                        ENV: AWG_FORCE_REINSTALL=1 эквивалентен флагу)
  --no-tweaks           Пропустить hardening/оптимизацию (без UFW, Fail2Ban, sysctl tweaks)
  --disable-ufw         Не включать UFW; firewall/NAT ответственность внешняя/ручная
  --preset=ТИП          Набор параметров обфускации: default, mobile
                        mobile: Jc=3, узкий Jmax — для мобильных операторов (Tele2, Yota, Megafon)
  --jc=N               Задать Jc вручную (1-128, поверх preset)
  --jmin=N             Задать Jmin вручную (0-1280, поверх preset)
  --jmax=N             Задать Jmax вручную (0-1280, поверх preset, должно быть >= Jmin)

Примеры:
  sudo bash install_amneziawg.sh                             # Интерактивная установка
  sudo bash install_amneziawg.sh --port=51820 --route-all    # Неинтерактивная
  sudo bash install_amneziawg.sh --route-amnezia --yes       # Полностью автоматическая
  sudo bash install_amneziawg.sh --preset=mobile --yes       # Оптимизация для мобильных сетей
  sudo bash install_amneziawg.sh --uninstall                 # Удаление
  sudo bash install_amneziawg.sh --diagnostic                # Диагностика

Репозиторий: https://github.com/bivlked/amneziawg-installer
EOF
    exit 0
}

# ==============================================================================
# Утилиты и валидация
# ==============================================================================

update_state() {
    local next_step=$1
    mkdir -p "$(dirname "$STATE_FILE")"
    # Атомарная запись: tmp-файл + flock + mv. Защита от битого
    # состояния при crash/power-loss между write и close.
    (
        flock -x 200
        local tmp="${STATE_FILE}.tmp.$BASHPID"
        if printf '%s\n' "$next_step" > "$tmp" && mv -f "$tmp" "$STATE_FILE"; then
            exit 0
        fi
        rm -f "$tmp" 2>/dev/null
        exit 1
    ) 200>"${STATE_FILE}.lock" || die "Ошибка записи состояния"
    log "Состояние: следующий шаг - $next_step"
}

request_reboot() {
    local next_step=$1
    update_state "$next_step"

    # Перед reboot-gate 1→2 сохраняем boot_id. На входе step 2
    # сравниваем с текущим — если совпадает, reboot не произошёл
    # и DKMS соберёт модуль под старое ядро (которое после следующего
    # reboot будет уже apt full-upgrade'нутым и не подхватит модуль).
    if [[ "$next_step" == "2" ]] && [[ -r /proc/sys/kernel/random/boot_id ]]; then
        if cat /proc/sys/kernel/random/boot_id > "$AWG_DIR/.boot_id_before_step2" 2>/dev/null; then
            log_debug "boot_id captured before reboot"
        fi
    fi

    echo "" >> "$LOG_FILE"
    log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    log_warn "!!! ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА СИСТЕМЫ                        !!!"
    log_warn "!!! После перезагрузки, запустите скрипт снова командой:   !!!"
    log_warn "!!! sudo bash $0 [с теми же параметрами, если были]       !!!"
    log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "" >> "$LOG_FILE"
    local confirm="y" reboot_choice_rc=0
    if [[ "$AUTO_YES" -eq 0 ]]; then
        while true; do
            if ! read -rp "Перезагрузить сейчас? [Y/n]: " confirm < /dev/tty; then
                log_warn "Нет интерактивного TTY для подтверждения reboot. Перезагрузитесь вручную и запустите скрипт снова."
                exit 1
            fi
            parse_reboot_choice "$confirm"
            reboot_choice_rc=$?
            case "$reboot_choice_rc" in
                0|1) break ;;
                *) log_warn "Введите y/yes или n/no." ;;
            esac
        done
    else
        log "Автоматическое подтверждение перезагрузки (--yes)."
    fi
    if [[ "$AUTO_YES" -eq 1 || "$reboot_choice_rc" -eq 0 ]]; then
        log "Инициирована перезагрузка..."
        sleep 5
        if ! reboot; then die "Команда reboot не удалась."; fi
        exit 1
    else
        log "Перезагрузка отменена. Перезагрузитесь вручную и запустите скрипт снова."
        exit 1
    fi
}

parse_reboot_choice() {
    case "${1:-y}" in
        y|Y|yes|YES|Yes) return 0 ;;
        n|N|no|NO|No) return 1 ;;
        *) return 2 ;;
    esac
}

check_os_version() {
    log "Проверка ОС..."

    # Определение через /etc/os-release (универсально для Ubuntu и Debian)
    OS_ID=""
    OS_VERSION=""
    OS_CODENAME=""
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
        OS_CODENAME="$VERSION_CODENAME"
    elif command -v lsb_release &>/dev/null; then
        OS_ID=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        OS_VERSION=$(lsb_release -sr)
        OS_CODENAME=$(lsb_release -sc)
    else
        log_warn "Не удалось определить ОС (/etc/os-release и lsb_release не найдены)."
        return 0
    fi
    export OS_ID OS_VERSION OS_CODENAME

    # Поддерживаемые ОС
    local supported=0
    case "$OS_ID" in
        ubuntu)
            if [[ "$OS_VERSION" == "24.04" || "$OS_VERSION" == "25.10" ]]; then
                supported=1
            fi
            ;;
        debian)
            if [[ "$OS_VERSION" == "12" || "$OS_VERSION" == "13" ]]; then
                supported=1
            fi
            ;;
    esac

    if [[ "$supported" -eq 1 ]]; then
        log "ОС: ${OS_ID^} $OS_VERSION ($OS_CODENAME) — поддерживается"
    else
        log_warn "Обнаружена $OS_ID $OS_VERSION ($OS_CODENAME). Скрипт протестирован на Ubuntu 24.04/25.10 и Debian 12/13."
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Продолжить? [y/N]: " confirm < /dev/tty
            if ! [[ "$confirm" =~ ^[Yy]$ ]]; then die "Отмена."; fi
        else
            log "Продолжаем на $OS_ID $OS_VERSION (--yes)."
        fi
    fi
}

check_free_space() {
    log "Проверка места..."
    local req=2048
    local avail
    avail=$(df -m / | awk 'NR==2 {print $4}')
    if [[ -z "$avail" ]]; then
        log_warn "Не удалось определить свободное место."
        return 0
    fi
    if [ "$avail" -lt "$req" ]; then
        log_warn "Доступно $avail МБ. Рекомендуется >= $req МБ."
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Продолжить? [y/N]: " confirm < /dev/tty
            if ! [[ "$confirm" =~ ^[Yy]$ ]]; then die "Отмена."; fi
        else
            log "Продолжаем с $avail МБ (--yes)."
        fi
    else
        log "Свободно: $avail МБ (OK)"
    fi
}

check_port_availability() {
    local port=$1
    log "Проверка порта $port..."
    local proc
    proc=$(ss -lunp | grep ":${port} ")
    if [[ -n "$proc" ]]; then
        log_error "Порт ${port}/udp уже используется! Процесс: $proc"
        return 1
    else
        log "Порт $port/udp свободен."
        return 0
    fi
}

check_web_port_availability() {
    [[ "${AWG_WEB_ENABLED:-1}" -eq 1 ]] || return 0
    is_public_web_bind || return 0
    [[ "${AWG_WEB_PORT:-8443}" == "443" ]] || return 0
    log "Проверка порта 443/tcp для публичной Web Panel..."
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)443$'; then
        if [[ "$AUTO_YES" -eq 0 && -z "$CLI_WEB_PORT" && "$ENV_AWG_WEB_PORT_SET" -eq 0 ]]; then
            local fallback
            read -rp "Порт 443/tcp занят. Использовать 8443 вместо 443? [y/N]: " fallback < /dev/tty
            if [[ "$fallback" =~ ^[Yy]$ ]]; then
                AWG_WEB_PORT=8443
                return 0
            fi
        fi
        die "Порт 443/tcp занят; выберите другой --web-port или освободите порт."
    fi
}

install_packages() {
    local packages=("$@")
    local to_install=()
    local pkg
    log "Проверка пакетов: ${packages[*]}..."
    for pkg in "${packages[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            to_install+=("$pkg")
        fi
    done
    if [ ${#to_install[@]} -eq 0 ]; then
        log "Все пакеты уже установлены."
        return 0
    fi
    log "Установка: ${to_install[*]}..."
    if [[ "${_APT_UPDATED:-0}" -eq 0 ]]; then
        apt_update_tolerant || log_warn "Не удалось обновить apt."
        _APT_UPDATED=1
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt install -y "${to_install[@]}"; then
        # v5.13.0: типичный сбой на 25.10/26.04 после in-place upgrade с 24.04 —
        # dpkg postinst пакета amneziawg-dkms запускает `dkms autoinstall`,
        # который итерируется по ВСЕМ ядрам в /lib/modules/. Старые 6.8.x
        # headers скомпилированы gcc-13, а в 25.10 по умолчанию только
        # gcc-15 → autoinstall фолится, dpkg не configure'ит зависящие
        # amneziawg-tools / amneziawg. Принудительно собираем модуль для
        # running ядра и завершаем dpkg --configure -a.
        if printf '%s\n' "${to_install[@]}" | grep -qx "amneziawg-dkms"; then
            log_warn "apt install не завершился — пробую DKMS-сборку только для текущего ядра $(uname -r)..."
            local _mver
            _mver="$(ls /var/lib/dkms/amneziawg/ 2>/dev/null | head -n1)"
            if [[ -n "$_mver" ]] \
               && dkms install -m amneziawg -v "$_mver" -k "$(uname -r)" --force \
               && DEBIAN_FRONTEND=noninteractive dpkg --configure -a; then
                log "DKMS-модуль собран для $(uname -r), dpkg сконфигурирован."
                log "Пакеты установлены."
                return 0
            fi
        fi
        die "Ошибка установки пакетов."
    fi
    log "Пакеты установлены."
}

cleanup_apt() {
    log "Очистка apt..."
    apt-get clean || log_warn "Ошибка apt-get clean"
    rm -rf /var/lib/apt/lists/* || log_warn "Ошибка rm /var/lib/apt/lists/*"
    log "Кэш apt очищен."
}

configure_ipv6() {
    if [[ "$CLI_DISABLE_IPV6" != "default" ]]; then
        DISABLE_IPV6=$CLI_DISABLE_IPV6
        log "IPv6 из CLI: $DISABLE_IPV6"
    elif [[ "$AUTO_YES" -eq 1 ]]; then
        DISABLE_IPV6=0
        log "IPv6 включён (--yes): auto-detect public /64 или NAT66 fallback."
    else
        read -rp "Включить IPv6 для клиентов (auto/нат66 fallback)? [Y/n]: " dis_ipv6 < /dev/tty
        if [[ "$dis_ipv6" =~ ^[Nn]$ ]]; then
            DISABLE_IPV6=1
        else
            DISABLE_IPV6=0
        fi
    fi
    export DISABLE_IPV6
    log "Отключение IPv6: $(if [ "$DISABLE_IPV6" -eq 1 ]; then echo 'Да'; else echo 'Нет'; fi)"
}

shell_quote() {
    local s="$1"
    s="${s//\'/\'\\\'\'}"
    printf "'%s'" "$s"
}

# Безопасная загрузка конфигурации (whitelist-парсер, без source/eval)
safe_load_config() {
    local config_file="${1:-$CONFIG_FILE}"
    if [[ ! -f "$config_file" ]]; then return 1; fi

    local line key value first_line=1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$first_line" -eq 1 ]]; then
            line="${line#$'\xEF\xBB\xBF'}"
            first_line=0
        fi
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue
        line="${line#export }"
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            if [[ "$value" == \'*\' ]]; then
                value="${value#\'}"
                value="${value%\'}"
            elif [[ "$value" == \"*\" ]]; then
                value="${value#\"}"
                value="${value%\"}"
            fi
            case "$key" in
                OS_ID|OS_VERSION|OS_CODENAME|AWG_PORT|AWG_TUNNEL_SUBNET|\
                DISABLE_IPV6|ALLOWED_IPS_MODE|ALLOWED_IPS|AWG_ENDPOINT|AWG_MTU|\
                AWG_Jc|AWG_Jmin|AWG_Jmax|AWG_S1|AWG_S2|AWG_S3|AWG_S4|\
                AWG_H1|AWG_H2|AWG_H3|AWG_H4|AWG_I1|AWG_PRESET|NO_TWEAKS|AWG_APPLY_MODE|\
                AWG_IPV6_ENABLED|AWG_IPV6_MODE|AWG_IPV6_MODE_REQUESTED|AWG_IPV6_MODE_EFFECTIVE|AWG_IPV6_MODE_REASON|AWG_IPV6_SUBNET|AWG_IPV6_NDP_PROXY|AWG_IPV6_LEAK_PROTECTION|\
                AWG_P2P_ENABLED|AWG_P2P_BASE_PORT|AWG_P2P_PORTS_PER_CLIENT|AWG_FULLCONE_NAT|AWG_DISABLE_UFW|\
                AWG_WEB_ENABLED|AWG_WEB_PORT|AWG_WEB_BIND|AWG_WEB_CERT_MODE|AWG_WEB_DOMAIN|AWG_WEB_CERT_FILE|AWG_WEB_KEY_FILE|AWG_WEB_CERT_PROVIDER|AWG_WEB_LE_EMAIL|AWG_WEB_PUBLIC_URL|AWG_WEB_CERT_FALLBACK|AWG_WEB_CERT_ATTEMPTED_MODE|AWG_WEB_CERT_FAILURE_REASON|AWG_WEB_CERT_FALLBACK_USED|\
                AWG_DNS_MODE|AWG_CUSTOM_DNS|AWG_ADGUARD_ENABLED|AWG_ADGUARD_PORT|AWG_ADGUARD_DIR|\
                AWG_WIRESOCK_HINTS|AWG_WIRESOCK_ID|AWG_WIRESOCK_IP|AWG_WIRESOCK_IB|\
                AWG_SERVER_NAME)
                    export "$key=$value"
                    ;;
            esac
        fi
    done < "$config_file"
}

# Чтение одного ключа из конфига (для точечных запросов)
safe_read_config_key() {
    local key="$1" config_file="${2:-$CONFIG_FILE}"
    local line first_line=1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$first_line" -eq 1 ]]; then
            line="${line#$'\xEF\xBB\xBF'}"
            first_line=0
        fi
        line="${line%$'\r'}"
        line="${line#export }"
        if [[ "$line" =~ ^${key}=(.*)$ ]]; then
            local value="${BASH_REMATCH[1]}"
            if [[ "$value" == \'*\' ]]; then
                value="${value#\'}"
                value="${value%\'}"
            elif [[ "$value" == \"*\" ]]; then
                value="${value#\"}"
                value="${value%\"}"
            fi
            echo "$value"
            return 0
        fi
    done < "$config_file"
    return 1
}

validate_jc_value() {
    local v="$1"
    [[ "$v" =~ ^[0-9]+$ ]] && [[ "$v" -ge 1 ]] && [[ "$v" -le 128 ]]
}

validate_junk_size() {
    local v="$1"
    [[ "$v" =~ ^[0-9]+$ ]] && [[ "$v" -ge 0 ]] && [[ "$v" -le 1280 ]]
}

validate_port_user() {
    local port="$1"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1024 ]] || [[ "$port" -gt 65535 ]]; then
        die "Некорректный порт: '$port'. Допустимый диапазон: 1024-65535."
    fi
}

validate_port_system() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]]
}

validate_web_port() {
    local port="$1"
    if ! validate_port_system "$port"; then
        die "Некорректный HTTPS порт Web Panel: '$port'. Допустимый диапазон: 1-65535."
    fi
}

validate_port() {
    validate_port_user "$1"
}

validate_bind_addr() {
    local bind="$1"
    [[ -n "$bind" ]] || return 1
    [[ "$bind" != *$'\n'* && "$bind" != *$'\r'* && "$bind" != *[[:space:]]* ]] || return 1
    [[ "$bind" != *[[:cntrl:]]* ]] || return 1
    python3 - "$bind" <<'PY'
import ipaddress, sys
try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
PY
}

generate_random_awg_port() {
    local min=30000 max=60999 range random_val port attempt
    range=$((max - min + 1))
    for attempt in {1..20}; do
        random_val=$(od -An -tu4 -N4 /dev/urandom 2>/dev/null | tr -d ' ')
        if [[ -z "$random_val" || ! "$random_val" =~ ^[0-9]+$ ]]; then
            random_val=$(( (RANDOM << 15) | RANDOM ))
        fi
        port=$((min + (random_val % range)))
        if command -v ss >/dev/null 2>&1 && ss -lun 2>/dev/null | grep -q ":${port} "; then
            continue
        fi
        echo "$port"
        return 0
    done
    echo 39743
}

validate_subnet() {
    local subnet="$1"
    if ! [[ "$subnet" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/24$ ]] \
       || [[ "${BASH_REMATCH[1]}" -gt 255 ]] || [[ "${BASH_REMATCH[2]}" -gt 255 ]] \
       || [[ "${BASH_REMATCH[3]}" -gt 255 ]] || [[ "${BASH_REMATCH[4]}" -gt 255 ]]; then
        die "Некорректная подсеть: '$subnet'. Поддерживается только /24."
    fi
    if [[ "${BASH_REMATCH[4]}" -eq 0 ]] || [[ "${BASH_REMATCH[4]}" -eq 255 ]]; then
        die "Некорректная подсеть: '$subnet'. Последний октет не может быть 0 (сетевой адрес) или 255 (broadcast)."
    fi
    if [[ "${BASH_REMATCH[4]}" -ne 1 ]]; then
        die "Некорректная подсеть: '$subnet'. Последний октет должен быть 1 (адрес сервера в подсети)."
    fi
}

# Валидация endpoint (FQDN / IPv4 / [IPv6]).
# Возвращает 0 если endpoint безопасен и попадает под один из форматов,
# иначе 1 (caller сам решает die или log_warn + unset).
# Запрещает newline/CR/quotes/backslash чтобы предотвратить injection в
# awgsetup_cfg.init и client.conf через --endpoint флаг (audit).
validate_endpoint() {
    local ep="$1"
    [[ -n "$ep" ]] || return 1
    # Запрещаем символы которые могут сломать конфиг или внести injection
    [[ "$ep" != *$'\n'* && "$ep" != *$'\r'* && \
       "$ep" != *"'"* && "$ep" != *'"'* && "$ep" != *'\\'* && \
       "$ep" != *' '* && "$ep" != *$'\t'* ]] || return 1
    # Один из трёх форматов: FQDN, IPv4, [IPv6]
    [[ "$ep" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*|[0-9]{1,3}(\.[0-9]{1,3}){3}|\[[0-9A-Fa-f:]+\])$ ]] || return 1
    # Если IPv4 формат — дополнительно проверяем диапазон октетов 0-255
    if [[ "$ep" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        [[ "${BASH_REMATCH[1]}" -le 255 && "${BASH_REMATCH[2]}" -le 255 && \
           "${BASH_REMATCH[3]}" -le 255 && "${BASH_REMATCH[4]}" -le 255 ]] || return 1
    fi
    return 0
}

validate_cidr_list() {
    local input="$1" cidr
    input="${input//$'\r'/}"
    input="${input//$'\t'/ }"
    IFS=',' read -ra cidrs <<< "$input"
    for cidr in "${cidrs[@]}"; do
        cidr=$(echo "$cidr" | tr -d ' ')
        if ! [[ "$cidr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] \
           || [[ "${BASH_REMATCH[1]}" -gt 255 ]] || [[ "${BASH_REMATCH[2]}" -gt 255 ]] \
           || [[ "${BASH_REMATCH[3]}" -gt 255 ]] || [[ "${BASH_REMATCH[4]}" -gt 255 ]] \
           || [[ "${BASH_REMATCH[5]}" -gt 32 ]]; then
            return 1
        fi
    done
}

validate_ipv6_subnet() {
    local subnet="$1"
    [[ -n "$subnet" && "$subnet" == *:* && "$subnet" == */* ]] || return 1
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$subnet" <<'PY'
import ipaddress, sys
try:
    net = ipaddress.ip_network(sys.argv[1], strict=False)
    if net.version != 6 or net.prefixlen < 48 or net.prefixlen > 64:
        raise ValueError
except Exception:
    sys.exit(1)
PY
    else
        [[ "$subnet" =~ ^[0-9A-Fa-f:]+/(4[8-9]|5[0-9]|6[0-4])$ ]]
    fi
}

normalize_ipv6_subnet_installer() {
    local subnet="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$subnet" <<'PY'
import ipaddress, sys
net = ipaddress.ip_network(sys.argv[1], strict=False)
print(str(net))
PY
    else
        echo "$subnet"
    fi
}

detect_ipv6_64_subnet() {
    local addr
    addr=$(ip -6 -o addr show scope global 2>/dev/null \
        | awk '{print $4}' \
        | grep -viE '^(fd|fe80:)' \
        | head -1)
    [[ -n "$addr" ]] || return 1
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$addr" <<'PY'
import ipaddress, sys
try:
    iface = ipaddress.ip_interface(sys.argv[1])
    if iface.version != 6:
        raise ValueError
    net = ipaddress.ip_network(f"{iface.ip}/64", strict=False)
    print(str(net))
except Exception:
    sys.exit(1)
PY
    else
        echo "${addr%/*}/64"
    fi
}

generate_ula_subnet() {
    local r
    r=$(od -An -N5 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    if [[ ${#r} -lt 10 ]]; then
        r="$(printf '%02x%04x%04x' "$((RANDOM % 256))" "$RANDOM" "$RANDOM")"
    fi
    echo "fd${r:0:2}:${r:2:4}:${r:6:4}:1::/64"
}

normalize_ipv6_mode_installer() {
    case "${1:-legacy}" in
        auto|routed|ndp|nat66|block|legacy) echo "${1:-legacy}" ;;
        native) echo "ndp" ;;
        ula) echo "nat66" ;;
        leak-block|leak_block|disable) echo "block" ;;
        disabled|off|0) echo "legacy" ;;
        *) return 1 ;;
    esac
}

resolve_ipv6_mode_choice() {
    case "${1:-1}" in
        1|auto) echo "auto" ;;
        2|routed) echo "routed" ;;
        3|ndp) echo "ndp" ;;
        4|nat66) echo "nat66" ;;
        5|block|leak-block|leak_block) echo "block" ;;
        *) return 1 ;;
    esac
}

select_effective_ipv6_mode() {
    local requested="$1" subnet="${2:-}" detected=""
    AWG_IPV6_MODE_REASON=""
    case "$requested" in
        routed)
            [[ -n "$subnet" ]] || return 1
            AWG_IPV6_MODE="routed"
            AWG_IPV6_SUBNET="$subnet"
            AWG_IPV6_MODE_REASON="selected routed because user provided dedicated prefix"
            ;;
        block)
            AWG_IPV6_MODE="block"
            AWG_IPV6_SUBNET=""
            AWG_IPV6_MODE_REASON="selected IPv6 leak-block mode"
            ;;
        ndp)
            if [[ -z "$subnet" ]]; then
                detected="$(detect_ipv6_64_subnet)" || return 1
                subnet="$detected"
                AWG_IPV6_MODE_REASON="selected ndp because public /64 was detected on external interface"
            else
                AWG_IPV6_MODE_REASON="selected ndp because public prefix was provided"
            fi
            AWG_IPV6_MODE="ndp"
            AWG_IPV6_SUBNET="$subnet"
            ;;
        nat66)
            if [[ -z "$subnet" ]]; then
                subnet="$(generate_ula_subnet)"
            fi
            AWG_IPV6_MODE="nat66"
            AWG_IPV6_SUBNET="$subnet"
            AWG_IPV6_MODE_REASON="selected nat66 because user selected NAT66 fallback"
            ;;
        auto)
            if [[ -n "$subnet" ]]; then
                if [[ "$subnet" == fd* || "$subnet" == FD* ]]; then
                    AWG_IPV6_MODE="nat66"
                    AWG_IPV6_SUBNET="$subnet"
                    AWG_IPV6_MODE_REASON="selected nat66 because ULA prefix was provided"
                else
                    AWG_IPV6_MODE="routed"
                    AWG_IPV6_SUBNET="$subnet"
                    AWG_IPV6_MODE_REASON="selected routed because user provided dedicated prefix"
                fi
            elif detected="$(detect_ipv6_64_subnet)"; then
                AWG_IPV6_MODE="ndp"
                AWG_IPV6_SUBNET="$detected"
                AWG_IPV6_MODE_REASON="selected ndp because public /64 was detected on external interface"
            else
                AWG_IPV6_MODE="nat66"
                AWG_IPV6_SUBNET="$(generate_ula_subnet)"
                AWG_IPV6_MODE_REASON="selected nat66 because no suitable public prefix was detected"
            fi
            ;;
        *) return 1 ;;
    esac
    AWG_IPV6_MODE_EFFECTIVE="$AWG_IPV6_MODE"
}

validate_server_name() {
    local name="$1"
    [[ -n "${name//[[:space:]]/}" ]] || return 1
    [[ "$name" != *$'\n'* && "$name" != *$'\r'* ]] || return 1
    [[ ${#name} -le 128 ]] || return 1
    [[ "$name" =~ ^[[:alnum:]_.\ ,!\?\(\)-]+$ ]] || return 1
}

validate_no_control_chars() {
    local v="$1"
    [[ "$v" != *$'\n'* && "$v" != *$'\r'* && "$v" != *$'\t'* ]] || return 1
    [[ "$v" != *[$'\001'-$'\010'$'\013'$'\014'$'\016'-$'\037'$'\177']* ]] || return 1
}

systemd_escape_value() {
    local v="$1"
    validate_no_control_chars "$v" || return 1
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    printf '%s' "$v"
}

systemd_env_line() {
    local key="$1" value="$2" escaped
    escaped="$(systemd_escape_value "$value")" || return 1
    printf 'Environment="%s=%s"\n' "$key" "$escaped"
}

validate_safe_abs_path() {
    local p="$1"
    validate_no_control_chars "$p" || return 1
    [[ "$p" == /* ]] || return 1
}

systemd_abs_path_value() {
    local p="$1"
    validate_safe_abs_path "$p" || return 1
    # Do not shell-quote systemd path directives. Reject unsafe values instead.
    [[ "$p" != *" "* && "$p" != *$'\t'* && "$p" != *\"* && "$p" != *\'* ]] || return 1
    printf '%s' "$p"
}

print_secret_console_only() {
    printf '%s\n' "$1" > /dev/tty 2>/dev/null || printf '%s\n' "$1"
}

configure_ipv6_client_mode() {
    AWG_IPV6_ENABLED=${AWG_IPV6_ENABLED:-0}
    AWG_IPV6_MODE=${AWG_IPV6_MODE:-legacy}
    AWG_IPV6_MODE_REQUESTED=${AWG_IPV6_MODE_REQUESTED:-${AWG_IPV6_MODE}}
    AWG_IPV6_MODE_EFFECTIVE=${AWG_IPV6_MODE_EFFECTIVE:-${AWG_IPV6_MODE}}
    AWG_IPV6_MODE_REASON=${AWG_IPV6_MODE_REASON:-}
    AWG_IPV6_SUBNET=${AWG_IPV6_SUBNET:-}
    AWG_IPV6_NDP_PROXY=${AWG_IPV6_NDP_PROXY:-0}
    AWG_IPV6_LEAK_PROTECTION=${AWG_IPV6_LEAK_PROTECTION:-warn}
    local requested_mode=""

    if [[ -n "$CLI_IPV6_MODE" ]]; then
        requested_mode=$(normalize_ipv6_mode_installer "$CLI_IPV6_MODE") || \
            die "Некорректный --ipv6-mode: '$CLI_IPV6_MODE' (ожидается auto, routed, ndp, nat66, block или legacy)."
    else
        requested_mode=$(normalize_ipv6_mode_installer "${AWG_IPV6_MODE_REQUESTED:-${AWG_IPV6_MODE:-legacy}}" 2>/dev/null || echo "legacy")
    fi

    if [[ "${DISABLE_IPV6:-1}" -eq 1 && "$requested_mode" != "block" ]]; then
        AWG_IPV6_ENABLED=0
        AWG_IPV6_MODE_REQUESTED=legacy
        AWG_IPV6_MODE=legacy
        AWG_IPV6_MODE_EFFECTIVE=legacy
        AWG_IPV6_MODE_REASON="disabled"
        AWG_IPV6_SUBNET=""
        AWG_IPV6_NDP_PROXY=0
        AWG_IPV6_LEAK_PROTECTION=warn
        export AWG_IPV6_ENABLED AWG_IPV6_MODE_REQUESTED AWG_IPV6_MODE AWG_IPV6_MODE_EFFECTIVE AWG_IPV6_MODE_REASON AWG_IPV6_SUBNET AWG_IPV6_NDP_PROXY AWG_IPV6_LEAK_PROTECTION
        return 0
    fi

    AWG_IPV6_ENABLED=1
    if [[ -n "$CLI_IPV6_SUBNET" ]]; then
        validate_ipv6_subnet "$CLI_IPV6_SUBNET" || die "Некорректный --ipv6-subnet: '$CLI_IPV6_SUBNET'. Нужен IPv6 /48../64."
        AWG_IPV6_SUBNET=$(normalize_ipv6_subnet_installer "$CLI_IPV6_SUBNET")
    fi

    if [[ "$requested_mode" == "legacy" && -n "$AWG_IPV6_SUBNET" ]]; then
        if [[ "$AWG_IPV6_SUBNET" == fd* || "$AWG_IPV6_SUBNET" == FD* ]]; then
            requested_mode=nat66
        else
            requested_mode=ndp
        fi
    elif [[ "$requested_mode" == "legacy" && ( "$CLI_ENABLE_NATIVE_IPV6" -eq 1 || "$CLI_UPGRADE_IPV6" -eq 1 || "$DISABLE_IPV6" -eq 0 ) ]]; then
        requested_mode=auto
    fi

    AWG_IPV6_MODE_REQUESTED="$requested_mode"
    if [[ "$requested_mode" == "block" ]]; then
        AWG_IPV6_ENABLED=0
        AWG_IPV6_MODE_REQUESTED=block
        AWG_IPV6_MODE=block
        AWG_IPV6_MODE_EFFECTIVE=block
        AWG_IPV6_MODE_REASON="IPv6 leak-block mode: full-tunnel clients receive ::/0 without a VPN IPv6 address"
        AWG_IPV6_SUBNET=""
        AWG_IPV6_NDP_PROXY=0
        AWG_IPV6_LEAK_PROTECTION=block
    elif [[ "$requested_mode" != "legacy" ]]; then
        if ! select_effective_ipv6_mode "$requested_mode" "$AWG_IPV6_SUBNET"; then
            case "$requested_mode" in
                routed) die "Для IPv6 mode routed нужен отдельный routed IPv6 prefix. Укажите --ipv6-subnet=... или выберите auto/ndp/nat66." ;;
                ndp) die "Для IPv6 mode ndp нужен публичный IPv6 /64. Укажите --ipv6-subnet=... или выберите auto/nat66." ;;
                *) die "Не удалось выбрать IPv6 mode '$requested_mode'." ;;
            esac
        fi
        if [[ "$AWG_IPV6_MODE" == "nat66" && -n "$AWG_IPV6_SUBNET" && "$AWG_IPV6_SUBNET" != fd* && "$AWG_IPV6_SUBNET" != FD* ]]; then
            log_warn "NAT66 обычно использует ULA fd../64; заданная подсеть сохранена как есть: $AWG_IPV6_SUBNET"
        fi
        if [[ "$requested_mode" == "auto" ]]; then
            log "IPv6 auto: ${AWG_IPV6_MODE_REASON}; effective=${AWG_IPV6_MODE}, subnet=${AWG_IPV6_SUBNET}"
        fi
        AWG_IPV6_LEAK_PROTECTION=route
    elif [[ -n "$AWG_IPV6_SUBNET" ]]; then
        AWG_IPV6_MODE_EFFECTIVE="$AWG_IPV6_MODE"
    fi

    case "$AWG_IPV6_MODE" in
        routed) AWG_IPV6_NDP_PROXY=0 ;;
        ndp) AWG_IPV6_NDP_PROXY=1 ;;
        nat66) AWG_IPV6_NDP_PROXY=0 ;;
        block) AWG_IPV6_ENABLED=0; AWG_IPV6_NDP_PROXY=0; AWG_IPV6_LEAK_PROTECTION=block ;;
        *) AWG_IPV6_ENABLED=0; AWG_IPV6_MODE_REQUESTED=legacy; AWG_IPV6_MODE=legacy; AWG_IPV6_MODE_EFFECTIVE=legacy; AWG_IPV6_MODE_REASON="disabled"; AWG_IPV6_SUBNET=""; AWG_IPV6_NDP_PROXY=0; AWG_IPV6_LEAK_PROTECTION=warn ;;
    esac
    AWG_IPV6_MODE_EFFECTIVE="$AWG_IPV6_MODE"
    export AWG_IPV6_ENABLED AWG_IPV6_MODE_REQUESTED AWG_IPV6_MODE AWG_IPV6_MODE_EFFECTIVE AWG_IPV6_MODE_REASON AWG_IPV6_SUBNET AWG_IPV6_NDP_PROXY AWG_IPV6_LEAK_PROTECTION
}

configure_routing_mode() {
    if [[ "$CLI_ROUTING_MODE" != "default" ]]; then
        ALLOWED_IPS_MODE=$CLI_ROUTING_MODE
        if [[ "$CLI_ROUTING_MODE" -eq 3 ]]; then
            ALLOWED_IPS=$CLI_CUSTOM_ROUTES
            if [ -z "$ALLOWED_IPS" ]; then die "Не указаны сети для --route-custom."; fi
        fi
        log "Режим маршрутизации из CLI: $ALLOWED_IPS_MODE"
    elif [[ "$AUTO_YES" -eq 1 ]]; then
        ALLOWED_IPS_MODE=2
        log "Режим маршрутизации: Amnezia+DNS (--yes, по умолчанию)."
    else
        echo ""
        log "Выберите режим маршрутизации (AllowedIPs клиента):"
        echo "  1) Весь трафик (0.0.0.0/0) - Макс. приватность, может блокировать LAN"
        echo "  2) Список Amnezia+DNS (умолч.) - Рекомендуется для обхода блокировок"
        echo "  3) Только указанные сети (Split Tunneling)"
        read -rp "Ваш выбор [2]: " r_mode < /dev/tty
        ALLOWED_IPS_MODE=${r_mode:-2}
    fi
    case "$ALLOWED_IPS_MODE" in
        1) ALLOWED_IPS="0.0.0.0/0"
           log "Выбран режим: Весь трафик." ;;
        3) if [[ -z "$CLI_CUSTOM_ROUTES" ]]; then
               read -rp "Введите сети (a.b.c.d/xx,...): " ALLOWED_IPS < /dev/tty
               while ! validate_cidr_list "$ALLOWED_IPS"; do
                   log_warn "Некорректный формат CIDR: '$ALLOWED_IPS'. Ожидается: x.x.x.x/y[,x.x.x.x/y]"
                   read -rp "Повторите ввод: " ALLOWED_IPS < /dev/tty
               done
           else
               ALLOWED_IPS=$CLI_CUSTOM_ROUTES
               if ! validate_cidr_list "$ALLOWED_IPS"; then
                   die "Некорректный формат CIDR: '$ALLOWED_IPS'. Ожидается: x.x.x.x/y[,x.x.x.x/y]"
               fi
           fi
           log "Выбран режим: Пользовательский ($ALLOWED_IPS)" ;;
        *) ALLOWED_IPS_MODE=2
           ALLOWED_IPS="0.0.0.0/5, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/6, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.0.0/9, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4, 8.8.8.8/32, 1.1.1.1/32"
           log "Выбран режим: Список Amnezia+DNS." ;;
    esac
    if [ -z "$ALLOWED_IPS" ]; then die "Не удалось определить AllowedIPs."; fi
    export ALLOWED_IPS_MODE ALLOWED_IPS
}

detect_endpoint_for_installer() {
    local ip="" svc
    for svc in https://ifconfig.me https://api.ipify.org https://icanhazip.com https://ipinfo.io/ip; do
        ip=$(curl -4 -sf --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')
        if validate_endpoint "$ip" 2>/dev/null; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

prompt_server_name() {
    [[ "$AUTO_YES" -eq 0 && -z "$CLI_SERVER_NAME" && "$ENV_AWG_SERVER_NAME_SET" -eq 0 ]] || return 0
    local input_name
    while true; do
        read -rp "Введите имя сервера [${AWG_SERVER_NAME:-MyVPN}]: " input_name < /dev/tty
        input_name="${input_name:-${AWG_SERVER_NAME:-MyVPN}}"
        if validate_server_name "$input_name"; then
            AWG_SERVER_NAME="$input_name"
            break
        fi
        log_warn "Некорректное имя сервера: пустое, слишком длинное или содержит перевод строки."
    done
}

prompt_endpoint() {
    [[ "$AUTO_YES" -eq 0 && -z "$CLI_ENDPOINT" && "$ENV_AWG_ENDPOINT_SET" -eq 0 ]] || return 0
    local input_endpoint
    read -rp "Введите внешний IP/домен сервера или Enter для автоопределения: " input_endpoint < /dev/tty
    if [[ -n "$input_endpoint" ]]; then
        validate_endpoint "$input_endpoint" || die "Некорректный endpoint: '$input_endpoint'. Допустимые форматы: FQDN, IPv4 или [IPv6]."
        AWG_ENDPOINT="$input_endpoint"
        return 0
    fi
    if AWG_ENDPOINT=$(detect_endpoint_for_installer); then
        log "Endpoint автоопределён: $AWG_ENDPOINT"
    else
        AWG_ENDPOINT=""
        log_warn "Не удалось автоопределить внешний IP/домен. Endpoint останется пустым; проверьте клиентские конфиги после установки."
    fi
}

prompt_awg_preset() {
    [[ "$AUTO_YES" -eq 0 && -z "$CLI_PRESET" && "$ENV_AWG_PRESET_SET" -eq 0 ]] || return 0
    local preset_choice
    echo ""
    echo "Выберите preset параметров AWG:"
    echo "  1) default — универсальный"
    echo "  2) mobile — для мобильных сетей, Tele2/Yota/Megafon/LTE/5G"
    read -rp "Ваш выбор [1]: " preset_choice < /dev/tty
    case "${preset_choice:-1}" in
        1) AWG_PRESET="default" ;;
        2) AWG_PRESET="mobile" ;;
        *) log_warn "Неизвестный preset '$preset_choice', выбран default."; AWG_PRESET="default" ;;
    esac
}

prompt_ipv6_mode() {
    [[ "$AUTO_YES" -eq 0 && -z "$CLI_IPV6_MODE" && -z "$CLI_IPV6_SUBNET" && "$ENV_AWG_IPV6_MODE_SET" -eq 0 && "$ENV_AWG_IPV6_SUBNET_SET" -eq 0 ]] || return 0
    [[ "${DISABLE_IPV6:-1}" -eq 0 ]] || return 0
    local ipv6_choice input_subnet
    echo ""
    echo "Выберите IPv6 mode:"
    echo "  1) auto — автоопределение:"
    echo "     - routed, если задан отдельный routed IPv6 prefix для VPN;"
    echo "     - ndp, если используется публичная /64 на внешнем интерфейсе;"
    echo "     - nat66, если публичный prefix не найден или NDP/routed не подходят."
    echo "  2) routed — отдельный routed IPv6 prefix (/64, /56, /48), выданный провайдером именно под VPN"
    echo "  3) ndp — использовать текущую публичную /64 на eth0 через NDP proxy"
    echo "  4) nat66 — fallback через NAT66"
    echo "  5) block — IPv4-only full tunnel блокирует IPv6 route (::/0), чтобы снизить риск IPv6 leak"
    while true; do
        read -rp "Ваш выбор [1]: " ipv6_choice < /dev/tty
        if AWG_IPV6_MODE_REQUESTED=$(resolve_ipv6_mode_choice "$ipv6_choice"); then
            break
        fi
        log_warn "Неизвестный IPv6 mode '$ipv6_choice'. Выберите 1, 2, 3, 4 или 5."
    done
    AWG_IPV6_MODE="$AWG_IPV6_MODE_REQUESTED"
    case "$AWG_IPV6_MODE_REQUESTED" in
        routed)
            while true; do
                read -rp "Введите IPv6 subnet для клиентов, например 2a13:...::/64: " input_subnet < /dev/tty
                validate_ipv6_subnet "$input_subnet" || { log_warn "Некорректный IPv6 subnet. Нужен IPv6 /48../64."; continue; }
                AWG_IPV6_SUBNET=$(normalize_ipv6_subnet_installer "$input_subnet")
                break
            done
            ;;
    esac
}

warn_public_web_bind() {
    [[ "${AWG_WEB_ENABLED:-1}" -eq 1 ]] || return 0
    [[ "${AWG_WEB_BIND:-}" == "0.0.0.0" || "${AWG_WEB_BIND:-}" == "::" ]] || return 0
    log_warn "================================================================"
    log_warn "ВНИМАНИЕ: Web Panel будет доступна из интернета (${AWG_WEB_BIND}:${AWG_WEB_PORT})."
    log_warn "Оставляйте публичный доступ только если понимаете риск и используете токены/HTTPS."
    log_warn "================================================================"
}

is_public_web_bind() {
    [[ "${AWG_WEB_BIND:-}" == "0.0.0.0" || "${AWG_WEB_BIND:-}" == "::" ]]
}

is_trusted_web_cert_mode() {
    case "${AWG_WEB_CERT_MODE:-selfsigned}" in
        ip-domain|letsencrypt|custom) return 0 ;;
        *) return 1 ;;
    esac
}

generate_ip_domain() {
    local endpoint="$1" provider="$2"
    [[ "$provider" == "sslip.io" || "$provider" == "nip.io" ]] || return 1
    [[ "$endpoint" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS=. octet
    for octet in $endpoint; do
        [[ "$octet" =~ ^[0-9]+$ && "$octet" -le 255 ]] || return 1
    done
    printf '%s.%s\n' "${endpoint//./-}" "$provider"
}

format_https_url() {
    local host="$1" port="${2:-443}"
    if [[ -z "$host" || "$host" == "not exposed" ]]; then
        printf 'not exposed\n'
        return 0
    fi
    if [[ "$host" == *:* && "$host" != \[* ]]; then
        host="[$host]"
    fi
    if [[ "$port" == "443" ]]; then
        printf 'https://%s/\n' "$host"
    else
        printf 'https://%s:%s/\n' "$host" "$port"
    fi
}

compute_web_public_url() {
    [[ "${AWG_WEB_ENABLED:-1}" -eq 1 ]] || { printf 'not exposed\n'; return 0; }
    is_public_web_bind || { printf 'not exposed\n'; return 0; }
    format_https_url "${AWG_WEB_DOMAIN:-${AWG_ENDPOINT:-}}" "${AWG_WEB_PORT:-8443}"
}

compute_web_vpn_url() {
    [[ "${AWG_WEB_ENABLED:-1}" -eq 1 ]] || { printf 'not exposed\n'; return 0; }
    if is_public_web_bind || [[ "${AWG_WEB_BIND:-}" == "127.0.0.1" || "${AWG_WEB_BIND:-}" == "::1" ]]; then
        printf 'not exposed\n'
    else
        format_https_url "${AWG_WEB_BIND:-${AWG_TUNNEL_SUBNET%/*}}" "${AWG_WEB_PORT:-8443}"
    fi
}

compute_web_local_url() {
    [[ "${AWG_WEB_ENABLED:-1}" -eq 1 ]] || { printf 'not exposed\n'; return 0; }
    if [[ "${AWG_WEB_BIND:-}" == "127.0.0.1" || "${AWG_WEB_BIND:-}" == "::1" ]]; then
        format_https_url "${AWG_WEB_BIND}" "${AWG_WEB_PORT:-8443}"
    else
        printf 'not exposed\n'
    fi
}

compute_trusted_https_status() {
    local cert_file="${AWG_DIR}/web/cert.pem"
    [[ "${AWG_WEB_ENABLED:-1}" -eq 1 ]] || { printf 'no\n'; return 0; }
    [[ -f "$cert_file" ]] || { printf 'no\n'; return 0; }
    [[ "${AWG_WEB_CERT_FALLBACK_USED:-}" == "selfsigned" ]] && { printf 'no\n'; return 0; }
    case "${AWG_WEB_CERT_MODE:-selfsigned}" in
        letsencrypt|ip-domain|custom) printf 'yes\n' ;;
        *) printf 'no\n' ;;
    esac
}

compute_cert_summary() {
    local trusted_https
    trusted_https="$(compute_trusted_https_status)"
    cat <<EOF
Certificate mode: ${AWG_WEB_CERT_MODE:-selfsigned}
Certificate provider: ${AWG_WEB_CERT_PROVIDER:-none}
Certificate attempted mode: ${AWG_WEB_CERT_ATTEMPTED_MODE:-none}
Certificate fallback: ${AWG_WEB_CERT_FALLBACK_USED:-none}
Certificate failure reason: ${AWG_WEB_CERT_FAILURE_REASON:-none}
Trusted HTTPS: ${trusted_https}
EOF
}

sanitize_menu_choice() {
    local value="$1"
    value="$(sanitize_prompt_input "$value")"
    value="${value//[[:space:]]/}"
    printf '%s' "$value"
}

sanitize_prompt_input() {
    local value="$1"
    # Strip common ANSI/control input artifacts from arrow keys, bracketed paste,
    # backspace/delete, and terminal escape sequences before validation.
    value="$(printf '%s' "$value" | LC_ALL=C sed -E $'s/\x1B\\[[0-9;?]*[ -/]*[@-~]//g; s/\x1B\\][^\a]*(\a|\x1B\\\\)//g; s/\x1B\\[\\?2004[hl]//g')"
    value="${value//$'\177'/}"
    value="${value//$'\b'/}"
    value="$(printf '%s' "$value" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

read_clean_input() {
    local __var="$1" prompt="$2" raw=""
    read -rp "$prompt" raw < /dev/tty
    printf -v "$__var" '%s' "$(sanitize_prompt_input "$raw")"
}

ask_choice() {
    local __var="$1" prompt="$2" default="$3" allowed="$4" value
    while true; do
        read_clean_input value "$prompt"
        value="${value:-$default}"
        value="$(sanitize_menu_choice "$value")"
        if [[ " $allowed " == *" $value "* ]]; then
            printf -v "$__var" '%s' "$value"
            return 0
        fi
        log_warn "Некорректный выбор '$value'. Допустимо: $allowed"
    done
}

ask_port() {
    local __var="$1" prompt="$2" default="$3" value
    while true; do
        read_clean_input value "$prompt"
        value="${value:-$default}"
        if [[ "$value" =~ ^[0-9]+$ && "$value" -ge 1024 && "$value" -le 65535 ]]; then
            printf -v "$__var" '%s' "$value"
            return 0
        fi
        log_warn "Некорректный порт '$value'. Введите число 1024-65535."
    done
}

ask_web_port() {
    local __var_name="$1"
    local prompt="$2"
    local default="$3"
    local value=""

    while true; do
        read_clean_input value "$prompt"
        value="${value:-$default}"

        if validate_port_system "$value"; then
            printf -v "$__var_name" '%s' "$value"
            return 0
        fi

        log_warn "Некорректный HTTPS порт Web Panel '$value'. Введите число 1-65535."
    done
}


ask_yes_no() {
    local __var="$1" prompt="$2" default="$3" value
    while true; do
        read_clean_input value "$prompt"
        value="${value:-$default}"
        case "$value" in
            y|Y|yes|YES) printf -v "$__var" 'yes'; return 0 ;;
            n|N|no|NO) printf -v "$__var" 'no'; return 0 ;;
            *) log_warn "Введите y или n." ;;
        esac
    done
}

ask_domain() {
    local __var="$1" prompt="$2" default="${3:-}" value
    while true; do
        read_clean_input value "$prompt"
        value="${value:-$default}"
        if [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]; then
            printf -v "$__var" '%s' "$value"
            return 0
        fi
        log_warn "Некорректный домен. Используйте FQDN без пробелов и управляющих символов."
    done
}

ask_client_name() {
    local __var="$1" prompt="$2" value
    while true; do
        read_clean_input value "$prompt"
        if [[ "$value" =~ ^[A-Za-z0-9_-]{1,63}$ ]]; then
            printf -v "$__var" '%s' "$value"
            return 0
        fi
        log_warn "Некорректное имя клиента. Допустимы латиница, цифры, '_' и '-'."
    done
}

apply_web_port_default() {
    local config_exists="${1:-0}"
    [[ "${AWG_WEB_ENABLED:-1}" -eq 1 ]] || return 0
    [[ "$config_exists" -eq 0 ]] || return 0
    [[ -z "$CLI_WEB_PORT" && "$ENV_AWG_WEB_PORT_SET" -eq 0 ]] || return 0
    if is_public_web_bind && is_trusted_web_cert_mode; then
        AWG_WEB_PORT=443
    else
        AWG_WEB_PORT=8443
    fi
}

update_web_public_url() {
    AWG_WEB_PUBLIC_URL=""
    [[ "${AWG_WEB_ENABLED:-1}" -eq 1 ]] || return 0
    is_public_web_bind || return 0
    local host="${AWG_WEB_DOMAIN:-${AWG_ENDPOINT:-}}"
    [[ -n "$host" ]] || return 0
    AWG_WEB_PUBLIC_URL="$(format_https_url "$host" "${AWG_WEB_PORT:-8443}")"
}

prompt_web_certificate() {
    [[ "$AUTO_YES" -eq 0 ]] || return 0
    [[ "${AWG_WEB_ENABLED:-1}" -eq 1 ]] || return 0
    is_public_web_bind || return 0
    [[ -z "$CLI_WEB_CERT_MODE" && "$ENV_AWG_WEB_CERT_MODE_SET" -eq 0 ]] || return 0
    local cert_choice provider_choice domain_input cert_input key_input email_input generated_domain
    echo ""
    echo "Настройка HTTPS для публичной Web Panel:"
    echo "  1) Свой домен + Let's Encrypt — рекомендуется для доверенного HTTPS"
    echo "     Пример: https://vpn.example.com/"
    echo "  2) Автоматический IP-домен sslip.io/nip.io + Let's Encrypt — экспериментально"
    if generated_domain=$(generate_ip_domain "${AWG_ENDPOINT:-}" "sslip.io"); then
        echo "     Пример: $(format_https_url "$generated_domain" 443)"
    else
        echo "     Требует IPv4 endpoint; для обычного домена выберите вариант 1"
    fi
    echo "     Может упереться в лимиты Let's Encrypt для sslip.io/nip.io"
    echo "  3) Свой сертификат и ключ"
    echo "  4) Самоподписанный сертификат"
    echo "     Работает сразу, но браузер и WG Tunnel могут ругаться"
    ask_choice cert_choice "Ваш выбор [2]: " "2" "1 2 3 4 selfsigned"
    case "${cert_choice:-2}" in
        1)
            AWG_WEB_CERT_MODE="letsencrypt"
            read_clean_input domain_input "Введите домен Web Panel [Enter = выбрать экспериментальный IP-домен]: "
            if [[ -n "$domain_input" ]]; then
                ask_domain AWG_WEB_DOMAIN "Введите домен Web Panel: " "$domain_input"
            else
                log_warn "Домен не указан; выбран экспериментальный IP-domain mode."
                AWG_WEB_CERT_MODE="ip-domain"
                cert_choice=2
            fi
            if [[ "${AWG_WEB_CERT_MODE:-}" == "letsencrypt" ]]; then
                read_clean_input email_input "Email для Let's Encrypt уведомлений, Enter чтобы пропустить: "
                [[ -n "$email_input" ]] && AWG_WEB_LE_EMAIL="$email_input"
                return 0
            fi
            ;&
        2)
            AWG_WEB_CERT_MODE="ip-domain"
            AWG_CERT_FALLBACK_SELFSIGNED=1
            echo ""
            echo "Провайдер pseudo-domain:"
            echo "  1) sslip.io — удобно, но best-effort"
            echo "  2) nip.io"
            ask_choice provider_choice "Ваш выбор [1]: " "1" "1 2 sslip.io nip.io"
            case "${provider_choice:-1}" in
                1|sslip.io) AWG_WEB_CERT_PROVIDER="sslip.io" ;;
                2|nip.io) AWG_WEB_CERT_PROVIDER="nip.io" ;;
                *) log_warn "Неизвестный provider '${provider_choice}', выбран sslip.io."; AWG_WEB_CERT_PROVIDER="sslip.io" ;;
            esac
            AWG_WEB_DOMAIN="$(generate_ip_domain "${AWG_ENDPOINT:-}" "$AWG_WEB_CERT_PROVIDER")" || die "ip-domain требует IPv4 endpoint. Укажите IPv4 endpoint или выберите свой домен."
            AWG_WEB_PUBLIC_URL="$(format_https_url "$AWG_WEB_DOMAIN" 443)"
            log "Web Panel domain: $AWG_WEB_DOMAIN"
            log_warn "IP-domain через ${AWG_WEB_CERT_PROVIDER} — best-effort: Let's Encrypt может отказать из-за лимитов registered domain sslip.io/nip.io."
            log_warn "HTTP-01 требует входящий TCP/80 в UFW и provider firewall/security group."
            read_clean_input email_input "Email для Let's Encrypt уведомлений, Enter чтобы пропустить: "
            [[ -n "$email_input" ]] && AWG_WEB_LE_EMAIL="$email_input"
            ;;
        3)
            AWG_WEB_CERT_MODE="custom"
            while [[ ! -f "${AWG_WEB_CERT_FILE:-}" ]]; do
                read_clean_input cert_input "Путь к fullchain/cert.pem: "
                AWG_WEB_CERT_FILE="$cert_input"
            done
            while [[ ! -f "${AWG_WEB_KEY_FILE:-}" ]]; do
                read_clean_input key_input "Путь к private key: "
                AWG_WEB_KEY_FILE="$key_input"
            done
            read_clean_input domain_input "Домен Web Panel/Public URL host для сертификата: "
            [[ -n "$domain_input" ]] && AWG_WEB_DOMAIN="$domain_input"
            ;;
        4|selfsigned)
            AWG_WEB_CERT_MODE="selfsigned"
            log_warn "Публичная Web Panel с self-signed TLS не рекомендуется: браузер и WG Tunnel URL Import могут отклонять сертификат."
            ;;
        *) log_warn "Неизвестный TLS mode '$cert_choice', выбран ip-domain."; AWG_WEB_CERT_MODE="ip-domain"; AWG_WEB_CERT_PROVIDER="sslip.io"; AWG_WEB_DOMAIN="$(generate_ip_domain "${AWG_ENDPOINT:-}" "$AWG_WEB_CERT_PROVIDER")" || die "ip-domain требует IPv4 endpoint." ;;
    esac
}

prompt_web_panel() {
    [[ "$AUTO_YES" -eq 0 ]] || { warn_public_web_bind; return 0; }
    [[ "$CLI_DISABLE_WEB" -eq 0 ]] || return 0
    local web_enable web_choice input_port public_confirm
    if [[ "$ENV_AWG_WEB_ENABLED_SET" -eq 0 ]]; then
        ask_yes_no web_enable "Включить Web Panel? [Y/n]: " "y"
        if [[ "$web_enable" == "no" ]]; then
            AWG_WEB_ENABLED=0
            return 0
        fi
        AWG_WEB_ENABLED=1
    fi
    [[ "${AWG_WEB_ENABLED:-1}" -eq 1 ]] || return 0
    if [[ -z "$CLI_WEB_BIND" && "$ENV_AWG_WEB_BIND_SET" -eq 0 ]]; then
        echo ""
        echo "Доступ к Web Panel:"
        echo "  1) VPN-only, 10.9.9.1 — безопасно по умолчанию, порт 8443"
        echo "  2) localhost, 127.0.0.1 — только SSH tunnel, порт 8443"
        echo "  3) public, 0.0.0.0 — доступ из интернета, домен + HTTPS, порт 443"
        ask_choice web_choice "Ваш выбор [1]: " "1" "1 2 3"
        case "${web_choice:-1}" in
            1) AWG_WEB_BIND="10.9.9.1" ;;
            2) AWG_WEB_BIND="127.0.0.1" ;;
            3) AWG_WEB_BIND="0.0.0.0" ;;
            *) log_warn "Неизвестный режим Web Panel '$web_choice', выбран VPN-only."; AWG_WEB_BIND="10.9.9.1" ;;
        esac
    fi
    prompt_web_certificate
    apply_web_port_default 0
    warn_public_web_bind
    if [[ "$AWG_WEB_BIND" == "0.0.0.0" || "$AWG_WEB_BIND" == "::" ]]; then
        read_clean_input public_confirm "Вы открываете Web Panel в интернет. Продолжить? type YES: "
        [[ "$public_confirm" == "YES" ]] || die "Публичная Web Panel не подтверждена."
    fi
    if [[ -z "$CLI_WEB_PORT" && "$ENV_AWG_WEB_PORT_SET" -eq 0 ]]; then
        ask_web_port input_port "Введите HTTPS порт Web Panel [${AWG_WEB_PORT:-8443}]: " "${AWG_WEB_PORT:-8443}"
        AWG_WEB_PORT="$input_port"
    fi
}

prompt_adguard() {
    [[ "$AUTO_YES" -eq 0 && "$CLI_ENABLE_ADGUARD" -eq 0 && "$CLI_DISABLE_ADGUARD" -eq 0 && "$ENV_AWG_ADGUARD_ENABLED_SET" -eq 0 ]] || return 0
    local ag_enable input_port
    ask_yes_no ag_enable "Установить AdGuard Home для DNS? [Y/n]: " "y"
    if [[ "$ag_enable" == "no" ]]; then
        AWG_ADGUARD_ENABLED=0
        AWG_DNS_MODE="system"
        return 0
    fi
    AWG_ADGUARD_ENABLED=1
    AWG_DNS_MODE="adguard"
    if [[ -z "$CLI_ADGUARD_PORT" && "$ENV_AWG_ADGUARD_PORT_SET" -eq 0 ]]; then
        ask_port input_port "Введите порт AdGuard UI [${AWG_ADGUARD_PORT:-3000}]: " "${AWG_ADGUARD_PORT:-3000}"
        AWG_ADGUARD_PORT="$input_port"
    fi
}

prompt_p2p() {
    [[ "$AUTO_YES" -eq 0 && -z "$CLI_P2P_BASE_PORT" && -z "$CLI_P2P_PORTS_PER_CLIENT" && "$CLI_FULLCONE_NAT" -eq 0 && "$ENV_AWG_P2P_ENABLED_SET" -eq 0 ]] || return 0
    local p2p_enable input_base input_count fullcone
    ask_yes_no p2p_enable "Настроить P2P ports для клиентов? [Y/n]: " "y"
    if [[ "$p2p_enable" == "no" ]]; then
        AWG_P2P_ENABLED=0
        AWG_P2P_PORTS_PER_CLIENT=0
        AWG_FULLCONE_NAT=0
        return 0
    fi
    AWG_P2P_ENABLED=1
    if [[ "$ENV_AWG_P2P_BASE_PORT_SET" -eq 0 ]]; then
        ask_port input_base "Введите базовый P2P порт [${AWG_P2P_BASE_PORT:-20000}]: " "${AWG_P2P_BASE_PORT:-20000}"
        AWG_P2P_BASE_PORT="$input_base"
    fi
    if [[ "$ENV_AWG_P2P_PORTS_PER_CLIENT_SET" -eq 0 ]]; then
        ask_choice input_count "Введите количество P2P ports на клиента [${AWG_P2P_PORTS_PER_CLIENT:-3}]: " "${AWG_P2P_PORTS_PER_CLIENT:-3}" "0 1 2 3 4 5 6 7 8 9 10"
        AWG_P2P_PORTS_PER_CLIENT="$input_count"
    fi
    if [[ "$ENV_AWG_FULLCONE_NAT_SET" -eq 0 ]]; then
        ask_yes_no fullcone "Включить fullcone NAT? [y/N]: " "n"
        if [[ "$fullcone" == "yes" ]]; then AWG_FULLCONE_NAT=1; else AWG_FULLCONE_NAT=0; fi
    fi
}

validate_wiresock_domain() {
    local value="$1"
    [[ -n "$value" && ${#value} -le 253 ]] || return 1
    [[ "$value" != *[[:space:]]* && "$value" != *[[:cntrl:]]* ]] || return 1
    [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

apply_wiresock_profile_defaults() {
    case "${AWG_WIRESOCK_HINTS:-off}" in
        mobile)
            AWG_WIRESOCK_ID="${AWG_WIRESOCK_ID:-bag.itunes.apple.com}"
            AWG_WIRESOCK_IP="${AWG_WIRESOCK_IP:-quic}"
            AWG_WIRESOCK_IB="${AWG_WIRESOCK_IB:-curl}"
            ;;
        dns)
            AWG_WIRESOCK_ID="${AWG_WIRESOCK_ID:-yandex.ru}"
            AWG_WIRESOCK_IP="${AWG_WIRESOCK_IP:-dns}"
            AWG_WIRESOCK_IB="${AWG_WIRESOCK_IB:-chrome}"
            ;;
        quic|auto)
            AWG_WIRESOCK_ID="${AWG_WIRESOCK_ID:-ozon.ru}"
            AWG_WIRESOCK_IP="${AWG_WIRESOCK_IP:-quic}"
            AWG_WIRESOCK_IB="${AWG_WIRESOCK_IB:-curl}"
            ;;
    esac
}

validate_wiresock_settings() {
    case "${AWG_WIRESOCK_HINTS:-off}" in off|auto|mobile|quic|dns) ;; *) die "Некорректный --wiresock-hints=${AWG_WIRESOCK_HINTS}" ;; esac
    [[ "${AWG_WIRESOCK_HINTS:-off}" == "off" ]] && return 0
    apply_wiresock_profile_defaults
    validate_wiresock_domain "${AWG_WIRESOCK_ID:-}" || die "Некорректный WireSock Id/domain: '${AWG_WIRESOCK_ID:-}'"
    case "${AWG_WIRESOCK_IP:-}" in quic|dns) ;; *) die "Некорректный --wiresock-ip=${AWG_WIRESOCK_IP:-}" ;; esac
    case "${AWG_WIRESOCK_IB:-}" in curl|chrome) ;; *) die "Некорректный --wiresock-ib=${AWG_WIRESOCK_IB:-}" ;; esac
}

prompt_wiresock_hints() {
    [[ "$AUTO_YES" -eq 0 && -z "$CLI_WIRESOCK_HINTS" ]] || return 0
    local enable profile custom_id
    ask_yes_no enable "Добавить WireSock compatibility hints в клиентские конфиги? [Y/n]: " "y"
    if [[ "$enable" == "no" ]]; then
        AWG_WIRESOCK_HINTS="off"
        return 0
    fi
    echo "Это комментарии #@ws:*; обычные клиенты их игнорируют."
    echo "  1) quic/mobile-compatible: ozon.ru, quic, curl"
    echo "  2) mobile: bag.itunes.apple.com, quic, curl"
    echo "  3) dns: yandex.ru, dns, chrome"
    ask_choice profile "Профиль WireSock [1]: " "1" "1 2 3 quic mobile dns"
    case "${profile:-1}" in
        1|quic) AWG_WIRESOCK_HINTS="quic" ;;
        2|mobile) AWG_WIRESOCK_HINTS="mobile" ;;
        3|dns) AWG_WIRESOCK_HINTS="dns" ;;
        *) log_warn "Неизвестный WireSock profile '$profile', выбран quic."; AWG_WIRESOCK_HINTS="quic" ;;
    esac
    apply_wiresock_profile_defaults
    read_clean_input custom_id "WireSock Id/domain [${AWG_WIRESOCK_ID}]: "
    [[ -n "$custom_id" ]] && AWG_WIRESOCK_ID="$custom_id"
}

web_exposure_label() {
    if [[ "${AWG_WEB_ENABLED:-1}" -ne 1 ]]; then
        echo "disabled"
    elif [[ "${AWG_WEB_BIND:-}" == "0.0.0.0" || "${AWG_WEB_BIND:-}" == "::" ]]; then
        echo "public"
    elif [[ "${AWG_WEB_BIND:-}" == "127.0.0.1" || "${AWG_WEB_BIND:-}" == "::1" ]]; then
        echo "local"
    else
        echo "vpn-only"
    fi
}

ipv6_summary_line() {
    if [[ "${AWG_IPV6_ENABLED:-0}" -ne 1 ]]; then
        echo "disabled"
        return
    fi
    local requested="${AWG_IPV6_MODE_REQUESTED:-${AWG_IPV6_MODE:-legacy}}"
    local effective="${AWG_IPV6_MODE_EFFECTIVE:-${AWG_IPV6_MODE:-legacy}}"
    if [[ "$requested" == "auto" ]]; then
        echo "enabled, requested auto, effective ${effective}, ${AWG_IPV6_SUBNET:-auto}"
    else
        echo "enabled, ${effective}, ${AWG_IPV6_SUBNET:-auto}"
    fi
}

print_install_choice_summary() {
    echo ""
    echo "Итоговые параметры:"
    echo "Server name: ${AWG_SERVER_NAME:-MyVPN}"
    echo "Endpoint: ${AWG_ENDPOINT:-not set}"
    echo "VPN port: ${AWG_PORT}"
    echo "Route mode: $(route_mode_label)"
    echo "Preset: ${AWG_PRESET:-default}"
    echo "IPv6: $(ipv6_summary_line)"
    echo "Web: $(if [[ "${AWG_WEB_ENABLED:-1}" -eq 1 ]]; then echo "enabled, ${AWG_WEB_BIND:-none}, ${AWG_WEB_PORT:-8443}, $(web_exposure_label)"; else echo "disabled"; fi)"
    echo "AdGuard: $(if [[ "${AWG_ADGUARD_ENABLED:-0}" -eq 1 ]]; then echo "enabled, port ${AWG_ADGUARD_PORT:-3000}"; else echo "disabled"; fi)"
    echo "P2P: base ${AWG_P2P_BASE_PORT:-20000}, ports/client ${AWG_P2P_PORTS_PER_CLIENT:-0}, fullcone ${AWG_FULLCONE_NAT:-0}"
}

confirm_install_choices() {
    print_install_choice_summary
    [[ "$AUTO_YES" -eq 0 ]] || return 0
    local confirm_install
    read -rp "Продолжить установку? [Y/n]: " confirm_install < /dev/tty
    [[ "$confirm_install" =~ ^[Nn]$ ]] && die "Установка отменена пользователем."
    return 0
}

# ==============================================================================
# Генерация AWG 2.0 параметров (inline — нужны в шаге 0, до скачивания awg_common.sh)
# ==============================================================================

# Случайное число [min, max] через /dev/urandom (поддержка uint32)
rand_range() {
    local min=$1 max=$2
    local range=$((max - min + 1))
    local random_val
    random_val=$(od -An -tu4 -N4 /dev/urandom | tr -d ' ')
    if [[ -z "$random_val" || ! "$random_val" =~ ^[0-9]+$ ]]; then
        # Fallback: комбинация двух $RANDOM для 30-битного диапазона
        random_val=$(( (RANDOM << 15) | RANDOM ))
    fi
    echo $(( (random_val % range) + min ))
}

# Генерация 4 непересекающихся диапазонов для AWG H1-H4.
# Алгоритм: 8 случайных значений → sort → 4 пары (low, high).
# Сортировка гарантирует low ≤ high и непересечение между парами.
# Минимальная ширина каждого диапазона = 1000 (для нормальной обфускации).
# Печатает 4 строки формата "low-high" в stdout.
# Возвращает 1 если за 20 попыток не удалось получить корректные диапазоны.
#
# Диапазон: [0, 2^31-1] = [0, 2147483647]. Спецификация AmneziaWG допускает
# полный uint32 (0-4294967295), но standalone Windows-клиент
# `amneziawg-windows-client` имеет UI-валидатор ограниченный 2^31-1 в
# `ui/syntax/highlighter.go:isValidHField()` (upstream bug
# amnezia-vpn/amneziawg-windows-client#85, не исправлен). Значения выше
# 2^31-1 на сервере работают, но клиентский редактор подчёркивает их
# красным и не даёт сохранять правки. Для совместимости генерируем в
# безопасной половине диапазона (#40).
#
# Оптимизация: один вызов `od -N32 -tu4` читает 32 байта = 8 uint32 значений
# одной операцией, вместо 8 отдельных subprocess через rand_range.
# Fallback на rand_range если /dev/urandom недоступен.
generate_awg_h_ranges() {
    local attempt=0 max_attempts=20
    while (( attempt < max_attempts )); do
        local raw arr=() _v
        raw=$(od -An -N32 -tu4 /dev/urandom 2>/dev/null | tr -s ' \n' '\n' | sed '/^$/d')
        if [[ -n "$raw" ]]; then
            local count=0
            while IFS= read -r _v; do
                [[ "$_v" =~ ^[0-9]+$ ]] || continue
                # Маска 0x7FFFFFFF: очищает старший бит, значение в [0, 2^31-1]
                # без bias (каждый младший бит независим).
                arr+=("$(( _v & 2147483647 ))")
                count=$((count + 1))
                (( count == 8 )) && break
            done <<< "$raw"
        fi
        if (( ${#arr[@]} != 8 )); then
            arr=()
            local _i
            for _i in 1 2 3 4 5 6 7 8; do
                arr+=("$(rand_range 0 2147483647)")
            done
        fi
        local sorted
        sorted=$(printf '%s\n' "${arr[@]}" | sort -n)
        arr=()
        while IFS= read -r _v; do arr+=("$_v"); done <<< "$sorted"
        if (( ${arr[1]} - ${arr[0]} >= 1000 )) && \
           (( ${arr[3]} - ${arr[2]} >= 1000 )) && \
           (( ${arr[5]} - ${arr[4]} >= 1000 )) && \
           (( ${arr[7]} - ${arr[6]} >= 1000 )); then
            printf '%s-%s\n' "${arr[0]}" "${arr[1]}"
            printf '%s-%s\n' "${arr[2]}" "${arr[3]}"
            printf '%s-%s\n' "${arr[4]}" "${arr[5]}"
            printf '%s-%s\n' "${arr[6]}" "${arr[7]}"
            return 0
        fi
        attempt=$((attempt + 1))
    done
    return 1
}

# Генерация CPS строки для I1
# Формат: "<r N>" где N — количество случайных байт (32-256)
generate_cps_i1() {
    local n
    n=$(rand_range 32 256)
    echo "<r ${n}>"
}

# Генерация всех AWG 2.0 параметров
# Поддерживает --preset=default|mobile и точечные --jc/--jmin/--jmax overrides
generate_awg_params() {
    local preset="${CLI_PRESET:-${AWG_PRESET:-default}}"
    log "Генерация параметров AWG 2.0 (preset: $preset)..."

    case "$preset" in
        default)
            # Jc 3-6: компромисс между обфускацией и совместимостью с мобильными (Discussion #38)
            AWG_Jc=$(rand_range 3 6)
            AWG_Jmin=$(rand_range 40 89)
            # Jmax = Jmin + 50..250 (~90-339 байт, Issue #42)
            AWG_Jmax=$(( AWG_Jmin + $(rand_range 50 250) ))
            ;;
        mobile)
            # Jc=3 фиксированный: alkorrnd (Tele2) — Jc=3 >95%, Jc=4 ~30%, Jc=5 <5%
            # Узкий Jmax: markmokrenko (Yota) — Jmax=70 работает, Jmax>300 блокируется
            AWG_Jc=3
            AWG_Jmin=$(rand_range 30 50)
            AWG_Jmax=$(( AWG_Jmin + $(rand_range 20 80) ))
            log "  Preset 'mobile': Jc=3, узкий Jmax для мобильных сетей"
            ;;
        *)
            die "Неизвестный preset: '$preset'. Допустимые: default, mobile"
            ;;
    esac

    # Точечные CLI overrides (поверх preset)
    if [[ -n "${CLI_JC:-}" ]]; then
        validate_jc_value "$CLI_JC" || die "Невалидный --jc=$CLI_JC (допустимо: 1-128)"
        AWG_Jc="$CLI_JC"
    fi
    if [[ -n "${CLI_JMIN:-}" ]]; then
        validate_junk_size "$CLI_JMIN" || die "Невалидный --jmin=$CLI_JMIN (допустимо: 0-1280)"
        AWG_Jmin="$CLI_JMIN"
    fi
    if [[ -n "${CLI_JMAX:-}" ]]; then
        validate_junk_size "$CLI_JMAX" || die "Невалидный --jmax=$CLI_JMAX (допустимо: 0-1280)"
        AWG_Jmax="$CLI_JMAX"
    fi

    # Sanity: Jmax >= Jmin
    if [[ "$AWG_Jmax" -lt "$AWG_Jmin" ]]; then
        die "Jmax ($AWG_Jmax) не может быть меньше Jmin ($AWG_Jmin)"
    fi

    AWG_PRESET="$preset"
    AWG_S1=$(rand_range 15 150)
    AWG_S2=$(rand_range 15 150)

    # Критическое ограничение из kernel: S1+56 != S2
    # Предотвращает одинаковый размер init и response сообщений
    while [[ $((AWG_S1 + 56)) -eq $AWG_S2 ]]; do
        AWG_S2=$(rand_range 15 150)
    done

    AWG_S3=$(rand_range 8 55)
    AWG_S4=$(rand_range 4 27)

    # H1-H4: 4 случайных непересекающихся uint32 диапазона.
    # Рандомизация на каждую установку защищает от ТСПУ-фингерпринта
    # по статическим H-значениям (Discussion #38, elvaleto/Klavishnik).
    # Алгоритм: 8 случайных uint32 → sort → 4 непересекающиеся пары.
    local _h_lines
    mapfile -t _h_lines < <(generate_awg_h_ranges) || true
    if [[ ${#_h_lines[@]} -ne 4 ]]; then
        die "Не удалось сгенерировать H1-H4 диапазоны."
    fi
    AWG_H1="${_h_lines[0]}"
    AWG_H2="${_h_lines[1]}"
    AWG_H3="${_h_lines[2]}"
    AWG_H4="${_h_lines[3]}"

    # I1: CPS concealment
    AWG_I1=$(generate_cps_i1)

    export AWG_Jc AWG_Jmin AWG_Jmax AWG_S1 AWG_S2 AWG_S3 AWG_S4 AWG_PRESET
    export AWG_H1 AWG_H2 AWG_H3 AWG_H4 AWG_I1

    log "  Jc=$AWG_Jc, Jmin=$AWG_Jmin, Jmax=$AWG_Jmax"
    log "  S1=$AWG_S1, S2=$AWG_S2, S3=$AWG_S3, S4=$AWG_S4"
    log "  H1=$AWG_H1"
    log "  H2=$AWG_H2"
    log "  H3=$AWG_H3"
    log "  H4=$AWG_H4"
    log "  I1=$AWG_I1"
    log "Параметры AWG 2.0 сгенерированы."
}

# ==============================================================================
# Системная оптимизация (новое в v5.0)
# ==============================================================================

# Определение характеристик железа
detect_hardware() {
    TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
    CPU_CORES=$(nproc)
    MAIN_NIC=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    log "Железо: RAM=${TOTAL_RAM_MB}MB, CPU=${CPU_CORES} ядер, NIC=${MAIN_NIC}"
}

# Удаление ненужных пакетов и сервисов
cleanup_system() {
    log "Очистка системы от ненужных компонентов..."

    # Снимок default route ДО очистки: cleanup не должен ломать сетевой стек.
    # На новых Ubuntu ISO autoremove после purge cloud-init может удалить
    # netplan-generator как transitive dependency и оставить сервер без сети.
    local pre_default_route
    pre_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
    log_debug "Pre-cleanup default route: ${pre_default_route:-<none>}"

    # Hold критичных пакетов сетевого стека. Сохраняем pre-existing user holds:
    # снимаем только те hold, которые поставили сами в этом запуске.
    local _hold_pkgs="netplan.io netplan-generator systemd-resolved netcfg ifupdown"
    local _preexisting_holds=""
    _preexisting_holds="$(apt-mark showhold 2>/dev/null || true)"
    local _held_actual=()
    local _hpkg
    for _hpkg in $_hold_pkgs; do
        if dpkg-query -W -f='${Status}' "$_hpkg" 2>/dev/null | grep -q "ok installed"; then
            if grep -qxF "$_hpkg" <<<"$_preexisting_holds"; then
                continue
            fi
            apt-mark hold "$_hpkg" >/dev/null 2>&1 && _held_actual+=("$_hpkg")
        fi
    done
    [ ${#_held_actual[@]} -gt 0 ] && log_debug "Apt-mark hold: ${_held_actual[*]}"

    # Пакеты для удаления (безопасные для VPS)
    # snapd и lxd-agent-loader — только на Ubuntu, на Debian их нет
    local packages_to_remove=()
    local pkg
    local cleanup_list="modemmanager networkd-dispatcher unattended-upgrades packagekit udisks2"
    if [[ "${OS_ID:-ubuntu}" == "ubuntu" ]]; then
        cleanup_list="snapd $cleanup_list lxd-agent-loader"
    fi
    for pkg in $cleanup_list; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            packages_to_remove+=("$pkg")
        fi
    done

    if [ ${#packages_to_remove[@]} -gt 0 ]; then
        log "Удаление: ${packages_to_remove[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get purge -y "${packages_to_remove[@]}" || log_warn "Ошибка удаления некоторых пакетов"
    fi

    # Очистка snap артефактов (только Ubuntu)
    if [[ "${OS_ID:-ubuntu}" == "ubuntu" && -d /snap ]]; then
        log "Очистка snap артефактов..."
        rm -rf /snap /var/snap /var/lib/snapd 2>/dev/null || log_warn "Ошибка очистки snap"
    fi

    # cloud-init: удалять только если НЕ управляет сетью
    # Консервативный подход: сначала проверяем маркеры cloud-init, затем renderer
    if dpkg-query -W -f='${Status}' cloud-init 2>/dev/null | grep -q "ok installed"; then
        local cloud_manages_network=0
        # Проверяем маркеры cloud-init (приоритет — безопасность)
        if ls /etc/netplan/*cloud-init* &>/dev/null 2>&1; then
            cloud_manages_network=1
        elif grep -rq "cloud-init" /etc/netplan/ 2>/dev/null; then
            cloud_manages_network=1
        elif [[ -f /etc/network/interfaces ]] && grep -q "cloud-init" /etc/network/interfaces 2>/dev/null; then
            cloud_manages_network=1
        fi
        if [[ $cloud_manages_network -eq 0 ]]; then
            log "Удаление cloud-init (сеть не зависит от него)..."
            DEBIAN_FRONTEND=noninteractive apt-get purge -y cloud-init 2>/dev/null || log_warn "Ошибка удаления cloud-init"
            rm -rf /etc/cloud /var/lib/cloud 2>/dev/null
        else
            log_warn "cloud-init управляет сетью — пропускаем удаление."
        fi
    fi

    # apt-get autoremove намеренно не запускаем: он может снести netplan-generator
    # и сломать default route. Небольшой объём orphan-пакетов безопаснее
    # потенциальной потери SSH-доступа.
    local _upkg
    for _upkg in "${_held_actual[@]}"; do
        apt-mark unhold "$_upkg" >/dev/null 2>&1 || true
    done

    local post_default_route
    post_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
    if [[ -n "$pre_default_route" && -z "$post_default_route" ]]; then
        log_error "Маршрут по умолчанию потерян после очистки. Попытка восстановления..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            netplan.io 2>/dev/null || true
        if apt-cache show netplan-generator &>/dev/null; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                netplan-generator 2>/dev/null || true
        fi
        systemctl restart systemd-networkd 2>/dev/null || true
        netplan apply 2>/dev/null || true
        local _wait
        for _wait in 1 2 3 5 5 5 5; do
            post_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
            [[ -n "$post_default_route" ]] && break
            sleep "$_wait"
        done
        if [[ -z "$post_default_route" ]]; then
            local _iface
            _iface="$(awk '{for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit } }' <<<"$pre_default_route")"
            if [[ -n "$_iface" ]]; then
                log_warn "Финальная попытка поднять интерфейс $_iface..."
                ip link set "$_iface" up 2>/dev/null || true
                if command -v networkctl &>/dev/null; then
                    networkctl renew "$_iface" 2>/dev/null || true
                    sleep 3
                    post_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
                fi
                if [[ -z "$post_default_route" ]] && command -v dhclient &>/dev/null; then
                    dhclient -4 "$_iface" 2>/dev/null || true
                    sleep 3
                    post_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
                fi
            fi
        fi
        if [[ -z "$post_default_route" ]]; then
            die "Сеть не восстановилась после cleanup_system. Восстановите её с консоли (например: sudo dhclient -4 <интерфейс>) и перезапустите установщик с флагом --no-tweaks."
        fi
        log_warn "Сеть восстановлена: $post_default_route"
    fi
    log "Очистка системы завершена."
}

# Настройка swap
optimize_swap() {
    log "Оптимизация swap..."
    local target_swap_mb

    if [[ $TOTAL_RAM_MB -le 2048 ]]; then
        target_swap_mb=1024
    else
        target_swap_mb=512
    fi

    # Проверяем текущий swap
    local current_swap_mb
    current_swap_mb=$(free -m | awk '/Swap:/ {print $2}')

    if [[ $current_swap_mb -ge $target_swap_mb ]]; then
        log "Swap уже достаточен: ${current_swap_mb}MB (цель: ${target_swap_mb}MB)"
    else
        log "Создание swap файла: ${target_swap_mb}MB"
        # Отключаем существующий swap файл если есть
        if [[ -f /swapfile ]]; then
            swapoff /swapfile 2>/dev/null
            rm -f /swapfile
        fi
        dd if=/dev/zero of=/swapfile bs=1M count="$target_swap_mb" status=none 2>/dev/null || {
            log_warn "Ошибка создания swap файла"
            return 1
        }
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1 || { log_warn "Ошибка mkswap"; return 1; }
        swapon /swapfile || { log_warn "Ошибка swapon"; return 1; }
        # Добавляем в fstab если отсутствует. Точная проверка по полям:
        # игнорируем закомментированные строки и partial matches (например,
        # `/swapfile.bak` или старая строка в комментарии).
        if ! awk '!/^[[:space:]]*#/ && $1 == "/swapfile" && $3 == "swap" {found=1} END {exit !(found+0)}' \
             /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        log "Swap файл создан: ${target_swap_mb}MB"
    fi

    # Настройка swappiness
    sysctl -w vm.swappiness=10 >/dev/null 2>&1
}

# Оптимизация сетевого интерфейса
optimize_nic() {
    if [[ -z "$MAIN_NIC" ]]; then
        log_warn "Основной NIC не определён, пропуск оптимизации."
        return 1
    fi

    if ! command -v ethtool &>/dev/null; then
        log_debug "ethtool не найден, пропуск NIC оптимизации."
        return 0
    fi

    log "Оптимизация NIC: $MAIN_NIC"
    # Отключение GRO/GSO/TSO — могут мешать VPN-трафику
    ethtool -K "$MAIN_NIC" gro off 2>/dev/null || log_debug "GRO: не поддерживается/уже выкл."
    ethtool -K "$MAIN_NIC" gso off 2>/dev/null || log_debug "GSO: не поддерживается/уже выкл."
    ethtool -K "$MAIN_NIC" tso off 2>/dev/null || log_debug "TSO: не поддерживается/уже выкл."
    log "NIC оптимизация завершена."
}

# Полная оптимизация системы
optimize_system() {
    log "Оптимизация системы под VPN-сервер..."
    detect_hardware
    optimize_swap
    optimize_nic
    log "Оптимизация системы завершена."
}

# ==============================================================================
# Настройка sysctl (минимальная, для --no-tweaks)
# ==============================================================================

setup_minimal_sysctl() {
    log "Настройка минимального sysctl (--no-tweaks)..."
    local f="/etc/sysctl.d/99-amneziawg-forwarding.conf"
    cat > "$f" << SYSEOF
# AmneziaWG — минимальные настройки (--no-tweaks)
net.ipv4.ip_forward = 1
SYSEOF
    if [[ "${DISABLE_IPV6:-1}" -eq 1 ]]; then
        cat >> "$f" << SYSEOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
SYSEOF
else
    cat >> "$f" << SYSEOF
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.all.proxy_ndp = ${AWG_IPV6_NDP_PROXY:-0}
SYSEOF
    fi
    sysctl -p "$f" >/dev/null 2>&1 || log_warn "Ошибка sysctl -p"
    log "Минимальный sysctl настроен."
}

# ==============================================================================
# Настройка sysctl (расширенная)
# ==============================================================================

setup_advanced_sysctl() {
    log "Настройка sysctl..."
    local f="/etc/sysctl.d/99-amneziawg-security.conf"

    # Адаптивные буферы по объёму RAM
    local rmem_max wmem_max netdev_backlog
    if [[ ${TOTAL_RAM_MB:-1024} -ge 2048 ]]; then
        rmem_max=16777216    # 16MB
        wmem_max=16777216
        netdev_backlog=5000
    else
        rmem_max=4194304     # 4MB
        wmem_max=4194304
        netdev_backlog=2500
    fi

    cat > "$f" << EOF
# AmneziaWG 2.0 Security/Performance Settings - $(date)
# Автоматически сгенерировано install_amneziawg.sh v${SCRIPT_VERSION}

# --- IP Forwarding ---
net.ipv4.ip_forward = 1
$(if [[ "${DISABLE_IPV6:-1}" -eq 1 ]]; then
    echo "net.ipv6.conf.all.disable_ipv6 = 1"
    echo "net.ipv6.conf.default.disable_ipv6 = 1"
    echo "net.ipv6.conf.lo.disable_ipv6 = 1"
else
    echo "# IPv6 не отключен"
    echo "net.ipv6.conf.all.forwarding = 1"
    echo "net.ipv6.conf.all.proxy_ndp = ${AWG_IPV6_NDP_PROXY:-0}"
fi)

# --- TCP/IP Hardening ---
# rp_filter = 2 (loose mode): проверяет source IP по ANY маршруту в таблице,
# а не по обратному маршруту через тот же интерфейс. Strict mode (=1) ломает
# routing на облачных хостерах (Hetzner и подобных) где шлюз в другой подсети,
# чем IP самой VPS — ответные пакеты не проходят strict reverse path check.
# Loose mode безопасен: подделанные source IP всё равно отсеиваются если для
# них нет маршрута вообще. Discussion #41 (z036).
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5
net.ipv4.tcp_rfc1337 = 1

# --- Redirects ---
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
$(if [[ "${DISABLE_IPV6:-1}" -ne 1 ]]; then
    echo "net.ipv6.conf.all.accept_redirects = 0"
    echo "net.ipv6.conf.default.accept_redirects = 0"
fi)

# --- BBR Congestion Control ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- Network Buffers (adaptive) ---
net.core.rmem_max = ${rmem_max}
net.core.wmem_max = ${wmem_max}
net.core.netdev_max_backlog = ${netdev_backlog}

# --- Conntrack ---
net.netfilter.nf_conntrack_max = 65536

# --- Security ---
vm.swappiness = 10
kernel.sysrq = 0

# Подавление kernel warning/notice messages в VNC-консоли хостера.
# Без этого fail2ban UFW-блокировки спамят VNC окно строками типа
# "[UFW BLOCK]" и делают консоль непригодной для работы.
# Format: console_loglevel default_msg_loglevel min_console_loglevel default_console_loglevel
# Значение 3 = KERN_ERR — на консоль идут только ошибки и критические.
# Discussion #41 (z036).
kernel.printk = 3 4 1 3
EOF

    log "Применение sysctl..."
    if ! sysctl -p "$f" >/dev/null 2>&1; then
        # nf_conntrack может быть недоступен до загрузки модуля
        log_warn "Некоторые параметры sysctl не применились (nf_conntrack будет доступен позже)."
        sysctl -p "$f" 2>/dev/null || true
    fi
}


# ==============================================================================
# Voice / Calls optimization: безопасный UDP conntrack tuning
# ==============================================================================

setup_voice_udp_optimization() {
    log "Настройка Voice / Calls UDP optimization..."
    local udp_proc="/proc/sys/net/netfilter/nf_conntrack_udp_timeout"
    local max_proc="/proc/sys/net/netfilter/nf_conntrack_max"
    local udp_file="/etc/sysctl.d/99-awg-udp.conf"
    local max_file="/etc/sysctl.d/99-awg-conntrack.conf"

    if [[ ! -e "$udp_proc" ]]; then
        modprobe nf_conntrack >/dev/null 2>&1 || log_warn "Не удалось загрузить nf_conntrack; продолжаю без UDP conntrack tuning."
    fi
    if [[ -e "$udp_proc" ]]; then
        cat > "$udp_file" <<'EOF'
# AmneziaWG safe Voice / Calls UDP tuning
net.netfilter.nf_conntrack_udp_timeout=120
net.netfilter.nf_conntrack_udp_timeout_stream=300
EOF
        sysctl -p "$udp_file" >/dev/null 2>&1 || log_warn "Не удалось применить $udp_file; продолжаю."
    else
        log_warn "nf_conntrack UDP sysctl недоступен; Voice / Calls UDP tuning пропущен."
    fi

    if [[ -r "$max_proc" ]]; then
        local current_max target_max=262144 desired_max
        current_max=$(cat "$max_proc" 2>/dev/null || echo 0)
        if [[ "$current_max" =~ ^[0-9]+$ ]]; then
            if (( current_max < target_max )); then
                desired_max=$target_max
            elif [[ -f "$max_file" ]]; then
                desired_max=$current_max
            else
                desired_max=""
            fi
            if [[ -n "$desired_max" ]]; then
                cat > "$max_file" <<EOF
# AmneziaWG safe conntrack capacity floor
net.netfilter.nf_conntrack_max=${desired_max}
EOF
                sysctl -p "$max_file" >/dev/null 2>&1 || log_warn "Не удалось применить $max_file; продолжаю."
            fi
        fi
    else
        log_warn "nf_conntrack_max недоступен; увеличение таблицы conntrack пропущено."
    fi
}

# ==============================================================================
# Фаервол и безопасность
# ==============================================================================

detect_ssh_ports() {
    local ports="" p pp valid=""
    local awk_ports='tolower($1)=="port"&&$2~/^[0-9]+$/{print $2} tolower($1)=="listenaddress"{v=$2; if(v~/\]:[0-9]+$/){sub(/.*\]:/,"",v); print v} else if(v~/^[0-9.]+:[0-9]+$/){sub(/.*:/,"",v); print v}}'

    if [[ -n "$CLI_SSH_PORT" ]]; then
        ports="${CLI_SSH_PORT//,/ }"
    else
        if command -v sshd &>/dev/null; then
            ports+=" $(sshd -T 2>/dev/null | awk "$awk_ports" | tr '\n' ' ')"
        fi
        if command -v ss &>/dev/null; then
            ports+=" $(ss -H -tlnp 2>/dev/null | awk '/"sshd"/{n=split($4,a,":"); print a[n]}' | tr '\n' ' ')"
        fi
        if [[ -n "${SSH_CONNECTION:-}" ]]; then
            ports+=" $(awk '{print $4}' <<<"$SSH_CONNECTION")"
        fi
        if [[ -z "${ports// }" ]]; then
            local cfgs=() d
            [[ -f /etc/ssh/sshd_config ]] && cfgs+=(/etc/ssh/sshd_config)
            for d in /etc/ssh/sshd_config.d/*.conf; do
                [[ -f "$d" ]] && cfgs+=("$d")
            done
            if [[ "${#cfgs[@]}" -gt 0 ]]; then
                ports+=" $(awk "$awk_ports" "${cfgs[@]}" 2>/dev/null | tr '\n' ' ')"
            fi
        fi
    fi

    for p in $ports; do
        if [[ "$p" =~ ^[0-9]+$ ]]; then
            pp=$((10#$p))
            if (( pp >= 1 && pp <= 65535 )); then
                case " $valid " in
                    *" $pp "*) ;;
                    *) valid+="${valid:+ }$pp" ;;
                esac
            fi
        fi
    done

    if [[ -z "$valid" ]]; then
        [[ -n "$CLI_SSH_PORT" ]] && log_warn "--ssh-port не содержит валидных портов, использую 22."
        valid="22"
    fi
    printf '%s' "$valid"
}

setup_improved_firewall() {
    if [[ "${AWG_DISABLE_UFW:-0}" == "1" ]]; then
        log_warn "UFW отключён пользователем (--disable-ufw/AWG_DISABLE_UFW=1)."
        log_warn "Убедитесь, что внешний firewall открывает VPN/Web ports и не открывает AdGuard наружу."
        return 0
    fi
    log "Настройка UFW..."
    if ! command -v ufw &>/dev/null; then install_packages ufw; fi

    # Определяем основной сетевой интерфейс для правила маршрутизации
    local main_nic
    main_nic=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    if [[ -z "$main_nic" ]]; then
        log_warn "Не удалось определить сетевой интерфейс для UFW route."
    fi

    local ssh_ports _sp
    ssh_ports=$(detect_ssh_ports)
    log "SSH-порт(ы) для правила UFW: ${ssh_ports}"

    local ufw_errors=0
    allow_web_panel_ufw() {
        [[ "${AWG_WEB_ENABLED:-1}" -eq 1 ]] || return 0
        if [[ "$AWG_WEB_BIND" == "0.0.0.0" || "$AWG_WEB_BIND" == "::" ]]; then
            log_warn "Веб-панель привязана публично (${AWG_WEB_BIND}); порт ${AWG_WEB_PORT}/tcp будет открыт глобально."
            ufw allow "${AWG_WEB_PORT}/tcp" comment "AmneziaWG Web Panel" || { log_warn "UFW: ошибка allow Web port"; ufw_errors=1; }
        elif [[ "$AWG_WEB_BIND" == "127.0.0.1" || "$AWG_WEB_BIND" == "::1" ]]; then
            log "Веб-панель привязана локально (${AWG_WEB_BIND}); глобальное UFW-правило не требуется."
        else
            ufw allow in on awg0 to "${AWG_WEB_BIND}" port "${AWG_WEB_PORT}" proto tcp comment "AmneziaWG Web Panel VPN-only" || { log_warn "UFW: ошибка allow Web port on awg0"; ufw_errors=1; }
        fi
    }
    if ufw status 2>/dev/null | grep -q inactive; then
        log "UFW неактивен. Настройка..."
        ufw default deny incoming  || { log_warn "UFW: ошибка default deny incoming"; ufw_errors=1; }
        ufw default allow outgoing || { log_warn "UFW: ошибка default allow outgoing"; ufw_errors=1; }
        for _sp in $ssh_ports; do
            ufw limit "${_sp}/tcp" comment "SSH Rate Limit" || { log_warn "UFW: ошибка limit SSH (порт ${_sp})"; ufw_errors=1; }
        done
        ufw allow "${AWG_PORT}/udp" comment "AmneziaWG VPN" || { log_warn "UFW: ошибка allow VPN port"; ufw_errors=1; }
        allow_web_panel_ufw
        if [[ "${AWG_ADGUARD_ENABLED:-0}" -eq 1 ]]; then
            ufw allow in on awg0 to any port 53 proto udp comment "AmneziaWG AdGuard DNS UDP" || log_warn "UFW: ошибка allow DNS UDP on awg0"
            ufw allow in on awg0 to any port 53 proto tcp comment "AmneziaWG AdGuard DNS TCP" || log_warn "UFW: ошибка allow DNS TCP on awg0"
            ufw allow in on awg0 to any port "${AWG_ADGUARD_PORT}" proto tcp comment "AmneziaWG AdGuard UI" || log_warn "UFW: ошибка allow AdGuard UI on awg0"
        fi
        if [[ -n "$main_nic" ]]; then
            ufw route allow in on awg0 out on "$main_nic" comment "AmneziaWG Routing" \
                || { log_warn "UFW: ошибка route rule"; ufw_errors=1; }
            log "Правило маршрутизации VPN добавлено (awg0 → ${main_nic})."
        fi
        if [[ "$ufw_errors" -ne 0 ]]; then
            log_error "Одна или несколько правил UFW не применились. Проверьте настройки вручную."
            return 1
        fi
        log "Правила UFW добавлены."
        log_warn "--- ВКЛЮЧЕНИЕ UFW ---"
        log_warn "UFW разрешит SSH только на порту(ах): ${ssh_ports}. Проверьте SSH доступ!"
        local confirm_ufw="y"
        if [[ "$AUTO_YES" -eq 0 ]]; then
            sleep 5
            read -rp "Включить UFW? [Y/n]: " confirm_ufw < /dev/tty
            confirm_ufw="${confirm_ufw:-y}"
        else
            log "Автоматическое включение UFW (--yes)."
        fi
        if [[ "$confirm_ufw" =~ ^[Nn]$ ]]; then
            AWG_DISABLE_UFW=1
            log_warn "UFW не включён. Убедитесь, что внешний firewall открывает VPN/Web ports и не открывает AdGuard наружу."
            return 0
        fi
        if ! ufw enable <<< "y"; then die "Ошибка включения UFW."; fi
        log "UFW включен."
        # Маркер: UFW был включён нашим установщиком (а не пользователем заранее).
        # Используется в step_uninstall чтобы решить, безопасно ли отключать UFW.
        # Защита от destructive uninstall на VPS где UFW использовался для SSH/web
        # hardening ДО установки нашего скрипта (audit).
        touch "$AWG_DIR/.ufw_enabled_by_installer" 2>/dev/null || \
            log_warn "Не удалось создать UFW marker — uninstall не сможет отключить UFW автоматически."
    else
        log "UFW активен. Обновление правил..."
        for _sp in $ssh_ports; do
            ufw limit "${_sp}/tcp" comment "SSH Rate Limit" || { log_warn "UFW: ошибка limit SSH (порт ${_sp})"; ufw_errors=1; }
        done
        ufw allow "${AWG_PORT}/udp" comment "AmneziaWG VPN" || { log_warn "UFW: ошибка allow VPN port"; ufw_errors=1; }
        allow_web_panel_ufw
        if [[ "${AWG_ADGUARD_ENABLED:-0}" -eq 1 ]]; then
            ufw allow in on awg0 to any port 53 proto udp comment "AmneziaWG AdGuard DNS UDP" || log_warn "UFW: ошибка allow DNS UDP on awg0"
            ufw allow in on awg0 to any port 53 proto tcp comment "AmneziaWG AdGuard DNS TCP" || log_warn "UFW: ошибка allow DNS TCP on awg0"
            ufw allow in on awg0 to any port "${AWG_ADGUARD_PORT}" proto tcp comment "AmneziaWG AdGuard UI" || log_warn "UFW: ошибка allow AdGuard UI on awg0"
        fi
        if [[ -n "$main_nic" ]]; then
            ufw route allow in on awg0 out on "$main_nic" comment "AmneziaWG Routing" \
                || { log_warn "UFW: ошибка route rule"; ufw_errors=1; }
        fi
        if [[ "$ufw_errors" -ne 0 ]]; then
            log_error "Одна или несколько правил UFW не применились. Проверьте настройки вручную."
            return 1
        fi
        ufw reload || log_warn "Ошибка перезагрузки UFW."
        log "Правила обновлены."
    fi
    log "UFW настроен."
    log "$(ufw status verbose 2>&1)"
    return 0
}

secure_files() {
    log "Установка безопасных прав доступа..."
    chmod 700 "$AWG_DIR" 2>/dev/null
    chmod 700 /etc/amnezia 2>/dev/null
    chmod 700 /etc/amnezia/amneziawg 2>/dev/null
    chmod 600 /etc/amnezia/amneziawg/*.conf 2>/dev/null
    find "$AWG_DIR" -name "*.conf" -type f -exec chmod 600 {} \; 2>/dev/null
    find "$AWG_DIR" -name "*.key" -type f -exec chmod 600 {} \; 2>/dev/null
    find "$AWG_DIR" -name "*.png" -type f -exec chmod 600 {} \; 2>/dev/null
    find "$AWG_DIR" -name "*.vpnuri" -type f -exec chmod 600 {} \; 2>/dev/null
    if [[ -d "$KEYS_DIR" ]]; then
        chmod 700 "$KEYS_DIR" 2>/dev/null
        chmod 600 "$KEYS_DIR"/* 2>/dev/null
    fi
    [[ -f "$CONFIG_FILE" ]] && chmod 600 "$CONFIG_FILE"
    [[ -f "$LOG_FILE" ]] && chmod 640 "$LOG_FILE"
    [[ -f "$MANAGE_SCRIPT_PATH" ]] && chmod 700 "$MANAGE_SCRIPT_PATH"
    [[ -f "$COMMON_SCRIPT_PATH" ]] && chmod 700 "$COMMON_SCRIPT_PATH"
    log "Права доступа установлены."
}

setup_fail2ban() {
    log "Настройка Fail2Ban..."
    if ! command -v fail2ban-client &>/dev/null; then install_packages fail2ban; fi
    if ! command -v fail2ban-client &>/dev/null; then
        log_warn "Fail2ban не установлен, пропускаем."
        return 1
    fi

    # Debian: journald вместо rsyslog, нужен python3-systemd
    if [[ "${OS_ID:-}" == "debian" ]]; then
        install_packages python3-systemd
    fi

    mkdir -p /etc/fail2ban/jail.d 2>/dev/null

    # Backend: systemd для Debian (нет rsyslog), auto для Ubuntu
    local f2b_backend="auto"
    if [[ "${OS_ID:-}" == "debian" ]]; then
        f2b_backend="systemd"
    fi

    cat > /etc/fail2ban/jail.d/amneziawg.conf << JAILEOF || { log_warn "Ошибка записи jail.d/amneziawg.conf"; return 1; }
# AmneziaWG — SSH protection (managed by amneziawg-installer)
[sshd]
enabled = true
backend = ${f2b_backend}
maxretry = 5
findtime = 10m
bantime  = 1h
banaction = ufw
JAILEOF

    if systemctl restart fail2ban; then
        log "Fail2Ban настроен и перезапущен."
    else
        log_warn "Ошибка перезапуска fail2ban"
    fi
    return 0
}

# ==============================================================================
# Проверка статуса сервиса
# ==============================================================================

check_service_status() {
    log "Проверка статуса сервиса..."
    local ok=1

    if systemctl is-failed --quiet awg-quick@awg0; then
        log_error "Сервис FAILED!"
        ok=0
    fi

    if ! ip addr show awg0 &>/dev/null; then
        log_error "Интерфейс awg0 не найден!"
        ok=0
    fi

    if ! awg show 2>/dev/null | grep -q "interface: awg0"; then
        log_error "awg show не видит интерфейс!"
        ok=0
    fi

    # Проверка порта
    local port_check=${AWG_PORT:-0}
    if [[ "$port_check" -eq 0 ]] && [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        port_check=$(safe_read_config_key "AWG_PORT" "$CONFIG_FILE")
        port_check=${port_check:-0}
    fi
    if [[ "$port_check" -ne 0 ]]; then
        if ! ss -lunp | grep -q ":${port_check} "; then
            log_error "Порт $port_check/udp не прослушивается!"
            ok=0
        fi
    fi

    # Проверка AWG 2.0 параметров
    if awg show awg0 2>/dev/null | grep -q "jc:"; then
        log "AWG 2.0 параметры активны."
    else
        log_warn "AWG 2.0 параметры не обнаружены в awg show."
    fi

    if [[ "$ok" -eq 1 ]]; then
        log "Статус сервиса и интерфейса OK."
        return 0
    else
        return 1
    fi
}

# ==============================================================================
# Диагностика
# ==============================================================================

create_diagnostic_report() {
    log "Создание диагностики..."
    local rf
    rf="$AWG_DIR/diag_$(date +%F_%T).txt"
    {
        echo "=== AMNEZIAWG 2.0 DIAGNOSTIC REPORT ==="
        echo ""
        echo "!!! ВНИМАНИЕ: Отчёт содержит IP-адреса, порты и маршруты."
        echo "!!! Перед публикацией в issue проверьте и замените приватные данные."
        echo ""
        echo "Generated: $(date)"
        echo "Hostname: $(hostname)"
        echo "Installer: v${SCRIPT_VERSION}"
        echo ""
        echo "--- OS ---"
        lsb_release -ds 2>/dev/null || cat /etc/os-release
        uname -a
        echo ""
        echo "--- Hardware ---"
        echo "RAM: $(awk '/MemTotal/ {printf "%.0f MB", $2/1024}' /proc/meminfo)"
        echo "CPU: $(nproc) cores"
        echo "Swap: $(free -m | awk '/Swap:/ {print $2}') MB"
        echo ""
        echo "--- Configuration ($CONFIG_FILE) ---"
        if [[ -f "$CONFIG_FILE" ]]; then
            sed 's/AWG_ENDPOINT=.*/AWG_ENDPOINT=[HIDDEN]/' "$CONFIG_FILE"
        else
            echo "File not found"
        fi
        echo ""
        echo "--- Server Config ($SERVER_CONF_FILE) ---"
        # Маскируем приватный ключ
        if [[ -f "$SERVER_CONF_FILE" ]]; then
            sed 's/PrivateKey = .*/PrivateKey = [HIDDEN]/' "$SERVER_CONF_FILE"
        else
            echo "File not found"
        fi
        echo ""
        echo "--- Service Status ---"
        systemctl status awg-quick@awg0 --no-pager -l 2>/dev/null || echo "Service not found"
        echo ""
        echo "--- AWG Status ---"
        awg show 2>/dev/null || echo "awg show failed"
        echo ""
        echo "--- AWG Version ---"
        awg --version 2>/dev/null || echo "awg --version failed"
        echo ""
        echo "--- Network Interfaces ---"
        ip a 2>/dev/null
        echo ""
        echo "--- Listening Ports ---"
        ss -lunp 2>/dev/null
        echo ""
        echo "--- Firewall Status ---"
        if command -v ufw &>/dev/null; then ufw status verbose; else echo "UFW N/A"; fi
        echo ""
        echo "--- Routing Table ---"
        ip route 2>/dev/null
        echo ""
        echo "--- Kernel Params ---"
        sysctl net.ipv4.ip_forward net.ipv6.conf.all.disable_ipv6 2>/dev/null
        echo ""
        echo "--- AWG Journal (last 50) ---"
        journalctl -u awg-quick@awg0 -n 50 --no-pager --output=cat 2>/dev/null || echo "N/A"
        echo ""
        echo "--- Client List ---"
        grep "^#_Name = " "$SERVER_CONF_FILE" 2>/dev/null | sed 's/^#_Name = //' || echo "N/A"
        echo ""
        echo "--- DKMS Status ---"
        dkms status 2>/dev/null || echo "N/A"
        echo ""
        echo "--- Module Info ---"
        modinfo amneziawg 2>/dev/null || echo "N/A"
        echo ""
        echo "=== END ==="
    } > "$rf" || log_error "Ошибка записи отчета."
    chmod 600 "$rf" || log_warn "Ошибка chmod отчета."
    log "Отчет: $rf"
}

# ==============================================================================
# Деинсталляция
# ==============================================================================

step_uninstall() {
    log "### ДЕИНСТАЛЛЯЦИЯ AMNEZIAWG ###"
    echo ""
    echo "ВНИМАНИЕ! Полное удаление AmneziaWG и конфигураций."
    echo "Процесс необратим!"
    echo ""
    local confirm="" backup="Y"
    if [[ "$AUTO_YES" -eq 0 ]]; then
        read -rp "Уверены? (введите 'yes'): " confirm < /dev/tty
        if [[ "$confirm" != "yes" ]]; then log "Деинсталляция отменена."; exit 1; fi
        read -rp "Создать бэкап перед удалением? [Y/n]: " backup < /dev/tty
    else
        log "Автоматическое подтверждение деинсталляции (--yes)."
    fi
    if [[ -z "$backup" || "$backup" =~ ^[Yy]$ ]]; then
        local bf
        bf="$HOME/awg_uninstall_backup_$(date +%F_%H-%M-%S).tar.gz"
        log "Создание бэкапа: $bf"
        if tar -czf "$bf" -C / etc/amnezia "$AWG_DIR" --ignore-failed-read 2>/dev/null \
            && chmod 600 "$bf"; then
            log "Бэкап создан: $bf"
        else
            log_warn "Бэкап не удался — проверьте $bf вручную перед продолжением"
        fi
    fi
    # Загружаем флаг --no-tweaks из сохранённой конфигурации
    local saved_no_tweaks=0
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        saved_no_tweaks=$(safe_read_config_key "NO_TWEAKS" "$CONFIG_FILE" 2>/dev/null) || saved_no_tweaks=0
        saved_no_tweaks=${saved_no_tweaks:-0}
    fi
    log "Остановка сервиса..."
    systemctl stop awg-quick@awg0 2>/dev/null
    systemctl disable awg-quick@awg0 2>/dev/null
    systemctl stop awg-web.service 2>/dev/null
    systemctl disable awg-web.service 2>/dev/null
    systemctl stop AdGuardHome.service 2>/dev/null
    systemctl disable AdGuardHome.service 2>/dev/null
    systemctl stop ndppd 2>/dev/null || true
    modprobe -r amneziawg 2>/dev/null || true
    # v5.12.0+: автовосстановление модуля при обновлении ядра.
    # Удаляем apt hook и systemd unit ДО apt purge, чтобы хук не сработал
    # во время purge amneziawg-dkms (helper попытался бы пересобрать DKMS,
    # но пакета уже нет). Файлы могут отсутствовать у установок до v5.12.0 —
    # все операции idempotent.
    log "Удаление компонентов автовосстановления модуля (v5.12.0+)..."
    if systemctl is-enabled amneziawg-ensure-module.service &>/dev/null; then
        systemctl disable amneziawg-ensure-module.service 2>/dev/null || true
    fi
    rm -f /etc/systemd/system/amneziawg-ensure-module.service \
        /etc/apt/apt.conf.d/99-amneziawg-post-kernel \
        /etc/logrotate.d/amneziawg-ensure-module \
        /usr/local/sbin/amneziawg-ensure-module \
        2>/dev/null
    # Также подчищаем staging dotfiles, оставшиеся от прерванного install (atomic deploy).
    rm -f /etc/systemd/system/.amneziawg-ensure-module.service.new \
        /etc/apt/apt.conf.d/.99-amneziawg-post-kernel.new \
        /etc/logrotate.d/.amneziawg-ensure-module.new \
        /usr/local/sbin/.amneziawg-ensure-module.new \
        2>/dev/null || true
    rm -f /var/log/amneziawg-ensure-module.log* 2>/dev/null || true
    rm -rf /var/lib/amneziawg 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    if [[ "$saved_no_tweaks" -eq 0 ]]; then
        log "Очистка правил UFW для AmneziaWG..."
        if command -v ufw &>/dev/null; then
            local port_to_del
            if [[ -f "$CONFIG_FILE" ]]; then
                # shellcheck source=/dev/null
                port_to_del=$(safe_read_config_key "AWG_PORT" "$CONFIG_FILE")
            fi
            port_to_del=${port_to_del:-39743}
            # Удаление наших правил выполняется ВСЕГДА (idempotent)
            ufw delete allow "${port_to_del}/udp" 2>/dev/null
            local web_port_to_del p2p_base_to_del
            web_port_to_del=$(safe_read_config_key "AWG_WEB_PORT" "$CONFIG_FILE" 2>/dev/null || true)
            web_port_to_del=${web_port_to_del:-8443}
            ufw delete allow "${web_port_to_del}/tcp" 2>/dev/null
            ufw delete allow in on awg0 to any port 53 proto udp 2>/dev/null
            ufw delete allow in on awg0 to any port 53 proto tcp 2>/dev/null
            local adguard_port_to_del
            adguard_port_to_del=$(safe_read_config_key "AWG_ADGUARD_PORT" "$CONFIG_FILE" 2>/dev/null || true)
            adguard_port_to_del=${adguard_port_to_del:-3000}
            ufw delete allow in on awg0 to any port "${adguard_port_to_del}" proto tcp 2>/dev/null
            p2p_base_to_del=$(safe_read_config_key "AWG_P2P_BASE_PORT" "$CONFIG_FILE" 2>/dev/null || true)
            p2p_base_to_del=${p2p_base_to_del:-20000}
            ufw delete allow "$((p2p_base_to_del + 1)):$((p2p_base_to_del + 1024))/tcp" 2>/dev/null
            ufw delete allow "$((p2p_base_to_del + 1)):$((p2p_base_to_del + 1024))/udp" 2>/dev/null
            # Для удаления route-правила нужно точное совпадение с тем как оно
            # было создано: "ufw route allow in on awg0 out on <nic>". Без "out on"
            # UFW не найдёт правило и оно останется в ufw status. Discussion #41.
            local _nic
            _nic=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
            if [[ -n "$_nic" ]]; then
                ufw route delete allow in on awg0 out on "$_nic" 2>/dev/null
            fi
            # Fallback: попытка удалить без out on (для совместимости со старыми правилами)
            ufw route delete allow in on awg0 2>/dev/null

            # ufw disable выполняется ТОЛЬКО если UFW был включён нашим установщиком.
            # Защита от destructive uninstall на VPS где UFW использовался для
            # SSH/web hardening ДО установки нашего скрипта (audit).
            # Backwards compat: старые установки без маркера сохраняют UFW активным.
            if [[ -f "$AWG_DIR/.ufw_enabled_by_installer" ]]; then
                log "Отключение UFW (был включён нашим установщиком)..."
                ufw --force disable 2>/dev/null
                rm -f "$AWG_DIR/.ufw_enabled_by_installer"
            else
                log "UFW оставлен активным (использовался до установки или старая версия инсталлятора)."
            fi
        fi
        log "Снятие блокировок Fail2Ban..."
        if command -v fail2ban-client &>/dev/null; then
            fail2ban-client unban --all 2>/dev/null || true
            systemctl stop fail2ban 2>/dev/null
        fi
    else
        log "Пропуск UFW/Fail2Ban (установка с --no-tweaks)."
    fi
    log "Удаление пакетов..."
    if [[ "$saved_no_tweaks" -eq 0 ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y amneziawg-dkms amneziawg-tools fail2ban qrencode ndppd 2>/dev/null || log_warn "Ошибка purge."
    else
        DEBIAN_FRONTEND=noninteractive apt-get purge -y amneziawg-dkms amneziawg-tools qrencode ndppd 2>/dev/null || log_warn "Ошибка purge."
    fi
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || log_warn "Ошибка autoremove."
    log "Удаление PPA и файлов..."
    rm -f /etc/apt/sources.list.d/amnezia-ppa.sources \
        /etc/apt/sources.list.d/amnezia-ppa.list \
        /etc/apt/sources.list.d/amnezia-ubuntu-ppa-*.list \
        /etc/apt/sources.list.d/amnezia-ubuntu-ppa-*.sources \
        /etc/apt/keyrings/amnezia-ppa.gpg 2>/dev/null
    rm -rf /etc/amnezia \
        /etc/ndppd.conf \
        /etc/systemd/system/awg-web.service \
        /etc/systemd/system/AdGuardHome.service \
        /etc/modules-load.d/amneziawg.conf \
        /etc/sysctl.d/99-amneziawg-security.conf \
        /etc/sysctl.d/99-amneziawg-forwarding.conf \
        /etc/sysctl.d/99-awg-udp.conf \
        /etc/sysctl.d/99-awg-conntrack.conf \
        /etc/logrotate.d/amneziawg* || log_warn "Ошибка удаления файлов."
    if [[ "$saved_no_tweaks" -eq 0 ]]; then
        # Удаляем только наш собственный jail-файл.
        # Раньше здесь была эвристика "если jail.local содержит banaction = ufw,
        # удалить весь файл" — слишком широкий фильтр, мог снести чужой
        # jail.local с custom jails. Эвристика убрана (audit).
        # Если у юзера остался jail.local от очень старых версий нашего
        # инсталлятора — пусть сам решает что с ним делать.
        rm -f /etc/fail2ban/jail.d/amneziawg.conf 2>/dev/null
    fi
    log "Удаление DKMS..."
    rm -rf /var/lib/dkms/amneziawg* || log_warn "Ошибка удаления DKMS."
    log "Восстановление sysctl..."
    if grep -q "disable_ipv6" /etc/sysctl.conf 2>/dev/null; then
        sed -i '/disable_ipv6/d' /etc/sysctl.conf || log_warn "Ошибка sed sysctl.conf"
    fi
    sysctl -p --system 2>/dev/null
    rm -f /etc/apt/sources.list.d/*.bak-* "$AWG_DIR"/ubuntu.sources.bak-* 2>/dev/null || true
    log "Удаление cron и скриптов..."
    rm -f /etc/cron.d/awg-expiry 2>/dev/null
    log "=== ДЕИНСТАЛЛЯЦИЯ ЗАВЕРШЕНА ==="
    # Копируем лог и удаляем рабочую директорию
    cp "$LOG_FILE" "$HOME/awg_uninstall.log" 2>/dev/null || true
    rm -rf "$AWG_DIR" 2>/dev/null || true
    exit 0
}

# ==============================================================================
# ШАГ 0: Инициализация
# ==============================================================================

initialize_setup() {
    if [ "$(id -u)" -ne 0 ]; then die "Запустите скрипт от root (sudo bash $0)."; fi

    mkdir -p "$AWG_DIR" || die "Ошибка создания $AWG_DIR"
    chown root:root "$AWG_DIR"

    # Process-wide lock: предотвращает запуск двух экземпляров install_amneziawg.sh
    # одновременно. Без него два concurrent запуска могли бы прочитать одинаковый
    # setup_state, конкурентно дёргать apt-get/dkms/ufw и сломать package state
    # (audit).
    # FD выбран фиксированным (9) и не конфликтует с update_state (использует 200).
    # Lock держится открытым весь lifetime процесса — release автоматически на exit.
    INSTALL_LOCK_FILE="$AWG_DIR/.install.lock"
    exec 9>"$INSTALL_LOCK_FILE" || die "Не могу открыть $INSTALL_LOCK_FILE"
    if ! flock -n 9; then
        die "Другой экземпляр install_amneziawg.sh уже запущен. Подождите завершения, либо если процесс висит — удалите $INSTALL_LOCK_FILE и попробуйте снова."
    fi

    touch "$LOG_FILE" || die "Не удалось создать лог-файл $LOG_FILE"
    chmod 640 "$LOG_FILE"
    log "--- НАЧАЛО УСТАНОВКИ AmneziaWG 2.0 (v${SCRIPT_VERSION}) ---"
    log "### ШАГ 0: Инициализация и проверка параметров ###"
    cd "$AWG_DIR" || die "Ошибка перехода в $AWG_DIR"
    log "Рабочая директория: $AWG_DIR"
    log "Лог файл: $LOG_FILE"

    check_os_version
    check_free_space

    local default_port
    default_port=$(generate_random_awg_port)
    local default_subnet="10.9.9.1/24"
    local config_exists=0

    # Инициализация переменных
    AWG_PORT=$default_port
    AWG_TUNNEL_SUBNET=$default_subnet
    DISABLE_IPV6="default"
    ALLOWED_IPS_MODE="default"
    ALLOWED_IPS=""
    AWG_ENDPOINT="${AWG_ENDPOINT:-}"
    AWG_MTU="${AWG_MTU:-1280}"
    AWG_SERVER_NAME="${AWG_SERVER_NAME:-MyVPN}"
    AWG_IPV6_ENABLED=${AWG_IPV6_ENABLED:-0}
    AWG_IPV6_MODE="${AWG_IPV6_MODE:-legacy}"
    AWG_IPV6_MODE_REQUESTED="${AWG_IPV6_MODE_REQUESTED:-${AWG_IPV6_MODE}}"
    AWG_IPV6_MODE_EFFECTIVE="${AWG_IPV6_MODE_EFFECTIVE:-${AWG_IPV6_MODE}}"
    AWG_IPV6_MODE_REASON="${AWG_IPV6_MODE_REASON:-}"
    AWG_IPV6_SUBNET="${AWG_IPV6_SUBNET:-}"
    AWG_IPV6_NDP_PROXY=${AWG_IPV6_NDP_PROXY:-0}
    AWG_IPV6_LEAK_PROTECTION=${AWG_IPV6_LEAK_PROTECTION:-warn}
    AWG_P2P_ENABLED=${AWG_P2P_ENABLED:-1}
    AWG_P2P_BASE_PORT=${AWG_P2P_BASE_PORT:-20000}
    AWG_P2P_PORTS_PER_CLIENT=${AWG_P2P_PORTS_PER_CLIENT:-3}
    AWG_FULLCONE_NAT=${AWG_FULLCONE_NAT:-0}
    AWG_DISABLE_UFW=${AWG_DISABLE_UFW:-0}
    AWG_WEB_ENABLED=${AWG_WEB_ENABLED:-1}
    AWG_WEB_PORT=${AWG_WEB_PORT:-8443}
    AWG_WEB_BIND="${AWG_WEB_BIND:-10.9.9.1}"
    AWG_WEB_CERT_MODE="${AWG_WEB_CERT_MODE:-selfsigned}"
    AWG_WEB_DOMAIN="${AWG_WEB_DOMAIN:-}"
    AWG_WEB_CERT_FILE="${AWG_WEB_CERT_FILE:-}"
    AWG_WEB_KEY_FILE="${AWG_WEB_KEY_FILE:-}"
    AWG_WEB_CERT_PROVIDER="${AWG_WEB_CERT_PROVIDER:-sslip.io}"
    AWG_WEB_LE_EMAIL="${AWG_WEB_LE_EMAIL:-}"
    AWG_WEB_PUBLIC_URL="${AWG_WEB_PUBLIC_URL:-}"
    AWG_WEB_CERT_FALLBACK="${AWG_WEB_CERT_FALLBACK:-abort}"
    AWG_WEB_CERT_ATTEMPTED_MODE="${AWG_WEB_CERT_ATTEMPTED_MODE:-}"
    AWG_WEB_CERT_FAILURE_REASON="${AWG_WEB_CERT_FAILURE_REASON:-}"
    AWG_WEB_CERT_FALLBACK_USED="${AWG_WEB_CERT_FALLBACK_USED:-}"
    AWG_DNS_MODE="adguard"
    AWG_CUSTOM_DNS="1.1.1.1"
    AWG_ADGUARD_ENABLED=${AWG_ADGUARD_ENABLED:-1}
    AWG_ADGUARD_PORT=${AWG_ADGUARD_PORT:-3000}
    AWG_ADGUARD_DIR="${AWG_ADGUARD_DIR:-/opt/AdGuardHome}"
    AWG_WIRESOCK_HINTS="${AWG_WIRESOCK_HINTS:-quic}"
    AWG_WIRESOCK_ID="${AWG_WIRESOCK_ID:-}"
    AWG_WIRESOCK_IP="${AWG_WIRESOCK_IP:-}"
    AWG_WIRESOCK_IB="${AWG_WIRESOCK_IB:-}"
    AWG_PRESET="${AWG_PRESET:-default}"

    # Загрузка конфига
    if [[ -f "$CONFIG_FILE" ]]; then
        log "Найден файл конфигурации $CONFIG_FILE. Загрузка настроек..."
        config_exists=1
        # shellcheck source=/dev/null
        safe_load_config "$CONFIG_FILE" || log_warn "Не удалось полностью загрузить настройки из $CONFIG_FILE."
        AWG_PORT=${AWG_PORT:-$default_port}
        AWG_TUNNEL_SUBNET=${AWG_TUNNEL_SUBNET:-$default_subnet}
        DISABLE_IPV6=${DISABLE_IPV6:-"default"}
        ALLOWED_IPS_MODE=${ALLOWED_IPS_MODE:-"default"}
        ALLOWED_IPS=${ALLOWED_IPS:-""}
        AWG_ENDPOINT=${AWG_ENDPOINT:-""}
        AWG_MTU=${AWG_MTU:-1280}
        AWG_SERVER_NAME=${AWG_SERVER_NAME:-MyVPN}
        AWG_IPV6_ENABLED=${AWG_IPV6_ENABLED:-0}
        AWG_IPV6_MODE=$(normalize_ipv6_mode_installer "${AWG_IPV6_MODE:-legacy}" 2>/dev/null || echo "legacy")
        AWG_IPV6_MODE_REQUESTED=$(normalize_ipv6_mode_installer "${AWG_IPV6_MODE_REQUESTED:-${AWG_IPV6_MODE}}" 2>/dev/null || echo "${AWG_IPV6_MODE:-legacy}")
        AWG_IPV6_MODE_EFFECTIVE=$(normalize_ipv6_mode_installer "${AWG_IPV6_MODE_EFFECTIVE:-${AWG_IPV6_MODE}}" 2>/dev/null || echo "${AWG_IPV6_MODE:-legacy}")
        AWG_IPV6_MODE_REASON=${AWG_IPV6_MODE_REASON:-}
        AWG_IPV6_SUBNET=${AWG_IPV6_SUBNET:-}
        AWG_IPV6_NDP_PROXY=${AWG_IPV6_NDP_PROXY:-0}
    AWG_IPV6_LEAK_PROTECTION=${AWG_IPV6_LEAK_PROTECTION:-warn}
        AWG_P2P_ENABLED=${AWG_P2P_ENABLED:-1}
        AWG_P2P_BASE_PORT=${AWG_P2P_BASE_PORT:-20000}
        AWG_P2P_PORTS_PER_CLIENT=${AWG_P2P_PORTS_PER_CLIENT:-3}
        AWG_FULLCONE_NAT=${AWG_FULLCONE_NAT:-0}
        AWG_DISABLE_UFW=${AWG_DISABLE_UFW:-0}
        AWG_WEB_ENABLED=${AWG_WEB_ENABLED:-1}
        AWG_WEB_PORT=${AWG_WEB_PORT:-8443}
        AWG_WEB_BIND=${AWG_WEB_BIND:-${AWG_TUNNEL_SUBNET%/*}}
        AWG_WEB_CERT_MODE=${AWG_WEB_CERT_MODE:-selfsigned}
        AWG_WEB_DOMAIN=${AWG_WEB_DOMAIN:-}
        AWG_WEB_CERT_FILE=${AWG_WEB_CERT_FILE:-}
        AWG_WEB_KEY_FILE=${AWG_WEB_KEY_FILE:-}
        AWG_WEB_CERT_PROVIDER=${AWG_WEB_CERT_PROVIDER:-sslip.io}
        AWG_WEB_LE_EMAIL=${AWG_WEB_LE_EMAIL:-}
        AWG_WEB_PUBLIC_URL=${AWG_WEB_PUBLIC_URL:-}
        AWG_WEB_CERT_FALLBACK=${AWG_WEB_CERT_FALLBACK:-abort}
        AWG_WEB_CERT_ATTEMPTED_MODE=${AWG_WEB_CERT_ATTEMPTED_MODE:-}
        AWG_WEB_CERT_FAILURE_REASON=${AWG_WEB_CERT_FAILURE_REASON:-}
        AWG_WEB_CERT_FALLBACK_USED=${AWG_WEB_CERT_FALLBACK_USED:-}
        AWG_DNS_MODE=${AWG_DNS_MODE:-adguard}
        AWG_CUSTOM_DNS=${AWG_CUSTOM_DNS:-1.1.1.1}
        AWG_ADGUARD_ENABLED=${AWG_ADGUARD_ENABLED:-1}
        AWG_ADGUARD_PORT=${AWG_ADGUARD_PORT:-3000}
        AWG_ADGUARD_DIR=${AWG_ADGUARD_DIR:-/opt/AdGuardHome}
        AWG_WIRESOCK_HINTS=${AWG_WIRESOCK_HINTS:-quic}
        AWG_WIRESOCK_ID=${AWG_WIRESOCK_ID:-}
        AWG_WIRESOCK_IP=${AWG_WIRESOCK_IP:-}
        AWG_WIRESOCK_IB=${AWG_WIRESOCK_IB:-}
        AWG_PRESET=${AWG_PRESET:-default}
        log "Настройки из файла загружены."
    else
        log "Файл конфигурации $CONFIG_FILE не найден."
    fi

    # Переопределение из CLI
    AWG_PORT=${CLI_PORT:-$AWG_PORT}
    AWG_TUNNEL_SUBNET=${CLI_SUBNET:-$AWG_TUNNEL_SUBNET}
    if [[ "$CLI_DISABLE_IPV6" != "default" ]]; then DISABLE_IPV6=$CLI_DISABLE_IPV6; fi
    [[ "$CLI_ENABLE_NATIVE_IPV6" -eq 1 || "$CLI_UPGRADE_IPV6" -eq 1 ]] && DISABLE_IPV6=0
    [[ -n "$CLI_P2P_BASE_PORT" ]] && AWG_P2P_BASE_PORT="$CLI_P2P_BASE_PORT"
    [[ -n "$CLI_P2P_PORTS_PER_CLIENT" ]] && AWG_P2P_PORTS_PER_CLIENT="$CLI_P2P_PORTS_PER_CLIENT"
    [[ "$CLI_FULLCONE_NAT" -eq 1 ]] && AWG_FULLCONE_NAT=1
    [[ "$CLI_DISABLE_UFW" -eq 1 ]] && AWG_DISABLE_UFW=1
    [[ -n "$CLI_WEB_PORT" ]] && AWG_WEB_PORT="$CLI_WEB_PORT"
    [[ -n "$CLI_WEB_BIND" ]] && AWG_WEB_BIND="$CLI_WEB_BIND"
    [[ "$CLI_DISABLE_WEB" -eq 1 ]] && AWG_WEB_ENABLED=0
    [[ -n "$CLI_WEB_CERT_MODE" ]] && AWG_WEB_CERT_MODE="$CLI_WEB_CERT_MODE"
    [[ -n "$CLI_WEB_DOMAIN" ]] && AWG_WEB_DOMAIN="$CLI_WEB_DOMAIN"
    [[ -n "$CLI_WEB_CERT_FILE" ]] && AWG_WEB_CERT_FILE="$CLI_WEB_CERT_FILE"
    [[ -n "$CLI_WEB_KEY_FILE" ]] && AWG_WEB_KEY_FILE="$CLI_WEB_KEY_FILE"
    [[ -n "$CLI_WEB_CERT_PROVIDER" ]] && AWG_WEB_CERT_PROVIDER="$CLI_WEB_CERT_PROVIDER"
    [[ -n "$CLI_WEB_LE_EMAIL" ]] && AWG_WEB_LE_EMAIL="$CLI_WEB_LE_EMAIL"
    [[ -n "$CLI_WEB_CERT_FALLBACK" ]] && AWG_WEB_CERT_FALLBACK="$CLI_WEB_CERT_FALLBACK"
    [[ -n "$CLI_ADGUARD_PORT" ]] && AWG_ADGUARD_PORT="$CLI_ADGUARD_PORT"
    [[ -n "$CLI_WIRESOCK_HINTS" ]] && AWG_WIRESOCK_HINTS="$CLI_WIRESOCK_HINTS"
    [[ -n "$CLI_WIRESOCK_ID" ]] && AWG_WIRESOCK_ID="$CLI_WIRESOCK_ID"
    [[ -n "$CLI_WIRESOCK_IP" ]] && AWG_WIRESOCK_IP="$CLI_WIRESOCK_IP"
    [[ -n "$CLI_WIRESOCK_IB" ]] && AWG_WIRESOCK_IB="$CLI_WIRESOCK_IB"
    [[ -n "$CLI_SERVER_NAME" ]] && AWG_SERVER_NAME="$CLI_SERVER_NAME"
    [[ -n "$CLI_PRESET" ]] && AWG_PRESET="$CLI_PRESET"
    if [[ -n "$CLI_DNS_MODE" ]]; then AWG_DNS_MODE="$CLI_DNS_MODE"; fi
    if [[ "$CLI_ENABLE_ADGUARD" -eq 1 ]]; then
        AWG_ADGUARD_ENABLED=1
        AWG_DNS_MODE="adguard"
    fi
    if [[ "$CLI_DISABLE_ADGUARD" -eq 1 ]]; then
        AWG_ADGUARD_ENABLED=0
        if [[ -z "$CLI_DNS_MODE" || "$AWG_DNS_MODE" == "adguard" ]]; then
            AWG_DNS_MODE="system"
        fi
    fi
    if [[ "$CLI_ROUTING_MODE" != "default" ]]; then
        ALLOWED_IPS_MODE=$CLI_ROUTING_MODE
        if [[ "$CLI_ROUTING_MODE" -eq 3 ]]; then ALLOWED_IPS=$CLI_CUSTOM_ROUTES; fi
    fi
    if [[ -n "$CLI_ENDPOINT" ]]; then
        if ! validate_endpoint "$CLI_ENDPOINT"; then
            die "Некорректный --endpoint: '$CLI_ENDPOINT'. Допустимые форматы: FQDN (vpn.example.com), IPv4 (1.2.3.4), [IPv6] ([2001:db8::1]). Запрещены пробелы, табы, кавычки, обратный слеш и переводы строк."
        fi
        AWG_ENDPOINT=$CLI_ENDPOINT
    fi
    if [[ "$CLI_NO_TWEAKS" -eq 1 ]]; then NO_TWEAKS=1; fi

    # Валидация после CLI override
    validate_port_user "$AWG_PORT"
    validate_subnet "$AWG_TUNNEL_SUBNET"
    validate_port_user "$AWG_P2P_BASE_PORT"
    if [[ "$AWG_P2P_BASE_PORT" -gt 64511 ]]; then
        die "Некорректный AWG_P2P_BASE_PORT: '$AWG_P2P_BASE_PORT' (нужно <= 64511, чтобы диапазон base+1..base+1024 помещался в TCP/UDP порты)."
    fi
    if ! [[ "$AWG_P2P_PORTS_PER_CLIENT" =~ ^[0-9]+$ ]] || [[ "$AWG_P2P_PORTS_PER_CLIENT" -lt 0 ]] || [[ "$AWG_P2P_PORTS_PER_CLIENT" -gt 12 ]]; then
        die "Некорректный AWG_P2P_PORTS_PER_CLIENT: '$AWG_P2P_PORTS_PER_CLIENT' (0-12)."
    fi
    validate_web_port "$AWG_WEB_PORT"
    validate_bind_addr "$AWG_WEB_BIND" || die "Некорректный AWG_WEB_BIND: '$AWG_WEB_BIND'. Нужен корректный IPv4/IPv6 адрес без пробелов и управляющих символов."
    case "${AWG_WEB_CERT_MODE:-selfsigned}" in selfsigned|custom|letsencrypt|ip-domain) ;; *) die "Некорректный --web-cert-mode=${AWG_WEB_CERT_MODE}" ;; esac
    case "${AWG_WEB_CERT_PROVIDER:-sslip.io}" in sslip.io|nip.io) ;; *) die "Некорректный --web-cert-provider=${AWG_WEB_CERT_PROVIDER}" ;; esac
    case "${AWG_WEB_CERT_FALLBACK:-abort}" in selfsigned|abort) ;; *) die "Некорректный --web-cert-fallback=${AWG_WEB_CERT_FALLBACK}" ;; esac
    if [[ "${AWG_WEB_CERT_MODE:-selfsigned}" == "custom" ]]; then
        [[ -f "${AWG_WEB_CERT_FILE:-}" && -f "${AWG_WEB_KEY_FILE:-}" ]] || die "Для --web-cert-mode=custom нужны существующие --web-cert-file и --web-key-file."
    fi
    if [[ "${AWG_WEB_CERT_MODE:-selfsigned}" == "letsencrypt" && -z "${AWG_WEB_DOMAIN:-}" ]]; then
        die "--web-cert-mode=letsencrypt требует --web-domain=DOMAIN."
    fi
    validate_port "$AWG_ADGUARD_PORT"
    validate_wiresock_settings
    validate_server_name "$AWG_SERVER_NAME" || die "Некорректное имя сервера: пустое, слишком длинное или содержит перевод строки."
    case "$AWG_DNS_MODE" in
        adguard|system|custom) ;;
        *) die "Некорректный --dns-mode: '$AWG_DNS_MODE' (ожидается adguard, system или custom)." ;;
    esac
    if [[ "$AWG_DNS_MODE" == "adguard" ]]; then
        AWG_ADGUARD_ENABLED=1
    fi
    # AWG_ENDPOINT мог прийти из CONFIG_FILE через safe_load_config (без CLI override).
    # Если значение есть и не валидно — log_warn + сброс в "" чтобы инсталлятор
    # вернулся к auto-detect через get_server_public_ip (audit).
    if [[ -n "$AWG_ENDPOINT" ]] && ! validate_endpoint "$AWG_ENDPOINT"; then
        log_warn "AWG_ENDPOINT='$AWG_ENDPOINT' из $CONFIG_FILE не валиден, использую auto-detect."
        AWG_ENDPOINT=""
    fi

    # Запрос у пользователя только на первом запуске
    if [[ "$config_exists" -eq 0 ]]; then
        log "Запрос настроек у пользователя (первый запуск)."
        prompt_server_name
        prompt_endpoint
        prompt_awg_preset
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Введите UDP порт AmneziaWG (1024-65535) [${AWG_PORT}]: " input_port < /dev/tty
            if [[ -n "$input_port" ]]; then AWG_PORT=$input_port; fi
        fi
        validate_port_user "$AWG_PORT"
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Введите подсеть туннеля [${AWG_TUNNEL_SUBNET}]: " input_subnet < /dev/tty
            if [[ -n "$input_subnet" ]]; then AWG_TUNNEL_SUBNET=$input_subnet; fi
        fi
        validate_subnet "$AWG_TUNNEL_SUBNET"
        if [[ "$DISABLE_IPV6" == "default" ]]; then configure_ipv6; fi
        prompt_ipv6_mode
        if [[ "$ALLOWED_IPS_MODE" == "default" ]]; then configure_routing_mode; fi
        prompt_web_panel
        prompt_adguard
        prompt_p2p
        prompt_wiresock_hints
    else
        log "Используются настройки из $CONFIG_FILE."
        warn_public_web_bind
        if [[ "$ALLOWED_IPS_MODE" == "3" ]] && [[ -n "$ALLOWED_IPS" ]]; then
            if ! validate_cidr_list "$ALLOWED_IPS"; then
                die "Некорректный ALLOWED_IPS в конфиге: '$ALLOWED_IPS'. Удалите $CONFIG_FILE и запустите установку заново."
            fi
        fi
    fi

    apply_web_port_default "$config_exists"
    case "${AWG_WEB_CERT_MODE:-selfsigned}" in selfsigned|custom|letsencrypt|ip-domain) ;; *) die "Некорректный --web-cert-mode=${AWG_WEB_CERT_MODE}" ;; esac
    case "${AWG_WEB_CERT_PROVIDER:-sslip.io}" in sslip.io|nip.io) ;; *) die "Некорректный --web-cert-provider=${AWG_WEB_CERT_PROVIDER}" ;; esac
    case "${AWG_WEB_CERT_FALLBACK:-abort}" in selfsigned|abort) ;; *) die "Некорректный --web-cert-fallback=${AWG_WEB_CERT_FALLBACK}" ;; esac
    if [[ "${AWG_WEB_CERT_MODE:-selfsigned}" == "ip-domain" && -z "${AWG_WEB_DOMAIN:-}" ]]; then
        AWG_WEB_DOMAIN="$(generate_ip_domain "${AWG_ENDPOINT:-}" "${AWG_WEB_CERT_PROVIDER:-sslip.io}")" || die "--web-cert-mode=ip-domain требует IPv4 --endpoint."
    fi
    if [[ "${AWG_WEB_CERT_MODE:-selfsigned}" == "letsencrypt" && -z "${AWG_WEB_DOMAIN:-}" ]]; then
        die "--web-cert-mode=letsencrypt требует --web-domain=DOMAIN."
    fi
    if [[ "${AWG_WEB_CERT_MODE:-selfsigned}" == "custom" ]]; then
        [[ -f "${AWG_WEB_CERT_FILE:-}" && -f "${AWG_WEB_KEY_FILE:-}" ]] || die "Для --web-cert-mode=custom нужны существующие --web-cert-file и --web-key-file."
    fi
    update_web_public_url

    # Значения по умолчанию
    if [[ "$DISABLE_IPV6" == "default" ]]; then DISABLE_IPV6=1; fi
    if [[ "$ALLOWED_IPS_MODE" == "default" ]]; then ALLOWED_IPS_MODE=2; fi
    if [[ -z "$ALLOWED_IPS" ]]; then configure_routing_mode; fi
    configure_ipv6_client_mode

    validate_port_user "$AWG_PORT"
    validate_subnet "$AWG_TUNNEL_SUBNET"
    validate_port_user "$AWG_P2P_BASE_PORT"
    if [[ "$AWG_P2P_BASE_PORT" -gt 64511 ]]; then
        die "Некорректный AWG_P2P_BASE_PORT: '$AWG_P2P_BASE_PORT' (нужно <= 64511, чтобы диапазон base+1..base+1024 помещался в TCP/UDP порты)."
    fi
    if ! [[ "$AWG_P2P_PORTS_PER_CLIENT" =~ ^[0-9]+$ ]] || [[ "$AWG_P2P_PORTS_PER_CLIENT" -lt 0 ]] || [[ "$AWG_P2P_PORTS_PER_CLIENT" -gt 12 ]]; then
        die "Некорректный AWG_P2P_PORTS_PER_CLIENT: '$AWG_P2P_PORTS_PER_CLIENT' (0-12)."
    fi
    validate_web_port "$AWG_WEB_PORT"
    validate_bind_addr "$AWG_WEB_BIND" || die "Некорректный AWG_WEB_BIND: '$AWG_WEB_BIND'. Нужен корректный IPv4/IPv6 адрес без пробелов и управляющих символов."
    validate_port "$AWG_ADGUARD_PORT"
    validate_wiresock_settings
    validate_server_name "$AWG_SERVER_NAME" || die "Некорректное имя сервера: пустое, слишком длинное или содержит перевод строки."
    confirm_install_choices

    # Проверка порта (пропускаем если AWG-сервис уже слушает этот порт)
    if ! systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
        check_port_availability "$AWG_PORT" || die "Порт $AWG_PORT/udp занят."
    else
        log "Сервис AWG активен — пропуск проверки порта."
    fi
    check_web_port_availability

    # Генерация AWG 2.0 параметров
    # Перегенерация если: первый запуск ИЛИ явный CLI override (--preset/--jc/--jmin/--jmax)
    if [[ -z "${AWG_Jc:-}" ]] || [[ -n "${CLI_PRESET:-}" ]] || [[ -n "${CLI_JC:-}" ]] \
        || [[ -n "${CLI_JMIN:-}" ]] || [[ -n "${CLI_JMAX:-}" ]]; then
        generate_awg_params
    else
        log "AWG 2.0 параметры уже заданы из конфига."
    fi

    # Сохранение конфигурации
    log "Сохранение настроек в $CONFIG_FILE..."
    local temp_conf
    temp_conf=$(mktemp) || die "Ошибка mktemp."
    _install_temp_files+=("$temp_conf")
    local quoted_server_name
    quoted_server_name=$(shell_quote "$AWG_SERVER_NAME")
    cat > "$temp_conf" << EOF
# Конфигурация установки AmneziaWG 2.0 (Авто-генерация)
# Используется скриптами установки и управления
export OS_ID='${OS_ID:-ubuntu}'
export OS_VERSION='${OS_VERSION:-}'
export OS_CODENAME='${OS_CODENAME:-}'
export AWG_PORT=${AWG_PORT}
export AWG_TUNNEL_SUBNET='${AWG_TUNNEL_SUBNET}'
export DISABLE_IPV6=${DISABLE_IPV6}
export ALLOWED_IPS_MODE=${ALLOWED_IPS_MODE}
export ALLOWED_IPS='${ALLOWED_IPS}'
export AWG_ENDPOINT='${AWG_ENDPOINT}'
export AWG_MTU=${AWG_MTU:-1280}
export AWG_SERVER_NAME=${quoted_server_name}
export AWG_IPV6_ENABLED=${AWG_IPV6_ENABLED}
export AWG_IPV6_MODE='${AWG_IPV6_MODE}'
export AWG_IPV6_MODE_REQUESTED='${AWG_IPV6_MODE_REQUESTED}'
export AWG_IPV6_MODE_EFFECTIVE='${AWG_IPV6_MODE_EFFECTIVE:-${AWG_IPV6_MODE}}'
export AWG_IPV6_MODE_REASON='${AWG_IPV6_MODE_REASON}'
export AWG_IPV6_SUBNET='${AWG_IPV6_SUBNET}'
export AWG_IPV6_NDP_PROXY=${AWG_IPV6_NDP_PROXY}
export AWG_IPV6_LEAK_PROTECTION='${AWG_IPV6_LEAK_PROTECTION:-warn}'
export AWG_P2P_ENABLED=${AWG_P2P_ENABLED}
export AWG_P2P_BASE_PORT=${AWG_P2P_BASE_PORT}
export AWG_P2P_PORTS_PER_CLIENT=${AWG_P2P_PORTS_PER_CLIENT}
export AWG_FULLCONE_NAT=${AWG_FULLCONE_NAT}
export AWG_DISABLE_UFW=${AWG_DISABLE_UFW}
export AWG_WEB_ENABLED=${AWG_WEB_ENABLED}
export AWG_WEB_PORT=${AWG_WEB_PORT}
export AWG_WEB_BIND='${AWG_WEB_BIND}'
export AWG_WEB_CERT_MODE='${AWG_WEB_CERT_MODE}'
export AWG_WEB_DOMAIN='${AWG_WEB_DOMAIN}'
export AWG_WEB_CERT_FILE='${AWG_WEB_CERT_FILE}'
export AWG_WEB_KEY_FILE='${AWG_WEB_KEY_FILE}'
export AWG_WEB_CERT_PROVIDER='${AWG_WEB_CERT_PROVIDER}'
export AWG_WEB_LE_EMAIL='${AWG_WEB_LE_EMAIL}'
export AWG_WEB_PUBLIC_URL='${AWG_WEB_PUBLIC_URL}'
export AWG_WEB_CERT_FALLBACK='${AWG_WEB_CERT_FALLBACK}'
export AWG_WEB_CERT_ATTEMPTED_MODE='${AWG_WEB_CERT_ATTEMPTED_MODE}'
export AWG_WEB_CERT_FAILURE_REASON='${AWG_WEB_CERT_FAILURE_REASON}'
export AWG_WEB_CERT_FALLBACK_USED='${AWG_WEB_CERT_FALLBACK_USED}'
export AWG_DNS_MODE='${AWG_DNS_MODE}'
export AWG_CUSTOM_DNS='${AWG_CUSTOM_DNS}'
export AWG_ADGUARD_ENABLED=${AWG_ADGUARD_ENABLED}
export AWG_ADGUARD_PORT=${AWG_ADGUARD_PORT}
export AWG_ADGUARD_DIR='${AWG_ADGUARD_DIR}'
export AWG_WIRESOCK_HINTS='${AWG_WIRESOCK_HINTS}'
export AWG_WIRESOCK_ID='${AWG_WIRESOCK_ID}'
export AWG_WIRESOCK_IP='${AWG_WIRESOCK_IP}'
export AWG_WIRESOCK_IB='${AWG_WIRESOCK_IB}'
# AWG 2.0 Parameters
export AWG_Jc=${AWG_Jc}
export AWG_Jmin=${AWG_Jmin}
export AWG_Jmax=${AWG_Jmax}
export AWG_S1=${AWG_S1}
export AWG_S2=${AWG_S2}
export AWG_S3=${AWG_S3}
export AWG_S4=${AWG_S4}
export AWG_H1='${AWG_H1}'
export AWG_H2='${AWG_H2}'
export AWG_H3='${AWG_H3}'
export AWG_H4='${AWG_H4}'
export AWG_I1='${AWG_I1}'
export AWG_PRESET='${AWG_PRESET:-default}'
export NO_TWEAKS=${NO_TWEAKS}
export AWG_APPLY_MODE='${AWG_APPLY_MODE:-syncconf}'
EOF
    if ! mv "$temp_conf" "$CONFIG_FILE"; then
        rm -f "$temp_conf"
        die "Ошибка сохранения $CONFIG_FILE"
    fi
    chmod 600 "$CONFIG_FILE" || log_warn "Ошибка chmod $CONFIG_FILE"
    log "Настройки сохранены."
    export AWG_PORT AWG_TUNNEL_SUBNET DISABLE_IPV6 ALLOWED_IPS_MODE ALLOWED_IPS AWG_ENDPOINT AWG_SERVER_NAME
    export AWG_IPV6_ENABLED AWG_IPV6_MODE_REQUESTED AWG_IPV6_MODE AWG_IPV6_MODE_EFFECTIVE AWG_IPV6_MODE_REASON AWG_IPV6_SUBNET AWG_IPV6_NDP_PROXY AWG_IPV6_LEAK_PROTECTION
    export AWG_P2P_ENABLED AWG_P2P_BASE_PORT AWG_P2P_PORTS_PER_CLIENT AWG_FULLCONE_NAT
    export AWG_WEB_ENABLED AWG_WEB_PORT AWG_WEB_BIND AWG_DISABLE_UFW
    export AWG_WEB_CERT_MODE AWG_WEB_DOMAIN AWG_WEB_CERT_FILE AWG_WEB_KEY_FILE AWG_WEB_CERT_PROVIDER AWG_WEB_LE_EMAIL AWG_WEB_PUBLIC_URL
    export AWG_WEB_CERT_FALLBACK AWG_WEB_CERT_ATTEMPTED_MODE AWG_WEB_CERT_FAILURE_REASON AWG_WEB_CERT_FALLBACK_USED
    export AWG_DNS_MODE AWG_CUSTOM_DNS AWG_ADGUARD_ENABLED AWG_ADGUARD_PORT AWG_ADGUARD_DIR
    export AWG_WIRESOCK_HINTS AWG_WIRESOCK_ID AWG_WIRESOCK_IP AWG_WIRESOCK_IB
    log "Порт: ${AWG_PORT}/udp"
    log "Подсеть: ${AWG_TUNNEL_SUBNET}"
    log "Откл. IPv6: $DISABLE_IPV6"
    log "IPv6 клиентов: ${AWG_IPV6_ENABLED} (requested=${AWG_IPV6_MODE_REQUESTED:-legacy}, effective=${AWG_IPV6_MODE_EFFECTIVE:-${AWG_IPV6_MODE:-legacy}} ${AWG_IPV6_SUBNET:-})"
    log "P2P: base=${AWG_P2P_BASE_PORT}, ports/client=${AWG_P2P_PORTS_PER_CLIENT}, fullcone=${AWG_FULLCONE_NAT}"
    log "Web: enabled=${AWG_WEB_ENABLED}, bind=${AWG_WEB_BIND}:${AWG_WEB_PORT}"
    log "DNS: mode=${AWG_DNS_MODE}, adguard=${AWG_ADGUARD_ENABLED}, port=${AWG_ADGUARD_PORT}"
    log "WireSock hints: ${AWG_WIRESOCK_HINTS:-off}"
    log "Имя сервера: ${AWG_SERVER_NAME}"
    log "Режим AllowedIPs: $ALLOWED_IPS_MODE"

    # Загрузка состояния
    if [[ -f "$STATE_FILE" ]]; then
        current_step=$(cat "$STATE_FILE")
        if ! [[ "$current_step" =~ ^[0-9]+$ ]]; then
            log_warn "$STATE_FILE поврежден."
            current_step=1
            update_state 1
        else
            log "Продолжение с шага $current_step."
        fi
    else
        current_step=1
        log "Начало с шага 1."
        update_state 1
    fi
    log "Шаг 0 завершен."
}

# ==============================================================================
# ШАГ 1: Обновление системы, очистка и оптимизация
# ==============================================================================

step1_update_and_optimize() {
    update_state 1
    log "### ШАГ 1: Обновление, очистка и оптимизация системы ###"

    # Очистка ненужных компонентов (ДО обновления для экономии трафика/времени)
    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        cleanup_system
    else
        log "Пропуск очистки системы (--no-tweaks)."
    fi

    log "Обновление списка пакетов..."
    apt_update_tolerant || die "Ошибка apt update."

    log "Разблокировка dpkg..."
    if ! apt-get check &>/dev/null; then
        log_warn "dpkg заблокирован или повреждён, исправление..."
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a || log_warn "dpkg --configure -a."
    fi

    log "Обновление системы..."
    DEBIAN_FRONTEND=noninteractive apt full-upgrade -y || die "Ошибка apt full-upgrade."
    log "Система обновлена."

    install_packages curl wget gpg sudo ethtool

    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        # Оптимизация системы
        optimize_system
        # Настройка sysctl
        setup_advanced_sysctl
        setup_voice_udp_optimization
    else
        log "Пропуск оптимизации и hardening (--no-tweaks)."
        setup_minimal_sysctl
        setup_voice_udp_optimization
    fi

    log "Шаг 1 успешно завершен."
    request_reboot 2
}

# ==============================================================================
# Поддержка предсобранных пакетов для ARM
# ==============================================================================

# _try_install_prebuilt_arm — скачать и установить предсобранный .deb для
# текущего ARM-ядра из релиза arm-packages на GitHub.
#
# Возвращает 0 при успехе, 1 если совпадений нет или установка не удалась
# (в этом случае вызывающий код переходит к DKMS).
_try_install_prebuilt_arm() {
    local kernel arch target_id asset_name asset_url tmpfile tmpsha expected_sha actual_sha
    kernel="$(uname -r)"
    arch="$(dpkg --print-architecture)"

    if [[ "$kernel" == *+rpt-rpi-2712* ]]; then
        target_id="rpi5-bookworm-arm64"
    elif [[ "$kernel" == *+rpt* && "$arch" == "arm64" ]]; then
        target_id="rpi-bookworm-arm64"
    elif [[ "$kernel" == *+rpt* && "$arch" == "armhf" ]]; then
        target_id="rpi-bookworm-armhf"
    elif [[ "$kernel" == *-generic* && "${OS_VERSION:-}" == "24.04" ]]; then
        target_id="ubuntu-2404-arm64"
    elif [[ "$kernel" == *-generic* && "${OS_VERSION:-}" == "25.10" ]]; then
        target_id="ubuntu-2510-arm64"
    elif [[ "$kernel" == *-arm64* && "${OS_ID:-}" == "debian" && "${OS_VERSION:-}" == "13" ]]; then
        target_id="debian-trixie-arm64"
    elif [[ "$kernel" == *-arm64* && "${OS_ID:-}" == "debian" ]]; then
        target_id="debian-bookworm-arm64"
    else
        log "Предсобранный пакет для ядра $kernel ($arch) не найден"
        return 1
    fi

    asset_name="amneziawg-kmod-${target_id}_${kernel}_${arch}.deb"
    asset_url="https://github.com/bivlked/amneziawg-installer/releases/download/arm-packages/${asset_name}"

    log "Попытка установки предсобранного пакета: $asset_name"
    tmpfile="$(mktemp /tmp/amneziawg-prebuilt-XXXXXX.deb)"
    tmpsha="$(mktemp /tmp/amneziawg-prebuilt-XXXXXX.deb.sha256)"

    # Сначала скачиваем контрольную сумму SHA256
    if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
            -o "$tmpsha" "${asset_url}.sha256" 2>/dev/null; then
        log "Предсобранный пакет недоступен для $kernel — используется DKMS"
        rm -f "$tmpfile" "$tmpsha"
        return 1
    fi

    if curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
            -o "$tmpfile" "$asset_url" 2>/dev/null; then
        # Проверяем целостность перед установкой модуля ядра
        expected_sha="$(cat "$tmpsha")"
        actual_sha="$(sha256sum "$tmpfile" | awk '{print $1}')"
        rm -f "$tmpsha"
        if [[ "$expected_sha" != "$actual_sha" ]]; then
            log_warn "Несовпадение SHA256 предсобранного пакета — скачивание отклонено"
            rm -f "$tmpfile"
            return 1
        fi

        log "Пакет скачан (SHA256 OK), установка..."
        if dpkg -i "$tmpfile" 2>/dev/null; then
            rm -f "$tmpfile"
            log "Предсобранный пакет установлен: $asset_name"
            return 0
        else
            log_warn "Ошибка установки (несовпадение vermagic или повреждённый пакет)"
            rm -f "$tmpfile"
            return 1
        fi
    else
        log "Предсобранный пакет недоступен для $kernel — используется DKMS"
        rm -f "$tmpfile" "$tmpsha"
        return 1
    fi
}

# ==============================================================================
# ШАГ 2: Установка AmneziaWG и зависимостей
# ==============================================================================

step2_install_amnezia() {
    update_state 2

    # Guard: убедиться что юзер действительно перезагрузился перед step 2.
    # Если boot_id совпадает с сохранённым в request_reboot 2 — reboot
    # не произошёл (например, юзер случайно запустил скрипт повторно).
    # В этом случае apt full-upgrade из step 1 подложил новое ядро на диск,
    # но работающее ядро всё ещё старое → DKMS соберёт модуль под старое,
    # после следующего reboot modprobe упадёт.
    local boot_id_file="$AWG_DIR/.boot_id_before_step2"
    if [[ -f "$boot_id_file" ]] && [[ -r /proc/sys/kernel/random/boot_id ]]; then
        local saved_boot_id current_boot_id
        saved_boot_id=$(< "$boot_id_file")
        current_boot_id=$(< /proc/sys/kernel/random/boot_id)
        if [[ -n "$saved_boot_id" ]] && [[ "$saved_boot_id" == "$current_boot_id" ]]; then
            die "Ожидалась перезагрузка перед шагом 2 (kernel upgrade активируется только после reboot). Выполните: sudo reboot — и запустите скрипт снова."
        fi
        log "Подтверждена перезагрузка (boot_id изменился) — продолжаем шаг 2"
        rm -f "$boot_id_file" 2>/dev/null || true
    fi

    log "### ШАГ 2: Установка AmneziaWG и зависимостей ###"
    _APT_UPDATED=0  # Reset: new sources will be added in this step

    apt_update_tolerant || die "Ошибка apt update."

    # PPA Amnezia (без software-properties-common)
    log "Добавление PPA Amnezia..."

    # Определение codename для PPA
    # На Debian маппим на ближайший Ubuntu codename, т.к. PPA — это Launchpad (Ubuntu)
    # Debian 12 (bookworm) → focal, Debian 13 (trixie) → noble
    local codename ppa_codename
    codename="${OS_CODENAME:-$(lsb_release -sc 2>/dev/null || echo "noble")}"
    case "${OS_ID:-ubuntu}" in
        debian)
            case "$codename" in
                bookworm) ppa_codename="focal" ;;
                trixie)   ppa_codename="noble" ;;
                *)        ppa_codename="noble" ;;
            esac
            log "Debian ($codename) → PPA codename: $ppa_codename"
            ;;
        *)
            ppa_codename="$codename"
            # Для Ubuntu non-LTS (questing/plucky/oracular/...) PPA Amnezia
            # пакетов не публикует — там 404 на dists/<codename>/Release.
            # Проверяем доступность через HEAD-запрос и переключаемся на
            # noble (LTS): сборка для noble корректно DKMS-собирается под
            # текущее ядро.
            # Связано: amnezia-vpn/amneziawg-linux-kernel-module#118
            case "$ppa_codename" in
                noble|jammy|focal)
                    # Known LTS — пропускаем pre-check (PPA точно опубликован)
                    ;;
                *)
                    log "Проверка доступности PPA Amnezia для Ubuntu '${ppa_codename}'..."
                    if ! curl -fsI --max-time 15 --retry 2 --retry-delay 5 \
                        "https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu/dists/${ppa_codename}/Release" \
                        >/dev/null 2>&1; then
                        log_warn "PPA Amnezia не публикует пакеты для Ubuntu '${ppa_codename}' (HTTP 404 или host недоступен)."
                        log_warn "Контекст: https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/issues/118"
                        if [[ "${AWG_ALLOW_PPA_CODENAME_FALLBACK:-0}" == "1" ]]; then
                            log_warn "Явно разрешён PPA fallback '${ppa_codename}' -> noble."
                            ppa_codename="noble"
                        else
                            die "PPA для '${ppa_codename}' недоступен. Чтобы явно fallback на noble, перезапустите с AWG_ALLOW_PPA_CODENAME_FALLBACK=1 или --allow-ppa-codename-fallback."
                        fi
                    else
                        log "PPA Amnezia доступен для '${ppa_codename}'."
                    fi
                    ;;
            esac
            ;;
    esac

    local keyring_dir="/etc/apt/keyrings"
    local keyring_file="${keyring_dir}/amnezia-ppa.gpg"
    local ppa_sources="/etc/apt/sources.list.d/amnezia-ppa.sources"
    local ppa_list="/etc/apt/sources.list.d/amnezia-ppa.list"
    # Проверка на legacy-файлы (от add-apt-repository предыдущих версий)
    local legacy_list="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-${codename}.list"
    local legacy_sources="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-${codename}.sources"
    # Повторный запуск на сервере, где предыдущий (≤ v5.12.1) создал .sources
    # с «битым» Suites=questing/plucky/etc.: если найденный suite не совпадает
    # с целевым ppa_codename — удаляем файл, чтобы пересоздать ниже с правильным.
    # Та же проверка для устаревшего .sources (формат от add-apt-repository).
    # Если файл существует, но строка `Suites:` не парсится — считаем повреждённым
    # и тоже пересоздаём, иначе сломанный файл проскочит как «PPA уже добавлен».
    local existing_suite=""
    if [[ -f "$ppa_sources" ]]; then
        existing_suite=$(awk '/^Suites:/{print $2; exit}' "$ppa_sources" 2>/dev/null)
    fi
    if [[ -f "$ppa_sources" && ( -z "$existing_suite" || "$existing_suite" != "$ppa_codename" ) ]]; then
        if [[ -z "$existing_suite" ]]; then
            log_warn "$ppa_sources существует, но строка Suites: не найдена — пересоздание."
        else
            log_warn "Существующий PPA suite='${existing_suite}', целевой='${ppa_codename}' — пересоздание $ppa_sources."
        fi
        rm -f "$ppa_sources" "$ppa_list"
    fi
    local legacy_suite=""
    if [[ -f "$legacy_sources" ]]; then
        legacy_suite=$(awk '/^Suites:/{print $2; exit}' "$legacy_sources" 2>/dev/null)
    fi
    if [[ -f "$legacy_sources" && ( -z "$legacy_suite" || "$legacy_suite" != "$ppa_codename" ) ]]; then
        log_warn "Устаревший PPA-файл $legacy_sources (suite='${legacy_suite:-<пусто>}') не соответствует целевому '${ppa_codename}' — удаление."
        rm -f "$legacy_sources" "$legacy_list"
    fi
    if [[ -f "$legacy_list" ]] || [[ -f "$legacy_sources" ]]; then
        log "PPA уже добавлен (legacy-формат)."
    elif [[ -f "$ppa_sources" ]] || [[ -f "$ppa_list" ]]; then
        log "PPA уже добавлен."
    else
        mkdir -p "$keyring_dir"
        log "Импорт GPG ключа Amnezia PPA..."
        # Atomic: pipe в temp, затем mv — полу-записанный keyring никогда не
        # окажется на целевом пути, даже если curl/gpg упали mid-way.
        local _kf_tmp
        _kf_tmp=$(mktemp -p "$keyring_dir" ".amnezia-ppa.gpg.tmp.XXXXXX") \
            || die "Не удалось создать временный файл для GPG ключа."
        # --batch --no-tty --yes: gpg не открывает /dev/tty (non-interactive
        # SSH, cloud-init, Ansible и т.п.) и не падает с "File exists" при
        # overwrite mktemp-файла. Без этих флагов gpg в батч-режиме откажется
        # писать в уже существующий пустой tmp-файл от mktemp.
        if ! curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x57290828" \
             | gpg --batch --no-tty --yes --dearmor -o "$_kf_tmp"; then
            rm -f "$_kf_tmp" 2>/dev/null
            die "Ошибка импорта GPG ключа Amnezia PPA."
        fi
        chmod 644 "$_kf_tmp" || { rm -f "$_kf_tmp" 2>/dev/null; die "Ошибка chmod GPG ключа."; }
        mv -f "$_kf_tmp" "$keyring_file" \
            || { rm -f "$_kf_tmp" 2>/dev/null; die "Ошибка перемещения GPG ключа."; }

        # Debian 12 использует traditional .list формат, Debian 13+ и Ubuntu 24.04+ — DEB822 .sources
        if [[ "${OS_ID:-ubuntu}" == "debian" && "${OS_VERSION}" == "12" ]]; then
            log "Debian 12: используем традиционный формат .list"
            echo "deb [signed-by=${keyring_file}] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu ${ppa_codename} main" \
                > "$ppa_list" || die "Ошибка создания $ppa_list"
            chmod 644 "$ppa_list"
        else
            cat > "$ppa_sources" <<PPASRC || die "Ошибка создания sources PPA."
Types: deb
URIs: https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu
Suites: ${ppa_codename}
Components: main
Signed-By: ${keyring_file}
PPASRC
            chmod 644 "$ppa_sources"
        fi
        log "PPA добавлен."
    fi
    # apt-get update + классификация ошибок:
    #   - Ошибки ТОЛЬКО на PPA Amnezia → продолжаем, apt_wait_for_ppa_package
    #     ниже сделает retry (issue #68: ppa.launchpadcontent.net коротко лежит).
    #   - Любая другая non-source ошибка (DNS / GPG mismatch / dpkg lock на base
    #     mirror) → fall-fail. Продолжать на stale apt-cache небезопасно —
    #     следующий apt-get install упадёт с менее actionable сообщением
    #     (PR #69 review finding).
    if ! apt_update_tolerant --ppa-amnezia-tolerant; then
        log_error "apt-get update завершился с hard error — не PPA outage (issue #68)."
        log_error "Проверьте: DNS, доступ к archive.ubuntu.com / deb.debian.org,"
        log_error "целостность ключей в /etc/apt/keyrings, занятость dpkg lock."
        die "apt update вернул ошибку (rc!=0, не PPA Amnezia)."
    fi
    # apt-get update толерантен к недоступному InRelease (rc=0 даже когда PPA
    # лежит). Поэтому проверяем именно появление пакета amneziawg-dkms в
    # apt-cache, с тремя попытками и backoff 30с/60с (≈1.5 мин total).
    # Кратковременный outage ppa.launchpadcontent.net (issue #68) не должен
    # валить установку.
    if ! apt_wait_for_ppa_package amneziawg-dkms 3 30; then
        log_error "Пакет amneziawg-dkms не появился в apt-cache после 3 попыток."
        log_error "Похоже, ppa.launchpadcontent.net сейчас недоступен — это outage"
        log_error "инфраструктуры Launchpad, не баг скрипта."
        log_error "Подождите 10–15 минут и запустите скрипт снова той же командой."
        log_error "Подробнее: https://github.com/bivlked/amneziawg-installer/issues/68"
        die "PPA Amnezia временно недоступен."
    fi

    # Пакеты AmneziaWG + qrencode + web/IPv6 helpers
    log "Установка пакетов AmneziaWG..."

    # На ARM: сначала пробуем предсобранный .deb (не требует build-tools и headers).
    # Откат на DKMS если совпадения нет или скачивание не удалось.
    local arch
    arch="$(uname -m)"
    if [[ "$arch" == "aarch64" || "$arch" == "armv7l" ]]; then
        if _try_install_prebuilt_arm; then
            log "Модуль ядра установлен из предсобранного пакета. Установка утилит из PPA..."
            install_packages "amneziawg-tools" "wireguard-tools" "qrencode" "python3" "openssl"
            [[ "${AWG_IPV6_MODE:-}" == "ndp" && "${AWG_IPV6_NDP_PROXY:-0}" -eq 1 ]] && install_packages "ndppd"
            log "Шаг 2 завершен (prebuilt ARM)."
            request_reboot 3
            return
        fi
        log "Совпадений не найдено — откат на DKMS."
    fi

    local packages=("amneziawg-dkms" "amneziawg-tools" "wireguard-tools" "dkms"
                    "build-essential" "dpkg-dev" "qrencode" "python3" "openssl")
    if [[ "${AWG_IPV6_MODE:-}" == "ndp" && "${AWG_IPV6_NDP_PROXY:-0}" -eq 1 ]]; then
        packages+=("ndppd")
    fi

    # Linux headers: на Debian может не быть точного linux-headers-$(uname -r)
    local current_headers
    current_headers="linux-headers-$(uname -r)"
    if dpkg -s "$current_headers" &>/dev/null || apt-cache show "$current_headers" &>/dev/null 2>&1; then
        packages+=("$current_headers")
    else
        log_warn "Нет headers для $(uname -r), установка общего пакета..."
        local kernel_release
        kernel_release="$(uname -r)"
        if [[ "$kernel_release" == *+rpt* || "$kernel_release" == *-rpi* ]]; then
            # Ядро Raspberry Pi Foundation (+rpt suffix) — использовать мета-пакет RPi
            # linux-headers-rpi-2712: Pi 5 / Cortex-A76; linux-headers-rpi-v8: Pi 3/4 arm64
            local rpi_headers
            if [[ "$kernel_release" == *2712* ]]; then
                rpi_headers="linux-headers-rpi-2712"
            else
                rpi_headers="linux-headers-rpi-v8"
            fi
            log "Обнаружено ядро Raspberry Pi, используем $rpi_headers"
            packages+=("$rpi_headers")
        elif [[ "${OS_ID:-ubuntu}" == "debian" ]]; then
            # На Debian: linux-headers-$(dpkg --print-architecture)
            local arch_pkg
            arch_pkg="linux-headers-$(dpkg --print-architecture 2>/dev/null || echo "amd64")"
            packages+=("$arch_pkg")
        else
            packages+=("linux-headers-generic")
        fi
    fi
    # v5.13.0: на 25.10/26.04 после in-place upgrade с 24.04 в системе могут
    # остаться kernel headers от 24.04 (6.8.x), скомпилированные gcc-13. В
    # 25.10 по умолчанию ставится только gcc-15 → dkms autoinstall в postinst
    # пакета amneziawg-dkms падает при сборке под устаревшие ядра, и dpkg
    # оставляет amneziawg* unconfigured. Если в системе обнаружены kernel
    # headers, отличные от running, заранее доставляем gcc-13 (доступен в
    # questing/universe и 26.04 archive), чтобы autoinstall прошёл для всех
    # ядер.
    local _running_kernel _has_stale=0 _hd _hd_kern
    _running_kernel="$(uname -r)"
    for _hd in /lib/modules/*/build; do
        [[ -e "$_hd" ]] || continue
        _hd_kern="${_hd#/lib/modules/}"
        _hd_kern="${_hd_kern%/build}"
        if [[ "$_hd_kern" != "$_running_kernel" ]]; then
            _has_stale=1
            break
        fi
    done
    if [[ "$_has_stale" -eq 1 ]] && ! command -v gcc-13 >/dev/null 2>&1; then
        if apt-cache madison gcc-13 2>/dev/null | grep -q .; then
            log "Обнаружены устаревшие kernel headers (≠ $_running_kernel) — устанавливаю gcc-13 для совместимости DKMS autoinstall."
            DEBIAN_FRONTEND=noninteractive apt install -y gcc-13 \
                || log_warn "Не удалось установить gcc-13 — DKMS autoinstall может падать на устаревших ядрах."
        else
            log_warn "Обнаружены устаревшие kernel headers, но gcc-13 недоступен в repo — DKMS autoinstall может падать."
        fi
    fi
    install_packages "${packages[@]}"

    # v5.12.0: мета-пакет linux-headers, чтобы apt автоматически подтягивал
    # заголовки при kernel upgrade. Без меты ставится только
    # linux-headers-$(uname -r) — он не tracking новые ядра, и на следующем
    # apt upgrade DKMS-модуль не успеет пересобраться.
    #
    # Detect kernel flavor (Ubuntu cloud images: aws/azure/gcp/oracle/kvm/
    # lowlatency/raspi; Debian cloud-amd64) — обычный linux-headers-generic
    # на Azure-VM tracking не тот kernel-pipeline. Берём суффикс uname -r,
    # пробуем flavor-specific meta, fallback на generic/arch.
    local arch_meta kernel_rel
    arch_meta="$(dpkg --print-architecture 2>/dev/null || echo '')"
    kernel_rel="$(uname -r)"
    local -a meta_candidates=()
    if [[ "$kernel_rel" == *+rpt* || "$kernel_rel" == *-rpi* ]]; then
        : # RPi: мета linux-headers-rpi-{2712,v8} уже добавлена в packages выше.
    elif [[ "${OS_ID:-ubuntu}" == "ubuntu" ]]; then
        # Ubuntu uname -r формат: 6.8.0-49-generic / 6.8.0-1009-aws / ...
        local flavor="${kernel_rel##*-}"
        if [[ -n "$flavor" && "$flavor" != "$kernel_rel" ]]; then
            meta_candidates+=("linux-headers-${flavor}")
        fi
        meta_candidates+=("linux-headers-generic")
    elif [[ "${OS_ID:-}" == "debian" && -n "$arch_meta" ]]; then
        # Debian: обычное ядро 6.12.85+deb13-amd64, cloud — 6.12.85+deb13-cloud-amd64.
        [[ "$kernel_rel" == *-cloud-* ]] \
            && meta_candidates+=("linux-headers-cloud-${arch_meta}")
        meta_candidates+=("linux-headers-${arch_meta}")
    fi
    local meta meta_installed=0
    for meta in "${meta_candidates[@]}"; do
        if dpkg-query -W -f='${Status}' "$meta" 2>/dev/null \
                | grep -q 'install ok installed'; then
            log "$meta уже установлен (auto-tracking ядерных обновлений)."
            meta_installed=1
            break
        fi
        log "Установка мета-пакета $meta..."
        if DEBIAN_FRONTEND=noninteractive apt install -y "$meta" 2>/dev/null; then
            log "$meta установлен."
            meta_installed=1
            break
        fi
        log_warn "Не удалось установить $meta — пробуем следующий вариант."
    done
    if [[ ${#meta_candidates[@]} -gt 0 && $meta_installed -eq 0 ]]; then
        log_warn "Ни один meta-пакет kernel-headers не установлен — auto-rebuild при kernel upgrade может не работать."
    fi

    # v5.12.0: standalone helper /usr/local/sbin/amneziawg-ensure-module
    # вызывается из apt hook (DPkg::Post-Invoke) и из Phase 4 systemd-юнита.
    # Helper самодостаточен — не source awg_common.sh, чтобы оставаться
    # рабочим даже после ручного перемещения /root/awg/.
    #
    # Развёртывание делается через staging-файл в той же FS, что и target,
    # с финальным `mv -f` — гарантирует atomic-подмену (cross-FS rename
    # = copy+remove, НЕ atomic). Стейджинг-файл начинается с точки —
    # apt и logrotate пропускают dotfiles при сканировании каталога.
    log "Развёртывание helper'а DKMS auto-repair..."
    mkdir -p /usr/local/sbin
    local _stage_helper=/usr/local/sbin/.amneziawg-ensure-module.new
    cat > "$_stage_helper" <<'AWG_ENSURE_HELPER_EOF'
#!/bin/bash
# amneziawg-ensure-module — rebuilds the AmneziaWG DKMS module after a
# kernel upgrade.
#
# Generated by install_amneziawg.sh (v5.12.0+). Do not edit; re-run the
# installer to refresh.
#
# Modes:
#   --hook     — invoked from /etc/apt/apt.conf.d/99-amneziawg-post-kernel
#                (DPkg::Post-Invoke). Constraints:
#                  - MUST NOT call apt-get install: the parent apt still
#                    holds /var/lib/dpkg/lock-frontend, a nested install
#                    would deadlock.
#                  - Skips modprobe and systemctl: the running kernel may
#                    still be the old one. The newly-built module is
#                    loaded after reboot via the systemd unit, or via
#                    `manage repair-module`.
#                Stamp-file fast-path keeps routine apt ops noise-free.
#
#   --systemd  — invoked from amneziawg-ensure-module.service at boot,
#                ordered Before=awg-quick@awg0.service. Builds for every
#                target kernel (same as --hook), then loads the module
#                via modprobe so awg-quick can start. No stamp fast-path
#                — boot must always verify load state, even if /lib/modules
#                hasn't changed since the last build (module not loaded
#                across reboots). Exit 1 if modprobe fails so systemd
#                marks the unit as failed (visible via systemctl status).
#
# Iteration target: every kernel that exposes /lib/modules/<ver>/build
# (= a directory with installed headers). uname -r alone is insufficient
# in apt-hook context because it returns the OLD running kernel while
# the new kernel's headers are already on disk.
#
# Output: stdout / stderr; --hook appends to
# /var/log/amneziawg-ensure-module.log (rotated weekly via
# /etc/logrotate.d/amneziawg-ensure-module). --systemd writes to journal
# (StandardOutput=journal, StandardError=journal in the unit file).

set -euo pipefail

MODE="${1:-}"
case "$MODE" in
    --hook|--systemd) ;;
    --help|-h) echo "Usage: $0 --hook | --systemd"; exit 0 ;;
    *) echo "amneziawg-ensure-module: missing or unknown mode (use --hook or --systemd)" >&2; exit 2 ;;
esac

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_line() { printf '[%s] [%s] %s\n' "$(ts)" "$MODE" "$*"; }

if [[ $(id -u) -ne 0 ]]; then
    log_line "ERROR: root privileges required" >&2
    exit 1
fi

if ! command -v dkms >/dev/null 2>&1; then
    log_line "WARN: dkms is not installed — nothing to do"
    exit 0
fi

declare -a target_kernels=()
shopt -s nullglob
for build_dir in /lib/modules/*/build; do
    [[ -d "$build_dir" || -L "$build_dir" ]] || continue
    target_kernels+=("$(basename "$(dirname "$build_dir")")")
done
shopt -u nullglob

if [[ ${#target_kernels[@]} -eq 0 ]]; then
    log_line "WARN: no /lib/modules/*/build directories — kernel headers missing"
    exit 0
fi

# Build per-run state signature (mtime + kver) used by both modes:
#   --hook     — for stamp-file fast-path comparison (silent exit if equal)
#   --systemd  — recorded after success so subsequent --hook calls can skip
STAMP_DIR=/var/lib/amneziawg
STAMP_FILE="${STAMP_DIR}/ensure-module.stamp"
current_state=""
for kver in "${target_kernels[@]}"; do
    # stat may fail (build dir removed in flight) — guard against set -e abort.
    # Empty mtime → comparison differs → we re-run dkms autoinstall (acceptable).
    mtime="$(stat -c '%Y' "/lib/modules/${kver}/build" 2>/dev/null || true)"
    current_state+="${mtime} ${kver} "
done

# Fast-path applies ONLY to --hook. Boot (--systemd) must always run the
# full path — module is not loaded across reboots even when /lib/modules
# state is unchanged.
if [[ "$MODE" == "--hook" ]] \
        && [[ -f "$STAMP_FILE" && "$(cat "$STAMP_FILE" 2>/dev/null)" == "$current_state" ]]; then
    # Silent exit — routine apt ops don't add log noise.
    exit 0
fi

# Strip the deprecated REMAKE_INITRD directive (triggers noisy warnings
# on modern DKMS releases).
for cfg in /var/lib/dkms/amneziawg/*/source/dkms.conf; do
    [[ -f "$cfg" ]] && sed -i '/^REMAKE_INITRD=/d' "$cfg" 2>/dev/null || true
done

build_rc=0
for kver in "${target_kernels[@]}"; do
    log_line "dkms autoinstall -k $kver"
    if ! dkms autoinstall -k "$kver"; then
        log_line "WARN: dkms autoinstall failed for kernel $kver" >&2
        build_rc=1
    fi
done

depmod -a 2>/dev/null || true

# --systemd: load the module so awg-quick can start. Exit 1 on modprobe
# failure — systemd marks the unit failed; visible via `systemctl status
# amneziawg-ensure-module.service`. awg-quick still starts (Before= is
# ordering only, not a dependency) and surfaces its own error if the
# module is unavailable.
if [[ "$MODE" == "--systemd" ]]; then
    log_line "modprobe amneziawg"
    if ! modprobe amneziawg 2>&1; then
        log_line "ERROR: modprobe amneziawg failed for running kernel $(uname -r)" >&2
        log_line "  Check: /var/lib/dkms/amneziawg/<ver>/<kernel>/log/make.log" >&2
        exit 1
    fi
    if ! lsmod 2>/dev/null | grep -q '^amneziawg '; then
        log_line "ERROR: amneziawg module not present in lsmod after modprobe" >&2
        exit 1
    fi
    log_line "amneziawg module loaded for $(uname -r)"
    # Update stamp on --systemd success (current kernel is usable, what matters
    # for boot) even if some other kernel's build failed (build_rc=1).
    mkdir -p "$STAMP_DIR" 2>/dev/null || true
    printf '%s' "$current_state" > "$STAMP_FILE" 2>/dev/null || true
    log_line "done"
    exit 0
fi

# --hook: update stamp only on full success — partial failures retry next run.
if [[ $build_rc -eq 0 ]]; then
    mkdir -p "$STAMP_DIR" 2>/dev/null || true
    printf '%s' "$current_state" > "$STAMP_FILE" 2>/dev/null || true
fi

log_line "done (rc=$build_rc)"
exit "$build_rc"
AWG_ENSURE_HELPER_EOF
    chown root:root "$_stage_helper" 2>/dev/null || true
    chmod 0755 "$_stage_helper" \
        || { rm -f "$_stage_helper"; die "Не удалось chmod helper'а."; }
    mv -f "$_stage_helper" /usr/local/sbin/amneziawg-ensure-module \
        || { rm -f "$_stage_helper"; die "Не удалось развернуть helper amneziawg-ensure-module."; }
    log "Helper /usr/local/sbin/amneziawg-ensure-module развёрнут."

    # v5.12.0: apt hook DPkg::Post-Invoke вызывает helper после kernel upgrade.
    mkdir -p /etc/apt/apt.conf.d
    local _stage_hook=/etc/apt/apt.conf.d/.99-amneziawg-post-kernel.new
    cat > "$_stage_hook" <<'AWG_APT_HOOK_EOF'
// amneziawg-installer (v5.12.0+): rebuild DKMS module after kernel upgrades.
// Generated by install_amneziawg.sh — do not edit; re-run the installer to refresh.
DPkg::Post-Invoke {"if [ -x /usr/local/sbin/amneziawg-ensure-module ]; then /usr/local/sbin/amneziawg-ensure-module --hook >>/var/log/amneziawg-ensure-module.log 2>&1 || true; fi";};
AWG_APT_HOOK_EOF
    chown root:root "$_stage_hook" 2>/dev/null || true
    chmod 0644 "$_stage_hook" \
        || { rm -f "$_stage_hook"; die "Не удалось chmod apt-hook."; }
    mv -f "$_stage_hook" /etc/apt/apt.conf.d/99-amneziawg-post-kernel \
        || { rm -f "$_stage_hook"; die "Не удалось развернуть apt-hook."; }
    log "Apt-hook 99-amneziawg-post-kernel установлен (auto-rebuild при apt upgrade ядра)."

    # v5.12.0: logrotate для /var/log/amneziawg-ensure-module.log
    mkdir -p /etc/logrotate.d
    local _stage_logrotate=/etc/logrotate.d/.amneziawg-ensure-module.new
    cat > "$_stage_logrotate" <<'AWG_LOGROTATE_EOF'
/var/log/amneziawg-ensure-module.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
AWG_LOGROTATE_EOF
    chown root:root "$_stage_logrotate" 2>/dev/null || true
    chmod 0644 "$_stage_logrotate" \
        || { rm -f "$_stage_logrotate"; die "Не удалось chmod logrotate-конфиг."; }
    mv -f "$_stage_logrotate" /etc/logrotate.d/amneziawg-ensure-module \
        || { rm -f "$_stage_logrotate"; die "Не удалось развернуть logrotate-конфиг."; }
    log "Logrotate-конфиг /etc/logrotate.d/amneziawg-ensure-module установлен (weekly, rotate 4)."

    # v5.12.0 Phase 4: systemd unit гарантирует, что модуль ядра построен
    # и загружен ДО старта awg-quick@awg0 на каждом boot. Type=oneshot +
    # RemainAfterExit=yes + Before=awg-quick@awg0.service — стандартный
    # pre-load pattern (после kernel upgrade DKMS пересборка может
    # понадобиться сразу при первом boot нового ядра).
    log "Развёртывание systemd-юнита amneziawg-ensure-module.service..."
    mkdir -p /etc/systemd/system
    local _stage_unit=/etc/systemd/system/.amneziawg-ensure-module.service.new
    cat > "$_stage_unit" <<'AWG_SYSTEMD_UNIT_EOF'
[Unit]
Description=Ensure amneziawg kernel module is built and loaded
Documentation=https://github.com/bivlked/amneziawg-installer
Before=awg-quick@awg0.service
After=systemd-modules-load.service local-fs.target
ConditionPathExists=/usr/local/sbin/amneziawg-ensure-module

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/amneziawg-ensure-module --systemd
TimeoutStartSec=300
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
AWG_SYSTEMD_UNIT_EOF
    chown root:root "$_stage_unit" 2>/dev/null || true
    chmod 0644 "$_stage_unit" \
        || { rm -f "$_stage_unit"; die "Не удалось chmod systemd unit."; }
    mv -f "$_stage_unit" /etc/systemd/system/amneziawg-ensure-module.service \
        || { rm -f "$_stage_unit"; die "Не удалось развернуть systemd unit."; }
    if ! systemctl daemon-reload; then
        log_warn "systemctl daemon-reload завершился с ошибкой — unit может не активироваться до перезагрузки."
    fi
    if ! systemctl enable amneziawg-ensure-module.service; then
        log_warn "Не удалось enable amneziawg-ensure-module.service — boot-time auto-rebuild не будет срабатывать."
    fi
    log "Systemd-юнит amneziawg-ensure-module.service установлен и enabled (Before=awg-quick@awg0)."

    # DKMS статус
    log "Проверка статуса DKMS..."
    local dkms_stat
    dkms_stat=$(dkms status 2>&1)
    if ! echo "$dkms_stat" | grep -q 'amneziawg.*installed'; then
        log_warn "DKMS статус не OK."
        log_msg "WARN" "$dkms_stat"
    else
        log "DKMS статус OK."
    fi

    log "Шаг 2 завершен."
    request_reboot 3
}

# ==============================================================================
# ШАГ 3: Проверка модуля ядра
# ==============================================================================

step3_check_module() {
    update_state 3
    log "### ШАГ 3: Проверка модуля ядра ###"
    sleep 2

    if ! lsmod | grep -q -w amneziawg; then
        log "Модуль не загружен. Загрузка..."
        modprobe amneziawg || die "Ошибка modprobe amneziawg."
        log "Модуль загружен."
        local mf="/etc/modules-load.d/amneziawg.conf"
        mkdir -p "$(dirname "$mf")"
        if ! grep -qxF 'amneziawg' "$mf" 2>/dev/null; then
            echo "amneziawg" > "$mf" || log_warn "Ошибка записи $mf"
            log "Добавлено в $mf."
        fi
    else
        log "Модуль amneziawg загружен."
    fi

    log "Информация о модуле:"
    modinfo amneziawg | grep -E "filename|version|vermagic|srcversion" | while IFS= read -r line; do
        log "  $line"
    done

    local cv kr
    cv=$(modinfo amneziawg 2>/dev/null | awk '/^vermagic:/{print $2}')
    if [[ -z "$cv" ]]; then
        die "Не удалось прочитать vermagic модуля amneziawg. Проверьте: modprobe amneziawg && modinfo amneziawg"
    fi
    kr=$(uname -r)
    if [[ "$cv" != "$kr" ]]; then
        log_warn "VerMagic НЕ совпадает: Модуль($cv) != Ядро($kr)!"
    else
        log "VerMagic совпадает."
    fi

    # Проверка версии awg
    if command -v awg &>/dev/null; then
        local awg_ver
        awg_ver=$(awg --version 2>/dev/null || echo "неизвестна")
        log "Версия awg: $awg_ver"
    else
        log_warn "Команда awg не найдена!"
    fi

    log "Шаг 3 завершен."
    update_state 4
}

# ==============================================================================
# ШАГ 4: Настройка фаервола
# ==============================================================================

step4_setup_firewall() {
    update_state 4
    if [[ "$NO_TWEAKS" -eq 0 && "${AWG_DISABLE_UFW:-0}" != "1" ]]; then
        log "### ШАГ 4: Настройка фаервола UFW ###"
        install_packages ufw
        setup_improved_firewall || die "Ошибка настройки UFW."
        log "Шаг 4 завершен."
    elif [[ "${AWG_DISABLE_UFW:-0}" == "1" ]]; then
        log "### ШАГ 4: Пропуск включения UFW (--disable-ufw/AWG_DISABLE_UFW=1) ###"
        setup_improved_firewall || true
    else
        log "### ШАГ 4: Пропуск настройки UFW (--no-tweaks) ###"
    fi
    update_state 5
}

# ==============================================================================
# ШАГ 5: Скачивание скриптов (БЕЗ Python!)
# ==============================================================================

verify_sha256() {
    local file="$1" expected="$2" label="$3"
    if [[ -z "$expected" || "$expected" == "RELEASE_PLACEHOLDER" ]]; then
        log_error "SHA256 для $label не задан; небезопасная загрузка запрещена."
        return 1
    fi
    local actual
    actual=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        log_error "SHA256 $label НЕ совпадает!"
        log_error "  Ожидался: $expected"
        log_error "  Получен:  $actual"
        log_error "  Файл мог быть подменён. Скачайте installer заново с GitHub."
        return 1
    fi
    log_debug "SHA256 $label: OK ($actual)"
    return 0
}

# _secure_download <url> <target> <expected_sha256> <label> <mode>
# Atomic download:
#   1. curl → mktemp на том же FS, что и target;
#   2. verify_sha256 на temp (не на target, чтобы corrupt-файл не оказался
#      на целевом пути даже на долю секунды);
#   3. chmod 700 на temp;
#   4. mv -f temp → target (атомарный rename).
# Если любой шаг падает — temp удаляется, target не трогается.
_secure_download() {
    local url="$1" target="$2" expected_sha256="$3" label="$4" mode="${5:-644}"
    local tmp target_dir verified=1
    target_dir=$(dirname "$target")
    mkdir -p "$target_dir" || die "Не удалось создать каталог $target_dir"
    tmp=$(mktemp -p "$target_dir" ".${label//\//_}.tmp.XXXXXX") \
        || die "Не удалось создать временный файл для $label"
    if ! curl -fLso "$tmp" --max-time 60 --retry 2 "$url"; then
        rm -f "$tmp" 2>/dev/null
        die "Ошибка скачивания $label"
    fi
    if [[ -z "$expected_sha256" || "$expected_sha256" == "RELEASE_PLACEHOLDER" ]]; then
        if [[ "${AWG_ALLOW_UNVERIFIED_DOWNLOAD:-0}" != "1" ]]; then
            rm -f "$tmp" 2>/dev/null
            die "$label отсутствует локально, а SHA256 не задан. Установка остановлена; задайте SHA256 manifest или используйте AWG_ALLOW_UNVERIFIED_DOWNLOAD=1 только для разработки."
        fi
        log_warn "$label скачивается без SHA256 только из-за AWG_ALLOW_UNVERIFIED_DOWNLOAD=1."
        verified=0
    elif ! verify_sha256 "$tmp" "$expected_sha256" "$label"; then
        rm -f "$tmp" 2>/dev/null
        die "Целостность $label не подтверждена (SHA256 mismatch). Установка прервана."
    fi
    if ! chmod "$mode" "$tmp"; then
        rm -f "$tmp" 2>/dev/null
        die "Ошибка chmod $label"
    fi
    if ! mv -f "$tmp" "$target"; then
        rm -f "$tmp" 2>/dev/null
        die "Ошибка перемещения $label на целевой путь"
    fi
    if [[ "$verified" -eq 1 ]]; then
        log "$label скачан и верифицирован."
    else
        log_warn "$label скачан без SHA256 verification."
    fi
}

_deploy_asset() {
    local asset_path="$1" target="$2" mode="${3:-644}" src url expected
    src="${INSTALLER_DIR}/${asset_path}"
    url="https://raw.githubusercontent.com/${AWG_REPO}/${AWG_BRANCH}/${asset_path}"
    expected="${AWG_ASSET_SHA256[$asset_path]-}"
    mkdir -p "$(dirname "$target")" || die "Не удалось создать каталог для $asset_path"
    if [[ -f "$src" ]]; then
        cp -a "$src" "$target" || die "Не удалось скопировать $asset_path"
        chmod "$mode" "$target" || die "Ошибка chmod $asset_path"
        log "$asset_path скопирован локально."
        return 0
    fi
    _secure_download "$url" "$target" "$expected" "$asset_path" "$mode"
}

step5_download_scripts() {
    update_state 5
    log "### ШАГ 5: Скачивание скриптов управления ###"
    cd "$AWG_DIR" || die "Ошибка перехода в $AWG_DIR"

    _deploy_asset "awg_common.sh" "$COMMON_SCRIPT_PATH" 700
    _deploy_asset "manage_amneziawg.sh" "$MANAGE_SCRIPT_PATH" 700

    log "Шаг 5 завершен."
    update_state 6
}

setup_ndppd_config() {
    [[ "${AWG_IPV6_ENABLED:-0}" -eq 1 && "${AWG_IPV6_MODE:-}" == "ndp" && "${AWG_IPV6_NDP_PROXY:-0}" -eq 1 ]] || return 0
    local nic conf="/etc/ndppd.conf"
    [[ -n "${AWG_IPV6_SUBNET:-}" ]] || { log_warn "ndppd пропущен: AWG_IPV6_SUBNET пуст."; return 0; }
    nic=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    [[ -n "$nic" ]] || nic="eth0"
    if [[ -f "$conf" ]] && ! grep -q "Managed by AmneziaWG installer" "$conf"; then
        cp -a "$conf" "${conf}.bak.$(date +%Y%m%d-%H%M%S)" || die "Не удалось сделать backup $conf"
    fi
    cat > "$conf" << EOF
# Managed by AmneziaWG installer. Manual changes may be overwritten.
route_ttl 30000
proxy ${nic} {
    router yes
    timeout 500
    ttl 30000
    rule ${AWG_IPV6_SUBNET} {
        auto
    }
}
EOF
    chmod 644 "$conf"
    systemctl enable ndppd 2>/dev/null || log_warn "Не удалось enable ndppd"
    systemctl restart ndppd 2>/dev/null || log_warn "Не удалось restart ndppd"
    log "ndppd настроен для ${AWG_IPV6_SUBNET} через ${nic}."
}

render_curated_adguard_yaml() {
    local existing_yaml="$1" output_yaml="$2" server_conf="$3" ag_port="$4" ag_user="$5" ag_hash="$6"
    AWG_TUNNEL_SUBNET="${AWG_TUNNEL_SUBNET:-10.9.9.1/24}" \
    AWG_IPV6_ENABLED="${AWG_IPV6_ENABLED:-0}" \
    AWG_IPV6_SUBNET="${AWG_IPV6_SUBNET:-}" \
    python3 - "$existing_yaml" "$output_yaml" "$server_conf" "$ag_port" "$ag_user" "$ag_hash" <<'PY'
import ipaddress
import json
import os
import re
import sys
from pathlib import Path

existing_yaml = Path(sys.argv[1])
output_yaml = Path(sys.argv[2])
server_conf = Path(sys.argv[3])
ag_port = int(sys.argv[4])
ag_user = sys.argv[5]
ag_hash = sys.argv[6]

enabled_filters = [
    (4, "https://adguardteam.github.io/HostlistsRegistry/assets/filter_60.txt", "HaGeZi's Xiaomi Tracker Blocklist"),
    (7, "https://raw.githubusercontent.com/AdguardTeam/cname-trackers/master/data/combined_disguised_trackers.txt", "AdguardTeam - CNAME Trackers"),
    (9, "https://raw.githubusercontent.com/AdguardTeam/cname-trackers/master/data/combined_disguised_ads.txt", "AdguardTeam - CNAME Ads"),
    (11, "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt", "AdGuard DNS Filter"),
    (12, "https://adguardteam.github.io/HostlistsRegistry/assets/filter_3.txt", "AdGuard Tracking Protection"),
    (13, "https://adguardteam.github.io/HostlistsRegistry/assets/filter_11.txt", "AdGuard Mobile Ads"),
    (14, "https://adguardteam.github.io/HostlistsRegistry/assets/filter_59.txt", "AdGuard DNS Popup Hosts filter"),
    (16, "https://big.oisd.nl/", "OISD - Big"),
    (19, "https://badmojr.github.io/1Hosts/Lite/domains.txt", "1Hosts - Lite"),
    (21, "https://hole.cert.pl/domains/v2/domains.txt", "CERT Polska - Dangerous Websites"),
    (28, "https://cdn.jsdelivr.net/gh/hoshsadiq/adblock-nocoin-list/hosts.txt", "Hoshsadiq - NoCoin Adblock List"),
    (29, "https://raw.githubusercontent.com/azet12/KADhosts/master/KADhosts.txt", "KADhosts"),
    (30, "https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt", "WindowsSpyBlocker - Telemetry"),
    (31, "https://adguardteam.github.io/HostlistsRegistry/assets/filter_23.txt", "WindowsSpyBlocker - Hosts spy rules"),
    (32, "https://raw.githubusercontent.com/Perflyst/PiHoleBlocklist/master/SmartTV.txt", "Perflyst SmartTV"),
    (33, "https://adguardteam.github.io/HostlistsRegistry/assets/filter_53.txt", "AWAvenue Ads Rule"),
]
disabled_filters = [
    (1, "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/pro-onlydomains.txt", "Hagezi - Pro"),
    (2, "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/pro.txt", "hagezi Multi PRO"),
    (3, "https://adguardteam.github.io/HostlistsRegistry/assets/filter_49.txt", "HaGeZi's Ultimate Blocklist"),
    (5, "https://adguardteam.github.io/HostlistsRegistry/assets/filter_46.txt", "HaGeZi's Anti-Piracy Blocklist"),
    (6, "https://adguardteam.github.io/HostlistsRegistry/assets/filter_45.txt", "HaGeZi's Allowlist Referral"),
    (8, "https://raw.githubusercontent.com/AdguardTeam/cname-trackers/master/data/combined_original_trackers.txt", "AdguardTeam - CNAME Clickthroughs"),
    (10, "https://raw.githubusercontent.com/AdguardTeam/cname-trackers/master/data/combined_original_microsites.txt", "AdguardTeam - CNAME Microsites"),
    (15, "https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_1_Russian/filter.txt", "AdGuard Russian Filter (ru)"),
    (17, "https://cdn.jsdelivr.net/gh/StevenBlack/hosts/hosts", "StevenBlack - Unified hosts"),
    (18, "https://adguardteam.github.io/HostlistsRegistry/assets/filter_33.txt", "Steven Black's List"),
    (20, "https://cdn.jsdelivr.net/gh/bongochong/CombinedPrivacyBlockLists/NoFormatting/cpbl-abp-list.txt", "Bongochong - Combined Privacy Block Lists"),
    (22, "https://cdn.jsdelivr.net/gh/kboghdady/youTube_ads_4_pi-hole/black.list", "Kboghdady - YouTube Ads DNS"),
    (23, "https://someonewhocares.org/hosts/hosts", "SomeoneWhoCares - Hosts"),
    (24, "https://winhelp2002.mvps.org/hosts.txt", "WinHelp2002 MVPS - Hosts"),
    (25, "https://adaway.org/hosts.txt", "AdAway - Hosts"),
    (26, "https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt", "AdAway Default Blocklist"),
    (27, "https://pgl.yoyo.org/as/serverlist.php?hostformat=hosts&showintro=1&mimetype=plaintext", "Yoyo.org - Hosts"),
    (34, "https://adguardteam.github.io/HostlistsRegistry/assets/filter_57.txt", "ShadowWhisperer's Dating List"),
    (35, "https://adguardteam.github.io/HostlistsRegistry/assets/filter_17.txt", "SWE Frellwit's Swedish Hosts File"),
    (36, "https://easylist-downloads.adblockplus.org/ruadlist.txt", "RU AdList classic"),
    (37, "https://easylist-downloads.adblockplus.org/bitblock.txt", "RU AdList BitBlock"),
    (38, "https://raw.githubusercontent.com/Zalexanninev15/NoADS_RU/main/ads_list_extended.txt", "NoADS_RU"),
]
upstream_dns = [
    "https://dns.adguard-dns.com/dns-query",
    "https://dns.alidns.com/dns-query",
    "https://dns.cloudflare.com/dns-query",
    "https://security.cloudflare-dns.com/dns-query",
    "https://doh.dns.sb/dns-query",
    "https://dns.pub/dns-query",
    "https://dns.google/dns-query",
    "https://dns.quad9.net/dns-query",
    "https://wikimedia-dns.org/dns-query",
]
bootstrap_dns = [
    "1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001",
    "9.9.9.10", "149.112.112.10", "2620:fe::10", "2620:fe::fe:10",
    "94.140.14.14", "94.140.15.15", "2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff",
    "223.5.5.5", "223.6.6.6", "2400:3200::1", "2400:3200:baba::1",
    "8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844",
    "185.222.222.222", "45.11.45.11", "2a09::", "2a11::",
    "119.29.29.29", "2402:4e00::",
]
curated_user_rules = [
    "@@||cdn.jsdelivr.net^",
    "@@||sso.yandex.ru^",
    "@@||passport.yandex.ru^",
    "@@||yastatic.net^",
    "@@||admitad.com^",
    "@@||awin1.com^",
    "||mc.yandex.ru^",
    "||an.yandex.ru^",
    "||bs.yandex.ru^",
    "||top-fwz1.mail.ru^",
    "||vk-portal.net^",
    "||appmetrica.yandex.com^",
    "||startup.mobile.yandex.net^",
    "||ad.mail.ru^",
    "||r3.mail.ru^",
    "||trg.mail.ru^",
    "||app-measurement.com^",
    "@@||4pda.to^$important",
    "@@||eth0.me^$important",
    "||doubleclick.net^",
    "||googlesyndication.com^",
    "||googleadservices.com^",
    "||media.net^",
    "||adcolony.com^",
    "||stats.wp.com^",
    "||pixel.facebook.com^",
    "||an.facebook.com^",
    "||ads.linkedin.com^",
    "||events.reddit.com^",
    "||events.redditmedia.com^",
    "||ads-api.tiktok.com^",
    "||analytics.tiktok.com^",
    "||ads.tiktok.com^",
    "||static.ads-twitter.com^",
    "||ads-api.twitter.com^",
    "||ads.pinterest.com^",
    "||trk.pinterest.com^",
    "||ads.yahoo.com^",
    "||partnerads.ysm.yahoo.com^",
    "||unityads.unity3d.com^",
    "||appmetrica.yandex.ru^",
    "||adfstat.yandex.ru^",
    "||metrika.yandex.ru^",
    "||adfox.yandex.ru^",
    "||bdapi-ads.realmemobile.com^",
    "||adsfs.oppomobile.com^",
    "||iadsdk.apple.com^",
    "||api-adservices.apple.com^",
    "||api.ad.xiaomi.com^",
    "||tracking.rus.miui.com^",
    "||samsungads.com^",
    "||smetrics.samsung.com^",
]

def q(value):
    return json.dumps(str(value), ensure_ascii=False)

def sq(value):
    return "'" + str(value).replace("'", "''") + "'"

def top_level(line):
    return line and not line.startswith((" ", "\t")) and ":" in line

def extract_top_block(lines, key):
    out = []
    i = 0
    needle = f"{key}:"
    while i < len(lines):
        if lines[i].strip() == needle and not lines[i].startswith((" ", "\t")):
            out.append(lines[i])
            i += 1
            while i < len(lines) and not top_level(lines[i]):
                out.append(lines[i])
                i += 1
            return out
        i += 1
    return []

def extract_clients_persistent(lines):
    clients = extract_top_block(lines, "clients")
    out = []
    for i, line in enumerate(clients):
        if re.match(r"^  persistent\s*:", line):
            out.append(line)
            j = i + 1
            while j < len(clients) and not re.match(r"^  [A-Za-z0-9_-]+\s*:", clients[j]):
                out.append(clients[j])
                j += 1
            return out
    return []

def extract_user_rules(lines):
    block = extract_top_block(lines, "user_rules")
    rules = []
    for line in block[1:]:
        m = re.match(r"^\s*-\s*(.*)\s*$", line)
        if not m:
            continue
        value = m.group(1).strip()
        if (value.startswith("'") and value.endswith("'")) or (value.startswith('"') and value.endswith('"')):
            value = value[1:-1]
        if value and value not in rules:
            rules.append(value)
    return rules

def parse_peers(path):
    peers = []
    if not path.is_file():
        return peers
    cur = None
    for raw in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw.strip()
        if line == "[Peer]":
            if cur and cur.get("name") and cur.get("ids"):
                peers.append(cur)
            cur = {"name": "", "ids": []}
            continue
        if cur is None:
            continue
        if line.startswith("#_Name = "):
            cur["name"] = line.split("=", 1)[1].strip()
        elif re.match(r"^AllowedIPs\s*=", line):
            value = line.split("=", 1)[1]
            for token in re.split(r"[,\s]+", value):
                token = token.strip()
                if token.endswith("/32") or token.endswith("/128"):
                    cur["ids"].append(token.rsplit("/", 1)[0])
    if cur and cur.get("name") and cur.get("ids"):
        peers.append(cur)
    return peers

def client_label(name):
    label = re.sub(r"[^a-z0-9-]+", "-", name.lower())
    return (re.sub(r"-+", "-", label).strip("-") or "client")[:63].rstrip("-") or "client"

def render_users(lines):
    users = extract_top_block(lines, "users")
    out = ["users:", f"  - name: {q(ag_user)}", f"    password: {q(ag_hash)}"]
    i = 1
    while i < len(users):
        if re.match(r"^  -\s+", users[i]):
            item = [users[i]]
            i += 1
            while i < len(users) and not re.match(r"^  -\s+", users[i]):
                item.append(users[i])
                i += 1
            name_line = next((line for line in item if re.match(r"^\s+name\s*:", line)), "")
            if not re.search(rf"name\s*:\s*['\"]?{re.escape(ag_user)}['\"]?\s*$", name_line):
                out.extend(item)
            continue
        i += 1
    return out

def render_clients(lines, peers):
    out = ["clients:"]
    if peers:
        out.append("  persistent:")
        for peer in peers:
            out.append(f"    - name: {q(peer['name'])}")
            out.append("      ids:")
            for client_id in peer["ids"]:
                out.append(f"        - {q(client_id)}")
    else:
        out.extend(extract_clients_persistent(lines) or ["  persistent: []"])
    out.extend(["  runtime_sources:", "    whois: true", "    arp: true", "    rdns: true", "    dhcp: true", "    hosts: true"])
    return out

lines = existing_yaml.read_text(encoding="utf-8", errors="ignore").splitlines() if existing_yaml.is_file() else []
peers = parse_peers(server_conf)
user_rules = []
for rule in curated_user_rules + extract_user_rules(lines):
    if rule not in user_rules:
        user_rules.append(rule)
tunnel = ipaddress.ip_interface(os.environ.get("AWG_TUNNEL_SUBNET", "10.9.9.1/24"))
vpn_ip = str(tunnel.ip)
allowed_clients = [str(tunnel.network)]
bind_hosts = [vpn_ip]
if os.environ.get("AWG_IPV6_ENABLED") == "1" and os.environ.get("AWG_IPV6_SUBNET"):
    v6_net = ipaddress.ip_network(os.environ["AWG_IPV6_SUBNET"], strict=False)
    bind_hosts.append(str(v6_net.network_address + 1))
    allowed_clients.append(str(v6_net))
rewrites = [(f"{client_label(peer['name'])}.awg", client_id) for peer in peers for client_id in peer["ids"]]

out = ["http:", f"  address: {vpn_ip}:{ag_port}", "  session_ttl: 720h", "  pprof:", "    enabled: false", "    port: 6060", "  doh:", "    routes:", "      - GET /dns-query", "      - POST /dns-query", "    insecure_enabled: false"]
out.extend(render_users(lines))
out.extend(["auth_attempts: 5", "block_auth_min: 15", "http_proxy: \"\"", "language: \"\"", "theme: auto", "dns:", "  bind_hosts:"])
out.extend(f"    - {host}" for host in bind_hosts)
out.extend(["  port: 53", "  anonymize_client_ip: false", "  ratelimit: 0", "  ratelimit_subnet_len_ipv4: 24", "  ratelimit_subnet_len_ipv6: 56", "  ratelimit_whitelist: []", "  refuse_any: true", "  upstream_mode: parallel", "  upstream_dns:"])
out.extend(f"    - {q(item)}" for item in upstream_dns)
out.append("  bootstrap_dns:")
out.extend(f"    - {q(item)}" for item in bootstrap_dns)
out.extend(["  bootstrap_prefer_ipv6: false", "  fallback_dns: []", "  fastest_timeout: 1s", "  allowed_clients:"])
out.extend(f"    - {q(item)}" for item in allowed_clients)
out.extend(["  disallowed_clients: []", "  blocked_hosts:", "    - version.bind", "    - id.server", "    - hostname.bind", "  trusted_proxies:", "    - 127.0.0.0/8", "    - ::1/128", "  cache_enabled: true", "  cache_size: 83886080", "  cache_ttl_min: 0", "  cache_ttl_max: 0", "  cache_optimistic: true", "  cache_optimistic_answer_ttl: 30s", "  cache_optimistic_max_age: 12h", "  bogus_nxdomain: []", "  aaaa_disabled: false", "  enable_dnssec: true", "  edns_client_subnet:", "    enabled: false", "    use_custom: false", "    custom_ip: \"\"", "  max_goroutines: 300", "  handle_ddr: true", "  ipset: []", "  ipset_file: \"\"", "  upstream_timeout: 10s", "  private_networks: []", "  use_private_ptr_resolvers: true", "  local_ptr_upstreams: []", "  use_dns64: false", "  dns64_prefixes: []", "  serve_http3: false", "  use_http3_upstreams: false", "  serve_plain_dns: true", "  hostsfile_enabled: true", "  pending_requests:", "    enabled: true", "filtering:", "  protection_enabled: true", "  filtering_enabled: true", "  blocking_mode: default", "  blocking_ipv4: \"\"", "  blocking_ipv6: \"\"", "  blocked_response_ttl: 10", "  parental_block_host: family-block.dns.adguard.com", "  safebrowsing_block_host: standard-block.dns.adguard.com", "  parental_enabled: false", "  safebrowsing_enabled: false", "  safe_search:", "    enabled: false", "    bing: false", "    duckduckgo: false", "    ecosia: false", "    google: false", "    pixabay: false", "    yandex: false", "    youtube: false"])
if rewrites:
    out.append("  rewrites:")
    for domain, answer in rewrites:
        out.extend([f"    - domain: {q(domain)}", f"      answer: {q(answer)}"])
else:
    out.append("  rewrites: []")
out.extend(["  safe_fs_patterns: []", "  cache_time: 30", "  filters_update_interval: 24", "filters:"])
for enabled, data in [(True, enabled_filters), (False, disabled_filters)]:
    for filter_id, url, name in data:
        out.extend([f"  - enabled: {str(enabled).lower()}", f"    url: {url}", f"    name: {q(name)}", f"    id: {filter_id}"])
out.extend(["whitelist_filters: []", "user_rules:"])
out.extend(f"  - {sq(rule)}" for rule in user_rules)
out.extend(["querylog:", "  dir_path: \"\"", "  ignored:", "    - '*.arpa'", "    - '*.lan'", "  interval: 2160h", "  size_memory: 1000", "  enabled: true", "  ignored_enabled: true", "  file_enabled: true", "statistics:", "  dir_path: \"\"", "  ignored:", "    - '*.arpa'", "    - '*.lan'", "  interval: 2160h", "  enabled: true", "  ignored_enabled: true"])
out.extend(render_clients(lines, peers))
out.extend(["dhcp:", "  enabled: false", "tls:", "  enabled: false", "  server_name: \"\"", "  force_https: false", "  port_https: 0", "  port_dns_over_tls: 0", "  port_dns_over_quic: 0", "  port_dnscrypt: 0", "log:", "  enabled: true", "  file: \"\"", "  max_backups: 0", "  max_size: 100", "  max_age: 3", "  compress: false", "  local_time: false", "  verbose: false", "schema_version: 29"])
output_yaml.write_text("\n".join(out) + "\n", encoding="utf-8")
PY
}

deploy_adguard_home() {
    [[ "${AWG_ADGUARD_ENABLED:-0}" -eq 1 ]] || return 0
    log "Развёртывание AdGuard Home (fork delta)..."

    local ag_dir="${AWG_ADGUARD_DIR:-/opt/AdGuardHome}"
    local ag_port="${AWG_ADGUARD_PORT:-3000}"
    local ag_bin="$ag_dir/AdGuardHome"
    local ag_yaml="$ag_dir/AdGuardHome.yaml"
    local ag_arch url tmp tgz AG_HASH=""
    local tmp_conf backup_conf timestamp had_config=0

    case "$(uname -m)" in
        x86_64|amd64) ag_arch="amd64" ;;
        aarch64|arm64) ag_arch="arm64" ;;
        armv7l|armv7*) ag_arch="armv7" ;;
        armv6l|armv6*) ag_arch="armv6" ;;
        *) log_warn "AdGuard Home: неподдерживаемая архитектура $(uname -m), пропуск."; return 0 ;;
    esac

    mkdir -p "$ag_dir" || { log_warn "AdGuard Home: не удалось создать $ag_dir"; return 0; }
    if [[ ! -x "$ag_bin" ]]; then
        tmp=$(mktemp -d) || { log_warn "AdGuard Home: mktemp failed"; return 0; }
        tgz="$tmp/AdGuardHome_linux_${ag_arch}.tar.gz"
        url="https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_${ag_arch}.tar.gz"
        if curl -fL --connect-timeout 10 --max-time 120 -o "$tgz" "$url"; then
            if tar -xzf "$tgz" -C "$tmp" && [[ -x "$tmp/AdGuardHome/AdGuardHome" ]]; then
                cp -a "$tmp/AdGuardHome/." "$ag_dir/" || log_warn "AdGuard Home: не удалось скопировать файлы в $ag_dir"
            else
                log_warn "AdGuard Home: архив не распакован, DNS fallback останется системным."
            fi
        else
            log_warn "AdGuard Home: download failed, VPN продолжит работать с текущим DNS fallback."
        fi
        rm -rf "$tmp"
    fi

    if [[ ! -x "$ag_bin" ]]; then
        log_warn "AdGuard Home binary не найден, пропуск запуска."
        return 0
    fi

    AG_USERNAME="${AG_USERNAME:-admin}"
    install_packages python3-bcrypt
    AG_PASSWORD="${AG_PASSWORD:-$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 15)}"
    if [[ -z "$AG_PASSWORD" ]]; then
        AG_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 15)"
    fi
    [[ -n "$AG_PASSWORD" ]] || die "AdGuard Home: не удалось сгенерировать пароль администратора"
    AG_HASH="$(printf '%s' "$AG_PASSWORD" | python3 -c '
import sys
import bcrypt

password = sys.stdin.buffer.read()
print(bcrypt.hashpw(password, bcrypt.gensalt(rounds=10, prefix=b"2b")).decode())
')" || die "AdGuard Home: не удалось сгенерировать bcrypt-хеш"
    [[ -n "$AG_HASH" ]] || die "AdGuard Home: пустой bcrypt-хеш пароля"

    timestamp="$(date '+%Y%m%d-%H%M%S')"
    tmp_conf="$(mktemp "$ag_dir/.AdGuardHome.yaml.tmp.XXXXXX")" || die "AdGuard Home: mktemp config failed"
    _install_temp_files+=("$tmp_conf")
    if [[ -f "$ag_yaml" ]]; then
        had_config=1
        backup_conf="${ag_yaml}.bak.${timestamp}"
        cp -p "$ag_yaml" "$backup_conf" || die "AdGuard Home: не удалось создать backup $backup_conf"
        chmod 600 "$backup_conf" 2>/dev/null || true
    fi

    render_curated_adguard_yaml "$ag_yaml" "$tmp_conf" "$SERVER_CONF_FILE" "$ag_port" "$AG_USERNAME" "$AG_HASH" || \
        die "AdGuard Home: не удалось сгенерировать curated YAML"
    chmod 600 "$tmp_conf"

    local ag_dir_unit ag_bin_unit ag_conf_unit
    ag_dir_unit="$(systemd_abs_path_value "$ag_dir")" || die "Некорректный AdGuardHome dir"
    ag_bin_unit="$(systemd_abs_path_value "$ag_bin")" || die "Некорректный AdGuardHome binary path"
    ag_conf_unit="$(systemd_abs_path_value "$ag_yaml")" || die "Некорректный AdGuardHome config path"

    cat > /etc/systemd/system/AdGuardHome.service << EOF
[Unit]
Description=AdGuard Home for AmneziaWG clients
After=network-online.target awg-quick@awg0.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${ag_dir_unit}
ExecStart=${ag_bin_unit} -c ${ag_conf_unit} -w ${ag_dir_unit} --no-check-update
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 /etc/systemd/system/AdGuardHome.service
    systemctl daemon-reload
    systemctl enable AdGuardHome.service 2>/dev/null || log_warn "Не удалось enable AdGuardHome.service"

    if systemctl is-active --quiet AdGuardHome.service 2>/dev/null; then
        systemctl stop AdGuardHome.service || true
    fi

    if ! "$ag_bin" --check-config -c "$tmp_conf" -w "$ag_dir"; then
        if [[ "$had_config" -eq 1 && -n "${backup_conf:-}" && -f "$backup_conf" ]]; then
            cp -p "$backup_conf" "$ag_yaml" || true
        fi
        die "AdGuard Home: --check-config не прошёл, backup восстановлен."
    fi

    if ! mv -f "$tmp_conf" "$ag_yaml"; then
        if [[ "$had_config" -eq 1 && -n "${backup_conf:-}" && -f "$backup_conf" ]]; then
            cp -p "$backup_conf" "$ag_yaml" || true
        fi
        die "AdGuard Home: не удалось атомарно заменить $ag_yaml"
    fi
    chmod 600 "$ag_yaml"

    if ! systemctl restart AdGuardHome.service; then
        log_warn "AdGuard Home не стартовал. VPN не сломан; переключитесь на system DNS: manage dns set-mode system."
    else
        log "AdGuard Home запущен с curated YAML: DNS ${AWG_TUNNEL_SUBNET%/*}:53, UI http://${AWG_TUNNEL_SUBNET%/*}:${ag_port}/"
    fi
}

web_ip_domain() {
    local ip="${AWG_ENDPOINT:-}" provider="${AWG_WEB_CERT_PROVIDER:-sslip.io}"
    generate_ip_domain "$ip" "$provider"
}

persist_config_value() {
    local key="$1" value="$2" tmp quoted
    [[ -f "$CONFIG_FILE" ]] || return 0
    quoted="$(shell_quote "$value")"
    tmp="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")" || return 1
    awk -v key="$key" -v line="export ${key}=${quoted}" '
        $0 ~ "^export " key "=" || $0 ~ "^" key "=" { print line; done=1; next }
        { print }
        END { if (!done) print line }
    ' "$CONFIG_FILE" > "$tmp" && mv -f "$tmp" "$CONFIG_FILE" || {
        rm -f "$tmp" 2>/dev/null
        return 1
    }
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

persist_web_cert_state() {
    persist_config_value AWG_WEB_CERT_MODE "${AWG_WEB_CERT_MODE:-selfsigned}" || log_warn "Не удалось сохранить AWG_WEB_CERT_MODE."
    persist_config_value AWG_WEB_DOMAIN "${AWG_WEB_DOMAIN:-}" || log_warn "Не удалось сохранить AWG_WEB_DOMAIN."
    persist_config_value AWG_WEB_PUBLIC_URL "${AWG_WEB_PUBLIC_URL:-}" || log_warn "Не удалось сохранить AWG_WEB_PUBLIC_URL."
    persist_config_value AWG_WEB_CERT_ATTEMPTED_MODE "${AWG_WEB_CERT_ATTEMPTED_MODE:-}" || log_warn "Не удалось сохранить AWG_WEB_CERT_ATTEMPTED_MODE."
    persist_config_value AWG_WEB_CERT_FAILURE_REASON "${AWG_WEB_CERT_FAILURE_REASON:-}" || log_warn "Не удалось сохранить AWG_WEB_CERT_FAILURE_REASON."
    persist_config_value AWG_WEB_CERT_FALLBACK_USED "${AWG_WEB_CERT_FALLBACK_USED:-}" || log_warn "Не удалось сохранить AWG_WEB_CERT_FALLBACK_USED."
}

ufw_allow_http01_temporarily() {
    local added=0
    AWG_CERTBOT_UFW80_ADDED=0
    export AWG_CERTBOT_UFW80_ADDED

    if ! command -v ufw >/dev/null 2>&1; then
        log_msg "WARN" "UFW не установлен; убедитесь, что 80/tcp открыт внешним firewall/security group."
        return 0
    fi
    if ! ufw status 2>/dev/null | grep -qi "Status: active"; then
        log_msg "WARN" "UFW неактивен; убедитесь, что 80/tcp открыт внешним firewall/security group."
        return 0
    fi
    if ufw status numbered 2>/dev/null | grep -Eq '(^|[[:space:]])80/tcp[[:space:]]+ALLOW IN'; then
        log_msg "INFO" "80/tcp уже открыт в UFW."
        return 0
    fi
    if ufw allow 80/tcp comment "Temporary Let's Encrypt HTTP-01" >/dev/null 2>&1; then
        added=1
    elif ufw allow 80/tcp >/dev/null 2>&1; then
        added=1
    else
        log_msg "WARN" "Не удалось открыть 80/tcp в UFW. Проверьте внешний firewall/security group."
        return 1
    fi
    ufw reload >/dev/null 2>&1 || true
    AWG_CERTBOT_UFW80_ADDED="$added"
    export AWG_CERTBOT_UFW80_ADDED
    log_msg "INFO" "Временно открыт 80/tcp для Let's Encrypt HTTP-01."
}

ufw_remove_http01_temporary_rule() {
    [[ "${AWG_CERTBOT_UFW80_ADDED:-0}" == "1" ]] || return 0
    AWG_CERTBOT_UFW80_ADDED=0
    export AWG_CERTBOT_UFW80_ADDED
    ufw delete allow 80/tcp >/dev/null 2>&1 || true
    ufw reload >/dev/null 2>&1 || true
    log_msg "INFO" "Временное правило 80/tcp удалено."
}

resolve_domain_ipv4() {
    local domain="$1"
    if command -v getent >/dev/null 2>&1; then
        getent ahostsv4 "$domain" 2>/dev/null | awk '/^[0-9]+\./ {print $1; exit}'
        return 0
    fi
    if command -v dig >/dev/null 2>&1; then
        dig +short A "$domain" 2>/dev/null | awk '/^[0-9]+\./ {print $1; exit}'
        return 0
    fi
    return 0
}

preflight_letsencrypt_domain() {
    local domain="$1" resolved endpoint="${AWG_ENDPOINT:-}" confirm
    log_warn "HTTP-01 требует входящий TCP/80 в UFW и provider firewall/security group."
    resolved="$(resolve_domain_ipv4 "$domain")"
    if [[ -z "$resolved" ]]; then
        log_warn "Не удалось проверить DNS A-record для $domain. Убедитесь, что домен указывает на сервер."
        return 0
    fi
    if [[ "$endpoint" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && "$resolved" != "$endpoint" ]]; then
        log_warn "DNS $domain resolves to $resolved, но endpoint сервера: $endpoint."
        if [[ "$AUTO_YES" -ne 0 ]]; then
            return 1
        fi
        read -rp "Продолжить попытку Let's Encrypt несмотря на DNS mismatch? [y/N]: " confirm < /dev/tty
        [[ "$confirm" =~ ^[Yy]$ ]]
        return $?
    fi
    log "DNS preflight: $domain -> $resolved"
}

check_http01_port_available() {
    if ss -tulpen 2>/dev/null | awk '{print $5}' | grep -Eq '(^|:)80$'; then
        log_error "Port 80 is already in use; standalone certbot cannot run. Stop the service or use custom/self-signed cert."
        return 1
    fi
}

classify_certbot_failure() {
    local log_file="$1"
    if grep -Eqi 'too many certificates|rate limit' "$log_file" 2>/dev/null; then
        printf 'rate_limit\n'
    elif grep -Eqi 'Timeout during connect|likely firewall problem' "$log_file" 2>/dev/null; then
        printf 'http01_timeout\n'
    elif grep -Eqi 'DNS problem|NXDOMAIN' "$log_file" 2>/dev/null; then
        printf 'dns\n'
    else
        printf 'certbot_failed\n'
    fi
}

certbot_failure_reason_text() {
    case "$1" in
        rate_limit) printf "Let's Encrypt rate limit for this domain/provider" ;;
        http01_timeout) printf "HTTP-01 timeout; check inbound TCP/80 in UFW and provider firewall/security group" ;;
        dns) printf "DNS problem; domain does not resolve correctly" ;;
        port_80_busy) printf "Port 80 is already in use on this server" ;;
        ufw_http01_failed) printf "Could not open temporary UFW 80/tcp rule" ;;
        dns_mismatch) printf "Domain does not resolve to the configured endpoint" ;;
        *) printf "certbot failed" ;;
    esac
}

handle_letsencrypt_failure() {
    local web_dir="$1" domain="$2" reason="$3" choice domain_input
    AWG_WEB_CERT_ATTEMPTED_MODE="${AWG_WEB_CERT_ATTEMPTED_MODE:-${AWG_WEB_CERT_MODE:-letsencrypt}}"
    AWG_WEB_CERT_FAILURE_REASON="$(certbot_failure_reason_text "$reason")"
    log_warn "Let's Encrypt не выпустил сертификат для ${domain}: ${AWG_WEB_CERT_FAILURE_REASON}."
    if [[ "${AWG_WEB_CERT_FALLBACK:-abort}" == "selfsigned" || "${AWG_CERT_FALLBACK_SELFSIGNED:-0}" == "1" ]]; then
        log_warn "VPN будет работать. Web Panel продолжит с self-signed HTTPS до настройки trusted cert."
        AWG_WEB_CERT_MODE="selfsigned"
        AWG_WEB_CERT_FALLBACK_USED="selfsigned"
        persist_web_cert_state
        deploy_web_tls "$web_dir"
        return 0
    fi
    if [[ "$AUTO_YES" -ne 0 ]]; then
        persist_web_cert_state
        die "Let's Encrypt issuance failed; trusted HTTPS не настроен. Для fallback задайте --web-cert-fallback=selfsigned или AWG_WEB_CERT_FALLBACK=selfsigned."
    fi
    echo ""
    echo "Let's Encrypt не выпустил сертификат для ${domain}."
    echo "Причина: ${AWG_WEB_CERT_FAILURE_REASON}"
    echo "Выберите:"
    echo "  1) Перейти на self-signed и продолжить"
    echo "  2) Ввести другой домен"
    echo "  3) Повторить certbot"
    echo "  4) Прервать установку"
    ask_choice choice "Ваш выбор [1]: " "1" "1 2 3 4"
    case "${choice:-1}" in
        1)
            log_warn "VPN будет работать. Web Panel продолжит с self-signed HTTPS до настройки trusted cert."
            AWG_WEB_CERT_MODE="selfsigned"
            AWG_WEB_CERT_FALLBACK_USED="selfsigned"
            persist_web_cert_state
            deploy_web_tls "$web_dir"
            ;;
        2)
            ask_domain domain_input "Введите новый домен Web Panel: "
            AWG_WEB_CERT_MODE="letsencrypt"
            AWG_WEB_DOMAIN="$domain_input"
            deploy_web_tls "$web_dir"
            ;;
        3)
            deploy_web_tls "$web_dir"
            ;;
        *) die "Let's Encrypt issuance failed; trusted HTTPS не настроен." ;;
    esac
}

deploy_web_tls() {
    local web_dir="$1" mode="${AWG_WEB_CERT_MODE:-selfsigned}" domain="${AWG_WEB_DOMAIN:-}"
    case "$mode" in
        selfsigned)
            if [[ ! -f "$web_dir/cert.pem" || ! -f "$web_dir/key.pem" ]]; then
                openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
                    -keyout "$web_dir/key.pem" -out "$web_dir/cert.pem" \
                    -subj "/CN=VPN Panel" >/dev/null 2>&1 || die "Ошибка генерации TLS сертификата"
            fi
            ;;
        custom)
            [[ -f "${AWG_WEB_CERT_FILE:-}" && -f "${AWG_WEB_KEY_FILE:-}" ]] || die "Custom TLS cert/key не найдены."
            install -m 644 "$AWG_WEB_CERT_FILE" "$web_dir/cert.pem" || die "Ошибка копирования custom cert"
            install -m 600 "$AWG_WEB_KEY_FILE" "$web_dir/key.pem" || die "Ошибка копирования custom key"
            ;;
        letsencrypt|ip-domain)
            AWG_WEB_CERT_ATTEMPTED_MODE="$mode"
            AWG_WEB_CERT_FAILURE_REASON=""
            AWG_WEB_CERT_FALLBACK_USED=""
            if [[ "$mode" == "ip-domain" ]]; then
                domain="$(web_ip_domain)" || die "ip-domain требует IPv4 AWG_ENDPOINT."
                AWG_WEB_DOMAIN="$domain"
            fi
            [[ -n "$domain" ]] || die "Let's Encrypt требует domain."
            log_warn "Let's Encrypt standalone требует временно доступный port 80/tcp и DNS ${domain} → endpoint."
            preflight_letsencrypt_domain "$domain" || { handle_letsencrypt_failure "$web_dir" "$domain" "dns_mismatch"; return 0; }
            check_http01_port_available || { handle_letsencrypt_failure "$web_dir" "$domain" "port_80_busy"; return 0; }
            install_packages certbot
            local certbot_account_args=()
            if [[ -n "${AWG_WEB_LE_EMAIL:-}" ]]; then
                certbot_account_args=(--email "$AWG_WEB_LE_EMAIL")
            else
                certbot_account_args=(--register-unsafely-without-email)
            fi
            ufw_allow_http01_temporarily || { handle_letsencrypt_failure "$web_dir" "$domain" "ufw_http01_failed"; return 0; }
            local certbot_log certbot_rc failure_class
            certbot_log="$(mktemp /tmp/awg-certbot-XXXXXX.log)" || die "Ошибка mktemp certbot log."
            _install_temp_files+=("$certbot_log")
            certbot certonly --standalone --non-interactive --agree-tos "${certbot_account_args[@]}" \
                -d "$domain" --deploy-hook "systemctl restart awg-web" >"$certbot_log" 2>&1
            certbot_rc=$?
            ufw_remove_http01_temporary_rule
            if [[ "$certbot_rc" -ne 0 ]]; then
                failure_class="$(classify_certbot_failure "$certbot_log")"
                if [[ "$VERBOSE" -eq 1 ]]; then
                    while IFS= read -r line; do log_debug "certbot: $line"; done < "$certbot_log"
                fi
                handle_letsencrypt_failure "$web_dir" "$domain" "$failure_class"
                return 0
            fi
            install -m 644 "/etc/letsencrypt/live/${domain}/fullchain.pem" "$web_dir/cert.pem" || die "Ошибка установки fullchain.pem"
            install -m 600 "/etc/letsencrypt/live/${domain}/privkey.pem" "$web_dir/key.pem" || die "Ошибка установки privkey.pem"
            AWG_WEB_CERT_FAILURE_REASON=""
            AWG_WEB_CERT_FALLBACK_USED=""
            persist_web_cert_state
            ;;
    esac
    chmod 600 "$web_dir/key.pem"
    chmod 644 "$web_dir/cert.pem"
    persist_web_cert_state
}

deploy_web_panel() {
    [[ "${AWG_WEB_ENABLED:-1}" -eq 1 ]] || { log "Веб-панель отключена (--disable-web)."; return 0; }
    log "Развёртывание веб-панели (fork delta)..."
    local web_dir="$AWG_DIR/web"
    mkdir -p "$web_dir" || die "Ошибка создания $web_dir"
    mkdir -p "$web_dir/vendor" || die "Ошибка создания $web_dir/vendor"
    chmod 755 "$web_dir" "$web_dir/vendor"

    if [[ ! -f "$web_dir/tokens.json" ]]; then
        local legacy_token="" super_token=""
        # auth_token — legacy-файл v5.13.0 fork delta; мигрируем его в tokens.json.
        if [[ -f "$web_dir/auth_token" ]]; then
            legacy_token=$(tr -d '[:space:]' < "$web_dir/auth_token" 2>/dev/null || true)
        fi
        if [[ -n "$legacy_token" ]]; then
            python3 - "$web_dir/tokens.json" "$legacy_token" <<'PY' || die "Ошибка миграции web tokens"
import hashlib, json, os, sys
path, token = sys.argv[1], sys.argv[2]
tmp = f"{path}.tmp.{os.getpid()}"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump({"super_token_hash": hashlib.sha256(token.encode()).hexdigest(), "users": {}}, fh, indent=2, sort_keys=True)
    fh.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
os.chmod(path, 0o600)
PY
            AWG_WEB_SUPER_TOKEN_ONCE="$legacy_token"
        else
            super_token=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
            python3 - "$web_dir/tokens.json" "$super_token" <<'PY' || die "Ошибка генерации web tokens"
import hashlib, json, os, sys
path, token = sys.argv[1], sys.argv[2]
tmp = f"{path}.tmp.{os.getpid()}"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump({"super_token_hash": hashlib.sha256(token.encode()).hexdigest(), "users": {}}, fh, indent=2, sort_keys=True)
    fh.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
os.chmod(path, 0o600)
PY
            AWG_WEB_SUPER_TOKEN_ONCE="$super_token"
        fi
    fi
    if [[ -z "${AWG_WEB_SUPER_TOKEN_ONCE:-}" ]]; then
        log_warn "Raw Web super token недоступен для install summary; выполняю safe reset-super для текущего fresh/resume install."
        AWG_WEB_SUPER_TOKEN_ONCE="$(python3 - "$web_dir/tokens.json" <<'PY'
import hashlib, json, os, re, secrets, sys
from pathlib import Path

path = Path(sys.argv[1])
data = {}
if path.exists():
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        data = {}
users = data.get("users") if isinstance(data, dict) else {}
if not isinstance(users, dict):
    users = {}
clean_users = {}
for key, value in users.items():
    if isinstance(key, str) and re.fullmatch(r"[0-9a-f]{64}", key):
        clean_users[key] = value if isinstance(value, dict) else {"name": "", "clients": value if isinstance(value, list) else []}
token = secrets.token_urlsafe(32)
tmp = path.with_name(path.name + f".tmp.{os.getpid()}")
tmp.write_text(json.dumps({"super_token_hash": hashlib.sha256(token.encode()).hexdigest(), "users": clean_users}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
os.chmod(path, 0o600)
print(token)
PY
)" || die "Ошибка reset Web super token"
    fi
    if [[ -n "${AWG_WEB_SUPER_TOKEN_ONCE:-}" ]]; then
        python3 - "$web_dir/tokens.json" "$AWG_WEB_SUPER_TOKEN_ONCE" <<'PY' || die "Сгенерированный Web super token не проходит проверку"
import hashlib, hmac, json, sys
path, token = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
stored = data.get("super_token_hash", "")
actual = hashlib.sha256(token.encode()).hexdigest()
if not hmac.compare_digest(stored, actual):
    raise SystemExit(1)
PY
    fi

    deploy_web_tls "$web_dir"

    local asset
    for asset in server.py index.html style.css app.js awg_i1.js favicon.svg vendor/tailwindcss.js vendor/apexcharts.min.js; do
        _deploy_asset "web/${asset}" "$web_dir/$asset" 644
    done
    chmod 755 "$web_dir" "$web_dir/vendor"
    chmod 600 "$web_dir/key.pem" "$web_dir/tokens.json" 2>/dev/null || true
    chmod 644 "$web_dir/cert.pem" 2>/dev/null || true

    validate_safe_abs_path "$AWG_DIR" || die "Web Panel: unsafe AWG_DIR path"
    validate_safe_abs_path "$SERVER_CONF_FILE" || die "Web Panel: unsafe SERVER_CONF_FILE path"
    validate_safe_abs_path "$web_dir" || die "Web Panel: unsafe web directory path"
    validate_safe_abs_path "$web_dir/server.py" || die "Web Panel: unsafe server.py path"
    validate_no_control_chars "${AWG_WEB_BIND:-}" || die "Web Panel: unsafe bind value"
    validate_no_control_chars "${AWG_WEB_PORT:-}" || die "Web Panel: unsafe port value"
    validate_no_control_chars "${AWG_WEB_DOMAIN:-}" || die "Web Panel: unsafe domain value"
    validate_no_control_chars "${AWG_ENDPOINT:-}" || die "Web Panel: unsafe endpoint value"
    local web_server_unit
    web_server_unit="$(systemd_abs_path_value "$web_dir/server.py")" || die "Некорректный web/server.py path"

    if [[ "${AWG_WEB_BIND:-}" == "0.0.0.0" || "${AWG_WEB_BIND:-}" == "::" ]]; then
        log_warn "Web Panel слушает публичный bind ${AWG_WEB_BIND}:${AWG_WEB_PORT:-8443}. Python stdlib HTTP server подходит для лёгкой админ-панели, но слабее nginx/caddy на публичном edge."
        log_warn "Рекомендуется VPN-only bind 10.9.9.1, localhost+SSH tunnel или reverse proxy с TLS, timeouts и connection limits."
    fi

    {
        cat <<EOF
[Unit]
Description=VPN Web Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EOF
        systemd_env_line AWG_DIR "$AWG_DIR"
        systemd_env_line SERVER_CONF_FILE "$SERVER_CONF_FILE"
        systemd_env_line AWG_WEB_BIND "${AWG_WEB_BIND:-}"
        systemd_env_line AWG_WEB_PORT "${AWG_WEB_PORT:-}"
        systemd_env_line AWG_WEB_DOMAIN "${AWG_WEB_DOMAIN:-}"
        systemd_env_line AWG_ENDPOINT "${AWG_ENDPOINT:-}"
        cat <<EOF
ExecStart=/usr/bin/python3 ${web_server_unit}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    } > /etc/systemd/system/awg-web.service
    chmod 644 /etc/systemd/system/awg-web.service
    systemctl daemon-reload
    systemctl enable awg-web.service 2>/dev/null || log_warn "Не удалось enable awg-web.service"
    log "Веб-панель развёрнута."
    if [[ -n "${AWG_WEB_SUPER_TOKEN_ONCE:-}" ]]; then
        log "Web super token: generated; raw value printed to console and INSTALL_SUMMARY only."
        print_secret_console_only "Web super token: ${AWG_WEB_SUPER_TOKEN_ONCE}"
    else
        log "Web tokens: $web_dir/tokens.json (для сброса: manage web token reset-super)"
    fi
}

# ==============================================================================
# ШАГ 6: Генерация конфигураций (нативная, без awgcfg.py)
# ==============================================================================

configs_ready_for_step6_resume() {
    [[ -f "$SERVER_CONF_FILE" ]] || return 1
    [[ -f "$AWG_DIR/my_phone.conf" && -f "$AWG_DIR/my_laptop.conf" ]] || return 1
    grep -qxF "#_Name = my_phone" "$SERVER_CONF_FILE" 2>/dev/null || return 1
    grep -qxF "#_Name = my_laptop" "$SERVER_CONF_FILE" 2>/dev/null || return 1
}

step6_generate_configs() {
    update_state 6
    log "### ШАГ 6: Генерация конфигураций AWG 2.0 ###"
    cd "$AWG_DIR" || die "Ошибка cd $AWG_DIR"

    # Подключаем общую библиотеку
    if [[ ! -f "$COMMON_SCRIPT_PATH" ]]; then
        die "awg_common.sh не найден. Шаг 5 не выполнен?"
    fi
    # shellcheck source=/dev/null
    source "$COMMON_SCRIPT_PATH"

    # Создаём директорию для ключей
    mkdir -p "$KEYS_DIR" || die "Ошибка создания $KEYS_DIR"

    if [[ "$FORCE_REINSTALL" -ne 1 && "$CLI_UPGRADE_IPV6" -ne 1 ]] && configs_ready_for_step6_resume; then
        log "Конфиги AWG и дефолтные клиенты уже созданы; resume step 6 продолжит web/cert deploy без пересоздания клиентов."
        validate_awg_config || log_warn "Валидация конфига выявила проблемы."
        generate_firewall_scripts || log_warn "Не удалось обновить firewall/P2P hook-скрипты."
        setup_ndppd_config
        deploy_web_panel
        secure_files
        log "Шаг 6 завершен."
        update_state 7
        return 0
    fi

    # Генерация серверных ключей (если ещё нет)
    if [[ ! -f "$AWG_DIR/server_private.key" ]]; then
        log "Генерация серверных ключей..."
        generate_server_keys || die "Ошибка генерации серверных ключей."
    else
        log "Серверные ключи уже существуют."
    fi

    # Бэкап существующего серверного конфига ДО перезаписи
    if [[ -f "$SERVER_CONF_FILE" ]]; then
        local s_bak
        s_bak="${SERVER_CONF_FILE}.bak-$(date +%F_%H%M%S)"
        cp "$SERVER_CONF_FILE" "$s_bak" || log_warn "Ошибка бэкапа $s_bak"
        log "Бэкап серверного конфига: $s_bak"
    fi

    # Создание серверного конфига AWG 2.0
    log "Создание серверного конфига..."
    render_server_config || die "Ошибка создания серверного конфига."

    # Восстановление существующих [Peer] блоков из бэкапа (кроме дефолтных)
    if [[ -n "${s_bak:-}" && -f "$s_bak" ]]; then
        local restored_peers
        restored_peers=$(awk '
            /^\[Peer\]/ { buf=$0"\n"; in_peer=1; skip=0; next }
            in_peer && /^\[/ { if (!skip) printf "%s\n", buf; buf=""; in_peer=0; next }
            in_peer { buf=buf $0"\n"; if ($0 ~ /^#_Name = (my_phone|my_laptop)$/) skip=1; next }
            END { if (in_peer && !skip) printf "%s", buf }
        ' "$s_bak")
        if [[ -n "$restored_peers" ]]; then
            printf '\n%s' "$restored_peers" >> "$SERVER_CONF_FILE"
            log "Существующие пиры восстановлены из бэкапа."
        fi
    fi

    # Генерация клиентов по умолчанию
    log "Создание клиентов по умолчанию..."
    local client_name
    for client_name in my_phone my_laptop; do
        if grep -qxF "#_Name = ${client_name}" "$SERVER_CONF_FILE" 2>/dev/null; then
            log "Клиент '$client_name' уже существует."
        else
            log "Создание клиента '$client_name'..."
            generate_client "$client_name" || log_warn "Ошибка создания клиента '$client_name'"
        fi
    done

    if [[ "$CLI_UPGRADE_IPV6" -eq 1 ]]; then
        log "Миграция существующих клиентов на IPv6/P2P metadata..."
        upgrade_existing_peers_ipv6_p2p 1 1 || log_warn "Миграция peer metadata завершилась с ошибкой."
        local upgrade_clients cname
        upgrade_clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //') || upgrade_clients=""
        while IFS= read -r cname; do
            [[ -n "$cname" ]] || continue
            regenerate_client "$cname" || log_warn "Не удалось перегенерировать '$cname' после IPv6 upgrade."
        done <<< "$upgrade_clients"
    fi

    # Валидация конфига
    validate_awg_config || log_warn "Валидация конфига выявила проблемы."
    generate_firewall_scripts || log_warn "Не удалось обновить firewall/P2P hook-скрипты."
    setup_ndppd_config
    deploy_web_panel

    # Установка прав доступа
    secure_files

    log "Конфигурационные файлы в $AWG_DIR:"
    ls -la "$AWG_DIR"/*.conf "$AWG_DIR"/*.png 2>/dev/null | while IFS= read -r line; do
        log "  $line"
    done

    log "Шаг 6 завершен."
    update_state 7
}

# ==============================================================================
# ШАГ 7: Запуск сервиса
# ==============================================================================

step7_start_service() {
    update_state 7
    log "### ШАГ 7: Запуск сервиса и настройка безопасности ###"

    log "Включение и запуск awg-quick@awg0..."
    if systemctl is-active --quiet awg-quick@awg0; then
        log "Сервис уже активен — перезапуск для применения конфигурации..."
        systemctl enable awg-quick@awg0 || log_warn "Не удалось enable awg-quick@awg0 — проверьте автозапуск вручную"
        systemctl restart awg-quick@awg0 || die "Ошибка restart awg-quick@awg0."
    else
        systemctl enable --now awg-quick@awg0 || die "Ошибка enable --now."
    fi
    log "Сервис включен и запущен."

    if [[ "${AWG_WEB_ENABLED:-1}" -eq 1 ]]; then
        log "Запуск веб-панели awg-web.service..."
        systemctl restart awg-web.service || log_warn "Не удалось запустить awg-web.service"
    fi
    deploy_adguard_home

    log "Проверка статуса сервиса..."
    local _attempt
    for _attempt in 1 2 3 4 5; do
        sleep 1
        check_service_status 2>/dev/null && break
        [[ $_attempt -lt 5 ]] && log_debug "Ожидание запуска сервиса... (попытка $_attempt/5)"
    done
    check_service_status || die "Проверка статуса сервиса не пройдена."

    # Fail2Ban
    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        setup_fail2ban
    else
        log "Пропуск Fail2Ban (--no-tweaks)."
    fi

    log "Шаг 7 успешно завершен."
    update_state 99
}

# ==============================================================================
# ШАГ 99: Завершение
# ==============================================================================

format_https_url() {
    local host="$1" port="${2:-443}"
    if [[ -z "$host" || "$host" == "not exposed" ]]; then
        printf 'not exposed\n'
        return 0
    fi
    if [[ "$host" == *:* && "$host" != \[* ]]; then
        host="[$host]"
    fi
    if [[ "$port" == "443" ]]; then
        printf 'https://%s/\n' "$host"
    else
        printf 'https://%s:%s/\n' "$host" "$port"
    fi
}

compute_web_public_url() {
    [[ "${AWG_WEB_ENABLED:-1}" -eq 1 ]] || { printf 'not exposed\n'; return 0; }
    [[ "${AWG_WEB_BIND:-}" == "0.0.0.0" || "${AWG_WEB_BIND:-}" == "::" ]] || { printf 'not exposed\n'; return 0; }
    format_https_url "${AWG_WEB_DOMAIN:-${AWG_ENDPOINT:-}}" "${AWG_WEB_PORT:-8443}"
}

compute_web_vpn_url() {
    [[ "${AWG_WEB_ENABLED:-1}" -eq 1 ]] || { printf 'not exposed\n'; return 0; }
    if [[ "${AWG_WEB_BIND:-}" == "0.0.0.0" || "${AWG_WEB_BIND:-}" == "::" || "${AWG_WEB_BIND:-}" == "127.0.0.1" || "${AWG_WEB_BIND:-}" == "::1" ]]; then
        printf 'not exposed\n'
    else
        format_https_url "${AWG_WEB_BIND:-${AWG_TUNNEL_SUBNET%/*}}" "${AWG_WEB_PORT:-8443}"
    fi
}

compute_web_local_url() {
    [[ "${AWG_WEB_ENABLED:-1}" -eq 1 ]] || { printf 'not exposed\n'; return 0; }
    if [[ "${AWG_WEB_BIND:-}" == "127.0.0.1" || "${AWG_WEB_BIND:-}" == "::1" ]]; then
        format_https_url "${AWG_WEB_BIND}" "${AWG_WEB_PORT:-8443}"
    else
        printf 'not exposed\n'
    fi
}

compute_trusted_https_status() {
    local cert_file="${AWG_DIR}/web/cert.pem"
    [[ "${AWG_WEB_ENABLED:-1}" -eq 1 ]] || { printf 'no\n'; return 0; }
    [[ -f "$cert_file" ]] || { printf 'no\n'; return 0; }
    [[ "${AWG_WEB_CERT_FALLBACK_USED:-}" == "selfsigned" ]] && { printf 'no\n'; return 0; }
    case "${AWG_WEB_CERT_MODE:-selfsigned}" in
        letsencrypt|ip-domain|custom) printf 'yes\n' ;;
        *) printf 'no\n' ;;
    esac
}

compute_cert_summary() {
    local trusted_https
    trusted_https="$(compute_trusted_https_status)"
    cat <<EOF
Certificate mode: ${AWG_WEB_CERT_MODE:-selfsigned}
Certificate provider: ${AWG_WEB_CERT_PROVIDER:-none}
Certificate attempted mode: ${AWG_WEB_CERT_ATTEMPTED_MODE:-none}
Certificate fallback: ${AWG_WEB_CERT_FALLBACK_USED:-none}
Certificate failure reason: ${AWG_WEB_CERT_FAILURE_REASON:-none}
Trusted HTTPS: ${trusted_https}
EOF
}

route_mode_label() {
    case "${ALLOWED_IPS_MODE:-}" in
        1) echo "route-all" ;;
        2) echo "amnezia-routes" ;;
        3) echo "custom" ;;
        *) echo "${ALLOWED_IPS_MODE:-unknown}" ;;
    esac
}

server_ipv6_addr_for_summary() {
    [[ "${AWG_IPV6_ENABLED:-0}" -eq 1 && -n "${AWG_IPV6_SUBNET:-}" ]] || return 0
    python3 - "$AWG_IPV6_SUBNET" <<'PY' 2>/dev/null || true
import ipaddress
import sys
net = ipaddress.ip_network(sys.argv[1], strict=False)
print(net.network_address + 1)
PY
}

adguard_allowed_clients_for_summary() {
    if ! python3 - "${AWG_TUNNEL_SUBNET:-10.9.9.1/24}" "${AWG_IPV6_ENABLED:-0}" "${AWG_IPV6_SUBNET:-}" <<'PY' 2>/dev/null; then
import ipaddress
import sys
v4 = ipaddress.ip_interface(sys.argv[1]).network
print(f"- {v4}")
if sys.argv[2] == "1" and sys.argv[3]:
    print(f"- {ipaddress.ip_network(sys.argv[3], strict=False)}")
PY
        echo "- 10.9.9.0/24"
        return 0
    fi
}

client_value_from_server_conf() {
    local client_name="$1" key="$2"
    [[ -f "$SERVER_CONF_FILE" ]] || return 0
    awk -v name="$client_name" -v key="$key" '
        $0 == "[Peer]" { in_peer=1; found=0; next }
        in_peer && $0 ~ /^#_Name[[:space:]]*=/ {
            value=$0; sub(/^#_Name[[:space:]]*=[[:space:]]*/, "", value)
            found=(value == name)
            next
        }
        in_peer && found && key == "AllowedIPs" && $0 ~ /^AllowedIPs[[:space:]]*=/ {
            value=$0; sub(/^AllowedIPs[[:space:]]*=[[:space:]]*/, "", value); print value; exit
        }
        in_peer && found && key == "P2P" && $0 ~ /^#_P2PPorts(_Disabled)?[[:space:]]*=/ {
            value=$0; sub(/^[^=]+=[[:space:]]*/, "", value); print value; exit
        }
    ' "$SERVER_CONF_FILE"
}

client_ipv4_for_summary() {
    local allowed
    allowed="$(client_value_from_server_conf "$1" "AllowedIPs")"
    printf '%s\n' "$allowed" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/32' | head -n 1 | sed 's#/32##'
}

client_ipv6_for_summary() {
    local allowed
    allowed="$(client_value_from_server_conf "$1" "AllowedIPs")"
    printf '%s\n' "$allowed" | grep -oE '([0-9A-Fa-f:]+)/128' | head -n 1 | sed 's#/128##'
}

client_file_status() {
    local path="$1"
    if [[ -f "$path" ]]; then
        printf '%s\n' "$path"
    else
        printf 'not generated\n'
    fi
}

write_client_files_summary() {
    local out_file="$1" client_name ipv4 ipv6 p2p
    if [[ ! -f "$SERVER_CONF_FILE" ]] || ! grep -q '^#_Name = ' "$SERVER_CONF_FILE" 2>/dev/null; then
        printf -- "- none\n" >> "$out_file"
        return 0
    fi
    grep '^#_Name = ' "$SERVER_CONF_FILE" 2>/dev/null | sed 's/^#_Name = //' | while IFS= read -r client_name; do
        [[ -n "$client_name" ]] || continue
        ipv4="$(client_ipv4_for_summary "$client_name")"
        ipv6="$(client_ipv6_for_summary "$client_name")"
        p2p="$(client_value_from_server_conf "$client_name" "P2P")"
        {
            printf -- "- %s:\n" "$client_name"
            printf '    config: %s\n' "$(client_file_status "$AWG_DIR/${client_name}.conf")"
            printf '    qr: %s\n' "$(client_file_status "$AWG_DIR/${client_name}.png")"
            printf '    vpnuri: %s\n' "$(client_file_status "$AWG_DIR/${client_name}.vpnuri")"
            printf '    vpnuri qr: %s\n' "$(client_file_status "$AWG_DIR/${client_name}.vpnuri.png")"
            printf '    IPv4: %s\n' "${ipv4:-none}"
            printf '    IPv6: %s\n' "${ipv6:-none}"
            printf '    P2P ports: %s\n' "${p2p:-none}"
        } >> "$out_file"
    done
}

print_client_files_console() {
    local client_name ipv4 ipv6 p2p
    log "КЛИЕНТЫ:"
    if [[ ! -f "$SERVER_CONF_FILE" ]] || ! grep -q '^#_Name = ' "$SERVER_CONF_FILE" 2>/dev/null; then
        log "  none"
        return 0
    fi
    grep '^#_Name = ' "$SERVER_CONF_FILE" 2>/dev/null | sed 's/^#_Name = //' | while IFS= read -r client_name; do
        [[ -n "$client_name" ]] || continue
        ipv4="$(client_ipv4_for_summary "$client_name")"
        ipv6="$(client_ipv6_for_summary "$client_name")"
        p2p="$(client_value_from_server_conf "$client_name" "P2P")"
        log "  ${client_name}"
        log "    .conf:       $(client_file_status "$AWG_DIR/${client_name}.conf")"
        log "    QR:          $(client_file_status "$AWG_DIR/${client_name}.png")"
        log "    vpn://:      $(client_file_status "$AWG_DIR/${client_name}.vpnuri")"
        log "    vpn:// QR:   $(client_file_status "$AWG_DIR/${client_name}.vpnuri.png")"
        log "    IPv4:        ${ipv4:-none}"
        log "    IPv6:        ${ipv6:-none}"
        log "    P2P ports:   ${p2p:-none}"
    done
}

print_summary_notice_block() {
    local path="$AWG_DIR/INSTALL_SUMMARY.txt"
    if [[ "$NO_COLOR" -eq 0 ]]; then
        printf '\033[1;33m'
    fi
    log "╔════════════════════════════════════════════════════════════╗"
    log "║  ВАЖНО: ВСЯ ИНФОРМАЦИЯ ДЛЯ ДОСТУПА СОХРАНЕНА В ФАЙЛЕ      ║"
    log "║                                                            ║"
    log "║  ${path}                            ║"
    log "║                                                            ║"
    log "║  Внутри: ссылки, Web token, AdGuard пароль, конфиги, QR.   ║"
    log "║  Файл содержит секреты. Права доступа: 0600.               ║"
    log "╚════════════════════════════════════════════════════════════╝"
    if [[ "$NO_COLOR" -eq 0 ]]; then
        printf '\033[0m'
    fi
}

write_install_summary() {
    local summary_path="$AWG_DIR/INSTALL_SUMMARY.txt"
    local tmp_path="$AWG_DIR/.INSTALL_SUMMARY.txt.tmp.$$"
    local timestamp generated route_label server_v6 web_host trusted_https cert_summary domain_only_access
    local web_public_url web_vpn_url web_local_url web_warning web_extra_url import_example
    local ag_password_display state_display ag_dns_listen ag_allowed_clients ufw_state firewall_resp

    mkdir -p "$AWG_DIR" || return 0
    chmod 700 "$AWG_DIR" 2>/dev/null || true
    generated="$(date '+%Y-%m-%d %H:%M:%S')"
    timestamp="$(date '+%Y%m%d-%H%M%S')"
    route_label="$(route_mode_label)"
    server_v6="$(server_ipv6_addr_for_summary)"
    web_host="${AWG_ENDPOINT:-server}"
    trusted_https="$(compute_trusted_https_status)"
    cert_summary="$(compute_cert_summary)"
    domain_only_access="no"
    if [[ "${AWG_WEB_ENABLED:-1}" -eq 1 && -n "${AWG_WEB_DOMAIN:-}" && ( "${AWG_WEB_BIND:-}" == "0.0.0.0" || "${AWG_WEB_BIND:-}" == "::" ) ]]; then
        domain_only_access="yes"
    fi
    web_public_url="$(compute_web_public_url)"
    web_vpn_url="$(compute_web_vpn_url)"
    web_local_url="$(compute_web_local_url)"
    web_warning="none"
    web_extra_url="none"
    import_example="${web_public_url%/}/import/my_phone/<token>"
    [[ "$web_public_url" == "not exposed" ]] && import_example="${web_vpn_url%/}/import/my_phone/<token>"
    ag_password_display="${AG_PASSWORD:-not available after initial generation; reset in AdGuard if needed}"
    ag_dns_listen="${AWG_TUNNEL_SUBNET%/*}:53"
    ag_allowed_clients="$(adguard_allowed_clients_for_summary)"
    state_display="$STATE_FILE"
    ufw_state="enabled/managed"
    firewall_resp="installer/UFW"
    if [[ "${AWG_DISABLE_UFW:-0}" == "1" ]]; then
        ufw_state="disabled by user"
        firewall_resp="external/manual"
    fi
    [[ -f "$STATE_FILE" ]] || state_display="$STATE_FILE (not present after successful cleanup)"

    if [[ "${AWG_WEB_ENABLED:-1}" -eq 1 && ( "${AWG_WEB_BIND:-}" == "0.0.0.0" || "${AWG_WEB_BIND:-}" == "::" ) ]]; then
        AWG_WEB_PUBLIC_URL="$web_public_url"
        web_warning="WARNING: Web Panel is publicly exposed"
    elif [[ "${AWG_WEB_ENABLED:-1}" -eq 1 && ( "${AWG_WEB_BIND:-}" == "127.0.0.1" || "${AWG_WEB_BIND:-}" == "::1" ) ]]; then
        web_extra_url="SSH tunnel: ssh -L ${AWG_WEB_PORT:-8443}:${AWG_WEB_BIND}:${AWG_WEB_PORT:-8443} root@${web_host}"
        import_example="${web_local_url%/}/import/my_phone/<token>"
    fi

    if [[ -f "$summary_path" ]]; then
        cp -p "$summary_path" "${summary_path}.bak.${timestamp}" 2>/dev/null || cp "$summary_path" "${summary_path}.bak.${timestamp}" 2>/dev/null || true
        chmod 600 "${summary_path}.bak.${timestamp}" 2>/dev/null || true
        chown root:root "${summary_path}.bak.${timestamp}" 2>/dev/null || true
    fi

    cat > "$tmp_path" <<EOF
============================================================
AmneziaWG Installer Summary
Generated: ${generated}
Server name: ${AWG_SERVER_NAME:-MyVPN}
Installer version: ${SCRIPT_VERSION}
Repository: ${AWG_REPO}
Permissions: 0600
============================================================

============================================================
IMPORTANT ACCESS INFO / SECRETS
============================================================

WEB PANEL
  Public URL: ${web_public_url}
  VPN URL: ${web_vpn_url}
  Local URL: ${web_local_url}
  Domain: ${AWG_WEB_DOMAIN:-none}
  Domain-only access: ${domain_only_access}
  IP access: $(if [[ "$domain_only_access" == "yes" ]]; then echo "blocked by Host header validation"; else echo "allowed for configured bind mode"; fi)
  Super token: ${AWG_WEB_SUPER_TOKEN_ONCE}
  Token file: ${AWG_DIR}/web/tokens.json
  Reset command: sudo bash ${MANAGE_SCRIPT_PATH} web token reset-super
  Trusted HTTPS: ${trusted_https}
  Certificate fallback: ${AWG_WEB_CERT_FALLBACK_USED:-none}
  Certificate failure reason: ${AWG_WEB_CERT_FAILURE_REASON:-none}

ADGUARD HOME
  UI URL: http://${AWG_TUNNEL_SUBNET%/*}:${AWG_ADGUARD_PORT:-3000}
  Login: ${AG_USERNAME:-admin}
  Password: ${ag_password_display}

CLIENT CONFIGS
EOF
    write_client_files_summary "$tmp_path"
    cat >> "$tmp_path" <<EOF

FILES
  Summary: ${summary_path}
  Install log: ${LOG_FILE}

[Web Panel]
Enabled: $(if [[ "${AWG_WEB_ENABLED:-1}" -eq 1 ]]; then echo "yes"; else echo "no"; fi)
Bind: ${AWG_WEB_BIND:-none}
Port: ${AWG_WEB_PORT:-8443}
Public URL: ${web_public_url}
VPN URL: ${web_vpn_url}
Local URL: ${web_local_url}
Access note: ${web_extra_url}
Exposure warning: ${web_warning}
Super token: ${AWG_WEB_SUPER_TOKEN_ONCE:-not available here; reset with manage web token reset-super}
Token file: ${AWG_DIR}/web/tokens.json
Domain-only access: ${domain_only_access}
IP access: $(if [[ "$domain_only_access" == "yes" ]]; then echo "blocked by Host header validation"; else echo "allowed for configured bind mode"; fi)
TLS cert: ${AWG_DIR}/web/cert.pem
TLS key: ${AWG_DIR}/web/key.pem
${cert_summary}
Domain: ${AWG_WEB_DOMAIN:-none}
Certificate file: ${AWG_DIR}/web/cert.pem
Private key file: ${AWG_DIR}/web/key.pem
Renewal note: Let's Encrypt modes install certbot renewal; deploy hook restarts awg-web.
Retry trusted cert: use your own domain and rerun the installer with --web-cert-mode=letsencrypt --web-domain=vpn.example.com, or install a custom certificate.
TLS warning: $(if [[ "${AWG_WEB_CERT_MODE:-selfsigned}" == "selfsigned" && ( "${AWG_WEB_BIND:-}" == "0.0.0.0" || "${AWG_WEB_BIND:-}" == "::" ) ]]; then echo "public self-signed TLS may be rejected by browsers/WG Tunnel"; else echo "none"; fi)

[AdGuard Home]
Enabled: $(if [[ "${AWG_ADGUARD_ENABLED:-0}" -eq 1 ]]; then echo "yes"; else echo "no"; fi)
Profile: curated
Service: AdGuardHome.service
Binary: ${AWG_ADGUARD_DIR:-/opt/AdGuardHome}/AdGuardHome
DNS listen: ${ag_dns_listen}
UI URL: http://${AWG_TUNNEL_SUBNET%/*}:${AWG_ADGUARD_PORT:-3000}
Upstream mode: parallel
Yandex DNS: disabled/not used
AliDNS: enabled
IPv6 bootstrap DNS: enabled
AAAA disabled: false
DNSSEC: true
Cache: 80 MiB, optimistic enabled
Filters enabled: 16
Filters disabled but present: 22
NoADS_RU: present, disabled
Russian regional lists: present, disabled
Windows telemetry blocking: enabled
Affiliate allowlist: enabled
Allowed clients:
${ag_allowed_clients}
Admin login: ${AG_USERNAME:-admin}
Admin password: ${ag_password_display}
Config file: ${AWG_ADGUARD_DIR:-/opt/AdGuardHome}/AdGuardHome.yaml

[Network]
Endpoint: ${AWG_ENDPOINT:-not set}
VPN UDP port: ${AWG_PORT}
Tunnel IPv4 subnet: ${AWG_TUNNEL_SUBNET}
Route mode: ${route_label}
AllowedIPs mode: ${ALLOWED_IPS_MODE}
AllowedIPs: ${ALLOWED_IPS}
UFW: ${ufw_state}
Firewall responsibility: ${firewall_resp}

[IPv6]
IPv6 enabled: $(if [[ "${AWG_IPV6_ENABLED:-0}" -eq 1 ]]; then echo "yes"; else echo "no"; fi)
IPv6 mode: ${AWG_IPV6_MODE:-legacy}
IPv6 requested mode: ${AWG_IPV6_MODE_REQUESTED:-${AWG_IPV6_MODE:-legacy}}
IPv6 effective mode: ${AWG_IPV6_MODE_EFFECTIVE:-${AWG_IPV6_MODE:-legacy}}
IPv6 selection reason: ${AWG_IPV6_MODE_REASON:-none}
IPv6 client subnet: ${AWG_IPV6_SUBNET:-none}
Server tunnel IPv6: ${server_v6:-none}

[WG Tunnel URL Import]
Supported: yes
Endpoint pattern: ${import_example}
Example: ${import_example}
Notes:
- HTTPS only.
- Response is raw config text starting with [Interface].
- Links are token-protected and expire.
- Self-signed TLS may be rejected by some mobile apps.

[Clients]
Config directory: ${AWG_DIR}
Default clients:
EOF
    write_client_files_summary "$tmp_path"
    cat >> "$tmp_path" <<EOF

[AWG 2.0 Parameters]
Preset: ${AWG_PRESET:-default}
Jc: ${AWG_Jc}
Jmin: ${AWG_Jmin}
Jmax: ${AWG_Jmax}
S1: ${AWG_S1}
S2: ${AWG_S2}
S3: ${AWG_S3}
S4: ${AWG_S4}
H1: ${AWG_H1}
H2: ${AWG_H2}
H3: ${AWG_H3}
H4: ${AWG_H4}
I1: ${AWG_I1:-}

[WireSock]
Hints: ${AWG_WIRESOCK_HINTS:-off}
Id: ${AWG_WIRESOCK_ID:-none}
Ip: ${AWG_WIRESOCK_IP:-none}
Ib: ${AWG_WIRESOCK_IB:-none}

[P2P]
Base port: ${AWG_P2P_BASE_PORT}
Ports per client: ${AWG_P2P_PORTS_PER_CLIENT}
Fullcone NAT: $(if [[ "${AWG_FULLCONE_NAT:-0}" -eq 1 ]]; then echo "yes"; else echo "no"; fi)

[Files]
Server config: ${SERVER_CONF_FILE}
Manage script: ${MANAGE_SCRIPT_PATH}
Common script: ${COMMON_SCRIPT_PATH}
Install log: ${LOG_FILE}
Install state: ${state_display}

[Useful commands]
systemctl status awg-quick@awg0 --no-pager
systemctl status awg-web --no-pager
systemctl status AdGuardHome.service --no-pager
sudo bash ${MANAGE_SCRIPT_PATH} help
sudo bash ${MANAGE_SCRIPT_PATH} web token reset-super
sudo bash ${MANAGE_SCRIPT_PATH} add <client>
sudo bash ${MANAGE_SCRIPT_PATH} qr <client>
sudo bash ${MANAGE_SCRIPT_PATH} show <client>

[Security notes]
- This file contains secrets. Keep permissions 0600.
- Rotate Web token if this file was exposed.
- Change AdGuard password after first login.
- Public Web Panel bind 0.0.0.0 exposes HTTPS panel to the Internet.
============================================================
EOF
    chmod 600 "$tmp_path"
    chown root:root "$tmp_path" 2>/dev/null || true
    mv -f "$tmp_path" "$summary_path"
    chmod 600 "$summary_path"
    chown root:root "$summary_path" 2>/dev/null || true
}

step99_finish() {
    local web_public_url web_vpn_url web_local_url trusted_https
    web_public_url="$(compute_web_public_url)"
    web_vpn_url="$(compute_web_vpn_url)"
    web_local_url="$(compute_web_local_url)"
    trusted_https="$(compute_trusted_https_status)"
    log "### ЗАВЕРШЕНИЕ УСТАНОВКИ ###"
    log "============================================================"
    log "УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА"
    log "============================================================"
    log " "
    log "ГЛАВНОЕ:"
    if [[ "${AWG_WEB_ENABLED:-1}" -eq 1 ]]; then
        log "  Web Panel:"
        log "    Public URL: ${web_public_url}"
        [[ "$web_vpn_url" != "not exposed" ]] && log "    VPN URL: ${web_vpn_url}"
        [[ "$web_local_url" != "not exposed" ]] && log "    Local URL: ${web_local_url}"
        if [[ "${AWG_WEB_BIND:-}" == "127.0.0.1" || "${AWG_WEB_BIND:-}" == "::1" ]]; then
            log "    SSH tunnel: ssh -L ${AWG_WEB_PORT:-8443}:${AWG_WEB_BIND}:${AWG_WEB_PORT:-8443} root@${AWG_ENDPOINT:-server}"
        fi
        log "  Web bind: ${AWG_WEB_BIND:-none}:${AWG_WEB_PORT:-8443}"
        log "  Domain: ${AWG_WEB_DOMAIN:-none}"
        log "  Certificate mode: ${AWG_WEB_CERT_MODE:-selfsigned}"
        log "  Trusted HTTPS: ${trusted_https}"
        log "  Web token file: $AWG_DIR/web/tokens.json"
        if [[ -n "${AWG_WEB_SUPER_TOKEN_ONCE:-}" ]]; then
            log "  Web super token: generated; raw value printed to console and INSTALL_SUMMARY only."
            print_secret_console_only "  Web super token: ${AWG_WEB_SUPER_TOKEN_ONCE}"
        else
            log "  Reset super token:"
            log "    sudo bash $MANAGE_SCRIPT_PATH web token reset-super"
        fi
    fi
    if [[ "${AWG_ADGUARD_ENABLED:-0}" -eq 1 && -n "${AG_PASSWORD:-}" ]]; then
        log " "
        log "  AdGuard Home: http://${AWG_TUNNEL_SUBNET%/*}:${AWG_ADGUARD_PORT:-3000}"
        log "  AdGuard login: ${AG_USERNAME:-admin}"
        log "  AdGuard password: generated; raw value printed to console and INSTALL_SUMMARY only."
        print_secret_console_only "  AdGuard password: ${AG_PASSWORD}"
    fi
    log " "
    log "  VPN endpoint: ${AWG_ENDPOINT:-not set}:${AWG_PORT}"
    log "  Client configs/QR/vpnuri: $AWG_DIR"
    log " "
    print_client_files_console
    log " "
    log "ПОЛЕЗНЫЕ КОМАНДЫ:"
    log "  sudo bash $MANAGE_SCRIPT_PATH help   # Управление клиентами"
    log "  systemctl status awg-quick@awg0      # Статус VPN"
    log "  awg show                              # Статус AmneziaWG"
    log "  ufw status verbose                    # Статус Firewall"
    log " "
    log "ВАЖНО: Для подключения используйте клиент Amnezia VPN >= 4.8.12.7"
    log "       с поддержкой протокола AWG 2.0"
    log " "
    write_install_summary
    log "ВАЖНО:"
    print_summary_notice_block
    log " "
    cleanup_apt
    log " "

    # Финальные проверки
    if [[ -f "$CONFIG_FILE" ]]; then
        log "Файл настроек $CONFIG_FILE: OK"
    else
        log_error "Файл настроек $CONFIG_FILE ОТСУТСТВУЕТ!"
    fi

    # Удаление файла состояния
    log "Удаление файла состояния установки..."
    rm -f "$STATE_FILE" "${STATE_FILE}.lock" "$AWG_DIR/.boot_id_before_step2" || log_warn "Не удалось удалить $STATE_FILE"
    log "Установка полностью завершена. Лог: $LOG_FILE"
    log "=============================================================================="
}

# ==============================================================================
# Основной цикл выполнения
# ==============================================================================

if [[ "$HELP" -eq 1 ]]; then show_help; fi
if [[ "$UNINSTALL" -eq 1 ]]; then step_uninstall; fi
if [[ "$DIAGNOSTIC" -eq 1 ]]; then create_diagnostic_report; exit 0; fi
if [[ "$VERBOSE" -eq 1 ]]; then set -x; fi

# v5.13.0: idempotency-страж — если AmneziaWG уже установлен и работает,
# повторный запуск даром тратит ~20 минут (Step 1 ещё раз настраивает sysctl/swap/BBR,
# `apt-get upgrade` может подтянуть новое ядро и заставить пользователя
# заново перезагружаться, Step 7 рестартит awg-quick@awg0 — handshake
# отваливаются на несколько секунд). Серверные ключи, пиры и параметры
# обфускации сохраняются при повторе, но без явного opt-in это поведение
# выглядит как «тихая переустановка». Защищаемся явным флагом.
# Поднимает ENV AWG_FORCE_REINSTALL=1 ровно так же, как CLI-флаг.
if [[ "${AWG_FORCE_REINSTALL:-0}" == "1" ]]; then
    FORCE_REINSTALL=1
fi
if [[ "$FORCE_REINSTALL" -ne 1 && "$CLI_UPGRADE_IPV6" -ne 1 ]] && [[ -f "$SERVER_CONF_FILE" ]] \
   && systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
    log_error "AmneziaWG уже установлен и запущен."
    log_error "Чтобы переустановить — добавьте --force (или AWG_FORCE_REINSTALL=1)."
    log_error "ВНИМАНИЕ: переустановка снова прогонит шаги 1 (sysctl/swap/BBR) и 7 (рестарт сервиса),"
    log_error "          параметры обфускации (Jc/Jmin/Jmax/H1-H4/I1) сохранятся."
    log_error "Для управления клиентами:  sudo bash $MANAGE_SCRIPT_PATH help"
    log_error "Для полного удаления:      sudo bash $0 --uninstall"
    exit 0
fi

initialize_setup

while (( current_step < 99 )); do
    log "Выполнение шага $current_step..."
    case $current_step in
        1) step1_update_and_optimize ;;
        2) step2_install_amnezia ;;
        3) step3_check_module; current_step=4 ;;
        4) step4_setup_firewall; current_step=5 ;;
        5) step5_download_scripts; current_step=6 ;;
        6) step6_generate_configs; current_step=7 ;;
        7) step7_start_service; current_step=99 ;;
        *) die "Ошибка: Неизвестный шаг $current_step." ;;
    esac
done

if (( current_step == 99 )); then step99_finish; fi
exit 0
