#!/usr/bin/env bash
# Safely plan or apply an IPv4 /24 tunnel-subnet cutover on an installed server.
set -Eeuo pipefail

AWG_DIR="${AWG_DIR:-/root/awg}"
CONFIG_FILE="${CONFIG_FILE:-$AWG_DIR/awgsetup_cfg.init}"
SERVER_CONF_FILE="${SERVER_CONF_FILE:-/etc/amnezia/amneziawg/awg0.conf}"
ADGUARD_DIR="${AWG_ADGUARD_DIR:-/opt/AdGuardHome}"
SYSTEMD_DIR="${AWG_SYSTEMD_DIR:-/etc/systemd/system}"
BACKUP_ROOT="${AWG_SUBNET_BACKUP_ROOT:-/root/awg-subnet-backups}"
LOCK_FILE="${AWG_SUBNET_LOCK_FILE:-/run/lock/awg-subnet-migration.lock}"

MODE="plan"
OLD_SUBNET=""
NEW_SUBNET=""
CONFIRM=""
WORK_DIR=""
BACKUP_FILE=""
MUTATION_STARTED=0
TUNNEL_WAS_ACTIVE=0
WEB_WAS_ACTIVE=0
ADGUARD_WAS_ACTIVE=0
UFW_RULE_CHANGED=0
UFW_WEB_PORT=""

log() { printf '[awg-subnet] %s\n' "$*"; }
warn() { printf '[awg-subnet] WARNING: %s\n' "$*" >&2; }
die() { printf '[awg-subnet] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage:
  migrate-tunnel-subnet.sh --old 10.9.9.1/24 --new 10.9.10.1/24
  migrate-tunnel-subnet.sh --old 10.9.9.1/24 --new 10.9.10.1/24 \
    --apply --confirm 'MIGRATE:10.9.9.1/24->10.9.10.1/24'

The default mode is read-only planning. Apply performs a coordinated cutover, briefly
restarts awg0/web/AdGuard, validates the result, and automatically restores a root-only
backup on failure. Client keys and peer identities are preserved, but every migrated
client config must be downloaded/re-imported after the cutover.

This resolves overlapping tunnel networks. It does not make two simultaneous 0.0.0.0/0
profiles deterministic; use active/standby full tunnels or disjoint split routes.
EOF
}

