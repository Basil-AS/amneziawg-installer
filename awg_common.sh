#!/bin/bash
# shellcheck disable=SC1003,SC2012,SC2015,SC2016,SC2004,SC2086,SC2317

# ==============================================================================
# Общая библиотека функций для AmneziaWG 2.0
# Автор: @bivlked
# Версия: 5.29.0-bas.5
# Дата: 2026-08-30
# Репозиторий: https://github.com/bivlked/amneziawg-installer
# ==============================================================================
#
# Этот файл содержит общие функции для генерации ключей, конфигураций,
# управления пирами и работы с AWG 2.0 параметрами.
# Предназначен для подключения через source из install и manage скриптов.
# ==============================================================================

# --- Константы (могут быть переопределены до source) ---
AWG_DIR="${AWG_DIR:-/root/awg}"
CONFIG_FILE="${CONFIG_FILE:-$AWG_DIR/awgsetup_cfg.init}"
SERVER_CONF_FILE="${SERVER_CONF_FILE:-/etc/amnezia/amneziawg/awg0.conf}"
KEYS_DIR="${KEYS_DIR:-$AWG_DIR/keys}"
AWG_HOSTS_FILE="${AWG_HOSTS_FILE:-/etc/hosts}"
AWG_PROFILE_SCRIPT_PATH="${AWG_PROFILE_SCRIPT_PATH:-$AWG_DIR/scripts/awg_profile.py}"

_awg_protocol_version() {
    case "${AWG_PROTOCOL_VERSION:-2.0}" in
        1.5|2.0|3.0|3.1) printf '%s' "${AWG_PROTOCOL_VERSION:-2.0}" ;;
        *) log_error "Unsupported AWG protocol version: ${AWG_PROTOCOL_VERSION:-}"; return 1 ;;
    esac
}

_awg_protocol_has_s34() {
    [[ "$(_awg_protocol_version)" != "1.5" ]]
}

_awg_protocol_has_cps() {
    [[ "$(_awg_protocol_version)" != "1.5" ]]
}

_awg31_render_extra_fields() {
    case "${AWG_PROTOCOL_VERSION:-2.0}" in 3.0|3.1) ;; *) return 0 ;; esac
    [[ -x "$AWG_PROFILE_SCRIPT_PATH" ]] || { log_error "AWG 3.x profile renderer is missing."; return 1; }
    [[ -f "$AWG_DIR/awg31-profile.json" ]] || { log_error "AWG 3.x profile is missing."; return 1; }
    python3 "$AWG_PROFILE_SCRIPT_PATH" render --input "$AWG_DIR/awg31-profile.json" \
        | grep -E '^(ContentPaddingAddition|HeaderProtectionKey|MaxHandshakeAttempts|KeepaliveTimeout|RejectAfterTime|RekeyAfterTime|RekeyTimeout|RandomTrailers|DisableCookies) = '
}

# Keep the validated JSON profile and the legacy AWG_* settings in lockstep.
# The profile is the source of truth for AWG 3.1-only fields, while the
# installer still persists J/S/H in awgsetup_cfg.init for older versions.
sync_awg31_profile_from_env() {
    case "${AWG_PROTOCOL_VERSION:-2.0}" in 3.0|3.1) ;; *) return 0 ;; esac
    [[ -f "$AWG_DIR/awg31-profile.json" ]] || return 1
    python3 - "$AWG_DIR/awg31-profile.json" <<'PY'
import json, os, sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
mapping = {
    "jc": "AWG_Jc", "jmin": "AWG_Jmin", "jmax": "AWG_Jmax",
    "s1": "AWG_S1", "s2": "AWG_S2", "s3": "AWG_S3", "s4": "AWG_S4",
    "h1": "AWG_H1", "h2": "AWG_H2", "h3": "AWG_H3", "h4": "AWG_H4",
}

for field, env_name in mapping.items():
    value = os.environ.get(env_name)
    if value is not None and value != "":
        data[field] = int(value) if value.isdigit() else value
data["protocolVersion"] = os.environ.get("AWG_PROTOCOL_VERSION", "3.1")
tmp = path.with_name(path.name + f".tmp.{os.getpid()}")
tmp.write_text(json.dumps(data, ensure_ascii=True, sort_keys=True) + "\n", encoding="utf-8")
tmp.chmod(0o600)
tmp.replace(path)
path.chmod(0o600)
PY
    python3 "$AWG_PROFILE_SCRIPT_PATH" validate --version "${AWG_PROTOCOL_VERSION}" --input "$AWG_DIR/awg31-profile.json" >/dev/null
}

awg_profile_status() {
    local version="${AWG_PROTOCOL_VERSION:-2.0}" profile="missing" capability="not_required"
    if [[ "$version" == "3.0" || "$version" == "3.1" ]]; then
        if [[ -f "$AWG_DIR/awg31-profile.json" ]] &&
           python3 "$AWG_PROFILE_SCRIPT_PATH" validate --version "$version" --input "$AWG_DIR/awg31-profile.json" >/dev/null 2>&1; then
            profile="valid"
        else
            profile="invalid_or_missing"
        fi
        if [[ -x "$AWG_DIR/scripts/probe-awg31.sh" ]] && "$AWG_DIR/scripts/probe-awg31.sh" >/dev/null 2>&1; then
            capability="confirmed"
        else
            capability="not_confirmed"
        fi
    fi
    printf 'protocol_version=%s\nprofile=%s\ncapability=%s\n' "$version" "$profile" "$capability"
}

# Версия библиотеки. manage-скрипт сверяет её со своей по MAJOR.MINOR после
# source и падает с понятной ошибкой, если awg_common.sh и manage разъехались
# (обновили один файл, забыли второй) - иначе рассинхрон всплывает как
# "command not found" в случайном месте. Бампается вместе с остальными версиями.
# shellcheck disable=SC2034  # используется в manage-скрипте после source
AWG_COMMON_VERSION="5.29.0-bas.5"

# --- Автоочистка временных файлов ---
# ВАЖНО: trap НЕ устанавливается здесь, чтобы не перезаписать trap вызывающего скрипта.
# Вызывающий скрипт должен вызвать _awg_cleanup() в своём обработчике EXIT.
_AWG_TEMP_FILES=()
# Файл-реестр temp-файлов: awg_mktemp часто вызывается через $(...) (subshell),
# где правка массива _AWG_TEMP_FILES теряется в родителе. Файл переживает
# subshell, поэтому _awg_cleanup надёжно удалит даже temp, созданный в
# подстановке команды (например прерванная запись конфига между mktemp и mv).
# $$ = PID вызывающего скрипта, стабилен для всех его subshell.
# Реестр лежит в $AWG_DIR (root-only 0700), а НЕ в общедоступном /tmp:
# предсказуемое имя в /tmp позволяло бы локальному пользователю заранее
# подложить файл со списком чужих путей, которые _awg_cleanup удалил бы от root.
_AWG_TEMP_REGISTRY="${AWG_DIR}/.awg_temp_registry.$$"

_awg_cleanup() {
    local f
    for f in "${_AWG_TEMP_FILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
    # Файловый кэш public IP (см. get_server_public_ip) - per-PID, подчищаем.
    rm -f "${AWG_DIR}/.public_ip.cache.$$" 2>/dev/null
    # Guard от symlink-подмены реестра: читаем только обычный файл.
    if [[ -n "${_AWG_TEMP_REGISTRY:-}" && -f "$_AWG_TEMP_REGISTRY" && ! -L "$_AWG_TEMP_REGISTRY" ]]; then
        while IFS= read -r f; do
            [[ -n "$f" && -f "$f" ]] && rm -f "$f"
        done < "$_AWG_TEMP_REGISTRY"
        rm -f "$_AWG_TEMP_REGISTRY"
    fi
}

# Обёртка mktemp с автоочисткой.
# Опциональный 1-й аргумент - целевой каталог: temp создаётся в нём же, где
# окажется итоговый файл, чтобы последующий mv был атомарным rename в пределах
# одной ФС, а не cross-fs copy+unlink (важно, когда /tmp смонтирован как tmpfs).
# Без аргумента поведение прежнее (/tmp или $TMPDIR) - обратная совместимость.
awg_mktemp() {
    local dir="${1:-}" f
    if [[ -n "$dir" ]]; then
        mkdir -p "$dir" 2>/dev/null
        f=$(mktemp -p "$dir") || return 1
    else
        f=$(mktemp) || return 1
    fi
    _AWG_TEMP_FILES+=("$f")
    # Дублируем путь в файл-реестр - он переживает subshell ($(awg_mktemp ...)),
    # в отличие от массива выше.
    [[ -n "${_AWG_TEMP_REGISTRY:-}" ]] && printf '%s\n' "$f" >> "$_AWG_TEMP_REGISTRY" 2>/dev/null
    echo "$f"
}

install_nginx_awg0_wait_dropin() {
    local iface="${1:-${AWG_NGINX_WAIT_IFACE:-awg0}}"
    local bind_ip="${2:-${AWG_NGINX_WAIT_IP:-${AWG_WEB_BIND:-}}}"
    [[ -n "$bind_ip" ]] || bind_ip="$(awg_ipv4_gateway)"
    local timeout="${3:-${AWG_NGINX_WAIT_TIMEOUT:-90}}"
    local systemd_dir="${AWG_SYSTEMD_DIR:-/etc/systemd/system}"
    local dropin_dir="${NGINX_SYSTEMD_DROPIN_DIR:-$systemd_dir/nginx.service.d}"
    local dropin_file="$dropin_dir/10-wait-awg0.conf"
    local tmp

    [[ "$iface" =~ ^[A-Za-z0-9_.:-]+$ ]] || { log_error "Некорректный VPN interface для nginx wait drop-in: $iface"; return 1; }
    _valid_ipv4 "$bind_ip" || { log_error "Некорректный IPv4 bind address для nginx wait drop-in: $bind_ip"; return 1; }
    [[ "$timeout" =~ ^[0-9]+$ && "$timeout" -ge 1 && "$timeout" -le 600 ]] || { log_error "Некорректный timeout для nginx wait drop-in: $timeout"; return 1; }

    mkdir -p "$dropin_dir" || { log_error "Ошибка создания $dropin_dir"; return 1; }
    tmp="$(mktemp "$dropin_dir/.10-wait-awg0.conf.XXXXXX")" || return 1
    _AWG_TEMP_FILES+=("$tmp")
    cat > "$tmp" <<EOF
[Unit]
After=network-online.target
Wants=network-online.target

[Service]
Restart=on-failure
RestartSec=5s
ExecStartPre=
ExecStartPre=/bin/sh -c 'for i in \$(seq 1 ${timeout}); do ip -4 addr show dev ${iface} 2>/dev/null | grep -q "inet ${bind_ip}/" && exit 0; sleep 1; done; echo "${iface} ${bind_ip} not ready"; exit 1'
ExecStartPre=/usr/sbin/nginx -t -q -g 'daemon on; master_process on;'
EOF
    chmod 644 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$dropin_file" || { rm -f "$tmp"; return 1; }
    if [[ -z "${AWG_SKIP_SYSTEMCTL:-}" ]]; then
        systemctl daemon-reload || { log_error "systemctl daemon-reload failed after nginx wait drop-in"; return 1; }
    fi
    log "nginx systemd drop-in installed: $dropin_file (wait ${iface} ${bind_ip}, ${timeout}s)"
}

# --- Заглушки для логирования (переопределяются вызывающим скриптом) ---
if ! declare -f log >/dev/null 2>&1; then
    log()       { echo "[INFO] $1"; }
    log_warn()  { echo "[WARN] $1" >&2; }
    log_error() { echo "[ERROR] $1" >&2; }
    log_debug() { echo "[DEBUG] $1"; }
fi

# ==============================================================================
# Утилиты
# ==============================================================================

# --- Валидаторы IP / CIDR (общие для install и manage) ---
# Проверяют не только форму, но и числовые диапазоны: октеты IPv4 0-255,
# префикс IPv4 0-32, IPv6 0-128. Без префикса адрес валиден (wireguard-tools
# трактует голый IPv4 как /32, IPv6 как /128 - host-route).

