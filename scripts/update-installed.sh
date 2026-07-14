#!/usr/bin/env bash
# Safely update an existing BAS AmneziaWG installation from the latest stable release.
set -Eeuo pipefail

AWG_DIR="${AWG_DIR:-/root/awg}"
SERVER_CONF_FILE="${SERVER_CONF_FILE:-/etc/amnezia/amneziawg/awg0.conf}"
AWG_REPO="${AWG_REPO:-Basil-AS/amneziawg-installer}"
BACKUP_ROOT="${AWG_UPDATE_BACKUP_ROOT:-/root/awg-update-backups}"
LOCK_FILE="${AWG_UPDATE_LOCK_FILE:-/run/lock/awg-project-update.lock}"
SYSTEMD_DIR="${AWG_SYSTEMD_DIR:-/etc/systemd/system}"
KEEP_BACKUPS="${AWG_UPDATE_KEEP_BACKUPS:-5}"
MODE="update"
TARGET_TAG=""
WORK_DIR=""
SNAPSHOT_DIR=""
MUTATION_STARTED=0
UPDATE_OK=0
WEB_WAS_ACTIVE=0
ADGUARD_WAS_ACTIVE=0

log() { printf '[awg-update] %s\n' "$*"; }
warn() { printf '[awg-update] WARNING: %s\n' "$*" >&2; }
die() { printf '[awg-update] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: update-installed.sh [options]

Safely update an existing BAS AmneziaWG installation from a stable GitHub release.

Options:
  --check             Report the installed and latest stable versions; change nothing.
  --dry-run           Download and fully validate the update; change nothing.
  --version TAG       Update to a specific stable release tag instead of latest.
  --repo OWNER/REPO   Override the release repository.
  --install-timer     Install and enable the weekly safe-update systemd timer.
  --remove-timer      Disable and remove the safe-update systemd timer.
  --keep-backups N    Keep N successful update snapshots (default: 5).
  -h, --help          Show this help.

The updater never regenerates keys, peers, client configs, firewall hooks, AdGuard data,
or access tokens. A failed post-update health check automatically restores old files.
EOF
}

