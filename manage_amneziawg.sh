#!/bin/bash
# shellcheck disable=SC1003,SC2012,SC2015,SC2016,SC2004,SC2086,SC2317

# Проверка минимальной версии Bash
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ОШИБКА: Требуется Bash >= 4.0 (текущая: ${BASH_VERSION})" >&2; exit 1
fi

# ==============================================================================
# Скрипт для управления пользователями (пирами) AmneziaWG 2.0
# Автор: @bivlked
# Версия: 5.13.0
# Дата: 2026-05-13
# Репозиторий: https://github.com/bivlked/amneziawg-installer
# ==============================================================================

# --- Безопасный режим и Константы ---
# shellcheck disable=SC2034
SCRIPT_VERSION="5.13.0"
set -o pipefail
AWG_DIR="/root/awg"
SERVER_CONF_FILE="/etc/amnezia/amneziawg/awg0.conf"
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
KEYS_DIR="$AWG_DIR/keys"
COMMON_SCRIPT_PATH="$AWG_DIR/awg_common.sh"
LOG_FILE="$AWG_DIR/manage_amneziawg.log"
NO_COLOR=0
VERBOSE_LIST=0
JSON_OUTPUT=0
EXPIRES_DURATION=""

# --- Автоочистка временных файлов и директорий ---
# _manage_temp_dirs хранит mktemp -d пути для backup/restore.
# _awg_cleanup из awg_common.sh удаляет файлы (awg_mktemp), но не директории —
# поэтому здесь chained cleanup: сначала наши директории, потом библиотечный.
# Гарантирует что SIGINT во время backup_configs/restore_backup не оставит
# orphan /tmp/tmp.XXXX (audit).
_manage_temp_dirs=()

manage_mktempdir() {
    local d
    d=$(mktemp -d) || return 1
    _manage_temp_dirs+=("$d")
    echo "$d"
}

_manage_cleanup() {
    local d
    for d in "${_manage_temp_dirs[@]}"; do
        [[ -d "$d" ]] && rm -rf "$d"
    done
    type _awg_cleanup &>/dev/null && _awg_cleanup
}
trap _manage_cleanup EXIT INT TERM

# --- Обработка аргументов ---
COMMAND=""
ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)         COMMAND="help"; break ;;
        -v|--verbose)      VERBOSE_LIST=1; shift ;;
        --no-color)        NO_COLOR=1; shift ;;
        --json)            JSON_OUTPUT=1; shift ;;
        --expires=*)       EXPIRES_DURATION="${1#*=}"; shift ;;
        --conf-dir=*)      AWG_DIR="${1#*=}"; shift ;;
        --server-conf=*)   SERVER_CONF_FILE="${1#*=}"; shift ;;
        --apply-mode=*)    _CLI_APPLY_MODE="${1#*=}"; export AWG_APPLY_MODE="$_CLI_APPLY_MODE"; shift ;;
        --psk)             CLI_ADD_PSK=1; shift ;;
        --yes)             CLI_YES=1; shift ;;
        --*)               echo "Неизвестная опция: $1" >&2; COMMAND="help"; break ;;
        *)
            if [[ -z "$COMMAND" ]]; then
                COMMAND=$1
            else
                ARGS+=("$1")
            fi
            shift ;;
    esac
done
CLIENT_NAME="${ARGS[0]}"
PARAM="${ARGS[1]}"
VALUE="${ARGS[2]}"

# Обновляем пути после возможного переопределения --conf-dir
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
KEYS_DIR="$AWG_DIR/keys"
COMMON_SCRIPT_PATH="$AWG_DIR/awg_common.sh"
LOG_FILE="$AWG_DIR/manage_amneziawg.log"

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

    # WARN и ERROR в stderr (симметрия с install_amneziawg.sh:110+, важно
    # для CI/automation парсинга: stdout = «данные», stderr = «диагностика»).
    if [[ "$type" == "ERROR" || "$type" == "WARN" ]]; then
        printf "${color_start}%s${color_end}\n" "$entry" >&2
    else
        printf "${color_start}%s${color_end}\n" "$entry"
    fi
}

log()       { log_msg "INFO" "$1"; }
log_warn()  { log_msg "WARN" "$1"; }
log_error() { log_msg "ERROR" "$1"; }
log_debug() { if [[ "$VERBOSE_LIST" -eq 1 ]]; then log_msg "DEBUG" "$1"; fi; }
die()       { log_error "$1"; exit 1; }

# ==============================================================================
# Утилиты
# ==============================================================================

is_interactive() { [[ -t 0 && -t 1 ]]; }

# Экранирование спецсимволов для sed (предотвращает command injection)
escape_sed() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//&/\\&}"
    s="${s//#/\\#}"
    s="${s////\\/}"
    printf '%s' "$s"
}

confirm_action() {
    # CLI флаг --yes или ENV AWG_YES=1 пропускают confirm-prompt — для скриптов,
    # cron, Ansible и интерактивных вызовов где явно подтвердили заранее.
    if [[ "${CLI_YES:-0}" == "1" || "${AWG_YES:-0}" == "1" ]]; then
        return 0
    fi
    if ! is_interactive; then return 0; fi
    local action="$1" subject="$2"
    read -rp "Вы действительно хотите $action $subject? [y/N]: " confirm < /dev/tty
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        return 0
    else
        log "Действие отменено."
        return 1
    fi
}

