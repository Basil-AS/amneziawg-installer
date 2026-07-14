#!/bin/bash
# shellcheck disable=SC1003,SC2012,SC2015,SC2016,SC2004,SC2086,SC2317

# ==============================================================================
# Common function library for AmneziaWG 2.0
# Author: @bivlked
# Version: 5.15.3-bas.1
# Date: 2026-05-13
# Repository: https://github.com/bivlked/amneziawg-installer
# ==============================================================================
#
# This file contains common functions for key generation, configuration
# rendering, peer management, and AWG 2.0 parameter handling.
# It is intended to be sourced by install and manage scripts.
# ==============================================================================

# --- Константы (могут быть переопределены до source) ---
AWG_DIR="${AWG_DIR:-/root/awg}"
CONFIG_FILE="${CONFIG_FILE:-$AWG_DIR/awgsetup_cfg.init}"
SERVER_CONF_FILE="${SERVER_CONF_FILE:-/etc/amnezia/amneziawg/awg0.conf}"
KEYS_DIR="${KEYS_DIR:-$AWG_DIR/keys}"
AWG_HOSTS_FILE="${AWG_HOSTS_FILE:-/etc/hosts}"

# --- Автоочистка временных файлов ---
# ВАЖНО: trap НЕ устанавливается здесь, чтобы не перезаписать trap вызывающего скрипта.
# Вызывающий скрипт должен вызвать _awg_cleanup() в своём обработчике EXIT.
_AWG_TEMP_FILES=()

_awg_cleanup() {
    local f
    for f in "${_AWG_TEMP_FILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
}

# Обёртка mktemp с автоочисткой
awg_mktemp() {
    local f
    f=$(mktemp) || return 1
    _AWG_TEMP_FILES+=("$f")
    echo "$f"
}