# _valid_ipv4 <addr> : ровно 4 октета, каждый 0-255 (10# защищает от трактовки
# ведущего нуля как восьмеричного числа в (( )) ).
_valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
        (( 10#$o <= 255 )) || return 1
    done
    return 0
}

# _valid_ipv6 <addr> : структурная проверка (не только charset). Допускает одну
# компрессию "::"; без неё требует ровно 8 групп по 1-4 hex; с ней - не более 7.
# Встроенный IPv4 (::ffff:1.2.3.4) намеренно не поддержан - в AllowedIPs туннеля
# не встречается, а точки уже отсекаются charset-проверкой.
_valid_ipv6() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    case "$ip" in
        *:::*)   return 1 ;;                     # три и более ":" подряд
        *::*::*) return 1 ;;                     # более одной "::"
    esac
    [[ "$ip" == :* && "$ip" != ::* ]] && return 1   # одиночное ведущее ":"
    [[ "$ip" == *: && "$ip" != *:: ]] && return 1   # одиночное хвостовое ":"
    local has_dcolon=0
    [[ "$ip" == *::* ]] && has_dcolon=1
    local IFS=':' parts=() p ngroups=0
    read -ra parts <<< "$ip"
    for p in "${parts[@]}"; do
        [[ -z "$p" ]] && continue                 # пустые поля от "::"
        [[ "$p" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        (( ngroups++ ))
    done
    if [[ $has_dcolon -eq 1 ]]; then
        (( ngroups <= 7 )) || return 1            # "::" заменяет >=1 группу
    else
        (( ngroups == 8 )) || return 1
    fi
    return 0
}

# _valid_cidr <token> : IPv4/IPv6 адрес с опциональным префиксом. Префикс, если
# задан, обязан быть числом в допустимом диапазоне (IPv4 0-32, IPv6 0-128).
# Пустой префикс после "/" (например "1.2.3.4/") отвергается.
_valid_cidr() {
    local tok="$1" addr prefix
    if [[ "$tok" == */* ]]; then
        addr="${tok%/*}"; prefix="${tok##*/}"
        [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    else
        addr="$tok"; prefix=""
    fi
    if _valid_ipv4 "$addr"; then
        [[ -z "$prefix" ]] && return 0
        (( 10#$prefix <= 32 )) || return 1
        return 0
    elif _valid_ipv6 "$addr"; then
        [[ -z "$prefix" ]] && return 0
        (( 10#$prefix <= 128 )) || return 1
        return 0
    fi
    return 1
}

# _valid_host_or_ipv4 <host> : для Endpoint - корректный IPv4 ИЛИ FQDN.
_valid_host_or_ipv4() {
    local host="$1"
    _valid_ipv4 "$host" && return 0
    [[ "$host" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]] || return 1
    # Полностью числовая последняя метка = не настоящий TLD (RFC 3696), а скорее
    # битый IPv4 (например "999.1.1.1"); отвергаем, чтобы не принять опечатку в IP.
    local last="${host##*.}"
    [[ "$last" =~ ^[0-9]+$ ]] && return 1
    return 0
}

# Порту из конфига нельзя доверять до проверки: и awgsetup_cfg.init, и ListenPort
# в живом awg0.conf правят руками, и там оказывается что угодно. Значение уходит
# в 'Endpoint = IP:PORT' клиентского .conf (add/regen), в JSON без кавычек
# ("number":abc не разбирается) и в арифметические сравнения (где bash выполняет
# подстановку команд из строки вида a[$(...)]) у check, и в regex правил UFW у
# diagnose. Функция, а не пара строк по месту: так её исполняет тест, а не копия
# логики.
_sanitize_port() {
    local p="${1:-}"
    # Пробелы по краям срезаю: 'AWG_PORT=39743 ' - обычный след ручной правки,
    # и это тот же самый порт. Раньше такой конфиг ронял проверку впустую.
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    # {1,5} отсекает переполнение 64-битной арифметики: длинная строка цифр
    # молча приземлилась бы внутрь допустимого диапазона. 10# снимает
    # восьмеричную трактовку значений с ведущим нулём (0070 иначе даст 56).
    if [[ "$p" =~ ^[0-9]{1,5}$ ]] && (( 10#$p >= 1 && 10#$p <= 65535 )); then
        printf '%s' "$((10#$p))"
    else
        printf '0'
    fi
}

# --- CIDR-арифметика (общая для аллокатора IPv4/IPv6) ---
# Чистые функции, только bash-арифметика ($(( ))), без внешних зависимостей.
# set-e-safe: значения берём через $(( ))/local, guard'ы через "|| return".

# _ipv4_to_int <a.b.c.d> : 32-битное целое из IPv4. Guard входа - _valid_ipv4
# (не переизобретаем проверку октетов). 10# защищает от трактовки ведущего нуля
# как восьмеричного числа.
_ipv4_to_int() {
    _valid_ipv4 "$1" || return 1
    local IFS=. o
    read -ra o <<< "$1"
    echo $(( (10#${o[0]} << 24) | (10#${o[1]} << 16) | (10#${o[2]} << 8) | 10#${o[3]} ))
}

# _int_to_ipv4 <int> : IPv4 из 32-битного целого.
_int_to_ipv4() {
    local n="$1"
    echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

# _cidr_bounds <addr/prefix> : печатает "network_int broadcast_int".
# Единственный источник формулы network/broadcast в awg_common.
_cidr_bounds() {
    local cidr="$1" addr prefix ip mask net bcast
    addr="${cidr%/*}"; prefix="${cidr##*/}"
    [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    (( 10#$prefix >= 0 && 10#$prefix <= 32 )) || return 1
    ip=$(_ipv4_to_int "$addr") || return 1
    if (( 10#$prefix == 0 )); then mask=0; else mask=$(( (0xFFFFFFFF << (32 - 10#$prefix)) & 0xFFFFFFFF )); fi
    net=$(( ip & mask ))
    bcast=$(( net | (0xFFFFFFFF ^ mask) ))
    echo "$net $bcast"
}

# Определение основного сетевого интерфейса (egress).
# Цепочка fallback, чтобы не падать на хостах, где зонд к 1.1.1.1 не отдаёт
# интерфейс: провайдер null-route'ит/блокирует адрес, policy-routing или
# IPv6-only egress (наблюдалось на Ubuntu 26.04 / Timeweb, issue #166).
# Ручное переопределение: export AWG_MAIN_NIC=<iface> перед запуском.
get_main_nic() {
    # Ручной оверрайд принимаем только если это существующий безопасный ifname:
    # значение попадает в PostUp/PostDown (iptables -o ...), поэтому имена с
    # shell-метасимволами и несуществующие интерфейсы отвергаем (fall-through
    # к авто-детекту).
    if [[ -n "${AWG_MAIN_NIC:-}" ]]; then
        if [[ "$AWG_MAIN_NIC" =~ ^[A-Za-z0-9._-]+$ ]] \
            && ip link show dev "$AWG_MAIN_NIC" &>/dev/null; then
            printf '%s\n' "$AWG_MAIN_NIC"
            return 0
        fi
        # Невалидный оверрайд отбрасываем ГРОМКО (log_warn идёт в stderr, вывод
        # $() не загрязняет): молчаливый fall-through путал бы пользователя,
        # который уже выполнил подсказку export AWG_MAIN_NIC=... с опечаткой.
        log_warn "AWG_MAIN_NIC='${AWG_MAIN_NIC}' проигнорирован: интерфейс не найден или имя некорректно - продолжаю авто-детект."
    fi
    local nic
    # 1) Реальный egress к публичному адресу (FIB-lookup, быстрый путь для большинства хостов).
    nic=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    # 2) Дефолтный IPv4-маршрут (когда зонд недостижим/заблокирован).
    [[ -z "$nic" ]] && nic=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    # 3) Первый UP-интерфейс с глобальным IPv4 (нет дефолт-маршрута). Исключаем
    #    туннельные/виртуальные (awg0 сам UP с 10.x scope global при --force
    #    переустановке, docker0/br-*/veth* на хостах с контейнерами) - иначе
    #    NAT ушёл бы в hairpin через сам туннель, а IPv6-only warning молча
    #    подавился бы (у awg0 есть глобальный IPv4).
    [[ -z "$nic" ]] && nic=$(ip -o -4 addr show up scope global 2>/dev/null \
        | awk '{sub(/@.*/,"",$2); if ($2!="lo" && $2 !~ /^(awg|wg|docker|br-|virbr|veth|lxc|tun|tap)/) { print $2; exit }}')
    # 4) Дефолтный IPv6-маршрут (IPv6-only egress).
    [[ -z "$nic" ]] && nic=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [[ -n "$nic" ]] || return 1
    printf '%s\n' "$nic"
}

# Возвращает 0, если у хоста нет IPv4-выхода: нет дефолтного IPv4-маршрута И у
# интерфейса $1 нет глобального IPv4-адреса. Такой хост IPv6-only (issue #166:
# Timeweb Ubuntu 26.04) - IPv4-туннель (10.x) не сможет NAT'иться наружу.
# Оба условия должны совпасть: на dual-stack/IPv4 хостах функция вернёт 1.
host_lacks_ipv4_egress() {
    local nic="$1"
    # [[ -z $(...) ]] вместо "| grep -q .": grep -q выходит на первой строке, и
    # под pipefail многострочный вывод ip (несколько default-маршрутов) мог бы
    # дать SIGPIPE=141 -> ложное "маршрута нет" на здоровом dual-stack хосте.
    [[ -z "$(ip -4 route show default 2>/dev/null)" ]] \
        && [[ -z "$(ip -o -4 addr show dev "$nic" up scope global 2>/dev/null)" ]]
}

# Определение внешнего IP-адреса сервера (с кэшированием).
#
# Список 6 сервисов покрывает основные NAT и cloud-сценарии без
# жёсткого ранжирования по uptime: ifconfig.me исторически стабилен
# на обычных VPS (Hetzner, Vultr, OVH), checkip.amazonaws.com -
# доступен даже из AWS / GCP / OCI private subnet за NAT Gateway,
# ipinfo.io / icanhazip / ifconfig.io - дополнительные fallback'и
# на случай rate-limit одного из endpoint'ов. Порядок alphabetical
# (детерминирован для тестов и diff'ов). First-wins: при первом
# валидном ответе остальные не запрашиваются.
_CACHED_PUBLIC_IP=""
# Файловый дубль кэша: get_server_public_ip практически всегда вызывается как
# $(...) (subshell), где присваивание _CACHED_PUBLIC_IP теряется в родителе и
# кэш-переменная никогда не срабатывает. Файл с PID-суффиксом переживает
# subshell (тот же приём, что _AWG_TEMP_REGISTRY) и удаляется в _awg_cleanup.
# Без него `manage regen` по N клиентам делал бы N curl-раундов (до 6 сервисов
# по 5 сек каждый) при пустом AWG_ENDPOINT.
_PUBLIC_IP_CACHE="${AWG_DIR}/.public_ip.cache.$$"
get_server_public_ip() {
    if [[ -n "$_CACHED_PUBLIC_IP" ]]; then
        echo "$_CACHED_PUBLIC_IP"
        return 0
    fi
    if [[ -f "$_PUBLIC_IP_CACHE" && ! -L "$_PUBLIC_IP_CACHE" ]]; then
        local cached
        cached=$(<"$_PUBLIC_IP_CACHE")
        if [[ -n "$cached" ]] && _valid_ipv4 "$cached"; then
            _CACHED_PUBLIC_IP="$cached"
            echo "$cached"
            return 0
        fi
    fi
    local ip="" svc
    for svc in \
        https://api.ipify.org \
        https://checkip.amazonaws.com \
        https://icanhazip.com \
        https://ifconfig.io \
        https://ifconfig.me \
        https://ipinfo.io/ip
    do
        ip=$(curl -4 -sf --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$ip" ]] && _valid_ipv4 "$ip"; then
            _CACHED_PUBLIC_IP="$ip"
            if [[ -n "${LOG_FILE:-}" && -w "$(dirname "${LOG_FILE}")" ]]; then
                printf '[%s] DEBUG: public IP detected: %s (via %s)\n' \
                    "$(date +'%F %T')" "$ip" "$svc" >>"$LOG_FILE" 2>/dev/null || true
            fi
            echo "$ip"
            return 0
        fi
    done
    if [[ -n "${LOG_FILE:-}" && -w "$(dirname "${LOG_FILE}")" ]]; then
        printf '[%s] DEBUG: public IP detection failed (all services unreachable or invalid)\n' \
            "$(date +'%F %T')" >>"$LOG_FILE" 2>/dev/null || true
    fi
    echo ""
    return 1
}

# Fallback: первый non-loopback IPv4 с сетевого интерфейса.
# Нужен когда curl до ifconfig.me / ipify / ... не проходит (LXC без egress,
# fail2ban на outbound, firewall, и т.п.). На bare metal / обычных VPS
# обычно совпадает с public IP; на NAT'нутом хосте даёт private IP — в
# этом случае вызывающий код должен написать log_warn чтобы пользователь
# сам исправил Endpoint в клиентских .conf.
_try_local_ip() {
    local ip
    ip=$(ip -4 -o addr show scope global 2>/dev/null \
        | awk '{print $4}' \
        | cut -d/ -f1 \
        | grep -v '^127\.' \
        | head -1)
    { [[ -n "$ip" ]] && _valid_ipv4 "$ip"; } || return 1
    echo "$ip"
    return 0
}

# Первый non-loopback IPv6 с сетевого интерфейса. Используется только как
# best-effort endpoint fallback; для клиентских адресов нужен отдельный /64.
_try_local_ipv6() {
    local ip
    ip=$(ip -6 -o addr show scope global 2>/dev/null \
        | awk '{print $4}' \
        | cut -d/ -f1 \
        | grep -vi '^fe80:' \
        | head -1)
    [[ -n "$ip" && "$ip" == *:* ]] || return 1
    echo "$ip"
    return 0
}


# ------------------------------------------------------------------------------
# Voice / Calls UDP tuning helpers
# ------------------------------------------------------------------------------

setup_voice_udp_optimization() {
    log "Настройка Voice / Calls UDP optimization..."
    local udp_proc="${AWG_PROC_SYS_ROOT:-/proc/sys}/net/netfilter/nf_conntrack_udp_timeout"
    local max_proc="${AWG_PROC_SYS_ROOT:-/proc/sys}/net/netfilter/nf_conntrack_max"
    local sysctl_dir="${AWG_SYSCTL_DIR:-/etc/sysctl.d}"
    local udp_file="$sysctl_dir/99-awg-udp.conf"
    local max_file="$sysctl_dir/99-awg-conntrack.conf"

    modprobe nf_conntrack 2>/dev/null || true
    mkdir -p "$sysctl_dir" 2>/dev/null || true
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

# ------------------------------------------------------------------------------
# IPv6 / P2P helpers
# ------------------------------------------------------------------------------

_awg_bool() {
    case "${1:-0}" in
        1|yes|true|on|enabled) return 0 ;;
        *) return 1 ;;
    esac
}

normalize_awg_ipv6_mode() {
    case "${1:-legacy}" in
        routed|ndp|nat66|block|legacy) echo "${1:-legacy}" ;;
        native) echo "ndp" ;;
        ula) echo "nat66" ;;
        leak-block|leak_block|disable) echo "block" ;;
        disabled|off|0) echo "legacy" ;;
        *) return 1 ;;
    esac
}

awg_ipv6_mode() {
    normalize_awg_ipv6_mode "${AWG_IPV6_MODE:-legacy}" 2>/dev/null || echo "legacy"
}

awg_ipv6_effective_mode() {
    local effective="${AWG_IPV6_MODE_EFFECTIVE:-}" mode="${AWG_IPV6_MODE:-legacy}"
    if [[ -z "$effective" || ( "$effective" == "legacy" && "$mode" != "legacy" ) ]]; then
        effective="$mode"
    fi
    normalize_awg_ipv6_mode "${effective:-legacy}" 2>/dev/null || echo "legacy"
}

awg_ipv6_effective_mode_is_ndp() {
    [[ "$(awg_ipv6_effective_mode)" == "ndp" ]]
}

awg_ipv6_enabled() {
    _awg_bool "${AWG_IPV6_ENABLED:-0}" && [[ -n "${AWG_IPV6_SUBNET:-}" ]]
}

awg_ipv6_leak_block_enabled() {
    [[ "$(normalize_awg_ipv6_mode "${AWG_IPV6_MODE:-legacy}" 2>/dev/null || echo legacy)" == "block" ]] || \
        [[ "${AWG_IPV6_LEAK_PROTECTION:-warn}" == "block" ]]
}

# ------------------------------------------------------------------------------
# NDP proxy (ndppd) helpers
#
# Used when an IPv6 prefix from the provider is on-link on the WAN interface
# rather than routed to the server: VPN clients behind awg0 then need an NDP
# proxy on the WAN interface to answer Neighbor Solicitations for their
# addresses.
# ------------------------------------------------------------------------------

NDPPD_CONF_FILE="${NDPPD_CONF_FILE:-/etc/ndppd.conf}"
NDPPD_SYSTEMD_DROPIN="${NDPPD_SYSTEMD_DROPIN:-/etc/systemd/system/ndppd.service.d/10-amneziawg.conf}"
NDP_SYSCTL_FILE="${NDP_SYSCTL_FILE:-/etc/sysctl.d/99-amneziawg-ndp.conf}"
IF_INET6_FILE="${IF_INET6_FILE:-/proc/net/if_inet6}"

if ! declare -f die >/dev/null 2>&1; then
    die() { log_error "$1"; exit 1; }
fi

# True if the host has at least one global-scope IPv6 address (any iface).
host_has_global_ipv6() {
    [[ -r "$IF_INET6_FILE" ]] || return 1
    awk '$4=="00"{found=1} END{exit !found}' "$IF_INET6_FILE"
}

# Validate that $1 is a syntactically valid IPv6 CIDR (e.g. 2001:db8::/64).
validate_ipv6_cidr() {
    local value="$1"
    [[ -n "$value" ]] || return 1
    command -v python3 &>/dev/null || return 1
    python3 - "$value" <<'PY' 2>/dev/null
import ipaddress
import sys

try:
    net = ipaddress.ip_network(sys.argv[1], strict=True)
except ValueError:
    sys.exit(1)
sys.exit(0 if net.version == 6 else 1)
PY
}

# Detect the VPN tunnel interface name (awg0/wg0).
get_vpn_nic() {
    if [[ -e /sys/class/net/awg0 ]]; then
        echo "awg0"
    elif [[ -e /sys/class/net/wg0 ]]; then
        echo "wg0"
    else
        echo "awg0"
    fi
}

# shellcheck disable=SC2120 # Optional config path; callers usually use SERVER_CONF_FILE.
awg_peer_ipv6_routes() {
    local conf="${1:-${SERVER_CONF_FILE:-/etc/amnezia/amneziawg/awg0.conf}}"
    [[ -f "$conf" ]] || return 0
    awk '/^AllowedIPs[[:space:]]*=/{gsub(/,/, " "); for (i=1; i<=NF; i++) if ($i ~ /^[0-9A-Fa-f:]+\/128$/) print $i}' "$conf"
}

get_wan_ipv6_prefixes() {
    local wan="${1:-$(get_main_nic)}"
    [[ -n "$wan" ]] || return 1
    ip -6 -o addr show dev "$wan" scope global 2>/dev/null | awk '{print $4}'
}

is_prefix_onlink_on_wan() {
    local prefix="$1" wan="${2:-$(get_main_nic)}"
    [[ -n "$prefix" && -n "$wan" ]] || return 1
    command -v python3 &>/dev/null || return 1
    local wan_prefix
    while IFS= read -r wan_prefix; do
        [[ -n "$wan_prefix" ]] || continue
        python3 - "$prefix" "$wan_prefix" <<'PY' 2>/dev/null && return 0
import ipaddress
import sys

try:
    wanted = ipaddress.ip_network(sys.argv[1], strict=False)
    onlink = ipaddress.ip_interface(sys.argv[2]).network
except ValueError:
    sys.exit(1)
sys.exit(0 if wanted.version == 6 and wanted == onlink else 1)
PY
    done < <(get_wan_ipv6_prefixes "$wan")
    return 1
}

detect_ipv6_address_collisions() {
    local prefix="${1:-${AWG_IPV6_SUBNET:-}}" wan="${2:-$(get_main_nic)}"
    command -v python3 &>/dev/null || return 0
    AWG_DIR="${AWG_DIR:-/root/awg}" SERVER_CONF_FILE="${SERVER_CONF_FILE:-/etc/amnezia/amneziawg/awg0.conf}" \
    python3 - "$prefix" "$wan" <<'PY'
import ipaddress
import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

prefix, wan = sys.argv[1], sys.argv[2]
try:
    net = ipaddress.ip_network(prefix, strict=False) if prefix else None
except ValueError:
    net = None

owners = defaultdict(list)

def add(addr, owner):
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return
    if ip.version == 6 and (net is None or ip in net):
        owners[str(ip)].append(owner)

try:
    out = subprocess.run(["ip", "-6", "-o", "addr", "show", "dev", wan, "scope", "global"], capture_output=True, text=True, timeout=2, check=False).stdout
    for token in re.findall(r"inet6\s+([0-9A-Fa-f:]+)/\d+", out):
        add(token, f"WAN:{wan}")
except Exception:
    pass

try:
    out = subprocess.run(["ip", "-6", "route", "show", "default"], capture_output=True, text=True, timeout=2, check=False).stdout
    for token in re.findall(r"\bvia\s+([0-9A-Fa-f:]+)", out):
        add(token, "WAN:gateway")
except Exception:
    pass

if net:
    add(str(net.network_address), "reserved:network")
    add(str(net.network_address + 1), "server:vpn")

paths = []
server_conf = Path(os.environ.get("SERVER_CONF_FILE", ""))
if server_conf:
    paths.append(server_conf)
awg_dir = Path(os.environ.get("AWG_DIR", ""))
if awg_dir:
    paths.extend(awg_dir.glob("*.conf"))

for path in paths:
    try:
        data = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        continue
    label = str(path)
    in_interface = False
    for line in data.splitlines():
        stripped = line.strip()
        if stripped == "[Interface]":
            in_interface = True
            continue
        if stripped.startswith("[") and stripped != "[Interface]":
            in_interface = False
        if in_interface and path == server_conf and stripped.startswith("Address"):
            for token in re.findall(r"([0-9A-Fa-f:]+/\d+)", stripped):
                add(token, f"server:{label}")
    for token in re.findall(r"(?:AllowedIPs|Address)\s*=\s*[^\n#]*?([0-9A-Fa-f:]+)/128", data):
        add(token, f"client:{label}")

for ip, who in sorted(owners.items(), key=lambda item: ipaddress.ip_address(item[0])):
    client = [x for x in who if x.startswith("client:")]
    non_client = [x for x in who if not x.startswith("client:")]
    if client and non_client:
        print(f"{ip}: {', '.join(who)}")
PY
}

awg_shell_quote() {
    printf "%q" "$1"
}

update_config_var() {
    local key="$1" value="$2" file="${3:-$CONFIG_FILE}" quoted tmp
    [[ -n "$key" && -n "$file" ]] || return 1
    tmp=$(awg_mktemp) || return 1
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        quoted="$value"
    else
        quoted="'${value//\'/\'\\\'\'}'"
    fi
    if [[ -f "$file" ]]; then
        awk -v key="$key" -v line="export ${key}=${quoted}" '
            $0 ~ "^export[[:space:]]+" key "=" || $0 ~ "^" key "=" {
                if (!done) { print line; done=1 }
                next
            }
            { print }
            END { if (!done) print line }
        ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    else
        printf 'export %s=%s\n' "$key" "$quoted" > "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    mv -f "$tmp" "$file"
}

# Classify the IPv6/NDP situation of this host into one of:
#   ipv6_disabled                    - no global IPv6 address; ndppd not applicable
#   ipv6_prefix_onlink_needs_ndp_proxy - AWG_IPV6_MODE=ndp: provider prefix is on-link, ndppd needed
#   ipv6_prefix_routed_to_server     - AWG_IPV6_MODE=routed/nat66: prefix routed to server, ndppd not needed
#   ipv6_public_single_address_only  - global address present, no AWG IPv6 prefix configured
#   ipv6_unknown_manual_review        - global address + prefix configured but mode unclear
ipv6_ndp_state() {
    if [[ "${DISABLE_IPV6:-0}" == "1" ]] || ! host_has_global_ipv6; then
        echo "ipv6_disabled"
        return 0
    fi
    case "$(awg_ipv6_effective_mode)" in
        ndp) echo "ipv6_prefix_onlink_needs_ndp_proxy" ;;
        routed|nat66) echo "ipv6_prefix_routed_to_server" ;;
        *)
            if [[ -n "${AWG_IPV6_SUBNET:-}" ]]; then
                echo "ipv6_unknown_manual_review"
            else
                echo "ipv6_public_single_address_only"
            fi
            ;;
    esac
}

# Generate $NDPPD_CONF_FILE for a given (or configured) IPv6 prefix.
# Refuses when IPv6 is unavailable on the host or the prefix is invalid.
ipv6_ndp_generate_config() {
    local prefix="${1:-${AWG_IPV6_SUBNET:-}}"
    if [[ -z "$prefix" ]]; then
        die "IPv6 prefix not specified and AWG_IPV6_SUBNET is empty. Provide a prefix explicitly."
    fi
    validate_ipv6_cidr "$prefix" || die "Invalid IPv6 CIDR prefix: $prefix"
    if [[ "${DISABLE_IPV6:-0}" == "1" ]] || ! host_has_global_ipv6; then
        die "No global IPv6 address detected on this host; refusing to configure ndppd."
    fi
    local wan vpn
    wan="$(get_main_nic)"
    [[ -n "$wan" ]] || wan="eth0"
    vpn="$(get_vpn_nic)"
    if [[ -f "$NDPPD_CONF_FILE" ]]; then
        cp -a "$NDPPD_CONF_FILE" "${NDPPD_CONF_FILE}.bak.$(date +%Y%m%d-%H%M%S)" || die "Failed to backup $NDPPD_CONF_FILE"
    fi
    {
        cat << EOF
# Managed by AmneziaWG installer. Manual changes may be overwritten.
route-ttl 30000
proxy ${wan} {
    router yes
    timeout 500
    ttl 30000
EOF
        local peer_route peer_ip wrote_peer_rules=0
        while IFS= read -r peer_route; do
            [[ -n "$peer_route" ]] || continue
            peer_ip="${peer_route%/128}"
            wrote_peer_rules=1
            cat << EOF
    rule ${peer_ip} {
        static
    }
EOF
        done < <(awg_peer_ipv6_routes)
        if [[ "$wrote_peer_rules" -eq 0 ]]; then
            cat << EOF
    rule ${prefix} {
        iface ${vpn}
    }
EOF
        fi
        cat << EOF
}
EOF
    } > "$NDPPD_CONF_FILE"
    chmod 644 "$NDPPD_CONF_FILE"
    log "ndppd config generated for ${prefix} on ${wan} -> $NDPPD_CONF_FILE"
}

ipv6_ndp_write_systemd_dropin() {
    local vpn="${1:-$(get_vpn_nic)}"
    mkdir -p "$(dirname "$NDPPD_SYSTEMD_DROPIN")" || die "Failed to create ndppd systemd drop-in directory"
    cat > "$NDPPD_SYSTEMD_DROPIN" << EOF
[Unit]
After=network-online.target awg-quick@${vpn}.service
Wants=network-online.target awg-quick@${vpn}.service

[Service]
Restart=on-failure
RestartSec=5s
EOF
    chmod 644 "$NDPPD_SYSTEMD_DROPIN" 2>/dev/null || true
}

ipv6_ndp_enable_sysctl() {
    local wan="${1:-$(get_main_nic)}"
    [[ -n "$wan" ]] || wan="eth0"
    mkdir -p "$(dirname "$NDP_SYSCTL_FILE")" || die "Failed to create sysctl directory"
    cat > "$NDP_SYSCTL_FILE" << EOF
# Managed by AmneziaWG installer. Manual changes may be overwritten.
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.all.proxy_ndp = 1
net.ipv6.conf.${wan}.proxy_ndp = 1
EOF
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.forwarding=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.all.proxy_ndp=1 >/dev/null 2>&1 || true
    sysctl -w "net.ipv6.conf.${wan}.proxy_ndp=1" >/dev/null 2>&1 || true
}

# Enable and start ndppd. Installs the package if missing. Refuses when
# IPv6 is unavailable on the host (never auto-installs in that case).
ipv6_ndp_enable() {
    if [[ "${DISABLE_IPV6:-0}" == "1" ]] || ! host_has_global_ipv6; then
        die "No global IPv6 address detected; ndppd is not applicable on this host."
    fi
    [[ -f "$NDPPD_CONF_FILE" ]] || die "ndppd config not found at $NDPPD_CONF_FILE; run 'ipv6 ndp generate' first."
    if ! command -v ndppd &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y ndppd || die "Failed to install ndppd package"
    fi
    ipv6_ndp_write_systemd_dropin "$(get_vpn_nic)"
    systemctl daemon-reload 2>/dev/null || true
    ipv6_ndp_enable_sysctl "$(get_main_nic)"
    systemctl enable --now ndppd || die "Failed to enable/start ndppd"
    systemctl restart ndppd || die "Failed to restart ndppd"
    log "ndppd enabled and started."
}

ipv6_ndp_refresh_after_config_apply() {
    awg_ipv6_effective_mode_is_ndp || return 0
    [[ "${AWG_IPV6_ENABLED:-0}" == "1" ]] || return 0
    [[ -n "${AWG_IPV6_SUBNET:-}" ]] || return 0
    ipv6_ndp_generate_config "$AWG_IPV6_SUBNET"
    ipv6_ndp_enable
    if [[ -x "${AWG_DIR:-/root/awg}/postup.sh" ]]; then
        bash "${AWG_DIR:-/root/awg}/postup.sh" 2>/dev/null || log_warn "Failed to apply live NDP peer routes; restart awg-quick@awg0 if IPv6 peers are unreachable."
    fi
}

# Disable and stop ndppd. Always allowed (cleanup must work even if IPv6
# is no longer available).
ipv6_ndp_disable() {
    systemctl disable --now ndppd 2>/dev/null || true
    log "ndppd disabled."
}

# Restart ndppd using the existing config file.
ipv6_ndp_restart() {
    [[ -f "$NDPPD_CONF_FILE" ]] || die "ndppd config not found at $NDPPD_CONF_FILE; run 'ipv6 ndp generate' first."
    systemctl restart ndppd || die "Failed to restart ndppd"
    log "ndppd restarted."
}

# Print a human-readable NDP proxy status summary.
ipv6_ndp_print_status() {
    local wan vpn state installed configured active enabled proxy_all proxy_wan forwarding collisions
    wan="$(get_main_nic)"; [[ -n "$wan" ]] || wan="eth0"
    vpn="$(get_vpn_nic)"
    state="$(ipv6_ndp_state)"
    command -v ndppd >/dev/null 2>&1 && installed="installed" || installed="missing"
    [[ -f "$NDPPD_CONF_FILE" ]] && configured="present" || configured="missing"
    active="$(systemctl is-active ndppd 2>/dev/null || echo inactive)"
    enabled="$(systemctl is-enabled ndppd 2>/dev/null || echo disabled)"
    proxy_all="$(cat /proc/sys/net/ipv6/conf/all/proxy_ndp 2>/dev/null || echo 0)"
    proxy_wan="$(cat "/proc/sys/net/ipv6/conf/${wan}/proxy_ndp" 2>/dev/null || echo 0)"
    forwarding="$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo 0)"
    collisions="$(detect_ipv6_address_collisions "${AWG_IPV6_SUBNET:-}" "$wan" 2>/dev/null || true)"
    [[ -n "$collisions" ]] || collisions="none"
    log "IPv6 enabled: $([[ "${AWG_IPV6_ENABLED:-0}" == "1" ]] && echo yes || echo no)"
    log "IPv6 mode requested: ${AWG_IPV6_MODE_REQUESTED:-${AWG_IPV6_MODE:-legacy}}"
    log "IPv6 mode effective: $(awg_ipv6_effective_mode)"
    log "NDP state: ${state}"
    log "NDP proxy needed: $(awg_ipv6_effective_mode_is_ndp && echo yes || echo no)"
    log "WAN iface: ${wan}"
    log "VPN iface: ${vpn}"
    log "Prefix: ${AWG_IPV6_SUBNET:-}"
    log "ndppd package: ${installed}"
    if [[ -f "$NDPPD_CONF_FILE" ]]; then
        log "ndppd config: present"
    else
        log "ndppd config: missing"
    fi
    log "ndppd active: ${active:-inactive}"
    log "ndppd enabled: ${enabled:-disabled}"
    log "proxy_ndp all: ${proxy_all}"
    log "proxy_ndp ${wan}: ${proxy_wan}"
    log "forwarding: ${forwarding}"
    log "address collisions: ${collisions}"
    if awg_ipv6_effective_mode_is_ndp; then
        [[ "$installed" == "installed" ]] || log_warn "ERROR: effective IPv6 mode is ndp but ndppd is missing"
        [[ "$configured" == "present" ]] || log_warn "ERROR: effective IPv6 mode is ndp but $NDPPD_CONF_FILE is missing"
        [[ "$active" == "active" ]] || log_warn "ERROR: effective IPv6 mode is ndp but ndppd is not active"
    fi
}

ipv6_ndp_fix() {
    safe_load_config "$CONFIG_FILE" 2>/dev/null || true
    local wan prefix changed=0
    wan="$(get_main_nic)"; [[ -n "$wan" ]] || wan="eth0"
    prefix="${AWG_IPV6_SUBNET:-}"
    [[ -n "$prefix" ]] || die "AWG_IPV6_SUBNET is empty; cannot configure NDP proxy."
    validate_ipv6_cidr "$prefix" || die "Invalid IPv6 CIDR prefix: $prefix"
    if is_prefix_onlink_on_wan "$prefix" "$wan"; then
        AWG_IPV6_ENABLED=1
        AWG_IPV6_MODE_REQUESTED="${AWG_IPV6_MODE_REQUESTED:-auto}"
        [[ "$AWG_IPV6_MODE_REQUESTED" == "legacy" ]] && AWG_IPV6_MODE_REQUESTED="auto"
        AWG_IPV6_MODE_EFFECTIVE=ndp
        AWG_IPV6_MODE=ndp
        AWG_IPV6_NDP_PROXY=1
        AWG_IPV6_MODE_REASON="selected ndp because VPN prefix matches WAN on-link /64"
        changed=1
    elif awg_ipv6_effective_mode_is_ndp; then
        changed=1
    else
        die "VPN prefix ${prefix} is not on-link on WAN ${wan}; refusing to force NDP."
    fi
    if [[ "$changed" -eq 1 && -f "$CONFIG_FILE" ]]; then
        update_config_var AWG_IPV6_ENABLED 1
        update_config_var AWG_IPV6_MODE "$AWG_IPV6_MODE"
        update_config_var AWG_IPV6_MODE_REQUESTED "$AWG_IPV6_MODE_REQUESTED"
        update_config_var AWG_IPV6_MODE_EFFECTIVE "$AWG_IPV6_MODE_EFFECTIVE"
        update_config_var AWG_IPV6_MODE_REASON "$AWG_IPV6_MODE_REASON"
        update_config_var AWG_IPV6_SUBNET "$AWG_IPV6_SUBNET"
        update_config_var AWG_IPV6_NDP_PROXY "$AWG_IPV6_NDP_PROXY"
    fi
    ipv6_ndp_generate_config "$prefix"
    ipv6_ndp_enable
    ipv6_ndp_print_status
}

# ------------------------------------------------------------------------------
# GeoIP database auto-update (scripts/update_geoip_dbs.py)
#
# Downloads free MaxMind GeoLite2 (ASN/City/Country) and DB-IP city-lite MMDB
# files into $AWG_DIR/geoip/. update-dbs runs the downloader once; the
# auto-update helpers install/enable/disable a weekly systemd timer that
# repeats it. Never enabled implicitly - only via explicit admin action.
# ------------------------------------------------------------------------------

GEOIP_UPDATE_SCRIPT="${GEOIP_UPDATE_SCRIPT:-$AWG_DIR/scripts/update_geoip_dbs.py}"
GEOIP_TIMER_UNIT_FILE="${GEOIP_TIMER_UNIT_FILE:-/etc/systemd/system/awg-geoip-update.timer}"
GEOIP_SERVICE_UNIT_FILE="${GEOIP_SERVICE_UNIT_FILE:-/etc/systemd/system/awg-geoip-update.service}"

# Run the GeoIP MMDB downloader once.
geoip_update_dbs() {
    [[ -f "$GEOIP_UPDATE_SCRIPT" ]] || die "GeoIP updater script not found: $GEOIP_UPDATE_SCRIPT"
    command -v python3 &>/dev/null || die "python3 is required to run the GeoIP updater"
    python3 "$GEOIP_UPDATE_SCRIPT" --awg-dir "$AWG_DIR"
}

# Write the systemd service+timer units for the weekly GeoIP DB auto-update.
geoip_auto_update_install_units() {
    [[ -f "$GEOIP_UPDATE_SCRIPT" ]] || die "GeoIP updater script not found: $GEOIP_UPDATE_SCRIPT"
    cat > "$GEOIP_SERVICE_UNIT_FILE" << EOF
[Unit]
Description=Update AmneziaWG Web Panel GeoIP MMDB databases
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 ${GEOIP_UPDATE_SCRIPT} --awg-dir ${AWG_DIR}
EOF
    cat > "$GEOIP_TIMER_UNIT_FILE" << EOF
[Unit]
Description=Weekly AmneziaWG Web Panel GeoIP MMDB database update

[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=3600

[Install]
WantedBy=timers.target
EOF
    chmod 644 "$GEOIP_SERVICE_UNIT_FILE" "$GEOIP_TIMER_UNIT_FILE"
    systemctl daemon-reload 2>/dev/null || true
}

# Install the units (if needed) and enable+start the weekly timer.
geoip_auto_update_enable() {
    geoip_auto_update_install_units
    systemctl enable --now awg-geoip-update.timer || die "Failed to enable awg-geoip-update.timer"
    log "GeoIP DB auto-update enabled (weekly timer)."
}

# Disable and stop the weekly timer. Always allowed, even if never enabled.
geoip_auto_update_disable() {
    systemctl disable --now awg-geoip-update.timer 2>/dev/null || true
    log "GeoIP DB auto-update disabled."
}

# Print the current auto-update timer status.
geoip_auto_update_status() {
    local _timer_enabled _timer_active
    _timer_enabled="$(systemctl is-enabled awg-geoip-update.timer 2>/dev/null)"
    _timer_active="$(systemctl is-active awg-geoip-update.timer 2>/dev/null)"
    log "GeoIP auto-update timer: ${_timer_enabled:-disabled}"
    log "GeoIP auto-update active: ${_timer_active:-inactive}"
}

awg_p2p_enabled() {
    _awg_bool "${AWG_P2P_ENABLED:-0}"
}

awg_server_name() {
    local name="${AWG_SERVER_NAME:-AWG Server}"
    name="${name//$'\r'/ }"
    name="${name//$'\n'/ }"
    [[ -n "${name//[[:space:]]/}" ]] || name="AWG Server"
    printf '%s' "$name"
}

awg_dns_mode() {
    case "${AWG_DNS_MODE:-system}" in
        adguard|system|custom) echo "${AWG_DNS_MODE}" ;;
        *) echo "system" ;;
    esac
}

awg_ipv4_gateway() {
    local tunnel="${AWG_TUNNEL_SUBNET:-10.9.9.1/24}"
    printf '%s\n' "${tunnel%/*}"
}

awg_ipv4_network() {
    python3 - "${AWG_TUNNEL_SUBNET:-10.9.9.1/24}" <<'PY'
import ipaddress
import sys
print(ipaddress.ip_interface(sys.argv[1]).network)
PY
}

awg_dns_servers() {
    local mode
    mode=$(awg_dns_mode)
    case "$mode" in
        adguard)
            local dns server_v6=""
            dns="$(awg_ipv4_gateway)"
            if awg_ipv6_enabled; then
                server_v6=$(get_server_ipv6_address 2>/dev/null || true)
                [[ -n "$server_v6" ]] && dns="${dns}, ${server_v6}"
            fi
            echo "$dns"
            ;;
        custom)
            echo "${AWG_CUSTOM_DNS:-1.1.1.1}"
            ;;
        *)
            echo "1.1.1.1, 1.0.0.1"
            ;;
    esac
}

ensure_dns_allowedips_routes() {
    local allowed_ips="$1" dns_servers="$2" tunnel_subnet="${3:-${AWG_TUNNEL_SUBNET:-10.9.9.1/24}}" ipv6_subnet="${4:-${AWG_IPV6_SUBNET:-}}"
    [[ -n "$allowed_ips" ]] || allowed_ips="0.0.0.0/0"
    python3 - "$allowed_ips" "$dns_servers" "$tunnel_subnet" "$ipv6_subnet" <<'PY'
import ipaddress
import re
import sys

allowed, dns_servers, tunnel_subnet, ipv6_subnet = sys.argv[1:5]
routes = [item.strip() for item in allowed.split(",") if item.strip()]
seen = set(routes)
initial_routes = tuple(routes)

def has_covering_route(ip):
    for route in initial_routes:
        try:
            if ip in ipaddress.ip_network(route, strict=False):
                return True
        except (TypeError, ValueError):
            continue
    return False

def has_covering_network(network):
    for route in routes:
        try:
            if network.subnet_of(ipaddress.ip_network(route, strict=False)):
                return True
        except (TypeError, ValueError):
            continue
    return False

networks = []
for value in (tunnel_subnet, ipv6_subnet):
    if not value:
        continue
    try:
        networks.append(ipaddress.ip_interface(value).network)
    except ValueError:
        try:
            networks.append(ipaddress.ip_network(value, strict=False))
        except ValueError:
            pass

for token in re.split(r"[,;\s]+", dns_servers):
    token = token.strip().strip("[]")
    if not token:
        continue
    try:
        ip = ipaddress.ip_address(token)
    except ValueError:
        continue
    if has_covering_route(ip):
        continue
    if any(ip in network for network in networks):
        route = f"{ip}/{'32' if ip.version == 4 else '128'}"
        if route not in seen:
            routes.append(route)
            seen.add(route)

# The tunnel network is a control-plane dependency, not an optional route.
# Add it after DNS host routes so existing split-DNS behavior is preserved.
# A full-tunnel route already covers it and is not duplicated.
for network in networks:
    if has_covering_network(network):
        continue
    route = str(network)
    if route not in seen:
        routes.append(route)
        seen.add(route)

print(", ".join(routes))
PY
}

validate_wiresock_hint_domain() {
    local value="$1"
    [[ -n "$value" && ${#value} -le 253 ]] || return 1
    [[ "$value" != *[[:space:]]* && "$value" != *[[:cntrl:]]* ]] || return 1
    [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

apply_wiresock_hint_defaults() {
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

render_wiresock_hints() {
    [[ "${AWG_WIRESOCK_HINTS:-off}" != "off" ]] || return 0
    apply_wiresock_hint_defaults
    validate_wiresock_hint_domain "${AWG_WIRESOCK_ID:-}" || return 1
    case "${AWG_WIRESOCK_IP:-}" in quic|dns) ;; *) return 1 ;; esac
    case "${AWG_WIRESOCK_IB:-}" in curl|chrome) ;; *) return 1 ;; esac
    cat <<EOF
# WireSock compatibility hints (ignored by standard clients)
#@ws:Id = ${AWG_WIRESOCK_ID}
#@ws:Ip = ${AWG_WIRESOCK_IP}
#@ws:Ib = ${AWG_WIRESOCK_IB}
EOF
}

normalize_ipv6_subnet() {
    local subnet="$1"
    [[ -n "$subnet" ]] || return 1
    python3 - "$subnet" <<'PY'
import ipaddress, sys
try:
    net = ipaddress.ip_network(sys.argv[1], strict=False)
    if net.version != 6 or net.prefixlen < 48 or net.prefixlen > 64:
        raise ValueError("expected IPv6 /48../64")
    print(str(net))
except Exception:
    sys.exit(1)
PY
}

ipv6_addr_at() {
    local subnet="$1" offset="$2"
    python3 - "$subnet" "$offset" <<'PY'
import ipaddress, sys
try:
    net = ipaddress.ip_network(sys.argv[1], strict=False)
    off = int(sys.argv[2])
    print(str(net.network_address + off))
except Exception:
    sys.exit(1)
PY
}

get_server_ipv6_address() {
    awg_ipv6_enabled || return 1
    if awg_ipv6_effective_mode_is_ndp; then
        ipv6_addr_at "$AWG_IPV6_SUBNET" 256
    else
        ipv6_addr_at "$AWG_IPV6_SUBNET" 1
    fi
}

_extract_peer_value() {
    local name="$1" key="$2"
    awk -v target="$name" -v key="$key" '
    /^\[Peer\]/ { in_peer=1; found=0; next }
    in_peer && $0 == "#_Name = " target { found=1; next }
    in_peer && found && index($0, key " = ") == 1 {
        sub("^[^=]+=[ \t]*", "")
        print
        exit
    }
    /^\[/ && !/^\[Peer\]/ { in_peer=0; found=0 }
    ' "$SERVER_CONF_FILE" 2>/dev/null
}

get_client_ipv4_from_server() {
    local name="$1" value part
    value=$(_extract_peer_value "$name" "AllowedIPs")
    IFS=',' read -ra _parts <<< "$value"
    for part in "${_parts[@]}"; do
        part="${part//[[:space:]]/}"
        if [[ "$part" =~ ^([0-9.]+)/32$ ]]; then
            echo "${BASH_REMATCH[1]}"
            return 0
        fi
    done
    return 1
}

get_client_ipv6_from_server() {
    local name="$1" value part
    value=$(_extract_peer_value "$name" "AllowedIPs")
    IFS=',' read -ra _parts <<< "$value"
    for part in "${_parts[@]}"; do
        part="${part//[[:space:]]/}"
        if [[ "$part" == *:* && "$part" == */128 ]]; then
            echo "${part%/128}"
            return 0
        fi
    done
    return 1
}

get_peer_p2p_ports() {
    local name="$1"
    awk -v target="$name" '
    /^\[Peer\]/ { in_peer=1; found=0; next }
    /^\[/ && !/^\[Peer\]/ { in_peer=0; found=0 }
    in_peer && $0 == "#_Name = " target { found=1; next }
    in_peer && found && /^#_P2PPorts(_Disabled)?[[:space:]]*=/ {
        sub(/^[^=]+=[ \t]*/, "")
        gsub(/[[:space:]]/, "")
        print
        exit
    }
    ' "$SERVER_CONF_FILE" 2>/dev/null
}

_p2p_used_ports_stream() {
    if [[ -f "$SERVER_CONF_FILE" ]]; then
        awk '/^#_P2PPorts(_Disabled)?[[:space:]]*=/ { sub(/^[^=]+=[ \t]*/, ""); print }' "$SERVER_CONF_FILE" \
            | tr ',' '\n' \
            | sed 's/[[:space:]]//g' \
            | awk -F: '/^[0-9]+(:[0-9]+)?$/ { print $1 }' || true
    fi
    if [[ -f "$AWG_DIR/p2p_rules.sh" ]]; then
        grep -hoE -- '--dport[[:space:]]+[0-9]+' "$AWG_DIR/p2p_rules.sh" 2>/dev/null \
            | awk '{print $2}' \
            | grep -E '^[0-9]+$' || true
    fi
}

validate_p2p_port() {
    local port="$1"
    local base="${AWG_P2P_BASE_PORT:-20000}"
    local min=$((base + 1))
    local max=$((base + 1024))
    [[ "$max" -le 65535 ]] || max=65535
    [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge "$min" ]] && [[ "$port" -le "$max" ]]
}

validate_l4_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]]
}

parse_p2p_forward_spec() {
    local spec="${1//[[:space:]]/}" external internal
    [[ -n "$spec" ]] || return 1
    if [[ "$spec" =~ ^([0-9]+):([0-9]+)$ ]]; then
        external="${BASH_REMATCH[1]}"
        internal="${BASH_REMATCH[2]}"
    elif [[ "$spec" =~ ^[0-9]+$ ]]; then
        external="$spec"
        internal="$spec"
    else
        return 1
    fi
    validate_p2p_port "$external" && validate_l4_port "$internal" || return 1
    printf '%s\t%s\n' "$external" "$internal"
}

get_default_p2p_ports_for_ipv4() {
    local ipv4="$1" count="${2:-${AWG_P2P_PORTS_PER_CLIENT:-3}}"
    local base="${AWG_P2P_BASE_PORT:-20000}"
    local last="${ipv4##*.}"
    [[ "$last" =~ ^[0-9]+$ ]] || return 1
    local candidates=($((base + last)) $((base + 256 + last)) $((base + 512 + last)))
    local out=() p
    for p in "${candidates[@]}"; do
        validate_p2p_port "$p" || continue
        out+=("$p")
        [[ "${#out[@]}" -ge "$count" ]] && break
    done
    (IFS=','; echo "${out[*]}")
}

get_next_p2p_port() {
    local base="${AWG_P2P_BASE_PORT:-20000}"
    local limit=$((base + 1024))
    local p
    declare -A used
    while IFS= read -r p; do
        [[ -n "$p" ]] && used["$p"]=1
    done < <(_p2p_used_ports_stream)
    for ((p=base + 1; p<=limit && p<=65535; p++)); do
        if [[ -z "${used[$p]+x}" ]]; then
            echo "$p"
            return 0
        fi
    done
    log_error "Нет свободных P2P портов в диапазоне $((base + 1))-${limit}"
    return 1
}

allocate_p2p_ports_for_ipv4() {
    local ipv4="$1" count="${2:-${AWG_P2P_PORTS_PER_CLIENT:-3}}"
    local defaults extra p
    declare -A used picked
    while IFS= read -r p; do
        [[ -n "$p" ]] && used["$p"]=1
    done < <(_p2p_used_ports_stream)

    IFS=',' read -ra defaults <<< "$(get_default_p2p_ports_for_ipv4 "$ipv4" "$count")"
    local out=()
    for p in "${defaults[@]}"; do
        validate_p2p_port "$p" || continue
        if [[ -z "${used[$p]+x}" && -z "${picked[$p]+x}" ]]; then
            out+=("$p")
            picked["$p"]=1
        fi
        [[ "${#out[@]}" -ge "$count" ]] && break
    done
    while [[ "${#out[@]}" -lt "$count" ]]; do
        extra=$(get_next_p2p_port) || break
        used["$extra"]=1
        picked["$extra"]=1
        out+=("$extra")
    done
    (IFS=','; echo "${out[*]}")
}

get_next_client_ipv6() {
    awg_ipv6_enabled || return 1
    local subnet="$AWG_IPV6_SUBNET" wan mode
    wan="$(get_main_nic 2>/dev/null || true)"
    mode="$(awg_ipv6_effective_mode)"
    python3 - "$subnet" "$SERVER_CONF_FILE" "${AWG_DIR:-}" "$wan" "$mode" <<'PY'
import ipaddress, os, re, subprocess, sys
from pathlib import Path

net = ipaddress.ip_network(sys.argv[1], strict=False)
server_conf, awg_dir, wan, mode = sys.argv[2:6]
server_offset = 0x100 if mode == "ndp" else 1
used = {net.network_address, net.network_address + server_offset}

def reserve_token(token):
    try:
        addr = ipaddress.ip_interface(token).ip if "/" in token else ipaddress.ip_address(token)
    except ValueError:
        return
    if addr.version == 6 and addr in net:
        used.add(addr)

paths = [Path(server_conf)]
if awg_dir:
    paths.extend(Path(awg_dir).glob("*.conf"))
for path in paths:
    try:
        data = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        continue
    for token in re.findall(r"(?:AllowedIPs|Address)\s*=\s*[^\n#]*?([0-9A-Fa-f:]+/128)", data):
        reserve_token(token)

if mode == "ndp":
    if wan:
        try:
            out = subprocess.run(["ip", "-6", "-o", "addr", "show", "dev", wan, "scope", "global"], capture_output=True, text=True, timeout=2, check=False).stdout
            for token in re.findall(r"inet6\s+([0-9A-Fa-f:]+/\d+)", out):
                reserve_token(token)
        except Exception:
            pass
    try:
        out = subprocess.run(["ip", "-6", "route", "show", "default"], capture_output=True, text=True, timeout=2, check=False).stdout
        for token in re.findall(r"\bvia\s+([0-9A-Fa-f:]+)", out):
            reserve_token(token)
    except Exception:
        pass

start = 0x101 if mode == "ndp" else 2
limit = min(net.num_addresses - 1, 65535)
for i in range(start, limit + 1):
    cand = net.network_address + i
    if cand not in used:
        print(cand)
        sys.exit(0)
sys.exit(1)
PY
}

_peer_inventory_tsv() {
    [[ -f "$SERVER_CONF_FILE" ]] || return 0
    local include_disabled="${1:-0}"
    awk -v include_disabled="$include_disabled" '
    function flush() {
        if (name != "") print name "\t" allowed "\t" ports
    }
    /^\[Peer\]/ { flush(); name=""; allowed=""; ports=""; in_peer=1; next }
    /^\[/ && !/^\[Peer\]/ { flush(); name=""; allowed=""; ports=""; in_peer=0; next }
    in_peer && /^#_Name = / { name=$0; sub(/^#_Name = /, "", name); next }
    in_peer && /^#_P2PPorts[[:space:]]*=/ { ports=$0; sub(/^#_P2PPorts[[:space:]]*=[[:space:]]*/, "", ports); next }
    include_disabled != "0" && in_peer && /^#_P2PPorts_Disabled[[:space:]]*=/ { ports=$0; sub(/^#_P2PPorts_Disabled[[:space:]]*=[[:space:]]*/, "", ports); next }
    in_peer && /^AllowedIPs[[:space:]]*=/ { allowed=$0; sub(/^AllowedIPs[[:space:]]*=[[:space:]]*/, "", allowed); next }
    END { flush() }
    ' "$SERVER_CONF_FILE"
}

generate_firewall_scripts() {
    local nic="${1:-}"
    [[ -n "$nic" ]] || nic=$(get_main_nic)
    [[ -n "$nic" ]] || nic="eth0"
    mkdir -p "$AWG_DIR" || return 1

    local postup="$AWG_DIR/postup.sh"
    local postdown="$AWG_DIR/postdown.sh"
    local p2p="$AWG_DIR/p2p_rules.sh"
    local tmp

    tmp=$(awg_mktemp) || return 1
    cat > "$tmp" << EOF
#!/bin/bash
# Auto-generated by awg_common.sh. Do not edit manually.
set +e
NIC="\${AWG_MAIN_NIC:-${nic}}"
AWG_IFACE="\${AWG_IFACE:-awg0}"
FULLCONE="${AWG_FULLCONE_NAT:-0}"
IPV6_ENABLED="${AWG_IPV6_ENABLED:-0}"
IPV6_MODE="${AWG_IPV6_MODE:-legacy}"
IPV6_SUBNET="${AWG_IPV6_SUBNET:-}"
AWG_MTU="${AWG_MTU:-1280}"
MSS4="$(( ${AWG_MTU:-1280} - 40 ))"
MSS6="$(( ${AWG_MTU:-1280} - 60 ))"
P2P_RULES="${p2p}"
SERVER_CONF_FILE="${SERVER_CONF_FILE:-/etc/amnezia/amneziawg/awg0.conf}"

case "\$IPV6_MODE" in
    native) IPV6_MODE="ndp" ;;
    ula) IPV6_MODE="nat66" ;;
esac

ipt_add() { local table="\$1" chain="\$2"; shift 2; iptables -t "\$table" -C "\$chain" "\$@" 2>/dev/null || iptables -t "\$table" -A "\$chain" "\$@"; }
ipt_ins() { local chain="\$1"; shift; iptables -C "\$chain" "\$@" 2>/dev/null || iptables -I "\$chain" "\$@"; }
ip6t_add() { local table="\$1" chain="\$2"; shift 2; ip6tables -t "\$table" -C "\$chain" "\$@" 2>/dev/null || ip6tables -t "\$table" -A "\$chain" "\$@"; }
ip6t_ins() { local chain="\$1"; shift; ip6tables -C "\$chain" "\$@" 2>/dev/null || ip6tables -I "\$chain" "\$@"; }
ndp_peer_ipv6_routes() {
    [[ -f "\$SERVER_CONF_FILE" ]] || return 0
    awk '/^AllowedIPs[[:space:]]*=/{gsub(/,/, " "); for (i=1; i<=NF; i++) if (\$i ~ /^[0-9A-Fa-f:]+\\/128$/) print \$i}' "\$SERVER_CONF_FILE"
}

if [[ "\$FULLCONE" == "1" ]]; then
    if ! ipt_add nat POSTROUTING -o "\$NIC" -j FULLCONENAT; then
        ipt_add nat POSTROUTING -o "\$NIC" -j MASQUERADE
    else
        ipt_add nat PREROUTING -i "\$NIC" -j FULLCONENAT
    fi
else
    ipt_add nat POSTROUTING -o "\$NIC" -j MASQUERADE
fi

ipt_ins FORWARD -i "\$AWG_IFACE" -j ACCEPT
ipt_ins FORWARD -o "\$AWG_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
ipt_add mangle FORWARD -o "\$AWG_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "\$MSS4"
ipt_add mangle FORWARD -i "\$AWG_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "\$MSS4"

if [[ "\$IPV6_ENABLED" == "1" ]]; then
    ip6t_ins FORWARD -i "\$AWG_IFACE" -j ACCEPT
    ip6t_ins FORWARD -o "\$AWG_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
    ip6t_ins FORWARD -i "\$NIC" -o "\$AWG_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
    ip6t_add mangle FORWARD -o "\$AWG_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "\$MSS6"
    ip6t_add mangle FORWARD -i "\$AWG_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "\$MSS6"
    if [[ "\$IPV6_MODE" == "nat66" && -n "\$IPV6_SUBNET" ]]; then
        ip6t_add nat POSTROUTING -s "\$IPV6_SUBNET" -o "\$NIC" -j MASQUERADE
    fi
    if [[ "\$IPV6_MODE" == "nat66" ]]; then
        ip6tables -C FORWARD -i "\$NIC" -o "\$AWG_IFACE" -m state --state NEW -j DROP 2>/dev/null || \
            ip6tables -A FORWARD -i "\$NIC" -o "\$AWG_IFACE" -m state --state NEW -j DROP
    fi
    if [[ "\$IPV6_MODE" == "ndp" ]]; then
        while IFS= read -r route; do
            [[ -n "\$route" ]] || continue
            ip -6 route replace "\$route" dev "\$AWG_IFACE"
            ip -6 neigh replace proxy "\${route%/128}" dev "\$NIC" 2>/dev/null || true
        done < <(ndp_peer_ipv6_routes)
    fi
fi

[[ -x "\$P2P_RULES" ]] && "\$P2P_RULES" up
exit 0
EOF
    mv -f "$tmp" "$postup" || return 1
    chmod 700 "$postup" 2>/dev/null || true

    tmp=$(awg_mktemp) || return 1
    cat > "$tmp" << EOF
#!/bin/bash
# Auto-generated by awg_common.sh. Do not edit manually.
set +e
NIC="\${AWG_MAIN_NIC:-${nic}}"
AWG_IFACE="\${AWG_IFACE:-awg0}"
IPV6_ENABLED="${AWG_IPV6_ENABLED:-0}"
IPV6_MODE="${AWG_IPV6_MODE:-legacy}"
IPV6_SUBNET="${AWG_IPV6_SUBNET:-}"
AWG_MTU="${AWG_MTU:-1280}"
MSS4="$(( ${AWG_MTU:-1280} - 40 ))"
MSS6="$(( ${AWG_MTU:-1280} - 60 ))"
P2P_RULES="${p2p}"
SERVER_CONF_FILE="${SERVER_CONF_FILE:-/etc/amnezia/amneziawg/awg0.conf}"

case "\$IPV6_MODE" in
    native) IPV6_MODE="ndp" ;;
    ula) IPV6_MODE="nat66" ;;
esac

del_ipt_nat() { local chain="\$1"; shift; while iptables -t nat -C "\$chain" "\$@" 2>/dev/null; do iptables -t nat -D "\$chain" "\$@"; done; }
del_ipt_table() { local table="\$1" chain="\$2"; shift 2; while iptables -t "\$table" -C "\$chain" "\$@" 2>/dev/null; do iptables -t "\$table" -D "\$chain" "\$@"; done; }
del_ipt() { local chain="\$1"; shift; while iptables -C "\$chain" "\$@" 2>/dev/null; do iptables -D "\$chain" "\$@"; done; }
del_ip6t_nat() { local chain="\$1"; shift; while ip6tables -t nat -C "\$chain" "\$@" 2>/dev/null; do ip6tables -t nat -D "\$chain" "\$@"; done; }
del_ip6t_table() { local table="\$1" chain="\$2"; shift 2; while ip6tables -t "\$table" -C "\$chain" "\$@" 2>/dev/null; do ip6tables -t "\$table" -D "\$chain" "\$@"; done; }
del_ip6t() { local chain="\$1"; shift; while ip6tables -C "\$chain" "\$@" 2>/dev/null; do ip6tables -D "\$chain" "\$@"; done; }
ndp_peer_ipv6_routes() {
    [[ -f "\$SERVER_CONF_FILE" ]] || return 0
    awk '/^AllowedIPs[[:space:]]*=/{gsub(/,/, " "); for (i=1; i<=NF; i++) if (\$i ~ /^[0-9A-Fa-f:]+\\/128$/) print \$i}' "\$SERVER_CONF_FILE"
}

[[ -x "\$P2P_RULES" ]] && "\$P2P_RULES" down

if [[ "\$WEB_ENABLED" == "1" ]]; then
    {
        ip -4 -o addr show scope global 2>/dev/null | awk '{split(\$4,a,"/"); print a[1]}'
        ip -4 -o addr show dev "\$AWG_IFACE" 2>/dev/null | awk '{split(\$4,a,"/"); print a[1]}'
    } | while IFS= read -r panel_addr; do
        [[ -n "\$panel_addr" ]] || continue
        for panel_port in 80 443 "\$PANEL_WEB_PORT"; do
            :
        done
    done
fi

del_ipt_nat PREROUTING -i "\$NIC" -j FULLCONENAT
del_ipt_nat POSTROUTING -o "\$NIC" -j FULLCONENAT
del_ipt_nat POSTROUTING -o "\$NIC" -j MASQUERADE
del_ipt FORWARD -i "\$AWG_IFACE" -j ACCEPT
del_ipt FORWARD -o "\$AWG_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
del_ipt_table mangle FORWARD -o "\$AWG_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "\$MSS4"
del_ipt_table mangle FORWARD -i "\$AWG_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "\$MSS4"

if [[ "\$IPV6_ENABLED" == "1" ]]; then
    if [[ "\$IPV6_MODE" == "ndp" ]]; then
        while IFS= read -r route; do
            [[ -n "\$route" ]] || continue
            ip -6 route del "\$route" dev "\$AWG_IFACE" 2>/dev/null || true
            ip -6 neigh del proxy "\${route%/128}" dev "\$NIC" 2>/dev/null || true
        done < <(ndp_peer_ipv6_routes)
    fi
    del_ip6t FORWARD -i "\$AWG_IFACE" -j ACCEPT
    del_ip6t FORWARD -o "\$AWG_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
    del_ip6t FORWARD -i "\$NIC" -o "\$AWG_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
    del_ip6t_table mangle FORWARD -o "\$AWG_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "\$MSS6"
    del_ip6t_table mangle FORWARD -i "\$AWG_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "\$MSS6"
    del_ip6t FORWARD -i "\$NIC" -o "\$AWG_IFACE" -m state --state NEW -j DROP
    if [[ "\$IPV6_MODE" == "nat66" && -n "\$IPV6_SUBNET" ]]; then
        del_ip6t_nat POSTROUTING -s "\$IPV6_SUBNET" -o "\$NIC" -j MASQUERADE
    fi
fi
exit 0
EOF
    mv -f "$tmp" "$postdown" || return 1
    chmod 700 "$postdown" 2>/dev/null || true

    tmp=$(awg_mktemp) || return 1
    cat > "$tmp" << EOF
#!/bin/bash
# Auto-generated P2P rules for AmneziaWG clients. Do not edit manually.
set +e
ACTION="\${1:-up}"
NIC="\${AWG_MAIN_NIC:-${nic}}"
AWG_IFACE="\${AWG_IFACE:-awg0}"
IPV6_MODE="${AWG_IPV6_MODE:-legacy}"

case "\$IPV6_MODE" in
    native) IPV6_MODE="ndp" ;;
    ula) IPV6_MODE="nat66" ;;
