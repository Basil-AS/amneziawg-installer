#!/bin/bash
# shellcheck disable=SC1003,SC2012,SC2015,SC2016,SC2004,SC2086,SC2317

# Minimum Bash version check
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ERROR: Bash >= 4.0 required (current: ${BASH_VERSION})" >&2; exit 1
fi

# ==============================================================================
# AmneziaWG 2.0 peer management script
# Author: @bivlked
# Version: 5.19.2-bas.1
# Date: 2026-05-13
# Repository: https://github.com/bivlked/amneziawg-installer
# ==============================================================================

# --- Safe mode and Constants ---
# shellcheck disable=SC2034
SCRIPT_VERSION="5.19.2-bas.1"
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
CLI_CARRIER=""
EXPIRES_DURATION=""
ROTATE_PRESET="default"
CLI_CARRIER=""

# --- Auto-cleanup of temporary files and directories ---
# _manage_temp_dirs holds mktemp -d paths for backup/restore.
# _awg_cleanup from awg_common.sh removes files (awg_mktemp), but not
# directories — so this is chained cleanup: first our directories, then
# the library one. Ensures that SIGINT during backup_configs/restore_backup
# does not leave orphan /tmp/tmp.XXXX (audit).
_manage_temp_dirs=()

manage_mktempdir() {
    local d
    d=$(mktemp -d) || return 1
    _manage_temp_dirs+=("$d")
    echo "$d"
}

_manage_cleaned=0
_manage_cleanup() {
    # Idempotent: on INT/TERM it is called from the signal handler, then again on
    # EXIT - the repeat must be a no-op.
    [[ "$_manage_cleaned" -eq 1 ]] && return 0
    _manage_cleaned=1
    local d
    for d in "${_manage_temp_dirs[@]}"; do
        [[ -d "$d" ]] && rm -rf "$d"
    done
    type _awg_cleanup &>/dev/null && _awg_cleanup
}
# On INT/TERM the cleanup used to run but the script did NOT exit - execution
# continued past the interrupted command and cleanup ran again on EXIT. A signal
# now means cleanup + explicit 130/143. restore_backup installs its OWN INT/TERM
# handler (with rollback) for its destructive phase and clears it in _restore_cleanup.
_manage_on_signal() {
    _manage_cleanup
    exit "$1"
}
trap _manage_cleanup EXIT
trap '_manage_on_signal 130' INT
trap '_manage_on_signal 143' TERM

# --- Argument handling ---
COMMAND=""
HELP_EXIT_RC=0   # C1: 0 = explicit help (exit 0); set to 1 for usage errors
ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)         COMMAND="help"; HELP_EXIT_RC=0; break ;;
        -v|--verbose)      VERBOSE_LIST=1; shift ;;
        --no-color)        NO_COLOR=1; shift ;;
        --json)            JSON_OUTPUT=1; shift ;;
        --expires=*)       EXPIRES_DURATION="${1#*=}"; shift ;;
        --conf-dir=*)      AWG_DIR="${1#*=}"; shift ;;
        --server-conf=*)   SERVER_CONF_FILE="${1#*=}"; shift ;;
        --apply-mode=*)
            _CLI_APPLY_MODE="${1#*=}"
            # Validate right at parse time: a typo (--apply-mode=restrat)
            # would silently act as syncconf - a user working around an issue
            # with restart mode would never learn the mode did not apply.
            case "$_CLI_APPLY_MODE" in
                syncconf|restart) ;;
                *) echo "Invalid --apply-mode value: '$_CLI_APPLY_MODE' (expected: syncconf or restart)" >&2; exit 1 ;;
            esac
            export AWG_APPLY_MODE="$_CLI_APPLY_MODE"
            shift ;;
        --psk)             CLI_ADD_PSK=1; shift ;;
        --reset-routes)    CLI_RESET_ROUTES=1; shift ;;
        --yes)             CLI_YES=1; shift ;;
        --preset=*)        ROTATE_PRESET="${1#*=}"; shift ;;
        --preset)          ROTATE_PRESET="${2:-}"; shift 2 ;;
        --carrier=*)       CLI_CARRIER="${1#*=}"; shift ;;
        --*)               echo "Unknown option: $1" >&2; COMMAND="help"; break ;;
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

if [[ "$COMMAND" == "client" ]]; then
    case "${ARGS[0]:-}" in
        regen|regenerate)
            COMMAND="regen"
            ARGS=("${ARGS[@]:1}")
            CLIENT_NAME="${ARGS[0]:-}"
            PARAM="${ARGS[1]:-}"
            VALUE="${ARGS[2]:-}"
            ;;
        *)
            echo "Unknown client command: ${ARGS[0]:-}" >&2
            COMMAND="help"
            ;;
    esac
fi
[[ "$COMMAND" == "regenerate" ]] && COMMAND="regen"
if [[ "$COMMAND" == "server" ]]; then
    case "${ARGS[0]:-}" in
        rotate-profile|rotate-awg|refresh-server-config)
            COMMAND="rotate-profile"
            ARGS=("${ARGS[@]:1}")
            ;;
        *)
            echo "Unknown server command: ${ARGS[0]:-}" >&2
            COMMAND="help"
            ;;
    esac
fi
case "$COMMAND" in
    rotate-profile|rotate-awg|refresh-server-config) COMMAND="rotate-profile" ;;
esac

# Update paths after possible --conf-dir override
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
KEYS_DIR="$AWG_DIR/keys"
COMMON_SCRIPT_PATH="$AWG_DIR/awg_common.sh"
LOG_FILE="$AWG_DIR/manage_amneziawg.log"

# ==============================================================================
# Logging functions
# ==============================================================================

log_msg() {
    local type="$1" msg="$2"
    local ts
    ts=$(date +'%F %T')
    local entry="[$ts] $type: $msg"
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
        echo "[$ts] ERROR: Log write error $LOG_FILE" >&2
    fi

    # WARN and ERROR go to stderr (symmetry with install_amneziawg.sh:110+,
    # important for CI/automation parsing: stdout = "data", stderr = "diagnostics").
    if [[ "$type" == "ERROR" || "$type" == "WARN" ]]; then
        printf "${color_start}%s${color_end}\n" "$entry" >&2
    elif [[ "${JSON_OUTPUT:-0}" -eq 1 ]]; then
        # weaq P2: in --json mode stdout must contain ONLY JSON (jq/automation).
        # Route INFO/DEBUG to stderr, otherwise list/show/stats --json print INFO
        # lines before the JSON and break parsing (confirmed on biHetzner).
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
# Utilities
# ==============================================================================

is_interactive() { [[ -t 0 && -t 1 ]]; }

# Escape special characters for sed (prevents command injection)
escape_sed() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//&/\\&}"
    s="${s//#/\\#}"
    s="${s////\\/}"
    printf '%s' "$s"
}