install_nginx_awg0_wait_dropin() {
    local iface="${1:-${AWG_NGINX_WAIT_IFACE:-awg0}}"
    local bind_ip="${2:-${AWG_NGINX_WAIT_IP:-${AWG_WEB_BIND:-10.9.9.1}}}"
    local timeout="${3:-${AWG_NGINX_WAIT_TIMEOUT:-90}}"
    local systemd_dir="${AWG_SYSTEMD_DIR:-/etc/systemd/system}"
    local dropin_dir="${NGINX_SYSTEMD_DROPIN_DIR:-$systemd_dir/nginx.service.d}"
    local dropin_file="$dropin_dir/10-wait-awg0.conf"
    local tmp

    [[ "$iface" =~ ^[A-Za-z0-9_.:-]+$ ]] || { log_error "Invalid VPN interface for nginx wait drop-in: $iface"; return 1; }
    [[ "$bind_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { log_error "Invalid IPv4 bind address for nginx wait drop-in: $bind_ip"; return 1; }
    [[ "$timeout" =~ ^[0-9]+$ && "$timeout" -ge 1 && "$timeout" -le 600 ]] || { log_error "Invalid timeout for nginx wait drop-in: $timeout"; return 1; }

    mkdir -p "$dropin_dir" || { log_error "Failed to create $dropin_dir"; return 1; }
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

# Определение основного сетевого интерфейса
get_main_nic() {
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}'
}

# Определение внешнего IP-адреса сервера (с кэшированием)
_CACHED_PUBLIC_IP=""
get_server_public_ip() {
    if [[ -n "$_CACHED_PUBLIC_IP" ]]; then
        echo "$_CACHED_PUBLIC_IP"
        return 0
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
        if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
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
    [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
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
    log "Configuring Voice / Calls UDP optimization..."
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
        sysctl -p "$udp_file" >/dev/null 2>&1 || log_warn "Failed to apply $udp_file; continuing."
    else
        log_warn "nf_conntrack UDP sysctl is unavailable; skipping Voice / Calls UDP tuning."
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
                sysctl -p "$max_file" >/dev/null 2>&1 || log_warn "Failed to apply $max_file; continuing."
            fi
        fi
    else
        log_warn "nf_conntrack_max is unavailable; skipping conntrack capacity floor."
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

awg_server_name() {
    local name="${AWG_SERVER_NAME:-MyVPN}"
    name="${name//$'\r'/ }"
    name="${name//$'\n'/ }"
    [[ -n "${name//[[:space:]]/}" ]] || name="MyVPN"
    printf '%s' "$name"
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

awg_dns_mode() {
    case "${AWG_DNS_MODE:-system}" in
        adguard|system|custom) echo "${AWG_DNS_MODE}" ;;
        *) echo "system" ;;
    esac
}

awg_dns_servers() {
    local mode
    mode=$(awg_dns_mode)
    case "$mode" in
        adguard)
            local dns="10.9.9.1" server_v6=""
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

def has_covering_route(ip):
    for route in routes:
        try:
            if ip in ipaddress.ip_network(route, strict=False):
                return True
        except ValueError:
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
    if net.version != 6 or net.prefixlen != 64:
        raise ValueError("expected IPv6 /64")
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
IPV6_MODE="$(normalize_awg_ipv6_mode "${AWG_IPV6_MODE:-legacy}" 2>/dev/null || echo legacy)"
IPV6_SUBNET="${AWG_IPV6_SUBNET:-}"
AWG_MTU="${AWG_MTU:-1280}"
MSS4="$(( ${AWG_MTU:-1280} - 40 ))"
MSS6="$(( ${AWG_MTU:-1280} - 60 ))"
P2P_RULES="${p2p}"
SERVER_CONF_FILE="${SERVER_CONF_FILE:-/etc/amnezia/amneziawg/awg0.conf}"

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
    if [[ "\$IPV6_MODE" == "ula" && -n "\$IPV6_SUBNET" ]]; then
        ip6t_add nat POSTROUTING -s "\$IPV6_SUBNET" -o "\$NIC" -j MASQUERADE
    fi
    ip6tables -C FORWARD -i "\$NIC" -o "\$AWG_IFACE" -m state --state NEW -j DROP 2>/dev/null || \
        ip6tables -A FORWARD -i "\$NIC" -o "\$AWG_IFACE" -m state --state NEW -j DROP
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
IPV6_MODE="$(normalize_awg_ipv6_mode "${AWG_IPV6_MODE:-legacy}" 2>/dev/null || echo legacy)"
IPV6_SUBNET="${AWG_IPV6_SUBNET:-}"
AWG_MTU="${AWG_MTU:-1280}"
MSS4="$(( ${AWG_MTU:-1280} - 40 ))"
MSS6="$(( ${AWG_MTU:-1280} - 60 ))"
P2P_RULES="${p2p}"
SERVER_CONF_FILE="${SERVER_CONF_FILE:-/etc/amnezia/amneziawg/awg0.conf}"

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
    if [[ "\$IPV6_MODE" == "ula" && -n "\$IPV6_SUBNET" ]]; then
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
IPV6_MODE="$(normalize_awg_ipv6_mode "${AWG_IPV6_MODE:-legacy}" 2>/dev/null || echo legacy)"

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
        random_val=$(( (RANDOM << 15) | RANDOM ))
    fi
    echo $(( (random_val % range) + min ))
}

# Генерация 4 непересекающихся диапазонов для AWG H1-H4.
# Алгоритм: 8 случайных значений → sort → 4 пары (low, high).
# Сортировка гарантирует low ≤ high и непересечение между парами.
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
        # Проверка минимальной ширины каждой пары
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

# ==============================================================================
# DKMS / Автовосстановление модуля ядра amneziawg
# ==============================================================================
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
            _ensure_awg_quick_running awg0 || \
                log_warn "Модуль активен, но awg-quick@awg0 не стартовал (модуль OK, это сервис-проблема)."
        fi
        return 0
    fi

    # Модуль на диске для running kernel — пробуем modprobe до full repair.
    if find "/lib/modules/${kernel_ver}" -name 'amneziawg.ko*' -print -quit 2>/dev/null | grep -q .; then
        if modprobe amneziawg 2>/dev/null && \
           lsmod 2>/dev/null | awk '{print $1}' | grep -qx 'amneziawg'; then
            log "amneziawg-модуль найден на диске и успешно загружен."
            if [[ "$mode" == "full" ]]; then
                _ensure_awg_quick_running awg0 || \
                    log_warn "Модуль загружен, но awg-quick@awg0 не стартовал (модуль OK, это сервис-проблема)."
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
        depmod -a "$kernel_ver" 2>/dev/null || \
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
        _ensure_awg_quick_running awg0 || \
            log_warn "Модуль загружен, но awg-quick@awg0 не стартовал (модуль OK, это сервис-проблема)."
    fi
    return 0
}

# ==============================================================================
# VPN readiness diagnostic checklist
# ==============================================================================

# Prints a readiness checklist for AmneziaWG: kernel module, hardware crypto
# acceleration, virtualization, IP forwarding, UDP buffers, WAN offloads,
# IPv6 routing and NDP proxy (ndppd). Diagnostics only: never modifies the
# host and always returns 0 so it cannot break the install flow (see
# install_amneziawg_en.sh step99).
print_vpn_readiness_checklist() {
    log "--- AmneziaWG readiness check (VPN readiness) ---"

    # 1. amneziawg/wireguard kernel module
    local mods has_awg=0 has_wg=0
    mods="$(lsmod 2>/dev/null | awk '{print $1}')"
    { grep -qx 'amneziawg' <<<"$mods"; } && has_awg=1
    [[ -d /sys/module/amneziawg ]] && has_awg=1
    { grep -qx 'wireguard' <<<"$mods"; } && has_wg=1
    [[ -d /sys/module/wireguard ]] && has_wg=1
    if [[ "$has_awg" -eq 1 ]]; then
        log "  [OK]   Kernel module: amneziawg loaded (kernel $(uname -r))"
    elif [[ "$has_wg" -eq 1 ]]; then
        log "  [OK]   Kernel module: wireguard loaded (kernel $(uname -r))"
    else
        log_warn "  [WARN] Kernel module: amneziawg/wireguard not found (a userspace implementation may be in use)"
    fi

    # 2. Hardware crypto acceleration (CPU flags)
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
        log "  [OK]   Crypto: hardware crypto acceleration available (${arch}: ${accel})"
    elif [[ -n "$accel" ]]; then
        log "  [INFO] Crypto: partial crypto acceleration (${arch}: ${accel})"
    else
        log_warn "  [WARN] Crypto: no hardware crypto acceleration detected (${arch}) — AmneziaWG will fall back to software crypto"
    fi

    # 3. Virtualization (informational)
    local virt
    virt="$(systemd-detect-virt 2>/dev/null || echo unknown)"
    log "  [INFO] Virtualization: ${virt}"

    # 4. IP forwarding (critical for VPN routing)
    local v4fwd v6fwd
    v4fwd="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
    v6fwd="$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo 0)"
    if [[ "$v4fwd" == "1" ]]; then
        log "  [OK]   IP forwarding: IPv4 enabled (IPv6: $([[ "$v6fwd" == "1" ]] && echo on || echo off))"
    else
        log_error "  [FAIL] IP forwarding: net.ipv4.ip_forward=0 — VPN client traffic will not be routed"
    fi

    # 5. Kernel UDP buffers
    local rmem wmem recommended=2500000
    rmem="$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo 0)"
    wmem="$(cat /proc/sys/net/core/wmem_max 2>/dev/null || echo 0)"
    if [[ "$rmem" -ge "$recommended" && "$wmem" -ge "$recommended" ]]; then
        log "  [OK]   UDP buffers: rmem_max=${rmem}, wmem_max=${wmem} (>= ${recommended})"
    else
        log_warn "  [WARN] UDP buffers: rmem_max=${rmem}, wmem_max=${wmem} (recommended >= ${recommended}) — throughput may suffer under load"
    fi

    # 6. WAN offloads (informational only — not treated as a problem)
    local wan_iface offload_info
    wan_iface="$(get_main_nic)"
    if [[ -n "$wan_iface" ]] && command -v ethtool >/dev/null 2>&1; then
        offload_info="$(ethtool -k "$wan_iface" 2>/dev/null | awk -F': ' '
            /^(tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload|large-receive-offload|udp-fragmentation-offload)/ {
                gsub(/[ \t].*/, "", $2); printf "%s=%s ", $1, $2
            }')"
        log "  [INFO] WAN offloads (${wan_iface}): ${offload_info:-n/a}"
    else
        log "  [INFO] WAN offloads: interface not detected or ethtool unavailable"
    fi

    # 7. IPv6 routing (informational)
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

    # 8. NDP proxy (ndppd) — diagnostics only, never auto-installed
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
        log "  [INFO] NDP proxy (ndppd): IPv6 is disabled — not applicable"
    elif [[ "$has_global_v6" -eq 1 && "$has_default_v6route" -eq 0 ]]; then
        if [[ -n "$ndppd_bin" && "$ndppd_conf" -eq 1 && "$ndppd_enabled" -eq 1 ]]; then
            log "  [OK]   NDP proxy (ndppd): installed and enabled"
        else
            log_warn "  [WARN] NDP proxy (ndppd): a global IPv6 address is present without a default route — ndppd may be needed (not installed automatically)"
        fi
    else
        log "  [INFO] NDP proxy (ndppd): a routed IPv6 prefix is present — not needed"
    fi

    log "--- End of AmneziaWG readiness check ---"
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
                AWG_H1|AWG_H2|AWG_H3|AWG_H4|AWG_I1|AWG_I2|AWG_I3|AWG_I4|AWG_I5|AWG_PRESET|NO_TWEAKS|AWG_APPLY_MODE|\
                AWG_IPV6_ENABLED|AWG_IPV6_MODE|AWG_IPV6_MODE_REQUESTED|AWG_IPV6_MODE_EFFECTIVE|AWG_IPV6_MODE_REASON|AWG_IPV6_SUBNET|AWG_IPV6_NDP_PROXY|AWG_IPV6_LEAK_PROTECTION|\
                AWG_P2P_ENABLED|AWG_P2P_BASE_PORT|AWG_P2P_PORTS_PER_CLIENT|AWG_FULLCONE_NAT|\
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

    # Atomic check: все 11 обязательных полей найдены?
    [[ -n "$_Jc" && -n "$_Jmin" && -n "$_Jmax" && \
       -n "$_S1" && -n "$_S2" && -n "$_S3" && -n "$_S4" && \
       -n "$_H1" && -n "$_H2" && -n "$_H3" && -n "$_H4" ]] || return 1

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

    # 3. Проверка обязательных AWG 2.0 параметров
    local missing=0
    local param
    for param in AWG_Jc AWG_Jmin AWG_Jmax AWG_S1 AWG_S2 AWG_S3 AWG_S4 AWG_H1 AWG_H2 AWG_H3 AWG_H4; do
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

    local privkey pubkey
    privkey=$(awg genkey) || {
        log_error "Ошибка генерации приватного ключа для '$name'"
        return 1
    }
    pubkey=$(echo "$privkey" | awg pubkey) || {
        log_error "Ошибка генерации публичного ключа для '$name'"
        return 1
    }

    echo "$privkey" > "$KEYS_DIR/${name}.private" || {
        log_error "Ошибка записи приватного ключа для '$name'"
        return 1
    }
    echo "$pubkey" > "$KEYS_DIR/${name}.public" || {
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

    echo "$privkey" > "$AWG_DIR/server_private.key" || return 1
    echo "$pubkey" > "$AWG_DIR/server_public.key" || return 1
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
    _tmp=$(awg_mktemp) || return 1
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

# Рендер серверного конфига AWG 2.0
# Использует глобальные переменные из load_awg_params()
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
        return 1
    fi

    local server_ip subnet_mask
    server_ip=$(echo "$AWG_TUNNEL_SUBNET" | cut -d'/' -f1)
    subnet_mask=$(echo "$AWG_TUNNEL_SUBNET" | cut -d'/' -f2)

    local conf_dir
    conf_dir=$(dirname "$SERVER_CONF_FILE")
    mkdir -p "$conf_dir" || {
        log_error "Ошибка создания $conf_dir"
        return 1
    }

    local address_line="${server_ip}/${subnet_mask}"
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
    local postup="/bin/bash ${AWG_DIR}/postup.sh"
    local postdown="/bin/bash ${AWG_DIR}/postdown.sh"

    # Формируем конфиг через временный файл (атомарная запись)
    local tmpfile
    tmpfile=$(awg_mktemp) || { log_error "Ошибка mktemp"; return 1; }

    cat > "$tmpfile" << EOF
[Interface]
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
S3 = ${AWG_S3}
S4 = ${AWG_S4}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}
EOF

    # I1-I5 are optional; I2-I5 may be supplied manually by the administrator.
    [[ -n "${AWG_I1:-}" ]] && echo "I1 = ${AWG_I1}" >> "$tmpfile"
    [[ -n "${AWG_I2:-}" ]] && echo "I2 = ${AWG_I2}" >> "$tmpfile"
    [[ -n "${AWG_I3:-}" ]] && echo "I3 = ${AWG_I3}" >> "$tmpfile"
    [[ -n "${AWG_I4:-}" ]] && echo "I4 = ${AWG_I4}" >> "$tmpfile"
    [[ -n "${AWG_I5:-}" ]] && echo "I5 = ${AWG_I5}" >> "$tmpfile"

    if ! mv "$tmpfile" "$SERVER_CONF_FILE"; then
        rm -f "$tmpfile"
        log_error "Ошибка записи серверного конфига"
        return 1
    fi
    chmod 600 "$SERVER_CONF_FILE"
    log "Серверный конфиг создан: $SERVER_CONF_FILE"
    return 0
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
render_client_config() {
    local name="$1"
    local client_ip="$2"
    local client_privkey="$3"
    local server_pubkey="$4"
    local endpoint="$5"
    local port="$6"
    local client_ipv6="${7:-}"

    load_awg_params || return 1

    local conf_file="$AWG_DIR/${name}.conf"
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
    elif awg_ipv6_leak_block_enabled && [[ "${ALLOWED_IPS_MODE:-}" == "1" ]]; then
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

    local tmpfile
    tmpfile=$(awg_mktemp) || { log_error "Ошибка mktemp"; return 1; }

    cat > "$tmpfile" << EOF
[Interface]
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
S3 = ${AWG_S3}
S4 = ${AWG_S4}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}
EOF

    [[ -n "${AWG_I1:-}" ]] && echo "I1 = ${AWG_I1}" >> "$tmpfile"
    [[ -n "${AWG_I2:-}" ]] && echo "I2 = ${AWG_I2}" >> "$tmpfile"
    [[ -n "${AWG_I3:-}" ]] && echo "I3 = ${AWG_I3}" >> "$tmpfile"
    [[ -n "${AWG_I4:-}" ]] && echo "I4 = ${AWG_I4}" >> "$tmpfile"
    [[ -n "${AWG_I5:-}" ]] && echo "I5 = ${AWG_I5}" >> "$tmpfile"
    if [[ "${AWG_WIRESOCK_HINTS:-off}" != "off" ]]; then
        render_wiresock_hints >> "$tmpfile" || { rm -f "$tmpfile"; log_error "Invalid WireSock compatibility hints"; return 1; }
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

    if [[ "${AWG_APPLY_MODE:-syncconf}" == "restart" ]]; then
        log "Перезапуск сервиса (apply-mode=restart)..."
        systemctl restart awg-quick@awg0 2>/dev/null; rc=$?
        [[ $rc -ne 0 ]] && log_warn "Ошибка перезапуска."
        if [[ $rc -eq 0 ]]; then
            ipv6_ndp_refresh_after_config_apply || rc=$?
        fi
        exec {apply_fd}>&-
        return $rc
    fi

    local strip_out
    strip_out=$(timeout 10 awg-quick strip awg0 2>/dev/null) || {
        log_warn "awg-quick strip не удался или timeout, использую полный перезапуск."
        systemctl restart awg-quick@awg0 2>/dev/null; rc=$?
        [[ $rc -ne 0 ]] && log_warn "Ошибка перезапуска."
        if [[ $rc -eq 0 ]]; then
            ipv6_ndp_refresh_after_config_apply || rc=$?
        fi
        exec {apply_fd}>&-
        return $rc
    }
    echo "$strip_out" | timeout 10 awg syncconf awg0 /dev/stdin 2>/dev/null || {
        log_warn "awg syncconf не удался или timeout, использую полный перезапуск."
        systemctl restart awg-quick@awg0 2>/dev/null; rc=$?
        [[ $rc -ne 0 ]] && log_warn "Ошибка перезапуска."
        if [[ $rc -eq 0 ]]; then
            ipv6_ndp_refresh_after_config_apply || rc=$?
        fi
        exec {apply_fd}>&-
        return $rc
    }
    log_debug "Конфигурация применена (syncconf)."
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
    local subnet_base
    subnet_base=$(echo "${AWG_TUNNEL_SUBNET:-10.9.9.1/24}" | cut -d'/' -f1 | cut -d'.' -f1-3)

    # Ассоциативный массив для O(1) lookup
    declare -A used_set
    used_set["${subnet_base}.1"]=1
    while IFS= read -r ip; do
        [[ "$ip" == "${subnet_base}."* ]] && used_set["$ip"]=1
    done < <(reserved_client_ipv4s_stream "$subnet_base")

    local i candidate
    for i in $(seq 2 254); do
        candidate="${subnet_base}.${i}"
        if [[ -z "${used_set[$candidate]+x}" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    log_error "Нет свободных IP в подсети ${subnet_base}.0/24"
    return 1
}

sync_clients_hosts() {
    local hosts_file="${AWG_HOSTS_FILE:-/etc/hosts}"
    [[ -f "$SERVER_CONF_FILE" ]] || return 0
    [[ -n "$hosts_file" ]] || return 0

    local dir tmp body
    dir=$(dirname "$hosts_file")
    mkdir -p "$dir" 2>/dev/null || {
        log_warn "Failed to create hosts directory: $dir"
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
        /^# BEGIN AmneziaWG clients$/ { skip=1; next }
        /^# END AmneziaWG clients$/ { skip=0; next }
        !skip { print }
        ' "$hosts_file" > "$tmp" 2>/dev/null || cp "$hosts_file" "$tmp" 2>/dev/null || return 0
    fi

    if [[ -s "$body" ]]; then
        {
            printf '\n# BEGIN AmneziaWG clients\n'
            cat "$body"
            printf '# END AmneziaWG clients\n'
        } >> "$tmp"
    fi

    if mv "$tmp" "$hosts_file"; then
        chmod 644 "$hosts_file" 2>/dev/null || true
        log_debug "hosts updated for AmneziaWG clients: $hosts_file"
    else
        log_warn "Failed to update hosts for clients: $hosts_file"
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

    if grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Пир '$name' уже существует в конфиге"
        return 1
    fi

    # Добавляем пир через временный файл (атомарно)
    local tmpfile
    tmpfile=$(awg_mktemp) || { log_error "Ошибка mktemp"; return 1; }

    cp "$SERVER_CONF_FILE" "$tmpfile" || {
        rm -f "$tmpfile"
        log_error "Ошибка копирования серверного конфига"
        return 1
    }

    cat >> "$tmpfile" << EOF

[Peer]
#_Name = ${name}
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

# Удаление [Peer] из серверного конфига по имени (с блокировкой)
# remove_peer_from_server <name>
remove_peer_from_server() {
    local name="$1"

    if [[ -z "$name" ]]; then
        log_error "remove_peer_from_server: не указано имя"
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

    local tmpfile
    tmpfile=$(awg_mktemp) || { log_error "Ошибка mktemp"; exec {lock_fd}>&-; return 1; }

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
    ' "$SERVER_CONF_FILE" > "$tmpfile"

    # Нормализация: сжать множественные пустые строки в одну
    local tmpclean
    tmpclean=$(awg_mktemp) || { log_error "Ошибка mktemp"; exec {lock_fd}>&-; return 1; }
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

    qrencode -t png -o "$png_file" < "$conf_file" || {
        log_error "Ошибка генерации QR-кода для '$name'"
        return 1
    }

    chmod 600 "$png_file"
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

    local client_privkey client_ip server_pubkey endpoint allowed_ips client_psk
    client_privkey=$(grep -oP 'PrivateKey\s*=\s*\K\S+' "$conf_file") || return 1
    client_ip=$(grep -oP 'Address\s*=\s*\K[0-9./]+' "$conf_file") || return 1
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
    # tr -d ' \r' — спирает пробелы И CR (на CRLF-конфигах '.+' жадно
    # затягивает \r в значение, что ломает JSON.allowed_ips).
    allowed_ips=$(grep -oP 'AllowedIPs\s*=\s*\K.+' "$conf_file" | tr -d ' \r') || allowed_ips="0.0.0.0/0"

    local vpn_uri perl_err
    perl_err=$(awg_mktemp) || perl_err="/tmp/awg_perl_err.$$"
    # shellcheck disable=SC2016
    vpn_uri=$(perl -MCompress::Zlib -MMIME::Base64 -e '
        my ($conf_path, $h1,$h2,$h3,$h4, $jc,$jmin,$jmax,
            $s1,$s2,$s3,$s4, $i1,$i2,$i3,$i4,$i5, $port, $ep, $cip, $cpk, $spk, $aips, $psk) = @ARGV;

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
        $inner .= qq("S1":"$s1","S2":"$s2","S3":"$s3","S4":"$s4",);
        if ($i1 ne "" || $i2 ne "" || $i3 ne "" || $i4 ne "" || $i5 ne "") {
            my $ei1 = je($i1); my $ei2 = je($i2); my $ei3 = je($i3);
            my $ei4 = je($i4); my $ei5 = je($i5);
            $inner .= qq("I1":"$ei1","I2":"$ei2","I3":"$ei3","I4":"$ei4","I5":"$ei5",);
        }
        my $eraw = je($raw);
        my @ips = split(/,/, $aips);
        my $ips_json = join(",", map { qq("$_") } @ips);
        $inner .= qq("allowed_ips":[$ips_json],);
        $inner .= qq("client_ip":"$cip","client_priv_key":"$cpk",);
        if (defined $psk && $psk ne "") {
            my $epsk = je($psk);
            $inner .= qq("psk_key":"$epsk",);
        }
        $inner .= qq("config":"$eraw",);
        $inner .= qq("hostName":"$ep","mtu":"1280",);
        $inner .= qq("persistent_keep_alive":"33","port":$port,);
        $inner .= qq("server_pub_key":"$spk"});

        my $einner = je($inner);
        my $outer = "{";
        $outer .= qq("containers":[{"awg":{"isThirdPartyConfig":true,);
        $outer .= qq("last_config":"$einner",);
        $outer .= qq("port":"$port","protocol_version":"2",);
        $outer .= qq("transport_proto":"udp"\},"container":"amnezia-awg"\}],);
        $outer .= qq("defaultContainer":"amnezia-awg",);
        $outer .= qq("description":"AWG Server",);
        $outer .= qq("dns1":"1.1.1.1","dns2":"1.0.0.1",);
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
        "${AWG_I1:-}" "${AWG_I2:-}" "${AWG_I3:-}" "${AWG_I4:-}" "${AWG_I5:-}" "$AWG_PORT" "$endpoint" \
        "$client_ip" "$client_privkey" "$server_pubkey" "$allowed_ips" "$client_psk" 2>"$perl_err"
    )

    if [[ -z "$vpn_uri" ]]; then
        log_warn "Ошибка генерации vpn:// URI для '$name'."
        [[ -s "$perl_err" ]] && log_warn "Perl: $(cat "$perl_err")"
        rm -f "$perl_err"
        return 1
    fi
    rm -f "$perl_err"

    echo "$vpn_uri" > "$uri_file"
    chmod 600 "$uri_file"
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
    local tmp_png="${png_file}.tmp.$$"

    if [[ ! -f "$uri_file" ]]; then
        log_error "vpn:// URI для '$name' не найден: $uri_file"
        return 1
    fi

    if ! command -v qrencode &>/dev/null; then
        log_warn "qrencode не установлен, QR vpn:// не создан для '$name'."
        return 1
    fi

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

    mv -f "$tmp_png" "$png_file"
    log_debug "QR vpn:// для '$name' создан: $png_file"
    return 0
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

    # Загружаем параметры
    load_awg_params || return 1

    # Опциональный PresharedKey: "auto" → `awg genpsk`, иначе используем
    # переданное значение как есть. Пустое/unset → без PSK.
    if [[ "${CLIENT_PSK:-}" == "auto" ]]; then
        CLIENT_PSK=$(awg genpsk) || {
            log_warn "awg genpsk не сработал — клиент будет создан без PresharedKey"
            CLIENT_PSK=""
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

    # Генерация ключей
    generate_keypair "$name" || { exec {lock_fd}>&-; return 1; }

    # Следующий свободный IP
    local client_ip
    client_ip=$(get_next_client_ip) || { exec {lock_fd}>&-; return 1; }

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
    client_privkey=$(cat "$KEYS_DIR/${name}.private") || { exec {lock_fd}>&-; return 1; }
    client_pubkey=$(cat "$KEYS_DIR/${name}.public") || { exec {lock_fd}>&-; return 1; }

    # Пытаемся восстановить server_public.key из awg0.conf если кеша нет
    # (поддержка ручных установок без installer-шага 6).
    _ensure_server_public_key || { exec {lock_fd}>&-; return 1; }
    server_pubkey=$(cat "$AWG_DIR/server_public.key") || { exec {lock_fd}>&-; return 1; }

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
        log_error "Не удалось определить внешний IP сервера. Используйте --endpoint=IP"
        exec {lock_fd}>&-
        return 1
    fi

    # Конфиг клиента
    render_client_config "$name" "$client_ip" "$client_privkey" "$server_pubkey" "$endpoint" "${AWG_PORT}" "$client_ipv6" || {
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
    local client_privkey client_ip server_pubkey
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
    local client_ipv6=""
    client_ipv6=$(get_client_ipv6_from_server "$name" 2>/dev/null || true)

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
        local _v
        _v=$(sed -n 's/^DNS[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
        [[ -n "$_v" ]] && current_dns="$_v"
        _v=$(sed -n 's/^PersistentKeepalive[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
        [[ -n "$_v" ]] && current_keepalive="$_v"
        _v=$(sed -n '/^\[Peer\]/,$ s/^AllowedIPs[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
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
    fi
    if awg_ipv6_enabled && [[ -n "$client_ipv6" && "$current_allowed_ips" != *"::/0"* ]]; then
        current_allowed_ips="${current_allowed_ips},::/0"
    fi

    # Перегенерация конфига
    render_client_config "$name" "$client_ip" "$client_privkey" "$server_pubkey" "$endpoint" "${AWG_PORT}" "$client_ipv6" || {
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    }

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
    if ! sed -i "s|^AllowedIPs = .*|AllowedIPs = ${_aip}|" "$_client_conf"; then
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

generate_runtime_awg_profile() {
    local preset="${1:-default}" h_lines
    case "$preset" in
        mobile)
            AWG_PRESET="mobile"
            AWG_Jc=3
            AWG_Jmin=$(awg_rand_range 30 50)
            AWG_Jmax=$(( AWG_Jmin + $(awg_rand_range 20 80) ))
            AWG_S1=$(awg_rand_range 15 150)
            AWG_S2=$(awg_rand_range 15 150)
            while [[ $((AWG_S1 + 56)) -eq $AWG_S2 ]]; do AWG_S2=$(awg_rand_range 15 150); done
            AWG_S3=$(awg_rand_range 0 10)
            AWG_S4=$(awg_rand_range 0 10)
            ;;
        default)
            AWG_PRESET="default"
            AWG_Jc=$(awg_rand_range 3 6)
            AWG_Jmin=$(awg_rand_range 40 89)
            AWG_Jmax=$(( AWG_Jmin + $(awg_rand_range 50 150) ))
            AWG_S1=$(awg_rand_range 15 150)
            AWG_S2=$(awg_rand_range 15 150)
            while [[ $((AWG_S1 + 56)) -eq $AWG_S2 ]]; do AWG_S2=$(awg_rand_range 15 150); done
            AWG_S3=$(awg_rand_range 8 55)
            AWG_S4=$(awg_rand_range 4 32)
            ;;
        *)
            log_error "Unknown preset: $preset"
            return 1
            ;;
    esac
    mapfile -t h_lines < <(generate_awg_h_ranges_runtime) || true
    [[ ${#h_lines[@]} -eq 4 ]] || { log_error "Failed to generate H ranges"; return 1; }
    AWG_H1="${h_lines[0]}"; AWG_H2="${h_lines[1]}"; AWG_H3="${h_lines[2]}"; AWG_H4="${h_lines[3]}"
    AWG_I1="$(generate_cps_i1_runtime)"
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
            out.append(f"export {key}={val}" if re.fullmatch(r"[0-9]+", val) else f"export {key}='{val}'")
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
    generate_firewall_scripts >/dev/null 2>&1 || log_warn "Failed to update firewall hook scripts."
    if ! apply_config; then
        log_error "apply_config failed after rotate-profile; rolling back."
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
    local _v
    _v=$(sed -n 's/^DNS[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
    [[ -n "$_v" ]] && current_dns="$_v"
    _v=$(sed -n 's/^PersistentKeepalive[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
    [[ -n "$_v" ]] && current_keepalive="$_v"
    _v=$(sed -n '/^\[Peer\]/,$ s/^AllowedIPs[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
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
    if ! render_client_config "$name" "$client_ip" "$client_privkey" "$server_pubkey" "$endpoint" "${AWG_PORT}" "$client_ipv6"; then
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
       ! sed -i "s/^PersistentKeepalive = .*/PersistentKeepalive = ${_ka}/" "$_client_conf" ||
       ! sed -i "s|^AllowedIPs = .*|AllowedIPs = ${_aip}|" "$_client_conf"; then
        log_error "Ошибка обновления пользовательских параметров в $_client_conf"
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

    for param in "${int_params[@]}"; do
        val=$(sed -n "s/^${param} = //p" "$SERVER_CONF_FILE" | head -1)
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
    jc=$(sed -n 's/^Jc = //p' "$SERVER_CONF_FILE" | head -1)
    jmin=$(sed -n 's/^Jmin = //p' "$SERVER_CONF_FILE" | head -1)
    jmax=$(sed -n 's/^Jmax = //p' "$SERVER_CONF_FILE" | head -1)
    s3=$(sed -n 's/^S3 = //p' "$SERVER_CONF_FILE" | head -1)
    s4=$(sed -n 's/^S4 = //p' "$SERVER_CONF_FILE" | head -1)
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

    for param in "${range_params[@]}"; do
        val=$(sed -n "s/^${param} = //p" "$SERVER_CONF_FILE" | head -1)
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
            fi
        fi
    done

    # I1 опционален, но рекомендован для AWG 2.0
    if ! grep -q "^I1 = " "$SERVER_CONF_FILE"; then
        log_warn "Параметр I1 (CPS) не найден — CPS concealment не активен"
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
EXPIRY_CRON="/etc/cron.d/awg-expiry"

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
            if remove_peer_from_server "$name" 2>/dev/null; then
                rm -f "$AWG_DIR/$name.conf" "$AWG_DIR/$name.png" "$AWG_DIR/$name.vpnuri"
                rm -f "$KEYS_DIR/${name}.private" "$KEYS_DIR/${name}.public"
                rm -f "$efile"
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
    if [[ -f "$EXPIRY_CRON" ]]; then
        log_debug "Cron-задача expiry уже установлена."
        return 0
    fi
    cat > "$EXPIRY_CRON" << CRONEOF
# AmneziaWG client expiry check — every 5 minutes
AWG_DIR="${AWG_DIR}"
CONFIG_FILE="${CONFIG_FILE}"
SERVER_CONF_FILE="${SERVER_CONF_FILE}"
*/5 * * * * root /bin/bash -c 'source "${AWG_DIR}/awg_common.sh" || exit 1; check_expired_clients' >> "${AWG_DIR}/expiry.log" 2>&1
CRONEOF
    chmod 644 "$EXPIRY_CRON"
    log "Cron-задача expiry установлена: $EXPIRY_CRON"
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