esac

ipt_nat_add() { local chain="\$1"; shift; iptables -t nat -C "\$chain" "\$@" 2>/dev/null || iptables -t nat -A "\$chain" "\$@"; }
ipt_nat_del() { local chain="\$1"; shift; while iptables -t nat -C "\$chain" "\$@" 2>/dev/null; do iptables -t nat -D "\$chain" "\$@"; done; }
ipt_fwd_add() { iptables -C FORWARD "\$@" 2>/dev/null || iptables -I FORWARD "\$@"; }
ipt_fwd_del() { while iptables -C FORWARD "\$@" 2>/dev/null; do iptables -D FORWARD "\$@"; done; }
ip6t_nat_add() { local chain="\$1"; shift; ip6tables -t nat -C "\$chain" "\$@" 2>/dev/null || ip6tables -t nat -A "\$chain" "\$@"; }
ip6t_nat_del() { local chain="\$1"; shift; while ip6tables -t nat -C "\$chain" "\$@" 2>/dev/null; do ip6tables -t nat -D "\$chain" "\$@"; done; }
ip6t_fwd_add() { ip6tables -C FORWARD "\$@" 2>/dev/null || ip6tables -I FORWARD "\$@"; }
ip6t_fwd_del() { while ip6tables -C FORWARD "\$@" 2>/dev/null; do ip6tables -D FORWARD "\$@"; done; }

case "\$ACTION" in up|down) ;; *) exit 2 ;; esac
EOF

    local name allowed ports part ipv4 ipv6 p external_port internal_port parsed
    while IFS=$'\t' read -r name allowed ports; do
        [[ -n "$name" && -n "$allowed" && -n "$ports" ]] || continue
        ipv4=""; ipv6=""
        IFS=',' read -ra _allowed_parts <<< "$allowed"
        for part in "${_allowed_parts[@]}"; do
            part="${part//[[:space:]]/}"
            [[ "$part" =~ ^([0-9.]+)/32$ ]] && ipv4="${BASH_REMATCH[1]}"
            [[ "$part" == *:* && "$part" == */128 ]] && ipv6="${part%/128}"
        done
        [[ -n "$ipv4" ]] || continue
        ports="${ports//[[:space:]]/}"
        IFS=',' read -ra _ports <<< "$ports"
        {
            echo ""
            echo "# Client: ${name} (${ipv4}${ipv6:+ / ${ipv6}}, P2P: ${ports})"
            echo 'if [[ "$ACTION" == "up" ]]; then'
            for p in "${_ports[@]}"; do
                parsed=$(parse_p2p_forward_spec "$p") || continue
                IFS=$'\t' read -r external_port internal_port <<< "$parsed"
                echo "    ipt_nat_add PREROUTING -i \"\$NIC\" -p tcp --dport ${external_port} -j DNAT --to-destination ${ipv4}:${internal_port}"
                echo "    ipt_nat_add PREROUTING -i \"\$NIC\" -p udp --dport ${external_port} -j DNAT --to-destination ${ipv4}:${internal_port}"
                echo "    ipt_fwd_add -i \"\$NIC\" -o \"\$AWG_IFACE\" -d ${ipv4} -p tcp --dport ${internal_port} -j ACCEPT"
                echo "    ipt_fwd_add -i \"\$NIC\" -o \"\$AWG_IFACE\" -d ${ipv4} -p udp --dport ${internal_port} -j ACCEPT"
                echo "    ipt_nat_add POSTROUTING -o \"\$AWG_IFACE\" -d ${ipv4} -p tcp --dport ${internal_port} -j MASQUERADE"
                echo "    ipt_nat_add POSTROUTING -o \"\$AWG_IFACE\" -d ${ipv4} -p udp --dport ${internal_port} -j MASQUERADE"
                if [[ -n "$ipv6" ]]; then
                    if [[ "$(awg_ipv6_mode)" == "nat66" ]]; then
                        echo "    ip6t_nat_add PREROUTING -i \"\$NIC\" -p tcp --dport ${external_port} -j DNAT --to-destination ${ipv6}"
                        echo "    ip6t_nat_add PREROUTING -i \"\$NIC\" -p udp --dport ${external_port} -j DNAT --to-destination ${ipv6}"
                    fi
                    echo "    ip6t_fwd_add -i \"\$NIC\" -o \"\$AWG_IFACE\" -d ${ipv6} -p tcp --dport ${internal_port} -j ACCEPT"
                    echo "    ip6t_fwd_add -i \"\$NIC\" -o \"\$AWG_IFACE\" -d ${ipv6} -p udp --dport ${internal_port} -j ACCEPT"
                fi
            done
            echo "else"
            for p in "${_ports[@]}"; do
                parsed=$(parse_p2p_forward_spec "$p") || continue
                IFS=$'\t' read -r external_port internal_port <<< "$parsed"
                echo "    ipt_nat_del PREROUTING -i \"\$NIC\" -p tcp --dport ${external_port} -j DNAT --to-destination ${ipv4}:${internal_port}"
                echo "    ipt_nat_del PREROUTING -i \"\$NIC\" -p udp --dport ${external_port} -j DNAT --to-destination ${ipv4}:${internal_port}"
                echo "    ipt_fwd_del -i \"\$NIC\" -o \"\$AWG_IFACE\" -d ${ipv4} -p tcp --dport ${internal_port} -j ACCEPT"
                echo "    ipt_fwd_del -i \"\$NIC\" -o \"\$AWG_IFACE\" -d ${ipv4} -p udp --dport ${internal_port} -j ACCEPT"
                echo "    ipt_nat_del POSTROUTING -o \"\$AWG_IFACE\" -d ${ipv4} -p tcp --dport ${internal_port} -j MASQUERADE"
                echo "    ipt_nat_del POSTROUTING -o \"\$AWG_IFACE\" -d ${ipv4} -p udp --dport ${internal_port} -j MASQUERADE"
                if [[ -n "$ipv6" ]]; then
                    if [[ "$(awg_ipv6_mode)" == "nat66" ]]; then
                        echo "    ip6t_nat_del PREROUTING -i \"\$NIC\" -p tcp --dport ${external_port} -j DNAT --to-destination ${ipv6}"
                        echo "    ip6t_nat_del PREROUTING -i \"\$NIC\" -p udp --dport ${external_port} -j DNAT --to-destination ${ipv6}"
                    fi
                    echo "    ip6t_fwd_del -i \"\$NIC\" -o \"\$AWG_IFACE\" -d ${ipv6} -p tcp --dport ${internal_port} -j ACCEPT"
                    echo "    ip6t_fwd_del -i \"\$NIC\" -o \"\$AWG_IFACE\" -d ${ipv6} -p udp --dport ${internal_port} -j ACCEPT"
                fi
            done
            echo "fi"
        } >> "$tmp"
    done < <(_peer_inventory_tsv)
    echo "exit 0" >> "$tmp"
    mv -f "$tmp" "$p2p" || return 1
    chmod 700 "$p2p" 2>/dev/null || true
    return 0
}

# Note: apt_update_tolerant() определена inline в install_amneziawg.sh
# (нужна в шагах 1-2 до скачивания этого файла). Здесь её нет — мёртвый код.

# ==============================================================================
# Генерация AWG 2.0 параметров (используется в тестах + manage)
# ==============================================================================

# Случайное число [min, max] через /dev/urandom (поддержка uint32).
# Дублирует install_amneziawg.sh:rand_range — нужно здесь для тестов и regen.
rand_range() {
    local min=$1 max=$2
    local range=$((max - min + 1))
    local random_val
    random_val=$(od -An -tu4 -N4 /dev/urandom 2>/dev/null | tr -d ' ')
    if [[ -z "$random_val" || ! "$random_val" =~ ^[0-9]+$ ]]; then
        # Fallback: три $RANDOM (15 бит каждый) с XOR-перекрытием покрывают
        # биты 0-30, т.е. весь [0, 2^31-1]. Прежний вариант (RANDOM<<15|RANDOM)
        # давал только 30 бит - верхняя половина диапазона H никогда не выпадала.
        random_val=$(( (RANDOM << 16) ^ (RANDOM << 8) ^ RANDOM ))
    fi
    echo $(( (random_val % range) + min ))
}

# Генерация 4 непересекающихся диапазонов для AWG H1-H4.
# Алгоритм: 8 случайных значений → sort → 4 пары (low, high).
# Сортировка даёт low <= high; строгие проверки ниже гарантируют зазор между
# парами (касание границ = пересечение в одной точке) и нижнюю границу >= 5
# (значения 1-4 зарезервированы под типы сообщений vanilla WireGuard).
# Минимальная ширина каждого диапазона = 1000.
# Печатает 4 строки "low-high" в stdout. Возвращает 1 при неудаче.
# Защита от ТСПУ-фингерпринта по статическим H-значениям (#38).
#
# Диапазон: [0, 2^31-1] = [0, 2147483647]. Спецификация AmneziaWG
# допускает полный uint32 (0-4294967295), но standalone Windows-клиент
# `amneziawg-windows-client` имеет UI-валидатор ограниченный 2^31-1 в
# `ui/syntax/highlighter.go:isValidHField()` (upstream bug
# amnezia-vpn/amneziawg-windows-client#85, не исправлен). Значения
# выше 2^31-1 на сервере работают, но клиентский редактор подчёркивает
# их красным и не даёт сохранять правки. Для совместимости генерируем
# в безопасной половине диапазона (#40).
#
# Оптимизация: один вызов `od -N32 -tu4` читает 32 байта = 8 uint32 значений
# одной операцией, вместо 8 отдельных subprocess через rand_range.
# Fallback на rand_range если /dev/urandom недоступен.
generate_awg_h_ranges() {
    local attempt=0 max_attempts=20
    while (( attempt < max_attempts )); do
        local raw arr=() _v
        # Один read 32 байт из /dev/urandom = 8 uint32 значений
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
        # Fallback: 8 отдельных вызовов rand_range (если urandom недоступен)
        if (( ${#arr[@]} != 8 )); then
            arr=()
            local _i
            for _i in 1 2 3 4 5 6 7 8; do
                arr+=("$(rand_range 0 2147483647)")
            done
        fi
        # Сортировка
        local sorted
        sorted=$(printf '%s\n' "${arr[@]}" | sort -n)
        arr=()
        while IFS= read -r _v; do arr+=("$_v"); done <<< "$sorted"
        # Проверка: минимальная ширина каждой пары, строгий зазор между
        # парами (без касания границ) и нижняя граница вне зарезервированных
        # значений 1-4 (типы сообщений vanilla WireGuard).
        if (( ${arr[0]} >= 5 )) && \
           (( ${arr[1]} - ${arr[0]} >= 1000 )) && \
           (( ${arr[3]} - ${arr[2]} >= 1000 )) && \
           (( ${arr[5]} - ${arr[4]} >= 1000 )) && \
           (( ${arr[7]} - ${arr[6]} >= 1000 )) && \
           (( ${arr[2]} > ${arr[1]} )) && \
           (( ${arr[4]} > ${arr[3]} )) && \
           (( ${arr[6]} > ${arr[5]} )); then
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

# ==============================================================================
# DKMS / Автовосстановление модуля ядра amneziawg
# ==============================================================================

# awg_module_version : версия модуля amneziawg (пустая строка, если определить
# не удалось). Сначала спрашиваем ЗАГРУЖЕННЫЙ модуль, и только потом файл.
#
# ⚠️ Почему не просто modinfo: modinfo читает метаданные того .ko, который
# ВЫБРАН на диске по modules.dep, а не того объекта, что работает в ядре.
# В норме это одно и то же, поэтому расхождение не всплывало. Но если на хосте
# оказались ДВА дерева с модулем одного имени - закреплённый 2.0 в extra/ и
# DKMS-3.0 в updates/dkms/ - modinfo назовёт тот, что выиграл по приоритету
# поиска, а загружен может быть другой (например, прежний, до перезагрузки).
# Тогда наша же диагностика сообщила бы версию, которой в ядре нет.
# /sys/module/amneziawg/version отражает именно загруженное и существует в
# ОБЕИХ линиях: MODULE_VERSION(WIREGUARD_VERSION) объявлен в src/main.c и в
# закреплённом 2.0-теге, и в 3.0.
# modinfo остаётся вторым путём - он работает, когда модуль не загружен.
#
# AWG_MODULE_VERSION_PATH переопределяется только тестами (bats): подменить
# /sys иначе нельзя, а проверить надо именно приоритет «загруженное важнее файла».
awg_module_version() {
    local ver="" sysfile="${AWG_MODULE_VERSION_PATH:-/sys/module/amneziawg/version}"
    if [[ -r "$sysfile" ]]; then
        # ⚠️ `|| true`, а НЕ `|| ver=""`: на файле без завершающего перевода
        # строки read возвращает 1, УЖЕ присвоив прочитанное. Сброс в пустую
        # строку затёр бы верное значение и молча уронил нас на modinfo.
        # ⚠️ И `2>/dev/null` стоит ДО `<`, а не после: перенаправления
        # применяются слева направо, поэтому при обратном порядке ошибка
        # открытия файла успевает уйти в исходный stderr - проверено, сырая
        # строка `bash: ...` вылезала посреди вывода manage check.
        IFS= read -r ver 2>/dev/null < "$sysfile" || true
        ver="${ver//[[:space:]]/}"
        # 🔴 Файл был читаем - отвечаем тем, что он дал, даже если это пустота,
        # и на modinfo НЕ уходим. Подмена ответом с диска - ровно то, от чего
        # эта функция создана уходить: при двух деревьях modinfo назовёт версию,
        # которой в ядре нет, а diagnose на её основании объявит линию протокола.
        # Пустая версия честнее неверной: потребители печатают строку без версии.
        printf '%s' "$ver"
        return 0
    fi
    ver=$(modinfo amneziawg 2>/dev/null | awk '/^version:/{print $2; exit}')
    printf '%s' "$ver"
}

# awg_module_build_id : признак СБОРКИ загруженного модуля, одной строкой.
# Пустая строка, если ничего опознать не удалось.
#
# 🔴 Зачем это отдельно от awg_module_version. Строка версии модуля сборку НЕ
# различает: замер на стенде 30 aug 2026 дал `3.1.20260812` И для сборки PPA от
# 14 aug (`4680320`), И для сборки от 28 aug (`3c38e16`) - MODULE_VERSION статичен
# в исходниках и меняется реже, чем сам код. Различают только srcversion (хеш
# исходников, который считает сборщик модуля) и версия пакета.
# Без этого признака диагностический отчёт не отвечает на вопрос «какая у тебя
# сборка», а именно он нужен, когда расходятся модуль ядра и userspace-клиент.
#
# AWG_MODULE_SRCVERSION_PATH переопределяется только тестами: подменить /sys
# иначе нельзя, а проверить надо именно чтение загруженного модуля.
awg_module_build_id() {
    local build_src="" build_pkg="" build_out=""
    local sysfile="${AWG_MODULE_SRCVERSION_PATH:-/sys/module/amneziawg/srcversion}"
    if [[ -r "$sysfile" ]]; then
        # `|| true` по той же причине, что и в awg_module_version: на файле без
        # завершающего перевода строки read возвращает 1, УЖЕ присвоив прочитанное.
        IFS= read -r build_src 2>/dev/null < "$sysfile" || true
        build_src="${build_src//[[:space:]]/}"
    fi
    # Только ПЕРВАЯ строка: при нескольких совпадениях склейка дала бы
    # правдоподобную, но несуществующую версию, а это хуже отказа.
    build_pkg=$(dpkg-query -W -f='${Version}\n' amneziawg-dkms 2>/dev/null | head -n 1 || true)
    build_pkg="${build_pkg//[[:space:]]/}"
    # 🔴 Две части НАЗВАНЫ ПО-РАЗНОМУ намеренно: это разные вещи, и они
    # расходятся штатно. Пакет можно обновить, а модуль в памяти останется
    # прежним до перезагрузки или modprobe - ровно это наблюдалось на стенде
    # 30 aug 2026. Слить их в один «признак сборки» значило бы выдать версию
    # пакета за версию загруженного кода.
    [[ -n "$build_src" ]] && build_out="srcversion загруженного $build_src"
    if [[ -n "$build_pkg" ]]; then
        [[ -n "$build_out" ]] && build_out="$build_out; "
        build_out="${build_out}установлен пакет $build_pkg"
    fi
    printf '%s' "$build_out"
}

#
# После apt upgrade ядра DKMS-модуль должен пересобраться для нового kernel.
# Если это не произошло (или модуль был отвязан), 4 функции ниже выполняют
# idempotent восстановление:
#
#   _sanitize_awg_dkms_conf       — убрать deprecated REMAKE_INITRD= из dkms.conf
#   _install_kernel_headers       — distro-aware fallback chain (Ubuntu/Debian)
#   _ensure_awg_quick_running     — стартовать awg-quick@awg0 если неактивен
#   ensure_amneziawg_kernel_module — master, публичная точка входа
#
# === Контекст использования и safety contract ===
#
# Master ensure_amneziawg_kernel_module() исходит из того, что running kernel
# (uname -r) и есть target kernel — то есть подходит только для post-reboot
# контекстов: manage repair-module, manage add/remove (после reboot user'а),
# systemd unit (стартует на boot когда ядро уже новое). Из DPkg::Post-Invoke
# хука uname -r всё ещё возвращает СТАРОЕ ядро — для этого случая Phase 3
# Apt hook helper будет использовать отдельную обёртку, итерирующую target
# ядра через /lib/modules/*/build.
#
# Master НЕ вызывает apt-get install по умолчанию (это deadlock в любом
# контексте где parent держит /var/lib/dpkg/lock-frontend). Вызов apt
# гейтится переменной окружения AWG_ALLOW_APT_IN_ENSURE=1 — её устанавливает
# только install_amneziawg step 2 / manage repair-module. Apt hook helper
# и systemd unit её НЕ устанавливают, master skip'ит шаг с headers.
#
# Headers нужно ставить отдельно — на этапе install через мета-пакет
# (linux-headers-$(arch) для Debian, linux-headers-generic для Ubuntu) —
# apt сам подтянет matching headers при apt upgrade ядра.

# Удаление deprecated директивы REMAKE_INITRD= из dkms.conf модуля amneziawg.
# Современные версии DKMS считают её deprecated и печатают noisy warnings.
_sanitize_awg_dkms_conf() {
    local conf
    for conf in /var/lib/dkms/amneziawg/*/source/dkms.conf; do
        [[ -f "$conf" ]] && sed -i '/^REMAKE_INITRD=/d' "$conf"
    done
}

# Установка пакета kernel headers через distro-aware fallback chain.
# Аргумент: версия ядра (по умолчанию $(uname -r)).
# Возвращает: 0 если хотя бы один кандидат установлен успешно, 1 если все провалились.
#
# ВАЖНО: вызывается только из контекстов где apt lock доступен (install_amneziawg
# step 2 или manage repair-module). НЕ должна вызываться из DPkg::Post-Invoke хука.
#
# Поддерживается распознавание Raspberry Pi Foundation kernel (+rpt/-rpi suffix):
# linux-headers-rpi-2712 (Pi 5 / Cortex-A76) или linux-headers-rpi-v8 (Pi 3/4 arm64).
_install_kernel_headers() {
    # Defense-in-depth: эта функция вызывает apt-get install и не должна
    # запускаться из hook-context (deadlock на dpkg lock). Master уже гейтит
    # её через AWG_ALLOW_APT_IN_ENSURE, но _ префикс не enforced — добавляем
    # тот же гард сюда чтобы случайный direct call из чужого скрипта не
    # обошёл защиту.
    if [[ "${AWG_ALLOW_APT_IN_ENSURE:-0}" != "1" ]]; then
        log_error "_install_kernel_headers: AWG_ALLOW_APT_IN_ENSURE не выставлен — apt-вызов запрещён в этом контексте."
        return 1
    fi

    local kernel_ver="${1:-$(uname -r)}"
    local candidates=()

    # RPi Foundation kernel (suffix +rpt или -rpi) — отдельный мета-пакет
    # независимо от distro. Pattern check order: 2712 → v7l → v7 → v8 (default).
    if [[ "$kernel_ver" == *+rpt* || "$kernel_ver" == *-rpi* ]]; then
        if [[ "$kernel_ver" == *2712* ]]; then
            candidates+=("linux-headers-rpi-2712")  # Pi 5 / Cortex-A76
        elif [[ "$kernel_ver" == *-rpi-v7l* ]]; then
            candidates+=("linux-headers-rpi-v7l")   # armhf 32-bit (LPAE)
        elif [[ "$kernel_ver" == *-rpi-v7* ]]; then
            candidates+=("linux-headers-rpi-v7")    # armhf 32-bit older
        else
            candidates+=("linux-headers-rpi-v8")    # Pi 3/4 arm64 default
        fi
    fi

    case "${OS_ID:-}" in
        ubuntu)
            candidates+=(
                "linux-headers-${kernel_ver}"
                "linux-headers-generic"
                "raspberrypi-kernel-headers"
            )
            ;;
        debian)
            local arch
            arch=$(dpkg --print-architecture 2>/dev/null)
            candidates+=("linux-headers-${kernel_ver}")
            if [[ -n "$arch" ]]; then
                # Cloud-images Debian используют отдельный мета-пакет
                # linux-headers-cloud-${arch} вместо обычного linux-headers-${arch}
                # (kernel ABI в них другая — sched/IRQ-таймеры урезаны под VM).
                # Prefer cloud-meta когда running kernel явно cloud — иначе
                # repair-module падает на AWS/Azure/GCP/cloud-Hetzner после
                # kernel upgrade, хотя headers доступны через cloud-meta.
                if [[ "$kernel_ver" == *-cloud-* ]]; then
                    candidates+=("linux-headers-cloud-${arch}")
                fi
                candidates+=("linux-headers-${arch}")
            fi
            ;;
        *)
            log_error "Установка kernel headers: неизвестный OS_ID='${OS_ID:-}' (поддерживаются только ubuntu/debian)."
            return 1
            ;;
    esac

    local pkg
    for pkg in "${candidates[@]}"; do
        if apt-get install -y "$pkg" >/dev/null 2>&1; then
            log "Установлены kernel headers: $pkg"
            return 0
        fi
        log_warn "Не удалось установить $pkg, пробую следующий кандидат..."
    done
    log_error "Не удалось установить ни один из пакетов kernel headers (${candidates[*]})."
    return 1
}

# Запуск awg-quick@<iface>, если сервис не активен.
# Аргумент: имя интерфейса (по умолчанию awg0).
# Возвращает: 0 при успешном старте или если сервис уже активен, 1 при сбое.
_ensure_awg_quick_running() {
    local iface="${1:-awg0}"
    local svc="awg-quick@${iface}.service"

    if systemctl is-active --quiet "$svc"; then
        return 0
    fi

    log "Запуск $svc (был неактивен)..."
    if systemctl start "$svc"; then
        log "$svc запущен."
        return 0
    fi
    log_error "Не удалось запустить $svc. Подробности: systemctl status $svc"
    return 1
}

# Master: гарантирует что модуль ядра amneziawg собран и загружен для running kernel.
# Idempotent: fast-path возвращает 0 если модуль уже loaded.
#
# Аргумент: режим — "full" (по умолчанию: модуль + старт awg-quick) или
#                  "module-only" (только модуль, без старта сервиса).
#
# ВАЖНО: master рассчитан на post-reboot контексты (manage repair-module,
# manage add/remove после reboot, systemd unit на boot). Apt/dpkg хук код
# НЕ должен звать master — uname -r в Post-Invoke возвращает старое ядро,
# поэтому хук должен использовать отдельную обёртку, итерирующую target
# kernels через /lib/modules/*/build (Phase 3 helper).
#
# Окружение: AWG_ALLOW_APT_IN_ENSURE=1 разрешает шаг установки kernel headers
# через apt-get install (опасно в hook context — deadlock на dpkg lock).
# Не установлено → шаг с headers пропускается с warn (предполагается что
# headers уже на диске через мета-пакет linux-headers-$(arch)).
#
# При необходимости запускает 5-шаговое восстановление:
#   headers → sanitize → dkms autoinstall → depmod → modprobe.
#
# Возвращает:
#   0 — модуль успешно загружен (и в "full" режиме awg-quick активен).
#   1 — финальный modprobe провалился, либо невалидный режим
#       (с печатью 4-шагового manual recovery).
#   2 - только "full": модуль в порядке, но awg-quick@awg0 не стартовал
#       (сервис-проблема: битый конфиг, занятый порт и т.п.). Раньше это
#       гасилось в log_warn + return 0, и repair-module рапортовал
#       "сервис активен" при лежащем сервисе (Issue #175).
ensure_amneziawg_kernel_module() {
    local mode="${1:-full}"
    case "$mode" in
        full|module-only) ;;
        *)
            log_error "ensure_amneziawg_kernel_module: невалидный режим '$mode' (ожидается 'full' или 'module-only')."
            return 1
            ;;
    esac
    local kernel_ver
    kernel_ver="$(uname -r)"

    # Fast-path: модуль уже загружен.
    if lsmod 2>/dev/null | awk '{print $1}' | grep -qx 'amneziawg'; then
        if [[ "$mode" == "full" ]]; then
            _ensure_awg_quick_running awg0 || {
                log_warn "Модуль активен, но awg-quick@awg0 не стартовал (модуль OK, это сервис-проблема)."
                return 2
            }
        fi
        return 0
    fi

    # Модуль на диске для running kernel — пробуем modprobe до full repair.
    if find "/lib/modules/${kernel_ver}" -name 'amneziawg.ko*' -print -quit 2>/dev/null | grep -q .; then
        if modprobe amneziawg 2>/dev/null && \
           lsmod 2>/dev/null | awk '{print $1}' | grep -qx 'amneziawg'; then
            log "amneziawg-модуль найден на диске и успешно загружен."
            if [[ "$mode" == "full" ]]; then
                _ensure_awg_quick_running awg0 || {
                    log_warn "Модуль загружен, но awg-quick@awg0 не стартовал (модуль OK, это сервис-проблема)."
                    return 2
                }
            fi
            return 0
        fi
    fi

    log_warn "amneziawg-модуль не загружен и не собран для ядра ${kernel_ver}."
    log_warn "Запускаю автоматическое восстановление..."

    # Step 1: kernel headers — только если apt разрешён вызвавшим контекстом.
    if [[ "${AWG_ALLOW_APT_IN_ENSURE:-0}" == "1" ]]; then
        case "${OS_ID:-}" in
            ubuntu|debian)
                local headers_pkg="linux-headers-${kernel_ver}"
                if ! dpkg-query -W -f='${Status}' "$headers_pkg" 2>/dev/null | grep -q 'install ok installed'; then
                    log "Kernel headers ($headers_pkg) не установлены. Устанавливаю..."
                    _install_kernel_headers "$kernel_ver" || \
                        log_warn "Не удалось установить kernel headers. Сборка DKMS-модуля может провалиться."
                fi
                ;;
        esac
    elif [[ ! -d "/lib/modules/${kernel_ver}/build" ]]; then
        log_warn "/lib/modules/${kernel_ver}/build отсутствует, headers не установлены."
        log_warn "Apt-установка пропущена (контекст не разрешает apt). Сборка DKMS-модуля скорее всего провалится."
    fi

    # Step 2: убрать deprecated REMAKE_INITRD из dkms.conf
    _sanitize_awg_dkms_conf

    # Step 3: dkms autoinstall для running kernel.
    # Если шаг ошибётся, всё равно пробуем modprobe ниже — он окончательный indicator.
    if command -v dkms >/dev/null 2>&1; then
        log "Запуск: dkms autoinstall -k ${kernel_ver}"
        if ! dkms autoinstall -k "${kernel_ver}" >/dev/null 2>&1; then
            log_warn "dkms autoinstall завершился с ошибкой для ядра ${kernel_ver}."
            local dkms_log
            dkms_log=$(find /var/lib/dkms/amneziawg -name 'make.log' -path "*${kernel_ver}*" 2>/dev/null | head -n 1)
            if [[ -n "$dkms_log" ]]; then
                log_warn "Последние 20 строк лога сборки DKMS (${dkms_log}):"
                tail -20 "$dkms_log" | while IFS= read -r line; do log_warn "  $line"; done
            else
                log_warn "Лог сборки не найден. Подробности в /var/lib/dkms/amneziawg/."
            fi
        fi
    else
        log_warn "Пакет dkms не установлен. Пересборка модуля ядра невозможна."
    fi

    # Step 4: обновить module dependency cache для конкретного ядра.
    if command -v depmod >/dev/null 2>&1; then
        depmod -a "$kernel_ver" >/dev/null 2>&1 || \
            log_warn "depmod -a $kernel_ver завершился с ошибкой; modprobe ниже даст финальный диагноз."
    fi

    # Step 5: финальная попытка modprobe.
    if ! modprobe amneziawg 2>/dev/null; then
        log_error "Модуль ядра amneziawg не удалось загрузить для ядра ${kernel_ver}."
        log_error "Модуль отсутствует в /lib/modules/${kernel_ver}/."
        log_error "Ручное восстановление:"
        log_error "  1. apt install -y \"linux-headers-${kernel_ver}\""
        log_error "  2. dkms autoinstall -k \"${kernel_ver}\" && depmod -a"
        log_error "  3. modprobe amneziawg"
        log_error "  4. systemctl start \"awg-quick@awg0\""
        return 1
    fi

    log "Модуль amneziawg успешно загружен для ядра ${kernel_ver}."
    if [[ "$mode" == "full" ]]; then
        _ensure_awg_quick_running awg0 || {
            log_warn "Модуль загружен, но awg-quick@awg0 не стартовал (модуль OK, это сервис-проблема)."
            return 2
        }
    fi
    return 0
}

# ==============================================================================
# Диагностика готовности окружения к AmneziaWG (VPN readiness)
# ==============================================================================

# Печатает чек-лист готовности хоста к AmneziaWG: модуль ядра, аппаратное
# ускорение криптографии, виртуализация, IP forwarding, UDP-буферы, WAN
# offloads, IPv6-маршрутизация и NDP proxy (ndppd). Только диагностика:
# ничего не меняет на хосте и всегда возвращает 0, чтобы не прерывать
# установку даже при найденных проблемах (см. install_amneziawg.sh step99).
print_vpn_readiness_checklist() {
    log "--- Проверка готовности к AmneziaWG (VPN readiness) ---"

    # 1. Модуль ядра amneziawg/wireguard
    local mods has_awg=0 has_wg=0
    mods="$(lsmod 2>/dev/null | awk '{print $1}')"
    { grep -qx 'amneziawg' <<<"$mods"; } && has_awg=1
    [[ -d /sys/module/amneziawg ]] && has_awg=1
    { grep -qx 'wireguard' <<<"$mods"; } && has_wg=1
    [[ -d /sys/module/wireguard ]] && has_wg=1
    if [[ "$has_awg" -eq 1 ]]; then
        log "  [OK]   Kernel module: amneziawg загружен (ядро $(uname -r))"
    elif [[ "$has_wg" -eq 1 ]]; then
        log "  [OK]   Kernel module: wireguard загружен (ядро $(uname -r))"
    else
        log_warn "  [WARN] Kernel module: amneziawg/wireguard не обнаружен (возможна userspace-реализация)"
    fi

    # 2. Аппаратное ускорение криптографии (CPU flags)
    local arch flags accel="" fast=0
    arch="$(uname -m)"
    flags=" $(awk -F: '/^(flags|Features)[[:space:]]*:/ {print $2; exit}' /proc/cpuinfo 2>/dev/null) "
    case "$arch" in
        x86_64|amd64|i386|i686)
            for f in aes avx avx2 bmi2 adx rdrand pclmulqdq; do
                [[ "$flags" == *" $f "* ]] && accel="${accel:+$accel }$f"
            done
            [[ "$flags" == *" aes "* && "$flags" == *" avx2 "* ]] && fast=1
            ;;
        arm*|aarch64)
            for f in aes pmull sha1 sha2 asimd; do
                [[ "$flags" == *" $f "* ]] && accel="${accel:+$accel }$f"
            done
            [[ "$flags" == *" aes "* && "$flags" == *" asimd "* ]] && fast=1
            ;;
    esac
    if [[ "$fast" -eq 1 ]]; then
        log "  [OK]   Crypto: аппаратное ускорение шифрования доступно (${arch}: ${accel})"
    elif [[ -n "$accel" ]]; then
        log "  [INFO] Crypto: частичное ускорение шифрования (${arch}: ${accel})"
    else
        log_warn "  [WARN] Crypto: аппаратное ускорение шифрования не обнаружено (${arch}) — AmneziaWG будет использовать программную криптографию"
    fi

    # 3. Виртуализация (информационно)
    local virt
    virt="$(systemd-detect-virt 2>/dev/null || echo unknown)"
    log "  [INFO] Virtualization: ${virt}"

    # 4. IP forwarding (критично для VPN-маршрутизации)
    local v4fwd v6fwd
    v4fwd="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
    v6fwd="$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo 0)"
    if [[ "$v4fwd" == "1" ]]; then
        log "  [OK]   IP forwarding: IPv4 включён (IPv6: $([[ "$v6fwd" == "1" ]] && echo on || echo off))"
    else
        log_error "  [FAIL] IP forwarding: net.ipv4.ip_forward=0 — маршрутизация трафика VPN-клиентов не будет работать"
    fi

    # 5. UDP-буферы ядра
    local rmem wmem recommended=2500000
    rmem="$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo 0)"
    wmem="$(cat /proc/sys/net/core/wmem_max 2>/dev/null || echo 0)"
    if [[ "$rmem" -ge "$recommended" && "$wmem" -ge "$recommended" ]]; then
        log "  [OK]   UDP buffers: rmem_max=${rmem}, wmem_max=${wmem} (>= ${recommended})"
    else
        log_warn "  [WARN] UDP buffers: rmem_max=${rmem}, wmem_max=${wmem} (рекомендуется >= ${recommended}) — возможны просадки при высокой нагрузке"
    fi

    # 6. WAN offloads (информационно — не считается проблемой)
    local wan_iface offload_info
    wan_iface="$(get_main_nic)"
    if [[ -n "$wan_iface" ]] && command -v ethtool >/dev/null 2>&1; then
        offload_info="$(ethtool -k "$wan_iface" 2>/dev/null | awk -F': ' '
            /^(tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload|large-receive-offload|udp-fragmentation-offload)/ {
                gsub(/[ \t].*/, "", $2); printf "%s=%s ", $1, $2
            }')"
        log "  [INFO] WAN offloads (${wan_iface}): ${offload_info:-n/a}"
    else
        log "  [INFO] WAN offloads: интерфейс не определён или ethtool недоступен"
    fi

    # 7. IPv6-маршрутизация (информационно)
    local v6disabled has_global_v6=0 v6mode
    v6disabled="$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)"
    if [[ -r /proc/net/if_inet6 ]]; then
        while read -r _addr _idx _plen scope _flags name; do
            if [[ "$scope" == "00" && "$name" != "lo" ]]; then
                has_global_v6=1
                break
            fi
        done < /proc/net/if_inet6
    fi
    if [[ "$v6disabled" != "1" && "$has_global_v6" -eq 1 ]]; then
        v6mode="enabled"
    else
        v6mode="disabled"
    fi
    log "  [INFO] IPv6 routing: ${v6mode} (global address: $([[ "$has_global_v6" -eq 1 ]] && echo yes || echo no))"

    # 8. NDP proxy (ndppd) — только диагностика, автоустановка не выполняется
    local ndppd_bin="" ndppd_conf=0 ndppd_enabled=0 has_default_v6route=0 ndppd_state
    ndppd_bin="$(command -v ndppd || true)"
    [[ -f /etc/ndppd.conf ]] && ndppd_conf=1
    if command -v systemctl >/dev/null 2>&1; then
        ndppd_state="$(systemctl is-enabled ndppd 2>/dev/null || true)"
        [[ "$ndppd_state" == "enabled" || "$ndppd_state" == "static" ]] && ndppd_enabled=1
    fi
    if [[ -r /proc/net/ipv6_route ]] \
        && grep -q '^00000000000000000000000000000000 ' /proc/net/ipv6_route 2>/dev/null; then
        has_default_v6route=1
    fi
    if [[ "$v6mode" == "disabled" ]]; then
        log "  [INFO] NDP proxy (ndppd): IPv6 отключён — не требуется"
    elif [[ "$has_global_v6" -eq 1 && "$has_default_v6route" -eq 0 ]]; then
        if [[ -n "$ndppd_bin" && "$ndppd_conf" -eq 1 && "$ndppd_enabled" -eq 1 ]]; then
            log "  [OK]   NDP proxy (ndppd): установлен и включён"
        else
            log_warn "  [WARN] NDP proxy (ndppd): глобальный IPv6-адрес есть, но маршрут по умолчанию отсутствует — возможно потребуется ndppd (не устанавливается автоматически)"
        fi
    else
        log "  [INFO] NDP proxy (ndppd): маршрутизируемый IPv6-префикс присутствует — не требуется"
    fi

    log "--- Конец проверки готовности к AmneziaWG ---"
    return 0
}