cleanup() {
    local rc=$?
    if [[ "$MUTATION_STARTED" -eq 1 && "$UPDATE_OK" -eq 0 && -n "$SNAPSHOT_DIR" ]]; then
        warn "Update failed after files changed; starting automatic rollback."
        rollback_snapshot || warn "Automatic rollback was incomplete; inspect $SNAPSHOT_DIR manually."
    fi
    [[ -z "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"
    exit "$rc"
}

require_commands() {
    local cmd missing=0
    for cmd in awk bash chmod cp curl find flock grep install ip mkdir mktemp mv python3 \
        rm sha256sum sort sysctl systemctl tail tar; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            warn "Required command is missing: $cmd"
            missing=1
        fi
    done
    [[ "$missing" -eq 0 ]] || die "Install the missing commands before updating."
}

validate_repo() {
    [[ "$AWG_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
        || die "Invalid repository name: $AWG_REPO"
}

validate_tag() {
    [[ "$1" =~ ^v[0-9][0-9A-Za-z._+-]*$ ]] || die "Invalid release tag: $1"
}

latest_stable_tag() {
    curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 --retry 2 \
        "https://api.github.com/repos/${AWG_REPO}/releases/latest" \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tag_name", ""))'
}

installed_version() {
    if [[ -r "$AWG_DIR/VERSION" ]]; then
        tr -d '\r\n' < "$AWG_DIR/VERSION"
    else
        printf 'unknown\n'
    fi
}

installed_is_newer_than_target() {
    local installed target newest
    installed="$(installed_version)"
    target="${TARGET_TAG#v}"
    [[ "$installed" != "unknown" && "$installed" != "$target" ]] || return 1
    newest="$(printf '%s\n%s\n' "$installed" "$target" | sort -V | tail -n 1)"
    [[ "$newest" == "$installed" ]]
}

resolve_target_tag() {
    if [[ -z "$TARGET_TAG" ]]; then
        TARGET_TAG="$(latest_stable_tag)" || die "Cannot query the latest stable release."
    fi
    validate_tag "$TARGET_TAG"
}

download_release_bundle() {
    local version asset checksum_asset base expected actual listed_name
    version="${TARGET_TAG#v}"
    asset="amneziawg-update-${version}.tar.gz"
    checksum_asset="${asset}.sha256"
    base="https://github.com/${AWG_REPO}/releases/download/${TARGET_TAG}"
    WORK_DIR="$(mktemp -d -t awg-update.XXXXXXXX)" || die "Cannot create staging directory."

    log "Downloading verified update bundle for ${TARGET_TAG}..."
    curl -fsSL --proto '=https' --tlsv1.2 --max-time 120 --max-filesize 52428800 --retry 2 \
        -o "$WORK_DIR/$asset" "$base/$asset" \
        || die "Release bundle is unavailable. This release may predate safe updates."
    curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 --max-filesize 4096 --retry 2 \
        -o "$WORK_DIR/$checksum_asset" "$base/$checksum_asset" \
        || die "Release checksum is unavailable; refusing an unverified update."

    read -r expected listed_name < "$WORK_DIR/$checksum_asset" || die "Malformed checksum file."
    expected="${expected,,}"
    listed_name="${listed_name#\*}"
    [[ "$expected" =~ ^[0-9a-f]{64}$ && "$listed_name" == "$asset" ]] \
        || die "Malformed or mismatched checksum file."
    actual="$(sha256sum "$WORK_DIR/$asset" | awk '{print tolower($1)}')"
    [[ "$actual" == "$expected" ]] || die "Release bundle SHA256 mismatch."

    mkdir "$WORK_DIR/payload"
    extract_release_bundle "$WORK_DIR/$asset" "$WORK_DIR/payload"
}

extract_release_bundle() {
    local archive="$1" destination="$2"
    python3 - "$archive" "$destination" <<'PY'
import os
import pathlib
import sys
import tarfile

archive, destination = sys.argv[1:]
root = pathlib.Path(destination).resolve()
with tarfile.open(archive, "r:gz") as tf:
    seen = set()
    total_size = 0
    for member in tf.getmembers():
        name = member.name
        parts = pathlib.PurePosixPath(name).parts
        if not name or name.startswith("/") or ".." in parts or name in seen:
            raise SystemExit(f"unsafe or duplicate archive path: {name!r}")
        if not (member.isfile() or member.isdir()):
            raise SystemExit(f"unsupported archive entry type: {name!r}")
        total_size += member.size
        if len(seen) >= 64 or total_size > 100 * 1024 * 1024:
            raise SystemExit("archive exceeds safe file-count or expanded-size limits")
        target = (root / name).resolve()
        if os.path.commonpath((root, target)) != str(root):
            raise SystemExit(f"archive path escapes staging root: {name!r}")
        seen.add(name)
    tf.extractall(root)
PY
}

required_payload_files() {
    cat <<'EOF'
VERSION
install_amneziawg.sh
install_amneziawg_en.sh
awg_common.sh
awg_common_en.sh
manage_amneziawg.sh
manage_amneziawg_en.sh
scripts/update-installed.sh
scripts/update_geoip_dbs.py
web/server.py
web/index.html
web/style.css
web/app.js
web/awg_i1.js
web/favicon.svg
web/vendor/tailwindcss.js
web/vendor/apexcharts.min.js
EOF
}

validate_payload() {
    local rel payload_version
    while IFS= read -r rel; do
        [[ -f "$WORK_DIR/payload/$rel" ]] || die "Required release file is missing: $rel"
    done < <(required_payload_files)

    payload_version="$(tr -d '\r\n' < "$WORK_DIR/payload/VERSION")"
    [[ "v$payload_version" == "$TARGET_TAG" ]] \
        || die "Bundle VERSION ($payload_version) does not match release tag ($TARGET_TAG)."

    for rel in install_amneziawg.sh install_amneziawg_en.sh awg_common.sh awg_common_en.sh \
        manage_amneziawg.sh manage_amneziawg_en.sh scripts/update-installed.sh; do
        bash -n "$WORK_DIR/payload/$rel" || die "Bash syntax validation failed: $rel"
    done
    python3 - "$WORK_DIR/payload/web/server.py" "$WORK_DIR/payload/scripts/update_geoip_dbs.py" <<'PY'
import ast
import pathlib
import sys
for raw in sys.argv[1:]:
    path = pathlib.Path(raw)
    ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
PY
    log "Release payload passed archive, version, Bash, and Python validation."
}

validate_server_config() {
    [[ -s "$SERVER_CONF_FILE" ]] || die "Server config is missing or empty: $SERVER_CONF_FILE"
    if command -v awg-quick >/dev/null 2>&1; then
        awg-quick strip awg0 >/dev/null || die "Current awg0 config does not pass awg-quick validation."
    fi
}

health_check() {
    local hook
    validate_server_config
    systemctl is-active --quiet awg-quick@awg0 \
        || die "awg-quick@awg0 is not active."
    ip link show awg0 >/dev/null 2>&1 || die "awg0 network interface is missing."
    [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]] \
        || die "IPv4 forwarding is disabled."
    if command -v awg >/dev/null 2>&1; then
        awg show awg0 >/dev/null || die "Cannot read live awg0 state."
    fi
    for hook in "$AWG_DIR/postup.sh" "$AWG_DIR/postdown.sh" "$AWG_DIR/p2p_rules.sh"; do
        [[ ! -f "$hook" ]] || bash -n "$hook" || die "Generated hook has invalid Bash syntax: $hook"
    done
    if ip -6 addr show dev awg0 scope global 2>/dev/null | grep -q 'inet6 '; then
        [[ "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null)" == "1" ]] \
            || die "IPv6 is configured on awg0 but IPv6 forwarding is disabled."
    fi
    if [[ "$WEB_WAS_ACTIVE" -eq 1 ]]; then
        systemctl is-active --quiet awg-web.service || die "awg-web.service is not active."
    fi
    if [[ "$ADGUARD_WAS_ACTIVE" -eq 1 ]]; then
        systemctl is-active --quiet AdGuardHome.service || die "AdGuardHome.service is not active."
    fi
}

destination_for() {
    case "$1" in
        VERSION) printf '%s/VERSION\n' "$AWG_DIR" ;;
        install_amneziawg.sh|install_amneziawg_en.sh|awg_common.sh|awg_common_en.sh|manage_amneziawg.sh|manage_amneziawg_en.sh)
            printf '%s/%s\n' "$AWG_DIR" "$1" ;;
        scripts/update-installed.sh) printf '%s/update-installed.sh\n' "$AWG_DIR" ;;
        scripts/update_geoip_dbs.py) printf '%s/scripts/update_geoip_dbs.py\n' "$AWG_DIR" ;;
        web/*) printf '%s/%s\n' "$AWG_DIR" "$1" ;;
        *) die "Internal error: unapproved payload path: $1" ;;
    esac
}

mode_for() {
    case "$1" in
        *.sh) printf '700\n' ;;
        scripts/*.py) printf '755\n' ;;
        *) printf '644\n' ;;
    esac
}

snapshot_targets() {
    local timestamp rel destination
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$BACKUP_ROOT" || die "Cannot create rollback backup root."
    SNAPSHOT_DIR="$(mktemp -d "$BACKUP_ROOT/${timestamp}.XXXXXXXX")" \
        || die "Cannot create rollback snapshot."
    mkdir -p "$SNAPSHOT_DIR/root" || die "Cannot initialize rollback snapshot."
    chmod 700 "$BACKUP_ROOT" "$SNAPSHOT_DIR" "$SNAPSHOT_DIR/root"
    : > "$SNAPSHOT_DIR/missing"
    while IFS= read -r rel; do
        destination="$(destination_for "$rel")"
        if [[ -e "$destination" ]]; then
            cp -a --parents "$destination" "$SNAPSHOT_DIR/root" \
                || die "Cannot snapshot $destination"
        else
            printf '%s\n' "$destination" >> "$SNAPSHOT_DIR/missing"
        fi
    done < <(required_payload_files)
    if [[ -e "$SYSTEMD_DIR/awg-web.service" ]]; then
        cp -a --parents "$SYSTEMD_DIR/awg-web.service" "$SNAPSHOT_DIR/root"
    else
        printf '%s\n' "$SYSTEMD_DIR/awg-web.service" >> "$SNAPSHOT_DIR/missing"
    fi
    cp -a --parents "$SERVER_CONF_FILE" "$SNAPSHOT_DIR/root"
    chmod -R go-rwx "$SNAPSHOT_DIR"
    log "Rollback snapshot: $SNAPSHOT_DIR"
}

atomic_install_file() {
    local source="$1" destination="$2" mode="$3" temp
    mkdir -p "$(dirname "$destination")"
    temp="$(mktemp "$(dirname "$destination")/.awg-update.XXXXXXXX")"
    install -m "$mode" "$source" "$temp"
    mv -f "$temp" "$destination"
}

update_web_unit_version() {
    local unit="$SYSTEMD_DIR/awg-web.service" version
    [[ -f "$unit" ]] || return 0
    version="${TARGET_TAG#v}"
    python3 - "$unit" "$version" <<'PY'
import os
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
version = sys.argv[2]
text = path.read_text(encoding="utf-8")
line = f'Environment="AWG_PROJECT_VERSION={version}"'
pattern = re.compile(r'^Environment=(?:"?)AWG_PROJECT_VERSION=.*$', re.MULTILINE)
if pattern.search(text):
    text = pattern.sub(line, text, count=1)
else:
    marker = "[Service]\n"
    if marker not in text:
        raise SystemExit("awg-web.service has no [Service] section")
    text = text.replace(marker, marker + line + "\n", 1)
tmp = path.with_name(path.name + f".tmp.{os.getpid()}")
tmp.write_text(text, encoding="utf-8")
os.chmod(tmp, 0o644)
os.replace(tmp, path)
PY
}

apply_payload() {
    local rel destination mode
    snapshot_targets
    MUTATION_STARTED=1
    if [[ "$WEB_WAS_ACTIVE" -eq 1 ]]; then
        systemctl stop awg-web.service
    fi
    while IFS= read -r rel; do
        destination="$(destination_for "$rel")"
        mode="$(mode_for "$rel")"
        atomic_install_file "$WORK_DIR/payload/$rel" "$destination" "$mode"
    done < <(required_payload_files)
    update_web_unit_version
    systemctl daemon-reload
    if [[ "$WEB_WAS_ACTIVE" -eq 1 ]]; then
        systemctl restart awg-web.service
    fi
}

rollback_snapshot() {
    local rel destination saved missing
    [[ -d "$SNAPSHOT_DIR/root" ]] || return 1
    while IFS= read -r rel; do
        destination="$(destination_for "$rel")"
        saved="$SNAPSHOT_DIR/root$destination"
        if [[ -e "$saved" ]]; then
            mkdir -p "$(dirname "$destination")"
            cp -a "$saved" "$destination"
        fi
    done < <(required_payload_files)
    saved="$SNAPSHOT_DIR/root$SYSTEMD_DIR/awg-web.service"
    [[ ! -e "$saved" ]] || cp -a "$saved" "$SYSTEMD_DIR/awg-web.service"
    while IFS= read -r missing; do
        [[ -z "$missing" ]] || rm -f -- "$missing"
    done < "$SNAPSHOT_DIR/missing"
    systemctl daemon-reload || true
    if [[ "$WEB_WAS_ACTIVE" -eq 1 ]]; then
        systemctl restart awg-web.service || return 1
    fi
    systemctl is-active --quiet awg-quick@awg0 || return 1
    log "Rollback completed from $SNAPSHOT_DIR"
}

prune_backups() {
    [[ "$KEEP_BACKUPS" =~ ^[0-9]+$ ]] || die "--keep-backups must be a non-negative integer."
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | awk -v keep="$KEEP_BACKUPS" 'NR > keep {sub(/^[^ ]+ /, ""); print}' \
        | while IFS= read -r old; do
            [[ "$old" == "$BACKUP_ROOT/"* ]] || continue
            rm -rf -- "$old"
        done
}

install_timer() {
    [[ "$EUID" -eq 0 ]] || die "Root is required to install the timer."
    [[ -x "$AWG_DIR/update-installed.sh" ]] || die "$AWG_DIR/update-installed.sh is not installed."
    cat > "$SYSTEMD_DIR/awg-project-update.service" <<EOF
[Unit]
Description=Safely update the BAS AmneziaWG project
After=network-online.target awg-quick@awg0.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$AWG_DIR/update-installed.sh
EOF
    cat > "$SYSTEMD_DIR/awg-project-update.timer" <<'EOF'
[Unit]
Description=Weekly BAS AmneziaWG safe update check

[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=6h

[Install]
WantedBy=timers.target
EOF
    chmod 644 "$SYSTEMD_DIR/awg-project-update.service" "$SYSTEMD_DIR/awg-project-update.timer"
    systemctl daemon-reload
    systemctl enable --now awg-project-update.timer
    log "Weekly safe-update timer enabled."
}

remove_timer() {
    [[ "$EUID" -eq 0 ]] || die "Root is required to remove the timer."
    systemctl disable --now awg-project-update.timer 2>/dev/null || true
    rm -f "$SYSTEMD_DIR/awg-project-update.timer" "$SYSTEMD_DIR/awg-project-update.service"
    systemctl daemon-reload
    log "Safe-update timer removed."
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check) MODE="check"; shift ;;
            --dry-run) MODE="dry-run"; shift ;;
            --version) [[ $# -ge 2 ]] || die "--version requires a tag"; TARGET_TAG="$2"; shift 2 ;;
            --repo) [[ $# -ge 2 ]] || die "--repo requires OWNER/REPO"; AWG_REPO="$2"; shift 2 ;;
            --install-timer) MODE="install-timer"; shift ;;
            --remove-timer) MODE="remove-timer"; shift ;;
            --keep-backups) [[ $# -ge 2 ]] || die "--keep-backups requires N"; KEEP_BACKUPS="$2"; shift 2 ;;
            -h|--help) usage; return 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    case "$MODE" in
        install-timer) install_timer; return 0 ;;
        remove-timer) remove_timer; return 0 ;;
    esac

    require_commands
    validate_repo
    [[ "$EUID" -eq 0 ]] || die "Root is required to inspect and update the installed server."
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Another project update is already running."
    WEB_WAS_ACTIVE=0
    ADGUARD_WAS_ACTIVE=0
    systemctl is-active --quiet awg-web.service && WEB_WAS_ACTIVE=1
    systemctl is-active --quiet AdGuardHome.service && ADGUARD_WAS_ACTIVE=1
    resolve_target_tag
    log "Installed: $(installed_version); target: ${TARGET_TAG#v}"
    if [[ "$MODE" == "check" ]]; then
        health_check
        log "Server and configuration health checks passed."
        return 0
    fi

    health_check
    if [[ "$(installed_version)" == "${TARGET_TAG#v}" ]]; then
        log "Already on the target version; server health checks passed."
        return 0
    fi
    if installed_is_newer_than_target; then
        log "Installed version is newer than the selected stable release; refusing a downgrade."
        return 0
    fi
    download_release_bundle
    validate_payload
    if [[ "$MODE" == "dry-run" ]]; then
        log "Dry run passed. No files or services were changed."
        return 0
    fi
    apply_payload
    health_check
    [[ "$(installed_version)" == "${TARGET_TAG#v}" ]] || die "Installed VERSION did not switch to target."
    if [[ "$WEB_WAS_ACTIVE" -eq 1 ]]; then
        systemctl show awg-web.service --property=Environment --value \
            | grep -Fq "AWG_PROJECT_VERSION=${TARGET_TAG#v}" \
            || die "awg-web.service did not load the target project version."
    fi
    UPDATE_OK=1
    MUTATION_STARTED=0
    prune_backups
    log "Update to ${TARGET_TAG} completed; VPN tunnel remained active."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    trap cleanup EXIT
    main "$@"
fi