cleanup() {
    local rc=$?
    if [[ "$MUTATION_STARTED" -eq 1 && -n "$BACKUP_FILE" ]]; then
        warn "Migration failed after services/files changed; restoring $BACKUP_FILE"
        rollback_now || warn "Automatic rollback was incomplete; manual recovery is required."
    fi
    [[ -z "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"
    exit "$rc"
}

require_commands() {
    local cmd missing=0
    for cmd in awk bash cp diff find flock grep install ip mktemp mv python3 sha256sum \
        systemctl tar; do
        command -v "$cmd" >/dev/null 2>&1 || { warn "Missing command: $cmd"; missing=1; }
    done
    [[ "$missing" -eq 0 ]] || die "Install missing commands before migration."
}

validate_subnet_pair() {
    python3 - "$OLD_SUBNET" "$NEW_SUBNET" <<'PY'
import ipaddress
import sys

old = ipaddress.ip_interface(sys.argv[1])
new = ipaddress.ip_interface(sys.argv[2])
for label, item in (("old", old), ("new", new)):
    if item.version != 4 or item.network.prefixlen != 24:
        raise SystemExit(f"{label} subnet must be an IPv4 /24")
    if item.ip != item.network.network_address + 1:
        raise SystemExit(f"{label} gateway must be the first usable address (.1)")
    if not item.ip.is_private:
        raise SystemExit(f"{label} subnet must be private RFC1918 space")
if old.network == new.network:
    raise SystemExit("old and new networks are identical")
PY
}

old_network() {
    python3 -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "$OLD_SUBNET"
}

new_network() {
    python3 -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "$NEW_SUBNET"
}

old_gateway() { printf '%s\n' "${OLD_SUBNET%/*}"; }
new_gateway() { printf '%s\n' "${NEW_SUBNET%/*}"; }

add_target() {
    local path="$1" existing
    [[ -f "$path" ]] || return 0
    for existing in "${TARGETS[@]-}"; do
        [[ "$existing" != "$path" ]] || return 0
    done
    TARGETS+=("$path")
}

discover_project_text_targets() {
    local path
    while IFS= read -r -d '' path; do
        add_target "$path"
    done < <(python3 - "$OLD_SUBNET" "$AWG_DIR" "$(dirname "$SERVER_CONF_FILE")" <<'PY'
import ipaddress
import os
import pathlib
import re
import sys

old = ipaddress.ip_interface(sys.argv[1]).network
roots = [pathlib.Path(item) for item in sys.argv[2:]]
excluded_dirs = {
    ".git", "backups", "backup", "logs", "log", "updates", ".update-work",
    "health_history", "geoip", "tests",
}
excluded_suffixes = {
    ".gz", ".xz", ".zip", ".tar", ".png", ".jpg", ".jpeg", ".gif", ".deb",
    ".jsonl", ".log", ".mmdb", ".md", ".txt", ".bats", ".sh",
}
pattern = re.compile(rb"(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])")

for root in roots:
    if not root.is_dir():
        continue
    for current, dirs, files in os.walk(root):
        dirs[:] = [item for item in dirs if item not in excluded_dirs]
        for name in files:
            path = pathlib.Path(current, name)
            if (
                path.is_symlink()
                or ".codex-pre-" in name
                or name == "migrate-tunnel-subnet.sh"
                or path.suffix.lower() in excluded_suffixes
            ):
                continue
            try:
                if path.stat().st_size > 16 * 1024 * 1024:
                    continue
                raw = path.read_bytes()
                if b"\0" in raw:
                    continue
                raw.decode("utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            for match in pattern.finditer(raw):
                try:
                    if ipaddress.ip_address(match.group().decode("ascii")) in old:
                        sys.stdout.buffer.write(os.fsencode(path) + b"\0")
                        break
                except (UnicodeDecodeError, ValueError):
                    pass
PY
    )
}

discover_targets() {
    TARGETS=()
    add_target "$CONFIG_FILE"
    add_target "$SERVER_CONF_FILE"
    discover_project_text_targets
    local path
    for path in "$ADGUARD_DIR/AdGuardHome.yaml" \
        "$SYSTEMD_DIR/awg-web.service" \
        "$SYSTEMD_DIR/nginx.service.d/10-wait-for-awg0.conf" /etc/hosts; do
        add_target "$path"
    done
    [[ -f "$CONFIG_FILE" && -f "$SERVER_CONF_FILE" ]] \
        || die "Installed config or awg0.conf is missing."
}

current_config_subnet() {
    awk -F= '/^(export[[:space:]]+)?AWG_TUNNEL_SUBNET=/{
        value=$2; gsub(/^[[:space:]'"'"']+|[[:space:]'"'"']+$/, "", value); print value; exit
    }' "$CONFIG_FILE"
}

transform_tree() {
    local counts="$WORK_DIR/replacements.tsv"
    : > "$counts"
    python3 - "$OLD_SUBNET" "$NEW_SUBNET" "$counts" "${STAGED_TARGETS[@]}" <<'PY'
import ipaddress
import os
import pathlib
import re
import sys

old = ipaddress.ip_interface(sys.argv[1]).network
new = ipaddress.ip_interface(sys.argv[2]).network
counts = pathlib.Path(sys.argv[3])
paths = [pathlib.Path(item) for item in sys.argv[4:]]
pattern = re.compile(r"(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])")

def replace(match, replacements):
    try:
        address = ipaddress.ip_address(match.group(0))
    except ValueError:
        return match.group(0)
    if address not in old:
        return match.group(0)
    replacements[0] += 1
    return str(new.network_address + (int(address) - int(old.network_address)))

rows = []
for path in paths:
    raw = path.read_text(encoding="utf-8", errors="strict")
    replacements = [0]
    updated = pattern.sub(lambda match: replace(match, replacements), raw)
    if replacements[0] and updated != raw:
        tmp = path.with_name(path.name + f".tmp.{os.getpid()}")
        tmp.write_text(updated, encoding="utf-8")
        os.chmod(tmp, path.stat().st_mode & 0o7777)
        os.replace(tmp, path)
        rows.append(f"{path}\t{replacements[0]}")
counts.write_text("\n".join(rows) + ("\n" if rows else ""), encoding="utf-8")
PY
}

stage_candidates() {
    WORK_DIR="$(mktemp -d -t awg-subnet.XXXXXXXX)" || die "Cannot create staging directory."
    mkdir -p "$WORK_DIR/stage"
    STAGED_TARGETS=()
    local path staged
    for path in "${TARGETS[@]}"; do
        cp -a --parents "$path" "$WORK_DIR/stage"
        staged="$WORK_DIR/stage$path"
        STAGED_TARGETS+=("$staged")
    done
    transform_tree
}

contains_network_address() {
    local file="$1" subnet="$2"
    python3 - "$file" "$subnet" <<'PY'
import ipaddress
import pathlib
import re
import sys
net = ipaddress.ip_interface(sys.argv[2]).network
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="ignore")
for raw in re.findall(r"(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])", text):
    try:
        if ipaddress.ip_address(raw) in net:
            raise SystemExit(0)
    except ValueError:
        pass
raise SystemExit(1)
PY
}

validate_stage() {
    local staged_config="$WORK_DIR/stage$CONFIG_FILE"
    local staged_server="$WORK_DIR/stage$SERVER_CONF_FILE"
    grep -qF "AWG_TUNNEL_SUBNET='${NEW_SUBNET}'" "$staged_config" \
        || grep -qF "AWG_TUNNEL_SUBNET=${NEW_SUBNET}" "$staged_config" \
        || die "Staged init config does not contain the new subnet."
    grep -Eq "^Address[[:space:]]*=.*$(new_gateway)/24" "$staged_server" \
        || die "Staged awg0.conf does not contain the new gateway."
    local staged
    for staged in "${STAGED_TARGETS[@]}"; do
        if contains_network_address "$staged" "$OLD_SUBNET"; then
            die "Staged project file still contains an old-subnet address: ${staged#"$WORK_DIR/stage"}"
        fi
    done
    local hook
    for hook in "$WORK_DIR/stage$AWG_DIR/postup.sh" "$WORK_DIR/stage$AWG_DIR/postdown.sh" \
        "$WORK_DIR/stage$AWG_DIR/p2p_rules.sh"; do
        [[ ! -f "$hook" ]] || bash -n "$hook" || die "Invalid staged hook: ${hook#"$WORK_DIR/stage"}"
    done
    local policy="$WORK_DIR/stage$AWG_DIR/web/access_policy.json"
    [[ ! -f "$policy" ]] || python3 -m json.tool "$policy" >/dev/null \
        || die "Staged web access policy is invalid JSON."
    if command -v awg-quick >/dev/null 2>&1; then
        awg-quick strip "$staged_server" >/dev/null \
            || die "Staged awg0.conf failed awg-quick validation."
    fi
    local adguard="$WORK_DIR/stage$ADGUARD_DIR/AdGuardHome.yaml"
    if [[ -x "$ADGUARD_DIR/AdGuardHome" && -f "$adguard" ]]; then
        "$ADGUARD_DIR/AdGuardHome" --check-config -c "$adguard" -w "$ADGUARD_DIR" >/dev/null \
            || die "Staged AdGuardHome.yaml failed validation."
    fi
}

show_plan() {
    local old_net new_net client_count changed_count
    old_net="$(old_network)"
    new_net="$(new_network)"
    client_count="$(grep -c '^#_Name = ' "$SERVER_CONF_FILE" 2>/dev/null || true)"
    changed_count="$(wc -l < "$WORK_DIR/replacements.tsv" | tr -d ' ')"
    cat <<EOF
Subnet migration plan (no changes made)
  old gateway/network: $(old_gateway) / $old_net
  new gateway/network: $(new_gateway) / $new_net
  peers discovered:    $client_count
  text files changed:  $changed_count of ${#TARGETS[@]}
  IPv6:                unchanged
  keys/peer identity:  unchanged
  required cutover:    awg0, web and active AdGuard restart
  client action:       download and re-import every German config after apply

WARNING: confirm that $new_net is absent from every client LAN and route table.
WARNING: two active full-tunnel profiles still compete for 0.0.0.0/0; use active/standby
         or configure disjoint split routes.

Files with address replacements:
EOF
    awk -F'\t' -v prefix="$WORK_DIR/stage" '{sub(prefix, "", $1); printf "  %s (%s replacements)\n", $1, $2}' "$WORK_DIR/replacements.tsv"
    printf '\nApply confirmation token:\n  MIGRATE:%s->%s\n' "$OLD_SUBNET" "$NEW_SUBNET"
}

create_backup() {
    local timestamp rel
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$BACKUP_ROOT"
    chmod 700 "$BACKUP_ROOT"
    BACKUP_FILE="$BACKUP_ROOT/subnet-${timestamp}.tar.gz"
    local archive_paths=()
    for rel in "$AWG_DIR" "$SERVER_CONF_FILE" "$ADGUARD_DIR/AdGuardHome.yaml" \
        "$SYSTEMD_DIR/awg-web.service" "$SYSTEMD_DIR/nginx.service.d/10-wait-for-awg0.conf" /etc/hosts; do
        [[ -e "$rel" ]] && archive_paths+=("${rel#/}")
    done
    tar -C / -czf "$BACKUP_FILE" "${archive_paths[@]}"
    chmod 600 "$BACKUP_FILE"
    sha256sum "$BACKUP_FILE" > "$BACKUP_FILE.sha256"
    chmod 600 "$BACKUP_FILE.sha256"
    log "Rollback archive: $BACKUP_FILE"
}

stop_active_services() {
    systemctl is-active --quiet awg-quick@awg0 && TUNNEL_WAS_ACTIVE=1 || true
    systemctl is-active --quiet awg-web.service && WEB_WAS_ACTIVE=1 || true
    systemctl is-active --quiet AdGuardHome.service && ADGUARD_WAS_ACTIVE=1 || true
    [[ "$WEB_WAS_ACTIVE" -eq 0 ]] || systemctl stop awg-web.service
    [[ "$ADGUARD_WAS_ACTIVE" -eq 0 ]] || systemctl stop AdGuardHome.service
    [[ "$TUNNEL_WAS_ACTIVE" -eq 0 ]] || systemctl stop awg-quick@awg0
}

install_staged_files() {
    local path staged temp
    for path in "${TARGETS[@]}"; do
        staged="$WORK_DIR/stage$path"
        temp="$(mktemp "$(dirname "$path")/.awg-subnet.XXXXXXXX")"
        rm -f "$temp"
        cp -a "$staged" "$temp"
        mv -f "$temp" "$path"
    done
}

regenerate_derived_files() {
    # shellcheck source=/dev/null
    source "$AWG_DIR/awg_common.sh"
    load_awg_params
    generate_firewall_scripts || return 1
    local name
    while IFS= read -r name; do
        [[ -n "$name" && -f "$AWG_DIR/$name.conf" ]] || continue
        generate_qr "$name" || warn "Raw config QR was not regenerated for $name"
        if generate_vpn_uri "$name"; then
            generate_qr_vpnuri "$name" || warn "vpn:// QR was not regenerated for $name"
        else
            warn "vpn:// URI was not regenerated for $name"
        fi
    done < <(sed -n 's/^#_Name = //p' "$SERVER_CONF_FILE")
    sync_clients_hosts
    sync_adguard_clients
}

refresh_selfsigned_certificate() {
    local cert_mode
    cert_mode="$(awk -F= '/^(export[[:space:]]+)?AWG_WEB_CERT_MODE=/{gsub(/[[:space:]'"'"']/, "", $2); print $2; exit}' "$CONFIG_FILE")"
    [[ "${cert_mode:-selfsigned}" == "selfsigned" ]] || return 0
    command -v openssl >/dev/null 2>&1 || { warn "openssl missing; existing self-signed cert retained."; return 0; }
    local cert="$AWG_DIR/web/cert.pem" key="$AWG_DIR/web/key.pem" tmp_cert tmp_key
    [[ -d "$AWG_DIR/web" ]] || return 0
    tmp_cert="$(mktemp "$AWG_DIR/web/.cert.pem.XXXXXXXX")"
    tmp_key="$(mktemp "$AWG_DIR/web/.key.pem.XXXXXXXX")"
    openssl req -x509 -newkey rsa:2048 -nodes -days 825 -subj "/CN=$(new_gateway)" \
        -addext "subjectAltName=IP:$(new_gateway),IP:127.0.0.1" \
        -keyout "$tmp_key" -out "$tmp_cert" >/dev/null 2>&1
    chmod 600 "$tmp_key"; chmod 644 "$tmp_cert"
    mv -f "$tmp_key" "$key"; mv -f "$tmp_cert" "$cert"
}