validate_client_name() {
    local name="$1"
    if [[ -z "$name" ]]; then log_error "Имя пустое."; return 1; fi
    if [[ ${#name} -gt 63 ]]; then log_error "Имя > 63 симв."; return 1; fi
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then log_error "Имя содержит недоп. символы."; return 1; fi
    return 0
}

# ==============================================================================
# Проверка зависимостей
# ==============================================================================

check_dependencies() {
    log "Проверка зависимостей..."
    local ok=1

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Не найден: $CONFIG_FILE"
        ok=0
    fi
    if [[ ! -f "$COMMON_SCRIPT_PATH" ]]; then
        log_error "Не найден: $COMMON_SCRIPT_PATH"
        ok=0
    fi
    if [[ ! -f "$SERVER_CONF_FILE" ]]; then
        log_error "Не найден: $SERVER_CONF_FILE"
        ok=0
    fi
    if [[ "$ok" -eq 0 ]]; then
        die "Не найдены файлы установки. Запустите install_amneziawg.sh."
    fi

    if ! command -v awg &>/dev/null; then die "'awg' не найден."; fi
    if ! command -v qrencode &>/dev/null; then log_warn "qrencode не найден (QR-коды не будут созданы)."; fi

    # Подключаем общую библиотеку
    # shellcheck source=/dev/null
    source "$COMMON_SCRIPT_PATH" || die "Ошибка загрузки $COMMON_SCRIPT_PATH"

    log "Зависимости OK."
}

# ==============================================================================
# Резервное копирование
# ==============================================================================

# Внутренняя функция: выполняет бэкап без захвата блокировки.
# Вызывается только из контекста, где .awg_backup.lock уже удерживается.
#
# Контракт обработки ошибок (v5.11.0 A1.1):
#   - Критичные артефакты (awg0.conf, CONFIG_FILE, server_*.key, клиентские
#     *.conf, $KEYS_DIR/*) — при ошибке cp возвращает 1 (не продолжает
#     молча). Повреждённый backup опаснее отсутствующего.
#   - Опциональные (QR *.png, *.vpnuri, expiry/, cron) — ошибка cp → log_warn,
#     продолжаем. Они восстанавливаются из конфига.
#   - Отсутствие глобов (клиентов нет) отличается от cp-failure через
#     compgen -G pre-check.
# По успеху устанавливает LAST_BACKUP_PATH (используется restore_backup
# для rollback snapshot).
_backup_configs_nolock() {
    log "Создание бэкапа..."
    local bd="$AWG_DIR/backups"
    mkdir -p "$bd" || die "Ошибка mkdir $bd"
    chmod 700 "$bd" 2>/dev/null
    local ts bf td
    # Миллисекундная точность в timestamp защищает от collision при rapid-fire
    # backup'ах (например, regen → backup → modify → backup в одной секунде).
    ts=$(date +%F_%H-%M-%S.%3N)
    bf="$bd/awg_backup_${ts}.tar.gz"
    td=$(manage_mktempdir) || die "Ошибка создания временной директории"

    mkdir -p "$td/server" "$td/clients" "$td/keys"

    # Серверный конфиг (mandatory)
    if [[ -f "$SERVER_CONF_FILE" ]]; then
        if ! cp -a "$SERVER_CONF_FILE" "$td/server/"; then
            log_error "Не удалось сохранить $SERVER_CONF_FILE в бэкап."
            rm -rf "$td"
            return 1
        fi
    else
        log_warn "Серверный конфиг отсутствует ($SERVER_CONF_FILE) — в бэкап не попадёт."
    fi
    # Опциональные файлы рядом с awg0.conf (backup'ы от modify, и т.п.)
    if compgen -G "${SERVER_CONF_FILE}.*" > /dev/null; then
        cp -a "${SERVER_CONF_FILE}".* "$td/server/" 2>/dev/null || \
            log_warn "Не удалось сохранить ${SERVER_CONF_FILE}.* (некритично)."
    fi

    # Метаданные клиентов (mandatory)
    if [[ -f "$CONFIG_FILE" ]]; then
        if ! cp -a "$CONFIG_FILE" "$td/clients/"; then
            log_error "Не удалось сохранить $CONFIG_FILE в бэкап."
            rm -rf "$td"
            return 1
        fi
    fi
    # Клиентские *.conf (critical если существуют)
    if compgen -G "$AWG_DIR/*.conf" > /dev/null; then
        if ! cp -a "$AWG_DIR"/*.conf "$td/clients/"; then
            log_error "Не удалось сохранить клиентские *.conf в бэкап."
            rm -rf "$td"
            return 1
        fi
    fi
    # QR-коды *.png (optional — перегенерируются из conf)
    if compgen -G "$AWG_DIR/*.png" > /dev/null; then
        cp -a "$AWG_DIR"/*.png "$td/clients/" 2>/dev/null || \
            log_warn "Не удалось сохранить клиентские *.png (некритично)."
    fi
    # vpn:// URI (optional — перегенерируются)
    if compgen -G "$AWG_DIR/*.vpnuri" > /dev/null; then
        cp -a "$AWG_DIR"/*.vpnuri "$td/clients/" 2>/dev/null || \
            log_warn "Не удалось сохранить клиентские *.vpnuri (некритично)."
    fi

    # Ключи клиентов (critical если существуют)
    if compgen -G "$KEYS_DIR/*" > /dev/null; then
        if ! cp -a "$KEYS_DIR"/* "$td/keys/"; then
            log_error "Не удалось сохранить ключи клиентов ($KEYS_DIR) в бэкап."
            rm -rf "$td"
            return 1
        fi
    fi

    # Ключи сервера (mandatory если существуют)
    if [[ -f "$AWG_DIR/server_private.key" ]]; then
        if ! cp -a "$AWG_DIR/server_private.key" "$td/"; then
            log_error "Не удалось сохранить server_private.key в бэкап."
            rm -rf "$td"
            return 1
        fi
    fi
    if [[ -f "$AWG_DIR/server_public.key" ]]; then
        if ! cp -a "$AWG_DIR/server_public.key" "$td/"; then
            log_error "Не удалось сохранить server_public.key в бэкап."
            rm -rf "$td"
            return 1
        fi
    fi

    # Expiry (critical — Unix epoch метки не восстановимы из других конфигов).
    # Потеря этих данных меняет поведение expiry-enforcement после restore.
    if [[ -d "${EXPIRY_DIR:-$AWG_DIR/expiry}" ]]; then
        if ! cp -a "${EXPIRY_DIR:-$AWG_DIR/expiry}" "$td/expiry"; then
            log_error "Не удалось сохранить expiry/ в бэкап."
            rm -rf "$td"
            return 1
        fi
    fi
    # Cron awg-expiry (critical — без него expiry-enforcement перестаёт работать).
    if [[ -f /etc/cron.d/awg-expiry ]]; then
        if ! cp -a /etc/cron.d/awg-expiry "$td/"; then
            log_error "Не удалось сохранить /etc/cron.d/awg-expiry в бэкап."
            rm -rf "$td"
            return 1
        fi
    fi

    tar -czf "$bf" -C "$td" . || { rm -rf "$td"; die "Ошибка tar $bf"; }
    log_debug "tar: архив создан $bf"
    rm -rf "$td"
    chmod 600 "$bf" || log_warn "Ошибка chmod бэкапа"

    # Оставляем максимум 10 бэкапов
    find "$bd" -maxdepth 1 -name "awg_backup_*.tar.gz" -printf '%T@ %p\n' | \
        sort -nr | tail -n +11 | cut -d' ' -f2- | xargs -r rm -f || \
        log_warn "Ошибка удаления старых бэкапов"

    LAST_BACKUP_PATH="$bf"
    log "Бэкап создан: $bf"
}

backup_configs() {
    local backup_lockfile="${AWG_DIR}/.awg_backup.lock"
    local backup_lock_fd
    exec {backup_lock_fd}>"$backup_lockfile"
    if ! flock -x -w 30 "$backup_lock_fd"; then
        log_error "Таймаут ожидания блокировки backup (30 сек). Другая операция backup/restore уже запущена."
        exec {backup_lock_fd}>&-
        return 1
    fi
    _backup_configs_nolock
    local _rc=$?
    exec {backup_lock_fd}>&-
    return "$_rc"
}

# Откат к pre-restore snapshot (v5.11.0 A5.1).
# Вызывается из restore_backup при любой ошибке после начала destructive ops.
# Извлекает snapshot из $1 и копирует файлы обратно в исходные пути, затем
# пытается запустить сервис. Не критично, если cp какого-то файла провалится:
# цель — вернуть систему в рабочее состояние best-effort, чтобы пользователь
# не остался без VPN.
_restore_do_rollback() {
    local _snap="$1"
    if [[ -z "$_snap" || ! -f "$_snap" ]]; then
        log_error "Rollback snapshot недоступен ($_snap) — требуется ручное восстановление."
        return 1
    fi
    log_warn "Откат к состоянию до restore ($(basename "$_snap"))..."
    local _rtd
    _rtd=$(manage_mktempdir) || {
        log_error "Не удалось создать tmpdir для отката. Ручное: tar -xzf $_snap -C /"
        return 1
    }
    if ! tar -xzf "$_snap" --no-same-owner --no-same-permissions -C "$_rtd" 2>/dev/null; then
        rm -rf "$_rtd"
        log_error "Не удалось распаковать rollback snapshot ($_snap). Ручное восстановление: tar -xzf $_snap -C <нужная папка>"
        return 1
    fi
    local _scdir
    _scdir=$(dirname "$SERVER_CONF_FILE")
    [[ -d "$_rtd/server" ]] && cp -a "$_rtd/server/"* "$_scdir/" 2>/dev/null
    [[ -d "$_rtd/clients" ]] && cp -a "$_rtd/clients/"* "$AWG_DIR/" 2>/dev/null
    [[ -d "$_rtd/keys" ]] && cp -a "$_rtd/keys/"* "$KEYS_DIR/" 2>/dev/null
    [[ -f "$_rtd/server_private.key" ]] && cp -a "$_rtd/server_private.key" "$AWG_DIR/" 2>/dev/null
    [[ -f "$_rtd/server_public.key" ]] && cp -a "$_rtd/server_public.key" "$AWG_DIR/" 2>/dev/null
    [[ -d "$_rtd/expiry" ]] && cp -a "$_rtd/expiry"/* "${EXPIRY_DIR:-$AWG_DIR/expiry}/" 2>/dev/null
    [[ -f "$_rtd/awg-expiry" ]] && cp -a "$_rtd/awg-expiry" /etc/cron.d/awg-expiry 2>/dev/null
    rm -rf "$_rtd"

    log "Откат завершён — пытаюсь запустить сервис..."
    if systemctl start awg-quick@awg0; then
        log "Сервис запущен после отката."
        return 0
    else
        log_error "Сервис не стартовал после отката — проверьте: systemctl status awg-quick@awg0"
        return 1
    fi
}

restore_backup() {
    local bf="$1"
    local bd="$AWG_DIR/backups"

    if [[ -z "$bf" ]]; then
        if ! is_interactive; then
            die "Путь к бэкапу обязателен в неинтерактивном режиме: restore <файл>"
        fi
        if [[ ! -d "$bd" ]] || [[ -z "$(ls -A "$bd" 2>/dev/null)" ]]; then
            die "Бэкапы не найдены в $bd."
        fi
        local backups
        backups=$(find "$bd" -maxdepth 1 -name "awg_backup_*.tar.gz" | sort -r)
        if [[ -z "$backups" ]]; then die "Бэкапы не найдены."; fi

        echo "Доступные бэкапы:"
        local i=1
        local bl=()
        while IFS= read -r f; do
            echo "  $i) $(basename "$f")"
            bl[$i]="$f"
            ((i++))
        done <<< "$backups"

        read -rp "Номер для восстановления (0-отмена): " choice < /dev/tty
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -eq 0 ]] || [[ "$choice" -ge "$i" ]]; then
            log "Отмена."
            return 1
        fi
        bf="${bl[$choice]}"
    fi

    if [[ ! -f "$bf" ]]; then die "Файл бэкапа '$bf' не найден."; fi
    log "Восстановление из $bf"
    if ! confirm_action "восстановить" "конфигурацию из '$bf'"; then return 1; fi

    # v5.11.0 A5.1: rollback infrastructure.
    # _rollback_snap заполнится после _backup_configs_nolock — до этого
    # момента destructive ops не выполняются, откат не нужен.
    # _destructive_ops_started=1 ставится перед первой деструктивной
    # операцией (после systemctl stop) — rollback делаем только когда
    # система реально изменена, иначе cp тех же байт это no-op overhead.
    # _restore_ok=1 выставляется только на финальном успехе.
    local _rollback_snap=""
    local _restore_ok=0
    local _destructive_ops_started=0
    local td=""

    # Захват блокировки backup (внешняя) — предотвращает параллельные backup/restore
    local backup_lockfile="${AWG_DIR}/.awg_backup.lock"
    local backup_lock_fd
    exec {backup_lock_fd}>"$backup_lockfile"
    if ! flock -x -w 30 "$backup_lock_fd"; then
        log_error "Таймаут ожидания блокировки backup (30 сек). Другая операция backup/restore уже запущена."
        exec {backup_lock_fd}>&-
        return 1
    fi

    # Захват блокировки конфига (внутренняя) — предотвращает изменение конфига во время restore
    local config_lockfile="${AWG_DIR}/.awg_config.lock"
    local config_lock_fd
    exec {config_lock_fd}>"$config_lockfile"
    if ! flock -x -w 30 "$config_lock_fd"; then
        log_error "Таймаут ожидания блокировки конфига (30 сек)."
        exec {config_lock_fd}>&-
        exec {backup_lock_fd}>&-
        return 1
    fi

    # Cleanup-хук: вызывается на любом return (через trap RETURN).
    # При _restore_ok=0 И _destructive_ops_started=1 → rollback к
    # _rollback_snap. Всегда → удаление временной директории и снятие
    # блокировок. Первым делом сбрасываем RETURN trap — bash `trap ...
    # RETURN` имеет global lifetime и без очистки срабатывал бы на
    # любом последующем return в этом shell.
    _restore_cleanup() {
        # Порядок важен: сначала захватываем $? (return-code функции
        # restore_backup), потом снимаем RETURN trap. Swap сломал бы
        # захват, т.к. `trap - RETURN` — builtin, затирает $? в 0.
        # Реентранс невозможен: `local` и `trap -` не вызывают функций,
        # а после `trap - RETURN` наш trap уже снят.
        local _rc=$?
        trap - RETURN
        if [[ $_restore_ok -eq 0 && $_destructive_ops_started -eq 1 && -n "$_rollback_snap" ]]; then
            _restore_do_rollback "$_rollback_snap" || true
        fi
        [[ -n "$td" && -d "$td" ]] && rm -rf "$td"
        [[ -n "${config_lock_fd:-}" ]] && exec {config_lock_fd}>&- 2>/dev/null
        [[ -n "${backup_lock_fd:-}" ]] && exec {backup_lock_fd}>&- 2>/dev/null
        return $_rc
    }
    trap _restore_cleanup RETURN

    log "Создание бэкапа текущей..."
    if ! _backup_configs_nolock; then
        log_error "Не удалось создать бэкап текущей конфигурации."
        return 1
    fi
    # Фиксируем rollback snapshot (устанавливается _backup_configs_nolock)
    _rollback_snap="${LAST_BACKUP_PATH:-}"

    td=$(manage_mktempdir) || {
        log_error "Ошибка создания временной директории"
        return 1
    }

    # Pre-extraction валидация: проверяем содержимое tar до распаковки.
    # Defense-in-depth: наш threat model (root-only локальные бэкапы) делает
    # эксплуатацию маловероятной, но crafted или подменённый архив мог бы
    # использовать path traversal (../), абсолютные пути, symlinks или device
    # файлы для перезаписи произвольных системных файлов при распаковке от root.

    # Проверка типов через verbose listing: отклоняем block/char/FIFO/hardlink
    local _tar_verbose _vline _tc
    _tar_verbose=$(tar -tvzf "$bf" 2>/dev/null) || {
        log_error "Не удалось прочитать содержимое архива $bf"
        return 1
    }
    while IFS= read -r _vline; do
        [[ -z "$_vline" ]] && continue
        _tc="${_vline:0:1}"
        case "$_tc" in
            b|c|p|h|l)
                log_error "Архив содержит опасный тип файла ('${_tc}'): '${_vline}' — восстановление отменено."
                return 1
                ;;
        esac
    done <<< "$_tar_verbose"

    # Проверка путей: абсолютные пути и path traversal
    local _tar_list _bad_entry
    _tar_list=$(tar -tzf "$bf" 2>/dev/null) || {
        log_error "Не удалось прочитать содержимое архива $bf"
        return 1
    }
    while IFS= read -r _bad_entry; do
        [[ -z "$_bad_entry" ]] && continue
        # Абсолютные пути
        if [[ "$_bad_entry" == /* ]]; then
            log_error "Архив содержит абсолютный путь: '$_bad_entry' — восстановление отменено."
            return 1
        fi
        # Parent directory traversal
        if [[ "$_bad_entry" == *..* ]]; then
            log_error "Архив содержит path traversal (..): '$_bad_entry' — восстановление отменено."
            return 1
        fi
    done <<< "$_tar_list"
    log_debug "Pre-extraction проверка пройдена: $(echo "$_tar_list" | wc -l) файлов в архиве."

    if ! tar -xzf "$bf" --no-same-owner --no-same-permissions -C "$td"; then
        log_error "Ошибка tar $bf"
        return 1
    fi

    # Post-extraction проверка: нет symlinks в распакованном дереве
    local _symlinks
    _symlinks=$(find "$td" -type l 2>/dev/null)
    if [[ -n "$_symlinks" ]]; then
        log_error "Архив содержит symlinks (возможная symlink attack):"
        while IFS= read -r _sl; do log_error "  $_sl → $(readlink "$_sl")"; done <<< "$_symlinks"
        return 1
    fi

    log "Остановка сервиса..."
    systemctl stop awg-quick@awg0 || log_warn "Сервис не остановлен."

    # С этого момента destructive ops. Все error paths → trap _restore_cleanup → rollback.
    _destructive_ops_started=1
    if [[ -d "$td/server" ]]; then
        log "Восстановление конфига сервера..."
        local server_conf_dir
        server_conf_dir=$(dirname "$SERVER_CONF_FILE")
        mkdir -p "$server_conf_dir"
        if ! cp -a "$td/server/"* "$server_conf_dir/"; then
            log_error "Ошибка копирования server — восстановление прервано (запуск отката)."
            return 1
        fi
        chmod 600 "$server_conf_dir"/*.conf 2>/dev/null
        chmod 700 "$server_conf_dir"
        log_debug "Конфиг сервера восстановлен в $server_conf_dir"
    fi

    if [[ -d "$td/clients" ]]; then
        log "Восстановление файлов клиентов..."
        if ! cp -a "$td/clients/"* "$AWG_DIR/"; then
            log_error "Ошибка копирования clients — восстановление прервано (запуск отката)."
            return 1
        fi
        chmod 600 "$AWG_DIR"/*.conf 2>/dev/null
        chmod 600 "$AWG_DIR"/*.png 2>/dev/null
        chmod 600 "$AWG_DIR"/*.vpnuri 2>/dev/null
        chmod 600 "$CONFIG_FILE" 2>/dev/null
        log_debug "Файлы клиентов восстановлены в $AWG_DIR"
    fi

    if [[ -d "$td/keys" ]]; then
        log "Восстановление ключей..."
        mkdir -p "$KEYS_DIR"
        if ! cp -a "$td/keys/"* "$KEYS_DIR/"; then
            log_error "Ошибка копирования keys — восстановление прервано (запуск отката)."
            return 1
        fi
        chmod 600 "$KEYS_DIR"/* 2>/dev/null
        log_debug "Ключи восстановлены в $KEYS_DIR"
    fi

    # Серверные ключи: cp -a сохраняет mode из архива, поэтому форсируем 600
    # независимо от того с какими правами они лежали в backup-е (audit fix).
    if [[ -f "$td/server_private.key" ]]; then
        if ! cp -a "$td/server_private.key" "$AWG_DIR/"; then
            log_error "Ошибка копирования server_private.key — восстановление прервано (запуск отката)."
            return 1
        fi
        chmod 600 "$AWG_DIR/server_private.key" 2>/dev/null || true
    fi
    if [[ -f "$td/server_public.key" ]]; then
        if ! cp -a "$td/server_public.key" "$AWG_DIR/"; then
            log_error "Ошибка копирования server_public.key — восстановление прервано (запуск отката)."
            return 1
        fi
        chmod 600 "$AWG_DIR/server_public.key" 2>/dev/null || true
    fi

    if [[ -d "$td/expiry" ]]; then
        log "Восстановление данных expiry..."
        mkdir -p "${EXPIRY_DIR:-$AWG_DIR/expiry}"
        cp -a "$td/expiry/"* "${EXPIRY_DIR:-$AWG_DIR/expiry}/" 2>/dev/null || true
        chmod 600 "${EXPIRY_DIR:-$AWG_DIR/expiry}"/* 2>/dev/null
    fi
    if [[ -f "$td/awg-expiry" ]]; then
        cp -a "$td/awg-expiry" /etc/cron.d/awg-expiry
        chmod 644 /etc/cron.d/awg-expiry
    fi

    # Pre-flight: валидация восстановленного конфига ДО старта сервиса.
    # Если конфиг invalid — сервис гарантированно упадёт, лучше откатиться
    # сейчас и объяснить причину, чем стартовать сломанный awg-quick@awg0.
    if ! validate_awg_config >/dev/null 2>&1; then
        log_error "Восстановленный серверный конфиг не прошёл валидацию — запуск отката."
        return 1
    fi

    log "Запуск сервиса..."
    if ! systemctl start awg-quick@awg0; then
        log_error "Ошибка запуска сервиса — запуск отката."
        local status_out
        status_out=$(systemctl status awg-quick@awg0 --no-pager 2>&1) || true
        while IFS= read -r line; do log_error "  $line"; done <<< "$status_out"
        return 1
    fi

    # Успех — rollback не нужен, trap выполнит только cleanup
    _restore_ok=1
    log "Восстановление завершено."
    return 0
}

# ==============================================================================
# Изменение параметра клиента
# ==============================================================================

modify_client() {
    local name="$1" param="$2" value="$3"

    if [[ -z "$name" || -z "$param" || -z "$value" ]]; then
        log_error "Использование: modify <имя> <параметр> <значение>"
        return 1
    fi

    # Валидация ДО взятия блокировки (ранние return не требуют fd cleanup)
    local allowed_params="DNS|Endpoint|AllowedIPs|PersistentKeepalive"
    if ! [[ "$param" =~ ^($allowed_params)$ ]]; then
        log_error "Параметр '$param' нельзя изменить через modify."
        log_error "Допустимые параметры: ${allowed_params//|/, }"
        return 1
    fi

    case "$param" in
        DNS)
            if ! [[ "$value" =~ ^[0-9a-fA-F.:,\ ]+$ ]]; then
                log_error "Невалидный DNS: '$value' (допустимы IP-адреса через запятую)"
                return 1
            fi ;;
        PersistentKeepalive)
            if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -gt 65535 ]]; then
                log_error "Невалидный PersistentKeepalive: '$value' (допустимо: 0-65535)"
                return 1
            fi ;;
        Endpoint)
            case "$value" in
                *$'\n'*|*$'\r'*|*\\*|*\"*|*\'*|"")
                    log_error "Невалидный Endpoint: '$value'"
                    return 1 ;;
            esac ;;
        AllowedIPs)
            case "$value" in
                *$'\n'*|*$'\r'*|*\\*|*\"*|*\'*|"")
                    log_error "Невалидный AllowedIPs: '$value'"
                    return 1 ;;
            esac ;;
    esac

    # Блокировка перед state-проверками (защита от TOCTOU с concurrent remove)
    local modify_lockfile="${AWG_DIR}/.awg_config.lock"
    local modify_lock_fd
    exec {modify_lock_fd}>"$modify_lockfile"
    if ! flock -x -w 10 "$modify_lock_fd"; then
        log_error "Не удалось получить блокировку конфигурации (другая операция выполняется)"
        exec {modify_lock_fd}>&-
        return 1
    fi

    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE"; then
        exec {modify_lock_fd}>&-
        die "Клиент '$name' не найден."
    fi

    local cf="$AWG_DIR/$name.conf"
    if [[ ! -f "$cf" ]]; then exec {modify_lock_fd}>&-; die "Файл $cf не найден."; fi

    if ! grep -q -E "^${param}[[:space:]]*=" "$cf"; then
        log_error "Параметр '$param' не найден в $cf."
        exec {modify_lock_fd}>&-
        return 1
    fi

    log "Изменение '$param' на '$value' для '$name'..."
    local bak
    bak="${cf}.bak-$(date +%F_%H-%M-%S)"
    # v5.11.0 A5.2: бэкап критически важен — если cp провалился, без бэкапа
    # destructive sed может повредить конфиг без возможности отката. Выходим.
    if ! cp "$cf" "$bak"; then
        log_error "Не удалось создать бэкап '$bak' — destructive sed отменён."
        exec {modify_lock_fd}>&-
        return 1
    fi
    log "Бэкап: $bak"

    local escaped_value
    escaped_value=$(escape_sed "$value")
    if ! sed -i "s#^${param}[[:space:]]*=[[:space:]]*.*#${param} = ${escaped_value}#" "$cf"; then
        log_error "Ошибка sed. Восстановление..."
        cp "$bak" "$cf" || log_warn "Ошибка восстановления."
        exec {modify_lock_fd}>&-
        return 1
    fi
    if ! grep -q -E "^${param} = " "$cf"; then
        log_error "Замена не выполнена для '$param'. Восстановление..."
        cp "$bak" "$cf" || log_warn "Ошибка восстановления."
        exec {modify_lock_fd}>&-
        return 1
    fi
    log_debug "sed: ${param} = ${value} в $cf"

    log "Параметр '$param' изменен."
    rm -f "$bak"

    log "Перегенерация QR-кода и vpn:// URI..."
    generate_qr "$name" || log_warn "Не удалось обновить QR-код."
    if generate_vpn_uri "$name"; then
        generate_qr_vpnuri "$name" || log_warn "Не удалось обновить QR vpn://."
    else
        log_warn "Не удалось обновить vpn:// URI."
    fi

    exec {modify_lock_fd}>&-
    return 0
}

# ==============================================================================
# Проверка состояния сервера
# ==============================================================================

check_server() {
    log "Проверка состояния сервера AmneziaWG 2.0..."
    local ok=1

    log "Статус сервиса:"
    if ! systemctl status awg-quick@awg0 --no-pager; then ok=0; fi

    log "Интерфейс awg0:"
    if ! ip addr show awg0 &>/dev/null; then
        log_error " - Интерфейс не найден!"
        ok=0
    else
        while IFS= read -r line; do log "  $line"; done < <(ip addr show awg0)
    fi

    log "Прослушивание порта:"
    # shellcheck source=/dev/null
    safe_load_config "$CONFIG_FILE" 2>/dev/null
    local port=${AWG_PORT:-0}
    if [[ "$port" -eq 0 ]]; then
        log_warn " - Не удалось определить порт."
    else
        if ! ss -lunp | grep -q ":${port} "; then
            log_error " - Порт ${port}/udp НЕ прослушивается!"
            ok=0
        else
            log " - Порт ${port}/udp прослушивается."
        fi
    fi

    log "Настройки ядра:"
    local fwd
    fwd=$(sysctl -n net.ipv4.ip_forward)
    if [[ "$fwd" != "1" ]]; then
        log_error " - IP Forwarding выключен ($fwd)!"
        ok=0
    else
        log " - IP Forwarding включен."
    fi

    log "Правила UFW:"
    if command -v ufw &>/dev/null; then
        if ! ufw status | grep -qw "${port}/udp"; then
            log_warn " - Правило UFW для ${port}/udp не найдено!"
        else
            log " - Правило UFW для ${port}/udp есть."
        fi
    else
        log_warn " - UFW не установлен."
    fi

    log "Статус AmneziaWG 2.0:"
    # Раньше awg show вызывался через process substitution без проверки exit code,
    # из-за чего check мог отрапортовать "Состояние OK" даже когда awg упал.
    # Теперь захватываем вывод и проверяем exit code (audit).
    local _awg_out
    if ! _awg_out=$(awg show awg0 2>&1); then
        log_error " - awg show awg0 завершился с ошибкой:"
        while IFS= read -r _l; do log_error "  $_l"; done <<< "$_awg_out"
        ok=0
    else
        while IFS= read -r _l; do log "  $_l"; done <<< "$_awg_out"
        if grep -q "jc:" <<< "$_awg_out"; then
            log " - AWG 2.0 параметры обфускации: активны"
        else
            log_warn " - AWG 2.0 параметры обфускации не обнаружены"
        fi
    fi

    if [[ "$ok" -eq 1 ]]; then
        log "Проверка завершена: Состояние OK."
        return 0
    else
        log_error "Проверка завершена: ОБНАРУЖЕНЫ ПРОБЛЕМЫ!"
        return 1
    fi
}

validate_dns_list() {
    local value="$1"
    [[ -n "$value" ]] || return 1
    [[ "$value" =~ ^[0-9a-fA-F.:,\ ]+$ ]] || return 1
}

shell_quote() {
    local s="$1"
    s="${s//\'/\'\\\'\'}"
    printf "'%s'" "$s"
}

validate_server_name() {
    local name="$1"
    [[ -n "${name//[[:space:]]/}" ]] || return 1
    [[ "$name" != *$'\n'* && "$name" != *$'\r'* ]] || return 1
    [[ ${#name} -le 128 ]] || return 1
}

set_config_value() {
    local key="$1" value="$2"
    [[ -f "$CONFIG_FILE" ]] || { log_error "Не найден $CONFIG_FILE"; return 1; }
    case "$value" in *$'\n'*|*$'\r'*) log_error "Невалидное значение для $key"; return 1 ;; esac
    local quoted
    quoted=$(shell_quote "$value")
    local tmp
    tmp=$(mktemp "${CONFIG_FILE}.tmp.XXXXXX") || return 1
    if awk -v key="$key" -v quoted="$quoted" '
        BEGIN { done=0 }
        $0 ~ "^(export[[:space:]]+)?" key "=" {
            print "export " key "=" quoted
            done=1
            next
        }
        { print }
        END {
            if (!done) print "export " key "=" quoted
        }
    ' "$CONFIG_FILE" > "$tmp"; then
        mv -f "$tmp" "$CONFIG_FILE" || { rm -f "$tmp"; return 1; }
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
        return 0
    fi
    rm -f "$tmp"
    return 1
}

update_server_conf_name() {
    local name="$1"
    validate_server_name "$name" || { log_error "Некорректное имя сервера."; return 1; }
    [[ -f "$SERVER_CONF_FILE" ]] || { log_error "Не найден $SERVER_CONF_FILE"; return 1; }
    local tmp
    tmp=$(mktemp "${SERVER_CONF_FILE}.tmp.XXXXXX") || return 1
    if awk -v name="$name" '
        /^\[Interface\]/ {
            print
            print "# Name = " name
            in_iface=1
            done=1
            next
        }
        in_iface && /^# Name = / { next }
        in_iface && /^\[/ { in_iface=0; print; next }
        { print }
        END { if (!done) exit 2 }
    ' "$SERVER_CONF_FILE" > "$tmp"; then
        mv -f "$tmp" "$SERVER_CONF_FILE" || { rm -f "$tmp"; return 1; }
        chmod 600 "$SERVER_CONF_FILE" 2>/dev/null || true
        return 0
    fi
    rm -f "$tmp"
    return 1
}

regenerate_all_clients_for_name() {
    local name rc=0
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        regenerate_client "$name" || { log_warn "Ошибка перегенерации '$name'"; rc=1; }
    done < <(grep '^#_Name = ' "$SERVER_CONF_FILE" 2>/dev/null | sed 's/^#_Name = //')
    return "$rc"
}

set_server_name() {
    local name="$1"
    validate_server_name "$name" || { log_error "Использование: set-name \"Новое Имя\""; return 1; }
    set_config_value "AWG_SERVER_NAME" "$name" || return 1
    export AWG_SERVER_NAME="$name"
    update_server_conf_name "$name" || return 1
    regenerate_all_clients_for_name || return 1
    log "Имя сервера установлено: $name. Клиентские конфиги и vpn:// перегенерированы."
}

web_token_py() {
    local action="$1" name="${2:-}"
    local token_file="$AWG_DIR/web/tokens.json"
    mkdir -p "$AWG_DIR/web" || return 1
    python3 - "$token_file" "$action" "$name" <<'PY'
import hashlib
import json
import os
import re
import secrets
import sys
from pathlib import Path

path = Path(sys.argv[1])
action = sys.argv[2]
name = sys.argv[3]
name_re = re.compile(r"^[A-Za-z0-9_-]{1,63}$")

def digest(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()

def load():
    if path.exists():
        try:
            data = json.loads(path.read_text())
        except Exception:
            data = {}
    else:
        data = {}
    if not isinstance(data, dict):
        data = {}
    users = data.get("users")
    if not isinstance(users, dict):
        users = {}
    legacy_normal = data.get("normal")
    if isinstance(legacy_normal, dict):
        for value in legacy_normal.values():
            if isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value):
                users.setdefault(value, [])
    clean_users = {}
    for key, value in users.items():
        if not isinstance(key, str) or not re.fullmatch(r"[0-9a-f]{64}", key):
            continue
        if isinstance(value, list):
            record = {"name": "", "clients": value}
        elif isinstance(value, dict):
            record = {"name": value.get("name", ""), "clients": value.get("clients", [])}
        else:
            continue
        if not isinstance(record["name"], str) or "\n" in record["name"] or "\r" in record["name"] or len(record["name"]) > 128:
            record["name"] = ""
        if not isinstance(record["clients"], list):
            record["clients"] = []
        clean_users[key] = {
            "name": record["name"],
            "clients": [item for item in record["clients"] if isinstance(item, str) and re.fullmatch(r"^[A-Za-z0-9_-]{1,63}$", item)],
        }
    super_hash = data.get("super_token_hash") or data.get("super")
    if not isinstance(super_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", super_hash):
        token = secrets.token_urlsafe(32)
        super_hash = digest(token)
        data["_new_super_token"] = token
    return {"super_token_hash": super_hash, "users": clean_users}

def save(data):
    tmp = path.with_name(path.name + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    os.chmod(path, 0o600)

data = load()
if action == "list":
    save(data)
    print("super: present")
    for key, record in sorted(data["users"].items()):
        suffix = ",".join(record["clients"]) if record["clients"] else "-"
        print(f"user: {key[:12]}... name={record['name'] or '-'} clients={suffix}")
elif action == "add":
    if not name_re.fullmatch(name):
        raise SystemExit("invalid token name")
    token = secrets.token_urlsafe(32)
    data["users"][digest(token)] = {"name": name, "clients": []}
    save(data)
    print("Token created. By default, it has access to 0 clients. Log in to the Web Panel with the Super Token to assign clients to this user.")
    print(token)
elif action == "revoke":
    matches = [key for key in data["users"] if key == name or key.startswith(name)]
    if len(matches) != 1:
        raise SystemExit("token not found")
    del data["users"][matches[0]]
    save(data)
    print(f"revoked: {matches[0]}")
elif action == "rotate":
    matches = [key for key in data["users"] if key == name or key.startswith(name)]
    if len(matches) != 1:
        raise SystemExit("token not found")
    record = data["users"].pop(matches[0])
    token = secrets.token_urlsafe(32)
    data["users"][digest(token)] = record
    save(data)
    print("Token rotated. Client access list preserved.")
    print(token)
elif action == "reset-super":
    token = secrets.token_urlsafe(32)
    data["super_token_hash"] = digest(token)
    data["users"] = {}
    save(data)
    print(token)
else:
    raise SystemExit("unknown action")
PY
}

toggle_client() {
    local name="$1"
    [[ -z "$name" ]] && { log_error "Использование: toggle <имя>"; return 1; }
    validate_client_name "$name" || return 1

    if [[ "${AWG_SKIP_APPLY:-0}" != "1" ]]; then
        ensure_amneziawg_kernel_module \
            || die "Модуль ядра amneziawg недоступен. Запустите 'manage repair-module' и повторите."
    fi

    local toggle_lockfile="${AWG_DIR}/.awg_config.lock"
    local toggle_lock_fd
    exec {toggle_lock_fd}>"$toggle_lockfile"
    if ! flock -x -w 10 "$toggle_lock_fd"; then
        log_error "Не удалось получить блокировку конфигурации (другая операция выполняется)"
        exec {toggle_lock_fd}>&-
        return 1
    fi

    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE"; then
        exec {toggle_lock_fd}>&-
        log_error "Клиент '$name' не найден."
        return 1
    fi

    local tmp state state_file
    tmp=$(mktemp) || { exec {toggle_lock_fd}>&-; log_error "Ошибка mktemp"; return 1; }
    state_file=$(mktemp) || { rm -f "$tmp"; exec {toggle_lock_fd}>&-; log_error "Ошибка mktemp"; return 1; }
    if ! awk -v target="$name" -v state_file="$state_file" '
        function is_header(line) { return line == "[Peer]" || line == "# [Peer]" }
        function is_cfg(line) { return line ~ /^(PublicKey|PresharedKey|AllowedIPs|Endpoint|PersistentKeepalive)[[:space:]]*=/ }
        function is_commented_cfg(line) { return line ~ /^# (PublicKey|PresharedKey|AllowedIPs|Endpoint|PersistentKeepalive)[[:space:]]*=/ }
        function flush_block(    i, disabled, has_target, out) {
            if (block_len == 0) return
            has_target = 0
            disabled = 0
            for (i = 1; i <= block_len; i++) {
                if (block[i] == "#_Name = " target) has_target = 1
                if (block[i] == "# [Peer]" || block[i] ~ /^# PublicKey[[:space:]]*=/) disabled = 1
            }
            if (!has_target) {
                for (i = 1; i <= block_len; i++) print block[i]
            } else {
                found = 1
                state = disabled ? "enabled" : "disabled"
                for (i = 1; i <= block_len; i++) {
                    out = block[i]
                    if (disabled) {
                        if (out == "# [Peer]") out = "[Peer]"
                        else if (is_commented_cfg(out)) out = substr(out, 3)
                    } else {
                        if (out == "[Peer]") out = "# [Peer]"
                        else if (is_cfg(out)) out = "# " out
                    }
                    print out
                }
            }
            block_len = 0
        }
        {
            if (is_header($0)) {
                flush_block()
                block[++block_len] = $0
                next
            }
            if (block_len > 0) {
                block[++block_len] = $0
                next
            }
            print
        }
        END {
            flush_block()
            if (!found) state = "missing"
            print state > state_file
        }
    ' "$SERVER_CONF_FILE" > "$tmp"; then
        rm -f "$tmp" "$state_file"
        exec {toggle_lock_fd}>&-
        log_error "Ошибка обработки $SERVER_CONF_FILE"
        return 1
    fi
    state=$(tr -d '[:space:]' < "$state_file" 2>/dev/null || true)
    rm -f "$state_file"

    if [[ "$state" == "missing" || -z "$state" ]]; then
        rm -f "$tmp"
        exec {toggle_lock_fd}>&-
        log_error "Клиент '$name' не найден."
        return 1
    fi

    if ! cp "$SERVER_CONF_FILE" "${SERVER_CONF_FILE}.bak-toggle-$(date +%F_%H-%M-%S)"; then
        rm -f "$tmp"
        exec {toggle_lock_fd}>&-
        log_error "Не удалось создать бэкап $SERVER_CONF_FILE"
        return 1
    fi
    if ! cat "$tmp" > "$SERVER_CONF_FILE"; then
        rm -f "$tmp"
        exec {toggle_lock_fd}>&-
        log_error "Не удалось обновить $SERVER_CONF_FILE"
        return 1
    fi
    rm -f "$tmp"

    [[ -n "${_CLI_APPLY_MODE:-}" ]] && export AWG_APPLY_MODE="$_CLI_APPLY_MODE"
    if [[ "${AWG_SKIP_APPLY:-0}" == "1" ]]; then
        apply_config
        log "Клиент '$name' переключён: $state. Применение отложено (AWG_SKIP_APPLY=1)."
    elif apply_config; then
        log "Клиент '$name' переключён: $state. Конфигурация применена."
    else
        exec {toggle_lock_fd}>&-
        log_error "Клиент '$name' переключён в конфиге, но apply_config упал. Проверьте: systemctl status awg-quick@awg0"
        return 1
    fi

    exec {toggle_lock_fd}>&-
    return 0
}

regenerate_all_clients_for_dns() {
    local name rc=0
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        regenerate_client "$name" || { log_warn "Ошибка перегенерации '$name'"; rc=1; }
    done < <(grep '^#_Name = ' "$SERVER_CONF_FILE" 2>/dev/null | sed 's/^#_Name = //')
    return "$rc"
}

dns_status() {
    safe_load_config "$CONFIG_FILE" 2>/dev/null || true
    local active="unknown"
    active=$(systemctl is-active AdGuardHome.service 2>/dev/null || true)
    log "DNS mode: ${AWG_DNS_MODE:-system}"
    log "Client DNS: $(awg_dns_servers)"
    log "AdGuard enabled: ${AWG_ADGUARD_ENABLED:-0}"
    log "AdGuard service: ${active:-unknown}"
    log "AdGuard UI: http://10.9.9.1:${AWG_ADGUARD_PORT:-3000}/"
    if [[ "${AWG_DNS_MODE:-system}" == "adguard" && "$active" != "active" ]]; then
        log_warn "AdGuard Home не активен. VPN продолжит работать; для fallback выполните: manage dns set-mode system"
    fi
}

dns_set_mode() {
    local mode="$1" custom="${2:-}"
    case "$mode" in
        adguard|system|custom) ;;
        *) log_error "Использование: dns set-mode adguard|system|custom [DNS]"; return 1 ;;
    esac
    if [[ "$mode" == "custom" ]]; then
        [[ -n "$custom" ]] || custom="${AWG_CUSTOM_DNS:-1.1.1.1}"
        validate_dns_list "$custom" || { log_error "Невалидный custom DNS: '$custom'"; return 1; }
        set_config_value "AWG_CUSTOM_DNS" "$custom" || return 1
    fi
    set_config_value "AWG_DNS_MODE" "$mode" || return 1
    if [[ "$mode" == "adguard" ]]; then
        set_config_value "AWG_ADGUARD_ENABLED" "1" || return 1
        systemctl restart AdGuardHome.service 2>/dev/null || log_warn "AdGuardHome.service не стартовал; VPN не менялся."
    fi
    safe_load_config "$CONFIG_FILE" 2>/dev/null || true
    regenerate_all_clients_for_dns || return 1
    log "DNS mode установлен: $mode. Клиентские конфиги перегенерированы."
}

# ==============================================================================
# Список клиентов
# ==============================================================================

list_clients() {
    log "Получение списка клиентов..."
    local clients
    clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //' | sort) || clients=""
    if [[ -z "$clients" ]]; then
        log "Клиенты не найдены."
        return 0
    fi

    local verbose=$VERBOSE_LIST
    local act=0 tot=0

    # Однопроходный парсинг серверного конфига: name → pubkey
    local -A _name_to_pk
    local _cn=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "#_Name = "* ]]; then
            _cn="${line#\#_Name = }"
            _cn="${_cn## }"; _cn="${_cn%% }"
        elif [[ -n "$_cn" && "$line" == "PublicKey = "* ]]; then
            local _pk="${line#PublicKey = }"
            _pk="${_pk## }"; _pk="${_pk%% }"
            [[ -n "$_pk" ]] && _name_to_pk["$_cn"]="$_pk"
            _cn=""
        fi
    done < "$SERVER_CONF_FILE"

    # Однопроходный парсинг awg show dump: pubkey → handshake timestamp
    local -A _pk_to_hs
    local awg_dump
    awg_dump=$(awg show awg0 dump 2>/dev/null) || awg_dump=""
    if [[ -n "$awg_dump" ]]; then
        # shellcheck disable=SC2034
        while IFS=$'\t' read -r _dpk _dpsk _dep _daips _dhs _drx _dtx _dka; do
            _pk_to_hs["$_dpk"]="$_dhs"
        done < <(echo "$awg_dump" | tail -n +2)
    fi

    if [[ $verbose -eq 1 ]]; then
        printf "%-18s | %-5s | %-5s | %-15s | %-30s | %-17s | %-15s | %s\n" "Имя клиента" "Conf" "QR" "IPv4" "IPv6" "P2P" "Ключ (нач.)" "Статус"
        printf -- "-%.0s" {1..130}
        echo
    else
        printf "%-18s | %-15s | %-17s | %s\n" "Имя клиента" "IPv4" "P2P" "Статус"
        printf -- "-%.0s" {1..75}
        echo
    fi

    local now
    now=$(date +%s)

    while IFS= read -r name; do
        name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
        if [[ -z "$name" ]]; then continue; fi
        ((tot++))

        local cf="?" png="?" pk="-" ip="-" ipv6="-" p2p="-" st="Нет данных"
        local color_start="" color_end=""
        if [[ "$NO_COLOR" -eq 0 ]]; then
            color_end="\033[0m"
            color_start="\033[0;37m"
        fi

        [[ -f "$AWG_DIR/${name}.conf" ]] && cf="+"
        [[ -f "$AWG_DIR/${name}.png" ]] && png="+"
        ip=$(get_client_ipv4_from_server "$name" 2>/dev/null || echo "-")
        ipv6=$(get_client_ipv6_from_server "$name" 2>/dev/null || echo "-")
        p2p=$(get_peer_p2p_ports "$name" 2>/dev/null)
        [[ -n "$p2p" ]] || p2p="-"

        if [[ "$cf" == "+" ]]; then
            local current_pk="${_name_to_pk[$name]:-}"

            if [[ -n "$current_pk" ]]; then
                pk="${current_pk:0:10}..."
                local handshake="${_pk_to_hs[$current_pk]:-0}"
                if [[ "$handshake" =~ ^[0-9]+$ && "$handshake" -gt 0 ]]; then
                    local diff=$((now - handshake))
                    if [[ $diff -ge 0 && $diff -lt 180 ]]; then
                        st="Активен"
                        [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;32m"
                        ((act++))
                    elif [[ $diff -ge 0 && $diff -lt 86400 ]]; then
                        st="Недавно"
                        [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;33m"
                        ((act++))
                    else
                        st="Нет handshake"
                        [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;37m"
                    fi
                else
                    st="Нет handshake"
                    [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;37m"
                fi
            else
                pk="?"
                st="Ошибка ключа"
                [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;31m"
            fi
        fi

        # Expiry info
        local exp_str=""
        local exp_ts
        exp_ts=$(get_client_expiry "$name" 2>/dev/null)
        if [[ -n "$exp_ts" ]]; then
            exp_str=" [$(format_remaining "$exp_ts")]"
        fi

        if [[ $verbose -eq 1 ]]; then
            printf "%-18s | %-5s | %-5s | %-15s | %-30s | %-17s | %-15s | ${color_start}%s${color_end}%s\n" "$name" "$cf" "$png" "$ip" "$ipv6" "$p2p" "$pk" "$st" "$exp_str"
        else
            printf "%-18s | %-15s | %-17s | ${color_start}%s${color_end}%s\n" "$name" "$ip" "$p2p" "$st" "$exp_str"
        fi
    done <<< "$clients"
    echo ""
    log "Всего клиентов: $tot, Активных/Недавно: $act"
}

# ==============================================================================
# Статистика трафика
# ==============================================================================

# Экранирование строки для безопасного включения в JSON
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Форматирование размера в человекочитаемый формат
format_bytes() {
    local bytes="${1:-0}"
    if [[ ! "$bytes" =~ ^[0-9]+$ ]]; then printf "0 B"; return; fi
    if [[ "$bytes" -ge 1073741824 ]]; then
        awk "BEGIN{printf \"%.2f GiB\", $bytes/1073741824}"
    elif [[ "$bytes" -ge 1048576 ]]; then
        awk "BEGIN{printf \"%.2f MiB\", $bytes/1048576}"
    elif [[ "$bytes" -ge 1024 ]]; then
        awk "BEGIN{printf \"%.1f KiB\", $bytes/1024}"
    else
        printf "%d B" "$bytes"
    fi
}

stats_clients() {
    local clients
    clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //' | sort) || clients=""
    if [[ -z "$clients" ]]; then
        if [[ "$JSON_OUTPUT" -eq 1 ]]; then
            echo "[]"
        else
            log "Клиенты не найдены."
        fi
        return 0
    fi

    # Получаем данные awg show awg0
    local awg_dump
    awg_dump=$(awg show awg0 dump 2>/dev/null) || {
        log_error "Ошибка получения данных awg show."
        return 1
    }

    # Маппинг: публичный ключ → имя клиента (single-pass)
    local -A pk_to_name
    local _current_name=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "#_Name = "* ]]; then
            _current_name="${line#\#_Name = }"
            _current_name="${_current_name## }"; _current_name="${_current_name%% }"
        elif [[ -n "$_current_name" && "$line" == "PublicKey = "* ]]; then
            local _pk="${line#PublicKey = }"
            _pk="${_pk## }"; _pk="${_pk%% }"
            [[ -n "$_pk" ]] && pk_to_name["$_pk"]="$_current_name"
            _current_name=""
        fi
    done < "$SERVER_CONF_FILE"

    local json_entries=()
    local table_rows=()
    local total_rx=0 total_tx=0

    # awg show dump: каждая строка пира = pubkey psk endpoint allowed-ips latest-handshake rx tx keepalive
    # shellcheck disable=SC2034
    while IFS=$'\t' read -r pk psk ep aips handshake rx tx keepalive; do
        local cname="${pk_to_name[$pk]:-unknown}"
        if [[ "$cname" == "unknown" ]]; then continue; fi

        local ip="-" ipv6="-" p2p="-"
        ip=$(get_client_ipv4_from_server "$cname" 2>/dev/null || echo "-")
        ipv6=$(get_client_ipv6_from_server "$cname" 2>/dev/null || echo "-")
        p2p=$(get_peer_p2p_ports "$cname" 2>/dev/null)
        [[ -n "$p2p" ]] || p2p="-"

        local hs_str="никогда"
        local status="Неактивен"
        if [[ "$handshake" =~ ^[0-9]+$ && "$handshake" -gt 0 ]]; then
            local now
            now=$(date +%s)
            local diff=$((now - handshake))
            if [[ $diff -ge 0 && $diff -lt 180 ]]; then
                status="Активен"
            elif [[ $diff -ge 0 && $diff -lt 86400 ]]; then
                status="Недавно"
            fi
            hs_str=$(date -d "@$handshake" '+%F %T' 2>/dev/null || echo "$handshake")
        fi

        total_rx=$((total_rx + rx))
        total_tx=$((total_tx + tx))

        if [[ "$JSON_OUTPUT" -eq 1 ]]; then
            json_entries+=("{\"name\":\"$(json_escape "$cname")\",\"ip\":\"$(json_escape "$ip")\",\"ipv6\":\"$(json_escape "$ipv6")\",\"endpoint\":\"$(json_escape "$ep")\",\"p2p_ports\":\"$(json_escape "$p2p")\",\"rx\":$rx,\"tx\":$tx,\"last_handshake\":$handshake,\"status\":\"$(json_escape "$status")\"}")
        else
            local rx_h tx_h
            rx_h=$(format_bytes "$rx")
            tx_h=$(format_bytes "$tx")
            table_rows+=("$(printf "%-15s | %-15s | %-28s | %-15s | %-12s | %-12s | %-19s | %s" "$cname" "$ip" "$ipv6" "$p2p" "$rx_h" "$tx_h" "$hs_str" "$status")")
        fi
    done < <(echo "$awg_dump" | tail -n +2)

    if [[ "$JSON_OUTPUT" -eq 1 ]]; then
        ( IFS=","; echo "[${json_entries[*]}]" )
    else
        log "Статистика трафика клиентов:"
        echo ""
        printf "%-15s | %-15s | %-28s | %-15s | %-12s | %-12s | %-19s | %s\n" "Имя" "IPv4" "IPv6" "P2P" "Получено" "Отправлено" "Последний handshake" "Статус"
        printf -- "-%.0s" {1..140}
        echo
        for row in "${table_rows[@]}"; do
            echo "$row"
        done
        echo ""
        log "Итого: Получено $(format_bytes "$total_rx"), Отправлено $(format_bytes "$total_tx")"
    fi
}

# ==============================================================================

voice_check() {
    echo "== Public IP =="
    if command -v curl >/dev/null 2>&1; then
        curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null || echo "warning: не удалось определить public IPv4"
        echo
    else
        echo "warning: curl не установлен"
    fi
    echo "== Default route =="
    if command -v ip >/dev/null 2>&1; then ip route get 1.1.1.1 2>&1 || true; else echo "warning: ip не установлен"; fi
    echo "== AWG interfaces =="
    if command -v ip >/dev/null 2>&1; then ip -br addr 2>/dev/null | grep -E 'awg|wg|tun' || echo "warning: AWG/WG/TUN interfaces not found"; else echo "warning: ip не установлен"; fi
    echo "== UDP conntrack sysctl =="
    if command -v sysctl >/dev/null 2>&1; then
        sysctl net.netfilter.nf_conntrack_udp_timeout 2>&1 || true
        sysctl net.netfilter.nf_conntrack_udp_timeout_stream 2>&1 || true
        sysctl net.netfilter.nf_conntrack_max 2>&1 || true
    else
        echo "warning: sysctl не установлен"
    fi
    if [[ -r /proc/sys/net/netfilter/nf_conntrack_count ]]; then
        echo "nf_conntrack_count = $(cat /proc/sys/net/netfilter/nf_conntrack_count)"
    else
        echo "warning: nf_conntrack_count недоступен"
    fi
    echo "== NAT rules =="
    if command -v nft >/dev/null 2>&1; then nft list ruleset 2>/dev/null | grep -Ei 'masquerade|snat|dnat|awg|10\.9\.9' || echo "warning: matching NAT rules not found"; else echo "warning: nft не установлен"; fi
    echo "== Recent UDP conntrack for AWG subnet =="
    if command -v conntrack >/dev/null 2>&1; then conntrack -L -p udp 2>/dev/null | grep -E '10\.9\.9\.' | tail -50 || echo "warning: recent AWG UDP conntrack entries not found"; else echo "warning: conntrack не установлен"; fi
    cat <<'EOF'
Run on client:
  stunclient stun.l.google.com 19302
  stunclient stun.cloudflare.com 3478
  stunclient stunserver2025.stunprotocol.org 3478

Expected:
  Mapped address = VPS public IP
EOF
}

# Справка
# ==============================================================================

usage() {
    exec >&2
    echo ""
    echo "Скрипт управления AmneziaWG 2.0 (v${SCRIPT_VERSION})"
    echo "=============================================="
    echo "Использование: $0 [ОПЦИИ] <КОМАНДА> [АРГУМЕНТЫ]"
    echo ""
    echo "Опции:"
    echo "  -h, --help            Показать эту справку"
    echo "  -v, --verbose         Расширенный вывод (для команды list)"
    echo "  --no-color            Отключить цветной вывод"
    echo "  --json                JSON-вывод (для команды stats)"
    echo "  --expires=ВРЕМЯ       Срок действия при add (1h, 12h, 1d, 7d, 30d, 4w)"
    echo "  --conf-dir=ПУТЬ       Указать директорию AWG (умолч: $AWG_DIR)"
    echo "  --server-conf=ПУТЬ    Указать файл конфига сервера"
    echo "  --apply-mode=РЕЖИМ    syncconf (умолч.) или restart (обход kernel panic)"
    echo "  --psk                 (только для add) сгенерировать PresharedKey для клиента"
    echo "  --yes                 Не спрашивать подтверждение (эквивалент ENV AWG_YES=1)"
    echo ""
    echo "Команды:"
    echo "  add <имя> [имя2 ...]        Добавить клиента(ов). --expires применяется ко всем"
    echo "  remove <имя> [имя2 ...]     Удалить клиента(ов)"
    echo "  toggle <имя>          Включить/выключить клиента без удаления"
    echo "  list [-v]             Показать список клиентов"
    echo "  stats [--json]        Статистика трафика по клиентам"
    echo "  voice-check           Диагностика UDP/STUN/NAT для звонков"
    echo "  p2p list              Показать P2P порты всех клиентов"
    echo "  p2p show <имя>        Показать P2P информацию клиента"
    echo "  p2p add <имя> [порт]  Добавить P2P порт (авто, если порт не указан)"
    echo "  p2p remove <имя> <порт> Удалить P2P порт клиента"
    echo "  ipv6 status           Показать режим IPv6"
    echo "  ipv6 upgrade          Выдать IPv6/P2P metadata существующим клиентам"
    echo "  dns status            Показать режим DNS и статус AdGuard Home"
    echo "  dns restart           Синхронизировать клиентов и перезапустить AdGuard Home"
    echo "  dns sync-clients      Синхронизировать клиентов в AdGuard Home"
    echo "  dns logs              Показать последние логи AdGuard Home"
    echo "  dns set-mode <режим>  Сменить DNS: adguard, system или custom [DNS]"
    echo "  set-name \"ИМЯ\"       Сменить имя сервера и перегенерировать клиентов"
    echo "  web token list        Показать токены веб-панели"
    echo "  web token add <name>  Создать обычный токен и вывести его значение"
    echo "  web token revoke <hash> Удалить обычный токен"
    echo "  web token rotate <hash> Заменить обычный токен, сохранив доступы"
    echo "  web token reset-super Перегенерировать super token"
    echo "  regen [имя]           Перегенерировать файлы клиента(ов)"
    echo "  modify <имя> <пар> <зн> Изменить параметр клиента"
    echo "  backup                Создать бэкап"
    echo "  restore [файл]        Восстановить из бэкапа"
    echo "  check | status        Проверить состояние сервера"
    echo "  show                  Показать статус \`awg show\`"
    echo "  restart               Перезапустить сервис AmneziaWG"
    echo "  repair-module         Восстановить модуль ядра после kernel upgrade"
    echo "                        (dkms autoinstall + modprobe + запуск awg-quick)"
    echo "  help                  Показать эту справку"
    echo ""
    exit 1
}

# ==============================================================================
# Основная логика
# ==============================================================================

if [[ "$COMMAND" == "help" || -z "$COMMAND" ]]; then
    usage
fi

check_dependencies || exit 1
cd "$AWG_DIR" || die "Ошибка перехода в $AWG_DIR"

log "Запуск команды '$COMMAND'..."
_cmd_rc=0

case $COMMAND in
    add)
        [[ ${#ARGS[@]} -eq 0 ]] && die "Не указано имя клиента."

        # Гарантируем, что модуль ядра amneziawg загружен и awg-quick@awg0 активен.
        # Без этого apply_config (awg syncconf) упадёт. См. также 'manage repair-module'.
        # AWG_SKIP_APPLY=1 (offline/batch edit без apply): пропускаем проверку модуля —
        # apply_config сам сделает no-op, и команда должна работать на dev-машине.
        if [[ "${AWG_SKIP_APPLY:-0}" != "1" ]]; then
            ensure_amneziawg_kernel_module \
                || die "Модуль ядра amneziawg недоступен. Запустите 'manage repair-module' и повторите."
        fi

        # --psk: включить опциональный PresharedKey для каждого нового клиента.
        # Export CLIENT_PSK="auto" → generate_client сам сгенерирует 32-байт
        # PSK через `awg genpsk` для каждого client'а в batch (разный PSK
        # на каждого).
        if [[ "${CLI_ADD_PSK:-0}" == "1" ]]; then
            export CLIENT_PSK="auto"
            log "PresharedKey будет сгенерирован для каждого нового клиента (--psk)."
        fi

        _added=0
        for _cname in "${ARGS[@]}"; do
            validate_client_name "$_cname" || { _cmd_rc=1; continue; }

            if grep -qxF "#_Name = ${_cname}" "$SERVER_CONF_FILE"; then
                log_warn "Клиент '$_cname' уже существует, пропуск."
                continue
            fi

            # В batch-режиме каждому клиенту — свой PSK: сбрасываем на "auto"
            # чтобы generate_client сгенерировал новый.
            if [[ "${CLI_ADD_PSK:-0}" == "1" ]]; then
                export CLIENT_PSK="auto"
            fi

            log "Добавление '$_cname'..."
            if generate_client "$_cname"; then
                log "Клиент '$_cname' добавлен."
                log "Файлы: $AWG_DIR/${_cname}.conf, $AWG_DIR/${_cname}.png"
                if [[ -f "$AWG_DIR/${_cname}.vpnuri" ]]; then
                    log "vpn:// URI: $AWG_DIR/${_cname}.vpnuri"
                fi
                if [[ -n "$EXPIRES_DURATION" ]]; then
                    if set_client_expiry "$_cname" "$EXPIRES_DURATION"; then
                        install_expiry_cron
                    fi
                fi
                ((_added++))
            else
                log_error "Ошибка добавления клиента '$_cname'."
                _cmd_rc=1
            fi
        done

        if [[ $_added -gt 0 ]]; then
            sync_clients_hosts
            [[ -n "${_CLI_APPLY_MODE:-}" ]] && export AWG_APPLY_MODE="$_CLI_APPLY_MODE"
            if [[ "${AWG_SKIP_APPLY:-0}" == "1" ]]; then
                # apply_config сам залогирует и вернёт 0
                apply_config
                log "Добавлено клиентов: $_added. Применение отложено (AWG_SKIP_APPLY=1)."
            elif apply_config; then
                log "Добавлено клиентов: $_added. Конфигурация применена."
            else
                log_error "Добавлено клиентов: $_added, но apply_config упал. Конфиг записан, но НЕ применён к live интерфейсу. Проверьте: systemctl status awg-quick@awg0"
                _cmd_rc=1
            fi
        fi
        # Hygiene: CLIENT_PSK не должен протекать в будущие операции
        unset CLIENT_PSK
        ;;

    remove)
        [[ ${#ARGS[@]} -eq 0 ]] && die "Не указано имя клиента."

        # Валидация всех имён перед удалением
        _valid_names=()
        for _rname in "${ARGS[@]}"; do
            validate_client_name "$_rname" || { _cmd_rc=1; continue; }
            if ! grep -qxF "#_Name = ${_rname}" "$SERVER_CONF_FILE"; then
                log_warn "Клиент '$_rname' не найден, пропуск."
                continue
            fi
            _valid_names+=("$_rname")
        done

        if [[ ${#_valid_names[@]} -eq 0 ]]; then
            log_error "Нет клиентов для удаления."
            _cmd_rc=1
        else
            # Подтверждение
            if [[ ${#_valid_names[@]} -eq 1 ]]; then
                if ! confirm_action "удалить" "клиента '${_valid_names[0]}'"; then exit 1; fi
            else
                if ! confirm_action "удалить" "${#_valid_names[@]} клиентов"; then exit 1; fi
            fi

            # Гарантируем загруженный модуль до любых мутаций (apply_config / awg syncconf).
            # AWG_SKIP_APPLY=1 (offline/batch edit без apply): пропускаем проверку модуля —
            # apply_config сам сделает no-op, и команда должна работать на dev-машине.
            if [[ "${AWG_SKIP_APPLY:-0}" != "1" ]]; then
                ensure_amneziawg_kernel_module \
                    || die "Модуль ядра amneziawg недоступен. Запустите 'manage repair-module' и повторите."
            fi

            _removed=0
            for _rname in "${_valid_names[@]}"; do
                log "Удаление '$_rname'..."
                [[ -x "$AWG_DIR/p2p_rules.sh" ]] && bash "$AWG_DIR/p2p_rules.sh" down 2>/dev/null || true
                if remove_peer_from_server "$_rname"; then
                    rm -f "$AWG_DIR/$_rname.conf" "$AWG_DIR/$_rname.png" \
                        "$AWG_DIR/$_rname.vpnuri" "$AWG_DIR/$_rname.vpnuri.png"
                    rm -f "$KEYS_DIR/${_rname}.private" "$KEYS_DIR/${_rname}.public"
                    remove_client_expiry "$_rname"
                    log "Клиент '$_rname' удалён."
                    ((_removed++))
                else
                    log_error "Ошибка удаления '$_rname'."
                    _cmd_rc=1
                fi
            done

            if [[ $_removed -gt 0 ]]; then
                sync_clients_hosts
                bash "$AWG_DIR/postup.sh" 2>/dev/null || log_warn "Не удалось применить firewall hooks live; перезапустите awg-quick@awg0."
                [[ -n "${_CLI_APPLY_MODE:-}" ]] && export AWG_APPLY_MODE="$_CLI_APPLY_MODE"
                if [[ "${AWG_SKIP_APPLY:-0}" == "1" ]]; then
                    apply_config
                    log "Удалено клиентов: $_removed. Применение отложено (AWG_SKIP_APPLY=1)."
                elif apply_config; then
                    log "Удалено клиентов: $_removed. Конфигурация применена."
                else
                    log_error "Удалено клиентов: $_removed, но apply_config упал. Peer-ы убраны из конфига, но могут оставаться на live интерфейсе. Проверьте: systemctl status awg-quick@awg0"
                    _cmd_rc=1
                fi
            fi
        fi
        ;;

    toggle)
        [[ -z "$CLIENT_NAME" ]] && die "Не указано имя клиента."
        toggle_client "$CLIENT_NAME" || _cmd_rc=1
        ;;

    list)
        list_clients || _cmd_rc=1
        ;;

    stats)
        stats_clients || _cmd_rc=1
        ;;

    voice-check|udp-check)
        voice_check || _cmd_rc=1
        ;;

    p2p)
        safe_load_config "$CONFIG_FILE" 2>/dev/null || true
        _sub="${ARGS[0]:-list}"
        case "$_sub" in
            list)
                printf "%-20s | %s\n" "Клиент" "P2P порты"
                printf -- "-%.0s" {1..55}; echo
                while IFS= read -r _name; do
                    [[ -n "$_name" ]] || continue
                    _ports=$(get_peer_p2p_ports "$_name")
                    [[ -n "$_ports" ]] || _ports="-"
                    printf "%-20s | %s\n" "$_name" "$_ports"
                done < <(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //' | sort)
                ;;
            show)
                _name="${ARGS[1]:-}"
                [[ -z "$_name" ]] && die "Не указано имя клиента."
                validate_client_name "$_name" || exit 1
                if ! grep -qxF "#_Name = ${_name}" "$SERVER_CONF_FILE"; then die "Клиент '$_name' не найден."; fi
                log "Клиент: $_name"
                log "IPv4: $(get_client_ipv4_from_server "$_name" 2>/dev/null || echo '-')"
                log "IPv6: $(get_client_ipv6_from_server "$_name" 2>/dev/null || echo '-')"
                log "P2P порты: $(get_peer_p2p_ports "$_name" 2>/dev/null || echo '-')"
                ;;
            add)
                _name="${ARGS[1]:-}"; _port="${ARGS[2]:-}"
                [[ -z "$_name" ]] && die "Не указано имя клиента."
                validate_client_name "$_name" || exit 1
                if [[ "${AWG_SKIP_APPLY:-0}" != "1" ]]; then
                    ensure_amneziawg_kernel_module || die "Модуль ядра amneziawg недоступен."
                fi
                if _new_port=$(add_p2p_port_to_peer "$_name" "$_port"); then
                    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q active; then
                        ufw allow "${_new_port}/tcp" comment "AmneziaWG P2P TCP" >/dev/null 2>&1 || log_warn "Не удалось открыть P2P TCP порт $_new_port в UFW."
                        ufw allow "${_new_port}/udp" comment "AmneziaWG P2P UDP" >/dev/null 2>&1 || log_warn "Не удалось открыть P2P UDP порт $_new_port в UFW."
                    fi
                    bash "$AWG_DIR/postup.sh" 2>/dev/null || log_warn "Не удалось применить firewall hooks live; перезапустите awg-quick@awg0."
                    log "P2P порт $_new_port добавлен клиенту '$_name'."
                else
                    _cmd_rc=1
                fi
                ;;
            remove)
                _name="${ARGS[1]:-}"; _port="${ARGS[2]:-}"
                [[ -z "$_name" || -z "$_port" ]] && die "Использование: p2p remove <имя> <порт>"
                validate_client_name "$_name" || exit 1
                [[ -x "$AWG_DIR/p2p_rules.sh" ]] && bash "$AWG_DIR/p2p_rules.sh" down 2>/dev/null || true
                if remove_p2p_port_from_peer "$_name" "$_port"; then
                    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q active; then
                        ufw delete allow "${_port}/tcp" >/dev/null 2>&1 || true
                        ufw delete allow "${_port}/udp" >/dev/null 2>&1 || true
                    fi
                    bash "$AWG_DIR/postup.sh" 2>/dev/null || log_warn "Не удалось применить firewall hooks live; перезапустите awg-quick@awg0."
                    log "P2P порт $_port удалён у клиента '$_name'."
                else
                    _cmd_rc=1
                fi
                ;;
            toggle)
                _name="${ARGS[1]:-}"
                [[ -z "$_name" ]] && die "Использование: p2p toggle <имя>"
                validate_client_name "$_name" || exit 1
                if ! grep -qxF "#_Name = ${_name}" "$SERVER_CONF_FILE"; then die "Клиент '$_name' не найден."; fi

                _lockfile="${AWG_DIR}/.awg_config.lock"
                exec {_lock_fd}>"$_lockfile"
                if ! flock -x -w 10 "$_lock_fd"; then
                    log_error "Не удалось получить блокировку конфига"
                    exec {_lock_fd}>&-
                    _cmd_rc=1
                else
                    _p2p_state=$(awk -v target="$_name" '
                        function is_header(line) { return line == "[Peer]" || line == "# [Peer]" }
                        is_header($0) { in_peer=1; found=0; next }
                        in_peer && $0 == "#_Name = " target { found=1; next }
                        in_peer && found && /^#_P2PPorts(_Disabled)?[[:space:]]*=/ {
                            print NR ":" ($0 ~ /^#_P2PPorts_Disabled[[:space:]]*=/ ? "disabled" : "enabled")
                            exit
                        }
                        in_peer && /^\[/ && !is_header($0) { in_peer=0; found=0 }
                    ' "$SERVER_CONF_FILE")

                    if [[ -z "$_p2p_state" ]]; then
                        log_error "У клиента '$_name' нет P2P портов."
                        _cmd_rc=1
                    else
                        _p2p_line="${_p2p_state%%:*}"
                        _p2p_mode="${_p2p_state#*:}"
                        if [[ "$_p2p_mode" == "enabled" ]]; then
                            sed -i "${_p2p_line}s/^#_P2PPorts[[:space:]]*=[[:space:]]*/#_P2PPorts_Disabled = /" "$SERVER_CONF_FILE" || _cmd_rc=1
                            _p2p_next="выключены"
                        else
                            sed -i "${_p2p_line}s/^#_P2PPorts_Disabled[[:space:]]*=[[:space:]]*/#_P2PPorts = /" "$SERVER_CONF_FILE" || _cmd_rc=1
                            _p2p_next="включены"
                        fi
                        [[ "$_cmd_rc" -eq 0 ]] && chmod 600 "$SERVER_CONF_FILE"
                    fi
                    exec {_lock_fd}>&-
                fi
                if [[ "$_cmd_rc" -eq 0 ]]; then
                    generate_firewall_scripts >/dev/null 2>&1 || log_warn "Не удалось обновить P2P/firewall hook-скрипты."
                    bash "$AWG_DIR/postdown.sh" 2>/dev/null || true
                    bash "$AWG_DIR/postup.sh" 2>/dev/null || log_warn "Не удалось применить firewall hooks live; перезапустите awg-quick@awg0."
                    log "P2P порты клиента '$_name' $_p2p_next."
                fi
                ;;
            *)
                die "Неизвестная p2p команда: $_sub"
                ;;
        esac
        ;;

    ipv6)
        safe_load_config "$CONFIG_FILE" 2>/dev/null || true
        _sub="${ARGS[0]:-status}"
        case "$_sub" in
            status)
                log "IPv6 enabled: ${AWG_IPV6_ENABLED:-0}"
                log "IPv6 mode: ${AWG_IPV6_MODE:-legacy}"
                log "IPv6 subnet: ${AWG_IPV6_SUBNET:-}"
                log "NDP proxy: ${AWG_IPV6_NDP_PROXY:-0}"
                ;;
            upgrade)
                if [[ "${AWG_IPV6_ENABLED:-0}" != "1" || -z "${AWG_IPV6_SUBNET:-}" ]]; then
                    die "IPv6 не включён в $CONFIG_FILE. Запустите install_amneziawg.sh --upgrade-ipv6."
                fi
                if upgrade_existing_peers_ipv6_p2p 1 1; then
                    _count=0
                    while IFS= read -r _name; do
                        [[ -n "$_name" ]] || continue
                        regenerate_client "$_name" || { log_warn "Ошибка regen '$_name'"; _cmd_rc=1; }
                        _count=$((_count + 1))
                    done < <(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //')
                    bash "$AWG_DIR/postup.sh" 2>/dev/null || log_warn "Не удалось применить firewall hooks live; перезапустите awg-quick@awg0."
                    log "IPv6/P2P upgrade завершён. Обработано клиентов: $_count."
                else
                    _cmd_rc=1
                fi
                ;;
            *)
                die "Неизвестная ipv6 команда: $_sub"
                ;;
        esac
        ;;

    dns)
        safe_load_config "$CONFIG_FILE" 2>/dev/null || true
        _sub="${ARGS[0]:-status}"
        case "$_sub" in
            status)
                dns_status
                ;;
            restart)
                sync_clients_hosts
                systemctl stop AdGuardHome.service 2>/dev/null || true
                if sync_adguard_clients && systemctl start AdGuardHome.service; then
                    log "Клиенты синхронизированы, AdGuard Home перезапущен."
                else
                    log_warn "AdGuard Home не перезапустился или клиенты не синхронизировались. VPN не менялся."
                    _cmd_rc=1
                fi
                ;;
            sync-clients)
                sync_clients_hosts
                systemctl stop AdGuardHome.service 2>/dev/null || true
                if sync_adguard_clients && systemctl start AdGuardHome.service; then
                    log "Клиенты синхронизированы в AdGuard Home."
                else
                    log_warn "Не удалось синхронизировать клиентов AdGuard Home. VPN не менялся."
                    _cmd_rc=1
                fi
                ;;
            logs)
                journalctl -u AdGuardHome.service -n 80 --no-pager || _cmd_rc=1
                ;;
            set-mode)
                dns_set_mode "${ARGS[1]:-}" "${ARGS[2]:-}" || _cmd_rc=1
                ;;
            *)
                die "Неизвестная dns команда: $_sub"
                ;;
        esac
        ;;

    set-name)
        safe_load_config "$CONFIG_FILE" 2>/dev/null || true
        [[ -z "${ARGS[0]:-}" ]] && die "Использование: set-name \"Новое Имя\""
        if set_server_name "${ARGS[*]}"; then
            sync_clients_hosts
        else
            _cmd_rc=1
        fi
        ;;

    web)
        _sub="${ARGS[0]:-}"
        if [[ "$_sub" != "token" ]]; then
            die "Использование: web token list|add <name>|revoke <hash>|rotate <hash>|reset-super"
        fi
        _token_cmd="${ARGS[1]:-list}"
        case "$_token_cmd" in
            list)
                web_token_py "list" || _cmd_rc=1
                ;;
            add)
                [[ -z "${ARGS[2]:-}" ]] && die "Использование: web token add <name>"
                web_token_py "add" "${ARGS[2]}" || _cmd_rc=1
                ;;
            revoke)
                [[ -z "${ARGS[2]:-}" ]] && die "Использование: web token revoke <hash>"
                web_token_py "revoke" "${ARGS[2]}" || _cmd_rc=1
                ;;
            rotate)
                [[ -z "${ARGS[2]:-}" ]] && die "Использование: web token rotate <hash>"
                web_token_py "rotate" "${ARGS[2]}" || _cmd_rc=1
                ;;
            reset-super)
                web_token_py "reset-super" || _cmd_rc=1
                ;;
            *)
                die "Неизвестная web token команда: $_token_cmd"
                ;;
        esac
        ;;

    regen)
        log "Перегенерация файлов конфигурации и QR..."
        if [[ ${#ARGS[@]} -eq 0 ]]; then
            # Без аргументов — все клиенты (сохраняет прежнее поведение).
            all_clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //')
            if [[ -z "$all_clients" ]]; then
                log "Клиенты не найдены."
            else
                while IFS= read -r cname; do
                    cname="${cname## }"; cname="${cname%% }"
                    [[ -z "$cname" ]] && continue
                    log "Перегенерация '$cname'..."
                    regenerate_client "$cname" || { log_warn "Ошибка перегенерации '$cname'"; _cmd_rc=1; }
                done <<< "$all_clients"
                log "Перегенерация завершена."
            fi
        else
            # С аргументами — обрабатываем каждое имя отдельно (паритет с add/remove).
            # До v5.11.5 здесь читался только $CLIENT_NAME (=ARGS[0]), остальные имена
            # молча терялись (Issue #70).
            _regen_count=0
            for _cname in "${ARGS[@]}"; do
                validate_client_name "$_cname" || { _cmd_rc=1; continue; }
                if ! grep -qxF "#_Name = ${_cname}" "$SERVER_CONF_FILE"; then
                    log_warn "Клиент '$_cname' не найден, пропуск."
                    _cmd_rc=1
                    continue
                fi
                log "Перегенерация '$_cname'..."
                if regenerate_client "$_cname"; then
                    _regen_count=$((_regen_count + 1))
                else
                    log_error "Ошибка перегенерации '$_cname'."
                    _cmd_rc=1
                fi
            done
            if [[ $_regen_count -gt 0 ]]; then
                log "Перегенерация завершена. Обработано: $_regen_count из ${#ARGS[@]}."
            fi
        fi
        ;;

    modify)
        [[ -z "$CLIENT_NAME" ]] && die "Не указано имя клиента."
        validate_client_name "$CLIENT_NAME" || exit 1
        modify_client "$CLIENT_NAME" "$PARAM" "$VALUE" || _cmd_rc=1
        ;;

    backup)
        backup_configs || _cmd_rc=1
        ;;

    restore)
        restore_backup "$CLIENT_NAME" || _cmd_rc=1 # CLIENT_NAME используется как [файл]
        ;;

    check|status)
        check_server || _cmd_rc=1
        ;;

    show)
        log "Статус AmneziaWG 2.0..."
        if ! awg show; then log_error "Ошибка awg show."; _cmd_rc=1; fi
        ;;

    restart)
        log "Перезапуск сервиса..."
        if ! confirm_action "перезапустить" "сервис"; then exit 1; fi
        # Перед systemctl restart убеждаемся, что модуль ядра загружен (mode=module-only,
        # т.к. сам systemctl ниже стартует unit явно — повторный start от ensure избыточен).
        ensure_amneziawg_kernel_module module-only \
            || die "Модуль ядра amneziawg недоступен. Запустите 'manage repair-module' и повторите."
        if ! systemctl restart awg-quick@awg0; then
            log_error "Ошибка перезапуска."
            status_out=$(systemctl status awg-quick@awg0 --no-pager 2>&1) || true
            while IFS= read -r line; do log_error "  $line"; done <<< "$status_out"
            exit 1
        else
            log "Сервис перезапущен."
        fi
        ;;

    repair-module|repair)
        # Явная пользовательская команда: после kernel upgrade модуль может
        # требовать пересборки DKMS. Здесь разрешаем apt-установку headers
        # (AWG_ALLOW_APT_IN_ENSURE=1) — пользователь явно запросил восстановление.
        log "Восстановление модуля ядра amneziawg (может занять до 5 минут — DKMS rebuild)..."
        if AWG_ALLOW_APT_IN_ENSURE=1 ensure_amneziawg_kernel_module full; then
            log "Модуль ядра amneziawg восстановлен, сервис awg-quick@awg0 активен."
        else
            log_error "Не удалось восстановить модуль ядра. См. лог выше; при необходимости выполните ручное восстановление."
            _cmd_rc=1
        fi
        ;;

    help)
        usage
        ;;

    *)
        log_error "Неизвестная команда: '$COMMAND'"
        _cmd_rc=1
        usage
        ;;
esac

log "Скрипт управления завершил работу."
exit $_cmd_rc