confirm_action() {
    # CLI flag --yes or ENV AWG_YES=1 skip the confirm prompt — useful for
    # scripts, cron, Ansible and interactive calls that pre-confirmed.
    if [[ "${CLI_YES:-0}" == "1" || "${AWG_YES:-0}" == "1" ]]; then
        return 0
    fi
    if ! is_interactive; then return 0; fi
    local action="$1" subject="$2"
    read -rp "Are you sure you want to $action $subject? [y/N]: " confirm < /dev/tty
    # Accept y/yes (case-insensitive) plus stray whitespace/CR around it.
    if [[ "$confirm" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then
        return 0
    else
        log "Action cancelled."
        return 1
    fi
}

validate_client_name() {
    local name="$1"
    if [[ -z "$name" ]]; then log_error "Name is empty."; return 1; fi
    if [[ ${#name} -gt 63 ]]; then log_error "Name exceeds 63 chars."; return 1; fi
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then log_error "Name contains invalid characters."; return 1; fi
    return 0
}

# ==============================================================================
# Dependency check
# ==============================================================================

check_dependencies() {
    log "Checking dependencies..."
    local ok=1

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Not found: $CONFIG_FILE"
        ok=0
    fi
    if [[ ! -f "$COMMON_SCRIPT_PATH" ]]; then
        log_error "Not found: $COMMON_SCRIPT_PATH"
        ok=0
    fi
    if [[ ! -f "$SERVER_CONF_FILE" ]]; then
        log_error "Not found: $SERVER_CONF_FILE"
        ok=0
    fi
    if [[ "$ok" -eq 0 ]]; then
        die "Installation files not found. Run install_amneziawg_en.sh."
    fi

    if ! command -v awg &>/dev/null; then die "'awg' not found."; fi
    if ! command -v qrencode &>/dev/null; then log_warn "qrencode not found (QR codes will not be created)."; fi

    # Load common library
    # shellcheck source=/dev/null
    source "$COMMON_SCRIPT_PATH" || die "Failed to load $COMMON_SCRIPT_PATH"

    log "Dependencies OK."
}

# ==============================================================================
# Backup
# ==============================================================================

# Internal function: performs backup without acquiring a lock.
# Called only from a context where .awg_backup.lock is already held.
#
# Error handling contract (v5.11.0 A1.1):
#   - Critical artifacts (awg0.conf, CONFIG_FILE, server_*.key, client
#     *.conf, $KEYS_DIR/*) — on cp failure, return 1 (no silent skip).
#     A corrupted backup is more dangerous than a missing one.
#   - Optional (QR *.png, *.vpnuri, expiry/, cron) — cp failure → log_warn,
#     continue. They can be regenerated from config.
#   - Missing globs (no clients yet) is distinguished from cp-failure via
#     compgen -G pre-check.
# On success, sets LAST_BACKUP_PATH (used by restore_backup for rollback
# snapshot).
_backup_configs_nolock() {
    # --no-prune: do not delete old backups after creating one. Used by the
    # pre-restore snapshot: otherwise, with 10 backups already present, prune
    # would drop the oldest one, which may be exactly the backup selected for
    # restore (it lives in the same $AWG_DIR/backups directory).
    local no_prune=0
    if [[ "${1:-}" == "--no-prune" ]]; then
        no_prune=1
        shift
    fi
    log "Creating backup..."
    local bd="$AWG_DIR/backups"
    mkdir -p "$bd" || die "mkdir error $bd"
    chmod 700 "$bd" 2>/dev/null
    local ts bf td
    # Millisecond precision in the timestamp prevents collisions on rapid-fire
    # backups (e.g. regen → backup → modify → backup within the same second).
    ts=$(date +%F_%H-%M-%S.%3N)
    bf="$bd/awg_backup_${ts}.tar.gz"
    td=$(manage_mktempdir) || die "Failed to create temp directory"

    mkdir -p "$td/server" "$td/clients" "$td/keys"

    # Server config (mandatory)
    if [[ -f "$SERVER_CONF_FILE" ]]; then
        if ! cp -a "$SERVER_CONF_FILE" "$td/server/"; then
            log_error "Failed to save $SERVER_CONF_FILE to backup."
            rm -rf "$td"
            return 1
        fi
    else
        log_warn "Server config missing ($SERVER_CONF_FILE) — will not be in backup."
    fi
    # Optional sidecar files next to awg0.conf (modify backups, etc.)
    if compgen -G "${SERVER_CONF_FILE}.*" > /dev/null; then
        cp -a "${SERVER_CONF_FILE}".* "$td/server/" 2>/dev/null || \
            log_warn "Failed to save ${SERVER_CONF_FILE}.* (non-critical)."
    fi

    # Client metadata (mandatory)
    if [[ -f "$CONFIG_FILE" ]]; then
        if ! cp -a "$CONFIG_FILE" "$td/clients/"; then
            log_error "Failed to save $CONFIG_FILE to backup."
            rm -rf "$td"
            return 1
        fi
    fi
    # Client *.conf (critical when present)
    if compgen -G "$AWG_DIR/*.conf" > /dev/null; then
        if ! cp -a "$AWG_DIR"/*.conf "$td/clients/"; then
            log_error "Failed to save client *.conf files to backup."
            rm -rf "$td"
            return 1
        fi
    fi
    # QR codes *.png (optional — regenerated from conf)
    if compgen -G "$AWG_DIR/*.png" > /dev/null; then
        cp -a "$AWG_DIR"/*.png "$td/clients/" 2>/dev/null || \
            log_warn "Failed to save client *.png (non-critical)."
    fi
    # vpn:// URIs (optional — regenerated)
    if compgen -G "$AWG_DIR/*.vpnuri" > /dev/null; then
        cp -a "$AWG_DIR"/*.vpnuri "$td/clients/" 2>/dev/null || \
            log_warn "Failed to save client *.vpnuri (non-critical)."
    fi

    # Client keys (critical when present)
    if compgen -G "$KEYS_DIR/*" > /dev/null; then
        if ! cp -a "$KEYS_DIR"/* "$td/keys/"; then
            log_error "Failed to save client keys ($KEYS_DIR) to backup."
            rm -rf "$td"
            return 1
        fi
    fi

    # Server keys (mandatory when present)
    if [[ -f "$AWG_DIR/server_private.key" ]]; then
        if ! cp -a "$AWG_DIR/server_private.key" "$td/"; then
            log_error "Failed to save server_private.key to backup."
            rm -rf "$td"
            return 1
        fi
    fi
    if [[ -f "$AWG_DIR/server_public.key" ]]; then
        if ! cp -a "$AWG_DIR/server_public.key" "$td/"; then
            log_error "Failed to save server_public.key to backup."
            rm -rf "$td"
            return 1
        fi
    fi

    # Expiry (critical — Unix epoch timestamps cannot be recovered from
    # other configs). Losing this data changes expiry-enforcement behavior
    # after restore.
    if [[ -d "${EXPIRY_DIR:-$AWG_DIR/expiry}" ]]; then
        if ! cp -a "${EXPIRY_DIR:-$AWG_DIR/expiry}" "$td/expiry"; then
            log_error "Failed to save expiry/ to backup."
            rm -rf "$td"
            return 1
        fi
    fi
    # Cron awg-expiry (critical — without it expiry-enforcement stops working).
    if [[ -f /etc/cron.d/awg-expiry ]]; then
        if ! cp -a /etc/cron.d/awg-expiry "$td/"; then
            log_error "Failed to save /etc/cron.d/awg-expiry to backup."
            rm -rf "$td"
            return 1
        fi
    fi

    tar \
        --exclude="*.tmp" \
        --exclude="*.tmp.*" \
        --exclude=".*.tmp" \
        --exclude="*.new" \
        --exclude="*.bak.tmp" \
        -czf "$bf" -C "$td" . || { rm -rf "$td"; die "tar error $bf"; }
    log_debug "tar: archive created $bf"
    rm -rf "$td"
    chmod 600 "$bf" || log_warn "chmod error on backup"

    # Keep maximum 10 backups (unless --no-prune)
    if [[ "$no_prune" -eq 0 ]]; then
        find "$bd" -maxdepth 1 -name "awg_backup_*.tar.gz" -printf '%T@ %p\n' | \
            sort -nr | tail -n +11 | cut -d' ' -f2- | xargs -r rm -f || \
            log_warn "Error deleting old backups"
    fi

    LAST_BACKUP_PATH="$bf"
    log "Backup created: $bf"
}

backup_configs() {
    local backup_lockfile="${AWG_DIR}/.awg_backup.lock"
    local backup_lock_fd
    exec {backup_lock_fd}>"$backup_lockfile"
    if ! flock -x -w 30 "$backup_lock_fd"; then
        log_error "Backup lock timeout (30 sec). Another backup/restore operation is already running."
        exec {backup_lock_fd}>&-
        return 1
    fi
    # Additionally take the config lock: a concurrent `manage add/remove`
    # could modify awg0.conf/keys BETWEEN copying server/ and clients/ into
    # tmpdir - each file in the backup is intact (atomic mv) but the set is
    # desynchronized (peer mismatch on restore). restore_backup holds both
    # locks - backup must do the same. IMPORTANT: in restore
    # _backup_configs_nolock is called under an already-held config lock -
    # here the lock is taken only for the direct backup command (flock is
    # non-reentrant, see the contract in awg_common.sh).
    local config_lockfile="${AWG_DIR}/.awg_config.lock"
    local config_lock_fd
    exec {config_lock_fd}>"$config_lockfile"
    if ! flock -x -w 30 "$config_lock_fd"; then
        log_error "Config lock timeout (30 sec)."
        exec {config_lock_fd}>&-
        exec {backup_lock_fd}>&-
        return 1
    fi
    _backup_configs_nolock
    local _rc=$?
    exec {config_lock_fd}>&-
    exec {backup_lock_fd}>&-
    return "$_rc"
}

# Roll back to pre-restore snapshot (v5.11.0 A5.1).
# Called from restore_backup on any error after destructive ops start.
# Extracts the snapshot from $1 and copies files back to their original
# locations, then tries to start the service. Non-fatal if a particular
# cp fails: the goal is best-effort return to a working state so the
# user is not left without a VPN.
_restore_do_rollback() {
    local _snap="$1"
    if [[ -z "$_snap" || ! -f "$_snap" ]]; then
        log_error "Rollback snapshot unavailable ($_snap) — manual recovery required."
        return 1
    fi
    log_warn "Rolling back to pre-restore state ($(basename "$_snap"))..."
    local _rtd
    _rtd=$(manage_mktempdir) || {
        log_error "Failed to create rollback tmpdir. Manual: tar -xzf $_snap -C /"
        return 1
    }
    if ! tar -xzf "$_snap" --no-same-owner --no-same-permissions -C "$_rtd" 2>/dev/null; then
        rm -rf "$_rtd"
        log_error "Failed to unpack rollback snapshot ($_snap). Manual recovery: tar -xzf $_snap -C <target dir>"
        return 1
    fi
    local _scdir
    _scdir=$(dirname "$SERVER_CONF_FILE")
    [[ -d "$_rtd/server" ]] && cp -a "$_rtd/server/"* "$_scdir/" 2>/dev/null
    [[ -d "$_rtd/clients" ]] && cp -a "$_rtd/clients/"* "$AWG_DIR/" 2>/dev/null
    [[ -d "$_rtd/keys" ]] && cp -a "$_rtd/keys/"* "$KEYS_DIR/" 2>/dev/null
    [[ -f "$_rtd/server_private.key" ]] && cp -a "$_rtd/server_private.key" "$AWG_DIR/" 2>/dev/null
    [[ -f "$_rtd/server_public.key" ]] && cp -a "$_rtd/server_public.key" "$AWG_DIR/" 2>/dev/null
    [[ -d "$_rtd/expiry" ]] && { mkdir -p "${EXPIRY_DIR:-$AWG_DIR/expiry}"; cp -a "$_rtd/expiry"/* "${EXPIRY_DIR:-$AWG_DIR/expiry}/" 2>/dev/null; }
    [[ -f "$_rtd/awg-expiry" ]] && cp -a "$_rtd/awg-expiry" /etc/cron.d/awg-expiry 2>/dev/null
    rm -rf "$_rtd"

    log "Rollback done — attempting to start service..."
    if systemctl start awg-quick@awg0; then
        log "Service started after rollback."
        return 0
    else
        log_error "Service did not start after rollback — check: systemctl status awg-quick@awg0"
        return 1
    fi
}

restore_backup() {
    local bf="$1"
    local bd="$AWG_DIR/backups"

    if [[ -z "$bf" ]]; then
        if ! is_interactive; then
            die "Backup file path is required in non-interactive mode: restore <file>"
        fi
        if [[ ! -d "$bd" ]] || [[ -z "$(ls -A "$bd" 2>/dev/null)" ]]; then
            die "No backups found in $bd."
        fi
        local backups
        backups=$(find "$bd" -maxdepth 1 -name "awg_backup_*.tar.gz" | sort -r)
        if [[ -z "$backups" ]]; then die "No backups found."; fi

        echo "Available backups:"
        local i=1
        local bl=()
        while IFS= read -r f; do
            echo "  $i) $(basename "$f")"
            bl[$i]="$f"
            ((i++))
        done <<< "$backups"

        read -rp "Number to restore (0-cancel): " choice < /dev/tty
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -eq 0 ]] || [[ "$choice" -ge "$i" ]]; then
            log "Cancelled."
            return 1
        fi
        bf="${bl[$choice]}"
    fi

    if [[ ! -f "$bf" ]]; then die "Backup file '$bf' not found."; fi
    log "Restoring from $bf"
    if ! confirm_action "restore" "configuration from '$bf'"; then return 1; fi

    # v5.11.0 A5.1: rollback infrastructure.
    # _rollback_snap is populated after _backup_configs_nolock — until that
    # point no destructive ops run, so no rollback is needed.
    # _destructive_ops_started=1 is set before the first destructive op
    # (after systemctl stop). We roll back only when the system has
    # actually been modified — otherwise copying the same bytes back is
    # needless overhead.
    # _restore_ok=1 is set only on final success.
    local _rollback_snap=""
    local _restore_ok=0
    local _destructive_ops_started=0
    local td=""

    # Acquire backup lock (outer) — prevents concurrent backup/restore operations
    local backup_lockfile="${AWG_DIR}/.awg_backup.lock"
    local backup_lock_fd
    exec {backup_lock_fd}>"$backup_lockfile"
    if ! flock -x -w 30 "$backup_lock_fd"; then
        log_error "Backup lock timeout (30 sec). Another backup/restore operation is already running."
        exec {backup_lock_fd}>&-
        return 1
    fi

    # Acquire config lock (inner) — prevents config changes during restore
    local config_lockfile="${AWG_DIR}/.awg_config.lock"
    local config_lock_fd
    exec {config_lock_fd}>"$config_lockfile"
    if ! flock -x -w 30 "$config_lock_fd"; then
        log_error "Config lock timeout (30 sec)."
        exec {config_lock_fd}>&-
        exec {backup_lock_fd}>&-
        return 1
    fi

    # Cleanup hook: fires on every return (via trap RETURN).
    # Rollback only when _restore_ok=0 AND _destructive_ops_started=1
    # AND _rollback_snap is captured. Always → remove temp dir and
    # release locks. First we clear the RETURN trap — bash's `trap ...
    # RETURN` has global lifetime, without this it would fire on any
    # subsequent return in this shell.
    _restore_cleanup() {
        # Order matters: capture $? (return code from restore_backup)
        # FIRST, then clear the RETURN trap. Swapping would break $?
        # capture because `trap - RETURN` is a builtin that clobbers
        # $? to 0. Reentrancy is impossible: `local` and `trap -` do
        # not invoke functions, and once `trap - RETURN` runs, our
        # trap is off.
        local _rc=$?
        # Clear RETURN and RESTORE the global INT/TERM (restore's local hooks are
        # set below). A plain `trap -` would reset them to default and the manager
        # would lose its B1 signal -> cleanup+exit behavior after a restore.
        trap - RETURN
        trap '_manage_on_signal 130' INT
        trap '_manage_on_signal 143' TERM
        if [[ $_restore_ok -eq 0 && $_destructive_ops_started -eq 1 && -n "$_rollback_snap" ]]; then
            _restore_do_rollback "$_rollback_snap" || true
        fi
        [[ -n "$td" && -d "$td" ]] && rm -rf "$td"
        [[ -n "${config_lock_fd:-}" ]] && exec {config_lock_fd}>&- 2>/dev/null
        [[ -n "${backup_lock_fd:-}" ]] && exec {backup_lock_fd}>&- 2>/dev/null
        return $_rc
    }
    trap _restore_cleanup RETURN
    # INT/TERM during restore: same rollback+cleanup as a normal return
    # (_restore_cleanup sees the local _restore_ok/_rollback_snap/td), then exit
    # with the signal code. Overrides the global _manage_on_signal so interrupting
    # the destructive phase does not leave the system without a rollback.
    # _restore_cleanup clears these hooks itself (trap - INT TERM above).
    trap '_restore_cleanup; exit 130' INT
    trap '_restore_cleanup; exit 143' TERM

    log "Backing up current config..."
    # --no-prune: the backup selected for restore ($bf) lives in the same
    # backups dir; pruning after the pre-restore snapshot could delete it.
    if ! _backup_configs_nolock --no-prune; then
        log_error "Failed to create backup of current configuration."
        return 1
    fi
    # Capture rollback snapshot (set by _backup_configs_nolock)
    _rollback_snap="${LAST_BACKUP_PATH:-}"

    td=$(manage_mktempdir) || {
        log_error "Failed to create temp directory"
        return 1
    }

    # Pre-extraction validation: inspect tar contents before unpacking.
    # Defense-in-depth: our threat model (root-only local backups) makes
    # exploitation unlikely, but a crafted or substituted archive could use
    # path traversal (../), absolute paths, symlinks or device files to
    # overwrite arbitrary system files when extracted as root.

    # Type check via verbose listing: reject block/char/FIFO/symlink ('l')
    # and hardlink ('h') entries - both link classes are unsafe to extract.
    local _tar_verbose _vline _tc
    _tar_verbose=$(tar -tvzf "$bf" 2>/dev/null) || {
        log_error "Cannot read archive contents: $bf"
        return 1
    }
    while IFS= read -r _vline; do
        [[ -z "$_vline" ]] && continue
        _tc="${_vline:0:1}"
        case "$_tc" in
            b|c|p|h|l)
                log_error "Archive contains dangerous entry type ('${_tc}'): '${_vline}' — restore aborted."
                return 1
                ;;
        esac
    done <<< "$_tar_verbose"

    # Path check: absolute paths and path traversal
    local _tar_list _bad_entry
    _tar_list=$(tar -tzf "$bf" 2>/dev/null) || {
        log_error "Cannot read archive contents: $bf"
        return 1
    }
    while IFS= read -r _bad_entry; do
        [[ -z "$_bad_entry" ]] && continue
        # Absolute paths
        if [[ "$_bad_entry" == /* ]]; then
            log_error "Archive contains absolute path: '$_bad_entry' — restore aborted."
            return 1
        fi
        # Parent directory traversal
        if [[ "$_bad_entry" == *..* ]]; then
            log_error "Archive contains path traversal (..): '$_bad_entry' — restore aborted."
            return 1
        fi
    done <<< "$_tar_list"
    log_debug "Pre-extraction check passed: $(echo "$_tar_list" | wc -l) files in archive."

    if ! tar -xzf "$bf" --no-same-owner --no-same-permissions -C "$td"; then
        log_error "tar error $bf"
        return 1
    fi

    # Post-extraction check: no symlinks in the unpacked tree
    local _symlinks
    _symlinks=$(find "$td" -type l 2>/dev/null)
    if [[ -n "$_symlinks" ]]; then
        log_error "Archive contains symlinks (possible symlink attack):"
        while IFS= read -r _sl; do log_error "  $_sl -> $(readlink "$_sl")"; done <<< "$_symlinks"
        return 1
    fi

    # Check backup completeness BEFORE stopping the service. A backup without a
    # server config is useless (a VPN cannot come up without it), and an empty
    # server/ used to crash `cp "$td/server/"*` AFTER the stop, forcing a rollback
    # of a working system. Checking before the destructive phase leaves the
    # service untouched and needs no rollback.
    local _srv_base
    _srv_base=$(basename "$SERVER_CONF_FILE")
    if [[ ! -f "$td/server/$_srv_base" ]]; then
        log_error "Incomplete backup: missing server config ($_srv_base) - restore aborted."
        return 1
    fi

    log "Stopping service..."
    systemctl stop awg-quick@awg0 || log_warn "Service not stopped."

    # From here on destructive ops. All error paths → trap _restore_cleanup → rollback.
    _destructive_ops_started=1
    if [[ -d "$td/server" ]]; then
        log "Restoring server config..."
        local server_conf_dir
        server_conf_dir=$(dirname "$SERVER_CONF_FILE")
        mkdir -p "$server_conf_dir"
        if ! cp -a "$td/server/"* "$server_conf_dir/"; then
            log_error "Error copying server — restore aborted (triggering rollback)."
            return 1
        fi
        chmod 600 "$server_conf_dir"/*.conf 2>/dev/null
        chmod 700 "$server_conf_dir"
        log_debug "Server config restored to $server_conf_dir"
    fi

    if [[ -d "$td/clients" ]]; then
        log "Restoring client files..."
        # C11: clean replacement, not a merge. Remove stale client artifacts that
        # are absent from the backup (otherwise a client deleted since the backup
        # lingers as orphan .conf/.png/.vpnuri). Scope strictly to managed client
        # globs - never touch scripts, server keys, backups/, logs, .lock,
        # awgsetup_cfg.init.
        rm -f "$AWG_DIR"/*.conf "$AWG_DIR"/*.png "$AWG_DIR"/*.vpnuri 2>/dev/null || true
        # An empty clients/ is a valid case (a server with no client configs):
        # the prune above already gives a clean replacement, so we just skip the
        # copy (without compgen the bare glob "$td/clients/"* would stay literal
        # and crash cp -> rollback).
        if compgen -G "$td/clients/*" > /dev/null; then
            if ! cp -a "$td/clients/"* "$AWG_DIR/"; then
                log_error "Error copying clients — restore aborted (triggering rollback)."
                return 1
            fi
            chmod 600 "$AWG_DIR"/*.conf 2>/dev/null
            chmod 600 "$AWG_DIR"/*.png 2>/dev/null
            chmod 600 "$AWG_DIR"/*.vpnuri 2>/dev/null
            chmod 600 "$CONFIG_FILE" 2>/dev/null
            log_debug "Client files restored to $AWG_DIR"
        else
            log_debug "Backup has no client files (clients/ empty) - skipping copy."
        fi
    fi

    if [[ -d "$td/keys" ]]; then
        log "Restoring keys..."
        mkdir -p "$KEYS_DIR"
        # C11: remove stale client keys absent from the backup (server keys live
        # in AWG_DIR, not KEYS_DIR, so they are not affected).
        rm -f "$KEYS_DIR"/* 2>/dev/null || true
        # C2: the backup's keys/ may be empty (server with no client keys).
        # Without a compgen guard the bare glob "$td/keys/*" would stay literal,
        # cp would fail and the whole restore would roll back. Empty keys/ is OK.
        if ! compgen -G "$td/keys/*" > /dev/null; then
            log_debug "Backup has no client keys (keys/ empty) - skipping, not an error."
        elif ! cp -a "$td/keys/"* "$KEYS_DIR/"; then
            log_error "Error copying keys — restore aborted (triggering rollback)."
            return 1
        else
            chmod 600 "$KEYS_DIR"/* 2>/dev/null
            log_debug "Keys restored to $KEYS_DIR"
        fi
    fi

    # Server keys: cp -a preserves the mode from the archive, so we force 600
    # regardless of the mode they had inside the backup (audit fix).
    if [[ -f "$td/server_private.key" ]]; then
        if ! cp -a "$td/server_private.key" "$AWG_DIR/"; then
            log_error "Error copying server_private.key — restore aborted (triggering rollback)."
            return 1
        fi
        chmod 600 "$AWG_DIR/server_private.key" 2>/dev/null || true
    fi
    if [[ -f "$td/server_public.key" ]]; then
        if ! cp -a "$td/server_public.key" "$AWG_DIR/"; then
            log_error "Error copying server_public.key — restore aborted (triggering rollback)."
            return 1
        fi
        chmod 600 "$AWG_DIR/server_public.key" 2>/dev/null || true
    fi

    if [[ -d "$td/expiry" ]]; then
        log "Restoring expiry data..."
        mkdir -p "${EXPIRY_DIR:-$AWG_DIR/expiry}"
        # C11: expiry is intentionally NOT pruned. Orphan stamps for nonexistent
        # clients are harmless: check_expired_clients detects on expiry that the
        # peer is absent from the config and cleans the stamp with the artifacts
        # itself. A prune here would be unsafe: both the rm and the following cp
        # are best-effort (|| true), so a copy failure after the prune would
        # silently leave expiry empty. The client artifacts themselves are
        # pruned above.
        cp -a "$td/expiry/"* "${EXPIRY_DIR:-$AWG_DIR/expiry}/" 2>/dev/null || true
        chmod 600 "${EXPIRY_DIR:-$AWG_DIR/expiry}"/* 2>/dev/null
    fi
    if [[ -f "$td/awg-expiry" ]]; then
        cp -a "$td/awg-expiry" /etc/cron.d/awg-expiry
        chmod 644 /etc/cron.d/awg-expiry
    fi

    # Pre-flight: validate restored config BEFORE starting the service.
    # If the config is invalid awg-quick@awg0 will definitely fail — better
    # to roll back now and explain why than to start a broken service.
    if ! validate_awg_config >/dev/null 2>&1; then
        log_error "Restored server config failed validation — triggering rollback."
        return 1
    fi

    log "Starting service..."
    if ! systemctl start awg-quick@awg0; then
        log_error "Service start error — triggering rollback."
        local status_out
        status_out=$(systemctl status awg-quick@awg0 --no-pager 2>&1) || true
        while IFS= read -r line; do log_error "  $line"; done <<< "$status_out"
        return 1
    fi

    # Success — rollback not needed, trap only performs cleanup
    _restore_ok=1
    log "Restore completed."
    return 0
}

# ==============================================================================
# Modify client parameter
# ==============================================================================

modify_client() {
    local name="$1" param="$2" value="$3"

    if [[ -z "$name" || -z "$param" || -z "$value" ]]; then
        log_error "Usage: modify <name> <param> <value>"
        return 1
    fi

    # Validation BEFORE taking the lock (early returns need no fd cleanup)
    local allowed_params="DNS|Endpoint|AllowedIPs|PersistentKeepalive"
    if ! [[ "$param" =~ ^($allowed_params)$ ]]; then
        log_error "Parameter '$param' cannot be changed via modify."
        log_error "Allowed parameters: ${allowed_params//|/, }"
        return 1
    fi

    case "$param" in
        DNS)
            # Structural validation of the DNS list. The old charset-only regex
            # ^[0-9a-fA-F.:,\ ]+$ let garbage through ('abc' - a-f letters;
            # '999.999.999.999' - out of range). DNS is IP-only by contract (no
            # FQDN), so each element must be a bare IPv4 or IPv6, like Endpoint/AllowedIPs.
            case "$value" in
                *$'\n'*|*$'\r'*|*\\*|*\"*|*\'*|"")
                    log_error "Invalid DNS: '$value'"
                    return 1 ;;
            esac
            case "$value" in
                ,*|*,|*,,*)
                    log_error "Invalid DNS '$value': empty list element (stray comma)"
                    return 1 ;;
            esac
            local _dns_tok _dns_ifs="$IFS"
            IFS=','
            for _dns_tok in $value; do
                _dns_tok="${_dns_tok//[[:space:]]/}"
                if [[ -z "$_dns_tok" ]]; then
                    IFS="$_dns_ifs"
                    log_error "Invalid DNS '$value': empty list element (stray comma)"
                    return 1
                fi
                if ! _valid_ipv4 "$_dns_tok" && ! _valid_ipv6 "$_dns_tok"; then
                    IFS="$_dns_ifs"
                    log_error "Invalid DNS '$value': '$_dns_tok' is not a valid IPv4/IPv6 address"
                    return 1
                fi
            done
            IFS="$_dns_ifs"
            ;;
        PersistentKeepalive)
            if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -gt 65535 ]]; then
                log_error "Invalid PersistentKeepalive: '$value' (expected: 0-65535)"
                return 1
            fi ;;
        Endpoint)
            # C5: beyond rejecting dangerous chars - positive host:port check.
            case "$value" in
                *$'\n'*|*$'\r'*|*\\*|*\"*|*\'*|*' '*|*$'\t'*|"")
                    log_error "Invalid Endpoint: '$value'"
                    return 1 ;;
            esac
            local _eh _ept
            if [[ "$value" == \[*\]:* ]]; then
                _eh="${value%]:*}"; _eh="${_eh#\[}"   # IPv6 without brackets
                _ept="${value##*]:}"
                _valid_ipv6 "$_eh" || { log_error "Invalid Endpoint '$value': malformed IPv6 host"; return 1; }
            else
                _eh="${value%:*}"; _ept="${value##*:}"
                _valid_host_or_ipv4 "$_eh" || { log_error "Invalid Endpoint '$value': expected host:port (FQDN / IPv4 / [IPv6])"; return 1; }
            fi
            { [[ "$_ept" =~ ^[0-9]+$ ]] && [[ "$_ept" -ge 1 && "$_ept" -le 65535 ]]; } || { log_error "Invalid Endpoint '$value': port must be 1-65535"; return 1; }
            ;;
        AllowedIPs)
            # C5: beyond rejecting dangerous chars - positive CIDR-list check.
            case "$value" in
                *$'\n'*|*$'\r'*|*\\*|*\"*|*\'*|"")
                    log_error "Invalid AllowedIPs: '$value'"
                    return 1 ;;
            esac
            # Stray commas: word-splitting on IFS=',' silently drops a TRAILING
            # empty element (e.g. "10.0.0.0/24,"), so check list structure
            # separately: leading/trailing/doubled comma.
            case "$value" in
                ,*|*,|*,,*)
                    log_error "Invalid AllowedIPs '$value': empty list element (stray comma)"
                    return 1 ;;
            esac
            local _aip_tok _aip_ifs="$IFS"
            IFS=','
            for _aip_tok in $value; do
                _aip_tok="${_aip_tok//[[:space:]]/}"
                if [[ -z "$_aip_tok" ]]; then
                    IFS="$_aip_ifs"
                    log_error "Invalid AllowedIPs '$value': empty list element (stray comma)"
                    return 1
                fi
                if ! _valid_cidr "$_aip_tok"; then
                    IFS="$_aip_ifs"
                    log_error "Invalid AllowedIPs '$value': '$_aip_tok' is not a CIDR (IPv4/IPv6 with optional /n prefix)"
                    return 1
                fi
            done
            IFS="$_aip_ifs"
            ;;
    esac

    # Lock before state checks (TOCTOU protection against concurrent remove)
    local modify_lockfile="${AWG_DIR}/.awg_config.lock"
    local modify_lock_fd
    exec {modify_lock_fd}>"$modify_lockfile"
    if ! flock -x -w 10 "$modify_lock_fd"; then
        log_error "Could not acquire config lock (another operation in progress)"
        exec {modify_lock_fd}>&-
        return 1
    fi

    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE"; then
        exec {modify_lock_fd}>&-
        die "Client '$name' not found."
    fi

    local cf="$AWG_DIR/$name.conf"
    if [[ ! -f "$cf" ]]; then exec {modify_lock_fd}>&-; die "File $cf not found."; fi

    if ! grep -q -E "^${param}[[:space:]]*=" "$cf"; then
        log_error "Parameter '$param' not found in $cf."
        exec {modify_lock_fd}>&-
        return 1
    fi

    log "Changing '$param' to '$value' for '$name'..."
    local bak
    bak="${cf}.bak-$(date +%F_%H-%M-%S)"
    # v5.11.0 A5.2: backup is critical — without it a destructive sed can
    # corrupt the config with no way back. Abort if the backup cp fails.
    if ! cp "$cf" "$bak"; then
        log_error "Failed to create backup '$bak' — destructive sed aborted."
        exec {modify_lock_fd}>&-
        return 1
    fi
    log "Backup: $bak"

    local escaped_value
    escaped_value=$(escape_sed "$value")
    if ! sed -i "s#^${param}[[:space:]]*=[[:space:]]*.*#${param} = ${escaped_value}#" "$cf"; then
        log_error "sed error. Restoring..."
        # After a successful rollback the .bak is identical to the config -
        # remove it so repeated failed modifies do not pile .bak files in $AWG_DIR.
        if cp "$bak" "$cf"; then rm -f "$bak"; else log_warn "Restore error."; fi
        exec {modify_lock_fd}>&-
        return 1
    fi
    if ! grep -q -E "^${param} = " "$cf"; then
        log_error "Replacement failed for '$param'. Restoring..."
        if cp "$bak" "$cf"; then rm -f "$bak"; else log_warn "Restore error."; fi
        exec {modify_lock_fd}>&-
        return 1
    fi
    log_debug "sed: ${param} = ${value} in $cf"

    log "Parameter '$param' changed."
    rm -f "$bak"

    log "Regenerating QR code and vpn:// URI..."
    generate_qr "$name" || log_warn "Failed to update QR code."
    if generate_vpn_uri "$name"; then
        generate_qr_vpnuri "$name" || log_warn "Failed to update vpn:// QR."
    else
        log_warn "Failed to update vpn:// URI."
    fi

    exec {modify_lock_fd}>&-
    return 0
}

# ==============================================================================
# Server status check
# ==============================================================================

check_server() {
    log "Checking AmneziaWG 2.0 server status..."
    local ok=1

    log "Service status:"
    if ! systemctl status awg-quick@awg0 --no-pager; then ok=0; fi

    log "Interface awg0:"
    if ! ip addr show awg0 &>/dev/null; then
        log_error " - Interface not found!"
        ok=0
    else
        while IFS= read -r line; do log "  $line"; done < <(ip addr show awg0)
    fi

    log "Port listening:"
    safe_load_config "$CONFIG_FILE" 2>/dev/null
    local port=${AWG_PORT:-0}
    if [[ "$port" -eq 0 ]]; then
        log_warn " - Failed to determine port."
    else
        if ! ss -lunp | grep -q ":${port} "; then
            log_error " - Port ${port}/udp is NOT listening!"
            ok=0
        else
            log " - Port ${port}/udp is listening."
        fi
    fi

    log "Kernel settings:"
    local fwd
    fwd=$(sysctl -n net.ipv4.ip_forward)
    if [[ "$fwd" != "1" ]]; then
        log_error " - IP Forwarding is disabled ($fwd)!"
        ok=0
    else
        log " - IP Forwarding is enabled."
    fi

    log "UFW rules:"
    if command -v ufw &>/dev/null; then
        if [[ "$port" -eq 0 ]]; then
            # The port could not be determined above - grepping for "0/udp" would give a false warning.
            log_warn " - Port not determined, UFW rule check skipped."
        elif ! ufw status | grep -qw "${port}/udp"; then
            log_warn " - UFW rule for ${port}/udp not found!"
        else
            log " - UFW rule for ${port}/udp is present."
        fi
    else
        log_warn " - UFW is not installed."
    fi

    log "AmneziaWG 2.0 status:"
    # Previously awg show was called via process substitution without an exit
    # code check, so check could report "Status OK" even when awg crashed.
    # Now we capture the output and check the exit code (audit).
    local _awg_out
    if ! _awg_out=$(awg show awg0 2>&1); then
        log_error " - awg show awg0 failed:"
        while IFS= read -r _l; do log_error "  $_l"; done <<< "$_awg_out"
        ok=0
    else
        while IFS= read -r _l; do log "  $_l"; done <<< "$_awg_out"
        if grep -q "jc:" <<< "$_awg_out"; then
            log " - AWG 2.0 obfuscation parameters: active"
        else
            log_warn " - AWG 2.0 obfuscation parameters not detected"
        fi
    fi

    if [[ "$ok" -eq 1 ]]; then
        log "Check completed: Status OK."
        return 0
    else
        log_error "Check completed: ISSUES FOUND!"
        return 1
    fi
}

# ==============================================================================
# Diagnose: read-only troubleshooting with optional carrier comparison
# ==============================================================================

_diagnose_carrier_known() {
    case "$1" in
        beeline_msk)            echo "3 6 40 89 50 250 random" ;;
        yota_msk|tele2_msk|tattelecom) echo "3 3 30 50 20 80 random" ;;
        tele2_krasnoyarsk|megafon_regions) echo "3 3 30 50 20 80 absent" ;;
        tmobile_us)             echo "6 6 10 10 40 40 binary" ;;
        *)                       return 1 ;;
    esac
}

_diagnose_carrier_list() {
    echo "beeline_msk yota_msk tele2_msk tele2_krasnoyarsk tattelecom megafon_regions tmobile_us"
}

_diag_line() {
    local status="$1" msg="$2"
    local color_start="" color_end=""
    if [[ "$NO_COLOR" -eq 0 ]]; then
        color_end="\033[0m"
        case "$status" in
            OK)   color_start="\033[0;32m" ;;
            WARN) color_start="\033[0;33m" ;;
            FAIL) color_start="\033[0;31m" ;;
            INFO) color_start="\033[0;36m" ;;
        esac
    fi
    printf "%b[%-4s]%b %s\n" "$color_start" "$status" "$color_end" "$msg"
}

diagnose_server() {
    local carrier="${CLI_CARRIER}"
    local ok=0 warn=0 fail=0

    log "Diagnosing AmneziaWG 2.0 server..."
    if [[ -n "$carrier" ]] && ! _diagnose_carrier_known "$carrier" >/dev/null; then
        log_error "Unknown carrier: '$carrier'"
        log_error "Supported: $(_diagnose_carrier_list)"
        return 1
    fi

    if lsmod 2>/dev/null | awk '$1 == "amneziawg" {f=1} END {exit !f}'; then
        _diag_line OK "amneziawg kernel module is loaded"; ok=$((ok+1))
    else
        _diag_line FAIL "amneziawg kernel module is NOT loaded"
        echo "        Fix: sudo bash $0 repair-module"
        fail=$((fail+1))
    fi

    if systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
        _diag_line OK "awg-quick@awg0 service is active"; ok=$((ok+1))
    else
        _diag_line FAIL "awg-quick@awg0 service is NOT active"
        echo "        Fix: sudo systemctl start awg-quick@awg0"
        fail=$((fail+1))
    fi

    if ip link show awg0 2>/dev/null | grep -qE "state (UP|UNKNOWN)"; then
        local awg_ip
        awg_ip=$(ip -4 -o addr show awg0 2>/dev/null | awk '{print $4; exit}')
        _diag_line OK "Interface awg0 is UP (${awg_ip:-?})"; ok=$((ok+1))
    else
        _diag_line FAIL "Interface awg0 is not UP or does not exist"
        fail=$((fail+1))
    fi

    local fwd
    fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "?")
    if [[ "$fwd" == "1" ]]; then
        _diag_line OK "sysctl net.ipv4.ip_forward=1"; ok=$((ok+1))
    else
        _diag_line FAIL "sysctl net.ipv4.ip_forward=$fwd (expected 1)"
        fail=$((fail+1))
    fi

    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
    if [[ "$cc" == "bbr" ]]; then
        _diag_line OK "sysctl tcp_congestion_control=bbr"; ok=$((ok+1))
    else
        _diag_line WARN "sysctl tcp_congestion_control=$cc (bbr recommended)"
        warn=$((warn+1))
    fi

    safe_load_config "$CONFIG_FILE" 2>/dev/null || true
    local awg_port="${AWG_PORT:-39743}"
    if command -v ufw &>/dev/null; then
        local ufw_st
        ufw_st=$(ufw status 2>/dev/null | head -1)
        if [[ "$ufw_st" == "Status: active" ]]; then
            if ufw status 2>/dev/null | grep -qE "^${awg_port}/udp[[:space:]]+ALLOW"; then
                _diag_line OK "UFW active, ${awg_port}/udp ALLOW"; ok=$((ok+1))
            else
                _diag_line WARN "UFW active, but ${awg_port}/udp is not ALLOW"
                warn=$((warn+1))
            fi
        else
            _diag_line WARN "UFW is not active ($ufw_st)"; warn=$((warn+1))
        fi
    else
        _diag_line WARN "ufw is not installed"; warn=$((warn+1))
    fi

    local peer_count
    peer_count=$(awg show awg0 peers 2>/dev/null | wc -l)
    _diag_line INFO "Configured peers: $peer_count"

    local jc jmin jmax i1
    jc=$(awg show awg0 2>/dev/null   | awk '/^[[:space:]]*jc:/   {print $2; exit}')
    jmin=$(awg show awg0 2>/dev/null | awk '/^[[:space:]]*jmin:/ {print $2; exit}')
    jmax=$(awg show awg0 2>/dev/null | awk '/^[[:space:]]*jmax:/ {print $2; exit}')
    i1=$(awg show awg0 2>/dev/null   | awk -F': ' '/^[[:space:]]*i1:/ {print $2; exit}')
    _diag_line INFO "AWG params: Jc=${jc:-?} Jmin=${jmin:-?} Jmax=${jmax:-?} I1=${i1:-absent}"

    local web_state adg_state p2p_count
    web_state="inactive"
    systemctl is-active --quiet awg-web.service 2>/dev/null && web_state="active"
    _diag_line INFO "Web panel: enabled=${AWG_WEB_ENABLED:-0} bind=${AWG_WEB_BIND:-?} port=${AWG_WEB_PORT:-?} service=$web_state"
    adg_state="inactive"
    systemctl is-active --quiet AdGuardHome.service 2>/dev/null && adg_state="active"
    _diag_line INFO "AdGuard Home: enabled=${AWG_ADGUARD_ENABLED:-0} service=$adg_state dns_mode=${AWG_DNS_MODE:-system}"
    _diag_line INFO "IPv6: enabled=${AWG_IPV6_ENABLED:-0} mode=${AWG_IPV6_MODE:-legacy} subnet=${AWG_IPV6_SUBNET:-none}"
    if [[ -f "$SERVER_CONF_FILE" ]]; then
        p2p_count=$(grep -c '^#_P2P_Ports = ' "$SERVER_CONF_FILE" 2>/dev/null || true)
    else
        p2p_count=0
    fi
    _diag_line INFO "P2P: enabled=${AWG_P2P_ENABLED:-0} peers_with_ports=$p2p_count"
    _diag_line INFO "WireSock hints: ${AWG_WIRESOCK_HINTS:-off}"

    if [[ -n "$carrier" ]]; then
        echo ""
        log "Comparing against carrier profile '$carrier'..."
        local row
        row=$(_diagnose_carrier_known "$carrier")
        local rc_jc_min rc_jc_max rc_jmin_lo rc_jmin_hi rc_jmax_off_lo rc_jmax_off_hi rc_i1
        read -r rc_jc_min rc_jc_max rc_jmin_lo rc_jmin_hi rc_jmax_off_lo rc_jmax_off_hi rc_i1 <<<"$row"

        if [[ -n "$jc" && "$jc" =~ ^[0-9]+$ && "$jc" -ge "$rc_jc_min" && "$jc" -le "$rc_jc_max" ]]; then
            _diag_line OK "Jc=$jc is within [$rc_jc_min..$rc_jc_max] for $carrier"; ok=$((ok+1))
        else
            _diag_line WARN "Jc=${jc:-?} is outside recommended [$rc_jc_min..$rc_jc_max] for $carrier"
            warn=$((warn+1))
        fi

        if [[ -n "$jmin" && "$jmin" =~ ^[0-9]+$ && "$jmin" -ge "$rc_jmin_lo" && "$jmin" -le "$rc_jmin_hi" ]]; then
            _diag_line OK "Jmin=$jmin is within [$rc_jmin_lo..$rc_jmin_hi] for $carrier"; ok=$((ok+1))
        else
            _diag_line WARN "Jmin=${jmin:-?} is outside recommended [$rc_jmin_lo..$rc_jmin_hi] for $carrier"
            warn=$((warn+1))
        fi

        if [[ -n "$jmax" && -n "$jmin" && "$jmax" =~ ^[0-9]+$ && "$jmin" =~ ^[0-9]+$ ]]; then
            local jmax_off
            jmax_off=$((jmax - jmin))
            if [[ "$jmax_off" -ge "$rc_jmax_off_lo" && "$jmax_off" -le "$rc_jmax_off_hi" ]]; then
                _diag_line OK "Jmax-Jmin=$jmax_off is within [$rc_jmax_off_lo..$rc_jmax_off_hi]"; ok=$((ok+1))
            else
                _diag_line WARN "Jmax-Jmin=$jmax_off is outside [$rc_jmax_off_lo..$rc_jmax_off_hi]"
                warn=$((warn+1))
            fi
        else
            _diag_line WARN "Could not calculate Jmax-Jmin (Jmax=${jmax:-?}, Jmin=${jmin:-?})"
            warn=$((warn+1))
        fi

        case "$rc_i1" in
            absent)
                if [[ -z "$i1" || "$i1" == "absent" ]]; then
                    _diag_line OK "I1 is absent as required for $carrier"; ok=$((ok+1))
                else
                    _diag_line WARN "I1=$i1, but $carrier expects I1=absent"
                    warn=$((warn+1))
                fi
                ;;
            random)
                if [[ -n "$i1" && "$i1" =~ ^\<r\ [0-9]+\>$ ]]; then
                    _diag_line OK "I1 random ($i1) matches $carrier"; ok=$((ok+1))
                elif [[ -z "$i1" ]]; then
                    _diag_line WARN "I1 is absent; $carrier usually works with I1 random (<r N>)"
                    warn=$((warn+1))
                else
                    _diag_line WARN "I1=$i1 has a non-standard format for $carrier"
                    warn=$((warn+1))
                fi
                ;;
            binary)
                if [[ -n "$i1" && "$i1" =~ ^\<r\ [0-9]+\>\<b\ 0x[0-9A-Fa-f]+\> ]]; then
                    _diag_line OK "I1 binary ($i1) matches $carrier"; ok=$((ok+1))
                else
                    _diag_line WARN "I1=${i1:-absent}; $carrier expects binary I1 (<r N><b 0xHEX>)"
                    warn=$((warn+1))
                fi
                ;;
        esac
    fi

    echo ""
    log "Summary: OK=$ok WARN=$warn FAIL=$fail"
    [[ "$fail" -eq 0 ]]
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
    [[ "$name" =~ ^[[:alnum:]_.\ ,!\?\(\)-]+$ ]] || return 1
}

set_config_value() {
    local key="$1" value="$2"
    [[ -f "$CONFIG_FILE" ]] || { log_error "Not found: $CONFIG_FILE"; return 1; }
    case "$value" in *$'\n'*|*$'\r'*) log_error "Invalid value for $key"; return 1 ;; esac
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
    validate_server_name "$name" || { log_error "Invalid server name."; return 1; }
    [[ -f "$SERVER_CONF_FILE" ]] || { log_error "Not found: $SERVER_CONF_FILE"; return 1; }
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
        refresh_client_config "$name" || { log_warn "Failed to refresh '$name'"; rc=1; }
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
    log "Server name set: $name. Client configs and vpn:// files regenerated."
}

web_token_py() {
    local action="$1" name="${2:-}" clients_csv="${3:-}"
    local token_file="$AWG_DIR/web/tokens.json"
    mkdir -p "$AWG_DIR/web" || return 1
    python3 - "$token_file" "$action" "$name" "$clients_csv" <<'PY'
import hashlib
import json
import os
import re
import secrets
import shutil
import sys
import time
from pathlib import Path

path = Path(sys.argv[1])
action = sys.argv[2]
name = sys.argv[3]
clients_csv = sys.argv[4]
client_re = re.compile(r"^[A-Za-z0-9_-]{1,63}$")

def digest(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()

def normalize(data, allow_new_super=False):
    if not isinstance(data, dict):
        raise SystemExit("tokens.json is invalid; run manage_amneziawg_en.sh web token reset-super")
    users = data.get("users")
    if not isinstance(users, dict):
        if path.exists() and "users" in data:
            raise SystemExit("tokens.json is invalid; run manage_amneziawg_en.sh web token reset-super")
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
            raise SystemExit("tokens.json is invalid; run manage_amneziawg_en.sh web token reset-super")
        if not isinstance(record["name"], str) or any(ord(ch) < 32 or ord(ch) == 127 for ch in record["name"]) or len(record["name"]) > 64:
            raise SystemExit("tokens.json is invalid; run manage_amneziawg_en.sh web token reset-super")
        if not isinstance(record["clients"], list):
            raise SystemExit("tokens.json is invalid; run manage_amneziawg_en.sh web token reset-super")
        clean_users[key] = {
            "name": record["name"],
            "clients": [item for item in record["clients"] if isinstance(item, str) and client_re.fullmatch(item)],
        }
    super_hash = data.get("super_token_hash") or data.get("super")
    if not isinstance(super_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", super_hash):
        if path.exists() and not allow_new_super:
            raise SystemExit("tokens.json is invalid; run manage_amneziawg_en.sh web token reset-super")
        token = secrets.token_urlsafe(32)
        super_hash = digest(token)
        data["_new_super_token"] = token
    return {"super_token_hash": super_hash, "users": clean_users}

def load():
    if path.exists():
        try:
            data = json.loads(path.read_text())
        except Exception:
            raise SystemExit("tokens.json is invalid; run manage_amneziawg_en.sh web token reset-super")
    else:
        data = {}
    return normalize(data, allow_new_super=not path.exists())

def save(data):
    tmp = path.with_name(path.name + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    os.chmod(path, 0o600)

def backup_existing():
    if not path.exists():
        return None
    backup = path.with_name(path.name + ".bak." + time.strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(path, backup)
    os.chmod(backup, 0o600)
    return backup

def clean_name(value):
    value = (value or "").strip()
    if len(value) > 64 or any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
        raise SystemExit("invalid token name")
    return value

def clean_clients(value):
    out, seen = [], set()
    for item in [part.strip() for part in value.split(",") if part.strip()]:
        if not client_re.fullmatch(item):
            raise SystemExit("invalid client name")
        if item not in seen:
            out.append(item)
            seen.add(item)
    return out

if action == "reset-super":
    backup = backup_existing()
    try:
        existing = json.loads(path.read_text()) if path.exists() else {}
        data = normalize(existing, allow_new_super=True)
    except Exception:
        data = {"super_token_hash": "0" * 64, "users": {}}
else:
    data = load()

if action == "list":
    save(data)
    print("super: present")
    for key, record in sorted(data["users"].items()):
        suffix = ",".join(record["clients"]) if record["clients"] else "-"
        print(f"user: {key[:12]}... name={record['name'] or '-'} clients={suffix}")
elif action == "add":
    name = clean_name(name)
    clients = clean_clients(clients_csv)
    token = secrets.token_urlsafe(32)
    data["users"][digest(token)] = {"name": name, "clients": clients}
    save(data)
    if clients:
        print("Token created.")
    else:
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
    save(data)
    summary = path.parent.parent / "INSTALL_SUMMARY.txt"
    if summary.exists():
        text = summary.read_text(encoding="utf-8", errors="replace")
        text = re.sub(r"(?m)^(\s*Super token: ).*$", lambda m: m.group(1) + token, text)
        text = re.sub(r"(?m)^(\s*Web Super Token: ).*$", lambda m: m.group(1) + token, text)
        summary.write_text(text, encoding="utf-8")
        os.chmod(summary, 0o600)
    if backup is not None:
        print(f"Backup: {backup}")
    print("Web super token reset successfully.")
    print("Raw super token:")
    print(token)
    print("")
    print("Saved to:")
    print(summary if summary.exists() else "INSTALL_SUMMARY.txt not found")
    print("")
    print("Token storage:")
    print(path)
    print("Only SHA-256 hash is stored there.")
elif action == "check":
    token = name
    token_digest = digest(token)
    if hmac_compare := getattr(__import__("hmac"), "compare_digest"):
        if hmac_compare(token_digest, data.get("super_token_hash", "")) or any(hmac_compare(token_digest, key) for key in data["users"]):
            print("valid")
            raise SystemExit(0)
    print("invalid")
    raise SystemExit(1)
elif action == "status":
    st_mode = "missing"
    if path.exists():
        st_mode = oct(path.stat().st_mode & 0o777)
    aliases = [record.get("name", "") for record in data["users"].values() if isinstance(record, dict) and record.get("name")]
    print(f"token_file: {path}")
    print(f"permissions: {st_mode}")
    print(f"super_hash_present: {'yes' if re.fullmatch(r'[0-9a-f]{64}', data.get('super_token_hash', '')) else 'no'}")
    print(f"user_tokens: {len(data['users'])}")
    print("aliases: " + (", ".join(sorted(aliases)) if aliases else "-"))
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
        refresh_client_config "$name" || { log_warn "Failed to refresh '$name'"; rc=1; }
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
    log "AdGuard UI: http://$(awg_ipv4_gateway):${AWG_ADGUARD_PORT:-3000}/"
    if [[ "${AWG_DNS_MODE:-system}" == "adguard" && "$active" != "active" ]]; then
        log_warn "AdGuard Home is not active. VPN keeps working; fallback with: manage dns set-mode system"
    fi
}

dns_set_mode() {
    local mode="$1" custom="${2:-}"
    case "$mode" in
        adguard|system|custom) ;;
        *) log_error "Usage: dns set-mode adguard|system|custom [DNS]"; return 1 ;;
    esac
    if [[ "$mode" == "custom" ]]; then
        [[ -n "$custom" ]] || custom="${AWG_CUSTOM_DNS:-1.1.1.1}"
        validate_dns_list "$custom" || { log_error "Invalid custom DNS: '$custom'"; return 1; }
        set_config_value "AWG_CUSTOM_DNS" "$custom" || return 1
    fi
    set_config_value "AWG_DNS_MODE" "$mode" || return 1
    if [[ "$mode" == "adguard" ]]; then
        set_config_value "AWG_ADGUARD_ENABLED" "1" || return 1
        systemctl restart AdGuardHome.service 2>/dev/null || log_warn "AdGuardHome.service did not start; VPN was not changed."
    fi
    safe_load_config "$CONFIG_FILE" 2>/dev/null || true
    regenerate_all_clients_for_dns || return 1
    log "DNS mode set to: $mode. Client configs regenerated."
}

# ==============================================================================
# Client list
# ==============================================================================

list_clients() {
    log "Getting client list..."
    local clients
    clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //' | sort) || clients=""
    if [[ -z "$clients" ]]; then
        if [[ "$JSON_OUTPUT" -eq 1 ]]; then
            echo "[]"
        else
            log "No clients found."
        fi
        return 0
    fi

    local verbose=$VERBOSE_LIST
    local act=0 tot=0

    # Single-pass server config parsing: name → pubkey
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

    # Single-pass awg show dump parsing: pubkey → handshake timestamp
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
        printf "%-18s | %-5s | %-5s | %-15s | %-30s | %-17s | %-15s | %s\n" "Client name" "Conf" "QR" "IPv4" "IPv6" "P2P" "Key (start)" "Status"
        printf -- "-%.0s" {1..130}
        echo
    else
        printf "%-18s | %-15s | %-17s | %s\n" "Client name" "IPv4" "P2P" "Status"
        printf -- "-%.0s" {1..75}
        echo
    fi

    local now
    now=$(date +%s)

    local json_entries=()

    while IFS= read -r name; do
        name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
        if [[ -z "$name" ]]; then continue; fi
        ((tot++))

        local cf="?" png="?" pk="-" ip="-" ipv6="-" p2p="-" st="No data"
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
                    if [[ $diff -lt 180 ]]; then
                        st="Active"
                        [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;32m"
                        ((act++))
                    elif [[ $diff -lt 86400 ]]; then
                        st="Recent"
                        [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;33m"
                        ((act++))
                    else
                        st="No handshake"
                        [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;37m"
                    fi
                else
                    st="No handshake"
                    [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;37m"
                fi
            else
                pk="?"
                st="Key error"
                [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;31m"
            fi
        fi

        # Expiry info: table output only (JSON does not print it - a wasted
        # file read per client). Accept only a numeric timestamp: a corrupted
        # expiry file would throw a bash arithmetic error from
        # format_remaining straight into the table.
        local exp_str=""
        if [[ "$JSON_OUTPUT" -ne 1 ]]; then
            local exp_ts
            exp_ts=$(get_client_expiry "$name" 2>/dev/null)
            if [[ "$exp_ts" =~ ^[0-9]+$ ]]; then
                exp_str=" [$(format_remaining "$exp_ts")]"
            elif [[ -n "$exp_ts" ]]; then
                exp_str=" [expiry corrupted]"
            fi
        fi

        if [[ $verbose -eq 1 ]]; then
            printf "%-18s | %-5s | %-5s | %-15s | %-30s | %-17s | %-15s | ${color_start}%s${color_end}%s\n" "$name" "$cf" "$png" "$ip" "$ipv6" "$p2p" "$pk" "$st" "$exp_str"
        else
            printf "%-18s | %-15s | %-17s | ${color_start}%s${color_end}%s\n" "$name" "$ip" "$p2p" "$st" "$exp_str"
        fi
    done <<< "$clients"

    if [[ "$JSON_OUTPUT" -eq 1 ]]; then
        ( IFS=","; echo "[${json_entries[*]}]" )
    else
        echo ""
        log "Total clients: $tot, Active/Recent: $act"
    fi
}

# ==============================================================================
# Traffic statistics
# ==============================================================================

# Escape string for safe JSON inclusion
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Format bytes to human-readable
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
            log "No clients found."
        fi
        return 0
    fi

    # Get awg show data
    local awg_dump
    awg_dump=$(awg show awg0 dump 2>/dev/null) || {
        log_error "Failed to get awg show data."
        return 1
    }

    # Map: public key -> client name (single-pass)
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
    # date +%s once before the loop (instead of a subprocess per peer);
    # one-second snapshot precision is enough for active/recent statuses.
    local _stats_now
    _stats_now=$(date +%s)

    # awg show dump: each peer line = pubkey psk endpoint allowed-ips latest-handshake rx tx keepalive
    # shellcheck disable=SC2034
    while IFS=$'\t' read -r pk psk ep aips handshake rx tx keepalive; do
        local cname="${pk_to_name[$pk]:-unknown}"
        if [[ "$cname" == "unknown" ]]; then continue; fi

        local ip="-" ipv6="-" p2p="-"
        ip=$(get_client_ipv4_from_server "$cname" 2>/dev/null || echo "-")
        ipv6=$(get_client_ipv6_from_server "$cname" 2>/dev/null || echo "-")
        p2p=$(get_peer_p2p_ports "$cname" 2>/dev/null)
        [[ -n "$p2p" ]] || p2p="-"

        local hs_str="never"
        local status="Inactive" status_code="inactive"
        if [[ "$handshake" =~ ^[0-9]+$ && "$handshake" -gt 0 ]]; then
            local diff=$((_stats_now - handshake))
            if [[ $diff -lt 180 ]]; then
                status="Active"; status_code="active"
            elif [[ $diff -lt 86400 ]]; then
                status="Recent"; status_code="recent"
            fi
            hs_str=$(date -d "@$handshake" '+%F %T' 2>/dev/null || echo "$handshake")
        fi

        total_rx=$((total_rx + rx))
        total_tx=$((total_tx + tx))

        if [[ "$JSON_OUTPUT" -eq 1 ]]; then
            json_entries+=("{\"name\":\"$(json_escape "$cname")\",\"ip\":\"$(json_escape "$ip")\",\"ipv6\":\"$(json_escape "$ipv6")\",\"p2p_ports\":\"$(json_escape "$p2p")\",\"rx\":$rx,\"tx\":$tx,\"last_handshake\":$handshake,\"status\":\"$(json_escape "$status")\"}")
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
        log "Client traffic statistics:"
        echo ""
        printf "%-15s | %-15s | %-28s | %-15s | %-12s | %-12s | %-19s | %s\n" "Name" "IPv4" "IPv6" "P2P" "Received" "Sent" "Last handshake" "Status"
        printf -- "-%.0s" {1..140}
        echo
        for row in "${table_rows[@]}"; do
            echo "$row"
        done
        echo ""
        log "Total: Received $(format_bytes "$total_rx"), Sent $(format_bytes "$total_tx")"
    fi
}


voice_check() {
    echo "== Public IP =="
    if command -v curl >/dev/null 2>&1; then
        curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null || echo "warning: could not determine public IPv4"
        echo
    else
        echo "warning: curl is not installed"
    fi
    echo "== Default route =="
    if command -v ip >/dev/null 2>&1; then ip route get 1.1.1.1 2>&1 || true; else echo "warning: ip is not installed"; fi
    echo "== AWG interfaces =="
    if command -v ip >/dev/null 2>&1; then ip -br addr 2>/dev/null | grep -E 'awg|wg|tun' || echo "warning: AWG/WG/TUN interfaces not found"; else echo "warning: ip is not installed"; fi
    echo "== UDP conntrack sysctl =="
    if command -v sysctl >/dev/null 2>&1; then
        sysctl net.netfilter.nf_conntrack_udp_timeout 2>&1 || true
        sysctl net.netfilter.nf_conntrack_udp_timeout_stream 2>&1 || true
        sysctl net.netfilter.nf_conntrack_max 2>&1 || true
    else
        echo "warning: sysctl is not installed"
    fi
    if [[ -r /proc/sys/net/netfilter/nf_conntrack_count ]]; then
        echo "nf_conntrack_count = $(cat /proc/sys/net/netfilter/nf_conntrack_count)"
    else
        echo "warning: nf_conntrack_count is unavailable"
    fi
    echo "== NAT rules =="
    if command -v nft >/dev/null 2>&1; then nft list ruleset 2>/dev/null | grep -Ei 'masquerade|snat|dnat|awg|10\.9\.9' || echo "warning: matching NAT rules not found"; else echo "warning: nft is not installed"; fi
    echo "== Recent UDP conntrack for AWG subnet =="
    if command -v conntrack >/dev/null 2>&1; then conntrack -L -p udp 2>/dev/null | grep -E '10\.9\.9\.' | tail -50 || echo "warning: recent AWG UDP conntrack entries not found"; else echo "warning: conntrack is not installed"; fi
    cat <<'EOF'
Run on client:
  stunclient stun.l.google.com 19302
  stunclient stun.cloudflare.com 3478
  stunclient stunserver2025.stunprotocol.org 3478

Expected:
  Mapped address = VPS public IP
EOF
}

# ==============================================================================
# Help
# ==============================================================================

usage() {
    # C1: explicit help (rc=0) -> stdout + exit 0; usage error (rc!=0, default)
    # -> stderr + exit 1. Explicit-help callers pass 0, error callers omit the
    # argument (get 1).
    local _rc="${1:-1}"
    [[ "$_rc" -ne 0 ]] && exec >&2
    echo ""
    echo "AmneziaWG 2.0 management script (v${SCRIPT_VERSION})"
    echo "=============================================="
    echo "Usage: $0 [OPTIONS] <COMMAND> [ARGUMENTS]"
    echo ""
    echo "Options:"
    echo "  -h, --help            Show this help"
    echo "  -v, --verbose         Verbose output (for list command)"
    echo "  --no-color            Disable colored output"
    echo "  --json                Machine-readable JSON output (for list / stats)"
    echo "  --expires=DURATION    Expiry time for add (1h, 12h, 1d, 7d, 30d, 4w)"
    echo "  --conf-dir=PATH       Specify AWG directory (default: $AWG_DIR)"
    echo "  --server-conf=PATH    Specify server config file"
    echo "  --apply-mode=MODE     syncconf (default) or restart (bypass kernel panic)"
    echo "  --psk                 (add only) generate a PresharedKey for the new client"
    echo "  --reset-routes        (regen only) reset client AllowedIPs to the current"
    echo "                        global routing mode (Issue #170)"
    echo "  --yes                 Skip confirm prompts (equivalent to ENV AWG_YES=1)"
    echo "  --carrier=NAME        (diagnose only) compare AWG params against carrier profile"
    echo "                        Available: beeline_msk yota_msk tele2_msk tele2_krasnoyarsk"
    echo "                                   tattelecom megafon_regions tmobile_us"
    echo ""
    echo "Commands:"
    echo "  add <name> [name2 ...]       Add client(s). --expires applies to all"
    echo "  remove <name> [name2 ...]    Remove client(s)"
    echo "  list [-v] [--json]    List clients (--json: machine-readable, includes client_ipv6)"
    echo "  stats [--json]        Client traffic statistics"
    echo "  diagnose [--carrier=N] Diagnose kernel/sysctl/UFW and fork-specific sections"
    echo "  voice-check           UDP/STUN/NAT diagnostics for calls"
    echo "  p2p list              Show P2P ports for all clients"
    echo "  p2p show <name>       Show client P2P information"
    echo "  p2p add <name> [port] Add P2P port (auto if omitted)"
    echo "  p2p remove <name> <port> Remove client P2P port"
    echo "  p2p toggle <name>     Enable/disable existing client P2P ports"
    echo "  ipv6 status           Show IPv6 mode"
    echo "  ipv6 upgrade          Add IPv6/P2P metadata to existing clients"
    echo "  ipv6 ndp status       Show NDP proxy (ndppd) diagnostics"
    echo "  ipv6 ndp install      Install ndppd and enable the service"
    echo "  ipv6 ndp generate [PREFIX]  Generate /etc/ndppd.conf for PREFIX (or AWG_IPV6_SUBNET)"
    echo "  ipv6 ndp enable       Install (if needed), enable+start ndppd"
    echo "  ipv6 ndp disable      Disable+stop ndppd"
    echo "  ipv6 ndp restart      Restart ndppd"
    echo "  ipv6 ndp fix          Fix auto/on-link mode, config, sysctl, and ndppd"
    echo "  dns status            Show DNS mode and AdGuard Home status"
    echo "  dns restart           Sync clients and restart AdGuard Home"
    echo "  dns sync-clients      Sync VPN clients into AdGuard Home"
    echo "  dns logs              Show recent AdGuard Home logs"
    echo "  dns set-mode <mode>   Change DNS: adguard, system, or custom [DNS]"
    echo "  geoip update-dbs      Download/update GeoIP MMDB databases (MaxMind GeoLite2, DB-IP)"
    echo "  geoip auto-update enable   Enable weekly GeoIP database auto-update"
    echo "  geoip auto-update disable  Disable GeoIP database auto-update"
    echo "  geoip auto-update status   Show GeoIP auto-update timer status"
    echo '  set-name "NAME"       Change server name and regenerate clients'
    echo "  server rotate-profile --preset mobile|default"
    echo "                        Rotate H/S/J/I1 AWG profile and regenerate clients"
    echo "  rotate-awg            Alias for server rotate-profile"
    echo "  refresh-server-config Alias for server rotate-profile"
    echo "  web token list        Show web panel tokens"
    echo "  web token create [--client NAME] [--name ALIAS]"
    echo "                        Create a user token and print its value"
    echo "  web token add [ALIAS] Compatibility alias for create --name ALIAS"
    echo "  web token revoke <hash> Revoke a user token"
    echo "  web token rotate <hash> Rotate a user token while preserving access"
    echo "  web token reset-super Regenerate the super token"
    echo "  web token check <token> Check a token without printing secrets"
    echo "  web token status Show token store status without secrets"
    echo "  web fix-nginx-startup Install systemd drop-in: nginx waits for awg0 VPN gateway"
    echo "  web nginx-wait-awg0   Alias for web fix-nginx-startup"
    echo "  regen <name>          Safely regenerate a client config and rotate keys"
    echo "  regenerate <name>     Alias for regen <name>"
    echo "  client regenerate <name> Same action via the client namespace"
    echo "  modify <name> <p> <v> Modify a client parameter"
    echo "  backup                Create a backup"
    echo "  restore [file]        Restore from backup"
    echo "  check | status        Check server status"
    echo "  diagnose [--carrier=N] Self-troubleshooting: kernel/sysctl/UFW + carrier comparison"
    echo "  show                  Show \`awg show\` status"
    echo "  restart               Restart AmneziaWG service"
    echo "  repair-module         Repair the kernel module after a kernel upgrade (alias: repair)"
    echo "                        (dkms autoinstall + modprobe + start awg-quick)"
    echo "  help                  Show this help"
    echo ""
    exit "$_rc"
}

# ==============================================================================
# Main logic
# ==============================================================================

if [[ -z "$COMMAND" ]]; then
    usage 1
fi
if [[ "$COMMAND" == "help" ]]; then
    usage "$HELP_EXIT_RC"
fi

check_dependencies || exit 1
cd "$AWG_DIR" || die "Failed to change to $AWG_DIR"

log "Running command '$COMMAND'..."
_cmd_rc=0

case $COMMAND in
    add)
        [[ ${#ARGS[@]} -eq 0 ]] && die "Client name not specified."

        # Make sure the amneziawg kernel module is loaded and awg-quick@awg0 is up.
        # Without it apply_config (awg syncconf) fails. See also 'manage repair-module'.
        # AWG_SKIP_APPLY=1 (offline/batch edit without apply): skip the module check —
        # apply_config will no-op anyway, and the command must work on a dev machine.
        if [[ "${AWG_SKIP_APPLY:-0}" != "1" ]]; then
            # rc=2 (module OK, service did not start) does not block add: the
            # config gets written and apply_config reports the failure itself.
            ensure_amneziawg_kernel_module; _mod_rc=$?
            if [[ "$_mod_rc" -eq 1 ]]; then
                die "amneziawg kernel module unavailable. Run 'manage repair-module' and try again."
            elif [[ "$_mod_rc" -eq 2 ]]; then
                log_warn "awg-quick@awg0 service is not active - the config will be written but may not be applied."
            fi
        fi

        # --psk: enable optional PresharedKey for every new client.
        # Export CLIENT_PSK="auto" -> generate_client produces a fresh
        # 32-byte PSK via `awg genpsk` for each client in the batch
        # (distinct PSK per client).
        if [[ "${CLI_ADD_PSK:-0}" == "1" ]]; then
            export CLIENT_PSK="auto"
            log "PresharedKey will be generated for each new client (--psk)."
        fi

        # Validate --expires ONCE before creating the first client. Otherwise a
        # bad format (--expires=bad) created permanent clients while
        # set_client_expiry failed silently per-client - a temporary client
        # quietly became permanent. A bad format now aborts before any change.
        if [[ -n "$EXPIRES_DURATION" ]]; then
            parse_duration "$EXPIRES_DURATION" >/dev/null \
                || die "Invalid --expires='$EXPIRES_DURATION'. Use: 1h, 12h, 1d, 7d, 30d, 4w."
        fi

        _added=0
        for _cname in "${ARGS[@]}"; do
            validate_client_name "$_cname" || { _cmd_rc=1; continue; }

            if grep -qxF "#_Name = ${_cname}" "$SERVER_CONF_FILE"; then
                # _cmd_rc=1 - parity with remove ("No clients to remove") and
                # regen ("not found, skipping"): a no-op for this name must be
                # distinguishable via the exit code for automation (Issue #175).
                log_warn "Client '$_cname' already exists, skipping."
                _cmd_rc=1
                continue
            fi

            # In batch mode each client gets its own PSK: reset to "auto"
            # so generate_client generates a new one every iteration.
            if [[ "${CLI_ADD_PSK:-0}" == "1" ]]; then
                export CLIENT_PSK="auto"
            fi

            log "Adding '$_cname'..."
            if generate_client "$_cname"; then
                log "Client '$_cname' added."
                # Mention .png only if the QR was actually created (qrencode
                # may be absent) - symmetric to the .vpnuri check below.
                if [[ -f "$AWG_DIR/${_cname}.png" ]]; then
                    log "Files: $AWG_DIR/${_cname}.conf, $AWG_DIR/${_cname}.png"
                else
                    log "Files: $AWG_DIR/${_cname}.conf"
                fi
                if [[ -f "$AWG_DIR/${_cname}.vpnuri" ]]; then
                    log "vpn:// URI: $AWG_DIR/${_cname}.vpnuri"
                fi
                if [[ -n "$EXPIRES_DURATION" ]]; then
                    if set_client_expiry "$_cname" "$EXPIRES_DURATION"; then
                        install_expiry_cron || { log_error "Client '$_cname' created with an expiry, but the auto-removal cron was NOT installed - the expired client will not be removed automatically."; _cmd_rc=1; }
                    else
                        # Format is validated above, so this is a write failure
                        # (FS/permissions). The client exists and works but has NO
                        # auto-expiry - signal it so a temporary client does not
                        # silently stay permanent.
                        log_error "Client '$_cname' created, but expiry was NOT set (expiry write error). The client is permanent - set the expiry again or remove it."
                        _cmd_rc=1
                    fi
                fi
                ((_added++))
            else
                log_error "Error adding client '$_cname'."
                _cmd_rc=1
            fi
        done

        if [[ $_added -gt 0 ]]; then
            if [[ "${AWG_SKIP_APPLY:-0}" == "1" ]]; then
                apply_config
                log "Clients added: $_added. Apply deferred (AWG_SKIP_APPLY=1)."
            elif apply_config; then
                log "Clients added: $_added. Configuration applied."
            else
                log_error "Clients added: $_added, but apply_config failed. Config written but NOT applied to live interface. Check: systemctl status awg-quick@awg0"
                _cmd_rc=1
            fi
        fi
        # Hygiene: do not let CLIENT_PSK leak into later operations
        unset CLIENT_PSK
        ;;

    remove)
        [[ ${#ARGS[@]} -eq 0 ]] && die "Client name not specified."

        # Validate all names before removing
        _valid_names=()
        for _rname in "${ARGS[@]}"; do
            validate_client_name "$_rname" || { _cmd_rc=1; continue; }
            if ! grep -qxF "#_Name = ${_rname}" "$SERVER_CONF_FILE"; then
                log_warn "Client '$_rname' not found, skipping."
                continue
            fi
            _valid_names+=("$_rname")
        done

        if [[ ${#_valid_names[@]} -eq 0 ]]; then
            log_error "No clients to remove."
            _cmd_rc=1
        else
            # Confirmation
            if [[ ${#_valid_names[@]} -eq 1 ]]; then
                if ! confirm_action "remove" "client '${_valid_names[0]}'"; then exit 1; fi
            else
                if ! confirm_action "remove" "${#_valid_names[@]} clients"; then exit 1; fi
            fi

            # Ensure module is loaded before any mutations (apply_config / awg syncconf).
            # AWG_SKIP_APPLY=1 (offline/batch edit without apply): skip the module check —
            # apply_config will no-op anyway, and the command must work on a dev machine.
            if [[ "${AWG_SKIP_APPLY:-0}" != "1" ]]; then
                # rc=2 (module OK, service did not start) does not block remove -
                # symmetric with add: apply_config reports the failure itself.
                ensure_amneziawg_kernel_module; _mod_rc=$?
                if [[ "$_mod_rc" -eq 1 ]]; then
                    die "amneziawg kernel module unavailable. Run 'manage repair-module' and try again."
                elif [[ "$_mod_rc" -eq 2 ]]; then
                    log_warn "awg-quick@awg0 service is not active - the config will be written but may not be applied."
                fi
            fi

            _removed=0
            for _rname in "${_valid_names[@]}"; do
                log "Removing '$_rname'..."
                [[ -x "$AWG_DIR/p2p_rules.sh" ]] && bash "$AWG_DIR/p2p_rules.sh" down 2>/dev/null || true
                if remove_peer_from_server "$_rname"; then
                    _remove_client_files "$_rname"
                    remove_client_expiry "$_rname"
                    log "Client '$_rname' removed."
                    ((_removed++))
                else
                    log_error "Error removing '$_rname'."
                    _cmd_rc=1
                fi
            done

            if [[ $_removed -gt 0 ]]; then
                bash "$AWG_DIR/postup.sh" 2>/dev/null || log_warn "Failed to apply firewall hooks live; restart awg-quick@awg0 if needed."
                [[ -n "${_CLI_APPLY_MODE:-}" ]] && export AWG_APPLY_MODE="$_CLI_APPLY_MODE"
                if [[ "${AWG_SKIP_APPLY:-0}" == "1" ]]; then
                    apply_config
                    log "Clients removed: $_removed. Apply deferred (AWG_SKIP_APPLY=1)."
                elif apply_config; then
                    log "Clients removed: $_removed. Configuration applied."
                else
                    log_error "Clients removed: $_removed, but apply_config failed. Peers removed from config but may still be present on live interface. Check: systemctl status awg-quick@awg0"
                    _cmd_rc=1
                fi
            fi
        fi
        ;;

    toggle)
        [[ -z "$CLIENT_NAME" ]] && die "Client name not specified."
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
                printf "%-20s | %s\n" "Client" "P2P ports"
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
                [[ -z "$_name" ]] && die "Client name is required."
                validate_client_name "$_name" || exit 1
                if ! grep -qxF "#_Name = ${_name}" "$SERVER_CONF_FILE"; then die "Client '$_name' not found."; fi
                log "Client: $_name"
                log "IPv4: $(get_client_ipv4_from_server "$_name" 2>/dev/null || echo '-')"
                log "IPv6: $(get_client_ipv6_from_server "$_name" 2>/dev/null || echo '-')"
                log "P2P ports: $(get_peer_p2p_ports "$_name" 2>/dev/null || echo '-')"
                ;;
            add)
                _name="${ARGS[1]:-}"; _port="${ARGS[2]:-}"
                [[ -z "$_name" ]] && die "Client name is required."
                validate_client_name "$_name" || exit 1
                if [[ "${AWG_SKIP_APPLY:-0}" != "1" ]]; then
                    ensure_amneziawg_kernel_module || die "AmneziaWG kernel module is unavailable."
                fi
                if _new_port=$(add_p2p_port_to_peer "$_name" "$_port"); then
                    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q active; then
                        ufw allow "${_new_port}/tcp" comment "AmneziaWG P2P TCP" >/dev/null 2>&1 || log_warn "Failed to open P2P TCP port $_new_port in UFW."
                        ufw allow "${_new_port}/udp" comment "AmneziaWG P2P UDP" >/dev/null 2>&1 || log_warn "Failed to open P2P UDP port $_new_port in UFW."
                    fi
                    bash "$AWG_DIR/postup.sh" 2>/dev/null || log_warn "Failed to apply firewall hooks live; restart awg-quick@awg0 if needed."
                    log "P2P port $_new_port added to client '$_name'."
                else
                    _cmd_rc=1
                fi
                ;;
            remove)
                _name="${ARGS[1]:-}"; _port="${ARGS[2]:-}"
                [[ -z "$_name" || -z "$_port" ]] && die "Usage: p2p remove <name> <port>"
                validate_client_name "$_name" || exit 1
                [[ -x "$AWG_DIR/p2p_rules.sh" ]] && bash "$AWG_DIR/p2p_rules.sh" down 2>/dev/null || true
                if remove_p2p_port_from_peer "$_name" "$_port"; then
                    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q active; then
                        ufw delete allow "${_port}/tcp" >/dev/null 2>&1 || true
                        ufw delete allow "${_port}/udp" >/dev/null 2>&1 || true
                    fi
                    bash "$AWG_DIR/postup.sh" 2>/dev/null || log_warn "Failed to apply firewall hooks live; restart awg-quick@awg0 if needed."
                    log "P2P port $_port removed from client '$_name'."
                else
                    _cmd_rc=1
                fi
                ;;
            toggle)
                _name="${ARGS[1]:-}"
                [[ -z "$_name" ]] && die "Usage: p2p toggle <name>"
                validate_client_name "$_name" || exit 1
                if ! grep -qxF "#_Name = ${_name}" "$SERVER_CONF_FILE"; then die "Client '$_name' not found."; fi

                _lockfile="${AWG_DIR}/.awg_config.lock"
                exec {_lock_fd}>"$_lockfile"
                if ! flock -x -w 10 "$_lock_fd"; then
                    log_error "Failed to acquire config lock"
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
                        log_error "Client '$_name' has no P2P ports."
                        _cmd_rc=1
                    else
                        _p2p_line="${_p2p_state%%:*}"
                        _p2p_mode="${_p2p_state#*:}"
                        if [[ "$_p2p_mode" == "enabled" ]]; then
                            sed -i "${_p2p_line}s/^#_P2PPorts[[:space:]]*=[[:space:]]*/#_P2PPorts_Disabled = /" "$SERVER_CONF_FILE" || _cmd_rc=1
                            _p2p_next="disabled"
                        else
                            sed -i "${_p2p_line}s/^#_P2PPorts_Disabled[[:space:]]*=[[:space:]]*/#_P2PPorts = /" "$SERVER_CONF_FILE" || _cmd_rc=1
                            _p2p_next="enabled"
                        fi
                        [[ "$_cmd_rc" -eq 0 ]] && chmod 600 "$SERVER_CONF_FILE"
                    fi
                    exec {_lock_fd}>&-
                fi
                if [[ "$_cmd_rc" -eq 0 ]]; then
                    generate_firewall_scripts >/dev/null 2>&1 || log_warn "Failed to update P2P/firewall hook scripts."
                    bash "$AWG_DIR/postdown.sh" 2>/dev/null || true
                    bash "$AWG_DIR/postup.sh" 2>/dev/null || log_warn "Failed to apply firewall hooks live; restart awg-quick@awg0 if needed."
                    log "Client P2P ports '$_name' $_p2p_next."
                fi
                ;;
            *)
                die "Unknown p2p command: $_sub"
                ;;
        esac
        ;;

    rotate-profile)
        case "${ROTATE_PRESET:-default}" in
            mobile|default) ;;
            *) die "Invalid --preset. Allowed: mobile or default" ;;
        esac
        if ! confirm_action "rotate AWG profile" "and regenerate all client configs"; then exit 1; fi
        if [[ "${AWG_SKIP_APPLY:-0}" != "1" ]]; then
            ensure_amneziawg_kernel_module \
                || die "amneziawg kernel module unavailable. Run 'manage repair-module' and try again."
        fi
        server_rotate_profile "$ROTATE_PRESET" || _cmd_rc=1
        ;;

    ipv6)
        safe_load_config "$CONFIG_FILE" 2>/dev/null || true
        _sub="${ARGS[0]:-status}"
        case "$_sub" in
            status)
                log "IPv6 enabled: ${AWG_IPV6_ENABLED:-0}"
                log "IPv6 mode: $(awg_ipv6_mode)"
                log "IPv6 subnet: ${AWG_IPV6_SUBNET:-}"
                log "NDP proxy: ${AWG_IPV6_NDP_PROXY:-0}"
                log "NDP state: $(ipv6_ndp_state)"
                ;;
            ndp)
                _ndp_sub="${ARGS[1]:-status}"
                case "$_ndp_sub" in
                    status)
                        ipv6_ndp_print_status
                        ;;
                    generate)
                        ipv6_ndp_generate_config "${ARGS[2]:-}"
                        ;;
                    enable)
                        ipv6_ndp_enable
                        ;;
                    install)
                        ipv6_ndp_enable
                        ;;
                    disable)
                        ipv6_ndp_disable
                        ;;
                    restart)
                        ipv6_ndp_restart
                        ;;
                    fix)
                        ipv6_ndp_fix
                        ;;
                    *)
                        die "Unknown ipv6 ndp command: $_ndp_sub"
                        ;;
                esac
                ;;
            upgrade)
                if [[ "${AWG_IPV6_ENABLED:-0}" != "1" || -z "${AWG_IPV6_SUBNET:-}" ]]; then
                    die "IPv6 is not enabled in $CONFIG_FILE. Run install_amneziawg_en.sh --upgrade-ipv6."
                fi
                if upgrade_existing_peers_ipv6_p2p 1 1; then
                    _count=0
                    while IFS= read -r _name; do
                        [[ -n "$_name" ]] || continue
                        refresh_client_config "$_name" || { log_warn "Refresh error '$_name'"; _cmd_rc=1; }
                        _count=$((_count + 1))
                    done < <(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //')
                    bash "$AWG_DIR/postup.sh" 2>/dev/null || log_warn "Failed to apply firewall hooks live; restart awg-quick@awg0 if needed."
                    log "IPv6/P2P upgrade completed. Processed clients: $_count."
                else
                    _cmd_rc=1
                fi
                ;;
            *)
                die "Unknown ipv6 command: $_sub"
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
                    log "Clients synced, AdGuard Home restarted."
                else
                    log_warn "AdGuard Home did not restart or clients were not synced. VPN was not changed."
                    _cmd_rc=1
                fi
                ;;
            sync-clients)
                sync_clients_hosts
                systemctl stop AdGuardHome.service 2>/dev/null || true
                if sync_adguard_clients && systemctl start AdGuardHome.service; then
                    log "Clients synced into AdGuard Home."
                else
                    log_warn "Failed to sync AdGuard Home clients. VPN was not changed."
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
                die "Unknown dns command: $_sub"
                ;;
        esac
        ;;

    geoip)
        _sub="${ARGS[0]:-update-dbs}"
        case "$_sub" in
            update-dbs)
                if geoip_update_dbs; then
                    log "GeoIP databases updated."
                else
                    log_warn "Failed to update one or more GeoIP databases."
                    _cmd_rc=1
                fi
                ;;
            auto-update)
                _au_sub="${ARGS[1]:-status}"
                case "$_au_sub" in
                    enable)
                        geoip_auto_update_enable || _cmd_rc=1
                        ;;
                    disable)
                        geoip_auto_update_disable || _cmd_rc=1
                        ;;
                    status)
                        geoip_auto_update_status
                        ;;
                    *)
                        die "Unknown geoip auto-update command: $_au_sub"
                        ;;
                esac
                ;;
            *)
                die "Unknown geoip command: $_sub"
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
        case "$_sub" in
            fix-nginx-startup|nginx-wait-awg0)
                safe_load_config "$CONFIG_FILE" 2>/dev/null || true
                install_nginx_awg0_wait_dropin "${AWG_NGINX_WAIT_IFACE:-awg0}" "${AWG_NGINX_WAIT_IP:-${AWG_WEB_BIND:-${AWG_TUNNEL_SUBNET%/*}}}" "${AWG_NGINX_WAIT_TIMEOUT:-90}" || _cmd_rc=1
                ;;
            token)
                _token_cmd="${ARGS[1]:-list}"
                case "$_token_cmd" in
            list)
                web_token_py "list" || _cmd_rc=1
                ;;
            create|add)
                _token_name=""
                _token_clients=()
                if [[ "$_token_cmd" == "add" && -n "${ARGS[2]:-}" && "${ARGS[2]:0:2}" != "--" ]]; then
                    _token_name="${ARGS[2]}"
                    _idx=3
                else
                    _idx=2
                fi
                while [[ $_idx -lt ${#ARGS[@]} ]]; do
                    case "${ARGS[$_idx]}" in
                        --name)
                            _idx=$((_idx + 1))
                            [[ $_idx -lt ${#ARGS[@]} ]] || die "Usage: web token create --name ALIAS"
                            _token_name="${ARGS[$_idx]}"
                            ;;
                        --name=*)
                            _token_name="${ARGS[$_idx]#--name=}"
                            ;;
                        --client)
                            _idx=$((_idx + 1))
                            [[ $_idx -lt ${#ARGS[@]} ]] || die "Usage: web token create --client NAME"
                            _token_clients+=("${ARGS[$_idx]}")
                            ;;
                        --client=*)
                            _token_clients+=("${ARGS[$_idx]#--client=}")
                            ;;
                        *)
                            die "Unknown web token create argument: ${ARGS[$_idx]}"
                            ;;
                    esac
                    _idx=$((_idx + 1))
                done
                _clients_csv="$(IFS=,; echo "${_token_clients[*]}")"
                web_token_py "add" "$_token_name" "$_clients_csv" || _cmd_rc=1
                ;;
            revoke)
                [[ -z "${ARGS[2]:-}" ]] && die "Usage: web token revoke <hash>"
                web_token_py "revoke" "${ARGS[2]}" || _cmd_rc=1
                ;;
            rotate)
                [[ -z "${ARGS[2]:-}" ]] && die "Usage: web token rotate <hash>"
                web_token_py "rotate" "${ARGS[2]}" || _cmd_rc=1
                ;;
            reset-super)
                web_token_py "reset-super" || _cmd_rc=1
                ;;
            check)
                [[ -z "${ARGS[2]:-}" ]] && die "Usage: web token check <token>"
                web_token_py "check" "${ARGS[2]}" || _cmd_rc=1
                ;;
            status)
                web_token_py "status" || _cmd_rc=1
                ;;
            *)
                die "Unknown web token command: $_token_cmd"
                ;;
                esac
                ;;
            *)
                die "Usage: web token list|create [--client NAME] [--name ALIAS]|add [ALIAS]|revoke <hash>|rotate <hash>|reset-super|check <token>|status|fix-nginx-startup|nginx-wait-awg0"
                ;;
        esac
        ;;

    regen)
        log "Regenerating config and QR files..."
        # --reset-routes (Issue #170): pass the flag to regenerate_client via
        # ENV - a regular regen preserves per-client AllowedIPs, with the flag
        # every client gets the global routing mode from awgsetup_cfg.init.
        if [[ "${CLI_RESET_ROUTES:-0}" == "1" ]]; then
            export AWG_REGEN_RESET_ROUTES=1
            log "AllowedIPs of all regenerated clients will be reset to the global routing mode (--reset-routes)."
        fi
        if [[ ${#ARGS[@]} -eq 0 ]]; then
            # No arguments — regenerate all clients (preserves prior behaviour).
            all_clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //')
            if [[ -z "$all_clients" ]]; then
                log "No clients found."
            else
                while IFS= read -r cname; do
                    cname="${cname## }"; cname="${cname%% }"
                    [[ -z "$cname" ]] && continue
                    log "Regenerating '$cname'..."
                    regenerate_client "$cname" || { log_warn "Regeneration error '$cname'"; _cmd_rc=1; }
                done <<< "$all_clients"
                log "Regeneration completed."
            fi
        else
            # With arguments — process each name individually (parity with add/remove).
            # Until v5.11.5 only $CLIENT_NAME (=ARGS[0]) was read here, the rest were
            # silently dropped (Issue #70).
            _regen_count=0
            for _cname in "${ARGS[@]}"; do
                validate_client_name "$_cname" || { _cmd_rc=1; continue; }
                if ! grep -qxF "#_Name = ${_cname}" "$SERVER_CONF_FILE"; then
                    log_warn "Client '$_cname' not found, skipping."
                    _cmd_rc=1
                    continue
                fi
                log "Regenerating '$_cname'..."
                if regenerate_client "$_cname"; then
                    _regen_count=$((_regen_count + 1))
                else
                    log_error "Regeneration error '$_cname'."
                    _cmd_rc=1
                fi
            done
            if [[ $_regen_count -gt 0 ]]; then
                log "Regeneration completed. Processed: $_regen_count of ${#ARGS[@]}."
            fi
        fi
        ;;

    modify)
        [[ -z "$CLIENT_NAME" ]] && die "Client name not specified."
        validate_client_name "$CLIENT_NAME" || exit 1
        modify_client "$CLIENT_NAME" "$PARAM" "$VALUE" || _cmd_rc=1
        ;;

    backup)
        backup_configs || _cmd_rc=1
        ;;

    restore)
        restore_backup "$CLIENT_NAME" || _cmd_rc=1 # CLIENT_NAME is used as [file]
        ;;

    check|status)
        check_server || _cmd_rc=1
        ;;

    show)
        log "AmneziaWG 2.0 status..."
        if ! awg show; then log_error "awg show error."; _cmd_rc=1; fi
        ;;

    restart)
        log "Restarting service..."
        if ! confirm_action "restart" "service"; then exit 1; fi
        # Verify kernel module is loaded before systemctl restart (mode=module-only —
        # the restart below starts the unit explicitly, so an extra start from ensure
        # would be redundant).
        ensure_amneziawg_kernel_module module-only \
            || die "amneziawg kernel module unavailable. Run 'manage repair-module' and try again."
        if ! systemctl restart awg-quick@awg0; then
            log_error "Restart error."
            status_out=$(systemctl status awg-quick@awg0 --no-pager 2>&1) || true
            while IFS= read -r line; do log_error "  $line"; done <<< "$status_out"
            exit 1
        else
            log "Service restarted."
        fi
        ;;

    repair-module|repair)
        # Explicit user-facing command: after a kernel upgrade the module may
        # need a DKMS rebuild. Allow apt-installing kernel headers here
        # (AWG_ALLOW_APT_IN_ENSURE=1) — the user explicitly requested repair.
        log "Repairing amneziawg kernel module (may take up to 5 minutes — DKMS rebuild)..."
        AWG_ALLOW_APT_IN_ENSURE=1 ensure_amneziawg_kernel_module full; _mod_rc=$?
        case "$_mod_rc" in
            0)
                log "amneziawg kernel module repaired, awg-quick@awg0 service is active."
                ;;
            2)
                # Previously this case masqueraded as success: "service is
                # active" + exit 0 while the service was down (Issue #175).
                log_error "The kernel module is fine, but the awg-quick@awg0 service did NOT start."
                log_error "Diagnostics: systemctl status awg-quick@awg0; journalctl -u awg-quick@awg0 -n 50"
                _cmd_rc=1
                ;;
            *)
                log_error "Could not repair the kernel module. See log above; manual recovery may be required."
                _cmd_rc=1
                ;;
        esac
        ;;

    diagnose)
        diagnose_server || _cmd_rc=1
        ;;

    # No help) branch here on purpose: every path that sets COMMAND="help"
    # (-h/--help, unknown option, positional help) is intercepted BEFORE the
    # dispatcher by the early `usage` (which terminates the process via exit).

    *)
        log_error "Unknown command: '$COMMAND'"
        _cmd_rc=1
        usage
        ;;
esac

log "Management script finished."
exit $_cmd_rc