update_ufw_web_rule() {
    command -v ufw >/dev/null 2>&1 || return 0
    ufw status 2>/dev/null | grep -q '^Status: active' || return 0
    local bind
    bind="$(awk -F= '/^(export[[:space:]]+)?AWG_WEB_BIND=/{gsub(/[[:space:]'"'"']/, "", $2); print $2; exit}' "$CONFIG_FILE")"
    [[ "$bind" == "$(new_gateway)" ]] || return 0
    UFW_WEB_PORT="$(awk -F= '/^(export[[:space:]]+)?AWG_WEB_PORT=/{gsub(/[[:space:]'"'"']/, "", $2); print $2; exit}' "$CONFIG_FILE")"
    UFW_WEB_PORT="${UFW_WEB_PORT:-8443}"
    ufw --force delete allow in on awg0 to "$(old_gateway)" port "$UFW_WEB_PORT" proto tcp >/dev/null 2>&1 || true
    ufw allow in on awg0 to "$(new_gateway)" port "$UFW_WEB_PORT" proto tcp comment "AmneziaWG Web Panel VPN-only"
    UFW_RULE_CHANGED=1
}

start_and_verify() {
    systemctl daemon-reload
    [[ "$TUNNEL_WAS_ACTIVE" -eq 0 ]] || systemctl start awg-quick@awg0
    [[ "$WEB_WAS_ACTIVE" -eq 0 ]] || systemctl start awg-web.service
    [[ "$ADGUARD_WAS_ACTIVE" -eq 0 ]] || systemctl start AdGuardHome.service
    if [[ "$TUNNEL_WAS_ACTIVE" -eq 1 ]]; then
        systemctl is-active --quiet awg-quick@awg0
        ip -4 address show dev awg0 | grep -qF "inet $(new_gateway)/24"
        if ip -4 address show dev awg0 | grep -qF "inet $(old_gateway)/24"; then
            return 1
        fi
        awg show awg0 >/dev/null
    fi
    [[ "$WEB_WAS_ACTIVE" -eq 0 ]] || systemctl is-active --quiet awg-web.service
    [[ "$ADGUARD_WAS_ACTIVE" -eq 0 ]] || systemctl is-active --quiet AdGuardHome.service
    [[ "$(current_config_subnet)" == "$NEW_SUBNET" ]]
    local path
    for path in "${TARGETS[@]}"; do
        if contains_network_address "$path" "$OLD_SUBNET"; then
            warn "Old-subnet address remains in active project file: $path"
            return 1
        fi
    done
}