# ==============================================================================
# Загрузка / сохранение параметров
# ==============================================================================

# Безопасная загрузка конфигурации (whitelist-парсер, без source/eval)
# Парсит только разрешённые ключи формата KEY=VALUE или export KEY=VALUE
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
                AWG_H1|AWG_H2|AWG_H3|AWG_H4|AWG_I1|AWG_I2|AWG_I3|AWG_I4|AWG_I5|AWG_PRESET|AWG_PROTOCOL_VERSION|NO_TWEAKS|AWG_APPLY_MODE|PREV_AWG_PORT|CLIENT_ISOLATION|CLIENT_ISOLATION_NET|\
                AWG_IPV6_ENABLED|AWG_IPV6_MODE|AWG_IPV6_MODE_REQUESTED|AWG_IPV6_MODE_EFFECTIVE|AWG_IPV6_MODE_REASON|AWG_IPV6_SUBNET|AWG_IPV6_NDP_PROXY|AWG_IPV6_LEAK_PROTECTION|\
                AWG_P2P_ENABLED|AWG_P2P_BASE_PORT|AWG_P2P_PORTS_PER_CLIENT|AWG_FULLCONE_NAT|\
                AWG_WEB_ENABLED|AWG_WEB_PORT|AWG_WEB_BIND|AWG_WEB_CERT_MODE|AWG_WEB_DOMAIN|AWG_WEB_CERT_FILE|AWG_WEB_KEY_FILE|AWG_WEB_CERT_PROVIDER|AWG_WEB_LE_EMAIL|AWG_WEB_PUBLIC_URL|AWG_WEB_CERT_FALLBACK|AWG_WEB_CERT_ATTEMPTED_MODE|AWG_WEB_CERT_FAILURE_REASON|AWG_WEB_CERT_FALLBACK_USED|\
                AWG_DNS_MODE|AWG_CUSTOM_DNS|AWG_ADGUARD_ENABLED|AWG_ADGUARD_PORT|AWG_ADGUARD_DIR|\
                AWG_WIRESOCK_HINTS|AWG_WIRESOCK_ID|AWG_WIRESOCK_IP|AWG_WIRESOCK_IB|AWG_SERVER_NAME)
                    export "$key=$value"
                    ;;
            esac
        fi
    done < "$config_file"
}

# Парсер живого серверного конфига AmneziaWG (источник истины для AWG_*).
# Читает секцию [Interface] из awg0.conf и экспортирует AWG_* переменные
# АТОМАРНО: либо все 11 обязательных параметров (Jc/Jmin/Jmax/S1-S4/H1-H4)
# найдены и экспортированы, либо ничего не меняется в окружении и возврат 1.
# Это защищает от mixed-state при частично corrupt awg0.conf.
# I1-I5, ListenPort — опциональные, экспортируются если нашлись.
# Решает баг #38: regen использовал устаревшие значения из init-файла,
# а не актуальные из awg0.conf после ручной правки.
# shellcheck disable=SC2120  # Опциональный аргумент используется только в тестах
load_awg_params_from_server_conf() {
    local conf="${1:-$SERVER_CONF_FILE}"
    [[ -f "$conf" ]] || return 1
    local protocol_version="${AWG_PROTOCOL_VERSION:-2.0}"

    # Локальное накопление — экспортируем всё-или-ничего в конце
    local _Jc="" _Jmin="" _Jmax=""
    local _S1="" _S2="" _S3="" _S4=""
    local _H1="" _H2="" _H3="" _H4=""
    local _I1="" _I2="" _I3="" _I4="" _I5="" _Port="" _MTU=""

    local in_iface=0 line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^\[Interface\] ]]; then in_iface=1; continue; fi
        if [[ "$line" =~ ^\[ ]]; then in_iface=0; continue; fi
        (( in_iface )) || continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        if [[ "$line" =~ ^[[:space:]]*([A-Za-z0-9]+)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            # Trim trailing whitespace
            value="${value%"${value##*[![:space:]]}"}"
            case "$key" in
                Jc)         _Jc="$value" ;;
                Jmin)       _Jmin="$value" ;;
                Jmax)       _Jmax="$value" ;;
                S1)         _S1="$value" ;;
                S2)         _S2="$value" ;;
                S3)         _S3="$value" ;;
                S4)         _S4="$value" ;;
                H1)         _H1="$value" ;;
                H2)         _H2="$value" ;;
                H3)         _H3="$value" ;;
                H4)         _H4="$value" ;;
                I1)         _I1="$value" ;;
                I2)         _I2="$value" ;;
                I3)         _I3="$value" ;;
                I4)         _I4="$value" ;;
                I5)         _I5="$value" ;;
                ListenPort) _Port="$value" ;;
                MTU)        _MTU="$value" ;;
            esac
        fi
    done < "$conf"

    # Atomic check: AWG 1.5 intentionally has no S3/S4.
    [[ -n "$_Jc" && -n "$_Jmin" && -n "$_Jmax" && \
       -n "$_S1" && -n "$_S2" && \
       -n "$_H1" && -n "$_H2" && -n "$_H3" && -n "$_H4" ]] || return 1
    if [[ "$protocol_version" != "1.5" ]] && [[ -z "$_S3" || -z "$_S4" ]]; then
        return 1
    fi

    # Atomic export — окружение модифицируется только при полном успехе
    export AWG_Jc="$_Jc" AWG_Jmin="$_Jmin" AWG_Jmax="$_Jmax"
    export AWG_S1="$_S1" AWG_S2="$_S2" AWG_S3="$_S3" AWG_S4="$_S4"
    export AWG_H1="$_H1" AWG_H2="$_H2" AWG_H3="$_H3" AWG_H4="$_H4"
    [[ -n "$_I1"   ]] && export AWG_I1="$_I1"
    [[ -n "$_I2"   ]] && export AWG_I2="$_I2"
    [[ -n "$_I3"   ]] && export AWG_I3="$_I3"
    [[ -n "$_I4"   ]] && export AWG_I4="$_I4"
    [[ -n "$_I5"   ]] && export AWG_I5="$_I5"
    [[ -n "$_Port" ]] && export AWG_PORT="$_Port"
    if _validate_mtu "${_MTU:-}"; then
        export AWG_MTU="$_MTU"
    fi
    return 0
}

# Загрузка AWG параметров.
#
# Семантика источников (важно для предотвращения split-brain между сервером
# и клиентскими конфигами, см. #38):
#
#   * init-файл ($CONFIG_FILE = awgsetup_cfg.init) — для НЕ-AWG настроек
#     (OS_ID, ALLOWED_IPS, AWG_PORT, AWG_ENDPOINT и т.п.). Загружается всегда
#     если существует.
#   * Live server config ($SERVER_CONF_FILE = /etc/amnezia/amneziawg/awg0.conf)
#     — ЕДИНСТВЕННЫЙ источник истины для AWG протокольных параметров
#     (Jc/Jmin/Jmax/S1-S4/H1-H4/I1-I5) когда файл существует.
#
# Если live server config существует но НЕ содержит полного набора AWG
# параметров (повреждение / неполная ручная правка) — функция возвращает 1
# с явной ошибкой. Молчаливый fallback на устаревшие значения из init-файла
# создал бы split-brain: сервер живёт по новому awg0.conf, а regen выпускал
# бы клиентам старые J*/S*/H*. Это именно тот класс проблем, который
# elvaleto и Klavishnik сообщили в Discussion #38.
#
# Init-файл используется для AWG параметров ТОЛЬКО когда live server config
# вообще отсутствует — это путь bootstrap первой установки, когда awg0.conf
# ещё не записан, а generate_awg_params уже сохранил значения в init.
load_awg_params() {
    # 1. Базовые настройки из init (всегда, для не-AWG ключей)
    if [[ -f "$CONFIG_FILE" ]]; then
        safe_load_config "$CONFIG_FILE" || log_warn "Не удалось загрузить $CONFIG_FILE"
    fi

    # 2. AWG протокольные параметры
    # Если CLI задал --preset/--jc/--jmin/--jmax, параметры уже set через generate_awg_params.
    # Пропускаем перезагрузку из awg0.conf чтобы не перезатереть свежие значения.
    if [[ -n "${CLI_PRESET:-}" || -n "${CLI_JC:-}" || -n "${CLI_JMIN:-}" || -n "${CLI_JMAX:-}" ]]; then
        log_debug "CLI overrides заданы — AWG params из generate_awg_params, не из $SERVER_CONF_FILE"
    elif [[ -f "$SERVER_CONF_FILE" ]]; then
        # Live config существует — он единственный источник истины.
        # Никакого fallback на init: иначе получим split-brain.
        # Unset I1-I5: optional values absent from live config must not leak
        # from a stale init file.
        unset AWG_I1 AWG_I2 AWG_I3 AWG_I4 AWG_I5
        if ! load_awg_params_from_server_conf; then
            log_error "В $SERVER_CONF_FILE отсутствуют обязательные AWG-параметры"
            log_error "(Jc/Jmin/Jmax/S1-S4/H1-H4). Не использую устаревшие значения"
            log_error "из $CONFIG_FILE, чтобы не создавать split-brain между сервером"
            log_error "и клиентскими конфигами. Восстановите [Interface] секцию в"
            log_error "$SERVER_CONF_FILE или восстановите awg0.conf из бэкапа."
            return 1
        fi
        log_debug "AWG параметры загружены из $SERVER_CONF_FILE (live config)"
    else
        # Bootstrap: server config ещё не существует (первая установка).
        # AWG_* должны быть в env через safe_load_config выше.
        log_debug "$SERVER_CONF_FILE не существует — использую AWG params из $CONFIG_FILE (bootstrap)"
    fi

    # 3. Проверка обязательных параметров выбранной версии
    local missing=0
    local param
    local required_params=(AWG_Jc AWG_Jmin AWG_Jmax AWG_S1 AWG_S2 AWG_H1 AWG_H2 AWG_H3 AWG_H4)
    [[ "${AWG_PROTOCOL_VERSION:-2.0}" == "1.5" ]] || required_params+=(AWG_S3 AWG_S4)
    for param in "${required_params[@]}"; do
        if [[ -z "${!param:-}" ]]; then
            log_error "Параметр $param не найден"
            missing=1
        fi
    done
    if [[ $missing -eq 1 ]]; then
        return 1
    fi
    return 0
}

# Предупреждение о расхождении awgsetup_cfg.init с живым awg0.conf (issue #196).
#
# После установки awg0.conf - единственный источник параметров обфускации, а
# init читается для них только на bootstrap первой установки (см. load_awg_params
# выше). Правка AWG_* в init после установки на клиентов не влияет, и до этой
# проверки она игнорировалась МОЛЧА: файл назван как конфиг установки, человек
# правит его и не получает ни намёка, что смотреть надо в другое место.
#
# Гейт по времени модификации отсекает ложные срабатывания на штатном пути.
# Рекомендованный способ тюнинга (правка [Interface] в awg0.conf + regen) тоже
# разводит эти файлы, но init после установки никто не перезаписывает, поэтому
# там он остаётся СТАРШЕ live-конфига. Предупреждаем только когда init тронут
# ПОЗЖЕ awg0.conf - это и есть случай "поправил init, эффекта нет".
#
# Проверку намеренно не вешаем на load_awg_params: её зовёт и установщик на
# шаге 6, где init заведомо свежее ещё не перезаписанного awg0.conf, и
# предупреждение всплывало бы посреди штатной установки.
_AWG_DRIFT_KEYS=(AWG_Jc AWG_Jmin AWG_Jmax AWG_S1 AWG_S2 AWG_S3 AWG_S4 \
                 AWG_H1 AWG_H2 AWG_H3 AWG_H4 AWG_I1 AWG_I2 AWG_I3 AWG_I4 AWG_I5)

# _awg_drift_dump <init|live> <файл>: по строке на ключ в порядке массива выше,
# поэтому дампы двух источников сравнимы построчно. Читаем в subshell, чтобы не
# трогать окружение вызывающего - функцию можно звать в любой момент, не рискуя
# перетереть уже загруженные параметры.
_awg_drift_dump() {
    local mode="$1" src="$2"
    (
        # Наследованные значения гасим: иначе ключ, которого в источнике нет,
        # показался бы равным тому, что уже лежит в окружении. Если погасить
        # не удалось (переменная readonly в вызывающем окружении), сравнивать
        # нечего - выходим без маркера.
        unset "${_AWG_DRIFT_KEYS[@]}" 2>/dev/null || exit 1
        if [[ "$mode" == "init" ]]; then
            safe_load_config "$src" >/dev/null 2>&1 || exit 1
        else
            load_awg_params_from_server_conf "$src" >/dev/null 2>&1 || exit 1
        fi
        # Маркер успеха первой строкой: mapfile не отдаёт код возврата
        # процесса-поставщика, поэтому без него отказ парсера не отличить от
        # набора пустых значений.
        printf 'ok\n'
        local k
        for k in "${_AWG_DRIFT_KEYS[@]}"; do
            printf '%s\n' "${!k:-}"
        done
    )
}

warn_awg_init_drift() {
    local init="${CONFIG_FILE:-}" live="${SERVER_CONF_FILE:-}"
    [[ -n "$init" && -n "$live" ]] || return 0
    [[ -f "$init" && -f "$live" ]] || return 0
    # init не новее live - значит расхождение, если оно есть, создано правкой
    # самого awg0.conf, то есть штатным путём. Молчим.
    [[ "$init" -nt "$live" ]] || return 0

    local -a ivals lvals
    mapfile -t ivals < <(_awg_drift_dump init "$init")
    mapfile -t lvals < <(_awg_drift_dump live "$live")
    # Без маркера сравнение недостоверно: разбор одного из источников отказал.
    # Молчим, а не объявляем разошедшимися все ключи разом - реальную причину
    # (например неполный [Interface]) дальше назовёт load_awg_params.
    [[ "${ivals[0]:-}" == "ok" && "${lvals[0]:-}" == "ok" ]] || return 0

    local drift="" i
    for i in "${!_AWG_DRIFT_KEYS[@]}"; do
        [[ "${ivals[i+1]:-}" == "${lvals[i+1]:-}" ]] || drift+="${_AWG_DRIFT_KEYS[i]#AWG_} "
    done
    [[ -n "$drift" ]] || return 0

    log_warn "Файл $init изменён позже $live, и параметры обфускации в них расходятся: ${drift% }"
    log_warn "Действуют значения из $live - после установки он единственный источник этих параметров. Если вы правили их в $init, до клиентов правка не дойдёт: меняйте секцию [Interface] в $live, затем перезапустите awg-quick@awg0 и выполните regen нужных клиентов."
    return 0
}

# ==============================================================================
# Генерация ключей
# ==============================================================================

# Генерация пары ключей (приватный + публичный)
# generate_keypair <name>
# Результат: keys/<name>.private, keys/<name>.public
generate_keypair() {
    local name="$1"
    if [[ -z "$name" ]]; then
        log_error "generate_keypair: не указано имя"
        return 1
    fi
    mkdir -p "$KEYS_DIR" || {
        log_error "Ошибка создания $KEYS_DIR"
        return 1
    }
    # 700 сразу при создании: mkdir -p с дефолтным umask дал бы 755, и до
    # secure_files инсталлера каталог ключей был бы доступен на чтение всем.
    chmod 700 "$KEYS_DIR"

    local privkey pubkey
    privkey=$(awg genkey) || {
        log_error "Ошибка генерации приватного ключа для '$name'"
        return 1
    }
    pubkey=$(echo "$privkey" | awg pubkey) || {
        log_error "Ошибка генерации публичного ключа для '$name'"
        return 1
    }

    # umask 077 в subshell: файл рождается сразу 600, без окна world-readable
    # между записью и chmod (при дефолтном umask 022 ключ был бы 644 на миг).
    ( umask 077; echo "$privkey" > "$KEYS_DIR/${name}.private" ) || {
        log_error "Ошибка записи приватного ключа для '$name'"
        return 1
    }
    ( umask 077; echo "$pubkey" > "$KEYS_DIR/${name}.public" ) || {
        log_error "Ошибка записи публичного ключа для '$name'"
        return 1
    }
    chmod 600 "$KEYS_DIR/${name}.private" "$KEYS_DIR/${name}.public" || {
        log_error "Ошибка установки прав на ключи '$name'"
        return 1
    }
    log_debug "Ключи для '$name' сгенерированы."
    return 0
}

# Генерация серверных ключей
# Результат: server_private.key, server_public.key в AWG_DIR
generate_server_keys() {
    local privkey pubkey
    privkey=$(awg genkey) || {
        log_error "Ошибка генерации приватного ключа сервера"
        return 1
    }
    pubkey=$(echo "$privkey" | awg pubkey) || {
        log_error "Ошибка генерации публичного ключа сервера"
        return 1
    }

    # umask 077: без окна world-readable между записью и chmod (см. generate_keypair).
    ( umask 077; echo "$privkey" > "$AWG_DIR/server_private.key" ) || return 1
    ( umask 077; echo "$pubkey" > "$AWG_DIR/server_public.key" ) || return 1
    chmod 600 "$AWG_DIR/server_private.key" "$AWG_DIR/server_public.key" || {
        log_error "Ошибка установки прав на серверные ключи"
        return 1
    }
    log "Серверные ключи сгенерированы."
    return 0
}

# Гарантирует наличие $AWG_DIR/server_public.key.
# Если файла нет — пытается восстановить его из PrivateKey в awg0.conf
# (полезно для ручных установок вне нашего installer, где кеш серверного
# pubkey не создаётся на шаге 6). Возвращает 0 если ключ уже есть или
# успешно восстановлен, 1 если ни того ни другого.
_ensure_server_public_key() {
    [[ -f "$AWG_DIR/server_public.key" ]] && return 0

    [[ -f "$SERVER_CONF_FILE" ]] || {
        log_error "Не могу восстановить server_public.key — отсутствует $SERVER_CONF_FILE"
        return 1
    }
    local _srv_priv
    _srv_priv=$(awk '
        /^\[Interface\]/ {in_iface=1; next}
        in_iface && /^[ \t]*PrivateKey[ \t]*=/ {
            sub(/^[ \t]*PrivateKey[ \t]*=[ \t]*/, "")
            gsub(/[[:space:]]/, "")
            print
            exit
        }
        /^\[/ && !/^\[Interface\]/ {in_iface=0}
    ' "$SERVER_CONF_FILE")
    if [[ -z "$_srv_priv" ]]; then
        log_error "Не найден PrivateKey в $SERVER_CONF_FILE — восстановить server_public.key невозможно"
        return 1
    fi
    mkdir -p "$AWG_DIR"
    local _tmp
    _tmp=$(awg_mktemp "$AWG_DIR") || return 1
    if ! echo "$_srv_priv" | awg pubkey > "$_tmp"; then
        rm -f "$_tmp"
        log_error "Не удалось вычислить публичный ключ через awg pubkey"
        return 1
    fi
    if ! mv -f "$_tmp" "$AWG_DIR/server_public.key"; then
        rm -f "$_tmp"
        log_error "Ошибка перемещения в $AWG_DIR/server_public.key"
        return 1
    fi
    chmod 600 "$AWG_DIR/server_public.key" 2>/dev/null || true
    log "server_public.key восстановлен из awg0.conf PrivateKey."
    return 0
}

# ==============================================================================
# Рендеринг конфигураций
# ==============================================================================

# Вычисление IPv6-адреса сервера (хост ::1) из туннельной подсети.
# Вход: PREFIX::/MASK (например fddd:2c4:2c4:2c4::/64).
# Выход: PREFIX::1/MASK (например fddd:2c4:2c4:2c4::1/64).
# Допущение: подсеть всегда оканчивается на ::/MASK (так формирует install-скрипт).
# Если завершающего ::/ нет - возвращаю вход без изменений (defensive fallback).
_derive_ipv6_server_addr() {
    local subnet="$1"
    if [[ "$subnet" == *"::/"* ]]; then
        echo "${subnet/::\//::1\/}"
    else
        echo "$subnet"
    fi
}

# Рендер серверного конфига AWG 2.0
# render_server_config [peers_source_file]
# Использует глобальные переменные из load_awg_params()
# peers_source_file (необязательный): файл, чьи [Peer]-блоки переносятся в
# новый конфиг ДО атомарного mv (обычно бэкап живого awg0.conf). Благодаря
# этому живой конфиг ни на мгновение не остаётся без пиров - сбой между
# render и отдельным append оставлял бы безпировый файл, а повторный запуск
# шага 6 уже бэкапил бы его (потеря всех пиров при --force reinstall).
# shellcheck disable=SC2154  # AWG_* vars loaded via load_awg_params -> source
render_server_config() {
    load_awg_params || return 1

    # During --force --port, the init file contains the requested new port
    # while the live awg0.conf still contains the old one loaded above.
    local init_port
    init_port=$(grep -oP '^\s*export AWG_PORT=\K[0-9]+' "$CONFIG_FILE" 2>/dev/null | head -n1)
    if [[ -n "$init_port" ]] && validate_l4_port "$init_port"; then
        AWG_PORT="$init_port"
    fi

    local server_privkey
    if [[ -f "$AWG_DIR/server_private.key" ]]; then
        server_privkey=$(cat "$AWG_DIR/server_private.key")
    else
        log_error "Приватный ключ сервера не найден: $AWG_DIR/server_private.key"
        return 1
    fi

    local nic
    nic=$(get_main_nic)
    if [[ -z "$nic" ]]; then
        log_error "Не удалось определить сетевой интерфейс."
        log_error "Укажите его вручную и перезапустите шаг 6: export AWG_MAIN_NIC=<iface>"
        log_error "Доступные интерфейсы: $(ip -br link 2>/dev/null | awk '$1!="lo"{printf "%s ", $1}')"
        return 1
    fi

    # IPv6-only egress: интерфейс есть, но IPv4-выхода нет. Туннель на IPv4 (10.x)
    # NAT'ится через MASQUERADE - на таком хосте IPv4-трафик клиентов наружу не
    # пойдёт (issue #166). Предупреждаем, не блокируем: peer-to-peer внутри
    # туннеля и IPv6-туннель (--allow-ipv6-tunnel) работают.
    if host_lacks_ipv4_egress "$nic"; then
        log_warn "Похоже, хост IPv6-only: у $nic нет IPv4-выхода."
        log_warn "VPN туннелирует IPv4, поэтому IPv4-трафик клиентов наружу не пойдёт."
        log_warn "Нужен хост с IPv4-адресом (dual-stack) или NAT64."
    fi

    local server_ip subnet_mask
    server_ip=$(echo "$AWG_TUNNEL_SUBNET" | cut -d'/' -f1)
    subnet_mask=$(echo "$AWG_TUNNEL_SUBNET" | cut -d'/' -f2)

    # Адрес [Interface]: IPv4 всегда, IPv6 только при включённом туннеле.
    # Сервер берёт хост ::1 в туннельной IPv6-подсети.
    # IPV6_SUBNET имеет форму PREFIX::/MASK (по умолчанию fddd:2c4:2c4:2c4::/64),
    # поэтому адрес сервера получаю заменой завершающего ::/MASK на ::1/MASK.
    local address_line="${server_ip}/${subnet_mask}"
    if [[ "${ALLOW_IPV6_TUNNEL:-0}" -eq 1 ]]; then
        local ipv6_subnet="${IPV6_SUBNET:-fddd:2c4:2c4:2c4::/64}"
        local ipv6_server_addr
        ipv6_server_addr=$(_derive_ipv6_server_addr "$ipv6_subnet")
        address_line="${address_line}, ${ipv6_server_addr}"
    fi

    local conf_dir
    conf_dir=$(dirname "$SERVER_CONF_FILE")
    mkdir -p "$conf_dir" || {
        log_error "Ошибка создания $conf_dir"
        return 1
    }

    local address_line="${server_ip}/${subnet_mask}" server_name
    server_name=$(awg_server_name)
    if awg_ipv6_enabled; then
        local server_ipv6
        server_ipv6=$(get_server_ipv6_address) || {
            log_error "Не удалось вычислить IPv6 адрес сервера из AWG_IPV6_SUBNET=${AWG_IPV6_SUBNET}"
            return 1
        }
        address_line="${address_line}, ${server_ipv6}/64"
    fi

    # Сложные правила NAT/forward/P2P живут во внешних hook-скриптах.
    generate_firewall_scripts "$nic" || log_warn "Не удалось сгенерировать PostUp/PostDown hook-скрипты."
    local postup="iptables -I FORWARD -i %i -j ACCEPT; /bin/bash ${AWG_DIR}/postup.sh"
    local postdown="/bin/bash ${AWG_DIR}/postdown.sh"
    if [[ "${CLIENT_ISOLATION:-1}" -eq 1 ]]; then
        postup="${postup}; while iptables -D FORWARD -i %i -o %i -j DROP 2>/dev/null; do :; done; iptables -I FORWARD -i %i -o %i -j DROP; while ip6tables -D FORWARD -i %i -o %i -j DROP 2>/dev/null; do :; done; ip6tables -I FORWARD -i %i -o %i -j DROP"
        postdown="iptables -D FORWARD -i %i -o %i -j DROP 2>/dev/null || true; ip6tables -D FORWARD -i %i -o %i -j DROP 2>/dev/null || true; ${postdown}"
    fi

    local protocol_version="${AWG_PROTOCOL_VERSION:-2.0}"
    local h1="${AWG_H1}" h2="${AWG_H2}" h3="${AWG_H3}" h4="${AWG_H4}"
    if [[ "$protocol_version" == "1.5" ]]; then
        h1="${h1%%-*}"; h2="${h2%%-*}"; h3="${h3%%-*}"; h4="${h4%%-*}"
    fi

    # Формируем конфиг через временный файл (атомарная запись)
    local tmpfile
    tmpfile=$(awg_mktemp "$(dirname "$SERVER_CONF_FILE")") || { log_error "Ошибка mktemp"; return 1; }

    cat > "$tmpfile" << EOF
[Interface]
# Name = ${server_name}
PrivateKey = ${server_privkey}
Address = ${address_line}
MTU = ${AWG_MTU:-1280}
ListenPort = ${AWG_PORT}
PostUp = ${postup}
PostDown = ${postdown}
Jc = ${AWG_Jc}
Jmin = ${AWG_Jmin}
Jmax = ${AWG_Jmax}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
EOF
    if _awg_protocol_has_s34; then
        cat >> "$tmpfile" << EOF
S3 = ${AWG_S3}
S4 = ${AWG_S4}
EOF
    fi
    cat >> "$tmpfile" << EOF
H1 = ${h1}
H2 = ${h2}
H3 = ${h3}
H4 = ${h4}
EOF

    if [[ "$protocol_version" == "3.0" || "$protocol_version" == "3.1" ]]; then
        _awg31_render_extra_fields >> "$tmpfile" || { rm -f "$tmpfile"; return 1; }
    fi

    # I1-I5 are optional; I2-I5 may be supplied manually by the administrator.
    if _awg_protocol_has_cps; then
    [[ -n "${AWG_I1:-}" ]] && echo "I1 = ${AWG_I1}" >> "$tmpfile"
    [[ -n "${AWG_I2:-}" ]] && echo "I2 = ${AWG_I2}" >> "$tmpfile"
    [[ -n "${AWG_I3:-}" ]] && echo "I3 = ${AWG_I3}" >> "$tmpfile"
    [[ -n "${AWG_I4:-}" ]] && echo "I4 = ${AWG_I4}" >> "$tmpfile"
    [[ -n "${AWG_I5:-}" ]] && echo "I5 = ${AWG_I5}" >> "$tmpfile"
    fi

    if ! mv "$tmpfile" "$SERVER_CONF_FILE"; then
        rm -f "$tmpfile"
        log_error "Ошибка записи серверного конфига"
        return 1
    fi
    chmod 600 "$SERVER_CONF_FILE"
    log "Серверный конфиг создан: $SERVER_CONF_FILE"
    return 0
}

# Предупредить, что списочное значение задано несколькими строками и они были
# объединены. Молчать тут нельзя: объединение меняет то, что человек написал
# руками, и если он ошибся, узнать об этом он должен от нас, а не от клиента.
_awg_warn_multiline() {
    local raw="$1" key="$2" name="$3" n
    n=$(printf '%s\n' "$raw" | grep -c '[^[:space:]]') || n=0
    (( n > 1 )) && log_warn "'${key}' у клиента '${name}' задан ${n} строками - значения объединены в одну."
    return 0
}

# Нормализация списка через запятую к каноническому виду "a, b, c".
#
# Зачем: установщик пишет AllowedIPs и DNS через запятую С ПРОБЕЛОМ, а
# regenerate_client читал эти значения через `tr -d '[:space:]'` и записывал
# прочитанное обратно, поэтому первый же regen оставлял в .conf слипшийся
# список (D#38 @humowns). Здесь список разбирается поэлементно, а разделитель
# ставится канонически, и повторный regen ЛЕЧИТ уже испорченные конфиги.
#
# 🔴 НЕ применять к значению, которое уходит в JSON-массив allowed_ips сборщика
# vpn:// (см. комментарий у generate_vpn_uri): там нужна КОМПАКТНАЯ форма.
# Одна редакция этой правки нормализацию туда уже завела, и на стенде это дало
# ведущий пробел внутри 33 элементов массива из 34.
#
# Пробелы срезаются ВНУТРИ элемента, а не только по краям: элементы этих двух
# списков (CIDR и адреса резолверов) пробелов не содержат никогда, а валидатор
# `manage modify` чистит их так же, через `${tok//[[:space:]]/}`. Заодно это
# лечит значения вида "1.1.1. 1", которые прежний `tr` вычищал случайно.
#
# Разбор через `read -a`, а не `for x in $raw`, чтобы значение не попало под
# glob-раскрутку. Trim инлайном, без вызова функции: подстановка на КАЖДЫЙ
# элемент порождает subshell, и на списке в 2000 записей это 18 секунд против
# 0.1 - а regen без имени идёт по всем клиентам сразу.
#
# ⚠️ Контракт: вход ОДНОСТРОЧНЫЙ. `read` без `-d` возьмёт только первую строку,
# поэтому многострочное значение вызывающий обязан склеить сам (`paste -sd, -`).
awg_normalize_csv() {
    local normalized="" item
    local -a parts
    IFS=',' read -r -a parts <<< "$1"
    for item in "${parts[@]}"; do
        item="${item//[[:space:]]/}"
        [[ -z "$item" ]] && continue
        normalized+="${normalized:+, }$item"
    done
    printf '%s' "$normalized"
}

# Допустимый диапазон MTU для AWG / WireGuard.
_validate_mtu() {
    local v="$1"
    [[ "$v" =~ ^[0-9]+$ ]] || return 1
    (( v >= 576 && v <= 9100 )) || return 1
    return 0
}

# Извлечение MTU из секции [Interface] серверного awg0.conf.
_extract_mtu_from_server_conf() {
    local conf="${SERVER_CONF_FILE:-/etc/amnezia/amneziawg/awg0.conf}"
    [[ -r "$conf" ]] || return 1
    local val
    val=$(awk '
        /^\[Interface\]/ {in_iface=1; next}
        /^\[/ {in_iface=0}
        in_iface && /^[[:space:]]*MTU[[:space:]]*=/ {
            gsub(/^[[:space:]]*MTU[[:space:]]*=[[:space:]]*/, "")
            gsub(/[[:space:]].*$/, "")
            if ($0 ~ /^[0-9]+$/) { mtu=$0 }
        }
        END { if (mtu != "") print mtu }
    ' "$conf")
    _validate_mtu "$val" || return 1
    echo "$val"
}

# Рендер клиентского конфига AWG 2.0
# render_client_config <name> <client_ip> <client_privkey> <server_pubkey> <endpoint> <port> [client_ipv6]
is_panel_domain_endpoint() {
    local endpoint="${1:-}" panel_domain="${AWG_WEB_DOMAIN:-}"
    endpoint="${endpoint,,}"; panel_domain="${panel_domain,,}"
    endpoint="${endpoint%.}"; panel_domain="${panel_domain%.}"
    [[ -n "$panel_domain" && "$endpoint" == "$panel_domain" ]]
}

render_client_config() {
    local name="$1"
    local client_ip="$2"
    local client_privkey="$3"
    local server_pubkey="$4"
    local endpoint="$5"
    local port="$6"
    local client_ipv6="${7:-}"

    if is_panel_domain_endpoint "$endpoint"; then
        log_error "VPN endpoint cannot use the web panel domain; use the dedicated VPN endpoint or IP."
        return 1
    fi

    load_awg_params || return 1

    local conf_file="$AWG_DIR/${name}.conf" server_name
    server_name=$(awg_server_name)
    local allowed_ips="${ALLOWED_IPS:-0.0.0.0/0}"
    local dns_servers
    dns_servers=$(awg_dns_servers)
    if [[ "${ALLOWED_IPS_MODE:-}" != "1" ]]; then
        allowed_ips="$(ensure_dns_allowedips_routes "$allowed_ips" "$dns_servers" "${AWG_TUNNEL_SUBNET:-10.9.9.1/24}" "${AWG_IPV6_SUBNET:-}")"
    fi
    local address_line="${client_ip}/32"
    if awg_ipv6_enabled; then
        if [[ -z "$client_ipv6" ]]; then
            client_ipv6=$(get_client_ipv6_from_server "$name" 2>/dev/null || true)
        fi
        if [[ -n "$client_ipv6" ]]; then
            address_line="${address_line}, ${client_ipv6}/128"
            if [[ "$allowed_ips" != *"::/0"* ]]; then
                allowed_ips="${allowed_ips}, ::/0"
            fi
        fi
    elif awg_ipv6_leak_block_enabled; then
        # Leak-block is independent of IPv4 routing mode.  Split-tunnel
        # profiles still need an IPv6 sink route, otherwise native IPv6 (and
        # WebRTC ICE traffic) can bypass the VPN even when IPv4 is intentional.
        if [[ "$allowed_ips" != *"::/0"* ]]; then
            allowed_ips="${allowed_ips}, ::/0"
        fi
    fi
    local mtu
    mtu=$(_extract_mtu_from_server_conf) || mtu=""
    if [[ -z "$mtu" ]]; then
        if _validate_mtu "${AWG_MTU:-}"; then
            mtu="$AWG_MTU"
        else
            mtu=1280
        fi
    fi

    # MTU: приоритет server awg0.conf > AWG_MTU из awgsetup_cfg.init > 1280 fallback.
    # Server config - источник правды для уже работающего сервера: пользователь
    # мог поправить MTU в /etc/amnezia/amneziawg/awg0.conf руками, и regen должен
    # это подхватить (Discussion #38). Невалидные значения (вне 576-9100)
    # на любом этапе откатываются к 1280.
    local mtu
    mtu=$(_extract_mtu_from_server_conf) || mtu=""
    if [[ -z "$mtu" ]]; then
        if _validate_mtu "${AWG_MTU:-}"; then
            mtu="$AWG_MTU"
        else
            mtu=1280
        fi
    fi

    # temp в каталоге клиентского конфига ($AWG_DIR) -> mv = атомарный rename.
    local tmpfile
    tmpfile=$(awg_mktemp "$AWG_DIR") || { log_error "Ошибка mktemp"; return 1; }

    local address_line
    local protocol_version="${AWG_PROTOCOL_VERSION:-2.0}"
    if [[ -n "$client_ipv6" ]]; then
        address_line="${client_ip}/32, ${client_ipv6}/128"
    else
        address_line="${client_ip}/32"
    fi

    cat > "$tmpfile" << EOF
[Interface]
# Name = ${server_name}
# IPv6 leak protection: $(if awg_ipv6_enabled; then echo "IPv6 is routed through VPN (${AWG_IPV6_MODE:-legacy})."; elif awg_ipv6_leak_block_enabled; then echo "block mode enabled; ::/0 is routed into the tunnel without assigning a VPN IPv6 address."; else echo "IPv4-only; native client IPv6 can leak unless the client blocks IPv6 outside VPN."; fi)
PrivateKey = ${client_privkey}
Address = ${address_line}
DNS = ${dns_servers}
MTU = ${mtu}
Jc = ${AWG_Jc}
Jmin = ${AWG_Jmin}
Jmax = ${AWG_Jmax}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
EOF
    if _awg_protocol_has_s34; then
        cat >> "$tmpfile" << EOF
S3 = ${AWG_S3}
S4 = ${AWG_S4}
EOF
    fi
    local h1="${AWG_H1}" h2="${AWG_H2}" h3="${AWG_H3}" h4="${AWG_H4}"
    if [[ "$protocol_version" == "1.5" ]]; then
        h1="${h1%%-*}"; h2="${h2%%-*}"; h3="${h3%%-*}"; h4="${h4%%-*}"
    fi
    cat >> "$tmpfile" << EOF
H1 = ${h1}
H2 = ${h2}
H3 = ${h3}
H4 = ${h4}
EOF

    if [[ "$protocol_version" == "3.0" || "$protocol_version" == "3.1" ]]; then
        _awg31_render_extra_fields >> "$tmpfile" || { rm -f "$tmpfile"; return 1; }
    fi

    if _awg_protocol_has_cps; then
    [[ -n "${AWG_I1:-}" ]] && echo "I1 = ${AWG_I1}" >> "$tmpfile"
    [[ -n "${AWG_I2:-}" ]] && echo "I2 = ${AWG_I2}" >> "$tmpfile"
    [[ -n "${AWG_I3:-}" ]] && echo "I3 = ${AWG_I3}" >> "$tmpfile"
    [[ -n "${AWG_I4:-}" ]] && echo "I4 = ${AWG_I4}" >> "$tmpfile"
    [[ -n "${AWG_I5:-}" ]] && echo "I5 = ${AWG_I5}" >> "$tmpfile"
    fi
    if [[ "${AWG_WIRESOCK_HINTS:-off}" != "off" ]]; then
        render_wiresock_hints >> "$tmpfile" || { rm -f "$tmpfile"; log_error "Некорректные WireSock compatibility hints"; return 1; }
    fi

    cat >> "$tmpfile" << EOF

[Peer]
PublicKey = ${server_pubkey}
EOF
    # PresharedKey — опциональный дополнительный слой поверх AWG 2.0
    # обфускации (включается через `manage add --psk`). Должен совпадать
    # в server peer и client [Peer].
    if [[ -n "${CLIENT_PSK:-}" ]]; then
        echo "PresharedKey = ${CLIENT_PSK}" >> "$tmpfile"
    fi
    cat >> "$tmpfile" << EOF
Endpoint = ${endpoint}:${port}
AllowedIPs = ${allowed_ips}
PersistentKeepalive = 25
EOF

    if ! mv "$tmpfile" "$conf_file"; then
        rm -f "$tmpfile"
        log_error "Ошибка записи конфига клиента '$name'"
        return 1
    fi
    chmod 600 "$conf_file"
    log_debug "Конфиг для '$name' создан: $conf_file"
    return 0
}

# ==============================================================================
# Операции, перезапускающие интерфейс: предупреждение и обратимость
# ==============================================================================

# awg_ssh_client_addr : адрес источника текущей SSH-сессии (пусто, если это не
# SSH или определить не удалось).
#
# ⚠️ Одного $SSH_CONNECTION НЕДОСТАТОЧНО: скрипт запускают через sudo, а sudo по
# умолчанию делает env_reset, и SSH_CONNECTION в env_keep Debian/Ubuntu не
# входит. Поэтому второй путь - who по нашему собственному tty.
# who может отдать имя хоста вместо адреса (при UseDNS yes); тогда сверка с
# подсетью не состоится, и вызывающий получит "определить не удалось" - это
# честнее, чем угадывать.
awg_ssh_client_addr() {
    local from_tty="" from_env="" mytty
    mytty=$(ps -o tty= -p $$ 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$mytty" && "$mytty" != "?" ]]; then
        from_tty=$(who 2>/dev/null | awk -v t="$mytty" '
            $2 == t && match($0, /\(([^)]+)\)/) {
                print substr($0, RSTART + 1, RLENGTH - 2); exit
            }')
    fi
    [[ -n "${SSH_CONNECTION:-}" ]] && from_env="${SSH_CONNECTION%% *}"
    # ⚠️ Приоритет у данных ПО НАШЕМУ tty, а не у унаследованной переменной.
    # SSH_CONNECTION приезжает из окружения и в переподключённой сессии
    # tmux/screen может указывать на ПРЕЖНЕЕ подключение - тогда мы выдали бы
    # уверенно неверный вердикт. utmp по своему tty описывает текущее.
    # Но если tty-путь дал не адрес (при UseDNS yes там будет имя хоста),
    # берём переменную: годный адрес полезнее честного «не знаю».
    if _valid_ipv4 "$from_tty" 2>/dev/null; then
        printf '%s' "$from_tty"
    elif _valid_ipv4 "$from_env" 2>/dev/null; then
        printf '%s' "$from_env"
    elif [[ -n "$from_tty" ]]; then
        printf '%s' "$from_tty"
    else
        printf '%s' "$from_env"
    fi
}

# _awg_tunnel_subnet : подсеть туннеля как addr/prefix, либо пустая строка.
#
# 🔴 ДЕФОЛТА ЗДЕСЬ НЕТ СОЗНАТЕЛЬНО, и это исправление критического дефекта.
# Прежняя редакция подставляла литерал 10.9.9.1/24, а manage на пути команды
# restart НЕ загружает awgsetup_cfg.init - значит AWG_TUNNEL_SUBNET там пуст.
# У любого, кто поставил сервер с --subnet, сессия из его подсети (например
# 10.66.66.2) сравнивалась с чужой 10.9.9.0/24 и объявлялась "не через туннель":
# скрипт уверенно утверждал ОБРАТНОЕ ИСТИНЕ ровно в том сценарии, ради которого
# проверка написана, и не показывал ни предупреждения, ни подсказки про консоль.
# Подставленный литерал превращает "данных нет" в "данные есть, и они такие".
#
# Источники по убыванию достоверности: живой интерфейс, конфиг сервера,
# переменная (её выставляет load_awg_params на других путях). Ничего не нашли -
# пусто, и вызывающий обязан сказать "не знаю", а не угадывать.
_awg_tunnel_subnet() {
    local subnet_value=""
    subnet_value=$(ip -4 -o addr show awg0 2>/dev/null \
        | awk '{ for (i = 1; i <= NF; i++) if ($i == "inet") { print $(i + 1); exit } }')
    if [[ -z "$subnet_value" && -r "$SERVER_CONF_FILE" ]]; then
        subnet_value=$(awk '
            /^[[:space:]]*#/ { next }
            /^[[:space:]]*\[/ { inif = (tolower($0) ~ /^[[:space:]]*\[interface\]/) ? 1 : 0; next }
            inif && tolower($0) ~ /^[[:space:]]*address[[:space:]]*=/ {
                sub(/^[^=]*=[[:space:]]*/, "")
                n = split($0, parts, ",")
                for (i = 1; i <= n; i++) {
                    gsub(/[[:space:]]/, "", parts[i])
                    if (parts[i] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/) { print parts[i]; exit }
                }
            }' "$SERVER_CONF_FILE")
    fi
    [[ -z "$subnet_value" && -n "${AWG_TUNNEL_SUBNET:-}" ]] && subnet_value="$AWG_TUNNEL_SUBNET"
    printf '%s' "$subnet_value"
}

# awg_session_via_tunnel [адрес] : идёт ли текущая сессия ЧЕРЕЗ туннель VPN.
#   0 - да, адрес источника лежит в подсети туннеля (перезапуск оборвёт доступ);
#   1 - нет, адрес вне подсети;
#   2 - определить не удалось (не SSH, адрес не IPv4, подсеть НЕИЗВЕСТНА).
# Три состояния, а не два, сознательно: "не знаю" и "не через туннель" требуют
# РАЗНЫХ формулировок, а склеивание их в 1 выдавало бы догадку за факт.
# Адрес можно передать аргументом, чтобы вызывающий не спрашивал utmp дважды и
# не получил вердикт по одному адресу с текстом про другой.
awg_session_via_tunnel() {
    local addr="${1:-}" subnet net_int bcast_int addr_int
    [[ -n "$addr" ]] || addr="$(awg_ssh_client_addr)"
    [[ -n "$addr" ]] || return 2
    [[ "$addr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 2
    subnet="$(_awg_tunnel_subnet)"
    [[ -n "$subnet" ]] || return 2
    # 🔴 Префикс /31 и /32 не несёт диапазона хостов, поэтому по нему нельзя
    # ответить на наш вопрос: любой адрес кроме серверного окажется "вне
    # подсети", и мы уверенно сказали бы "доступ не пострадает" человеку,
    # сидящему в туннеле. Наш генератор пишет /16../30, но путь через живой
    # интерфейс наследует ЛЮБОЙ префикс, а /32 в [Interface] - обычная
    # практика WireGuard. Отвечаем "не знаю" (проверено на стенде).
    [[ "${subnet##*/}" =~ ^[0-9]+$ ]] || return 2
    (( 10#${subnet##*/} <= 30 )) || return 2
    read -r net_int bcast_int < <(_cidr_bounds "$subnet" 2>/dev/null) || return 2
    [[ -n "$net_int" && -n "$bcast_int" ]] || return 2
    addr_int="$(_ipv4_to_int "$addr" 2>/dev/null)" || return 2
    [[ -n "$addr_int" ]] || return 2
    (( addr_int >= net_int && addr_int <= bcast_int )) && return 0
    return 1
}

# awg_warn_interface_disruption : предупредить ДО операции, перезапускающей
# интерфейс. Вызывать раньше confirm_action, чтобы предупреждение было видно и
# при --yes (неинтерактивные запуски тоже отрезают людей от сервера).
awg_warn_interface_disruption() {
    local rc addr subnet
    log_warn "Интерфейс awg0 будет перезапущен - соединения всех клиентов прервутся на несколько секунд."
    # Адрес спрашиваем ОДИН раз и передаём в проверку: два независимых вызова
    # могли дать вердикт по одному адресу и текст про другой (или пустой).
    addr="$(awg_ssh_client_addr)"
    # Подсеть тоже резолвим ОДИН раз и ДО вердикта: прежняя редакция
    # спрашивала её второй раз уже после, и напечатанная подсеть могла
    # оказаться не той, по которой вердикт вынесен.
    subnet="$(_awg_tunnel_subnet)"
    # rc берём формой `|| rc=$?`, а НЕ `cmd; rc=$?`: под set -e вторая форма
    # прерывает функцию на ненулевом коде, то есть предупреждение оборвалось
    # бы на середине. В репозитории есть встроенный скрипт с set -euo
    # pipefail, поэтому это не гипотетический случай.
    rc=0
    awg_session_via_tunnel "$addr" || rc=$?
    case "$rc" in
        0)
            log_warn "ВНИМАНИЕ: похоже, вы подключены к серверу ЧЕРЕЗ этот же VPN."
            log_warn "  Адрес вашей сессии $addr входит в подсеть туннеля ${subnet},"
            log_warn "  значит после перезапуска текущее подключение оборвётся."
            log_warn "  Если доступ не вернётся сам - заходите через консоль или VNC в панели"
            log_warn "  вашего провайдера: она работает в обход VPN."
            ;;
        1)
            log_debug "Сессия идёт не через туннель (адрес $addr) - доступ к серверу не пострадает."
            ;;
        *)
            log_warn "  Если вы подключены к серверу ЧЕРЕЗ этот VPN, вы потеряете доступ."
            log_warn "  Запасной путь на такой случай - консоль или VNC в панели провайдера."
            ;;
    esac
}

# _awg_device_param_names : имена device-параметров AWG (2.0 и 3.0), которые
# живут в секции [Interface] и которые syncconf НЕ снимает.
_awg_device_param_names() {
    printf '%s\n' Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5 \
        ContentPaddingAddition HeaderProtectionKey MaxHandshakeAttempts \
        KeepaliveTimeout RejectAfterTime RekeyAfterTime RekeyTimeout
}

# _awg_device_params_fingerprint [конфиг] : отсортированный список ИМЁН
# device-параметров, присутствующих в секции [Interface]. Одной строкой.
# Только имена: значения syncconf применяет корректно, проблема ровно в снятии.
_awg_device_params_fingerprint() {
    local conf="${1:-$SERVER_CONF_FILE}" known
    [[ -r "$conf" ]] || return 1
    known="$(_awg_device_param_names | tr '\n' '|')"
    known="${known%|}"
    awk -v known="$known" '
        BEGIN { n = split(known, k, "|"); for (i = 1; i <= n; i++) low[tolower(k[i])] = k[i] }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*\[/ { inif = (tolower($0) ~ /^[[:space:]]*\[interface\]/) ? 1 : 0; next }
        inif && /=/ {
            name = $1
            sub(/[[:space:]]*=.*$/, "", name)
            gsub(/[[:space:]]/, "", name)
            if (tolower(name) in low) print low[tolower(name)]
        }
    ' "$conf" | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

# _awg_save_device_params <файл состояния> <отпечаток> : запомнить применённый
# набор. Файл в AWG_DIR (root-only), потеря = мягкая деградация: следующая
# проверка просто не сработает, лишнего перезапуска не будет.
# Запись АТОМАРНАЯ (temp + mv): оборванная запись оставила бы полупустой
# снимок, а он читается как «параметры убрали» и порождает ложное
# предупреждение. Отказ не глушим совсем - пишем в debug, иначе тихая потеря
# состояния выглядела бы как успех.
# Имя temp-файла ФИКСИРОВАННОЕ, а не с $$: если процесс убьют между записью и
# mv, следующий запуск перезапишет тот же файл, а не оставит россыпь сирот.
# Гонки нет - весь участок держит flock apply_config.
# ⚠️ Отказ записи идёт в log_warn, а НЕ в log_debug. log_debug печатает только
# при --verbose и в лог-файл при этом не попадает вовсе, то есть прежняя
# редакция обещала «не глушим совсем», а по факту глушила полностью. Причины
# отказа под root (ENOSPC, remount read-only, пропавший AWG_DIR) не мягкие: в
# этот момент под угрозой и awg0.conf, и бэкапы, и лог. return 0 оставлен -
# применение конфигурации не должно падать из-за диагностического снимка.
_awg_save_device_params() {
    local state="$1" fp="$2" tmp="${1}.tmp"
    if ! printf '%s\n' "$fp" > "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        log_warn "Не удалось записать снимок параметров интерфейса ($state) - проверьте место на диске и права."
        return 0
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$state" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        log_warn "Не удалось заменить снимок параметров интерфейса ($state) - проверьте место на диске и права."
    fi
    return 0
}

# awg_record_device_params : запомнить, какой набор device-параметров стоит в
# конфиге СЕЙЧАС. Вызывать ПОСЛЕ успешного применения или пересоздания
# интерфейса - снимок обязан означать «то, что реально стоит на живом
# интерфейсе», иначе обнаружение снятия начинает врать в обе стороны.
#
# 🔴 Два правила, каждое из которых закрывает найденный ревью дефект:
# 1. Отпечаток считается ЗАНОВО, а не берётся посчитанный до применения: если в
#    тот момент файл перезаписывался, посчитанное было неполным, и сохранение
#    его закрепило бы неверный набор.
# 2. ПУСТОЙ набор не пишем НИКОГДА. Пустой снимок отключает проверку навсегда
#    (сравнивать не с чем), а пустота почти всегда означает недочитанный файл:
#    наш генератор всегда пишет Jc/S/H. Лучше сохранить прежний хороший снимок.
awg_record_device_params() {
    local state="${AWG_DIR}/.awg_device_params" fp
    [[ -r "$SERVER_CONF_FILE" ]] || return 0
    fp="$(_awg_device_params_fingerprint "$SERVER_CONF_FILE" 2>/dev/null)" || return 0
    [[ -n "$fp" ]] || return 0
    _awg_save_device_params "$state" "$fp"
}

# ==============================================================================
# Применение конфигурации (syncconf)
# ==============================================================================

# Применение изменений конфигурации
# AWG_SKIP_APPLY=1: пропустить apply (для batch-автоматизации)
# AWG_APPLY_MODE=syncconf|restart: режим применения (конфиг или --apply-mode CLI)
# flock на .awg_apply.lock: защита от параллельных вызовов
apply_config() {
    # Пропуск apply (AWG_SKIP_APPLY=1 manage add/remove ...)
    if [[ "${AWG_SKIP_APPLY:-0}" == "1" ]]; then
        log_debug "apply_config пропущен (AWG_SKIP_APPLY=1)."
        return 0
    fi

    # Межпроцессная блокировка apply_config
    local apply_lockfile="${AWG_DIR}/.awg_apply.lock"
    local apply_fd
    exec {apply_fd}>"$apply_lockfile"
    if ! flock -x -w 120 "$apply_fd"; then
        log_warn "Не удалось получить блокировку apply_config."
        exec {apply_fd}>&-
        return 1
    fi

    local rc=0

    # 🔴 syncconf НЕ СНИМАЕТ device-параметры AWG. Проверено на модуле
    # 3.0.20260731-04: поставленные Jc/S4/H1/I1/ContentPaddingAddition/
    # RekeyAfterTime остались на живом интерфейсе после применения конфига, где
    # их нет. Семантика WireGuard («setconf = полная картина») для AWG-параметров
    # не действует, она аддитивна. Значит операция «убрать параметр из awg0.conf
    # и применить» тихо не сработала бы: файл изменился, интерфейс нет, и такое
    # расхождение ничем не ловится. Снять параметр можно только пересозданием
    # интерфейса, то есть перезапуском сервиса.
    #
    # Сравниваем НАБОР ИМЁН параметров с тем, что применяли в прошлый раз, а не
    # с живым интерфейсом: `awg showconf` печатает и нейтральные значения
    # (S4 = 0, H1 = 1), поэтому сверка с ним давала бы ложные срабатывания на
    # каждом применении. Значения не сравниваем вовсе - их syncconf применяет
    # корректно, проблема ровно в снятии.
    # Состояния нет (первая установка, потерянный файл) - молчим: сравнивать не
    # с чем, а предупреждать наугад хуже, чем не предупреждать.
    local params_state="${AWG_DIR}/.awg_device_params"
    local now_fp="" prev_fp="" removed=""
    if [[ -r "$SERVER_CONF_FILE" ]]; then
        # Путь передаём явно, хотя он же и по умолчанию: иначе shellcheck 0.9
        # (та версия, что стоит в CI) справедливо ругается SC2120 на параметр,
        # который никто никогда не передаёт.
        now_fp="$(_awg_device_params_fingerprint "$SERVER_CONF_FILE" 2>/dev/null)" || now_fp=""
        [[ -r "$params_state" ]] && IFS= read -r prev_fp 2>/dev/null < "$params_state"
        # ⚠️ Пустой набор при непустом прежнем НЕ считаем удалением всего.
        # Наш генератор всегда пишет Jc/S/H, поэтому пустота означает скорее
        # недочитанный или переписываемый в этот момент файл, чем реальную
        # чистку. Молчим: ложная тревога тут дороже пропущенной.
        if [[ -n "$prev_fp" && -n "$now_fp" ]]; then
            local _p
            for _p in $prev_fp; do
                [[ " $now_fp " == *" $_p "* ]] || removed+="${removed:+, }$_p"
            done
        fi
    fi

    if [[ "${AWG_APPLY_MODE:-syncconf}" == "restart" ]]; then
        # Явный restart-режим рвёт соединения клиентов, в том числе SSH через
        # туннель, поэтому предупреждаем так же, как при manage restart.
        awg_warn_interface_disruption
        log "Перезапуск сервиса (apply-mode=restart)..."
        systemctl restart awg-quick@awg0 2>/dev/null; rc=$?
        if [[ $rc -ne 0 ]]; then
            log_warn "Ошибка перезапуска."
        else
            awg_record_device_params
            ipv6_ndp_refresh_after_config_apply || rc=$?
        fi
        exec {apply_fd}>&-
        return $rc
    fi

    # 🔴 Обнаруженное снятие параметра НЕ перезапускаем сами - предупреждаем.
    # Первая редакция этой правки перезапускала сервис автоматически, и это было
    # ХУЖЕ той ловушки, которую закрывало: перезапуск рвёт соединения ВСЕХ
    # клиентов, а состояние может отстать без всякой вины пользователя. Пример:
    # человек убрал строку и применил её через `manage restart` - интерфейс уже
    # пересоздан, параметр уже снят, но снимок набора остался прежним, и
    # следующий обычный `add` увидел бы "удаление" второй раз и оборвал всех
    # заново. Цена ложного предупреждения - строка в журнале; цена ложного
    # перезапуска - обрыв у всех. Поэтому говорим, а решает человек.
    # ⚠️ Снимок здесь НЕ обновляем. Он обновляется только ПОСЛЕ успешного
    # применения, ниже. Прежняя редакция обновляла его сразу, и это гасило
    # предупреждение навсегда, если применение потом падало: состояние уже
    # «догнало» файл, а на живом интерфейсе не изменилось ничего.
    if [[ -n "$removed" ]]; then
        log_warn "Из секции [Interface] убрано: ${removed}."
        log_warn "  syncconf такие параметры НЕ снимает - на живом интерфейсе они останутся."
        log_warn "  Чтобы снятие вступило в силу, интерфейс надо пересоздать:"
        log_warn "    systemctl restart awg-quick@awg0"
        log_warn "  Это оборвёт соединения всех клиентов на несколько секунд, поэтому"
        log_warn "  сами мы этого не делаем. Если вы уже перезапускали сервис вручную,"
        log_warn "  предупреждение можно игнорировать: после успешного применения снимок"
        log_warn "  обновится, и на следующих запусках этой строки не будет."
    fi

    local strip_out
    strip_out=$(timeout 10 awg-quick strip awg0 2>/dev/null) || {
        log_warn "awg-quick strip не удался или timeout, использую полный перезапуск."
        # Этот перезапуск НЕ ожидаем: человек запускал рутинный add/remove.
        # Он рвёт всех клиентов, поэтому предупреждаем и здесь, а не только в
        # явном restart-режиме.
        awg_warn_interface_disruption
        systemctl restart awg-quick@awg0 2>/dev/null; rc=$?
        if [[ $rc -ne 0 ]]; then
            log_warn "Ошибка перезапуска."
        else
            awg_record_device_params
            ipv6_ndp_refresh_after_config_apply || rc=$?
        fi
        exec {apply_fd}>&-
        return $rc
    }
    echo "$strip_out" | timeout 10 awg syncconf awg0 /dev/stdin 2>/dev/null || {
        log_warn "awg syncconf не удался или timeout, использую полный перезапуск."
        # Как и выше: незапланированный перезапуск оборвёт всех, включая
        # SSH-сессию через туннель, - об этом надо сказать до, а не после.
        awg_warn_interface_disruption
        systemctl restart awg-quick@awg0 2>/dev/null; rc=$?
        if [[ $rc -ne 0 ]]; then
            log_warn "Ошибка перезапуска."
        else
            awg_record_device_params
            ipv6_ndp_refresh_after_config_apply || rc=$?
        fi
        exec {apply_fd}>&-
        return $rc
    }
    log_debug "Конфигурация применена (syncconf)."
    awg_record_device_params
    ipv6_ndp_refresh_after_config_apply || rc=$?
    exec {apply_fd}>&-
    return $rc
}

# ==============================================================================
# Управление пирами
# ==============================================================================

reserved_client_ipv4s_stream() {
    local subnet_base="$1"
    local escaped_base
    escaped_base=$(printf '%s' "$subnet_base" | sed 's/\./\\./g')

    if [[ -f "$SERVER_CONF_FILE" ]]; then
        grep -oP 'AllowedIPs\s*=\s*\K[0-9.]+' "$SERVER_CONF_FILE" 2>/dev/null || true
    fi
    if [[ -d "$AWG_DIR" ]]; then
        grep -hoP 'Address\s*=\s*\K[0-9.]+' "$AWG_DIR"/*.conf 2>/dev/null || true
        grep -hoE "${escaped_base}\\.[0-9]{1,3}" "$AWG_DIR/postup.sh" "$AWG_DIR/postdown.sh" "$AWG_DIR/p2p_rules.sh" 2>/dev/null || true
        if [[ -d "$AWG_DIR/adguard" ]]; then
            grep -RhoE "${escaped_base}\\.[0-9]{1,3}" "$AWG_DIR/adguard" 2>/dev/null || true
        fi
    fi
}

# Получить следующий свободный IP в подсети
get_next_client_ip() {
    local subnet="${AWG_TUNNEL_SUBNET:-10.9.9.1/24}"
    local net_int bcast_int
    read -r net_int bcast_int < <(_cidr_bounds "$subnet") || {
        log_error "get_next_client_ip: не удалось разобрать подсеть '$subnet'"
        return 1
    }
    # Ассоциативный массив для O(1) lookup. Сервер (network+1) занят.
    local server_ip
    server_ip=$(_int_to_ipv4 $((net_int + 1)))
    declare -A used_set
    used_set["$server_ip"]=1
    while IFS= read -r ip; do
        [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && used_set["$ip"]=1
    done < <(reserved_client_ipv4s_stream "")

    local i candidate
    for (( i = net_int + 1; i <= bcast_int - 1; i++ )); do
        candidate=$(_int_to_ipv4 "$i")
        if [[ -z "${used_set[$candidate]+x}" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    log_error "Нет свободных IP в подсети ${subnet}"
    return 1
}

sync_clients_hosts() {
    local hosts_file="${AWG_HOSTS_FILE:-/etc/hosts}"
    [[ -f "$SERVER_CONF_FILE" ]] || return 0
    [[ -n "$hosts_file" ]] || return 0

    local dir tmp body
    dir=$(dirname "$hosts_file")
    mkdir -p "$dir" 2>/dev/null || {
        log_warn "Не удалось создать каталог для hosts: $dir"
        return 0
    }
    tmp=$(awg_mktemp) || return 0
    body=$(awg_mktemp) || return 0

    awk '
    function dns_alias(src, out) {
        out=tolower(src)
        gsub(/[^a-z0-9-]/, "-", out)
        gsub(/-+/, "-", out)
        sub(/^-+/, "", out)
        sub(/-+$/, "", out)
        if (out == "") out="client"
        if (length(out) > 63) {
            out=substr(out, 1, 63)
            sub(/-+$/, "", out)
        }
        return out ".awg"
    }
    function emit() {
        if (name != "" && ipv4 != "") {
            alias=dns_alias(name)
            print ipv4 " " name " " alias
            if (ipv6 != "") print ipv6 " " name " " alias
        }
    }
    /^\[Peer\]/ { emit(); name=""; ipv4=""; ipv6=""; in_peer=1; next }
    /^\[/ && !/^\[Peer\]/ { emit(); name=""; ipv4=""; ipv6=""; in_peer=0; next }
    in_peer && /^#_Name = / { name=$0; sub(/^#_Name = /, "", name); next }
    in_peer && /^AllowedIPs[[:space:]]*=/ {
        line=$0
        sub(/^AllowedIPs[[:space:]]*=[[:space:]]*/, "", line)
        gsub(/,/, " ", line)
        n=split(line, parts, /[[:space:]]+/)
        for (i=1; i<=n; i++) {
            token=parts[i]
            if (token ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/32$/) {
                sub(/\/32$/, "", token)
                ipv4=token
            } else if (token ~ /^[0-9A-Fa-f:]+\/128$/) {
                sub(/\/128$/, "", token)
                ipv6=token
            }
        }
        next
    }
    END { emit() }
    ' "$SERVER_CONF_FILE" > "$body" 2>/dev/null || return 0

    if [[ -f "$hosts_file" ]]; then
        awk '
        /^# --- AWG CLIENTS START ---$/ { skip=1; next }
        /^# --- AWG CLIENTS END ---$/ { skip=0; next }
        /^# BEGIN AmneziaWG clients$/ { skip=1; next }
        /^# END AmneziaWG clients$/ { skip=0; next }
        !skip { print }
        ' "$hosts_file" > "$tmp" 2>/dev/null || cp "$hosts_file" "$tmp" 2>/dev/null || return 0
    fi

    if [[ -s "$body" ]]; then
        {
            printf '\n# --- AWG CLIENTS START ---\n'
            cat "$body"
            printf '# --- AWG CLIENTS END ---\n'
        } >> "$tmp"
    fi

    if mv "$tmp" "$hosts_file"; then
        chmod 644 "$hosts_file" 2>/dev/null || true
        log_debug "hosts обновлён для клиентов AmneziaWG: $hosts_file"
    else
        log_warn "Не удалось обновить hosts для клиентов: $hosts_file"
    fi
}

sync_adguard_clients() {
    local ag_dir="${AWG_ADGUARD_DIR:-/opt/AdGuardHome}"
    local ag_yaml="$ag_dir/AdGuardHome.yaml"
    [[ -f "$SERVER_CONF_FILE" && -f "$ag_yaml" ]] || return 0

    python3 - "$SERVER_CONF_FILE" "$ag_yaml" <<'PY'
import json
import re
import sys
from pathlib import Path

server_conf = Path(sys.argv[1])
ag_yaml = Path(sys.argv[2])

def parse_peers(path):
    peers = []
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
            continue
        if re.match(r"^AllowedIPs\s*=", line):
            value = line.split("=", 1)[1]
            for token in re.split(r"[,\s]+", value):
                token = token.strip()
                if token.endswith("/32") or token.endswith("/128"):
                    cur["ids"].append(token.rsplit("/", 1)[0])
    if cur and cur.get("name") and cur.get("ids"):
        peers.append(cur)
    return peers

def top_level(line):
    return line and not line.startswith((" ", "\t")) and ":" in line

def remove_top_block(lines, key):
    out = []
    i = 0
    needle = f"{key}:"
    while i < len(lines):
        if lines[i].strip() == needle and not lines[i].startswith((" ", "\t")):
            i += 1
            while i < len(lines) and not top_level(lines[i]):
                i += 1
            continue
        out.append(lines[i])
        i += 1
    return out

def render_clients(peers):
    out = ["clients:"]
    if peers:
        out.append("  persistent:")
        for peer in peers:
            out.append(f"    - name: {json.dumps(peer['name'], ensure_ascii=False)}")
            out.append("      ids:")
            for client_id in peer["ids"]:
                out.append(f"        - {json.dumps(client_id, ensure_ascii=False)}")
    else:
        out.append("  persistent: []")
    out.extend([
        "  runtime_sources:",
        "    whois: true",
        "    arp: true",
        "    rdns: true",
        "    dhcp: true",
        "    hosts: true",
    ])
    return out

def render_rewrites(peers):
    entries = []
    for peer in peers:
        label = re.sub(r"[^a-z0-9-]+", "-", peer["name"].lower())
        label = re.sub(r"-+", "-", label).strip("-") or "client"
        label = label[:63].rstrip("-") or "client"
        domain = f"{label}.awg"
        for client_id in peer["ids"]:
            entries.append((domain, client_id))
    if not entries:
        return ["  rewrites: []"]
    out = ["  rewrites:"]
    for domain, answer in entries:
        out.append(f"    - domain: {json.dumps(domain, ensure_ascii=False)}")
        out.append(f"      answer: {json.dumps(answer, ensure_ascii=False)}")
    return out

def upsert_filtering_rewrites(lines, peers):
    rewrites = render_rewrites(peers)
    out = []
    i = 0
    found_filtering = False
    while i < len(lines):
        line = lines[i]
        if line.strip() == "filtering:" and not line.startswith((" ", "\t")):
            found_filtering = True
            out.append(line)
            out.extend(rewrites)
            i += 1
            while i < len(lines) and not top_level(lines[i]):
                if re.match(r"^  rewrites\s*:", lines[i]):
                    i += 1
                    while i < len(lines) and not top_level(lines[i]) and not re.match(r"^  [A-Za-z0-9_-]+:", lines[i]):
                        i += 1
                    continue
                out.append(lines[i])
                i += 1
            continue
        out.append(line)
        i += 1
    if not found_filtering:
        out.extend(["filtering:", *rewrites])
    return out

peers = parse_peers(server_conf)
lines = ag_yaml.read_text(encoding="utf-8", errors="ignore").splitlines()
lines = remove_top_block(lines, "clients")
lines = upsert_filtering_rewrites(lines, peers)

insert_at = len(lines)
for idx, line in enumerate(lines):
    if line.startswith("log:") or line.startswith("os:") or line.startswith("schema_version:"):
        insert_at = idx
        break
lines[insert_at:insert_at] = render_clients(peers)

new_text = "\n".join(lines).rstrip() + "\n"
old_text = ag_yaml.read_text(encoding="utf-8", errors="ignore")
if new_text != old_text:
    tmp = ag_yaml.with_name(f"{ag_yaml.name}.tmp")
    tmp.write_text(new_text, encoding="utf-8")
    tmp.chmod(0o600)
    tmp.replace(ag_yaml)
    ag_yaml.chmod(0o600)
PY
}

# Добавление [Peer] в серверный конфиг (атомарно через tmpfile + mv).
#
# КОНТРАКТ БЛОКИРОВКИ: вызывающий код ОБЯЗАН держать exclusive flock на
# ${AWG_DIR}/.awg_config.lock когда вызывает эту функцию. Эту блокировку
# берёт generate_client() — единственный текущий caller. Не вызывать
# add_peer_to_server напрямую без удержания lock'а.
#
# Почему inner flock здесь невозможен: bash flock не re-entrant между
# разными file descriptors на тот же файл. generate_client() открывает
# .awg_config.lock на свой fd и держит exclusive lock, а попытка
# открыть тот же файл на новый fd внутри add_peer_to_server и взять
# на нём exclusive lock приводит к самоблокировке (родительский lock
# виден как чужой). Контракт-based locking — единственный надёжный
# вариант для bash в этой ситуации. Re-entrant поведение возможно
# только если sub-функция использует TOТ ЖЕ fd что родитель (через
# inheritance), но это требует передачи fd как аргумента.
#
# add_peer_to_server <name> <pubkey> <client_ip> [client_ipv6] [p2p_ports]
add_peer_to_server() {
    local name="$1"
    local pubkey="$2"
    local client_ip="$3"
    local client_ipv6="${4:-}"
    local p2p_ports="${5:-}"

    if [[ -z "$name" || -z "$pubkey" || -z "$client_ip" ]]; then
        log_error "add_peer_to_server: недостаточно аргументов"
        return 1
    fi
    # Имя уходит в heredoc конфига (#_Name = ...): перевод строки в имени
    # дал бы инъекцию секции [Peer]. Defense-in-depth, см. generate_client.
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "add_peer_to_server: невалидное имя клиента '$name'"
        return 1
    fi

    if grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Пир '$name' уже существует в конфиге"
        return 1
    fi

    # Добавляем пир через временный файл (атомарно).
    # temp в каталоге серверного конфига -> mv = атомарный rename на той же ФС.
    local tmpfile
    tmpfile=$(awg_mktemp "$(dirname "$SERVER_CONF_FILE")") || { log_error "Ошибка mktemp"; return 1; }

    cp "$SERVER_CONF_FILE" "$tmpfile" || {
        rm -f "$tmpfile"
        log_error "Ошибка копирования серверного конфига"
        return 1
    }

    cat >> "$tmpfile" << EOF

[Peer]
#_Name = ${name}
#_IPv4 = on
#_IPv4Address = ${client_ip}/32
PublicKey = ${pubkey}
EOF
    # PresharedKey — опционально, пишется если передан через CLIENT_PSK env.
    # Должен совпадать у server peer и client [Peer].
    if [[ -n "${CLIENT_PSK:-}" ]]; then
        echo "PresharedKey = ${CLIENT_PSK}" >> "$tmpfile"
    fi
    if [[ -n "$p2p_ports" ]]; then
        echo "#_P2PPorts_Disabled = ${p2p_ports}" >> "$tmpfile"
    fi
    if [[ -n "$client_ipv6" ]]; then
        printf '%s\n' "#_IPv6 = on" "#_IPv6Address = ${client_ipv6}/128" >> "$tmpfile"
        echo "AllowedIPs = ${client_ip}/32, ${client_ipv6}/128" >> "$tmpfile"
    else
        echo "AllowedIPs = ${client_ip}/32" >> "$tmpfile"
    fi

    if ! mv "$tmpfile" "$SERVER_CONF_FILE"; then
        rm -f "$tmpfile"
        log_error "Ошибка обновления серверного конфига"
        return 1
    fi
    chmod 600 "$SERVER_CONF_FILE"
    generate_firewall_scripts >/dev/null 2>&1 || log_warn "Не удалось обновить P2P/firewall hook-скрипты."
    sync_clients_hosts
    log "Пир '$name' добавлен в серверный конфиг."
    return 0
}

# set_client_ip_family <name> <ipv4|ipv6> <on|off>
# Keep the family permission as explicit peer metadata so disabling a family
# does not destroy the address needed to re-enable it later. Legacy peers with
# no markers are treated as enabled for every address present in AllowedIPs.
set_client_ip_family() {
    local name="$1" family="$2" state="$3"
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || { log_error "Invalid client name"; return 1; }
    [[ "$family" == "ipv4" || "$family" == "ipv6" ]] || { log_error "Family must be ipv4 or ipv6"; return 1; }
    [[ "$state" == "on" || "$state" == "off" ]] || { log_error "State must be on or off"; return 1; }
    [[ -f "$SERVER_CONF_FILE" && -f "$AWG_DIR/${name}.conf" ]] || { log_error "Client '$name' files not found"; return 1; }

    local lockfile="${AWG_DIR}/.awg_config.lock" lock_fd
    exec {lock_fd}>"$lockfile"
    flock -x -w 30 "$lock_fd" || { log_error "Could not lock AWG configuration"; exec {lock_fd}>&-; return 1; }

    local backup_server backup_client
    backup_server="${SERVER_CONF_FILE}.bak-family-$(date +%s)"
    backup_client="$AWG_DIR/${name}.conf.bak-family-$(date +%s)"
    cp -- "$SERVER_CONF_FILE" "$backup_server" && cp -- "$AWG_DIR/${name}.conf" "$backup_client" || {
        rm -f -- "$backup_server" "$backup_client"; exec {lock_fd}>&-; log_error "Could not create family-permission backup"; return 1;
    }
    if ! AWG_FAMILY_NAME="$name" AWG_FAMILY="$family" AWG_FAMILY_STATE="$state" \
        AWG_FAMILY_SERVER="$SERVER_CONF_FILE" AWG_FAMILY_CLIENT="$AWG_DIR/${name}.conf" \
        python3 - <<'PY'
import os, re, sys, tempfile
from pathlib import Path

name = os.environ["AWG_FAMILY_NAME"]
family = os.environ["AWG_FAMILY"]
state = os.environ["AWG_FAMILY_STATE"]
server_path = Path(os.environ["AWG_FAMILY_SERVER"])
client_path = Path(os.environ["AWG_FAMILY_CLIENT"])
address_re = re.compile(r"^(\s*)(#\s*)?AllowedIPs\s*=\s*(.*)$")
state_re = re.compile(r"^#_(IPv4|IPv6)\s*=\s*(on|off)\s*$")
address_marker_re = re.compile(r"^#_(IPv4|IPv6)Address\s*=\s*(\S+)\s*$")

def split_tokens(value):
    return [x for x in re.split(r"[\s,]+", value.strip()) if x]

def transform_server(text):
    lines = text.splitlines()
    blocks, current = [], []
    for line in lines:
        if line in ("[Peer]", "# [Peer]") and current:
            blocks.append(current); current = []
        current.append(line)
    if current: blocks.append(current)
    found = False
    for block in blocks:
        if f"#_Name = {name}" not in block:
            continue
        found = True
        addresses = {"ipv4": None, "ipv6": None}
        states = {"ipv4": None, "ipv6": None}
        allowed_index = None
        for i, line in enumerate(block):
            mm = state_re.match(line)
            if mm:
                states[mm.group(1).lower()] = mm.group(2)
            amark = address_marker_re.match(line)
            if amark:
                addresses[amark.group(1).lower()] = amark.group(2)
            am = address_re.match(line)
            if am:
                allowed_index = i
                for token in split_tokens(am.group(3)):
                    if token.endswith("/32") and re.fullmatch(r"\d+\.\d+\.\d+\.\d+/32", token): addresses["ipv4"] = addresses["ipv4"] or token
                    if token.endswith("/128") and ":" in token: addresses["ipv6"] = addresses["ipv6"] or token
        for fam in ("ipv4", "ipv6"):
            states[fam] = states[fam] or ("on" if addresses[fam] else "off")
        states[family] = state
        if states["ipv4"] == "off" and states["ipv6"] == "off": raise ValueError("both IP families cannot be disabled")
        if states["ipv4"] == "on" and not addresses["ipv4"]: raise ValueError("peer has no recoverable IPv4 address")
        if states["ipv6"] == "on" and not addresses["ipv6"]: raise ValueError("peer has no recoverable IPv6 address")
        if allowed_index is None: raise ValueError("peer has no AllowedIPs")
        address_values = []
        if states["ipv4"] == "on": address_values.append(addresses["ipv4"])
        if states["ipv6"] == "on": address_values.append(addresses["ipv6"])
        block[allowed_index] = "AllowedIPs = " + ", ".join(address_values)
        block[:] = [line for line in block if not (state_re.match(line) or address_marker_re.match(line))]
        insert_at = next((i for i, line in enumerate(block) if line == f"#_Name = {name}"), 0) + 1
        block[insert_at:insert_at] = [
            f"#_IPv4 = {states['ipv4']}", f"#_IPv4Address = {addresses['ipv4'] or ''}",
            f"#_IPv6 = {states['ipv6']}", f"#_IPv6Address = {addresses['ipv6'] or ''}",
        ]
        break
    if not found: raise ValueError("client peer not found")
    return "\n".join(line for block in blocks for line in block) + "\n"

def transform_client(text):
    lines = text.splitlines()
    address_index = next((i for i, line in enumerate(lines) if re.match(r"^\s*Address\s*=", line)), None)
    if address_index is None: raise ValueError("client Address is missing")
    values = split_tokens(lines[address_index].split("=", 1)[1])
    kept = [x for x in values if not (family == "ipv4" and x.endswith("/32")) and not (family == "ipv6" and x.endswith("/128"))]
    if state == "on":
        server = transform_server(server_path.read_text(encoding="utf-8"))
        match = re.search(rf"#_Name = {re.escape(name)}.*?(?=\n\[Peer\]|\Z)", server, re.S)
        address = re.search(r"#_IPv4Address = (\S+)" if family == "ipv4" else r"#_IPv6Address = (\S+)", match.group(0) if match else "")
        if not address: raise ValueError("family address marker is missing")
        kept.append(address.group(1))
    if not kept: raise ValueError("both IP families cannot be disabled")
    order = sorted(set(kept), key=lambda x: 0 if x.endswith("/32") else 1)
    lines[address_index] = "Address = " + ", ".join(order)
    return "\n".join(lines) + "\n"

server_text = transform_server(server_path.read_text(encoding="utf-8"))
client_text = transform_client(client_path.read_text(encoding="utf-8"))
for path, text in ((server_path, server_text), (client_path, client_text)):
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.family.", dir=str(path.parent), text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle: handle.write(text)
        os.chmod(tmp, 0o600); os.replace(tmp, path)
    finally:
        try: os.unlink(tmp)
        except FileNotFoundError: pass
PY
    then
        cp -- "$backup_server" "$SERVER_CONF_FILE"; cp -- "$backup_client" "$AWG_DIR/${name}.conf"
        rm -f -- "$backup_server" "$backup_client"; exec {lock_fd}>&-; log_error "Family permission update failed"; return 1
    fi
    if [[ "${AWG_SKIP_APPLY:-0}" != "1" ]] && ! apply_config; then
        cp -- "$backup_server" "$SERVER_CONF_FILE" 2>/dev/null || true
        cp -- "$backup_client" "$AWG_DIR/${name}.conf" 2>/dev/null || true
        rm -f -- "$backup_server" "$backup_client"
        exec {lock_fd}>&-; log_error "Family permission changed on disk but apply failed"; return 1
    fi
    rm -f -- "$backup_server" "$backup_client"
    exec {lock_fd}>&-
    log "Client '$name' $family permission: $state"
    return 0
}

# Удаление [Peer] из серверного конфига по имени (с блокировкой)
# remove_peer_from_server <name>
remove_peer_from_server() {
    local name="$1"

    if [[ -z "$name" ]]; then
        log_error "remove_peer_from_server: не указано имя"
        return 1
    fi
    # Defense-in-depth: тот же контракт, что в add_peer_to_server.
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "remove_peer_from_server: невалидное имя клиента '$name'"
        return 1
    fi

    # Межпроцессная блокировка
    local lockfile="${AWG_DIR}/.awg_config.lock"
    local lock_fd
    exec {lock_fd}>"$lockfile"
    if ! flock -x -w 10 "$lock_fd"; then
        log_error "Не удалось получить блокировку конфига"
        exec {lock_fd}>&-
        return 1
    fi

    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Пир '$name' не найден в конфиге"
        exec {lock_fd}>&-
        return 1
    fi

    # temp в каталоге серверного конфига -> финальный mv = атомарный rename.
    local tmpfile
    tmpfile=$(awg_mktemp "$(dirname "$SERVER_CONF_FILE")") || { log_error "Ошибка mktemp"; exec {lock_fd}>&-; return 1; }

    # Удаляем блок [Peer] содержащий #_Name = name
    # Логика: буферизуем каждый [Peer] блок, проверяем имя, выводим только если не совпадает
    awk -v target="$name" '
    BEGIN { buf=""; is_target=0 }
    /^\[Peer\]/ {
        # Вывести предыдущий буфер если он не target
        if (buf != "" && !is_target) printf "%s", buf
        buf = $0 "\n"
        is_target = 0
        next
    }
    /^\[/ && !/^\[Peer\]/ {
        # Любая другая секция — сбросить буфер
        if (buf != "" && !is_target) printf "%s", buf
        buf = ""
        is_target = 0
        print
        next
    }
    {
        if (buf != "") {
            buf = buf $0 "\n"
            if ($0 == "#_Name = " target) is_target = 1
        } else {
            print
        }
    }
    END {
        if (buf != "" && !is_target) printf "%s", buf
    }
    ' "$SERVER_CONF_FILE" > "$tmpfile" || {
        log_error "Ошибка фильтрации серверного конфига (awk)"
        rm -f "$tmpfile"
        exec {lock_fd}>&-
        return 1
    }

    # Sanity-check ДО mv: при ENOSPC/I/O-сбое awk оставил бы пустой/обрезанный
    # tmpfile, и атомарный mv заменил бы рабочий конфиг битым (потеря
    # PrivateKey сервера и всех пиров). [Interface] обязан сохраниться.
    if ! grep -q '^\[Interface\]' "$tmpfile"; then
        log_error "Результат удаления пира выглядит битым ([Interface] отсутствует) - конфиг не изменён"
        rm -f "$tmpfile"
        exec {lock_fd}>&-
        return 1
    fi

    # Нормализация: сжать множественные пустые строки в одну.
    # tmpclean - на той же ФС, что и tmpfile (mv tmpclean->tmpfile атомарен).
    local tmpclean
    tmpclean=$(awg_mktemp "$(dirname "$SERVER_CONF_FILE")") || { log_error "Ошибка mktemp"; exec {lock_fd}>&-; return 1; }
    if cat -s "$tmpfile" > "$tmpclean" 2>/dev/null; then
        mv "$tmpclean" "$tmpfile"
    else
        rm -f "$tmpclean"
    fi

    if ! mv "$tmpfile" "$SERVER_CONF_FILE"; then
        rm -f "$tmpfile"
        log_error "Ошибка обновления серверного конфига"
        exec {lock_fd}>&-
        return 1
    fi
    chmod 600 "$SERVER_CONF_FILE"
    exec {lock_fd}>&-
    generate_firewall_scripts >/dev/null 2>&1 || log_warn "Не удалось обновить P2P/firewall hook-скрипты."
    sync_clients_hosts
    log "Пир '$name' удалён из серверного конфига."
    return 0
}

# ==============================================================================
# Полный цикл работы с клиентом
# ==============================================================================

# Генерация QR-кода для клиента
# generate_qr <name>
generate_qr() {
    local name="$1"
    local conf_file="$AWG_DIR/${name}.conf"
    local png_file="$AWG_DIR/${name}.png"

    if [[ ! -f "$conf_file" ]]; then
        log_error "Конфиг клиента '$name' не найден: $conf_file"
        return 1
    fi

    if ! command -v qrencode &>/dev/null; then
        log_warn "qrencode не установлен, QR-код не создан для '$name'."
        return 1
    fi

    # C4: генерируем во временный файл и атомарно переносим (mv) - чтобы
    # прерывание qrencode не оставило частичный/битый PNG поверх рабочего.
    # awg_mktemp "$AWG_DIR" кладёт tmp в ту же папку (mv = атомарный rename на
    # одной ФС) И регистрирует его в общем cleanup-реестре, поэтому SIGKILL
    # между qrencode и mv не оставит осиротевший tmp.
    local tmp_png
    tmp_png=$(awg_mktemp "$AWG_DIR") || { log_error "Ошибка mktemp для QR '$name'"; return 1; }
    if ! qrencode -t png -o "$tmp_png" < "$conf_file"; then
        log_error "Ошибка генерации QR-кода для '$name'"
        rm -f "$tmp_png"
        return 1
    fi
    chmod 600 "$tmp_png" 2>/dev/null
    if ! mv -f "$tmp_png" "$png_file"; then
        log_error "Ошибка сохранения QR-кода для '$name'"
        rm -f "$tmp_png"
        return 1
    fi
    log_debug "QR-код для '$name' создан: $png_file"
    return 0
}

# Генерация vpn:// URI для импорта в Amnezia Client
# generate_vpn_uri <name>
generate_vpn_uri() {
    local name="$1"
    local conf_file="$AWG_DIR/${name}.conf"
    local uri_file="$AWG_DIR/${name}.vpnuri"

    if [[ ! -f "$conf_file" ]]; then
        log_error "Конфиг клиента '$name' не найден: $conf_file"
        return 1
    fi

    if ! command -v perl &>/dev/null; then
        log_warn "perl не найден, vpn:// URI не создан для '$name'."
        return 1
    fi

    if ! perl -MCompress::Zlib -MMIME::Base64 -e '1' 2>/dev/null; then
        log_warn "Perl модули Compress::Zlib/MIME::Base64 не найдены, vpn:// URI не создан."
        return 1
    fi

    load_awg_params || return 1

    # Prefer the typed Python renderer.  Keep the Perl path below as a
    # compatibility fallback for already-installed versions during upgrades.
    local uri_generator="$AWG_DIR/scripts/gen_vpn_uri.py" py_uri_tmp py_uri_err
    if [[ -f "$uri_generator" ]] && command -v python3 &>/dev/null; then
        local _uri_client_key _uri_server_key _uri_psk
        _uri_client_key=$(grep -oP 'PrivateKey\s*=\s*\K\S+' "$conf_file") || return 1
        _uri_psk=$(awk '/^[[:space:]]*PresharedKey[[:space:]]*=/{sub(/^[[:space:]]*PresharedKey[[:space:]]*=[[:space:]]*/, ""); sub(/\r$/, ""); sub(/[ \t]+$/, ""); print; exit}' "$conf_file" 2>/dev/null)
        _ensure_server_public_key || return 1
        _uri_server_key=$(cat "$AWG_DIR/server_public.key" 2>/dev/null) || return 1
        py_uri_tmp=$(awg_mktemp "$AWG_DIR") || return 1
        py_uri_err=$(awg_mktemp "$AWG_DIR") || { rm -f "$py_uri_tmp"; return 1; }
        if AWG_URI_CPK="$_uri_client_key" AWG_URI_PSK="$_uri_psk" AWG_URI_SPK="$_uri_server_key" \
            python3 "$uri_generator" --conf "$conf_file" >"$py_uri_tmp" 2>"$py_uri_err"; then
            chmod 600 "$py_uri_tmp" && mv -f "$py_uri_tmp" "$uri_file"
            rm -f "$py_uri_err"
            log_debug "vpn:// URI для '$name' создан: $uri_file"
            return 0
        fi
        rm -f "$py_uri_tmp"
        [[ -s "$py_uri_err" ]] && log_warn "Python vpn:// renderer failed for '$name': $(cat "$py_uri_err")"
        rm -f "$py_uri_err"
        return 1
    fi

    # AWG_PORT - единственное НЕкавыченное числовое поле inner JSON ("port":N).
    # Пустое/нечисловое значение дало бы "port":, - синтаксически битый JSON,
    # который Amnezia Client молча не импортирует.
    if ! [[ "${AWG_PORT:-}" =~ ^[0-9]+$ ]]; then
        log_warn "AWG_PORT не определён или не число ('${AWG_PORT:-}') - vpn:// URI не создан для '$name'."
        return 1
    fi

    local client_privkey client_ip client_ipv6 server_pubkey endpoint allowed_ips client_psk
    client_privkey=$(grep -oP 'PrivateKey\s*=\s*\K\S+' "$conf_file") || return 1
    # Извлекаем IPv4 из Address (первое поле до запятой, без /prefix).
    # Regex останавливается на цифрах и точках - не захватывает IPv6 при dual-stack.
    client_ip=$(awk '/^Address[[:space:]]*=/{
        sub(/^Address[[:space:]]*=[[:space:]]*/, "")
        sub(/\r$/, "")
        n = split($0, parts, /[[:space:]]*,[[:space:]]*/)
        sub(/\/[0-9]+$/, "", parts[1])
        print parts[1]; exit
    }' "$conf_file") || return 1
    # Извлекаем IPv6 из Address (второе поле, если присутствует), без /prefix.
    client_ipv6=$(awk '/^Address[[:space:]]*=/{
        sub(/^Address[[:space:]]*=[[:space:]]*/, "")
        sub(/\r$/, "")
        n = split($0, parts, /[[:space:]]*,[[:space:]]*/)
        if (n >= 2) {
            sub(/\/[0-9]+$/, "", parts[2])
            gsub(/[[:space:]]/, "", parts[2])
            print parts[2]
        }
        exit
    }' "$conf_file" 2>/dev/null)
    client_ipv6="${client_ipv6:-}"
    _ensure_server_public_key || return 1
    server_pubkey=$(cat "$AWG_DIR/server_public.key" 2>/dev/null) || return 1
    # PresharedKey — опциональный. awk вместо grep чтобы пустой результат
    # не считался ошибкой (grep -P без match → rc=1, нам это здесь не нужно).
    # Дополнительно срезаем CR (CRLF от Windows-редакторов) и хвостовые
    # пробелы — иначе они улетят в JSON psk_key и сломают handshake так же,
    # как полное отсутствие поля. Без psk_key в inner JSON AmneziaVPN импорт
    # vpn:// теряет PSK и handshake падает (issue #67, fix v5.11.4).
    client_psk=$(awk '/^[[:space:]]*PresharedKey[[:space:]]*=/{sub(/^[[:space:]]*PresharedKey[[:space:]]*=[[:space:]]*/, ""); sub(/\r$/, ""); sub(/[ \t]+$/, ""); print; exit}' "$conf_file" 2>/dev/null)
    local raw_endpoint
    raw_endpoint=$(grep -oP 'Endpoint\s*=\s*\K\S+' "$conf_file") || return 1
    if [[ "$raw_endpoint" == \[* ]]; then
        # IPv6: [addr]:port
        endpoint="${raw_endpoint%%]:*}"
        endpoint="${endpoint#\[}"
    else
        # IPv4/hostname: addr:port
        endpoint="${raw_endpoint%:*}"
    fi
    # tr -d ' \r' - стирает пробелы И CR (на CRLF-конфигах '.+' жадно
    # затягивает \r в значение, что ломает JSON.allowed_ips).
    #
    # v5.27.1: НЕ трогать. Значение уходит в JSON-массив allowed_ips через
    # split(/,/), поэтому пробелы тут вредны - они уехали бы внутрь элементов
    # массива. Пробелы в клиентском .conf этот путь не портит: встроенный
    # конфиг вкладывается из файла как есть.
    allowed_ips=$(grep -oP 'AllowedIPs\s*=\s*\K.+' "$conf_file" | paste -sd, - | tr -d ' \r')
    # Проверяем ПУСТОТУ, а не код возврата: `||` тут не срабатывал даже на
    # строке "AllowedIPs = " без значения, потому что grep находил пробел и
    # выходил с нулём, а конвейер с paste делает статус тем более бесполезным.
    [[ -n "$allowed_ips" ]] || { log_warn "AllowedIPs не прочитан из '$conf_file' - в ссылку уйдёт полный туннель."; allowed_ips="0.0.0.0/0"; }

    # MTU/PersistentKeepalive/DNS из .conf - могли быть изменены через manage modify.
    # Клиент Amnezia при импорте vpn:// использует структурные поля inner JSON
    # (awgConfigurator берёт mtu именно из структурного поля, не из embedded config),
    # поэтому хардкод рассинхронизировал бы их с .conf - тот же класс, что issue #67
    # (structured-поле psk_key было авторитетным).
    local mtu keepalive dns_line dns1 dns2
    mtu=$(grep -oP '^MTU\s*=\s*\K[0-9]+' "$conf_file" | head -n1); mtu="${mtu:-1280}"
    keepalive=$(grep -oP '^PersistentKeepalive\s*=\s*\K[0-9]+' "$conf_file" | head -n1); keepalive="${keepalive:-33}"
    dns_line=$(grep -oP '^DNS\s*=\s*\K.+' "$conf_file" | paste -sd, - | tr -d ' \r')
    dns1="${dns_line%%,*}"; dns1="${dns1:-1.1.1.1}"
    if [[ "$dns_line" == *,* ]]; then dns2="${dns_line#*,}"; dns2="${dns2%%,*}"; else dns2="$dns1"; fi

    local protocol_version="${AWG_PROTOCOL_VERSION:-2.0}" awg31_content_padding=""
    local awg31_header_key="" awg31_max_handshake="" awg31_keepalive_timeout=""
    local awg31_reject_after="" awg31_rekey_after="" awg31_rekey_timeout=""
    local awg31_random_trailers="" awg31_disable_cookies=""
    if [[ "$protocol_version" == "3.0" || "$protocol_version" == "3.1" ]]; then
        python3 "$AWG_PROFILE_SCRIPT_PATH" validate --version "$protocol_version" --input "$AWG_DIR/awg31-profile.json" >/dev/null || return 1
        awg31_content_padding=$(grep -oP '^ContentPaddingAddition\s*=\s*\K\S+' "$conf_file" | head -n1)
        awg31_header_key=$(grep -oP '^HeaderProtectionKey\s*=\s*\K\S+' "$conf_file" | head -n1)
        awg31_max_handshake=$(grep -oP '^MaxHandshakeAttempts\s*=\s*\K\S+' "$conf_file" | head -n1)
        awg31_keepalive_timeout=$(grep -oP '^KeepaliveTimeout\s*=\s*\K\S+' "$conf_file" | head -n1)
        awg31_reject_after=$(grep -oP '^RejectAfterTime\s*=\s*\K\S+' "$conf_file" | head -n1)
        awg31_rekey_after=$(grep -oP '^RekeyAfterTime\s*=\s*\K\S+' "$conf_file" | head -n1)
        awg31_rekey_timeout=$(grep -oP '^RekeyTimeout\s*=\s*\K\S+' "$conf_file" | head -n1)
        awg31_random_trailers=$(grep -oP '^RandomTrailers\s*=\s*\K\S+' "$conf_file" | head -n1)
        awg31_disable_cookies=$(grep -oP '^DisableCookies\s*=\s*\K\S+' "$conf_file" | head -n1)
        [[ -n "$awg31_content_padding" && -n "$awg31_header_key" ]] || return 1
    fi

    local vpn_uri perl_err
    perl_err=$(awg_mktemp "$AWG_DIR") || { log_warn "Ошибка mktemp - vpn:// URI не создан для '$name'."; return 1; }
    # Секреты (privkey клиента, PSK) передаются в perl через env, НЕ через argv:
    # командная строка процесса видна всем пользователям в /proc/<pid>/cmdline
    # на время работы perl. server_pubkey не секрет, но идёт той же группой.
    # shellcheck disable=SC2016
    vpn_uri=$(AWG_URI_CPK="$client_privkey" AWG_URI_PSK="$client_psk" AWG_URI_SPK="$server_pubkey" \
      perl -MCompress::Zlib -MMIME::Base64 -e '
        my ($conf_path, $h1,$h2,$h3,$h4, $jc,$jmin,$jmax,
            $s1,$s2,$s3,$s4, $i1,$i2,$i3,$i4,$i5, $port, $ep, $cip, $cipv6, $aips,
            $mtu, $keepalive, $dns1, $dns2, $srvname, $protocol_version,
            $cpadding, $hpk, $max_handshake, $keepalive_timeout, $reject_after,
            $rekey_after, $rekey_timeout, $random_trailers, $disable_cookies) = @ARGV;
        my $cpk = $ENV{AWG_URI_CPK} // "";
        my $psk = $ENV{AWG_URI_PSK} // "";
        my $spk = $ENV{AWG_URI_SPK} // "";

        open my $fh, "<", $conf_path or die;
        local $/; my $raw = <$fh>; close $fh;
        chomp $raw;

        sub je {
            my $s = shift;
            $s =~ s/\\/\\\\/g; $s =~ s/"/\\"/g;
            $s =~ s/\n/\\n/g;  $s =~ s/\r/\\r/g;
            $s =~ s/\t/\\t/g;  return $s;
        }

        my $inner = "{";
        $inner .= qq("H1":"$h1","H2":"$h2","H3":"$h3","H4":"$h4",);
        $inner .= qq("Jc":"$jc","Jmin":"$jmin","Jmax":"$jmax",);
        $inner .= qq("S1":"$s1","S2":"$s2",);
        if ($protocol_version ne "1.5") {
            $inner .= qq("S3":"$s3","S4":"$s4",);
        }
        if ($protocol_version eq "3.0" || $protocol_version eq "3.1") {
            $inner .= qq("ContentPaddingAddition":"$cpadding","HeaderProtectionKey":"$hpk",);
            $inner .= qq("MaxHandshakeAttempts":"$max_handshake","KeepaliveTimeout":"$keepalive_timeout",);
            $inner .= qq("RejectAfterTime":"$reject_after","RekeyAfterTime":"$rekey_after",);
            $inner .= qq("RekeyTimeout":"$rekey_timeout","RandomTrailers":"$random_trailers",);
            $inner .= qq("DisableCookies":"$disable_cookies",);
        }
        if ($protocol_version ne "1.5" && ($i1 ne "" || $i2 ne "" || $i3 ne "" || $i4 ne "" || $i5 ne "")) {
            my $ei1 = je($i1); my $ei2 = je($i2); my $ei3 = je($i3);
            my $ei4 = je($i4); my $ei5 = je($i5);
            $inner .= qq("I1":"$ei1","I2":"$ei2","I3":"$ei3","I4":"$ei4","I5":"$ei5",);
        }
        my $eraw = je($raw);
        my @ips = split(/,/, $aips);
        my $ips_json = join(",", map { qq("$_") } @ips);
        $inner .= qq("allowed_ips":[$ips_json],);
        $inner .= qq("client_ip":"$cip",);
        $cipv6 //= "";
        $inner .= qq("client_ipv6":"$cipv6",);
        $inner .= qq("client_priv_key":"$cpk",);
        if (defined $psk && $psk ne "") {
            my $epsk = je($psk);
            $inner .= qq("psk_key":"$epsk",);
        }
        $inner .= qq("config":"$eraw",);
        $inner .= qq("hostName":"$ep","mtu":"$mtu",);
        $inner .= qq("persistent_keep_alive":"$keepalive","port":$port,);
        $inner .= qq("server_pub_key":"$spk"});

        my $einner = je($inner);
        my $outer = "{";
        $outer .= qq("containers":[{"awg":{"isThirdPartyConfig":true,);
        $outer .= qq("last_config":"$einner",);
        $outer .= qq("port":"$port","protocol_version":"$protocol_version",);
        $outer .= qq("transport_proto":"udp"\},"container":"amnezia-awg"\}],);
        $outer .= qq("defaultContainer":"amnezia-awg",);
        my $esrv = je($srvname);
        $outer .= qq("name":"$esrv","defaultName":"$esrv",);
        $outer .= qq("description":"$esrv",);
        my $ed1 = je($dns1); my $ed2 = je($dns2);
        $outer .= qq("dns1":"$ed1","dns2":"$ed2",);
        $outer .= qq("hostName":"$ep"});

        my $compressed = compress($outer);
        my $payload = pack("N", length($outer)) . $compressed;
        my $b64 = encode_base64($payload, "");
        $b64 =~ tr|+/|-_|;
        $b64 =~ s/=+$//;
        print "vpn://" . $b64;
    ' "$conf_file" \
        "$AWG_H1" "$AWG_H2" "$AWG_H3" "$AWG_H4" \
        "$AWG_Jc" "$AWG_Jmin" "$AWG_Jmax" \
        "$AWG_S1" "$AWG_S2" "$AWG_S3" "$AWG_S4" \
        "$AWG_I1" "${AWG_I2:-}" "${AWG_I3:-}" "${AWG_I4:-}" "${AWG_I5:-}" "$AWG_PORT" "$endpoint" \
        "$client_ip" "$client_ipv6" "$allowed_ips" \
        "$mtu" "$keepalive" "$dns1" "$dns2" "${AWG_SERVER_NAME:-AWG Server}" "$protocol_version" \
        "$awg31_content_padding" "$awg31_header_key" "$awg31_max_handshake" "$awg31_keepalive_timeout" \
        "$awg31_reject_after" "$awg31_rekey_after" "$awg31_rekey_timeout" "$awg31_random_trailers" "$awg31_disable_cookies" 2>"$perl_err"
    )

    if [[ -z "$vpn_uri" ]]; then
        log_warn "Ошибка генерации vpn:// URI для '$name'."
        [[ -s "$perl_err" ]] && log_warn "Perl: $(cat "$perl_err")"
        rm -f "$perl_err"
        return 1
    fi
    rm -f "$perl_err"

    # Пишем через tmp + atomic mv (как .conf/.png), чтобы обрыв записи не оставил
    # пустой/обрезанный .vpnuri поверх рабочего.
    local _uri_tmp
    _uri_tmp=$(awg_mktemp "$AWG_DIR") || { log_error "Ошибка mktemp для vpn:// URI '$name'"; return 1; }
    printf '%s\n' "$vpn_uri" > "$_uri_tmp" || { rm -f "$_uri_tmp"; log_error "Ошибка записи vpn:// URI для '$name'"; return 1; }
    chmod 600 "$_uri_tmp"
    if ! mv -f "$_uri_tmp" "$uri_file"; then
        rm -f "$_uri_tmp"
        log_error "Ошибка сохранения vpn:// URI для '$name'"
        return 1
    fi
    log_debug "vpn:// URI для '$name' создан: $uri_file"
    return 0
}

# Генерация QR-кода из vpn:// URI (для импорта в Amnezia VPN app Android/iOS/Desktop)
# generate_qr_vpnuri <name>
#
# Пишет через tmp в той же директории + atomic mv, чтобы при сбое qrencode
# или chmod пользователь никогда не увидел обрезанный `.vpnuri.png`:
# старая версия файла остаётся на месте, новая появляется только целиком.
generate_qr_vpnuri() {
    local name="$1"
    local uri_file="$AWG_DIR/${name}.vpnuri"
    local png_file="$AWG_DIR/${name}.vpnuri.png"
    local tmp_png

    if [[ ! -f "$uri_file" ]]; then
        log_error "vpn:// URI для '$name' не найден: $uri_file"
        return 1
    fi

    if ! command -v qrencode &>/dev/null; then
        log_warn "qrencode не установлен, QR vpn:// не создан для '$name'."
        return 1
    fi

    tmp_png=$(awg_mktemp "$AWG_DIR") || { log_error "Ошибка mktemp для QR vpn:// '$name'"; return 1; }
    if ! qrencode -t png -l L -s 6 -m 4 -o "$tmp_png" < "$uri_file"; then
        log_error "Ошибка генерации QR vpn:// для '$name'"
        rm -f "$tmp_png"
        return 1
    fi

    if ! chmod 600 "$tmp_png"; then
        log_error "Не удалось выставить права 600 на $tmp_png"
        rm -f "$tmp_png"
        return 1
    fi

    if ! mv -f "$tmp_png" "$png_file"; then
        log_error "Ошибка сохранения QR vpn:// для '$name'"
        rm -f "$tmp_png"
        return 1
    fi
    log_debug "QR vpn:// для '$name' создан: $png_file"
    return 0
}

# Удаляет частично созданные артефакты клиента (ключи + .conf). Используется
# в early-error путях generate_client - C10: не оставлять orphan-ключи при сбое
# до коммита пира в серверный конфиг.
_rollback_client_artifacts() {
    rm -f "$KEYS_DIR/$1.private" "$KEYS_DIR/$1.public" "$AWG_DIR/$1.conf"
}

# Полный набор клиентских артефактов (conf/png/vpnuri/vpnuri.png + ключи).
# Единый список для `manage remove` и автоудаления истёкших, чтобы пути не
# расходились (раньше expiry-cleanup забывал .vpnuri.png). НЕ трогает expiry-метку
# и cron - это делает вызывающий (remove_client_expiry / rm "$efile").
_remove_client_files() {
    local name="$1"
    rm -f "$AWG_DIR/${name}.conf" "$AWG_DIR/${name}.png" \
        "$AWG_DIR/${name}.vpnuri" "$AWG_DIR/${name}.vpnuri.png" \
        "$KEYS_DIR/${name}.private" "$KEYS_DIR/${name}.public"
}

# Полный цикл создания клиента:
# keypair → next IP → client config → add peer → QR
# generate_client <name> [endpoint]
#
# Env var contract:
#   CLIENT_PSK — необязательный. Если установлен в "auto", генерирует
#     свежий PSK через `awg genpsk` и прописывает его и в серверный
#     [Peer], и в клиентский [Peer]. Если установлен в конкретное
#     значение (32-байт base64) — использует его без генерации. Если
#     пуст/не установлен — PSK не добавляется (default behaviour).
generate_client() {
    local name="$1"
    local endpoint="${2:-}"

    if [[ -z "$name" ]]; then
        log_error "generate_client: не указано имя"
        return 1
    fi
    # Контракт библиотеки (defense-in-depth): имя с метасимволами/переводами
    # строк дало бы инъекцию в пути и heredoc серверного конфига. Тот же
    # regex, что validate_client_name в manage и set_client_expiry здесь.
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "generate_client: невалидное имя клиента '$name'"
        return 1
    fi

    # Загружаем параметры
    load_awg_params || return 1

    # Опциональный PresharedKey: "auto" → `awg genpsk`, иначе используем
    # переданное значение как есть. Пустое/unset → без PSK.
    if [[ "${CLIENT_PSK:-}" == "auto" ]]; then
        # --psk запрошен явно: при сбое awg genpsk НЕ деградируем молча в клиента
        # без PSK (это ослабило бы запрошенную безопасность). Fail-closed; здесь
        # ещё нет созданных артефактов (ключи/конфиг создаются ниже), откат не нужен.
        CLIENT_PSK=$(awg genpsk) || {
            log_error "awg genpsk не сработал - клиент с PresharedKey (--psk) НЕ создан. Повторите."
            return 1
        }
    fi

    # Межпроцессная блокировка: атомарность IP-аллокации + добавления пира
    local lockfile="${AWG_DIR}/.awg_config.lock"
    local lock_fd
    exec {lock_fd}>"$lockfile"
    if ! flock -x -w 30 "$lock_fd"; then
        log_error "Не удалось получить блокировку конфига"
        exec {lock_fd}>&-
        return 1
    fi

    # C6: клиент не должен уже существовать. Проверяю ПОД локом, ДО генерации
    # ключей - иначе `add <существующее_имя>` молча перезатёр бы ключи живого
    # клиента (generate_keypair перезаписывает безусловно), а параллельный add
    # того же имени гонялся бы за перезапись.
    if [[ -e "$KEYS_DIR/${name}.private" || -e "$KEYS_DIR/${name}.public" || -e "$AWG_DIR/${name}.conf" ]]; then
        log_error "Клиент '$name' уже существует. Используйте 'remove' или другое имя."
        exec {lock_fd}>&-
        return 1
    fi

    # Генерация ключей. С этого момента любой ранний сбой обязан удалить уже
    # созданные ключи/conf (C10) через _rollback_client_artifacts.
    generate_keypair "$name" || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }

    # Следующий свободный IP
    local client_ip
    client_ip=$(get_next_client_ip) || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }

    # IPv6-адрес клиента (при ALLOW_IPV6_TUNNEL=1)
    local client_ipv6=""
    if [[ "${ALLOW_IPV6_TUNNEL:-0}" == "1" ]]; then
        client_ipv6=$(get_next_client_ipv6 "$client_ip") || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }
        log_debug "Выделен IPv6-адрес ${client_ipv6} для клиента ${name}"
    fi

    local client_ipv6="" p2p_ports=""
    if awg_ipv6_enabled; then
        client_ipv6=$(get_next_client_ipv6) || {
            log_error "Не удалось выделить IPv6 адрес для '$name'"
            exec {lock_fd}>&-
            return 1
        }
    fi
    if awg_p2p_enabled; then
        p2p_ports=$(allocate_p2p_ports_for_ipv4 "$client_ip" "${AWG_P2P_PORTS_PER_CLIENT:-3}") || {
            log_error "Не удалось выделить P2P порты для '$name'"
            exec {lock_fd}>&-
            return 1
        }
    fi

    # Читаем ключи
    local client_privkey client_pubkey server_pubkey
    client_privkey=$(cat "$KEYS_DIR/${name}.private") || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }
    client_pubkey=$(cat "$KEYS_DIR/${name}.public") || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }

    # Пытаемся восстановить server_public.key из awg0.conf если кеша нет
    # (поддержка ручных установок без installer-шага 6).
    _ensure_server_public_key || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }
    server_pubkey=$(cat "$AWG_DIR/server_public.key") || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }

    # Endpoint: из аргумента → AWG_ENDPOINT (awgsetup_cfg.init) → curl до
    # внешних сервисов → локальный IP с сетевого интерфейса.
    # Последний fallback для LXC / сред без egress: может быть NAT-адресом,
    # поэтому предупреждаем пользователя в лог.
    if [[ -z "$endpoint" ]]; then
        endpoint="${AWG_ENDPOINT:-}"
    fi
    if [[ -z "$endpoint" ]]; then
        endpoint=$(get_server_public_ip)
    fi
    if [[ -z "$endpoint" ]]; then
        endpoint=$(_try_local_ip) && log_warn "Используется локальный IP сервера как Endpoint ('$endpoint') — curl до внешних сервисов не прошёл. Если сервер за NAT, поправьте Endpoint в клиентских .conf вручную."
    fi
    if [[ -z "$endpoint" ]]; then
        log_error "Не удалось определить внешний IP сервера. Задайте AWG_ENDPOINT в awgsetup_cfg.init (или переустановите с --endpoint=IP)."
        _rollback_client_artifacts "$name"
        exec {lock_fd}>&-
        return 1
    fi

    # Порт сервера приходит из живого awg0.conf (ListenPort), иначе из
    # awgsetup_cfg.init - оба правятся руками. render ставит его в
    # 'Endpoint = IP:PORT' клиентского .conf: битый порт уносится на устройство
    # и отлаживается вслепую. Отказываем явно, как generate_vpn_uri для vpn://
    # URI. Артефакты откатит _rollback ниже.
    local _cport
    _cport=$(_sanitize_port "${AWG_PORT:-}")
    if [[ "$_cport" == "0" ]]; then
        log_error "AWG_PORT некорректен ('${AWG_PORT:-}') - клиентский конфиг для '$name' не создан. Проверьте ListenPort в $SERVER_CONF_FILE (или AWG_PORT в $CONFIG_FILE)."
        _rollback_client_artifacts "$name"
        exec {lock_fd}>&-
        return 1
    fi

    # Конфиг клиента
    render_client_config "$name" "$client_ip" "$client_privkey" "$server_pubkey" "$endpoint" "$_cport" "$client_ipv6" || {
        log_error "Откат: удаление ключей '$name'"
        rm -f "$KEYS_DIR/${name}.private" "$KEYS_DIR/${name}.public"
        exec {lock_fd}>&-
        return 1
    }

    # Добавляем пир в серверный конфиг
    if ! add_peer_to_server "$name" "$client_pubkey" "$client_ip" "$client_ipv6" "$p2p_ports"; then
        log_error "Откат: удаление файлов '$name'"
        rm -f "$AWG_DIR/${name}.conf" "$KEYS_DIR/${name}.private" "$KEYS_DIR/${name}.public"
        exec {lock_fd}>&-
        return 1
    fi

    # Освобождаем блокировку — пир записан, дальше некритичные операции
    exec {lock_fd}>&-

    # QR-код (необязательный, ошибка не фатальна)
    if ! generate_qr "$name"; then
        log_warn "QR-код не создан. Конфиг: $AWG_DIR/${name}.conf"
    fi

    # vpn:// URI и QR для Amnezia VPN app (необязательные).
    # QR vpn:// пробуем только если URI создан успешно — иначе читать нечего.
    if ! generate_vpn_uri "$name"; then
        log_warn "vpn:// URI не создан для '$name'."
    elif ! generate_qr_vpnuri "$name"; then
        log_warn "QR vpn:// не создан для '$name'."
    fi

    local msg="Клиент '$name' создан (IPv4: $client_ip"
    [[ -n "$client_ipv6" ]] && msg="${msg}, IPv6: $client_ipv6"
    [[ -n "$p2p_ports" ]] && msg="${msg}, P2P: $p2p_ports"
    msg="${msg})."
    log "$msg"
    return 0
}