rollback_now() {
    MUTATION_STARTED=0
    systemctl stop awg-web.service AdGuardHome.service awg-quick@awg0 2>/dev/null || true
    tar -C / -xzf "$BACKUP_FILE" || return 1
    if [[ "$UFW_RULE_CHANGED" -eq 1 ]] && command -v ufw >/dev/null 2>&1; then
        ufw --force delete allow in on awg0 to "$(new_gateway)" port "$UFW_WEB_PORT" proto tcp >/dev/null 2>&1 || true
        ufw allow in on awg0 to "$(old_gateway)" port "$UFW_WEB_PORT" proto tcp comment "AmneziaWG Web Panel VPN-only" >/dev/null 2>&1 || true
    fi
    systemctl daemon-reload || true
    [[ "$TUNNEL_WAS_ACTIVE" -eq 0 ]] || systemctl start awg-quick@awg0 || return 1
    [[ "$WEB_WAS_ACTIVE" -eq 0 ]] || systemctl start awg-web.service || return 1
    [[ "$ADGUARD_WAS_ACTIVE" -eq 0 ]] || systemctl start AdGuardHome.service || return 1
    log "Rollback completed."
}

apply_migration() {
    [[ "$EUID" -eq 0 ]] || die "Root is required for --apply."
    local expected="MIGRATE:${OLD_SUBNET}->${NEW_SUBNET}"
    [[ "$CONFIRM" == "$expected" ]] || die "Apply is locked. Pass --confirm '$expected'"
    create_backup
    MUTATION_STARTED=1
    stop_active_services
    install_staged_files
    regenerate_derived_files
    refresh_selfsigned_certificate
    update_ufw_web_rule
    start_and_verify || die "Post-migration health check failed."
    MUTATION_STARTED=0
    log "Migration completed: ${OLD_SUBNET} -> ${NEW_SUBNET}"
    warn "Download and re-import every client config before deleting old copies."
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --old) [[ $# -ge 2 ]] || die "--old requires CIDR"; OLD_SUBNET="$2"; shift 2 ;;
            --new) [[ $# -ge 2 ]] || die "--new requires CIDR"; NEW_SUBNET="$2"; shift 2 ;;
            --apply) MODE="apply"; shift ;;
            --confirm) [[ $# -ge 2 ]] || die "--confirm requires token"; CONFIRM="$2"; shift 2 ;;
            -h|--help) usage; return 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    [[ -n "$OLD_SUBNET" && -n "$NEW_SUBNET" ]] || { usage >&2; return 2; }
    require_commands
    validate_subnet_pair
    [[ "$(current_config_subnet)" == "$OLD_SUBNET" ]] \
        || die "Installed subnet ($(current_config_subnet)) does not match --old ($OLD_SUBNET)."
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Another subnet migration is already running."
    discover_targets
    stage_candidates
    validate_stage
    show_plan
    [[ "$MODE" != "apply" ]] || apply_migration
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    trap cleanup EXIT
    main "$@"
fi