# Перегенерация конфига и QR для существующего клиента
# regenerate_client <name> [endpoint]
#
# v5.11.0 A5.3: защищается блокировкой .awg_config.lock (сериализация
# с modify_client / remove и параллельными regen на том же имени) и
# проверяет возврат каждого sed -i при восстановлении пользовательских
# настроек — прежде молча игнорировались ошибки sed.
#
# Lock scope: держится только пока мутируется $AWG_DIR/${name}.conf.
# generate_qr / generate_vpn_uri / generate_qr_vpnuri вызываются ВНЕ lock
# как best-effort derived artifacts — если между sed-ом и QR-генерацией
# concurrent modify успеет изменить conf, QR может устареть на один такт.
# Также concurrent `manage remove <name>` может удалить клиента после
# release lock, и regen «воскресит» `.conf` / `.png` / `.vpnuri` /
# `.vpnuri.png` для уже удалённого peer-а (stale artefacts в $AWG_DIR).
# Это приемлемо: пользователь получит актуальное состояние на следующей
# операции (повторный `remove` или `regen`), и peer уже удалён из server-
# конфига — трафик через него не идёт. Включать QR/URI в lock дороже
# (lock на несколько секунд — блокирует другие клиенты) без выигрыша
# по целостности server-state.
refresh_client_config() {
    local name="$1"
    local endpoint="${2:-}"

    if [[ -z "$name" ]]; then
        log_error "refresh_client_config: не указано имя"
        return 1
    fi
    # Контракт библиотеки (defense-in-depth): имя интерполируется в пути и
    # конфиг, поэтому валидируем здесь же, не полагаясь на вызывающего
    # (manage делает свой validate_client_name, но cron/чужой скрипт - нет).
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "regenerate_client: невалидное имя клиента '$name'"
        return 1
    fi

    # Межпроцессная блокировка: защита от race с modify_client/remove и
    # параллельных regen на одном имени клиента.
    local lockfile="${AWG_DIR}/.awg_config.lock"
    local lock_fd
    exec {lock_fd}>"$lockfile"
    if ! flock -x -w 10 "$lock_fd"; then
        log_error "Не удалось получить блокировку конфига (другая операция выполняется)"
        exec {lock_fd}>&-
        return 1
    fi

    load_awg_params || { exec {lock_fd}>&-; return 1; }
    if [[ -n "${AWG_I1_OVERRIDE:-}" ]]; then
        validate_i1_override "$AWG_I1_OVERRIDE" || {
            log_error "Invalid AWG_I1_OVERRIDE"
            exec {lock_fd}>&-
            return 1
        }
        AWG_I1="$AWG_I1_OVERRIDE"
    fi

    # Проверяем, что клиент существует в серверном конфиге
    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Клиент '$name' не найден в серверном конфиге"
        exec {lock_fd}>&-
        return 1
    fi

    # Читаем приватный ключ клиента
    local client_privkey client_ip server_pubkey client_ipv6
    if [[ -f "$KEYS_DIR/${name}.private" ]]; then
        client_privkey=$(cat "$KEYS_DIR/${name}.private")
    elif [[ -f "$AWG_DIR/${name}.conf" ]]; then
        # Пробуем извлечь из существующего конфига
        client_privkey=$(sed -n 's/^PrivateKey[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
    fi

    if [[ -z "$client_privkey" ]]; then
        log_error "Приватный ключ клиента '$name' не найден"
        exec {lock_fd}>&-
        return 1
    fi

    # IP клиента из серверного конфига
    client_ip=$(get_client_ipv4_from_server "$name" 2>/dev/null || true)
    client_ipv6=$(get_client_ipv6_from_server "$name" 2>/dev/null || true)

    # Only carry IPv6 forward if ALLOW_IPV6_TUNNEL is enabled
    if [[ "${ALLOW_IPV6_TUNNEL:-0}" != "1" ]]; then
        client_ipv6=""
    fi

    if [[ -z "$client_ip" ]]; then
        log_error "IP клиента '$name' не найден в серверном конфиге"
        exec {lock_fd}>&-
        return 1
    fi

    # Auto-gen из awg0.conf если кеша нет (ручная установка)
    _ensure_server_public_key || { exec {lock_fd}>&-; return 1; }
    server_pubkey=$(cat "$AWG_DIR/server_public.key" 2>/dev/null) || {
        log_error "Публичный ключ сервера не найден"
        exec {lock_fd}>&-
        return 1
    }

    # Endpoint chain: arg → AWG_ENDPOINT → curl → local IP (best-effort).
    if [[ -z "$endpoint" ]]; then
        endpoint="${AWG_ENDPOINT:-}"
    fi
    if [[ -z "$endpoint" ]]; then
        endpoint=$(get_server_public_ip)
    fi
    if [[ -z "$endpoint" ]]; then
        endpoint=$(_try_local_ip) && log_warn "Используется локальный IP сервера как Endpoint ('$endpoint') — curl до внешних сервисов не прошёл."
    fi
    if [[ -z "$endpoint" ]]; then
        log_error "Не удалось определить внешний IP сервера."
        exec {lock_fd}>&-
        return 1
    fi

    # Сохраняем пользовательские настройки из текущего .conf (modify)
    local current_dns="1.1.1.1" current_keepalive="25" current_allowed_ips="${ALLOWED_IPS:-0.0.0.0/0}"
    if [[ -f "$AWG_DIR/${name}.conf" ]]; then
        local _v _raw
        # tr -d '[:space:]' стирал здесь пробелы после запятых, и regen писал
        # в .conf слипшийся список (D#38). Нормализуем, а не выкусываем.
        #
        # Строки СКЛЕИВАЮТСЯ, а не берётся первая: wg допускает повтор DNS и
        # AllowedIPs, значения при этом складываются. Прежний `tr` слеплял их в
        # заведомо невалидный CIDR, и awg-quick отказывался поднимать интерфейс
        # ГРОМКО; взять первую строку означало бы отдать пользователю валидный
        # конфиг, из которого часть сетей исчезла молча.
        _raw=$(sed -n 's/^DNS[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf")
        _awg_warn_multiline "$_raw" "DNS" "$name"
        _v=$(awg_normalize_csv "$(printf '%s' "$_raw" | paste -sd, -)")
        [[ -n "$_v" ]] && current_dns="$_v"
        _v=$(sed -n 's/^PersistentKeepalive[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
        [[ -n "$_v" ]] && current_keepalive="$_v"
        _raw=$(sed -n '/^\[Peer\]/,$ s/^AllowedIPs[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf")
        _awg_warn_multiline "$_raw" "AllowedIPs" "$name"
        _v=$(awg_normalize_csv "$(printf '%s' "$_raw" | paste -sd, -)")
        [[ -n "$_v" ]] && current_allowed_ips="$_v"
        # v5.11.1: preserve PresharedKey через regen — если у клиента
        # был PSK (создан с manage add --psk), regen без этого сохранения
        # выбросил бы его и сломал handshake (server peer всё ещё с PSK,
        # client conf уже без). CLIENT_PSK передаётся в render_client_config.
        local _psk
        _psk=$(sed -n '/^\[Peer\]/,$ s/^PresharedKey[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
        if [[ -n "$_psk" ]]; then
            export CLIENT_PSK="$_psk"
        else
            unset CLIENT_PSK
        fi
    else
        # Клиентский .conf утерян (regen как восстановление): PresharedKey
        # восстанавливаем из server [Peer]-блока, иначе пересозданный конфиг
        # вышел бы без PSK при живом PSK на сервере - handshake молча ломается.
        # Порядок полей в блоке контролируем мы (add_peer_to_server пишет
        # #_Name первым), поэтому found-then-PSK достаточно.
        local _psk
        _psk=$(awk -v target="$name" '
            /^\[Peer\]/ { in_peer=1; found=0; next }
            in_peer && $0 == "#_Name = " target { found=1; next }
            in_peer && found && /^PresharedKey[ \t]*=/ {
                sub(/^PresharedKey[ \t]*=[ \t]*/, ""); sub(/\r$/, ""); print; exit
            }
            /^\[/ && !/^\[Peer\]/ { in_peer=0; found=0 }
        ' "$SERVER_CONF_FILE" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$_psk" ]]; then
            export CLIENT_PSK="$_psk"
        else
            unset CLIENT_PSK
        fi
    fi
    if awg_ipv6_enabled && [[ -n "$client_ipv6" && "$current_allowed_ips" != *"::/0"* ]]; then
        current_allowed_ips="${current_allowed_ips},::/0"
    fi

    # Перегенерация конфига
    local _cport
    _cport=$(_sanitize_port "${AWG_PORT:-}")
    if [[ "$_cport" == "0" ]]; then
        log_error "AWG_PORT некорректен ('${AWG_PORT:-}') — конфиг '$name' не обновлён."
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi
    render_client_config "$name" "$client_ip" "$client_privkey" "$server_pubkey" "$endpoint" "$_cport" "$client_ipv6" || {
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    }

    # При regen подтягиваем новые дефолты для НЕ-кастомизированных клиентов:
    # полнотуннельный 0.0.0.0/0 получает ::/0 (нужно iOS AmneziaVPN), одиночный
    # DNS 1.1.1.1 становится парой с резервом. Значения, заданные пользователем
    # через modify, не равны старым дефолтам и потому сохраняются как есть.
    [[ "$current_allowed_ips" == "0.0.0.0/0" ]] && current_allowed_ips="0.0.0.0/0, ::/0"
    [[ "$current_dns" == "1.1.1.1" ]] && current_dns="1.1.1.1, 1.0.0.1"

    # Восстанавливаем пользовательские настройки (экранируем & и \ для sed replacement)
    local _dns _ka _aip
    _dns=$(printf '%s' "$current_dns" | sed 's/[&\\/]/\\&/g')
    _ka=$(printf '%s' "$current_keepalive" | sed 's/[&\\/]/\\&/g')
    _aip=$(printf '%s' "$current_allowed_ips" | sed 's/[&\\/]/\\&/g')
    local _client_conf="$AWG_DIR/${name}.conf"
    if ! sed -i "s/^DNS = .*/DNS = ${_dns}/" "$_client_conf"; then
        log_error "Ошибка sed при записи DNS в $_client_conf"
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi
    if ! sed -i "s/^PersistentKeepalive = .*/PersistentKeepalive = ${_ka}/" "$_client_conf"; then
        log_error "Ошибка sed при записи PersistentKeepalive в $_client_conf"
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi
    # Делимитер '/' (а не '|'): класс экранирования выше покрывает & \ / -
    # символ '|' в значении сломал бы sed-выражение с '|'-делимитером.
    # regen --reset-routes (Issue #170): НЕ восстанавливаем старый AllowedIPs
    # клиента - оставляем значение из render_client_config, вычисленное из
    # глобального режима маршрутизации (awgsetup_cfg.init) с корректным
    # IPv6-зеркалированием. Обычный regen сохраняет индивидуальные настройки.
    if [[ "${AWG_REGEN_RESET_ROUTES:-0}" == "1" ]]; then
        log "AllowedIPs клиента '$name' сброшен на глобальный режим маршрутизации (--reset-routes)."
    elif ! sed -i "s/^AllowedIPs = .*/AllowedIPs = ${_aip}/" "$_client_conf"; then
        log_error "Ошибка sed при записи AllowedIPs в $_client_conf"
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi

    # Освобождаем блокировку — конфиг записан, дальше некритичные операции
    exec {lock_fd}>&-

    # QR-код
    generate_qr "$name"

    # vpn:// URI и QR для Amnezia VPN app (best-effort).
    # QR vpn:// пробуем только если URI пересоздан успешно.
    if generate_vpn_uri "$name"; then
        generate_qr_vpnuri "$name" || log_warn "QR vpn:// не обновлён для '$name'."
    else
        log_warn "vpn:// URI не обновлён для '$name'."
    fi

    # Hygiene: PSK не должен протекать в следующие операции в том же shell
    unset CLIENT_PSK

    log "Конфиг клиента '$name' обновлён."
    return 0
}

validate_i1_override() {
    local i1="$1"

    [[ -n "$i1" ]] || return 1
    [[ ${#i1} -le 2000 ]] || return 1

    case "$i1" in
        *[\'\"\;\`\$\|\&\\/]*)
            return 1
            ;;
        *$'\n'*|*$'\r'*|*$'\t'*)
            return 1
            ;;
    esac

    [[ "$i1" =~ ^[[:space:]0-9a-fA-Fx\<\>br]+$ ]] || return 1
    [[ "$i1" == *"<b 0x"* || "$i1" == *"<r "* ]] || return 1
}

awg_rand_range() {
    local min="$1" max="$2" range random_val
    range=$((max - min + 1))
    random_val=$(od -An -tu4 -N4 /dev/urandom 2>/dev/null | tr -d ' ')
    [[ "$random_val" =~ ^[0-9]+$ ]] || random_val=$(( (RANDOM << 15) | RANDOM ))
    echo $(( (random_val % range) + min ))
}

generate_awg_h_ranges_runtime() {
    local attempt=0 max_attempts=20
    while (( attempt < max_attempts )); do
        local raw arr=() _v
        raw=$(od -An -N32 -tu4 /dev/urandom 2>/dev/null | tr -s ' \n' '\n' | sed '/^$/d')
        if [[ -n "$raw" ]]; then
            local count=0
            while IFS= read -r _v; do
                [[ "$_v" =~ ^[0-9]+$ ]] || continue
                arr+=("$(( _v & 2147483647 ))")
                count=$((count + 1))
                (( count == 8 )) && break
            done <<< "$raw"
        fi
        if (( ${#arr[@]} != 8 )); then
            arr=()
            for _v in 1 2 3 4 5 6 7 8; do arr+=("$(awg_rand_range 0 2147483647)"); done
        fi
        mapfile -t arr < <(printf '%s\n' "${arr[@]}" | sort -n)
        if (( ${arr[1]} - ${arr[0]} >= 1000 )) && (( ${arr[3]} - ${arr[2]} >= 1000 )) && \
           (( ${arr[5]} - ${arr[4]} >= 1000 )) && (( ${arr[7]} - ${arr[6]} >= 1000 )); then
            printf '%s-%s\n%s-%s\n%s-%s\n%s-%s\n' \
                "${arr[0]}" "${arr[1]}" "${arr[2]}" "${arr[3]}" \
                "${arr[4]}" "${arr[5]}" "${arr[6]}" "${arr[7]}"
            return 0
        fi
        attempt=$((attempt + 1))
    done
    return 1
}

generate_cps_i1_runtime() {
    echo "<r $(awg_rand_range 32 256)>"
}

generate_awg31_s_values_runtime() {
    local attempt s1 s2 s3
    for attempt in {1..64}; do
        s1=$(awg_rand_range 12 149)
        s2=$(awg_rand_range 12 149)
        s3=$(awg_rand_range 12 63)
        if [[ $((148 + s1)) -ne $((92 + s2)) ]] &&
           [[ $((148 + s1)) -ne $((64 + s3)) ]] &&
           [[ $((148 + s1)) -ne 44 ]] &&
           [[ $((92 + s2)) -ne $((64 + s3)) ]] &&
           [[ $((92 + s2)) -ne 44 ]] &&
           [[ $((64 + s3)) -ne 44 ]]; then
            printf '%s\n%s\n%s\n12\n' "$s1" "$s2" "$s3"
            return 0
        fi
    done
    return 1
}

generate_runtime_awg_profile() {
    local preset="${1:-default}" h_lines s_lines
    case "$preset" in
        mobile)
            AWG_PRESET="mobile"
            AWG_Jc=3
            AWG_Jmin=$(awg_rand_range 30 50)
            AWG_Jmax=$(( AWG_Jmin + $(awg_rand_range 20 80) ))
            if [[ "${AWG_PROTOCOL_VERSION:-2.0}" == "3.0" || "${AWG_PROTOCOL_VERSION:-2.0}" == "3.1" ]]; then
                mapfile -t s_lines < <(generate_awg31_s_values_runtime) || return 1
                [[ ${#s_lines[@]} -eq 4 ]] || return 1
                AWG_S1="${s_lines[0]}"; AWG_S2="${s_lines[1]}"
                AWG_S3="${s_lines[2]}"; AWG_S4="${s_lines[3]}"
            else
                AWG_S1=$(awg_rand_range 15 150)
                AWG_S2=$(awg_rand_range 15 150)
                if [[ $((AWG_S1 + 56)) -eq $AWG_S2 ]]; then
                    AWG_S2=$((AWG_S2 + 1)); (( AWG_S2 <= 150 )) || AWG_S2=15
                fi
                AWG_S3=$(awg_rand_range 0 10)
                AWG_S4=$(awg_rand_range 0 10)
            fi
            ;;
        default|balanced)
            AWG_PRESET="default"
            AWG_Jc=$(awg_rand_range 3 6)
            AWG_Jmin=$(awg_rand_range 40 89)
            AWG_Jmax=$(( AWG_Jmin + $(awg_rand_range 50 150) ))
            if [[ "${AWG_PROTOCOL_VERSION:-2.0}" == "3.0" || "${AWG_PROTOCOL_VERSION:-2.0}" == "3.1" ]]; then
                mapfile -t s_lines < <(generate_awg31_s_values_runtime) || return 1
                [[ ${#s_lines[@]} -eq 4 ]] || return 1
                AWG_S1="${s_lines[0]}"; AWG_S2="${s_lines[1]}"
                AWG_S3="${s_lines[2]}"; AWG_S4="${s_lines[3]}"
            else
                AWG_S1=$(awg_rand_range 15 150)
                AWG_S2=$(awg_rand_range 15 150)
                if [[ $((AWG_S1 + 56)) -eq $AWG_S2 ]]; then
                    AWG_S2=$((AWG_S2 + 1)); (( AWG_S2 <= 150 )) || AWG_S2=15
                fi
                AWG_S3=$(awg_rand_range 8 55)
                AWG_S4=$(awg_rand_range 4 32)
            fi
            ;;
        stealth)
            AWG_PRESET="stealth"
            AWG_Jc=$(awg_rand_range 3 8)
            AWG_Jmin=$(awg_rand_range 64 160)
            AWG_Jmax=$(( AWG_Jmin + $(awg_rand_range 160 420) ))
            if [[ "${AWG_PROTOCOL_VERSION:-2.0}" == "3.0" || "${AWG_PROTOCOL_VERSION:-2.0}" == "3.1" ]]; then
                mapfile -t s_lines < <(generate_awg31_s_values_runtime) || return 1
                [[ ${#s_lines[@]} -eq 4 ]] || return 1
                AWG_S1="${s_lines[0]}"; AWG_S2="${s_lines[1]}"
                AWG_S3="${s_lines[2]}"; AWG_S4="${s_lines[3]}"
            else
                AWG_S1=$(awg_rand_range 20 149); AWG_S2=$(awg_rand_range 20 149)
                AWG_S3=$(awg_rand_range 16 55); AWG_S4=$(awg_rand_range 12 32)
            fi
            ;;
        compatibility)
            AWG_PRESET="compatibility"
            AWG_Jc=$(awg_rand_range 3 5)
            AWG_Jmin=$(awg_rand_range 20 64)
            AWG_Jmax=$(( AWG_Jmin + $(awg_rand_range 20 80) ))
            if [[ "${AWG_PROTOCOL_VERSION:-2.0}" == "3.0" || "${AWG_PROTOCOL_VERSION:-2.0}" == "3.1" ]]; then
                mapfile -t s_lines < <(generate_awg31_s_values_runtime) || return 1
                [[ ${#s_lines[@]} -eq 4 ]] || return 1
                AWG_S1="${s_lines[0]}"; AWG_S2="${s_lines[1]}"
                AWG_S3="${s_lines[2]}"; AWG_S4="${s_lines[3]}"
            else
                AWG_S1=$(awg_rand_range 15 150); AWG_S2=$(awg_rand_range 15 150)
                AWG_S3=$(awg_rand_range 12 55); AWG_S4=$(awg_rand_range 12 32)
            fi
            ;;
        *)
            log_error "Неизвестный preset: $preset"
            return 1
            ;;
    esac
    mapfile -t h_lines < <(generate_awg_h_ranges_runtime) || true
    [[ ${#h_lines[@]} -eq 4 ]] || { log_error "Не удалось сгенерировать H ranges"; return 1; }
    AWG_H1="${h_lines[0]}"; AWG_H2="${h_lines[1]}"; AWG_H3="${h_lines[2]}"; AWG_H4="${h_lines[3]}"
    if [[ "${AWG_PROTOCOL_VERSION:-2.0}" == "1.5" ]]; then
        unset AWG_S3 AWG_S4 AWG_I1
        AWG_H1="${AWG_H1%%-*}"; AWG_H2="${AWG_H2%%-*}"
        AWG_H3="${AWG_H3%%-*}"; AWG_H4="${AWG_H4%%-*}"
    else
        AWG_I1="$(generate_cps_i1_runtime)"
    fi
    export AWG_PRESET AWG_Jc AWG_Jmin AWG_Jmax AWG_S1 AWG_S2 AWG_S3 AWG_S4 AWG_H1 AWG_H2 AWG_H3 AWG_H4 AWG_I1
}

update_awg_profile_in_files() {
    python3 - "$CONFIG_FILE" "$SERVER_CONF_FILE" <<'PY'
import os
import re
import sys
from pathlib import Path

config = Path(sys.argv[1])
server = Path(sys.argv[2])
keys = ["AWG_PRESET", "AWG_Jc", "AWG_Jmin", "AWG_Jmax", "AWG_S1", "AWG_S2", "AWG_S3", "AWG_S4", "AWG_H1", "AWG_H2", "AWG_H3", "AWG_H4", "AWG_I1"]
values = {key: os.environ[key] for key in keys if key in os.environ}

if config.exists():
    lines = config.read_text(encoding="utf-8", errors="ignore").splitlines()
    seen = set()
    out = []
    for line in lines:
        m = re.match(r"^(?:export\s+)?(AWG_(?:PRESET|Jc|Jmin|Jmax|S[1-4]|H[1-4]|I1))=", line)
        if m and m.group(1) in values:
            key = m.group(1)
            val = values[key]
            if re.fullmatch(r"[0-9]+", val):
                out.append(f"export {key}={val}")
            else:
                out.append(f"export {key}='{val}'")
            seen.add(key)
        else:
            out.append(line)
    for key in keys:
        if key not in seen and key in values:
            val = values[key]
            out.append(f"export {key}={val}" if re.fullmatch(r"[0-9]+", val) else f"export {key}='{val}'")
    tmp = config.with_name(config.name + f".tmp.{os.getpid()}")
    tmp.write_text("\n".join(out).rstrip() + "\n", encoding="utf-8")
    tmp.chmod(0o600)
    tmp.replace(config)
    config.chmod(0o600)

text = server.read_text(encoding="utf-8", errors="ignore").splitlines()
field_map = {"Jc": "AWG_Jc", "Jmin": "AWG_Jmin", "Jmax": "AWG_Jmax", "S1": "AWG_S1", "S2": "AWG_S2", "S3": "AWG_S3", "S4": "AWG_S4", "H1": "AWG_H1", "H2": "AWG_H2", "H3": "AWG_H3", "H4": "AWG_H4", "I1": "AWG_I1"}
seen = set()
out = []
in_iface = False
inserted = False
for line in text:
    if line.strip() == "[Interface]":
        in_iface = True
        out.append(line)
        continue
    if in_iface and line.startswith("["):
        for field, env_key in field_map.items():
            if field not in seen and env_key in values:
                out.append(f"{field} = {values[env_key]}")
        inserted = True
        in_iface = False
        out.append(line)
        continue
    if in_iface:
        m = re.match(r"^([A-Za-z0-9]+)\s*=", line.strip())
        if m and m.group(1) in field_map:
            field = m.group(1)
            out.append(f"{field} = {values[field_map[field]]}")
            seen.add(field)
            continue
    out.append(line)
if in_iface and not inserted:
    for field, env_key in field_map.items():
        if field not in seen and env_key in values:
            out.append(f"{field} = {values[env_key]}")
tmp = server.with_name(server.name + f".tmp.{os.getpid()}")
tmp.write_text("\n".join(out).rstrip() + "\n", encoding="utf-8")
tmp.chmod(0o600)
tmp.replace(server)
server.chmod(0o600)
PY
}

read_i1_override_for_client() {
    local name="$1"
    [[ -n "${AWG_I1_OVERRIDES_FILE:-}" && -f "$AWG_I1_OVERRIDES_FILE" ]] || return 1
    python3 - "$AWG_I1_OVERRIDES_FILE" "$name" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
value = data.get(sys.argv[2], "")
if value:
    print(value)
PY
}

server_rotate_profile() {
    local preset="${1:-default}" timestamp backup_dir name override_i1 old_apply
    load_awg_params || return 1
    generate_runtime_awg_profile "$preset" || return 1
    timestamp="$(date '+%Y%m%d-%H%M%S.%3N')"
    backup_dir="${AWG_DIR}/rotate-backups/${timestamp}"
    mkdir -p "$backup_dir" || return 1
    chmod 700 "$AWG_DIR/rotate-backups" "$backup_dir" 2>/dev/null || true
    cp -p "$SERVER_CONF_FILE" "$backup_dir/awg0.conf" || return 1
    cp -p "$CONFIG_FILE" "$backup_dir/awgsetup_cfg.init" 2>/dev/null || true
    cp -p "$AWG_DIR"/*.conf "$backup_dir/" 2>/dev/null || true
    cp -p "$AWG_DIR"/*.png "$AWG_DIR"/*.vpnuri "$AWG_DIR"/*.vpnuri.png "$backup_dir/" 2>/dev/null || true

    update_awg_profile_in_files || return 1
    old_apply="${AWG_SKIP_APPLY:-}"
    export AWG_SKIP_APPLY=1
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        override_i1="$(read_i1_override_for_client "$name" 2>/dev/null || true)"
        [[ -n "$override_i1" ]] || override_i1="$(generate_cps_i1_runtime)"
        export AWG_I1_OVERRIDE="$override_i1"
        if ! refresh_client_config "$name"; then
            unset AWG_I1_OVERRIDE
            [[ -n "$old_apply" ]] && export AWG_SKIP_APPLY="$old_apply" || unset AWG_SKIP_APPLY
            cp -p "$backup_dir/awg0.conf" "$SERVER_CONF_FILE" 2>/dev/null || true
            cp -p "$backup_dir"/*.conf "$AWG_DIR/" 2>/dev/null || true
            apply_config >/dev/null 2>&1 || true
            return 1
        fi
    done < <(grep '^#_Name = ' "$SERVER_CONF_FILE" 2>/dev/null | sed 's/^#_Name = //')
    unset AWG_I1_OVERRIDE
    [[ -n "$old_apply" ]] && export AWG_SKIP_APPLY="$old_apply" || unset AWG_SKIP_APPLY
    generate_firewall_scripts >/dev/null 2>&1 || log_warn "Не удалось обновить firewall hook-скрипты."
    if ! apply_config; then
        log_error "apply_config упал после rotate-profile; выполняется rollback."
        cp -p "$backup_dir/awg0.conf" "$SERVER_CONF_FILE" 2>/dev/null || true
        cp -p "$backup_dir"/*.conf "$AWG_DIR/" 2>/dev/null || true
        apply_config >/dev/null 2>&1 || true
        return 1
    fi
    {
        printf '%s preset=%s Jc=%s Jmin=%s Jmax=%s S1=%s S2=%s S3=%s S4=%s\n' \
            "$(date '+%F %T')" "$preset" "$AWG_Jc" "$AWG_Jmin" "$AWG_Jmax" "$AWG_S1" "$AWG_S2" "$AWG_S3" "$AWG_S4"
    } >> "$AWG_DIR/ROTATION_HISTORY.log"
    chmod 600 "$AWG_DIR/ROTATION_HISTORY.log" 2>/dev/null || true
    log "Server AWG profile rotated (preset: $preset). Client configs regenerated."
}

replace_peer_credentials() {
    local name="$1" new_pubkey="$2" new_psk="${3:-}"
    local tmpfile
    [[ -n "$name" && -n "$new_pubkey" ]] || return 1
    tmpfile=$(awg_mktemp) || return 1
    awk -v target="$name" -v pub="$new_pubkey" -v psk="$new_psk" '
        function flush_block(    i,line,prefix,has_pub,has_psk) {
            if (!in_block) return
            if (target_block) {
                has_pub=0; has_psk=0
                for (i=1; i<=n; i++) {
                    line=block[i]
                    if (line ~ /^#?[[:space:]]*PublicKey[[:space:]]*=/) {
                        prefix=(line ~ /^#/) ? "# " : ""
                        print prefix "PublicKey = " pub
                        has_pub=1
                        continue
                    }
                    if (line ~ /^#?[[:space:]]*PresharedKey[[:space:]]*=/) {
                        if (psk != "") {
                            prefix=(line ~ /^#/) ? "# " : ""
                            print prefix "PresharedKey = " psk
                            has_psk=1
                        }
                        continue
                    }
                    print line
                    if (psk != "" && has_pub && !has_psk && line !~ /^#?[[:space:]]*PresharedKey[[:space:]]*=/) {
                        print "PresharedKey = " psk
                        has_psk=1
                    }
                }
            } else {
                for (i=1; i<=n; i++) print block[i]
            }
            in_block=0; target_block=0; n=0
        }
        /^#? ?\[Peer\]$/ { flush_block(); in_block=1; target_block=0; n=0; block[++n]=$0; next }
        /^\[/ && in_block { flush_block(); print; next }
        in_block {
            block[++n]=$0
            if ($0 == "#_Name = " target) target_block=1
            next
        }
        { print }
        END { flush_block() }
    ' "$SERVER_CONF_FILE" > "$tmpfile" || {
        rm -f "$tmpfile"
        return 1
    }
    mv "$tmpfile" "$SERVER_CONF_FILE" || {
        rm -f "$tmpfile"
        return 1
    }
    chmod 600 "$SERVER_CONF_FILE"
}

restore_regenerate_backup() {
    local server_bak="$1" client_bak="$2" priv_bak="$3" pub_bak="$4" name="$5"
    [[ -f "$server_bak" ]] && cp -p "$server_bak" "$SERVER_CONF_FILE" || true
    if [[ -f "$client_bak" ]]; then
        cp -p "$client_bak" "$AWG_DIR/${name}.conf" || true
    fi
    if [[ -f "$priv_bak" ]]; then
        cp -p "$priv_bak" "$KEYS_DIR/${name}.private" || true
    fi
    if [[ -f "$pub_bak" ]]; then
        cp -p "$pub_bak" "$KEYS_DIR/${name}.public" || true
    fi
    chmod 600 "$SERVER_CONF_FILE" "$AWG_DIR/${name}.conf" "$KEYS_DIR/${name}.private" "$KEYS_DIR/${name}.public" 2>/dev/null || true
}

regenerate_client() {
    local name="$1"
    local endpoint="${2:-}"

    if [[ -z "$name" ]]; then
        log_error "regenerate_client: не указано имя"
        return 1
    fi
    if type validate_client_name >/dev/null 2>&1; then
        validate_client_name "$name" || return 1
    elif ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Имя содержит недоп. символы."
        return 1
    fi

    local lockfile="${AWG_DIR}/.awg_config.lock"
    local lock_fd
    exec {lock_fd}>"$lockfile"
    if ! flock -x -w 30 "$lock_fd"; then
        log_error "Не удалось получить блокировку конфига (другая операция выполняется)"
        exec {lock_fd}>&-
        return 1
    fi

    load_awg_params || { exec {lock_fd}>&-; return 1; }

    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Клиент '$name' не найден в серверном конфиге"
        exec {lock_fd}>&-
        return 1
    fi
    if [[ ! -f "$AWG_DIR/${name}.conf" ]]; then
        log_error "Конфиг клиента '$name' не найден"
        exec {lock_fd}>&-
        return 1
    fi

    local client_ip client_ipv6 server_pubkey
    client_ip=$(get_client_ipv4_from_server "$name" 2>/dev/null || true)
    client_ipv6=$(get_client_ipv6_from_server "$name" 2>/dev/null || true)
    if [[ -z "$client_ip" ]]; then
        log_error "IP клиента '$name' не найден в серверном конфиге"
        exec {lock_fd}>&-
        return 1
    fi

    _ensure_server_public_key || { exec {lock_fd}>&-; return 1; }
    server_pubkey=$(cat "$AWG_DIR/server_public.key" 2>/dev/null) || {
        log_error "Публичный ключ сервера не найден"
        exec {lock_fd}>&-
        return 1
    }

    if [[ -z "$endpoint" ]]; then endpoint="${AWG_ENDPOINT:-}"; fi
    if [[ -z "$endpoint" ]]; then endpoint=$(get_server_public_ip); fi
    if [[ -z "$endpoint" ]]; then
        endpoint=$(_try_local_ip) && log_warn "Используется локальный IP сервера как Endpoint ('$endpoint') — curl до внешних сервисов не прошёл."
    fi
    if [[ -z "$endpoint" ]]; then
        log_error "Не удалось определить внешний IP сервера."
        exec {lock_fd}>&-
        return 1
    fi

    local current_dns="1.1.1.1" current_keepalive="25" current_allowed_ips="${ALLOWED_IPS:-0.0.0.0/0}"
    local old_psk="" new_psk="" new_i1="${AWG_I1:-}"
    local _v _raw
    _raw=$(sed -n 's/^DNS[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf")
    _awg_warn_multiline "$_raw" "DNS" "$name"
    _v=$(awg_normalize_csv "$(printf '%s' "$_raw" | paste -sd, -)")
    [[ -n "$_v" ]] && current_dns="$_v"
    _v=$(sed -n 's/^PersistentKeepalive[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
    [[ -n "$_v" ]] && current_keepalive="$_v"
    _raw=$(sed -n '/^\[Peer\]/,$ s/^AllowedIPs[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf")
    _awg_warn_multiline "$_raw" "AllowedIPs" "$name"
    _v=$(awg_normalize_csv "$(printf '%s' "$_raw" | paste -sd, -)")
    [[ -n "$_v" ]] && current_allowed_ips="$_v"
    old_psk=$(sed -n '/^\[Peer\]/,$ s/^PresharedKey[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
    if [[ -z "$old_psk" ]]; then
        old_psk=$(awk -v target="$name" '
            /^#? ?\[Peer\]$/ { in_peer=1; found=0; next }
            in_peer && $0 == "#_Name = " target { found=1; next }
            in_peer && found && /^#?[[:space:]]*PresharedKey[[:space:]]*=/ {
                sub(/^#?[[:space:]]*PresharedKey[[:space:]]*=[[:space:]]*/, ""); print; exit
            }
            in_peer && /^\[/ { in_peer=0; found=0 }
        ' "$SERVER_CONF_FILE" | tr -d '[:space:]')
    fi
    if [[ -n "$old_psk" ]]; then
        new_psk=$(awg genpsk) || {
            log_error "Не удалось сгенерировать новый PresharedKey для '$name'"
            exec {lock_fd}>&-
            return 1
        }
        export CLIENT_PSK="$new_psk"
    else
        unset CLIENT_PSK
    fi
    if awg_ipv6_enabled && [[ -n "$client_ipv6" && "$current_allowed_ips" != *"::/0"* ]]; then
        current_allowed_ips="${current_allowed_ips},::/0"
    fi
    if [[ -n "${AWG_I1_OVERRIDE:-}" ]]; then
        validate_i1_override "$AWG_I1_OVERRIDE" || {
            log_error "Invalid AWG_I1_OVERRIDE"
            exec {lock_fd}>&-
            unset CLIENT_PSK
            return 1
        }
        new_i1="$AWG_I1_OVERRIDE"
    fi

    local timestamp backup_dir server_bak client_bak priv_bak pub_bak
    timestamp="$(date '+%Y%m%d-%H%M%S.%3N')"
    backup_dir="${AWG_DIR}/regen-backups"
    mkdir -p "$backup_dir" || {
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    }
    chmod 700 "$backup_dir" 2>/dev/null || true
    server_bak="${backup_dir}/awg0.conf.${name}.${timestamp}.bak"
    client_bak="${backup_dir}/${name}.conf.${timestamp}.bak"
    priv_bak="${backup_dir}/${name}.private.${timestamp}.bak"
    pub_bak="${backup_dir}/${name}.public.${timestamp}.bak"
    cp -p "$SERVER_CONF_FILE" "$server_bak" || { exec {lock_fd}>&-; unset CLIENT_PSK; return 1; }
    cp -p "$AWG_DIR/${name}.conf" "$client_bak" || { exec {lock_fd}>&-; unset CLIENT_PSK; return 1; }
    [[ -f "$KEYS_DIR/${name}.private" ]] && cp -p "$KEYS_DIR/${name}.private" "$priv_bak" || true
    [[ -f "$KEYS_DIR/${name}.public" ]] && cp -p "$KEYS_DIR/${name}.public" "$pub_bak" || true

    if ! generate_keypair "$name"; then
        restore_regenerate_backup "$server_bak" "$client_bak" "$priv_bak" "$pub_bak" "$name"
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi
    local client_privkey client_pubkey
    client_privkey=$(cat "$KEYS_DIR/${name}.private") || {
        restore_regenerate_backup "$server_bak" "$client_bak" "$priv_bak" "$pub_bak" "$name"
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    }
    client_pubkey=$(cat "$KEYS_DIR/${name}.public") || {
        restore_regenerate_backup "$server_bak" "$client_bak" "$priv_bak" "$pub_bak" "$name"
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    }

    local _old_i1="${AWG_I1:-}"
    AWG_I1="$new_i1"
    local _cport
    _cport=$(_sanitize_port "${AWG_PORT:-}")
    if [[ "$_cport" == "0" ]]; then
        log_error "AWG_PORT некорректен ('${AWG_PORT:-}') — конфиг '$name' не перегенерирован."
        AWG_I1="$_old_i1"
        restore_regenerate_backup "$server_bak" "$client_bak" "$priv_bak" "$pub_bak" "$name"
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi
    if ! render_client_config "$name" "$client_ip" "$client_privkey" "$server_pubkey" "$endpoint" "$_cport" "$client_ipv6"; then
        AWG_I1="$_old_i1"
        restore_regenerate_backup "$server_bak" "$client_bak" "$priv_bak" "$pub_bak" "$name"
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi

    local _dns _ka _aip _client_conf
    _dns=$(printf '%s' "$current_dns" | sed 's/[&\\/]/\\&/g')
    _ka=$(printf '%s' "$current_keepalive" | sed 's/[&\\/]/\\&/g')
    _aip=$(printf '%s' "$current_allowed_ips" | sed 's/[&\\/]/\\&/g')
    _client_conf="$AWG_DIR/${name}.conf"
    if ! sed -i "s/^DNS = .*/DNS = ${_dns}/" "$_client_conf" ||
       ! sed -i "s/^PersistentKeepalive = .*/PersistentKeepalive = ${_ka}/" "$_client_conf"; then
        log_error "Ошибка обновления пользовательских параметров в $_client_conf"
        AWG_I1="$_old_i1"
        restore_regenerate_backup "$server_bak" "$client_bak" "$priv_bak" "$pub_bak" "$name"
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi
    # --reset-routes keeps the route set rendered from awgsetup_cfg.init,
    # including an explicit IPv6 leak-block sink on split-tunnel profiles.
    if [[ "${AWG_REGEN_RESET_ROUTES:-0}" != "1" ]] &&
       ! sed -i "s/^AllowedIPs = .*/AllowedIPs = ${_aip}/" "$_client_conf"; then
        log_error "Ошибка обновления AllowedIPs в $_client_conf"
        AWG_I1="$_old_i1"
        restore_regenerate_backup "$server_bak" "$client_bak" "$priv_bak" "$pub_bak" "$name"
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi
    if [[ -n "${AWG_I1_OVERRIDE:-}" ]]; then
        local _i1_tmp
        _i1_tmp=$(awg_mktemp) || {
            AWG_I1="$_old_i1"
            restore_regenerate_backup "$server_bak" "$client_bak" "$priv_bak" "$pub_bak" "$name"
            exec {lock_fd}>&-
            unset CLIENT_PSK
            return 1
        }
        if ! awk -v i1="$new_i1" '
            /^\[Peer\]/ && !done { print "I1 = " i1; done=1 }
            /^I1[[:space:]]*=/ { if (!done) { print "I1 = " i1; done=1 }; next }
            { print }
            END { if (!done) print "I1 = " i1 }
        ' "$_client_conf" > "$_i1_tmp" || ! mv "$_i1_tmp" "$_client_conf"; then
            rm -f "$_i1_tmp"
            AWG_I1="$_old_i1"
            restore_regenerate_backup "$server_bak" "$client_bak" "$priv_bak" "$pub_bak" "$name"
            exec {lock_fd}>&-
            unset CLIENT_PSK
            return 1
        fi
        chmod 600 "$_client_conf"
    fi

    if ! replace_peer_credentials "$name" "$client_pubkey" "$new_psk"; then
        log_error "Ошибка обновления peer credentials для '$name'"
        AWG_I1="$_old_i1"
        restore_regenerate_backup "$server_bak" "$client_bak" "$priv_bak" "$pub_bak" "$name"
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi
    generate_firewall_scripts >/dev/null 2>&1 || log_warn "Не удалось обновить P2P/firewall hook-скрипты."
    sync_clients_hosts

    if ! apply_config; then
        log_error "apply_config упал после регенерации '$name'; выполняется rollback."
        AWG_I1="$_old_i1"
        restore_regenerate_backup "$server_bak" "$client_bak" "$priv_bak" "$pub_bak" "$name"
        apply_config >/dev/null 2>&1 || true
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi

    exec {lock_fd}>&-

    generate_qr "$name" || log_warn "QR-код не обновлён для '$name'."
    if generate_vpn_uri "$name"; then
        generate_qr_vpnuri "$name" || log_warn "QR vpn:// не обновлён для '$name'."
    else
        log_warn "vpn:// URI не обновлён для '$name'."
    fi

    AWG_I1="$_old_i1"
    unset CLIENT_PSK
    log "Конфиг клиента '$name' безопасно перегенерирован."
    return 0
}

p2p_port_owner() {
    local needle="$1" name _allowed ports p parsed external_port _internal_port
    while IFS=$'\t' read -r name _allowed ports; do
        IFS=',' read -ra _ports <<< "${ports//[[:space:]]/}"
        for p in "${_ports[@]}"; do
            parsed=$(parse_p2p_forward_spec "$p") || continue
            IFS=$'\t' read -r external_port _internal_port <<< "$parsed"
            if [[ "$external_port" == "$needle" ]]; then
                echo "$name"
                return 0
            fi
        done
    done < <(_peer_inventory_tsv all)
    return 1
}

set_peer_p2p_ports() {
    local name="$1" ports="$2"
    [[ -n "$name" ]] || return 1
    local p parsed external_port internal_port clean_spec
    IFS=',' read -ra _ports <<< "${ports//[[:space:]]/}"
    local clean=()
    declare -A seen
    for p in "${_ports[@]}"; do
        [[ -z "$p" ]] && continue
        parsed=$(parse_p2p_forward_spec "$p") || { log_error "Невалидный P2P порт: $p"; return 1; }
        IFS=$'\t' read -r external_port internal_port <<< "$parsed"
        [[ -z "${seen[$external_port]+x}" ]] || continue
        seen["$external_port"]=1
        clean_spec="$external_port"
        [[ "$internal_port" == "$external_port" ]] || clean_spec="${external_port}:${internal_port}"
        clean+=("$clean_spec")
    done
    ports=$(IFS=','; echo "${clean[*]}")

    local lockfile="${AWG_DIR}/.awg_config.lock" lock_fd
    exec {lock_fd}>"$lockfile"
    if ! flock -x -w 10 "$lock_fd"; then
        log_error "Не удалось получить блокировку конфига"
        exec {lock_fd}>&-
        return 1
    fi
    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Клиент '$name' не найден"
        exec {lock_fd}>&-
        return 1
    fi

    local tmpfile
    tmpfile=$(awg_mktemp) || { exec {lock_fd}>&-; return 1; }
    local p2p_key="#_P2PPorts_Disabled"
    if awk -v target="$name" '
        /^\[Peer\]/ { in_peer=1; found=0; next }
        /^\[/ && !/^\[Peer\]/ { in_peer=0; found=0 }
        in_peer && $0 == "#_Name = " target { found=1; next }
        in_peer && found && /^#_P2PPorts[[:space:]]*=/ { found_enabled=1; exit }
        END { exit found_enabled ? 0 : 1 }
    ' "$SERVER_CONF_FILE" 2>/dev/null; then
        p2p_key="#_P2PPorts"
    fi
    awk -v target="$name" -v ports="$ports" -v p2p_key="$p2p_key" '
    function flush_meta_if_needed() {
        if (in_target && !ports_seen && ports != "") {
            print p2p_key " = " ports
            ports_seen=1
        }
    }
    /^\[Peer\]/ { flush_meta_if_needed(); in_peer=1; in_target=0; ports_seen=0; print; next }
    /^\[/ && !/^\[Peer\]/ { flush_meta_if_needed(); in_peer=0; in_target=0; ports_seen=0; print; next }
    in_peer && $0 == "#_Name = " target {
        in_target=1
        print
        if (ports != "") {
            print p2p_key " = " ports
            ports_seen=1
        }
        next
    }
    in_peer && in_target && /^#_P2PPorts(_Disabled)?[[:space:]]*=/ { next }
    { print }
    END { flush_meta_if_needed() }
    ' "$SERVER_CONF_FILE" > "$tmpfile" || {
        rm -f "$tmpfile"
        exec {lock_fd}>&-
        return 1
    }
    if ! mv "$tmpfile" "$SERVER_CONF_FILE"; then
        rm -f "$tmpfile"
        exec {lock_fd}>&-
        return 1
    fi
    chmod 600 "$SERVER_CONF_FILE"
    exec {lock_fd}>&-
    generate_firewall_scripts >/dev/null 2>&1 || log_warn "Не удалось обновить P2P/firewall hook-скрипты."
    return 0
}

add_p2p_port_to_peer() {
    local name="$1" port="${2:-}"
    [[ -n "$name" ]] || return 1
    if [[ -z "$port" ]]; then
        port=$(get_next_p2p_port) || return 1
    fi
    validate_p2p_port "$port" || { log_error "Невалидный P2P порт: $port"; return 1; }
    local owner
    owner=$(p2p_port_owner "$port" 2>/dev/null || true)
    if [[ -n "$owner" && "$owner" != "$name" ]]; then
        log_error "P2P порт $port уже назначен клиенту '$owner'"
        return 1
    fi
    local ports current p found=0 parsed external_port _internal_port
    current=$(get_peer_p2p_ports "$name")
    IFS=',' read -ra _ports <<< "${current//[[:space:]]/}"
    local out=()
    for p in "${_ports[@]}"; do
        [[ -z "$p" ]] && continue
        parsed=$(parse_p2p_forward_spec "$p") || continue
        IFS=$'\t' read -r external_port _internal_port <<< "$parsed"
        out+=("$p")
        [[ "$external_port" == "$port" ]] && found=1
    done
    [[ "$found" -eq 0 ]] && out+=("$port")
    ports=$(IFS=','; echo "${out[*]}")
    set_peer_p2p_ports "$name" "$ports"
    echo "$port"
}

remove_p2p_port_from_peer() {
    local name="$1" port="$2"
    validate_p2p_port "$port" || { log_error "Невалидный P2P порт: $port"; return 1; }
    local current p parsed external_port _internal_port
    current=$(get_peer_p2p_ports "$name")
    IFS=',' read -ra _ports <<< "${current//[[:space:]]/}"
    local out=()
    for p in "${_ports[@]}"; do
        [[ -z "$p" ]] && continue
        parsed=$(parse_p2p_forward_spec "$p") || continue
        IFS=$'\t' read -r external_port _internal_port <<< "$parsed"
        [[ "$external_port" == "$port" ]] && continue
        out+=("$p")
    done
    set_peer_p2p_ports "$name" "$(IFS=','; echo "${out[*]}")"
}

upgrade_existing_peers_ipv6_p2p() {
    local do_ipv6="${1:-1}" do_p2p="${2:-1}"
    local lockfile="${AWG_DIR}/.awg_config.lock" lock_fd
    exec {lock_fd}>"$lockfile"
    if ! flock -x -w 30 "$lock_fd"; then
        log_error "Не удалось получить блокировку конфига"
        exec {lock_fd}>&-
        return 1
    fi
    [[ -f "$SERVER_CONF_FILE" ]] || { exec {lock_fd}>&-; return 1; }
    local tmpfile
    tmpfile=$(awg_mktemp) || { exec {lock_fd}>&-; return 1; }
    AWG_IPV6_SUBNET="${AWG_IPV6_SUBNET:-}" \
    AWG_IPV6_ENABLED="${AWG_IPV6_ENABLED:-0}" \
    AWG_IPV6_MODE_EFFECTIVE="${AWG_IPV6_MODE_EFFECTIVE:-${AWG_IPV6_MODE:-legacy}}" \
    AWG_P2P_ENABLED="${AWG_P2P_ENABLED:-0}" \
    AWG_P2P_BASE_PORT="${AWG_P2P_BASE_PORT:-20000}" \
    AWG_P2P_PORTS_PER_CLIENT="${AWG_P2P_PORTS_PER_CLIENT:-3}" \
    python3 - "$SERVER_CONF_FILE" "$tmpfile" "$do_ipv6" "$do_p2p" <<'PY'
import ipaddress, os, re, sys

src, dst, do_ipv6, do_p2p = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4] == "1"
data = open(src, encoding="utf-8", errors="ignore").read().splitlines()
ipv6_enabled = os.environ.get("AWG_IPV6_ENABLED") == "1" and os.environ.get("AWG_IPV6_SUBNET")
p2p_enabled = os.environ.get("AWG_P2P_ENABLED") == "1"
net = ipaddress.ip_network(os.environ["AWG_IPV6_SUBNET"], strict=False) if ipv6_enabled else None
ipv6_mode = os.environ.get("AWG_IPV6_MODE_EFFECTIVE", os.environ.get("AWG_IPV6_MODE", "legacy"))
base = int(os.environ.get("AWG_P2P_BASE_PORT", "20000"))
count = int(os.environ.get("AWG_P2P_PORTS_PER_CLIENT", "3"))

used_v6 = set()
used_ports = set()
for line in data:
    if line.startswith("AllowedIPs"):
        for token in re.findall(r"([0-9A-Fa-f:]+/128)", line):
            try:
                used_v6.add(ipaddress.ip_interface(token).ip)
            except ValueError:
                pass
    if line.startswith("#_P2PPorts"):
        used_ports.update(int(x) for x in re.findall(r"\d+", line))
if net:
    used_v6.add(net.network_address)
    used_v6.add(net.network_address + (0x100 if ipv6_mode == "ndp" else 1))

def alloc_v6():
    if not net:
        return ""
    start = 0x101 if ipv6_mode == "ndp" else 2
    for i in range(start, min(net.num_addresses - 1, 65535) + 1):
        cand = net.network_address + i
        if cand not in used_v6:
            used_v6.add(cand)
            return str(cand)
    raise SystemExit("no free IPv6 addresses")

def alloc_ports(ipv4):
    last = int(ipv4.split(".")[-1])
    out = []
    for off in (0, 256, 512):
        p = base + off + last
        if 1024 <= p <= 65535 and p not in used_ports:
            used_ports.add(p)
            out.append(p)
        if len(out) >= count:
            return ",".join(map(str, out))
    p = base + 1
    while len(out) < count and p <= base + 1024 and p <= 65535:
        if p not in used_ports:
            used_ports.add(p)
            out.append(p)
        p += 1
    return ",".join(map(str, out))

out = []
i = 0
while i < len(data):
    line = data[i]
    if line != "[Peer]":
        out.append(line)
        i += 1
        continue
    block = [line]
    i += 1
    while i < len(data) and data[i] != "[Peer]" and not (data[i].startswith("[") and data[i] != "[Peer]"):
        block.append(data[i])
        i += 1
    name = ""
    allowed_idx = None
    p2p_idx = None
    for idx, bline in enumerate(block):
        if bline.startswith("#_Name = "):
            name = bline.split("=", 1)[1].strip()
        elif bline.startswith("AllowedIPs"):
            allowed_idx = idx
        elif bline.startswith("#_P2PPorts"):
            p2p_idx = idx
    if name and allowed_idx is not None:
        allowed = block[allowed_idx].split("=", 1)[1].strip()
        m4 = re.search(r"(\d+\.\d+\.\d+\.\d+)/32", allowed)
        has_v6 = re.search(r"[0-9A-Fa-f:]+/128", allowed)
        if do_ipv6 and ipv6_enabled and m4 and not has_v6:
            block[allowed_idx] = f"AllowedIPs = {m4.group(1)}/32, {alloc_v6()}/128"
        if do_p2p and p2p_enabled and m4 and p2p_idx is None:
            insert_at = 1
            for idx, bline in enumerate(block):
                if bline.startswith("#_Name = "):
                    insert_at = idx + 1
                    break
            block.insert(insert_at, f"#_P2PPorts_Disabled = {alloc_ports(m4.group(1))}")
    out.extend(block)
open(dst, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        rm -f "$tmpfile"
        exec {lock_fd}>&-
        log_error "Миграция peer metadata не удалась"
        return $rc
    fi
    if ! mv "$tmpfile" "$SERVER_CONF_FILE"; then
        rm -f "$tmpfile"
        exec {lock_fd}>&-
        return 1
    fi
    chmod 600 "$SERVER_CONF_FILE"
    exec {lock_fd}>&-
    generate_firewall_scripts >/dev/null 2>&1 || log_warn "Не удалось обновить P2P/firewall hook-скрипты."
    return 0
}

# ==============================================================================
# Валидация
# ==============================================================================

# Проверка AWG 2.0 конфигурации серверного конфига
validate_awg_config() {
    if [[ ! -f "$SERVER_CONF_FILE" ]]; then
        log_error "Серверный конфиг не найден: $SERVER_CONF_FILE"
        return 1
    fi

    local ok=1
    local param val
    local int_params=("Jc" "Jmin" "Jmax" "S1" "S2" "S3" "S4")
    local range_params=("H1" "H2" "H3" "H4")

    # Парсинг выровнен с load_awg_params_from_server_conf: произвольные пробелы
    # вокруг '=', last-wins при дублях строк (валидируем то значение, которое
    # реально загрузится), trim пробелов/CR. Раньше валидатор требовал ровно
    # один пробел и брал first-wins - вручную поправленный 'Jc=4' успешно
    # загружался, но проваливал валидацию с ложным "параметр не найден".
    for param in "${int_params[@]}"; do
        val=$(sed -n "s/^[[:space:]]*${param}[[:space:]]*=[[:space:]]*//p" "$SERVER_CONF_FILE" | tail -1 | tr -d '[:space:]')
        if [[ -z "$val" ]]; then
            log_error "Параметр '$param' не найден в серверном конфиге"
            ok=0
        elif ! [[ "$val" =~ ^[0-9]+$ ]]; then
            log_error "Параметр '$param' содержит невалидное значение: '$val' (ожидается целое число)"
            ok=0
        fi
    done

    # Протокольные границы (defense-in-depth для восстановленных бэкапов)
    local jc jmin jmax s3 s4
    jc=$(sed -n 's/^[[:space:]]*Jc[[:space:]]*=[[:space:]]*//p' "$SERVER_CONF_FILE" | tail -1 | tr -d '[:space:]')
    jmin=$(sed -n 's/^[[:space:]]*Jmin[[:space:]]*=[[:space:]]*//p' "$SERVER_CONF_FILE" | tail -1 | tr -d '[:space:]')
    jmax=$(sed -n 's/^[[:space:]]*Jmax[[:space:]]*=[[:space:]]*//p' "$SERVER_CONF_FILE" | tail -1 | tr -d '[:space:]')
    s3=$(sed -n 's/^[[:space:]]*S3[[:space:]]*=[[:space:]]*//p' "$SERVER_CONF_FILE" | tail -1 | tr -d '[:space:]')
    s4=$(sed -n 's/^[[:space:]]*S4[[:space:]]*=[[:space:]]*//p' "$SERVER_CONF_FILE" | tail -1 | tr -d '[:space:]')
    if [[ "$jc" =~ ^[0-9]+$ ]]; then
        if [[ "$jc" -lt 1 || "$jc" -gt 128 ]]; then
            log_error "Jc=$jc вне допустимого диапазона (1-128)"
            ok=0
        fi
    fi
    if [[ "$jmin" =~ ^[0-9]+$ && "$jmax" =~ ^[0-9]+$ ]]; then
        if [[ "$jmin" -gt 1280 ]]; then
            log_error "Jmin=$jmin превышает 1280"
            ok=0
        fi
        if [[ "$jmax" -gt 1280 ]]; then
            log_error "Jmax=$jmax превышает 1280"
            ok=0
        fi
        if [[ "$jmax" -lt "$jmin" ]]; then
            log_error "Jmax ($jmax) меньше Jmin ($jmin)"
            ok=0
        fi
    fi
    if [[ "$s3" =~ ^[0-9]+$ && "$s3" -gt 64 ]]; then
        log_error "S3=$s3 превышает максимум (64)"
        ok=0
    fi
    if [[ "$s4" =~ ^[0-9]+$ && "$s4" -gt 32 ]]; then
        log_error "S4=$s4 превышает максимум (32)"
        ok=0
    fi

    local _h_ranges=()
    for param in "${range_params[@]}"; do
        val=$(sed -n "s/^[[:space:]]*${param}[[:space:]]*=[[:space:]]*//p" "$SERVER_CONF_FILE" | tail -1 | tr -d '[:space:]')
        if [[ -z "$val" ]]; then
            log_error "Параметр '$param' не найден в серверном конфиге"
            ok=0
        elif ! [[ "$val" =~ ^[0-9]+-[0-9]+$ ]]; then
            log_error "Параметр '$param' содержит невалидное значение: '$val' (ожидается формат MIN-MAX)"
            ok=0
        else
            local range_lo="${val%-*}" range_hi="${val#*-}"
            if [[ "$range_lo" -ge "$range_hi" ]]; then
                log_error "Параметр '$param': нижняя граница ($range_lo) >= верхней ($range_hi)"
                ok=0
            else
                _h_ranges+=("$range_lo $range_hi $param")
            fi
        fi
    done

    # Попарное непересечение H1-H4 - ключевой инвариант AWG 2.0. Без этой
    # проверки конфиг из чужого бэкапа с пересекающимися диапазонами
    # проходил валидацию, хотя протокол его не допускает.
    if [[ ${#_h_ranges[@]} -eq 4 ]]; then
        local _i _j _lo1 _hi1 _n1 _lo2 _hi2 _n2
        for ((_i = 0; _i < 4; _i++)); do
            for ((_j = _i + 1; _j < 4; _j++)); do
                read -r _lo1 _hi1 _n1 <<< "${_h_ranges[$_i]}"
                read -r _lo2 _hi2 _n2 <<< "${_h_ranges[$_j]}"
                if (( _lo1 <= _hi2 && _lo2 <= _hi1 )); then
                    log_error "Диапазоны ${_n1} (${_lo1}-${_hi1}) и ${_n2} (${_lo2}-${_hi2}) пересекаются"
                    ok=0
                fi
            done
        done
    fi

    # I1 опционален. Отсутствие = либо не задан, либо намеренно отключён через
    # --no-cps (issue #159): десктопный AmneziaVPN на macOS не поддерживает CPS.
    if ! grep -qE '^[[:space:]]*I1[[:space:]]*=' "$SERVER_CONF_FILE"; then
        if grep -qE '^[[:space:]]*(export[[:space:]]+)?NO_CPS=1' "$CONFIG_FILE" 2>/dev/null; then
            log "I1 (CPS) отключён намеренно (--no-cps) - ожидаемо для десктопного AmneziaVPN на macOS"
        else
            log_warn "Параметр I1 (CPS) не найден - CPS concealment не активен"
        fi
    fi

    if [[ $ok -eq 1 ]]; then
        log "Валидация AWG 2.0 конфига: OK"
        return 0
    else
        return 1
    fi
}

# ==============================================================================
# Срок действия клиентов (expiry)
# ==============================================================================

EXPIRY_DIR="${AWG_DIR}/expiry"
EXPIRY_CRON="${EXPIRY_CRON:-/etc/cron.d/awg-expiry}"

# Парсинг длительности в секунды: 1h, 12h, 1d, 7d, 30d
# parse_duration <duration_string>
parse_duration() {
    local input="$1"
    local num unit
    if [[ "$input" =~ ^([0-9]+)([hdw])$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
    else
        log_error "Некорректный формат длительности: '$input'. Используйте: 1h, 12h, 1d, 7d, 4w"
        return 1
    fi
    case "$unit" in
        h) echo $((num * 3600)) ;;
        d) echo $((num * 86400)) ;;
        w) echo $((num * 604800)) ;; # 7 дней
        *) return 1 ;;
    esac
}

# Установка срока действия клиента
# set_client_expiry <name> <duration>
set_client_expiry() {
    local name="$1"
    local duration="$2"
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Невалидное имя клиента: '$name'"
        return 1
    fi
    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Клиент '$name' не найден."
        return 1
    fi
    local seconds
    seconds=$(parse_duration "$duration") || return 1
    local now
    now=$(date +%s)
    local expires_at=$((now + seconds))

    mkdir -p "$EXPIRY_DIR" || {
        log_error "Ошибка создания $EXPIRY_DIR"
        return 1
    }
    echo "$expires_at" > "$EXPIRY_DIR/$name" || {
        log_error "Ошибка записи expiry для '$name'"
        return 1
    }
    chmod 600 "$EXPIRY_DIR/$name"
    local expires_date
    expires_date=$(date -d "@$expires_at" '+%F %T' 2>/dev/null || echo "$expires_at")
    log "Срок действия '$name': $expires_date ($duration)"
    return 0
}

# Получение срока действия клиента (unix timestamp или пустая строка)
# get_client_expiry <name>
get_client_expiry() {
    local name="$1"
    local efile="$EXPIRY_DIR/$name"
    if [[ -f "$efile" ]]; then
        cat "$efile"
    fi
}

# Форматирование оставшегося времени
# format_remaining <expires_at_timestamp>
format_remaining() {
    local expires_at="$1"
    local now
    now=$(date +%s)
    local diff=$((expires_at - now))
    if [[ $diff -le 0 ]]; then
        local ago=$(( (-diff) / 3600 ))
        if [[ $ago -ge 24 ]]; then
            echo "истёк $(( ago / 24 ))д назад"
        elif [[ $ago -ge 1 ]]; then
            echo "истёк ${ago}ч назад"
        else
            local ago_mins=$(( (-diff) / 60 ))
            if [[ $ago_mins -ge 1 ]]; then
                echo "истёк ${ago_mins}м назад"
            else
                echo "только что истёк"
            fi
        fi
        return 0
    fi
    local days=$((diff / 86400))
    local hours=$(( (diff % 86400) / 3600 ))
    if [[ $days -gt 0 ]]; then
        echo "${days}д ${hours}ч"
    else
        local mins=$(( (diff % 3600) / 60 ))
        echo "${hours}ч ${mins}м"
    fi
}

# Проверка и удаление истёкших клиентов
check_expired_clients() {
    if [[ ! -d "$EXPIRY_DIR" ]]; then return 0; fi

    local removed=0
    local efile
    for efile in "$EXPIRY_DIR"/*; do
        [[ -f "$efile" ]] || continue
        local name
        name=$(basename "$efile")
        # Валидация имени: тот же regex что validate_client_name в manage_amneziawg.sh.
        # Defense-in-depth — EXPIRY_DIR доступен только root, но защита от
        # случайно попавшего невалидного файла (или symlink attack если expiry_dir
        # когда-то станет shared) нужна перед использованием $name в путях
        # и передачей в remove_peer_from_server (self-audit).
        if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            log_warn "Пропуск невалидного expiry файла: '$name'"
            continue
        fi
        local expires_at
        expires_at=$(cat "$efile" 2>/dev/null)
        if [[ -z "$expires_at" || ! "$expires_at" =~ ^[0-9]+$ ]]; then
            log_warn "Некорректные данные expiry для '$name': '$(head -c 50 "$efile" 2>/dev/null)'"
            continue
        fi

        local now
        now=$(date +%s)
        if [[ $now -ge $expires_at ]]; then
            log "Клиент '$name' истёк. Удаление..."
            if [[ -r "$SERVER_CONF_FILE" ]] && ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE"; then
                # Orphan-метка: peer уже удалён из конфига (вручную, через awg
                # или restore старого бэкапа). Без этой ветки cron каждые 5
                # минут вечно ретраил бы remove_peer_from_server и копил warn
                # в expiry.log, а артефакты клиента никогда не зачищались.
                # Гард [[ -r ]]: временно отсутствующий/нечитаемый конфиг
                # (mid-restore, сбой ФС) НЕ повод стирать артефакты клиента -
                # такой случай уходит в обычную ветку с warn и повтором позже.
                _remove_client_files "$name"
                remove_client_expiry "$name"
                log "Клиент '$name': peer отсутствует в конфиге - зачищены осиротевшие артефакты и expiry-метка."
            elif remove_peer_from_server "$name" 2>/dev/null; then
                _remove_client_files "$name"
                remove_client_expiry "$name"
                log "Клиент '$name' удалён (истёк)."
                ((removed++))
            else
                log_warn "Не удалось удалить истёкшего клиента '$name'."
            fi
        fi
    done

    if [[ $removed -gt 0 ]]; then
        log "Удалено истёкших клиентов: $removed. Применение конфигурации..."
        if ! apply_config; then
            log_error "apply_config упал после удаления истёкших клиентов. Peer-ы убраны из конфига и expiry/, но могут оставаться на live интерфейсе. Требуется ручной перезапуск: systemctl restart awg-quick@awg0"
            return 1
        fi
    fi
    return 0
}

# Установка cron-задачи для автоудаления
install_expiry_cron() {
    # Идемпотентность по СОДЕРЖИМОМУ, не по факту существования файла. Раньше
    # ранний выход «файл есть» оставлял stale-пути после restore/переноса/
    # --conf-dir: cron продолжал смотреть в старый AWG_DIR. Генерируем ожидаемый
    # текст и заменяем файл, только если он отличается.
    local _cron_tmp
    _cron_tmp=$(awg_mktemp "$(dirname "$EXPIRY_CRON")") || { log_error "Ошибка mktemp для cron expiry"; return 1; }
    # Проверяем успех записи ДО cmp/mv: иначе сбой (диск/права) мог бы атомарно
    # заменить рабочий cron пустым/частичным tmp.
    if ! cat > "$_cron_tmp" << CRONEOF
# AmneziaWG client expiry check - every 5 minutes
AWG_DIR="${AWG_DIR}"
CONFIG_FILE="${CONFIG_FILE}"
SERVER_CONF_FILE="${SERVER_CONF_FILE}"
*/5 * * * * root /bin/bash -c 'source "${AWG_DIR}/awg_common.sh" || exit 1; trap _awg_cleanup EXIT; check_expired_clients' >> "${AWG_DIR}/expiry.log" 2>&1
CRONEOF
    then
        rm -f "$_cron_tmp"
        log_error "Ошибка записи cron-задачи expiry"
        return 1
    fi
    if [[ -f "$EXPIRY_CRON" ]] && cmp -s "$_cron_tmp" "$EXPIRY_CRON"; then
        rm -f "$_cron_tmp"
        log_debug "Cron-задача expiry уже актуальна."
        return 0
    fi
    chmod 644 "$_cron_tmp"
    if ! mv -f "$_cron_tmp" "$EXPIRY_CRON"; then
        rm -f "$_cron_tmp"
        log_error "Ошибка установки cron-задачи expiry: $EXPIRY_CRON"
        return 1
    fi
    log "Cron-задача expiry установлена/обновлена: $EXPIRY_CRON"
}

# Удаление expiry-данных клиента
remove_client_expiry() {
    local name="$1"
    rm -f "$EXPIRY_DIR/$name" 2>/dev/null
    # Удаляем cron если больше нет клиентов с expiry
    if [[ -d "$EXPIRY_DIR" ]] && [[ -z "$(ls -A "$EXPIRY_DIR" 2>/dev/null)" ]]; then
        rm -f "$EXPIRY_CRON" 2>/dev/null
        log_debug "Cron-задача expiry удалена (нет клиентов с expiry)."
    fi
}
