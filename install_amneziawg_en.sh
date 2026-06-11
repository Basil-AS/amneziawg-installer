#!/bin/bash
# shellcheck disable=SC1003,SC2012,SC2015,SC2016,SC2004,SC2086,SC2317

# Minimum Bash version check
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ERROR: Bash >= 4.0 required (current: ${BASH_VERSION})" >&2; exit 1
fi

# ==============================================================================
# AmneziaWG 2.0 installation and configuration script for Ubuntu/Debian servers
# Author: @bivlked
# Version: 5.13.0
# Date: 2026-05-13
# Repository: https://github.com/bivlked/amneziawg-installer
# ==============================================================================

# --- Safe mode and Constants ---
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

# SHA256 manifest for remote bootstrap assets. Local files next to the installer
# are used first; remote download is allowed only with pinned SHA256 or explicit
# AWG_ALLOW_UNVERIFIED_DOWNLOAD=1 for development.
declare -A AWG_ASSET_SHA256=(
    ["awg_common_en.sh"]="a140a78d065b4a8b1479138854dea033447e4f93e42086068bef19c553601e74"
    ["manage_amneziawg_en.sh"]="4c5e12156177fc5a58957f45744b81abae85b1a778d45298c7742efb836f698a"
    ["web/server.py"]="fea50ad7a6cb9fe649d177d9e6c25166cb3347b9ca60884d54bd0782ddc4af6e"
    ["web/index.html"]="7c07ed1d1991e08c0f9fc31e86ed8eb2bba5fa96387088f1f18918396cf7e662"
    ["web/app.js"]="881f9f54d9158bc0c337d8af5da7d7e3e44f03cea5e31f660892ef930112a661"
    ["web/awg_i1.js"]="c97a6ac6c4e4bd7ab24c37c45f451e364414f276441f8da1c0805d26013aaa03"
    ["web/style.css"]="90233eda8fb57f3020cc3826a6dc17be41206bc839a0e31e657b96adfb974345"
    ["web/favicon.svg"]="ae700ecb12dbf01403d0ed25247bac6b70f11201b094ee6c14b774b7fa533859"
    ["web/vendor/tailwindcss.js"]="176e894661aa9cdc9a5cba6c720044cbbf7b8bd80d1c9a142a7c24b1b6c50d15"
    ["web/vendor/apexcharts.min.js"]="a7400cd48b40b4f39d1c15137ae0cc8cbec31dc2b55a606640f1cd11912416dd"
    ["scripts/update_geoip_dbs.py"]="e912ecc497df2b0aaa02bace2a8e0707d5263b4165b5f8c4ea09962db5517bee"
)

# CLI flags
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
CLI_ENABLE_GEOIP_AUTO_UPDATE=0
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

# --- Auto-cleanup of temporary files ---
_install_temp_files=()
_install_cleanup() {
    local f
    for f in "${_install_temp_files[@]}"; do [[ -f "$f" ]] && rm -f "$f"; done
    type ufw_remove_http01_temporary_rule &>/dev/null && ufw_remove_http01_temporary_rule
    # Clean up temporary files from awg_common.sh (if already sourced)
    type _awg_cleanup &>/dev/null && _awg_cleanup
}
handle_interrupt() {
    trap - INT TERM EXIT
    echo >&2
    if declare -F log_msg >/dev/null 2>&1; then
        log_msg "WARN" "Installation interrupted by user (Ctrl-C)."
        log_msg "WARN" "Partial files may remain in $AWG_DIR. To clean up, run: sudo bash ./install_amneziawg.sh --uninstall"
    else
        echo "WARN: Installation interrupted by user (Ctrl-C)." >&2
        echo "WARN: Partial files may remain in $AWG_DIR. To clean up, run: sudo bash ./install_amneziawg.sh --uninstall" >&2
    fi
    _install_cleanup
    exit 130
}
trap _install_cleanup EXIT
trap handle_interrupt INT TERM

# --- Argument processing ---
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
        --enable-geoip-auto-update) CLI_ENABLE_GEOIP_AUTO_UPDATE=1 ;;
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
        *) echo "Unknown argument: $1"; HELP=1 ;;
    esac
    shift
done

# ==============================================================================
# Logging functions
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
        echo "[$ts] ERROR: Log write error $LOG_FILE" >&2
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
die()       { log_error "CRITICAL ERROR: $1"; log_error "Installation aborted. Log: $LOG_FILE"; exit 1; }

# ==============================================================================
# apt-get update wrapper that tolerates 404s only for source packages (deb-src).
# INLINE: needed in steps 1-2 before awg_common.sh is downloaded (Step 5).
# Some mirrors (Hetzner, AWS) do not serve source packages, but the default
# ubuntu.sources contains 'Types: deb deb-src'. We do not need source packages
# (kernel module is built via DKMS using binary headers), so such 404s are safe
# to ignore. Returns 0 if update succeeded OR if all errors are on source markers.
# Any other error (GPG, binary-package network, silent crash / OOM / SIGKILL) → non-zero.
# ==============================================================================
apt_update_tolerant() {
    # --ppa-amnezia-tolerant: also ignore errors from the Amnezia PPA. Used
    # in step 2 — apt_wait_for_ppa_package below already retries for the
    # ppa.launchpadcontent.net outage scenario (issue #68). Without this
    # flag we must fail fast on any non-source error, otherwise the script
    # would continue installing on a stale apt-cache (PR #69 review finding).
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

    # Filter error lines. Ignore:
    #   1. Lines about source packages (deb-src / /source/ / Sources)
    #   2. Generic 'Some index files failed to download' — symptom, not cause
    non_src_errors=$(printf '%s\n' "$err_output" \
        | grep -E '^(E:|Err:|W:)' \
        | grep -vE '(deb-src|/source/|Sources([^[:alpha:]]|$))' \
        | grep -vE 'Some index files failed to download' || true)

    # Remember pre-PPA-filter state — we need to distinguish "real APT errors,
    # but all on Amnezia PPA" (tolerant OK) from "no classifiable errors at all"
    # (OOM / silent crash — NOT tolerant even if the output happens to mention
    # a PPA URL elsewhere).
    [[ -n "$non_src_errors" ]] && raw_had_non_src_errors=1

    # Optional (step 2): drop errors that are only on the Amnezia PPA — they
    # will be re-checked via apt_wait_for_ppa_package against apt-cache (issue #68).
    if [[ $ppa_tolerant -eq 1 && -n "$non_src_errors" ]]; then
        non_src_errors=$(printf '%s\n' "$non_src_errors" \
            | grep -vE 'ppa\.launchpadcontent\.net.*amnezia' || true)
    fi

    if [[ -z "$non_src_errors" ]]; then
        # Edge case: rc != 0 but no classifiable E:/Err:/W: lines found
        # (OOM-killer SIGKILL, silent crash, unknown apt output format).
        # Ignore ONLY if the output actually contains source-markers, or if
        # ppa-tolerant + there were real APT lines and all of them were on the
        # Amnezia PPA.
        if printf '%s\n' "$err_output" | grep -qE '(deb-src|/source/|Sources([^[:alpha:]]|$))'; then
            log_warn "apt update: source packages unavailable in mirror (expected, ignored)"
            return 0
        fi
        if [[ $ppa_tolerant -eq 1 && $raw_had_non_src_errors -eq 1 ]] \
            && printf '%s\n' "$err_output" | grep -qE 'ppa\.launchpadcontent\.net.*amnezia'; then
            log_warn "apt update: errors only on Amnezia PPA (issue #68), continuing with retry."
            return 0
        fi
        log_error "apt update exited with rc=$rc without any classifiable APT lines — possible silent crash / OOM / SIGKILL"
        return "$rc"
    fi

    log_error "apt update failed with non-source errors:"
    printf '%s\n' "$non_src_errors" | while IFS= read -r line; do
        log_error "  $line"
    done
    return "$rc"
}

# ==============================================================================
# apt_wait_for_ppa_package <package> [max_attempts] [initial_delay_seconds]
#   Waits until the given package becomes visible in apt-cache, with
#   exponential backoff between attempts. Needed in step 2 after the
#   Amnezia PPA is added: ppa.launchpadcontent.net sometimes briefly
#   goes down (issue #68), and without retries the first cold install
#   fails even though the PPA is back a minute later.
#
#   IMPORTANT: this checks apt-cache show, not the rc of apt-get update.
#   apt-get update returns 0 tolerantly even when an InRelease file did
#   not download — so a plain rc-based retry does not catch a PPA outage.
#   Package visibility in apt-cache is the only reliable signal that
#   the PPA actually got indexed.
#
#   With the defaults (3 attempts × initial=30s) the timeline is:
#   attempt 1 → sleep 30s → apt update + attempt 2 → sleep 60s →
#   apt update + attempt 3 (last). After the third fail we return 1.
#   Total wait between attempts is about 1.5 minutes.
#
#   The 1800s delay cap guards against arithmetic overflow if the helper
#   is ever called with a very large max.
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
        log_warn "Package '${pkg}' did not appear in apt-cache (attempt ${attempt}/${max}, PPA still unavailable), retrying in ${delay}s..."
        sleep "$delay"
        apt_update_tolerant >/dev/null 2>&1 || true
        delay=$(( delay * 2 > 1800 ? 1800 : delay * 2 ))
    done
    return 1
}

# ==============================================================================
# Help
# ==============================================================================

show_help() {
    cat << 'EOF'
Usage: sudo bash install_amneziawg_en.sh [OPTIONS]
Script for installation and configuration of AmneziaWG 2.0 on Ubuntu (24.04 / 25.10) and Debian (12 / 13).

Options:
  -h, --help            Show this help and exit
  --uninstall           Uninstall AmneziaWG and all its configurations
  --diagnostic          Generate diagnostic report and exit
  -v, --verbose         Verbose output for debugging (including DEBUG)
  --no-color            Disable colored terminal output
  --port=NUMBER         Set UDP port (1024-65535) non-interactively
  --subnet=SUBNET       Set tunnel subnet (x.x.x.x/yy) non-interactively
  --allow-ipv6          Keep IPv6 enabled non-interactively
  --disallow-ipv6       Force-disable IPv6 non-interactively
  --enable-native-ipv6  Compatibility alias: enable client IPv6
  --ipv6-mode=MODE      Client IPv6 mode: auto, routed, ndp, nat66, block, or legacy
  --ipv6-subnet=CIDR    Set client IPv6 /48../64 (for example 2001:db8:1::/64)
  --upgrade-ipv6        Migrate existing clients to IPv6/P2P metadata
  --p2p-base-port=PORT  Base P2P port (default 20000; range base+1..base+1024)
  --p2p-ports-per-client=N
                        P2P ports for each new client (default 3)
  --fullcone-nat        Try FULLCONENAT instead of MASQUERADE for IPv4
  --web-port=PORT       Web panel HTTPS port (default 8443)
  --web-bind=ADDR       Web panel bind address (default 10.9.9.1, inside the VPN)
                        0.0.0.0 exposes the panel publicly; use only intentionally
  --web-cert-mode=MODE  TLS mode: selfsigned, custom, letsencrypt, ip-domain
  --web-domain=DOMAIN   Domain for letsencrypt/custom summary
  --web-cert-file=PATH  fullchain.pem for --web-cert-mode=custom
  --web-key-file=PATH   privkey.pem for --web-cert-mode=custom
  --web-cert-provider=sslip.io|nip.io  ip-domain provider (default: sslip.io)
  --web-le-email=EMAIL  Email for Let's Encrypt notices (optional)
  --web-cert-fallback=selfsigned|abort
                        Let's Encrypt failure behavior (default: abort with --yes, prompt in wizard)
  --allow-ppa-codename-fallback
                        Explicitly allow Ubuntu non-LTS PPA codename fallback to noble
  --disable-web         Do not install/start the web panel
  --enable-adguard      Install AdGuard Home and give clients DNS 10.9.9.1
  --disable-adguard     Do not install AdGuard Home and use system DNS
  --adguard-port=PORT   AdGuard Home HTTP port on localhost/VPN (default 3000)
  --enable-geoip-auto-update
                        Enable a weekly systemd timer that auto-updates GeoIP MMDB databases
  --dns-mode=MODE       Client DNS mode: adguard, system, or custom
  --wiresock-hints=MODE WireSock hints: off, auto, mobile, quic, or dns (default: quic)
  --disable-wiresock-hints
  --wiresock-id=DOMAIN  Domain for #@ws:Id
  --wiresock-ip=quic|dns Value for #@ws:Ip
  --wiresock-ib=curl|chrome Value for #@ws:Ib
  --server-name=NAME    Server name in .conf and vpn:// (default MyVPN)
  --route-all           Use 'All traffic' mode non-interactively
  --route-amnezia       Use 'Amnezia' mode non-interactively
  --route-custom=NETS   Use 'Custom' mode non-interactively
  --endpoint=IP         Specify external server IP (for servers behind NAT)
  --ssh-port=PORT[,PORT]
                        Explicitly open SSH port(s) in UFW; otherwise autodetect
  -y, --yes             Auto-confirm (reboots, UFW, etc.)
  -f, --force           Force reinstall on top of an already-running AmneziaWG
                        (by default a run on a configured server aborts;
                        ENV: AWG_FORCE_REINSTALL=1 is equivalent to the flag)
  --no-tweaks           Skip hardening/optimization (no UFW, Fail2Ban, sysctl tweaks)
  --disable-ufw         Do not enable UFW; firewall/NAT responsibility is external/manual
  --preset=TYPE         Obfuscation parameter preset: default, mobile
                        mobile: Jc=3, narrow Jmax — for mobile carriers (Tele2, Yota, Megafon)
  --jc=N               Set Jc manually (1-128, overrides preset)
  --jmin=N             Set Jmin manually (0-1280, overrides preset)
  --jmax=N             Set Jmax manually (0-1280, overrides preset, must be >= Jmin)

Examples:
  sudo bash install_amneziawg_en.sh                             # Interactive installation
  sudo bash install_amneziawg_en.sh --port=51820 --route-all    # Non-interactive
  sudo bash install_amneziawg_en.sh --route-amnezia --yes       # Fully automated
  sudo bash install_amneziawg_en.sh --preset=mobile --yes       # Optimized for mobile networks
  sudo bash install_amneziawg_en.sh --uninstall                 # Uninstall
  sudo bash install_amneziawg_en.sh --diagnostic                # Diagnostics

Repository: https://github.com/bivlked/amneziawg-installer
EOF
    exit 0
}

# ==============================================================================
# Utilities and validation
# ==============================================================================

update_state() {
    local next_step=$1
    mkdir -p "$(dirname "$STATE_FILE")"
    # Atomic write: tmp-file + flock + mv. Protects against a truncated
    # state file if the process is killed / power-lost between write and close.
    (
        flock -x 200
        local tmp="${STATE_FILE}.tmp.$BASHPID"
        if printf '%s\n' "$next_step" > "$tmp" && mv -f "$tmp" "$STATE_FILE"; then
            exit 0
        fi
        rm -f "$tmp" 2>/dev/null
        exit 1
    ) 200>"${STATE_FILE}.lock" || die "Failed to write state"
    log "State: next step - $next_step"
}

request_reboot() {
    local next_step=$1
    update_state "$next_step"

    # Capture boot_id before the 1→2 reboot gate. On step 2 entry we
    # compare it with the current boot_id — if they match, the user did
    # not reboot, which means apt full-upgrade staged a new kernel on
    # disk but the running kernel is still the old one. DKMS would build
    # the module against the old kernel and modprobe would fail after
    # the next reboot. Fail fast instead.
    if [[ "$next_step" == "2" ]] && [[ -r /proc/sys/kernel/random/boot_id ]]; then
        if cat /proc/sys/kernel/random/boot_id > "$AWG_DIR/.boot_id_before_step2" 2>/dev/null; then
            log_debug "boot_id captured before reboot"
        fi
    fi

    echo "" >> "$LOG_FILE"
    log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    log_warn "!!! SYSTEM REBOOT REQUIRED                                !!!"
    log_warn "!!! After reboot, run the script again:                   !!!"
    log_warn "!!! sudo bash $0 [with the same parameters, if any]      !!!"
    log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "" >> "$LOG_FILE"
    local confirm="y" reboot_choice_rc=0
    if [[ "$AUTO_YES" -eq 0 ]]; then
        while true; do
            if ! read -rp "Reboot now? [Y/n]: " confirm < /dev/tty; then
                log_warn "No interactive TTY is available for reboot confirmation. Reboot manually and run the script again."
                exit 1
            fi
            parse_reboot_choice "$confirm"
            reboot_choice_rc=$?
            case "$reboot_choice_rc" in
                0|1) break ;;
                *) log_warn "Enter y/yes or n/no." ;;
            esac
        done
    else
        log "Auto-confirming reboot (--yes)."
    fi
    if [[ "$AUTO_YES" -eq 1 || "$reboot_choice_rc" -eq 0 ]]; then
        log "Reboot initiated..."
        sleep 5
        if ! reboot; then die "Reboot command failed."; fi
        exit 1
    else
        log "Reboot cancelled. Reboot manually and run the script again."
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
    log "Checking OS..."

    # Detection via /etc/os-release (universal for Ubuntu and Debian)
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
        log_warn "Cannot detect OS (/etc/os-release and lsb_release not found)."
        return 0
    fi
    export OS_ID OS_VERSION OS_CODENAME

    # Supported OS
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
        log "OS: ${OS_ID^} $OS_VERSION ($OS_CODENAME) — supported"
    else
        log_warn "Detected $OS_ID $OS_VERSION ($OS_CODENAME). Script tested on Ubuntu 24.04/25.10 and Debian 12/13."
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Continue? [y/N]: " confirm < /dev/tty
            if ! [[ "$confirm" =~ ^[Yy]$ ]]; then die "Cancelled."; fi
        else
            log "Continuing on $OS_ID $OS_VERSION (--yes)."
        fi
    fi
}

check_free_space() {
    log "Checking disk space..."
    local req=2048
    local avail
    avail=$(df -m / | awk 'NR==2 {print $4}')
    if [[ -z "$avail" ]]; then
        log_warn "Failed to determine free space."
        return 0
    fi
    if [ "$avail" -lt "$req" ]; then
        log_warn "Available $avail MB. Recommended >= $req MB."
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Continue? [y/N]: " confirm < /dev/tty
            if ! [[ "$confirm" =~ ^[Yy]$ ]]; then die "Cancelled."; fi
        else
            log "Continuing with $avail MB (--yes)."
        fi
    else
        log "Free: $avail MB (OK)"
    fi
}

check_port_availability() {
    local port=$1
    log "Checking port $port..."
    local proc
    proc=$(ss -lunp | grep ":${port} ")
    if [[ -n "$proc" ]]; then
        log_error "Port ${port}/udp already in use! Process: $proc"
        return 1
    else
        log "Port $port/udp is free."
        return 0
    fi
}

check_web_port_availability() {
    [[ "${AWG_WEB_ENABLED:-1}" -eq 1 ]] || return 0
    is_public_web_bind || return 0
    [[ "${AWG_WEB_PORT:-8443}" == "443" ]] || return 0
    log "Checking port 443/tcp for public Web Panel..."
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)443$'; then
        if [[ "$AUTO_YES" -eq 0 && -z "$CLI_WEB_PORT" && "$ENV_AWG_WEB_PORT_SET" -eq 0 ]]; then
            local fallback
            read -rp "Port 443/tcp is busy. Use 8443 instead of 443? [y/N]: " fallback < /dev/tty
            if [[ "$fallback" =~ ^[Yy]$ ]]; then
                AWG_WEB_PORT=8443
                return 0
            fi
        fi
        die "Port 443/tcp is busy; choose another --web-port or free the port."
    fi
}

install_packages() {
    local packages=("$@")
    local to_install=()
    local pkg
    log "Checking packages: ${packages[*]}..."
    for pkg in "${packages[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            to_install+=("$pkg")
        fi
    done
    if [ ${#to_install[@]} -eq 0 ]; then
        log "All packages already installed."
        return 0
    fi
    log "Installing: ${to_install[*]}..."
    if [[ "${_APT_UPDATED:-0}" -eq 0 ]]; then
        apt_update_tolerant || log_warn "Failed to update apt."
        _APT_UPDATED=1
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt install -y "${to_install[@]}"; then
        # v5.13.0: typical failure on 25.10/26.04 after an in-place upgrade
        # from 24.04 — the amneziawg-dkms postinst runs `dkms autoinstall`
        # which iterates over ALL kernels in /lib/modules/. The leftover
        # 6.8.x headers were compiled with gcc-13, but 25.10 ships only
        # gcc-15 by default → autoinstall fails, dpkg leaves the dependent
        # amneziawg-tools / amneziawg unconfigured. Force-build the module
        # for the running kernel only and finish with dpkg --configure -a.
        if printf '%s\n' "${to_install[@]}" | grep -qx "amneziawg-dkms"; then
            log_warn "apt install did not complete — trying a DKMS build for the running kernel $(uname -r) only..."
            local _mver
            _mver="$(ls /var/lib/dkms/amneziawg/ 2>/dev/null | head -n1)"
            if [[ -n "$_mver" ]] \
               && dkms install -m amneziawg -v "$_mver" -k "$(uname -r)" --force \
               && DEBIAN_FRONTEND=noninteractive dpkg --configure -a; then
                log "DKMS module built for $(uname -r), dpkg configured."
                log "Packages installed."
                return 0
            fi
        fi
        die "Package installation error."
    fi
    log "Packages installed."
}

cleanup_apt() {
    log "Cleaning apt..."
    apt-get clean || log_warn "apt-get clean error"
    rm -rf /var/lib/apt/lists/* || log_warn "rm /var/lib/apt/lists/* error"
    log "apt cache cleared."
}

configure_ipv6() {
    if [[ "$CLI_DISABLE_IPV6" != "default" ]]; then
        DISABLE_IPV6=$CLI_DISABLE_IPV6
        log "IPv6 from CLI: $DISABLE_IPV6"
    elif [[ "$AUTO_YES" -eq 1 ]]; then
        DISABLE_IPV6=1
        log "IPv6 disabled (--yes, default)."
    else
        read -rp "Disable IPv6 (recommended)? [Y/n]: " dis_ipv6 < /dev/tty
        if [[ "$dis_ipv6" =~ ^[Nn]$ ]]; then
            DISABLE_IPV6=0
        else
            DISABLE_IPV6=1
        fi
    fi
    export DISABLE_IPV6
    log "IPv6 disable: $(if [ "$DISABLE_IPV6" -eq 1 ]; then echo 'Yes'; else echo 'No'; fi)"
}

shell_quote() {
    local s="$1"
    s="${s//\'/\'\\\'\'}"
    printf "'%s'" "$s"
}

# Safe configuration loader (whitelist parser, no source/eval)
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

# Read a single key from config (for point queries)
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
        die "Invalid port: '$port'. Allowed range: 1024-65535."
    fi
}

validate_port_system() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]]
}

validate_web_port() {
    local port="$1"
    if ! validate_port_system "$port"; then
        die "Invalid Web Panel HTTPS port: '$port'. Allowed range: 1-65535."
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
    python3 - "$bind" <<'PY2'
import ipaddress, sys
try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
PY2
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
        die "Invalid subnet: '$subnet'. Only /24 is supported."
    fi
    if [[ "${BASH_REMATCH[4]}" -eq 0 ]] || [[ "${BASH_REMATCH[4]}" -eq 255 ]]; then
        die "Invalid subnet: '$subnet'. Last octet cannot be 0 (network address) or 255 (broadcast)."
    fi
    if [[ "${BASH_REMATCH[4]}" -ne 1 ]]; then
        die "Invalid subnet: '$subnet'. Last octet must be 1 (server address in subnet)."
    fi
}

# Endpoint validation (FQDN / IPv4 / [IPv6]).
# Returns 0 if the endpoint is safe and matches one of the formats,
# otherwise 1 (the caller decides between die or log_warn + unset).
# Forbids newline/CR/quotes/backslash to prevent injection into
# awgsetup_cfg.init and client.conf via the --endpoint flag (audit).
validate_endpoint() {
    local ep="$1"
    [[ -n "$ep" ]] || return 1
    # Forbid characters that could break the config or inject content
    [[ "$ep" != *$'\n'* && "$ep" != *$'\r'* && \
       "$ep" != *"'"* && "$ep" != *'"'* && "$ep" != *'\\'* && \
       "$ep" != *' '* && "$ep" != *$'\t'* ]] || return 1
    # One of three formats: FQDN, IPv4, [IPv6]
    [[ "$ep" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*|[0-9]{1,3}(\.[0-9]{1,3}){3}|\[[0-9A-Fa-f:]+\])$ ]] || return 1
    # If IPv4 format — additionally validate octet range 0-255
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
            die "Invalid --ipv6-mode: '$CLI_IPV6_MODE' (expected auto, routed, ndp, nat66, block or legacy)."
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
        validate_ipv6_subnet "$CLI_IPV6_SUBNET" || die "Invalid --ipv6-subnet: '$CLI_IPV6_SUBNET'. IPv6 /48../64 is required."
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
                routed) die "IPv6 mode routed requires a dedicated routed IPv6 prefix. Provide --ipv6-subnet=... or choose auto/ndp/nat66." ;;
                ndp) die "IPv6 mode ndp requires public IPv6 /64. Provide --ipv6-subnet=... or choose auto/nat66." ;;
                *) die "Failed to select IPv6 mode '$requested_mode'." ;;
            esac
        fi
        if [[ "$AWG_IPV6_MODE" == "nat66" && -n "$AWG_IPV6_SUBNET" && "$AWG_IPV6_SUBNET" != fd* && "$AWG_IPV6_SUBNET" != FD* ]]; then
            log_warn "NAT66 usually uses ULA fd../64; keeping the provided subnet as-is: $AWG_IPV6_SUBNET"
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
            if [ -z "$ALLOWED_IPS" ]; then die "No networks specified for --route-custom."; fi
        fi
        log "Routing mode from CLI: $ALLOWED_IPS_MODE"
    elif [[ "$AUTO_YES" -eq 1 ]]; then
        ALLOWED_IPS_MODE=2
        log "Routing mode: Amnezia+DNS (--yes, default)."
    else
        echo ""
        log "Select routing mode (client AllowedIPs):"
        echo "  1) All traffic (0.0.0.0/0) - Max privacy, may block LAN"
        echo "  2) Amnezia List+DNS (default) - Recommended for bypassing restrictions"
        echo "  3) Only specified networks (Split Tunneling)"
        read -rp "Your choice [2]: " r_mode < /dev/tty
        ALLOWED_IPS_MODE=${r_mode:-2}
    fi
    case "$ALLOWED_IPS_MODE" in
        1) ALLOWED_IPS="0.0.0.0/0"
           log "Selected mode: All traffic." ;;
        3) if [[ -z "$CLI_CUSTOM_ROUTES" ]]; then
               read -rp "Enter networks (a.b.c.d/xx,...): " ALLOWED_IPS < /dev/tty
               while ! validate_cidr_list "$ALLOWED_IPS"; do
                   log_warn "Invalid CIDR format: '$ALLOWED_IPS'. Expected: x.x.x.x/y[,x.x.x.x/y]"
                   read -rp "Try again: " ALLOWED_IPS < /dev/tty
               done
           else
               ALLOWED_IPS=$CLI_CUSTOM_ROUTES
               if ! validate_cidr_list "$ALLOWED_IPS"; then
                   die "Invalid CIDR format: '$ALLOWED_IPS'. Expected: x.x.x.x/y[,x.x.x.x/y]"
               fi
           fi
           log "Selected mode: Custom ($ALLOWED_IPS)" ;;
        *) ALLOWED_IPS_MODE=2
           ALLOWED_IPS="0.0.0.0/5, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/6, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.0.0/9, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4, 8.8.8.8/32, 1.1.1.1/32"
           log "Selected mode: Amnezia List+DNS." ;;
    esac
    if [ -z "$ALLOWED_IPS" ]; then die "Failed to determine AllowedIPs."; fi
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
        read -rp "Enter server name [${AWG_SERVER_NAME:-MyVPN}]: " input_name < /dev/tty
        input_name="${input_name:-${AWG_SERVER_NAME:-MyVPN}}"
        if validate_server_name "$input_name"; then
            AWG_SERVER_NAME="$input_name"
            break
        fi
        log_warn "Invalid server name: empty, too long, or contains a newline."
    done
}

prompt_endpoint() {
    [[ "$AUTO_YES" -eq 0 && -z "$CLI_ENDPOINT" && "$ENV_AWG_ENDPOINT_SET" -eq 0 ]] || return 0
    local input_endpoint
    read -rp "Enter server public IP/domain or press Enter for auto-detect: " input_endpoint < /dev/tty
    if [[ -n "$input_endpoint" ]]; then
        validate_endpoint "$input_endpoint" || die "Invalid endpoint: '$input_endpoint'. Allowed formats: FQDN, IPv4, or [IPv6]."
        AWG_ENDPOINT="$input_endpoint"
        return 0
    fi
    if AWG_ENDPOINT=$(detect_endpoint_for_installer); then
        log "Endpoint auto-detected: $AWG_ENDPOINT"
    else
        AWG_ENDPOINT=""
        log_warn "Failed to auto-detect the public IP/domain. Endpoint will stay empty; check client configs after installation."
    fi
}

prompt_awg_preset() {
    [[ "$AUTO_YES" -eq 0 && -z "$CLI_PRESET" && "$ENV_AWG_PRESET_SET" -eq 0 ]] || return 0
    local preset_choice
    echo ""
    echo "Choose AWG parameter preset:"
    echo "  1) default - general purpose"
    echo "  2) mobile - mobile networks, Tele2/Yota/Megafon/LTE/5G"
    read -rp "Your choice [1]: " preset_choice < /dev/tty
    case "${preset_choice:-1}" in
        1) AWG_PRESET="default" ;;
        2) AWG_PRESET="mobile" ;;
        *) log_warn "Unknown preset '$preset_choice', using default."; AWG_PRESET="default" ;;
    esac
}

prompt_ipv6_mode() {
    [[ "$AUTO_YES" -eq 0 && -z "$CLI_IPV6_MODE" && -z "$CLI_IPV6_SUBNET" && "$ENV_AWG_IPV6_MODE_SET" -eq 0 && "$ENV_AWG_IPV6_SUBNET_SET" -eq 0 ]] || return 0
    [[ "${DISABLE_IPV6:-1}" -eq 0 ]] || return 0
    local ipv6_choice input_subnet
    echo ""
    echo "Choose IPv6 mode:"
    echo "  1) auto - auto-detect:"
    echo "     - routed when a dedicated routed IPv6 prefix is provided for VPN clients;"
    echo "     - ndp when using the public /64 already assigned to the external interface;"
    echo "     - nat66 when no public prefix is detected or routed/NDP are unsuitable."
    echo "  2) routed - dedicated routed IPv6 prefix (/64, /56, /48) assigned by provider for VPN clients"
    echo "  3) ndp - use the current public /64 on eth0 via NDP proxy"
    echo "  4) nat66 - NAT66 fallback"
    echo "  5) block - IPv4-only full tunnel routes ::/0 into VPN to reduce IPv6 leak risk"
    while true; do
        read -rp "Your choice [1]: " ipv6_choice < /dev/tty
        if AWG_IPV6_MODE_REQUESTED=$(resolve_ipv6_mode_choice "$ipv6_choice"); then
            break
        fi
        log_warn "Unknown IPv6 mode '$ipv6_choice'. Choose 1, 2, 3, 4 or 5."
    done
    AWG_IPV6_MODE="$AWG_IPV6_MODE_REQUESTED"
    case "$AWG_IPV6_MODE_REQUESTED" in
        routed)
            while true; do
                read -rp "Enter IPv6 subnet for clients, for example 2a13:...::/64: " input_subnet < /dev/tty
                validate_ipv6_subnet "$input_subnet" || { log_warn "Invalid IPv6 subnet. IPv6 /48../64 is required."; continue; }
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
    log_warn "WARNING: Web Panel will be reachable from the Internet (${AWG_WEB_BIND}:${AWG_WEB_PORT})."
    log_warn "Keep public access only if you understand the risk and use tokens/HTTPS."
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
        log_warn "Invalid choice '$value'. Allowed: $allowed"
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
        log_warn "Invalid port '$value'. Enter a number from 1024 to 65535."
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

        log_warn "Invalid Web Panel HTTPS port '$value'. Enter a number from 1 to 65535."
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
            *) log_warn "Enter y or n." ;;
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
        log_warn "Invalid domain. Use an FQDN without spaces or control characters."
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
        log_warn "Invalid client name. Use Latin letters, digits, '_' and '-'."
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
    echo "HTTPS setup for public Web Panel:"
    echo "  1) Your domain + Let's Encrypt - recommended for trusted HTTPS"
    echo "     Example: https://vpn.example.com/"
    echo "  2) Automatic IP domain sslip.io/nip.io + Let's Encrypt - experimental"
    if generated_domain=$(generate_ip_domain "${AWG_ENDPOINT:-}" "sslip.io"); then
        echo "     Example: $(format_https_url "$generated_domain" 443)"
    else
        echo "     Requires an IPv4 endpoint; choose option 1 for a real domain"
    fi
    echo "     May hit Let's Encrypt rate limits for sslip.io/nip.io"
    echo "  3) Your certificate and key"
    echo "  4) Self-signed certificate"
    echo "     Works immediately, but browsers and WG Tunnel may complain"
    ask_choice cert_choice "Your choice [2]: " "2" "1 2 3 4 selfsigned"
    case "${cert_choice:-2}" in
        1)
            AWG_WEB_CERT_MODE="letsencrypt"
            read_clean_input domain_input "Enter Web Panel domain [Enter = choose experimental IP domain]: "
            if [[ -n "$domain_input" ]]; then
                ask_domain AWG_WEB_DOMAIN "Enter Web Panel domain: " "$domain_input"
            else
                log_warn "No domain entered; using experimental IP-domain mode."
                AWG_WEB_CERT_MODE="ip-domain"
                cert_choice=2
            fi
            if [[ "${AWG_WEB_CERT_MODE:-}" == "letsencrypt" ]]; then
                read_clean_input email_input "Email for Let's Encrypt notices, Enter to skip: "
                [[ -n "$email_input" ]] && AWG_WEB_LE_EMAIL="$email_input"
                return 0
            fi
            ;&
        2)
            AWG_WEB_CERT_MODE="ip-domain"
            AWG_CERT_FALLBACK_SELFSIGNED=1
            echo ""
            echo "Pseudo-domain provider:"
            echo "  1) sslip.io - convenient, but best-effort"
            echo "  2) nip.io"
            ask_choice provider_choice "Your choice [1]: " "1" "1 2 sslip.io nip.io"
            case "${provider_choice:-1}" in
                1|sslip.io) AWG_WEB_CERT_PROVIDER="sslip.io" ;;
                2|nip.io) AWG_WEB_CERT_PROVIDER="nip.io" ;;
                *) log_warn "Unknown provider '${provider_choice}', using sslip.io."; AWG_WEB_CERT_PROVIDER="sslip.io" ;;
            esac
            AWG_WEB_DOMAIN="$(generate_ip_domain "${AWG_ENDPOINT:-}" "$AWG_WEB_CERT_PROVIDER")" || die "ip-domain requires an IPv4 endpoint. Set an IPv4 endpoint or choose your own domain."
            AWG_WEB_PUBLIC_URL="$(format_https_url "$AWG_WEB_DOMAIN" 443)"
            log "Web Panel domain: $AWG_WEB_DOMAIN"
            log_warn "IP-domain through ${AWG_WEB_CERT_PROVIDER} is best-effort: Let's Encrypt may reject issuance due registered-domain limits for sslip.io/nip.io."
            log_warn "HTTP-01 requires inbound TCP/80 in UFW and the provider firewall/security group."
            read_clean_input email_input "Email for Let's Encrypt notices, Enter to skip: "
            [[ -n "$email_input" ]] && AWG_WEB_LE_EMAIL="$email_input"
            ;;
        3)
            AWG_WEB_CERT_MODE="custom"
            while [[ ! -f "${AWG_WEB_CERT_FILE:-}" ]]; do
                read_clean_input cert_input "Path to fullchain/cert.pem: "
                AWG_WEB_CERT_FILE="$cert_input"
            done
            while [[ ! -f "${AWG_WEB_KEY_FILE:-}" ]]; do
                read_clean_input key_input "Path to private key: "
                AWG_WEB_KEY_FILE="$key_input"
            done
            read_clean_input domain_input "Web Panel domain/Public URL host for the certificate: "
            [[ -n "$domain_input" ]] && AWG_WEB_DOMAIN="$domain_input"
            ;;
        4|selfsigned)
            AWG_WEB_CERT_MODE="selfsigned"
            log_warn "Public Web Panel with self-signed TLS is not recommended: browsers and WG Tunnel URL Import may reject the certificate."
            ;;
        *) log_warn "Unknown TLS mode '$cert_choice', using ip-domain."; AWG_WEB_CERT_MODE="ip-domain"; AWG_WEB_CERT_PROVIDER="sslip.io"; AWG_WEB_DOMAIN="$(generate_ip_domain "${AWG_ENDPOINT:-}" "$AWG_WEB_CERT_PROVIDER")" || die "ip-domain requires an IPv4 endpoint." ;;
    esac
}

prompt_web_panel() {
    [[ "$AUTO_YES" -eq 0 ]] || { warn_public_web_bind; return 0; }
    [[ "$CLI_DISABLE_WEB" -eq 0 ]] || return 0
    local web_enable web_choice input_port public_confirm
    if [[ "$ENV_AWG_WEB_ENABLED_SET" -eq 0 ]]; then
        ask_yes_no web_enable "Enable Web Panel? [Y/n]: " "y"
        if [[ "$web_enable" == "no" ]]; then
            AWG_WEB_ENABLED=0
            return 0
        fi
        AWG_WEB_ENABLED=1
    fi
    [[ "${AWG_WEB_ENABLED:-1}" -eq 1 ]] || return 0
    if [[ -z "$CLI_WEB_BIND" && "$ENV_AWG_WEB_BIND_SET" -eq 0 ]]; then
        echo ""
        echo "Web Panel access:"
        echo "  1) VPN-only, 10.9.9.1 - safe default, port 8443"
        echo "  2) localhost, 127.0.0.1 - SSH tunnel only, port 8443"
        echo "  3) public, 0.0.0.0 - Internet access, domain + HTTPS, port 443"
        ask_choice web_choice "Your choice [1]: " "1" "1 2 3"
        case "${web_choice:-1}" in
            1) AWG_WEB_BIND="10.9.9.1" ;;
            2) AWG_WEB_BIND="127.0.0.1" ;;
            3) AWG_WEB_BIND="0.0.0.0" ;;
            *) log_warn "Unknown Web Panel access '$web_choice', using VPN-only."; AWG_WEB_BIND="10.9.9.1" ;;
        esac
    fi
    prompt_web_certificate
    apply_web_port_default 0
    warn_public_web_bind
    if [[ "$AWG_WEB_BIND" == "0.0.0.0" || "$AWG_WEB_BIND" == "::" ]]; then
        read_clean_input public_confirm "You are exposing Web Panel to the Internet. Continue? type YES: "
        [[ "$public_confirm" == "YES" ]] || die "Public Web Panel was not confirmed."
    fi
    if [[ -z "$CLI_WEB_PORT" && "$ENV_AWG_WEB_PORT_SET" -eq 0 ]]; then
        ask_web_port input_port "Enter HTTPS Web Panel port [${AWG_WEB_PORT:-8443}]: " "${AWG_WEB_PORT:-8443}"
        AWG_WEB_PORT="$input_port"
    fi
}

prompt_adguard() {
    [[ "$AUTO_YES" -eq 0 && "$CLI_ENABLE_ADGUARD" -eq 0 && "$CLI_DISABLE_ADGUARD" -eq 0 && "$ENV_AWG_ADGUARD_ENABLED_SET" -eq 0 ]] || return 0
    local ag_enable input_port
    ask_yes_no ag_enable "Install AdGuard Home for DNS? [Y/n]: " "y"
    if [[ "$ag_enable" == "no" ]]; then
        AWG_ADGUARD_ENABLED=0
        AWG_DNS_MODE="system"
        return 0
    fi
    AWG_ADGUARD_ENABLED=1
    AWG_DNS_MODE="adguard"
    if [[ -z "$CLI_ADGUARD_PORT" && "$ENV_AWG_ADGUARD_PORT_SET" -eq 0 ]]; then
        ask_port input_port "Enter AdGuard UI port [${AWG_ADGUARD_PORT:-3000}]: " "${AWG_ADGUARD_PORT:-3000}"
        AWG_ADGUARD_PORT="$input_port"
    fi
}

prompt_p2p() {
    [[ "$AUTO_YES" -eq 0 && -z "$CLI_P2P_BASE_PORT" && -z "$CLI_P2P_PORTS_PER_CLIENT" && "$CLI_FULLCONE_NAT" -eq 0 && "$ENV_AWG_P2P_ENABLED_SET" -eq 0 ]] || return 0
    local p2p_enable input_base input_count fullcone
    ask_yes_no p2p_enable "Configure P2P ports for clients? [Y/n]: " "y"
    if [[ "$p2p_enable" == "no" ]]; then
        AWG_P2P_ENABLED=0
        AWG_P2P_PORTS_PER_CLIENT=0
        AWG_FULLCONE_NAT=0
        return 0
    fi
    AWG_P2P_ENABLED=1
    if [[ "$ENV_AWG_P2P_BASE_PORT_SET" -eq 0 ]]; then
        ask_port input_base "Enter base P2P port [${AWG_P2P_BASE_PORT:-20000}]: " "${AWG_P2P_BASE_PORT:-20000}"
        AWG_P2P_BASE_PORT="$input_base"
    fi
    if [[ "$ENV_AWG_P2P_PORTS_PER_CLIENT_SET" -eq 0 ]]; then
        ask_choice input_count "Enter P2P ports per client [${AWG_P2P_PORTS_PER_CLIENT:-3}]: " "${AWG_P2P_PORTS_PER_CLIENT:-3}" "0 1 2 3 4 5 6 7 8 9 10"
        AWG_P2P_PORTS_PER_CLIENT="$input_count"
    fi
    if [[ "$ENV_AWG_FULLCONE_NAT_SET" -eq 0 ]]; then
        ask_yes_no fullcone "Enable fullcone NAT? [y/N]: " "n"
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
    case "${AWG_WIRESOCK_HINTS:-off}" in off|auto|mobile|quic|dns) ;; *) die "Invalid --wiresock-hints=${AWG_WIRESOCK_HINTS}" ;; esac
    [[ "${AWG_WIRESOCK_HINTS:-off}" == "off" ]] && return 0
    apply_wiresock_profile_defaults
    validate_wiresock_domain "${AWG_WIRESOCK_ID:-}" || die "Invalid WireSock Id/domain: '${AWG_WIRESOCK_ID:-}'"
    case "${AWG_WIRESOCK_IP:-}" in quic|dns) ;; *) die "Invalid --wiresock-ip=${AWG_WIRESOCK_IP:-}" ;; esac
    case "${AWG_WIRESOCK_IB:-}" in curl|chrome) ;; *) die "Invalid --wiresock-ib=${AWG_WIRESOCK_IB:-}" ;; esac
}

prompt_wiresock_hints() {
    [[ "$AUTO_YES" -eq 0 && -z "$CLI_WIRESOCK_HINTS" ]] || return 0
    local enable profile custom_id
    ask_yes_no enable "Add WireSock compatibility hints to client configs? [Y/n]: " "y"
    if [[ "$enable" == "no" ]]; then
        AWG_WIRESOCK_HINTS="off"
        return 0
    fi
    echo "These are #@ws:* comments; standard clients ignore them."
    echo "  1) quic/mobile-compatible: ozon.ru, quic, curl"
    echo "  2) mobile: bag.itunes.apple.com, quic, curl"
    echo "  3) dns: yandex.ru, dns, chrome"
    ask_choice profile "WireSock profile [1]: " "1" "1 2 3 quic mobile dns"
    case "${profile:-1}" in
        1|quic) AWG_WIRESOCK_HINTS="quic" ;;
        2|mobile) AWG_WIRESOCK_HINTS="mobile" ;;
        3|dns) AWG_WIRESOCK_HINTS="dns" ;;
        *) log_warn "Unknown WireSock profile '$profile', using quic."; AWG_WIRESOCK_HINTS="quic" ;;
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
    echo "Final parameters:"
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
    read -rp "Continue installation? [Y/n]: " confirm_install < /dev/tty
    [[ "$confirm_install" =~ ^[Nn]$ ]] && die "Installation cancelled by user."
    return 0
}

# ==============================================================================
# AWG 2.0 parameter generation (inline — needed in step 0, before downloading awg_common.sh)
# ==============================================================================

# Random number [min, max] via /dev/urandom (uint32 support)
rand_range() {
    local min=$1 max=$2
    local range=$((max - min + 1))
    local random_val
    random_val=$(od -An -tu4 -N4 /dev/urandom | tr -d ' ')
    if [[ -z "$random_val" || ! "$random_val" =~ ^[0-9]+$ ]]; then
        # Fallback: combining two $RANDOM for 30-bit range
        random_val=$(( (RANDOM << 15) | RANDOM ))
    fi
    echo $(( (random_val % range) + min ))
}

# Generate 4 non-overlapping ranges for AWG H1-H4.
# Algorithm: 8 random values → sort → 4 (low, high) pairs.
# Sorting guarantees low ≤ high and non-overlap between pairs.
# Minimum width per range = 1000 (for proper obfuscation).
# Prints 4 "low-high" lines to stdout. Returns 1 on failure.
# Mitigates Russian DPI fingerprinting of static H values (#38).
#
# Range: [0, 2^31-1] = [0, 2147483647]. The AmneziaWG spec allows the
# full uint32 (0-4294967295), but the standalone Windows client
# `amneziawg-windows-client` has a UI validator capped at 2^31-1 in
# `ui/syntax/highlighter.go:isValidHField()` (upstream bug
# amnezia-vpn/amneziawg-windows-client#85, not yet fixed). Values above
# 2^31-1 work on the server, but the client's config editor underlines
# them as invalid and blocks saving. For compatibility we generate in
# the safe half of the range (#40).
#
# Optimization: a single `od -N32 -tu4` call reads 32 bytes = 8 uint32
# values in one operation, instead of 8 separate subprocess calls via
# rand_range. Falls back to rand_range if /dev/urandom is unavailable.
generate_awg_h_ranges() {
    local attempt=0 max_attempts=20
    while (( attempt < max_attempts )); do
        local raw arr=() _v
        raw=$(od -An -N32 -tu4 /dev/urandom 2>/dev/null | tr -s ' \n' '\n' | sed '/^$/d')
        if [[ -n "$raw" ]]; then
            local count=0
            while IFS= read -r _v; do
                [[ "$_v" =~ ^[0-9]+$ ]] || continue
                # Mask 0x7FFFFFFF: clears the top bit, value in [0, 2^31-1]
                # with no bias (each lower bit stays independent).
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

# Generate CPS string for I1
# Format: "<r N>" where N is the number of random bytes (32-256)
generate_cps_i1() {
    local n
    n=$(rand_range 32 256)
    echo "<r ${n}>"
}

# Generate all AWG 2.0 parameters
generate_awg_params() {
    local preset="${CLI_PRESET:-${AWG_PRESET:-default}}"
    log "Generating AWG 2.0 parameters (preset: $preset)..."

    case "$preset" in
        default)
            # Jc 3-6: balance between obfuscation and mobile compatibility (Discussion #38)
            AWG_Jc=$(rand_range 3 6)
            AWG_Jmin=$(rand_range 40 89)
            # Jmax = Jmin + 50..250 (~90-339 bytes, Issue #42)
            AWG_Jmax=$(( AWG_Jmin + $(rand_range 50 250) ))
            ;;
        mobile)
            # Jc=3 fixed: alkorrnd (Tele2) — Jc=3 >95%, Jc=4 ~30%, Jc=5 <5%
            # Narrow Jmax: markmokrenko (Yota) — Jmax=70 works, Jmax>300 blocked
            AWG_Jc=3
            AWG_Jmin=$(rand_range 30 50)
            AWG_Jmax=$(( AWG_Jmin + $(rand_range 20 80) ))
            log "  Preset 'mobile': Jc=3, narrow Jmax for mobile networks"
            ;;
        *)
            die "Unknown preset: '$preset'. Allowed: default, mobile"
            ;;
    esac

    # Individual CLI overrides (on top of preset)
    if [[ -n "${CLI_JC:-}" ]]; then
        validate_jc_value "$CLI_JC" || die "Invalid --jc=$CLI_JC (allowed: 1-128)"
        AWG_Jc="$CLI_JC"
    fi
    if [[ -n "${CLI_JMIN:-}" ]]; then
        validate_junk_size "$CLI_JMIN" || die "Invalid --jmin=$CLI_JMIN (allowed: 0-1280)"
        AWG_Jmin="$CLI_JMIN"
    fi
    if [[ -n "${CLI_JMAX:-}" ]]; then
        validate_junk_size "$CLI_JMAX" || die "Invalid --jmax=$CLI_JMAX (allowed: 0-1280)"
        AWG_Jmax="$CLI_JMAX"
    fi

    # Sanity: Jmax >= Jmin
    if [[ "$AWG_Jmax" -lt "$AWG_Jmin" ]]; then
        die "Jmax ($AWG_Jmax) cannot be less than Jmin ($AWG_Jmin)"
    fi

    AWG_PRESET="$preset"
    AWG_S1=$(rand_range 15 150)
    AWG_S2=$(rand_range 15 150)

    # Critical kernel constraint: S1+56 != S2
    # Prevents init and response messages from having the same size
    while [[ $((AWG_S1 + 56)) -eq $AWG_S2 ]]; do
        AWG_S2=$(rand_range 15 150)
    done

    AWG_S3=$(rand_range 8 55)
    AWG_S4=$(rand_range 4 27)

    # H1-H4: 4 random non-overlapping uint32 ranges.
    # Per-install randomization protects against Russian DPI fingerprinting
    # of static H values (Discussion #38, elvaleto/Klavishnik).
    # Algorithm: 8 random uint32 → sort → 4 non-overlapping pairs.
    local _h_lines
    mapfile -t _h_lines < <(generate_awg_h_ranges) || true
    if [[ ${#_h_lines[@]} -ne 4 ]]; then
        die "Failed to generate H1-H4 ranges."
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
    log "AWG 2.0 parameters generated."
}

# ==============================================================================
# System optimization (new in v5.0)
# ==============================================================================

# Detect hardware characteristics
detect_hardware() {
    TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
    CPU_CORES=$(nproc)
    MAIN_NIC=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    log "Hardware: RAM=${TOTAL_RAM_MB}MB, CPU=${CPU_CORES} cores, NIC=${MAIN_NIC}"
}

# Remove unnecessary packages and services
cleanup_system() {
    log "Cleaning system of unnecessary components..."

    # Snapshot default route BEFORE cleanup: cleanup must not break networking.
    # On newer Ubuntu ISOs, autoremove after purging cloud-init can remove
    # netplan-generator as a transitive dependency and leave the server offline.
    local pre_default_route
    pre_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
    log_debug "Pre-cleanup default route: ${pre_default_route:-<none>}"

    # Hold critical network stack packages. Preserve pre-existing user holds:
    # unhold only packages that this cleanup run held itself.
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

    # Packages to remove (safe for VPS)
    # snapd and lxd-agent-loader — Ubuntu only, not present on Debian
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
        log "Removing: ${packages_to_remove[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get purge -y "${packages_to_remove[@]}" || log_warn "Error removing some packages"
    fi

    # Cleaning snap artifacts (Ubuntu only)
    if [[ "${OS_ID:-ubuntu}" == "ubuntu" && -d /snap ]]; then
        log "Cleaning snap artifacts..."
        rm -rf /snap /var/snap /var/lib/snapd 2>/dev/null || log_warn "snap cleanup error"
    fi

    # cloud-init: remove only if NOT managing network
    # Conservative approach: check cloud-init markers first, then renderer
    if dpkg-query -W -f='${Status}' cloud-init 2>/dev/null | grep -q "ok installed"; then
        local cloud_manages_network=0
        # Check cloud-init markers (priority — safety)
        if ls /etc/netplan/*cloud-init* &>/dev/null 2>&1; then
            cloud_manages_network=1
        elif grep -rq "cloud-init" /etc/netplan/ 2>/dev/null; then
            cloud_manages_network=1
        elif [[ -f /etc/network/interfaces ]] && grep -q "cloud-init" /etc/network/interfaces 2>/dev/null; then
            cloud_manages_network=1
        fi
        if [[ $cloud_manages_network -eq 0 ]]; then
            log "Removing cloud-init (network doesn't depend on it)..."
            DEBIAN_FRONTEND=noninteractive apt-get purge -y cloud-init 2>/dev/null || log_warn "cloud-init removal error"
            rm -rf /etc/cloud /var/lib/cloud 2>/dev/null
        else
            log_warn "cloud-init manages network — skipping removal."
        fi
    fi

    # Intentionally do not run apt-get autoremove: it can remove
    # netplan-generator and break the default route. A small amount of orphaned
    # packages is safer than losing SSH access.
    local _upkg
    for _upkg in "${_held_actual[@]}"; do
        apt-mark unhold "$_upkg" >/dev/null 2>&1 || true
    done

    local post_default_route
    post_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
    if [[ -n "$pre_default_route" && -z "$post_default_route" ]]; then
        log_error "Default route was lost after cleanup. Attempting recovery..."
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
                log_warn "Last recovery attempt for interface $_iface..."
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
            die "Network did not recover after cleanup_system. Restore it from the console (e.g. sudo dhclient -4 <iface>) and retry the installer with --no-tweaks."
        fi
        log_warn "Network recovered: $post_default_route"
    fi
    log "System cleanup completed."
}

# Swap configuration
optimize_swap() {
    log "Optimizing swap..."
    local target_swap_mb

    if [[ $TOTAL_RAM_MB -le 2048 ]]; then
        target_swap_mb=1024
    else
        target_swap_mb=512
    fi

    # Check current swap
    local current_swap_mb
    current_swap_mb=$(free -m | awk '/Swap:/ {print $2}')

    if [[ $current_swap_mb -ge $target_swap_mb ]]; then
        log "Swap is already sufficient: ${current_swap_mb}MB (target: ${target_swap_mb}MB)"
    else
        log "Creating swap file: ${target_swap_mb}MB"
        # Disable existing swap file if present
        if [[ -f /swapfile ]]; then
            swapoff /swapfile 2>/dev/null
            rm -f /swapfile
        fi
        dd if=/dev/zero of=/swapfile bs=1M count="$target_swap_mb" status=none 2>/dev/null || {
            log_warn "Error creating swap file"
            return 1
        }
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1 || { log_warn "mkswap error"; return 1; }
        swapon /swapfile || { log_warn "swapon error"; return 1; }
        # Add to fstab if missing. Precise field match: ignore commented
        # lines and partial matches (e.g. `/swapfile.bak` or an old entry
        # left in a comment).
        if ! awk '!/^[[:space:]]*#/ && $1 == "/swapfile" && $3 == "swap" {found=1} END {exit !(found+0)}' \
             /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        log "Swap file created: ${target_swap_mb}MB"
    fi

    # Setting swappiness
    sysctl -w vm.swappiness=10 >/dev/null 2>&1
}

# Network interface optimization
optimize_nic() {
    if [[ -z "$MAIN_NIC" ]]; then
        log_warn "Main NIC not detected, skipping optimization."
        return 1
    fi

    if ! command -v ethtool &>/dev/null; then
        log_debug "ethtool not found, skipping NIC optimization."
        return 0
    fi

    log "NIC optimization: $MAIN_NIC"
    # Disable GRO/GSO/TSO — may interfere with VPN traffic
    ethtool -K "$MAIN_NIC" gro off 2>/dev/null || log_debug "GRO: not supported/already off."
    ethtool -K "$MAIN_NIC" gso off 2>/dev/null || log_debug "GSO: not supported/already off."
    ethtool -K "$MAIN_NIC" tso off 2>/dev/null || log_debug "TSO: not supported/already off."
    log "NIC optimization completed."
}

# Full system optimization
optimize_system() {
    log "Optimizing system for VPN server..."
    detect_hardware
    optimize_swap
    optimize_nic
    log "System optimization completed."
}

# ==============================================================================
# Sysctl configuration (minimal, for --no-tweaks)
# ==============================================================================

setup_minimal_sysctl() {
    log "Configuring minimal sysctl (--no-tweaks)..."
    local f="/etc/sysctl.d/99-amneziawg-forwarding.conf"
    cat > "$f" << SYSEOF
# AmneziaWG — minimal settings (--no-tweaks)
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
    sysctl -p "$f" >/dev/null 2>&1 || log_warn "sysctl -p error"
    log "Minimal sysctl configured."
}

# ==============================================================================
# Sysctl configuration (extended)
# ==============================================================================

setup_advanced_sysctl() {
    log "Configuring sysctl..."
    local f="/etc/sysctl.d/99-amneziawg-security.conf"

    # Adaptive buffers based on RAM
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
# Auto-generated by install_amneziawg_en.sh v${SCRIPT_VERSION}

# --- IP Forwarding ---
net.ipv4.ip_forward = 1
$(if [[ "${DISABLE_IPV6:-1}" -eq 1 ]]; then
    echo "net.ipv6.conf.all.disable_ipv6 = 1"
    echo "net.ipv6.conf.default.disable_ipv6 = 1"
    echo "net.ipv6.conf.lo.disable_ipv6 = 1"
else
    echo "# IPv6 not disabled"
    echo "net.ipv6.conf.all.forwarding = 1"
    echo "net.ipv6.conf.all.proxy_ndp = ${AWG_IPV6_NDP_PROXY:-0}"
fi)

# --- TCP/IP Hardening ---
# rp_filter = 2 (loose mode): validates source IP against ANY route in the
# table, not against the reverse path through the same interface. Strict mode
# (=1) breaks routing on cloud hosters (Hetzner and similar) where the gateway
# is in a different subnet than the VPS IP — reply packets fail the strict
# reverse path check. Loose mode is safe: spoofed source IPs are still dropped
# if no route exists for them at all. Discussion #41 (z036).
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

# Suppress kernel warning/notice messages in the hoster VNC console.
# Without this, fail2ban UFW blocks spam the VNC window with "[UFW BLOCK]"
# lines and make the console unusable.
# Format: console_loglevel default_msg_loglevel min_console_loglevel default_console_loglevel
# Value 3 = KERN_ERR — only errors and above reach the console.
# Discussion #41 (z036).
kernel.printk = 3 4 1 3
EOF

    log "Applying sysctl..."
    if ! sysctl -p "$f" >/dev/null 2>&1; then
        # nf_conntrack may be unavailable before module is loaded
        log_warn "Some sysctl parameters did not apply (nf_conntrack will be available later)."
        sysctl -p "$f" 2>/dev/null || true
    fi
}


# ==============================================================================
# Voice / Calls optimization: безопасный UDP conntrack tuning
# ==============================================================================

setup_voice_udp_optimization() {
    log "Configuring Voice / Calls UDP optimization..."
    local udp_proc="/proc/sys/net/netfilter/nf_conntrack_udp_timeout"
    local max_proc="/proc/sys/net/netfilter/nf_conntrack_max"
    local udp_file="/etc/sysctl.d/99-awg-udp.conf"
    local max_file="/etc/sysctl.d/99-awg-conntrack.conf"

    if [[ ! -e "$udp_proc" ]]; then
        modprobe nf_conntrack >/dev/null 2>&1 || log_warn "Failed to load nf_conntrack; continuing without UDP conntrack tuning."
    fi
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

# ==============================================================================
# Firewall and security
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
        [[ -n "$CLI_SSH_PORT" ]] && log_warn "--ssh-port has no valid ports, falling back to 22."
        valid="22"
    fi
    printf '%s' "$valid"
}

setup_improved_firewall() {
    if [[ "${AWG_DISABLE_UFW:-0}" == "1" ]]; then
        log_warn "UFW disabled by user (--disable-ufw/AWG_DISABLE_UFW=1)."
        log_warn "Ensure an external firewall opens VPN/Web ports and does not expose AdGuard publicly."
        return 0
    fi
    log "Configuring UFW..."
    if ! command -v ufw &>/dev/null; then install_packages ufw; fi

    # Detect main network interface for route rule
    local main_nic
    main_nic=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    if [[ -z "$main_nic" ]]; then
        log_warn "Could not detect network interface for UFW route."
    fi

    local ssh_ports _sp
    ssh_ports=$(detect_ssh_ports)
    log "SSH port(s) for the UFW rule: ${ssh_ports}"

    local ufw_errors=0
    allow_web_panel_ufw() {
        [[ "${AWG_WEB_ENABLED:-1}" -eq 1 ]] || return 0
        if [[ "$AWG_WEB_BIND" == "0.0.0.0" || "$AWG_WEB_BIND" == "::" ]]; then
            log_warn "Web panel is publicly bound (${AWG_WEB_BIND}); port ${AWG_WEB_PORT}/tcp will be opened globally."
            ufw allow "${AWG_WEB_PORT}/tcp" comment "AmneziaWG Web Panel" || { log_warn "UFW: failed to allow Web port"; ufw_errors=1; }
        elif [[ "$AWG_WEB_BIND" == "127.0.0.1" || "$AWG_WEB_BIND" == "::1" ]]; then
            log "Web panel is locally bound (${AWG_WEB_BIND}); no global UFW rule is needed."
        else
            ufw allow in on awg0 to "${AWG_WEB_BIND}" port "${AWG_WEB_PORT}" proto tcp comment "AmneziaWG Web Panel VPN-only" || { log_warn "UFW: failed to allow Web port on awg0"; ufw_errors=1; }
        fi
    }
    if ufw status 2>/dev/null | grep -q inactive; then
        log "UFW is inactive. Configuring..."
        ufw default deny incoming  || { log_warn "UFW: failed to set default deny incoming"; ufw_errors=1; }
        ufw default allow outgoing || { log_warn "UFW: failed to set default allow outgoing"; ufw_errors=1; }
        for _sp in $ssh_ports; do
            ufw limit "${_sp}/tcp" comment "SSH Rate Limit" || { log_warn "UFW: failed to limit SSH (port ${_sp})"; ufw_errors=1; }
        done
        ufw allow "${AWG_PORT}/udp" comment "AmneziaWG VPN" || { log_warn "UFW: failed to allow VPN port"; ufw_errors=1; }
        allow_web_panel_ufw
        if [[ "${AWG_ADGUARD_ENABLED:-0}" -eq 1 ]]; then
            ufw allow in on awg0 to any port 53 proto udp comment "AmneziaWG AdGuard DNS UDP" || log_warn "UFW: failed to allow DNS UDP on awg0"
            ufw allow in on awg0 to any port 53 proto tcp comment "AmneziaWG AdGuard DNS TCP" || log_warn "UFW: failed to allow DNS TCP on awg0"
            ufw allow in on awg0 to any port "${AWG_ADGUARD_PORT}" proto tcp comment "AmneziaWG AdGuard UI" || log_warn "UFW: failed to allow AdGuard UI on awg0"
        fi
        if [[ -n "$main_nic" ]]; then
            ufw route allow in on awg0 out on "$main_nic" comment "AmneziaWG Routing" \
                || { log_warn "UFW: failed to add route rule"; ufw_errors=1; }
            log "VPN routing rule added (awg0 → ${main_nic})."
        fi
        if [[ "$ufw_errors" -ne 0 ]]; then
            log_error "One or more UFW rules failed to apply. Check settings manually."
            return 1
        fi
        log "UFW rules added."
        log_warn "--- ENABLING UFW ---"
        log_warn "UFW will allow SSH only on port(s): ${ssh_ports}. Verify SSH access!"
        local confirm_ufw="y"
        if [[ "$AUTO_YES" -eq 0 ]]; then
            sleep 5
            read -rp "Enable UFW? [Y/n]: " confirm_ufw < /dev/tty
            confirm_ufw="${confirm_ufw:-y}"
        else
            log "Auto-enabling UFW (--yes)."
        fi
        if [[ "$confirm_ufw" =~ ^[Nn]$ ]]; then
            AWG_DISABLE_UFW=1
            log_warn "UFW not enabled. Ensure an external firewall opens VPN/Web ports and does not expose AdGuard publicly."
            return 0
        fi
        if ! ufw enable <<< "y"; then die "UFW enable error."; fi
        log "UFW enabled."
        # Marker: UFW was enabled by our installer (not by the user beforehand).
        # Used in step_uninstall to decide whether disabling UFW is safe.
        # Protects against destructive uninstall on a VPS where UFW was used
        # for SSH/web hardening BEFORE our script was installed (audit).
        touch "$AWG_DIR/.ufw_enabled_by_installer" 2>/dev/null || \
            log_warn "Failed to create UFW marker — uninstall will not disable UFW automatically."
    else
        log "UFW is active. Updating rules..."
        for _sp in $ssh_ports; do
            ufw limit "${_sp}/tcp" comment "SSH Rate Limit" || { log_warn "UFW: failed to limit SSH (port ${_sp})"; ufw_errors=1; }
        done
        ufw allow "${AWG_PORT}/udp" comment "AmneziaWG VPN" || { log_warn "UFW: failed to allow VPN port"; ufw_errors=1; }
        allow_web_panel_ufw
        if [[ "${AWG_ADGUARD_ENABLED:-0}" -eq 1 ]]; then
            ufw allow in on awg0 to any port 53 proto udp comment "AmneziaWG AdGuard DNS UDP" || log_warn "UFW: failed to allow DNS UDP on awg0"
            ufw allow in on awg0 to any port 53 proto tcp comment "AmneziaWG AdGuard DNS TCP" || log_warn "UFW: failed to allow DNS TCP on awg0"
            ufw allow in on awg0 to any port "${AWG_ADGUARD_PORT}" proto tcp comment "AmneziaWG AdGuard UI" || log_warn "UFW: failed to allow AdGuard UI on awg0"
        fi
        if [[ -n "$main_nic" ]]; then
            ufw route allow in on awg0 out on "$main_nic" comment "AmneziaWG Routing" \
                || { log_warn "UFW: failed to add route rule"; ufw_errors=1; }
        fi
        if [[ "$ufw_errors" -ne 0 ]]; then
            log_error "One or more UFW rules failed to apply. Check settings manually."
            return 1
        fi
        ufw reload || log_warn "UFW reload error."
        log "Rules updated."
    fi
    log "UFW configured."
    log "$(ufw status verbose 2>&1)"
    return 0
}

secure_files() {
    log "Setting secure file permissions..."
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
    log "File permissions set."
}

setup_fail2ban() {
    log "Configuring Fail2Ban..."
    if ! command -v fail2ban-client &>/dev/null; then install_packages fail2ban; fi
    if ! command -v fail2ban-client &>/dev/null; then
        log_warn "Fail2Ban not installed, skipping."
        return 1
    fi

    # Debian: journald instead of rsyslog, needs python3-systemd
    if [[ "${OS_ID:-}" == "debian" ]]; then
        install_packages python3-systemd
    fi

    mkdir -p /etc/fail2ban/jail.d 2>/dev/null

    # Backend: systemd for Debian (no rsyslog), auto for Ubuntu
    local f2b_backend="auto"
    if [[ "${OS_ID:-}" == "debian" ]]; then
        f2b_backend="systemd"
    fi

    cat > /etc/fail2ban/jail.d/amneziawg.conf << JAILEOF || { log_warn "jail.d/amneziawg.conf write error"; return 1; }
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
        log "Fail2Ban configured and restarted."
    else
        log_warn "fail2ban restart error"
    fi
    return 0
}

# ==============================================================================
# Service status check
# ==============================================================================

check_service_status() {
    log "Checking service status..."
    local ok=1

    if systemctl is-failed --quiet awg-quick@awg0; then
        log_error "Service FAILED!"
        ok=0
    fi

    if ! ip addr show awg0 &>/dev/null; then
        log_error "Interface awg0 not found!"
        ok=0
    fi

    if ! awg show 2>/dev/null | grep -q "interface: awg0"; then
        log_error "awg show cannot see interface!"
        ok=0
    fi

    # Port check
    local port_check=${AWG_PORT:-0}
    if [[ "$port_check" -eq 0 ]] && [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        port_check=$(safe_read_config_key "AWG_PORT" "$CONFIG_FILE")
        port_check=${port_check:-0}
    fi
    if [[ "$port_check" -ne 0 ]]; then
        if ! ss -lunp | grep -q ":${port_check} "; then
            log_error "Port $port_check/udp is not listening!"
            ok=0
        fi
    fi

    # AWG 2.0 parameter check
    if awg show awg0 2>/dev/null | grep -q "jc:"; then
        log "AWG 2.0 parameters active."
    else
        log_warn "AWG 2.0 parameters not detected in awg show."
    fi

    if [[ "$ok" -eq 1 ]]; then
        log "Service and interface status OK."
        return 0
    else
        return 1
    fi
}

# ==============================================================================
# Diagnostics
# ==============================================================================

create_diagnostic_report() {
    log "Creating diagnostics..."
    local rf
    rf="$AWG_DIR/diag_$(date +%F_%T).txt"
    {
        echo "=== AMNEZIAWG 2.0 DIAGNOSTIC REPORT ==="
        echo ""
        echo "!!! WARNING: This report contains IP addresses, ports and routes."
        echo "!!! Review and redact private data before posting to public issues."
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
        # Mask private key
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
    } > "$rf" || log_error "Report write error."
    chmod 600 "$rf" || log_warn "Report chmod error."
    log "Report: $rf"
}

# ==============================================================================
# Uninstall
# ==============================================================================

step_uninstall() {
    log "### AMNEZIAWG UNINSTALL ###"
    echo ""
    echo "WARNING! Complete removal of AmneziaWG and configurations."
    echo "This process is irreversible!"
    echo ""
    local confirm="" backup="Y"
    if [[ "$AUTO_YES" -eq 0 ]]; then
        read -rp "Are you sure? (type 'yes'): " confirm < /dev/tty
        if [[ "$confirm" != "yes" ]]; then log "Uninstall cancelled."; exit 1; fi
        read -rp "Create backup before removal? [Y/n]: " backup < /dev/tty
    else
        log "Auto-confirming uninstall (--yes)."
    fi
    if [[ -z "$backup" || "$backup" =~ ^[Yy]$ ]]; then
        local bf
        bf="$HOME/awg_uninstall_backup_$(date +%F_%H-%M-%S).tar.gz"
        log "Creating backup: $bf"
        if tar -czf "$bf" -C / etc/amnezia "$AWG_DIR" --ignore-failed-read 2>/dev/null \
            && chmod 600 "$bf"; then
            log "Backup created: $bf"
        else
            log_warn "Backup failed — check $bf manually before continuing"
        fi
    fi
    # Load --no-tweaks flag from saved configuration
    local saved_no_tweaks=0
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        saved_no_tweaks=$(safe_read_config_key "NO_TWEAKS" "$CONFIG_FILE" 2>/dev/null) || saved_no_tweaks=0
        saved_no_tweaks=${saved_no_tweaks:-0}
    fi
    log "Stopping service..."
    systemctl stop awg-quick@awg0 2>/dev/null
    systemctl disable awg-quick@awg0 2>/dev/null
    systemctl stop awg-web.service 2>/dev/null
    systemctl disable awg-web.service 2>/dev/null
    systemctl stop AdGuardHome.service 2>/dev/null
    systemctl disable AdGuardHome.service 2>/dev/null
    systemctl stop ndppd 2>/dev/null || true
    modprobe -r amneziawg 2>/dev/null || true
    # v5.12.0+: kernel module auto-repair on kernel upgrade.
    # Remove apt hook and systemd unit BEFORE apt purge so the hook does not
    # fire during amneziawg-dkms purge (the helper would try to rebuild DKMS,
    # but the package is already gone). Files may be absent on installs from
    # before v5.12.0 — all operations are idempotent.
    log "Removing kernel module auto-repair components (v5.12.0+)..."
    if systemctl is-enabled amneziawg-ensure-module.service &>/dev/null; then
        systemctl disable amneziawg-ensure-module.service 2>/dev/null || true
    fi
    rm -f /etc/systemd/system/amneziawg-ensure-module.service \
        /etc/apt/apt.conf.d/99-amneziawg-post-kernel \
        /etc/logrotate.d/amneziawg-ensure-module \
        /usr/local/sbin/amneziawg-ensure-module \
        2>/dev/null
    # Also clean up staging dotfiles that may be left over from an interrupted install (atomic deploy).
    rm -f /etc/systemd/system/.amneziawg-ensure-module.service.new \
        /etc/apt/apt.conf.d/.99-amneziawg-post-kernel.new \
        /etc/logrotate.d/.amneziawg-ensure-module.new \
        /usr/local/sbin/.amneziawg-ensure-module.new \
        2>/dev/null || true
    rm -f /var/log/amneziawg-ensure-module.log* 2>/dev/null || true
    rm -rf /var/lib/amneziawg 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    if [[ "$saved_no_tweaks" -eq 0 ]]; then
        log "Cleaning up AmneziaWG UFW rules..."
        if command -v ufw &>/dev/null; then
            local port_to_del
            if [[ -f "$CONFIG_FILE" ]]; then
                # shellcheck source=/dev/null
                port_to_del=$(safe_read_config_key "AWG_PORT" "$CONFIG_FILE")
            fi
            port_to_del=${port_to_del:-39743}
            # Removing our rules is ALWAYS performed (idempotent)
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
            # To delete a route rule we need an exact match with how it was created:
            # "ufw route allow in on awg0 out on <nic>". Without "out on", UFW will
            # not find the rule and it stays in ufw status. Discussion #41.
            local _nic
            _nic=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
            if [[ -n "$_nic" ]]; then
                ufw route delete allow in on awg0 out on "$_nic" 2>/dev/null
            fi
            # Fallback: try deleting without out on (for compatibility with older rules)
            ufw route delete allow in on awg0 2>/dev/null

            # ufw disable runs ONLY if UFW was enabled by our installer.
            # Protects against destructive uninstall on a VPS where UFW was used
            # for SSH/web hardening BEFORE our script was installed (audit).
            # Backwards compat: older installs without the marker keep UFW active.
            if [[ -f "$AWG_DIR/.ufw_enabled_by_installer" ]]; then
                log "Disabling UFW (was enabled by our installer)..."
                ufw --force disable 2>/dev/null
                rm -f "$AWG_DIR/.ufw_enabled_by_installer"
            else
                log "Leaving UFW active (was active before installation, or older installer version)."
            fi
        fi
        log "Removing Fail2Ban bans..."
        if command -v fail2ban-client &>/dev/null; then
            fail2ban-client unban --all 2>/dev/null || true
            systemctl stop fail2ban 2>/dev/null
        fi
    else
        log "Skipping UFW/Fail2Ban (installed with --no-tweaks)."
    fi
    log "Removing packages..."
    if [[ "$saved_no_tweaks" -eq 0 ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y amneziawg-dkms amneziawg-tools fail2ban qrencode ndppd 2>/dev/null || log_warn "Purge error."
    else
        DEBIAN_FRONTEND=noninteractive apt-get purge -y amneziawg-dkms amneziawg-tools qrencode ndppd 2>/dev/null || log_warn "Purge error."
    fi
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || log_warn "Autoremove error."
    log "Removing PPA and files..."
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
        /etc/logrotate.d/amneziawg* || log_warn "File removal error."
    if [[ "$saved_no_tweaks" -eq 0 ]]; then
        # Remove only our own jail file.
        # Previously there was a heuristic "if jail.local contains banaction = ufw,
        # remove the whole file" — too broad a filter, could wipe an unrelated
        # jail.local with custom jails. Heuristic removed (audit).
        # If a user still has a jail.local from very old installer versions,
        # leave it for them to deal with.
        rm -f /etc/fail2ban/jail.d/amneziawg.conf 2>/dev/null
    fi
    log "Removing DKMS..."
    rm -rf /var/lib/dkms/amneziawg* || log_warn "DKMS removal error."
    log "Restoring sysctl..."
    if grep -q "disable_ipv6" /etc/sysctl.conf 2>/dev/null; then
        sed -i '/disable_ipv6/d' /etc/sysctl.conf || log_warn "sed sysctl.conf error"
    fi
    sysctl -p --system 2>/dev/null
    rm -f /etc/apt/sources.list.d/*.bak-* "$AWG_DIR"/ubuntu.sources.bak-* 2>/dev/null || true
    log "Removing cron and scripts..."
    rm -f /etc/cron.d/awg-expiry 2>/dev/null
    log "=== UNINSTALL COMPLETED ==="
    # Copy log and remove working directory
    cp "$LOG_FILE" "$HOME/awg_uninstall.log" 2>/dev/null || true
    rm -rf "$AWG_DIR" 2>/dev/null || true
    exit 0
}

# ==============================================================================
# STEP 0: Initialization
# ==============================================================================

initialize_setup() {
    if [ "$(id -u)" -ne 0 ]; then die "Run the script as root (sudo bash $0)."; fi

    mkdir -p "$AWG_DIR" || die "Error creating $AWG_DIR"
    chown root:root "$AWG_DIR"

    # Process-wide lock: prevents two install_amneziawg.sh instances from
    # running concurrently. Without it two parallel runs could read the
    # same setup_state, race each other on apt-get/dkms/ufw and corrupt
    # package state (audit).
    # FD 9 is fixed and does not conflict with update_state (uses 200).
    # The lock is held open for the whole process lifetime — released
    # automatically on exit.
    INSTALL_LOCK_FILE="$AWG_DIR/.install.lock"
    exec 9>"$INSTALL_LOCK_FILE" || die "Cannot open $INSTALL_LOCK_FILE"
    if ! flock -n 9; then
        die "Another install_amneziawg_en.sh instance is already running. Wait for it to finish, or if the process is hung, remove $INSTALL_LOCK_FILE and try again."
    fi

    touch "$LOG_FILE" || die "Failed to create log file $LOG_FILE"
    chmod 640 "$LOG_FILE"
    log "--- STARTING AmneziaWG 2.0 INSTALLATION (v${SCRIPT_VERSION}) ---"
    log "### STEP 0: Initialization and parameter check ###"
    cd "$AWG_DIR" || die "Error changing to $AWG_DIR"
    log "Working directory: $AWG_DIR"
    log "Log file: $LOG_FILE"

    check_os_version
    check_free_space

    local default_port
    default_port=$(generate_random_awg_port)
    local default_subnet="10.9.9.1/24"
    local config_exists=0

    # Variable initialization
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

    # Load config
    if [[ -f "$CONFIG_FILE" ]]; then
        log "Configuration file found $CONFIG_FILE. Loading settings..."
        config_exists=1
        # shellcheck source=/dev/null
        safe_load_config "$CONFIG_FILE" || log_warn "Failed to fully load settings from $CONFIG_FILE."
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
        log "Settings loaded from file."
    else
        log "Configuration file $CONFIG_FILE not found."
    fi

    # CLI override
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
            die "Invalid --endpoint: '$CLI_ENDPOINT'. Allowed formats: FQDN (vpn.example.com), IPv4 (1.2.3.4), [IPv6] ([2001:db8::1]). Spaces, tabs, quotes, backslashes and newlines are forbidden."
        fi
        AWG_ENDPOINT=$CLI_ENDPOINT
    fi
    if [[ "$CLI_NO_TWEAKS" -eq 1 ]]; then NO_TWEAKS=1; fi

    # Validate after CLI override
    validate_port_user "$AWG_PORT"
    validate_subnet "$AWG_TUNNEL_SUBNET"
    validate_port_user "$AWG_P2P_BASE_PORT"
    if [[ "$AWG_P2P_BASE_PORT" -gt 64511 ]]; then
        die "Invalid AWG_P2P_BASE_PORT: '$AWG_P2P_BASE_PORT' (must be <= 64511 so base+1..base+1024 fits in TCP/UDP ports)."
    fi
    if ! [[ "$AWG_P2P_PORTS_PER_CLIENT" =~ ^[0-9]+$ ]] || [[ "$AWG_P2P_PORTS_PER_CLIENT" -lt 0 ]] || [[ "$AWG_P2P_PORTS_PER_CLIENT" -gt 12 ]]; then
        die "Invalid AWG_P2P_PORTS_PER_CLIENT: '$AWG_P2P_PORTS_PER_CLIENT' (0-12)."
    fi
    validate_web_port "$AWG_WEB_PORT"
    validate_bind_addr "$AWG_WEB_BIND" || die "Invalid AWG_WEB_BIND: '$AWG_WEB_BIND'. Expected a valid IPv4/IPv6 address without whitespace or control characters."
    case "${AWG_WEB_CERT_MODE:-selfsigned}" in selfsigned|custom|letsencrypt|ip-domain) ;; *) die "Invalid --web-cert-mode=${AWG_WEB_CERT_MODE}" ;; esac
    case "${AWG_WEB_CERT_PROVIDER:-sslip.io}" in sslip.io|nip.io) ;; *) die "Invalid --web-cert-provider=${AWG_WEB_CERT_PROVIDER}" ;; esac
    case "${AWG_WEB_CERT_FALLBACK:-abort}" in selfsigned|abort) ;; *) die "Invalid --web-cert-fallback=${AWG_WEB_CERT_FALLBACK}" ;; esac
    if [[ "${AWG_WEB_CERT_MODE:-selfsigned}" == "custom" ]]; then
        [[ -f "${AWG_WEB_CERT_FILE:-}" && -f "${AWG_WEB_KEY_FILE:-}" ]] || die "--web-cert-mode=custom requires existing --web-cert-file and --web-key-file."
    fi
    if [[ "${AWG_WEB_CERT_MODE:-selfsigned}" == "letsencrypt" && -z "${AWG_WEB_DOMAIN:-}" ]]; then
        die "--web-cert-mode=letsencrypt requires --web-domain=DOMAIN."
    fi
    validate_port "$AWG_ADGUARD_PORT"
    validate_wiresock_settings
    validate_server_name "$AWG_SERVER_NAME" || die "Invalid server name: empty, too long, or contains a newline."
    case "$AWG_DNS_MODE" in
        adguard|system|custom) ;;
        *) die "Invalid --dns-mode: '$AWG_DNS_MODE' (expected adguard, system, or custom)." ;;
    esac
    if [[ "$AWG_DNS_MODE" == "adguard" ]]; then
        AWG_ADGUARD_ENABLED=1
    fi
    # AWG_ENDPOINT may have come from CONFIG_FILE via safe_load_config (no CLI override).
    # If the value is present and invalid — log_warn + reset to "" so the installer
    # falls back to auto-detect via get_server_public_ip (audit).
    if [[ -n "$AWG_ENDPOINT" ]] && ! validate_endpoint "$AWG_ENDPOINT"; then
        log_warn "AWG_ENDPOINT='$AWG_ENDPOINT' from $CONFIG_FILE is invalid, falling back to auto-detect."
        AWG_ENDPOINT=""
    fi

    # Request settings from user only on first run
    if [[ "$config_exists" -eq 0 ]]; then
        log "Requesting settings from user (first run)."
        prompt_server_name
        prompt_endpoint
        prompt_awg_preset
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Enter AmneziaWG UDP port (1024-65535) [${AWG_PORT}]: " input_port < /dev/tty
            if [[ -n "$input_port" ]]; then AWG_PORT=$input_port; fi
        fi
        validate_port_user "$AWG_PORT"
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Enter tunnel subnet [${AWG_TUNNEL_SUBNET}]: " input_subnet < /dev/tty
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
        log "Using settings from $CONFIG_FILE."
        warn_public_web_bind
        if [[ "$ALLOWED_IPS_MODE" == "3" ]] && [[ -n "$ALLOWED_IPS" ]]; then
            if ! validate_cidr_list "$ALLOWED_IPS"; then
                die "Invalid ALLOWED_IPS in config: '$ALLOWED_IPS'. Delete $CONFIG_FILE and re-run the installer."
            fi
        fi
    fi

    apply_web_port_default "$config_exists"
    case "${AWG_WEB_CERT_MODE:-selfsigned}" in selfsigned|custom|letsencrypt|ip-domain) ;; *) die "Invalid --web-cert-mode=${AWG_WEB_CERT_MODE}" ;; esac
    case "${AWG_WEB_CERT_PROVIDER:-sslip.io}" in sslip.io|nip.io) ;; *) die "Invalid --web-cert-provider=${AWG_WEB_CERT_PROVIDER}" ;; esac
    case "${AWG_WEB_CERT_FALLBACK:-abort}" in selfsigned|abort) ;; *) die "Invalid --web-cert-fallback=${AWG_WEB_CERT_FALLBACK}" ;; esac
    if [[ "${AWG_WEB_CERT_MODE:-selfsigned}" == "ip-domain" && -z "${AWG_WEB_DOMAIN:-}" ]]; then
        AWG_WEB_DOMAIN="$(generate_ip_domain "${AWG_ENDPOINT:-}" "${AWG_WEB_CERT_PROVIDER:-sslip.io}")" || die "--web-cert-mode=ip-domain requires IPv4 --endpoint."
    fi
    if [[ "${AWG_WEB_CERT_MODE:-selfsigned}" == "letsencrypt" && -z "${AWG_WEB_DOMAIN:-}" ]]; then
        die "--web-cert-mode=letsencrypt requires --web-domain=DOMAIN."
    fi
    if [[ "${AWG_WEB_CERT_MODE:-selfsigned}" == "custom" ]]; then
        [[ -f "${AWG_WEB_CERT_FILE:-}" && -f "${AWG_WEB_KEY_FILE:-}" ]] || die "--web-cert-mode=custom requires existing --web-cert-file and --web-key-file."
    fi
    update_web_public_url

    # Default values
    if [[ "$DISABLE_IPV6" == "default" ]]; then DISABLE_IPV6=1; fi
    if [[ "$ALLOWED_IPS_MODE" == "default" ]]; then ALLOWED_IPS_MODE=2; fi
    if [[ -z "$ALLOWED_IPS" ]]; then configure_routing_mode; fi
    configure_ipv6_client_mode

    validate_port_user "$AWG_PORT"
    validate_subnet "$AWG_TUNNEL_SUBNET"
    validate_port_user "$AWG_P2P_BASE_PORT"
    if [[ "$AWG_P2P_BASE_PORT" -gt 64511 ]]; then
        die "Invalid AWG_P2P_BASE_PORT: '$AWG_P2P_BASE_PORT' (must be <= 64511 so base+1..base+1024 fits in TCP/UDP ports)."
    fi
    if ! [[ "$AWG_P2P_PORTS_PER_CLIENT" =~ ^[0-9]+$ ]] || [[ "$AWG_P2P_PORTS_PER_CLIENT" -lt 0 ]] || [[ "$AWG_P2P_PORTS_PER_CLIENT" -gt 12 ]]; then
        die "Invalid AWG_P2P_PORTS_PER_CLIENT: '$AWG_P2P_PORTS_PER_CLIENT' (0-12)."
    fi
    validate_web_port "$AWG_WEB_PORT"
    validate_bind_addr "$AWG_WEB_BIND" || die "Invalid AWG_WEB_BIND: '$AWG_WEB_BIND'. Expected a valid IPv4/IPv6 address without whitespace or control characters."
    validate_port "$AWG_ADGUARD_PORT"
    validate_wiresock_settings
    validate_server_name "$AWG_SERVER_NAME" || die "Invalid server name: empty, too long, or contains a newline."
    confirm_install_choices

    # Port check (skip if AWG service is already listening on this port)
    if ! systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
        check_port_availability "$AWG_PORT" || die "Port $AWG_PORT/udp is occupied."
    else
        log "AWG service is active — skipping port check."
    fi
    check_web_port_availability

    # AWG 2.0 parameter generation
    # Regenerate if: first run OR explicit CLI override (--preset/--jc/--jmin/--jmax)
    if [[ -z "${AWG_Jc:-}" ]] || [[ -n "${CLI_PRESET:-}" ]] || [[ -n "${CLI_JC:-}" ]] \
        || [[ -n "${CLI_JMIN:-}" ]] || [[ -n "${CLI_JMAX:-}" ]]; then
        generate_awg_params
    else
        log "AWG 2.0 parameters already set from config."
    fi

    # Save configuration
    log "Saving settings to $CONFIG_FILE..."
    local temp_conf
    temp_conf=$(mktemp) || die "mktemp error."
    _install_temp_files+=("$temp_conf")
    local quoted_server_name
    quoted_server_name=$(shell_quote "$AWG_SERVER_NAME")
    cat > "$temp_conf" << EOF
# AmneziaWG 2.0 installation configuration (Auto-generated)
# Used by installation and management scripts
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
        die "Error saving $CONFIG_FILE"
    fi
    chmod 600 "$CONFIG_FILE" || log_warn "chmod $CONFIG_FILE error"
    log "Settings saved."
    export AWG_PORT AWG_TUNNEL_SUBNET DISABLE_IPV6 ALLOWED_IPS_MODE ALLOWED_IPS AWG_ENDPOINT AWG_SERVER_NAME
    export AWG_IPV6_ENABLED AWG_IPV6_MODE_REQUESTED AWG_IPV6_MODE AWG_IPV6_MODE_EFFECTIVE AWG_IPV6_MODE_REASON AWG_IPV6_SUBNET AWG_IPV6_NDP_PROXY AWG_IPV6_LEAK_PROTECTION
    export AWG_P2P_ENABLED AWG_P2P_BASE_PORT AWG_P2P_PORTS_PER_CLIENT AWG_FULLCONE_NAT
    export AWG_WEB_ENABLED AWG_WEB_PORT AWG_WEB_BIND AWG_DISABLE_UFW
    export AWG_WEB_CERT_MODE AWG_WEB_DOMAIN AWG_WEB_CERT_FILE AWG_WEB_KEY_FILE AWG_WEB_CERT_PROVIDER AWG_WEB_LE_EMAIL AWG_WEB_PUBLIC_URL
    export AWG_WEB_CERT_FALLBACK AWG_WEB_CERT_ATTEMPTED_MODE AWG_WEB_CERT_FAILURE_REASON AWG_WEB_CERT_FALLBACK_USED
    export AWG_DNS_MODE AWG_CUSTOM_DNS AWG_ADGUARD_ENABLED AWG_ADGUARD_PORT AWG_ADGUARD_DIR
    export AWG_WIRESOCK_HINTS AWG_WIRESOCK_ID AWG_WIRESOCK_IP AWG_WIRESOCK_IB
    log "Port: ${AWG_PORT}/udp"
    log "Subnet: ${AWG_TUNNEL_SUBNET}"
    log "IPv6 disable: $DISABLE_IPV6"
    log "Client IPv6: ${AWG_IPV6_ENABLED} (requested=${AWG_IPV6_MODE_REQUESTED:-legacy}, effective=${AWG_IPV6_MODE_EFFECTIVE:-${AWG_IPV6_MODE:-legacy}} ${AWG_IPV6_SUBNET:-})"
    log "P2P: base=${AWG_P2P_BASE_PORT}, ports/client=${AWG_P2P_PORTS_PER_CLIENT}, fullcone=${AWG_FULLCONE_NAT}"
    log "Web: enabled=${AWG_WEB_ENABLED}, bind=${AWG_WEB_BIND}:${AWG_WEB_PORT}"
    log "DNS: mode=${AWG_DNS_MODE}, adguard=${AWG_ADGUARD_ENABLED}, port=${AWG_ADGUARD_PORT}"
    log "WireSock hints: ${AWG_WIRESOCK_HINTS:-off}"
    log "Server name: ${AWG_SERVER_NAME}"
    log "AllowedIPs mode: $ALLOWED_IPS_MODE"

    # Loading state
    if [[ -f "$STATE_FILE" ]]; then
        current_step=$(cat "$STATE_FILE")
        if ! [[ "$current_step" =~ ^[0-9]+$ ]]; then
            log_warn "$STATE_FILE corrupted."
            current_step=1
            update_state 1
        else
            log "Resuming from step $current_step."
        fi
    else
        current_step=1
        log "Starting from step 1."
        update_state 1
    fi
    log "Step 0 completed."
}

# ==============================================================================
# STEP 1: System update, cleanup, and optimization
# ==============================================================================

step1_update_and_optimize() {
    update_state 1
    log "### STEP 1: System update, cleanup, and optimization ###"

    # Clean unnecessary components (BEFORE update to save bandwidth/time)
    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        cleanup_system
    else
        log "Skipping system cleanup (--no-tweaks)."
    fi

    log "Updating package lists..."
    apt_update_tolerant || die "apt update error."

    log "Unlocking dpkg..."
    if ! apt-get check &>/dev/null; then
        log_warn "dpkg locked or corrupted, fixing..."
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a || log_warn "dpkg --configure -a."
    fi

    log "Updating system..."
    DEBIAN_FRONTEND=noninteractive apt full-upgrade -y || die "apt full-upgrade error."
    log "System updated."

    install_packages curl wget gpg sudo ethtool

    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        # System optimization
        optimize_system
        # Sysctl configuration
        setup_advanced_sysctl
        setup_voice_udp_optimization
    else
        log "Skipping optimization and hardening (--no-tweaks)."
        setup_minimal_sysctl
        setup_voice_udp_optimization
    fi

    log "Step 1 completed successfully."
    request_reboot 2
}

# ==============================================================================
# ARM prebuilt support
# ==============================================================================

# _try_install_prebuilt_arm — download and install a prebuilt amneziawg .deb
# for the current ARM kernel from the arm-packages GitHub release.
#
# Returns 0 if a matching prebuilt was installed successfully.
# Returns 1 if no match was found or installation failed (caller falls back to DKMS).
#
# Prebuilt packages are built by .github/workflows/arm-build.yml and published
# to the arm-packages release tag. The filename encodes both the target ID and
# the exact kernel version: amneziawg-kmod-<target-id>_<kernel-version>_<arch>.deb
#
# Kernel version matching is exact — the module vermagic must match uname -r.
# DKMS is the preferred path for kernels that haven't been pre-built yet.
_try_install_prebuilt_arm() {
    local kernel arch target_id asset_name asset_url tmpfile tmpsha expected_sha actual_sha
    kernel="$(uname -r)"
    arch="$(dpkg --print-architecture)"

    # Map kernel string to a build target ID
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
        log "No prebuilt target for kernel $kernel ($arch)"
        return 1
    fi

    # Asset filename encodes the exact kernel version
    asset_name="amneziawg-kmod-${target_id}_${kernel}_${arch}.deb"
    asset_url="https://github.com/bivlked/amneziawg-installer/releases/download/arm-packages/${asset_name}"

    log "Trying prebuilt: $asset_name"
    tmpfile="$(mktemp /tmp/amneziawg-prebuilt-XXXXXX.deb)"
    tmpsha="$(mktemp /tmp/amneziawg-prebuilt-XXXXXX.deb.sha256)"

    # Download SHA256 checksum first
    if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
            -o "$tmpsha" "${asset_url}.sha256" 2>/dev/null; then
        log "Prebuilt not available for $kernel — using DKMS"
        rm -f "$tmpfile" "$tmpsha"
        return 1
    fi

    if curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
            -o "$tmpfile" "$asset_url" 2>/dev/null; then
        # Verify integrity before installing a kernel module
        expected_sha="$(cat "$tmpsha")"
        actual_sha="$(sha256sum "$tmpfile" | awk '{print $1}')"
        rm -f "$tmpsha"
        if [[ "$expected_sha" != "$actual_sha" ]]; then
            log_warn "Prebuilt SHA256 mismatch — discarding download"
            rm -f "$tmpfile"
            return 1
        fi

        log "Downloaded prebuilt (SHA256 OK), installing..."
        if dpkg -i "$tmpfile" 2>/dev/null; then
            rm -f "$tmpfile"
            log "Prebuilt installed: $asset_name"
            return 0
        else
            log_warn "Prebuilt install failed (vermagic mismatch or corrupt package)"
            rm -f "$tmpfile"
            return 1
        fi
    else
        log "Prebuilt not available for $kernel — using DKMS"
        rm -f "$tmpfile" "$tmpsha"
        return 1
    fi
}

# ==============================================================================
# STEP 2: Installing AmneziaWG and dependencies
# ==============================================================================

step2_install_amnezia() {
    update_state 2

    # Guard: make sure the user actually rebooted before step 2.
    # If boot_id matches the one saved in request_reboot 2 — the reboot
    # did not happen (e.g. user re-ran the script by mistake). Step 1's
    # apt full-upgrade staged a new kernel on disk, but the running
    # kernel is still the old one → DKMS would build the module against
    # the old kernel and modprobe would fail after the next reboot.
    local boot_id_file="$AWG_DIR/.boot_id_before_step2"
    if [[ -f "$boot_id_file" ]] && [[ -r /proc/sys/kernel/random/boot_id ]]; then
        local saved_boot_id current_boot_id
        saved_boot_id=$(< "$boot_id_file")
        current_boot_id=$(< /proc/sys/kernel/random/boot_id)
        if [[ -n "$saved_boot_id" ]] && [[ "$saved_boot_id" == "$current_boot_id" ]]; then
            die "Reboot expected before step 2 (kernel upgrade is only activated after reboot). Run: sudo reboot — then re-run the script."
        fi
        log "Reboot confirmed (boot_id changed) — continuing with step 2"
        rm -f "$boot_id_file" 2>/dev/null || true
    fi

    log "### STEP 2: Installing AmneziaWG and dependencies ###"
    _APT_UPDATED=0  # Reset: new sources will be added in this step

    apt_update_tolerant || die "apt update error."

    # PPA Amnezia (without software-properties-common)
    log "Adding Amnezia PPA..."

    # Determine codename for PPA
    # On Debian, map to nearest Ubuntu codename since PPA is Launchpad (Ubuntu)
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
            # For Ubuntu non-LTS (questing/plucky/oracular/...) Amnezia PPA does
            # not publish packages — dists/<codename>/Release returns 404.
            # Pre-check via HEAD and fall back to noble (LTS): the noble build
            # gets DKMS-compiled against the running kernel.
            # Upstream: amnezia-vpn/amneziawg-linux-kernel-module#118
            case "$ppa_codename" in
                noble|jammy|focal)
                    # Known LTS — skip pre-check (PPA is reliably published)
                    ;;
                *)
                    log "Checking Amnezia PPA availability for Ubuntu '${ppa_codename}'..."
                    if ! curl -fsI --max-time 15 --retry 2 --retry-delay 5 \
                        "https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu/dists/${ppa_codename}/Release" \
                        >/dev/null 2>&1; then
                        log_warn "Amnezia PPA does not publish packages for Ubuntu '${ppa_codename}' (HTTP 404 or host unreachable)."
                        log_warn "Context: https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/issues/118"
                        if [[ "${AWG_ALLOW_PPA_CODENAME_FALLBACK:-0}" == "1" ]]; then
                            log_warn "Explicitly allowed PPA fallback '${ppa_codename}' -> noble."
                            ppa_codename="noble"
                        else
                            die "PPA for '${ppa_codename}' is unavailable. To explicitly fallback to noble, rerun with AWG_ALLOW_PPA_CODENAME_FALLBACK=1 or --allow-ppa-codename-fallback."
                        fi
                    else
                        log "Amnezia PPA is available for '${ppa_codename}'."
                    fi
                    ;;
            esac
            ;;
    esac

    local keyring_dir="/etc/apt/keyrings"
    local keyring_file="${keyring_dir}/amnezia-ppa.gpg"
    local ppa_sources="/etc/apt/sources.list.d/amnezia-ppa.sources"
    local ppa_list="/etc/apt/sources.list.d/amnezia-ppa.list"
    # Check for legacy files (from add-apt-repository of previous versions)
    local legacy_list="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-${codename}.list"
    local legacy_sources="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-${codename}.sources"
    # Re-run on a server where a previous run (≤ v5.12.1) wrote a broken
    # .sources file with Suites=questing/plucky/etc.: if the existing suite
    # doesn't match the target ppa_codename, remove the file so it gets
    # recreated below with the correct suite. Same check for legacy
    # .sources (add-apt-repository format).
    # If the file exists but `Suites:` can't be parsed — treat as corrupt
    # and recreate, otherwise the broken file would slip through as
    # "PPA already added".
    local existing_suite=""
    if [[ -f "$ppa_sources" ]]; then
        existing_suite=$(awk '/^Suites:/{print $2; exit}' "$ppa_sources" 2>/dev/null)
    fi
    if [[ -f "$ppa_sources" && ( -z "$existing_suite" || "$existing_suite" != "$ppa_codename" ) ]]; then
        if [[ -z "$existing_suite" ]]; then
            log_warn "$ppa_sources exists but no Suites: line found — recreating."
        else
            log_warn "Existing PPA suite='${existing_suite}', target='${ppa_codename}' — recreating $ppa_sources."
        fi
        rm -f "$ppa_sources" "$ppa_list"
    fi
    local legacy_suite=""
    if [[ -f "$legacy_sources" ]]; then
        legacy_suite=$(awk '/^Suites:/{print $2; exit}' "$legacy_sources" 2>/dev/null)
    fi
    if [[ -f "$legacy_sources" && ( -z "$legacy_suite" || "$legacy_suite" != "$ppa_codename" ) ]]; then
        log_warn "Legacy PPA $legacy_sources (suite='${legacy_suite:-<empty>}') does not match target '${ppa_codename}' — removing."
        rm -f "$legacy_sources" "$legacy_list"
    fi
    if [[ -f "$legacy_list" ]] || [[ -f "$legacy_sources" ]]; then
        log "PPA already added (legacy format)."
    elif [[ -f "$ppa_sources" ]] || [[ -f "$ppa_list" ]]; then
        log "PPA already added."
    else
        mkdir -p "$keyring_dir"
        log "Importing Amnezia PPA GPG key..."
        # Atomic: pipe into temp, then mv — a half-written keyring never
        # lives on the target path, even if curl/gpg die mid-way.
        local _kf_tmp
        _kf_tmp=$(mktemp -p "$keyring_dir" ".amnezia-ppa.gpg.tmp.XXXXXX") \
            || die "Failed to create temp file for GPG key."
        # --batch --no-tty --yes: gpg must not open /dev/tty (non-interactive
        # SSH, cloud-init, Ansible, etc.) and must not abort with "File exists"
        # when overwriting the mktemp-created tmp file. Without --yes gpg in
        # batch mode refuses to write into the pre-existing empty tmp file.
        if ! curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x57290828" \
             | gpg --batch --no-tty --yes --dearmor -o "$_kf_tmp"; then
            rm -f "$_kf_tmp" 2>/dev/null
            die "Amnezia PPA GPG key import error."
        fi
        chmod 644 "$_kf_tmp" || { rm -f "$_kf_tmp" 2>/dev/null; die "chmod GPG key error."; }
        mv -f "$_kf_tmp" "$keyring_file" \
            || { rm -f "$_kf_tmp" 2>/dev/null; die "Failed to move GPG key to target path."; }

        # Debian 12 uses traditional .list format, Debian 13+ and Ubuntu 24.04+ use DEB822 .sources
        if [[ "${OS_ID:-ubuntu}" == "debian" && "${OS_VERSION}" == "12" ]]; then
            log "Debian 12: using traditional .list format"
            echo "deb [signed-by=${keyring_file}] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu ${ppa_codename} main" \
                > "$ppa_list" || die "Failed to create $ppa_list"
            chmod 644 "$ppa_list"
        else
            cat > "$ppa_sources" <<PPASRC || die "PPA sources creation error."
Types: deb
URIs: https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu
Suites: ${ppa_codename}
Components: main
Signed-By: ${keyring_file}
PPASRC
            chmod 644 "$ppa_sources"
        fi
        log "PPA added."
    fi
    # apt-get update + error classification:
    #   - Errors only on the Amnezia PPA → continue, apt_wait_for_ppa_package
    #     below will retry (issue #68: ppa.launchpadcontent.net briefly down).
    #   - Any other non-source error (DNS / GPG mismatch / dpkg lock on the
    #     base mirror) → fail fast. Continuing on a stale apt-cache is unsafe —
    #     the next apt-get install would fail with a less actionable error
    #     (PR #69 review finding).
    if ! apt_update_tolerant --ppa-amnezia-tolerant; then
        log_error "apt-get update failed with a hard error — not a PPA outage (issue #68)."
        log_error "Check: DNS, access to archive.ubuntu.com / deb.debian.org,"
        log_error "integrity of keys in /etc/apt/keyrings, dpkg lock contention."
        die "apt update returned an error (rc!=0, not the Amnezia PPA)."
    fi
    # apt-get update is tolerant to an unreachable InRelease (rc=0 even when
    # the PPA is down). So we check that amneziawg-dkms actually appears in
    # apt-cache, with three attempts and 30s/60s backoff (~1.5 min total).
    # A brief ppa.launchpadcontent.net outage (issue #68) must not break
    # the install.
    if ! apt_wait_for_ppa_package amneziawg-dkms 3 30; then
        log_error "Package amneziawg-dkms did not appear in apt-cache after 3 attempts."
        log_error "ppa.launchpadcontent.net appears to be down — this is a"
        log_error "Launchpad infrastructure outage, not a script bug."
        log_error "Wait 10–15 minutes and re-run the script with the same args."
        log_error "Details: https://github.com/bivlked/amneziawg-installer/issues/68"
        die "Amnezia PPA is temporarily unavailable."
    fi

    # AmneziaWG + qrencode packages (NO Python!)
    log "Installing AmneziaWG packages..."

    # On ARM: try prebuilt .deb first (no build tools or headers required).
    # Falls back to DKMS if no matching prebuilt is available or download fails.
    local arch
    arch="$(uname -m)"
    if [[ "$arch" == "aarch64" || "$arch" == "armv7l" ]]; then
        if _try_install_prebuilt_arm; then
            log "Prebuilt kernel module installed. Installing userspace tools from PPA..."
            install_packages "amneziawg-tools" "wireguard-tools" "qrencode" "python3" "openssl"
            [[ "${AWG_IPV6_MODE:-}" == "ndp" && "${AWG_IPV6_NDP_PROXY:-0}" -eq 1 ]] && install_packages "ndppd"
            log "Step 2 completed (prebuilt ARM)."
            request_reboot 3
            return
        fi
        log "No matching prebuilt — falling back to DKMS build."
    fi

    local packages=("amneziawg-dkms" "amneziawg-tools" "wireguard-tools" "dkms"
                    "build-essential" "dpkg-dev" "qrencode" "python3" "openssl")
    if [[ "${AWG_IPV6_MODE:-}" == "ndp" && "${AWG_IPV6_NDP_PROXY:-0}" -eq 1 ]]; then
        packages+=("ndppd")
    fi

    # Linux headers: on Debian, exact linux-headers-$(uname -r) may not be available
    local current_headers
    current_headers="linux-headers-$(uname -r)"
    if dpkg -s "$current_headers" &>/dev/null || apt-cache show "$current_headers" &>/dev/null 2>&1; then
        packages+=("$current_headers")
    else
        log_warn "No headers for $(uname -r), installing generic package..."
        local kernel_release
        kernel_release="$(uname -r)"
        if [[ "$kernel_release" == *+rpt* || "$kernel_release" == *-rpi* ]]; then
            # Raspberry Pi Foundation kernel (+rpt suffix) — use RPi meta-package
            # linux-headers-rpi-2712: Pi 5 / Cortex-A76; linux-headers-rpi-v8: Pi 3/4 arm64
            local rpi_headers
            if [[ "$kernel_release" == *2712* ]]; then
                rpi_headers="linux-headers-rpi-2712"
            else
                rpi_headers="linux-headers-rpi-v8"
            fi
            log "Raspberry Pi kernel detected, using $rpi_headers"
            packages+=("$rpi_headers")
        elif [[ "${OS_ID:-ubuntu}" == "debian" ]]; then
            # On Debian: linux-headers-$(dpkg --print-architecture)
            local arch_pkg
            arch_pkg="linux-headers-$(dpkg --print-architecture 2>/dev/null || echo "amd64")"
            packages+=("$arch_pkg")
        else
            packages+=("linux-headers-generic")
        fi
    fi
    # v5.13.0: on 25.10/26.04 after an in-place upgrade from 24.04, the
    # system may still carry kernel headers from 24.04 (6.8.x) compiled with
    # gcc-13. 25.10 ships gcc-15 by default → dkms autoinstall in the
    # amneziawg-dkms postinst fails when building against stale kernels, and
    # dpkg leaves amneziawg* unconfigured. If we detect kernel headers other
    # than the running one, install gcc-13 ahead of time (available in
    # questing/universe and 26.04 archive) so autoinstall succeeds for every
    # kernel.
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
            log "Stale kernel headers detected (other than $_running_kernel) — installing gcc-13 for DKMS autoinstall compatibility."
            DEBIAN_FRONTEND=noninteractive apt install -y gcc-13 \
                || log_warn "gcc-13 install failed — DKMS autoinstall may fail on stale kernels."
        else
            log_warn "Stale kernel headers detected, but gcc-13 is not in the repo — DKMS autoinstall may fail."
        fi
    fi
    install_packages "${packages[@]}"

    # v5.12.0: install a kernel-headers meta-package so apt automatically
    # pulls matching headers on every kernel upgrade. Without the meta only
    # linux-headers-$(uname -r) is installed, which does not track new
    # kernels and the DKMS module fails to rebuild on the next apt upgrade.
    #
    # Detect kernel flavor (Ubuntu cloud images: aws/azure/gcp/oracle/kvm/
    # lowlatency/raspi; Debian cloud-amd64) — a plain linux-headers-generic
    # on an Azure VM does not track the right kernel pipeline. Take the
    # uname -r suffix, try the flavor-specific meta first, fall back to
    # generic / arch.
    local arch_meta kernel_rel
    arch_meta="$(dpkg --print-architecture 2>/dev/null || echo '')"
    kernel_rel="$(uname -r)"
    local -a meta_candidates=()
    if [[ "$kernel_rel" == *+rpt* || "$kernel_rel" == *-rpi* ]]; then
        : # RPi: linux-headers-rpi-{2712,v8} meta is already in packages above.
    elif [[ "${OS_ID:-ubuntu}" == "ubuntu" ]]; then
        # Ubuntu uname -r format: 6.8.0-49-generic / 6.8.0-1009-aws / ...
        local flavor="${kernel_rel##*-}"
        if [[ -n "$flavor" && "$flavor" != "$kernel_rel" ]]; then
            meta_candidates+=("linux-headers-${flavor}")
        fi
        meta_candidates+=("linux-headers-generic")
    elif [[ "${OS_ID:-}" == "debian" && -n "$arch_meta" ]]; then
        # Debian: stock kernel 6.12.85+deb13-amd64, cloud — 6.12.85+deb13-cloud-amd64.
        [[ "$kernel_rel" == *-cloud-* ]] \
            && meta_candidates+=("linux-headers-cloud-${arch_meta}")
        meta_candidates+=("linux-headers-${arch_meta}")
    fi
    local meta meta_installed=0
    for meta in "${meta_candidates[@]}"; do
        if dpkg-query -W -f='${Status}' "$meta" 2>/dev/null \
                | grep -q 'install ok installed'; then
            log "$meta is already installed (auto-tracking kernel upgrades)."
            meta_installed=1
            break
        fi
        log "Installing meta-package $meta..."
        if DEBIAN_FRONTEND=noninteractive apt install -y "$meta" 2>/dev/null; then
            log "$meta installed."
            meta_installed=1
            break
        fi
        log_warn "Failed to install $meta — trying next candidate."
    done
    if [[ ${#meta_candidates[@]} -gt 0 && $meta_installed -eq 0 ]]; then
        log_warn "No kernel-headers meta-package installed — auto-rebuild on kernel upgrade may not work."
    fi

    # v5.12.0: deploy the standalone helper /usr/local/sbin/amneziawg-ensure-module.
    # It is invoked from the apt hook (DPkg::Post-Invoke) and from the Phase 4
    # systemd unit. The helper is self-contained — it does NOT source
    # awg_common.sh — so it keeps working even if /root/awg/ is moved.
    #
    # Deploy uses a staging file in the SAME filesystem as the destination
    # plus a final `mv -f` — guaranteeing atomic replacement (a cross-FS
    # rename is copy+remove, NOT atomic). The staging file starts with a
    # dot so apt and logrotate skip dotfiles when scanning the directory.
    log "Deploying DKMS auto-repair helper..."
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
        || { rm -f "$_stage_helper"; die "Failed to chmod helper."; }
    mv -f "$_stage_helper" /usr/local/sbin/amneziawg-ensure-module \
        || { rm -f "$_stage_helper"; die "Failed to deploy amneziawg-ensure-module helper."; }
    log "Helper /usr/local/sbin/amneziawg-ensure-module deployed."

    # v5.12.0: apt hook DPkg::Post-Invoke calls the helper after a kernel upgrade.
    mkdir -p /etc/apt/apt.conf.d
    local _stage_hook=/etc/apt/apt.conf.d/.99-amneziawg-post-kernel.new
    cat > "$_stage_hook" <<'AWG_APT_HOOK_EOF'
// amneziawg-installer (v5.12.0+): rebuild DKMS module after kernel upgrades.
// Generated by install_amneziawg.sh — do not edit; re-run the installer to refresh.
DPkg::Post-Invoke {"if [ -x /usr/local/sbin/amneziawg-ensure-module ]; then /usr/local/sbin/amneziawg-ensure-module --hook >>/var/log/amneziawg-ensure-module.log 2>&1 || true; fi";};
AWG_APT_HOOK_EOF
    chown root:root "$_stage_hook" 2>/dev/null || true
    chmod 0644 "$_stage_hook" \
        || { rm -f "$_stage_hook"; die "Failed to chmod apt hook."; }
    mv -f "$_stage_hook" /etc/apt/apt.conf.d/99-amneziawg-post-kernel \
        || { rm -f "$_stage_hook"; die "Failed to deploy apt hook."; }
    log "Apt hook 99-amneziawg-post-kernel installed (auto-rebuild on apt kernel upgrade)."

    # v5.12.0: logrotate config for /var/log/amneziawg-ensure-module.log
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
        || { rm -f "$_stage_logrotate"; die "Failed to chmod logrotate config."; }
    mv -f "$_stage_logrotate" /etc/logrotate.d/amneziawg-ensure-module \
        || { rm -f "$_stage_logrotate"; die "Failed to deploy logrotate config."; }
    log "Logrotate config /etc/logrotate.d/amneziawg-ensure-module installed (weekly, rotate 4)."

    # v5.12.0 Phase 4: systemd unit guarantees the kernel module is built
    # and loaded BEFORE awg-quick@awg0 starts on every boot. Type=oneshot +
    # RemainAfterExit=yes + Before=awg-quick@awg0.service — the standard
    # pre-load pattern (after a kernel upgrade DKMS may need to rebuild on
    # the very first boot of the new kernel).
    log "Deploying systemd unit amneziawg-ensure-module.service..."
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
        || { rm -f "$_stage_unit"; die "Failed to chmod systemd unit."; }
    mv -f "$_stage_unit" /etc/systemd/system/amneziawg-ensure-module.service \
        || { rm -f "$_stage_unit"; die "Failed to deploy systemd unit."; }
    if ! systemctl daemon-reload; then
        log_warn "systemctl daemon-reload failed — the unit may not activate until reboot."
    fi
    if ! systemctl enable amneziawg-ensure-module.service; then
        log_warn "Failed to enable amneziawg-ensure-module.service — boot-time auto-rebuild will not run."
    fi
    log "Systemd unit amneziawg-ensure-module.service installed and enabled (Before=awg-quick@awg0)."

    # DKMS status
    log "Checking DKMS status..."
    local dkms_stat
    dkms_stat=$(dkms status 2>&1)
    if ! echo "$dkms_stat" | grep -q 'amneziawg.*installed'; then
        log_warn "DKMS status not OK."
        log_msg "WARN" "$dkms_stat"
    else
        log "DKMS status OK."
    fi

    log "Step 2 completed."
    request_reboot 3
}

# ==============================================================================
# STEP 3: Kernel module check
# ==============================================================================

step3_check_module() {
    update_state 3
    log "### STEP 3: Kernel module check ###"
    sleep 2

    if ! lsmod | grep -q -w amneziawg; then
        log "Module not loaded. Loading..."
        modprobe amneziawg || die "modprobe amneziawg error."
        log "Module loaded."
        local mf="/etc/modules-load.d/amneziawg.conf"
        mkdir -p "$(dirname "$mf")"
        if ! grep -qxF 'amneziawg' "$mf" 2>/dev/null; then
            echo "amneziawg" > "$mf" || log_warn "Write error $mf"
            log "Added to $mf."
        fi
    else
        log "amneziawg module loaded."
    fi

    log "Module information:"
    modinfo amneziawg | grep -E "filename|version|vermagic|srcversion" | while IFS= read -r line; do
        log "  $line"
    done

    local cv kr
    cv=$(modinfo amneziawg 2>/dev/null | awk '/^vermagic:/{print $2}')
    if [[ -z "$cv" ]]; then
        die "Failed to read amneziawg vermagic. Check: modprobe amneziawg && modinfo amneziawg"
    fi
    kr=$(uname -r)
    if [[ "$cv" != "$kr" ]]; then
        log_warn "VerMagic MISMATCH: Module($cv) != Kernel($kr)!"
    else
        log "VerMagic matches."
    fi

    # Check awg version
    if command -v awg &>/dev/null; then
        local awg_ver
        awg_ver=$(awg --version 2>/dev/null || echo "unknown")
        log "awg version: $awg_ver"
    else
        log_warn "awg command not found!"
    fi

    log "Step 3 completed."
    update_state 4
}

# ==============================================================================
# STEP 4: Firewall configuration
# ==============================================================================

step4_setup_firewall() {
    update_state 4
    if [[ "$NO_TWEAKS" -eq 0 && "${AWG_DISABLE_UFW:-0}" != "1" ]]; then
        log "### STEP 4: UFW firewall configuration ###"
        install_packages ufw
        setup_improved_firewall || die "UFW configuration error."
        log "Step 4 completed."
    elif [[ "${AWG_DISABLE_UFW:-0}" == "1" ]]; then
        log "### STEP 4: Skipping UFW enable (--disable-ufw/AWG_DISABLE_UFW=1) ###"
        setup_improved_firewall || true
    else
        log "### STEP 4: Skipping UFW configuration (--no-tweaks) ###"
    fi
    update_state 5
}

# ==============================================================================
# STEP 5: Downloading scripts (NO Python!)
# ==============================================================================

verify_sha256() {
    local file="$1" expected="$2" label="$3"
    if [[ -z "$expected" || "$expected" == "RELEASE_PLACEHOLDER" ]]; then
        log_error "SHA256 for $label is not set; unsafe download is blocked."
        return 1
    fi
    local actual
    actual=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        log_error "SHA256 mismatch for $label!"
        log_error "  Expected: $expected"
        log_error "  Got:      $actual"
        log_error "  File may have been tampered with. Re-download the installer from GitHub."
        return 1
    fi
    log_debug "SHA256 $label: OK ($actual)"
    return 0
}

# _secure_download <url> <target> <expected_sha256> <label> <mode>
# Atomic download:
#   1. curl → mktemp on the same FS as target;
#   2. verify_sha256 on the temp file (not on target, so a corrupt file
#      never lives on the target path even for a fraction of a second);
#   3. chmod 700 on temp;
#   4. mv -f temp → target (atomic rename).
# If any step fails, temp is removed and target is untouched.
_secure_download() {
    local url="$1" target="$2" expected_sha256="$3" label="$4" mode="${5:-644}"
    local tmp target_dir verified=1
    target_dir=$(dirname "$target")
    mkdir -p "$target_dir" || die "Failed to create directory $target_dir"
    tmp=$(mktemp -p "$target_dir" ".${label//\//_}.tmp.XXXXXX") \
        || die "Failed to create temp file for $label"
    if ! curl -fLso "$tmp" --max-time 60 --retry 2 "$url"; then
        rm -f "$tmp" 2>/dev/null
        die "$label download error"
    fi
    if [[ -z "$expected_sha256" || "$expected_sha256" == "RELEASE_PLACEHOLDER" ]]; then
        if [[ "${AWG_ALLOW_UNVERIFIED_DOWNLOAD:-0}" != "1" ]]; then
            rm -f "$tmp" 2>/dev/null
            die "$label is not available locally and SHA256 is unset. Installation stopped; add it to the SHA256 manifest or set AWG_ALLOW_UNVERIFIED_DOWNLOAD=1 only for development."
        fi
        log_warn "$label is being downloaded without SHA256 only because AWG_ALLOW_UNVERIFIED_DOWNLOAD=1."
        verified=0
    elif ! verify_sha256 "$tmp" "$expected_sha256" "$label"; then
        rm -f "$tmp" 2>/dev/null
        die "$label integrity check failed (SHA256 mismatch). Installation aborted."
    fi
    if ! chmod "$mode" "$tmp"; then
        rm -f "$tmp" 2>/dev/null
        die "chmod $label error"
    fi
    if ! mv -f "$tmp" "$target"; then
        rm -f "$tmp" 2>/dev/null
        die "Failed to move $label to target path"
    fi
    if [[ "$verified" -eq 1 ]]; then
        log "$label downloaded and verified."
    else
        log_warn "$label downloaded without SHA256 verification."
    fi
}

_deploy_asset() {
    local asset_path="$1" target="$2" mode="${3:-644}" src url expected
    src="${INSTALLER_DIR}/${asset_path}"
    url="https://raw.githubusercontent.com/${AWG_REPO}/${AWG_BRANCH}/${asset_path}"
    expected="${AWG_ASSET_SHA256[$asset_path]-}"
    mkdir -p "$(dirname "$target")" || die "Failed to create directory for $asset_path"
    if [[ -f "$src" ]]; then
        cp -a "$src" "$target" || die "Failed to copy $asset_path"
        chmod "$mode" "$target" || die "chmod failed for $asset_path"
        log "$asset_path copied locally."
        return 0
    fi
    _secure_download "$url" "$target" "$expected" "$asset_path" "$mode"
}

step5_download_scripts() {
    update_state 5
    log "### STEP 5: Downloading management scripts ###"
    cd "$AWG_DIR" || die "Error changing to $AWG_DIR"

    _deploy_asset "awg_common_en.sh" "$COMMON_SCRIPT_PATH" 700
    _deploy_asset "manage_amneziawg_en.sh" "$MANAGE_SCRIPT_PATH" 700
    _deploy_asset "scripts/update_geoip_dbs.py" "$AWG_DIR/scripts/update_geoip_dbs.py" 755

    log "Step 5 completed."
    update_state 6
}

setup_ndppd_config() {
    [[ "${AWG_IPV6_ENABLED:-0}" -eq 1 && "${AWG_IPV6_MODE:-}" == "ndp" && "${AWG_IPV6_NDP_PROXY:-0}" -eq 1 ]] || return 0
    local nic conf="/etc/ndppd.conf"
    [[ -n "${AWG_IPV6_SUBNET:-}" ]] || { log_warn "ndppd skipped: AWG_IPV6_SUBNET is empty."; return 0; }
    nic=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    [[ -n "$nic" ]] || nic="eth0"
    if [[ -f "$conf" ]] && ! grep -q "Managed by AmneziaWG installer" "$conf"; then
        cp -a "$conf" "${conf}.bak.$(date +%Y%m%d-%H%M%S)" || die "Failed to back up $conf"
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
    systemctl enable ndppd 2>/dev/null || log_warn "Failed to enable ndppd"
    systemctl restart ndppd 2>/dev/null || log_warn "Failed to restart ndppd"
    log "ndppd configured for ${AWG_IPV6_SUBNET} via ${nic}."
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
    log "Deploying AdGuard Home (fork delta)..."

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
        *) log_warn "AdGuard Home: unsupported architecture $(uname -m), skipping."; return 0 ;;
    esac

    mkdir -p "$ag_dir" || { log_warn "AdGuard Home: failed to create $ag_dir"; return 0; }
    if [[ ! -x "$ag_bin" ]]; then
        tmp=$(mktemp -d) || { log_warn "AdGuard Home: mktemp failed"; return 0; }
        tgz="$tmp/AdGuardHome_linux_${ag_arch}.tar.gz"
        url="https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_${ag_arch}.tar.gz"
        if curl -fL --connect-timeout 10 --max-time 120 -o "$tgz" "$url"; then
            if tar -xzf "$tgz" -C "$tmp" && [[ -x "$tmp/AdGuardHome/AdGuardHome" ]]; then
                cp -a "$tmp/AdGuardHome/." "$ag_dir/" || log_warn "AdGuard Home: failed to copy files into $ag_dir"
            else
                log_warn "AdGuard Home: archive unpack failed, DNS fallback remains available."
            fi
        else
            log_warn "AdGuard Home: download failed, VPN will keep working with the current DNS fallback."
        fi
        rm -rf "$tmp"
    fi

    if [[ ! -x "$ag_bin" ]]; then
        log_warn "AdGuard Home binary not found, skipping service start."
        return 0
    fi

    AG_USERNAME="${AG_USERNAME:-admin}"
    install_packages python3-bcrypt
    AG_PASSWORD="${AG_PASSWORD:-$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 15)}"
    if [[ -z "$AG_PASSWORD" ]]; then
        AG_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 15)"
    fi
    [[ -n "$AG_PASSWORD" ]] || die "AdGuard Home: failed to generate admin password"
    AG_HASH="$(printf '%s' "$AG_PASSWORD" | python3 -c '
import sys
import bcrypt

password = sys.stdin.buffer.read()
print(bcrypt.hashpw(password, bcrypt.gensalt(rounds=10, prefix=b"2b")).decode())
')" || die "AdGuard Home: failed to generate bcrypt hash"
    [[ -n "$AG_HASH" ]] || die "AdGuard Home: empty bcrypt password hash"

    timestamp="$(date '+%Y%m%d-%H%M%S')"
    tmp_conf="$(mktemp "$ag_dir/.AdGuardHome.yaml.tmp.XXXXXX")" || die "AdGuard Home: mktemp config failed"
    _install_temp_files+=("$tmp_conf")
    if [[ -f "$ag_yaml" ]]; then
        had_config=1
        backup_conf="${ag_yaml}.bak.${timestamp}"
        cp -p "$ag_yaml" "$backup_conf" || die "AdGuard Home: failed to create backup $backup_conf"
        chmod 600 "$backup_conf" 2>/dev/null || true
    fi

    render_curated_adguard_yaml "$ag_yaml" "$tmp_conf" "$SERVER_CONF_FILE" "$ag_port" "$AG_USERNAME" "$AG_HASH" || \
        die "AdGuard Home: failed to generate curated YAML"
    chmod 600 "$tmp_conf"

    local ag_dir_unit ag_bin_unit ag_conf_unit
    ag_dir_unit="$(systemd_abs_path_value "$ag_dir")" || die "Invalid AdGuardHome dir"
    ag_bin_unit="$(systemd_abs_path_value "$ag_bin")" || die "Invalid AdGuardHome binary path"
    ag_conf_unit="$(systemd_abs_path_value "$ag_yaml")" || die "Invalid AdGuardHome config path"

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
    systemctl enable AdGuardHome.service 2>/dev/null || log_warn "Failed to enable AdGuardHome.service"

    if systemctl is-active --quiet AdGuardHome.service 2>/dev/null; then
        systemctl stop AdGuardHome.service || true
    fi

    if ! "$ag_bin" --check-config -c "$tmp_conf" -w "$ag_dir"; then
        if [[ "$had_config" -eq 1 && -n "${backup_conf:-}" && -f "$backup_conf" ]]; then
            cp -p "$backup_conf" "$ag_yaml" || true
        fi
        die "AdGuard Home: --check-config failed, backup restored."
    fi

    if ! mv -f "$tmp_conf" "$ag_yaml"; then
        if [[ "$had_config" -eq 1 && -n "${backup_conf:-}" && -f "$backup_conf" ]]; then
            cp -p "$backup_conf" "$ag_yaml" || true
        fi
        die "AdGuard Home: failed to atomically replace $ag_yaml"
    fi
    chmod 600 "$ag_yaml"

    if ! systemctl restart AdGuardHome.service; then
        log_warn "AdGuard Home did not start. VPN is not broken; switch to system DNS: manage dns set-mode system."
    else
        log "AdGuard Home is running with curated YAML: DNS ${AWG_TUNNEL_SUBNET%/*}:53, UI http://${AWG_TUNNEL_SUBNET%/*}:${ag_port}/"
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
    persist_config_value AWG_WEB_CERT_MODE "${AWG_WEB_CERT_MODE:-selfsigned}" || log_warn "Failed to persist AWG_WEB_CERT_MODE."
    persist_config_value AWG_WEB_DOMAIN "${AWG_WEB_DOMAIN:-}" || log_warn "Failed to persist AWG_WEB_DOMAIN."
    persist_config_value AWG_WEB_PUBLIC_URL "${AWG_WEB_PUBLIC_URL:-}" || log_warn "Failed to persist AWG_WEB_PUBLIC_URL."
    persist_config_value AWG_WEB_CERT_ATTEMPTED_MODE "${AWG_WEB_CERT_ATTEMPTED_MODE:-}" || log_warn "Failed to persist AWG_WEB_CERT_ATTEMPTED_MODE."
    persist_config_value AWG_WEB_CERT_FAILURE_REASON "${AWG_WEB_CERT_FAILURE_REASON:-}" || log_warn "Failed to persist AWG_WEB_CERT_FAILURE_REASON."
    persist_config_value AWG_WEB_CERT_FALLBACK_USED "${AWG_WEB_CERT_FALLBACK_USED:-}" || log_warn "Failed to persist AWG_WEB_CERT_FALLBACK_USED."
}

ufw_allow_http01_temporarily() {
    local added=0
    AWG_CERTBOT_UFW80_ADDED=0
    export AWG_CERTBOT_UFW80_ADDED

    if ! command -v ufw >/dev/null 2>&1; then
        log_msg "WARN" "UFW is not installed; make sure 80/tcp is open in the external firewall/security group."
        return 0
    fi
    if ! ufw status 2>/dev/null | grep -qi "Status: active"; then
        log_msg "WARN" "UFW is inactive; make sure 80/tcp is open in the external firewall/security group."
        return 0
    fi
    if ufw status numbered 2>/dev/null | grep -Eq '(^|[[:space:]])80/tcp[[:space:]]+ALLOW IN'; then
        log_msg "INFO" "80/tcp is already open in UFW."
        return 0
    fi
    if ufw allow 80/tcp comment "Temporary Let's Encrypt HTTP-01" >/dev/null 2>&1; then
        added=1
    elif ufw allow 80/tcp >/dev/null 2>&1; then
        added=1
    else
        log_msg "WARN" "Failed to open 80/tcp in UFW. Check the external firewall/security group."
        return 1
    fi
    ufw reload >/dev/null 2>&1 || true
    AWG_CERTBOT_UFW80_ADDED="$added"
    export AWG_CERTBOT_UFW80_ADDED
    log_msg "INFO" "Temporarily opened 80/tcp for Let's Encrypt HTTP-01."
}

ufw_remove_http01_temporary_rule() {
    [[ "${AWG_CERTBOT_UFW80_ADDED:-0}" == "1" ]] || return 0
    AWG_CERTBOT_UFW80_ADDED=0
    export AWG_CERTBOT_UFW80_ADDED
    ufw delete allow 80/tcp >/dev/null 2>&1 || true
    ufw reload >/dev/null 2>&1 || true
    log_msg "INFO" "Temporary 80/tcp rule removed."
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
    log_warn "HTTP-01 requires inbound TCP/80 in UFW and the provider firewall/security group."
    resolved="$(resolve_domain_ipv4 "$domain")"
    if [[ -z "$resolved" ]]; then
        log_warn "Could not verify DNS A record for $domain. Make sure it points to this server."
        return 0
    fi
    if [[ "$endpoint" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && "$resolved" != "$endpoint" ]]; then
        log_warn "DNS $domain resolves to $resolved, but server endpoint is $endpoint."
        if [[ "$AUTO_YES" -ne 0 ]]; then
            return 1
        fi
        read -rp "Continue Let's Encrypt attempt despite DNS mismatch? [y/N]: " confirm < /dev/tty
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
    log_warn "Let's Encrypt did not issue a certificate for ${domain}: ${AWG_WEB_CERT_FAILURE_REASON}."
    if [[ "${AWG_WEB_CERT_FALLBACK:-abort}" == "selfsigned" || "${AWG_CERT_FALLBACK_SELFSIGNED:-0}" == "1" ]]; then
        log_warn "VPN will work. Web Panel will continue with self-signed HTTPS until you configure a trusted cert."
        AWG_WEB_CERT_MODE="selfsigned"
        AWG_WEB_CERT_FALLBACK_USED="selfsigned"
        persist_web_cert_state
        deploy_web_tls "$web_dir"
        return 0
    fi
    if [[ "$AUTO_YES" -ne 0 ]]; then
        persist_web_cert_state
        die "Let's Encrypt issuance failed; trusted HTTPS is not configured. Use --web-cert-fallback=selfsigned or AWG_WEB_CERT_FALLBACK=selfsigned to continue with fallback."
    fi
    echo ""
    echo "Let's Encrypt did not issue a certificate for ${domain}."
    echo "Reason: ${AWG_WEB_CERT_FAILURE_REASON}"
    echo "Choose:"
    echo "  1) Switch to self-signed and continue"
    echo "  2) Enter another domain"
    echo "  3) Retry certbot"
    echo "  4) Abort installation"
    ask_choice choice "Your choice [1]: " "1" "1 2 3 4"
    case "${choice:-1}" in
        1)
            log_warn "VPN will work. Web Panel will continue with self-signed HTTPS until you configure a trusted cert."
            AWG_WEB_CERT_MODE="selfsigned"
            AWG_WEB_CERT_FALLBACK_USED="selfsigned"
            persist_web_cert_state
            deploy_web_tls "$web_dir"
            ;;
        2)
            ask_domain domain_input "Enter new Web Panel domain: "
            AWG_WEB_CERT_MODE="letsencrypt"
            AWG_WEB_DOMAIN="$domain_input"
            deploy_web_tls "$web_dir"
            ;;
        3)
            deploy_web_tls "$web_dir"
            ;;
        *) die "Let's Encrypt issuance failed; trusted HTTPS is not configured." ;;
    esac
}

deploy_web_tls() {
    local web_dir="$1" mode="${AWG_WEB_CERT_MODE:-selfsigned}" domain="${AWG_WEB_DOMAIN:-}"
    case "$mode" in
        selfsigned)
            if [[ ! -f "$web_dir/cert.pem" || ! -f "$web_dir/key.pem" ]]; then
                openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
                    -keyout "$web_dir/key.pem" -out "$web_dir/cert.pem" \
                    -subj "/CN=VPN Panel" >/dev/null 2>&1 || die "Failed to generate TLS certificate"
            fi
            ;;
        custom)
            [[ -f "${AWG_WEB_CERT_FILE:-}" && -f "${AWG_WEB_KEY_FILE:-}" ]] || die "Custom TLS cert/key not found."
            install -m 644 "$AWG_WEB_CERT_FILE" "$web_dir/cert.pem" || die "Failed to copy custom cert"
            install -m 600 "$AWG_WEB_KEY_FILE" "$web_dir/key.pem" || die "Failed to copy custom key"
            ;;
        letsencrypt|ip-domain)
            AWG_WEB_CERT_ATTEMPTED_MODE="$mode"
            AWG_WEB_CERT_FAILURE_REASON=""
            AWG_WEB_CERT_FALLBACK_USED=""
            if [[ "$mode" == "ip-domain" ]]; then
                domain="$(web_ip_domain)" || die "ip-domain requires IPv4 AWG_ENDPOINT."
                AWG_WEB_DOMAIN="$domain"
            fi
            [[ -n "$domain" ]] || die "Let's Encrypt requires a domain."
            log_warn "Let's Encrypt standalone requires temporary reachable port 80/tcp and DNS ${domain} → endpoint."
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
            certbot_log="$(mktemp /tmp/awg-certbot-XXXXXX.log)" || die "Failed to create certbot log."
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
            install -m 644 "/etc/letsencrypt/live/${domain}/fullchain.pem" "$web_dir/cert.pem" || die "Failed to install fullchain.pem"
            install -m 600 "/etc/letsencrypt/live/${domain}/privkey.pem" "$web_dir/key.pem" || die "Failed to install privkey.pem"
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
    [[ "${AWG_WEB_ENABLED:-1}" -eq 1 ]] || { log "Web panel disabled (--disable-web)."; return 0; }
    log "Deploying web panel (fork delta)..."
    local web_dir="$AWG_DIR/web"
    mkdir -p "$web_dir" || die "Failed to create $web_dir"
    mkdir -p "$web_dir/vendor" || die "Failed to create $web_dir/vendor"
    chmod 755 "$web_dir" "$web_dir/vendor"

    if [[ ! -f "$web_dir/tokens.json" ]]; then
        local legacy_token="" super_token=""
        # auth_token is a legacy v5.13.0 fork-delta file; migrate it into tokens.json.
        if [[ -f "$web_dir/auth_token" ]]; then
            legacy_token=$(tr -d '[:space:]' < "$web_dir/auth_token" 2>/dev/null || true)
        fi
        if [[ -n "$legacy_token" ]]; then
            python3 - "$web_dir/tokens.json" "$legacy_token" <<'PY' || die "Failed to migrate web tokens"
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
            python3 - "$web_dir/tokens.json" "$super_token" <<'PY' || die "Failed to generate web tokens"
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
        log_warn "Raw Web super token is unavailable for install summary; running safe reset-super for this fresh/resume install."
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
)" || die "Failed to reset Web super token"
    fi
    if [[ -n "${AWG_WEB_SUPER_TOKEN_ONCE:-}" ]]; then
        python3 - "$web_dir/tokens.json" "$AWG_WEB_SUPER_TOKEN_ONCE" <<'PY' || die "Generated Web super token failed verification"
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
    web_server_unit="$(systemd_abs_path_value "$web_dir/server.py")" || die "Invalid web/server.py path"

    if [[ "${AWG_WEB_BIND:-}" == "0.0.0.0" || "${AWG_WEB_BIND:-}" == "::" ]]; then
        log_warn "Web Panel is listening on public bind ${AWG_WEB_BIND}:${AWG_WEB_PORT:-8443}. Python stdlib HTTP server is acceptable for a lightweight admin panel, but weaker than nginx/caddy at a public edge."
        log_warn "Recommended options: VPN-only bind 10.9.9.1, localhost + SSH tunnel, or a reverse proxy with TLS, timeouts and connection limits."
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
    systemctl enable awg-web.service 2>/dev/null || log_warn "Failed to enable awg-web.service"
    install_nginx_awg0_wait_dropin "${AWG_NGINX_WAIT_IFACE:-awg0}" "${AWG_NGINX_WAIT_IP:-${AWG_TUNNEL_SUBNET%/*}}" "${AWG_NGINX_WAIT_TIMEOUT:-90}" \
        || log_warn "Failed to install nginx wait-for-awg0 drop-in"
    log "Web panel deployed."
    if [[ -n "${AWG_WEB_SUPER_TOKEN_ONCE:-}" ]]; then
        log "Web super token: generated; raw value printed to console and INSTALL_SUMMARY only."
        print_secret_console_only "Web super token: ${AWG_WEB_SUPER_TOKEN_ONCE}"
    else
        log "Web tokens: $web_dir/tokens.json (to reset: manage web token reset-super)"
    fi
}


# ==============================================================================
# STEP 6: Config generation (native, without awgcfg.py)
# ==============================================================================

configs_ready_for_step6_resume() {
    [[ -f "$SERVER_CONF_FILE" ]] || return 1
    [[ -f "$AWG_DIR/my_phone.conf" && -f "$AWG_DIR/my_laptop.conf" ]] || return 1
    grep -qxF "#_Name = my_phone" "$SERVER_CONF_FILE" 2>/dev/null || return 1
    grep -qxF "#_Name = my_laptop" "$SERVER_CONF_FILE" 2>/dev/null || return 1
}

step6_generate_configs() {
    update_state 6
    log "### STEP 6: AWG 2.0 config generation ###"
    cd "$AWG_DIR" || die "cd $AWG_DIR error"

    # Load shared library
    if [[ ! -f "$COMMON_SCRIPT_PATH" ]]; then
        die "awg_common.sh not found. Step 5 not completed?"
    fi
    # shellcheck source=/dev/null
    source "$COMMON_SCRIPT_PATH"

    # Create key directory
    mkdir -p "$KEYS_DIR" || die "Error creating $KEYS_DIR"

    if [[ "$FORCE_REINSTALL" -ne 1 && "$CLI_UPGRADE_IPV6" -ne 1 ]] && configs_ready_for_step6_resume; then
        log "AWG configs and default clients already exist; resume step 6 will continue web/cert deploy without recreating clients."
        validate_awg_config || log_warn "Config validation found issues."
        generate_firewall_scripts || log_warn "Failed to update firewall/P2P hook scripts."
        setup_ndppd_config
        deploy_web_panel
        secure_files
        log "Step 6 completed."
        update_state 7
        return 0
    fi

    # Generate server keys (if not yet present)
    if [[ ! -f "$AWG_DIR/server_private.key" ]]; then
        log "Generating server keys..."
        generate_server_keys || die "Server key generation error."
    else
        log "Server keys already exist."
    fi

    # Backup existing server config BEFORE overwriting
    if [[ -f "$SERVER_CONF_FILE" ]]; then
        local s_bak
        s_bak="${SERVER_CONF_FILE}.bak-$(date +%F_%H%M%S)"
        cp "$SERVER_CONF_FILE" "$s_bak" || log_warn "Backup error $s_bak"
        log "Server config backup: $s_bak"
    fi

    # Create AWG 2.0 server config
    log "Creating server config..."
    render_server_config || die "Server config creation error."

    # Restore existing [Peer] blocks from backup (excluding defaults)
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
            log "Existing peers restored from backup."
        fi
    fi

    # Generate default clients
    log "Creating default clients..."
    local client_name
    for client_name in my_phone my_laptop; do
        if grep -qxF "#_Name = ${client_name}" "$SERVER_CONF_FILE" 2>/dev/null; then
            log "Client '$client_name' already exists."
        else
            log "Creating client '$client_name'..."
            generate_client "$client_name" || log_warn "Client creation error '$client_name'"
        fi
    done

    if [[ "$CLI_UPGRADE_IPV6" -eq 1 ]]; then
        log "Migrating existing clients to IPv6/P2P metadata..."
        upgrade_existing_peers_ipv6_p2p 1 1 || log_warn "Peer metadata migration failed."
        local upgrade_clients cname
        upgrade_clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //') || upgrade_clients=""
        while IFS= read -r cname; do
            [[ -n "$cname" ]] || continue
            regenerate_client "$cname" || log_warn "Failed to regenerate '$cname' after IPv6 upgrade."
        done <<< "$upgrade_clients"
    fi

    # Config validation
    validate_awg_config || log_warn "Config validation found issues."
    generate_firewall_scripts || log_warn "Failed to update firewall/P2P hook scripts."
    setup_ndppd_config
    deploy_web_panel

    if [[ "$CLI_ENABLE_GEOIP_AUTO_UPDATE" -eq 1 ]]; then
        geoip_auto_update_enable || log_warn "Failed to enable GeoIP database auto-update."
    fi

    # Set file permissions
    secure_files

    log "Configuration files in $AWG_DIR:"
    ls -la "$AWG_DIR"/*.conf "$AWG_DIR"/*.png 2>/dev/null | while IFS= read -r line; do
        log "  $line"
    done

    log "Step 6 completed."
    update_state 7
}

# ==============================================================================
# STEP 7: Service startup
# ==============================================================================

step7_start_service() {
    update_state 7
    log "### STEP 7: Service startup and security configuration ###"

    log "Enabling and starting awg-quick@awg0..."
    if systemctl is-active --quiet awg-quick@awg0; then
        log "Service already active — restarting to apply configuration..."
        systemctl enable awg-quick@awg0 || log_warn "Failed to enable awg-quick@awg0 — check autostart manually"
        systemctl restart awg-quick@awg0 || die "restart awg-quick@awg0 error."
    else
        systemctl enable --now awg-quick@awg0 || die "enable --now error."
    fi
    log "Service enabled and started."

    if [[ "${AWG_WEB_ENABLED:-1}" -eq 1 ]]; then
        log "Starting web panel awg-web.service..."
        systemctl restart awg-web.service || log_warn "Failed to start awg-web.service"
    fi
    deploy_adguard_home

    log "Checking service status..."
    local _attempt
    for _attempt in 1 2 3 4 5; do
        sleep 1
        check_service_status 2>/dev/null && break
        [[ $_attempt -lt 5 ]] && log_debug "Waiting for service startup... (attempt $_attempt/5)"
    done
    check_service_status || die "Service status check failed."

    # Fail2Ban
    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        setup_fail2ban
    else
        log "Skipping Fail2Ban (--no-tweaks)."
    fi

    log "Step 7 completed successfully."
    update_state 99
}

# ==============================================================================
# STEP 99: Completion
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
    log "CLIENTS:"
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
    log "║  IMPORTANT: ALL ACCESS INFO IS SAVED IN THIS FILE          ║"
    log "║                                                            ║"
    log "║  ${path}                            ║"
    log "║                                                            ║"
    log "║  Contains: links, Web token, AdGuard password, configs, QR.║"
    log "║  This file contains secrets. Permissions: 0600.            ║"
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
    log "### INSTALLATION COMPLETE ###"
    log "============================================================"
    log "INSTALLATION COMPLETED SUCCESSFULLY"
    log "============================================================"
    log " "
    log "MAIN:"
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
    log "USEFUL COMMANDS:"
    log "  sudo bash $MANAGE_SCRIPT_PATH help   # Client management"
    log "  systemctl status awg-quick@awg0      # VPN status"
    log "  awg show                              # AmneziaWG status"
    log "  ufw status verbose                    # Firewall status"
    log " "
    log "IMPORTANT: Use Amnezia VPN client >= 4.8.12.7 to connect"
    log "           with AWG 2.0 protocol support"
    log " "
    write_install_summary
    log "IMPORTANT:"
    print_summary_notice_block
    log " "
    if declare -f print_vpn_readiness_checklist >/dev/null 2>&1; then
        print_vpn_readiness_checklist
        log " "
    fi
    cleanup_apt
    log " "

    # Final checks
    if [[ -f "$CONFIG_FILE" ]]; then
        log "Settings file $CONFIG_FILE: OK"
    else
        log_error "Settings file $CONFIG_FILE MISSING!"
    fi

    # Remove state file
    log "Removing installation state file..."
    rm -f "$STATE_FILE" "${STATE_FILE}.lock" "$AWG_DIR/.boot_id_before_step2" || log_warn "Failed to remove $STATE_FILE"
    log "Installation fully completed. Log: $LOG_FILE"
    log "=============================================================================="
}

# ==============================================================================
# Main execution loop
# ==============================================================================

if [[ "$HELP" -eq 1 ]]; then show_help; fi
if [[ "$UNINSTALL" -eq 1 ]]; then step_uninstall; fi
if [[ "$DIAGNOSTIC" -eq 1 ]]; then create_diagnostic_report; exit 0; fi
if [[ "$VERBOSE" -eq 1 ]]; then set -x; fi

# v5.13.0: idempotency guard — if AmneziaWG is already installed and
# running, a re-run wastes ~20 minutes (Step 1 re-tunes sysctl/swap/BBR,
# `apt-get upgrade` can pull a new kernel and force another reboot, Step 7
# restarts awg-quick@awg0 — handshakes drop for a few seconds). Server
# keys, peers and obfuscation parameters survive a re-run, but without
# explicit opt-in this behaviour looks like a silent reinstall. Guarded by
# an explicit flag.
# AWG_FORCE_REINSTALL=1 in the environment is equivalent to --force.
if [[ "${AWG_FORCE_REINSTALL:-0}" == "1" ]]; then
    FORCE_REINSTALL=1
fi
if [[ "$FORCE_REINSTALL" -ne 1 && "$CLI_UPGRADE_IPV6" -ne 1 ]] && [[ -f "$SERVER_CONF_FILE" ]] \
   && systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
    log_error "AmneziaWG is already installed and running."
    log_error "To reinstall — pass --force (or AWG_FORCE_REINSTALL=1)."
    log_error "WARNING: a reinstall will rerun Step 1 (sysctl/swap/BBR) and Step 7 (service restart);"
    log_error "         obfuscation parameters (Jc/Jmin/Jmax/H1-H4/I1) survive."
    log_error "To manage clients:  sudo bash $MANAGE_SCRIPT_PATH help"
    log_error "To fully uninstall: sudo bash $0 --uninstall"
    exit 0
fi

initialize_setup

while (( current_step < 99 )); do
    log "Executing step $current_step..."
    case $current_step in
        1) step1_update_and_optimize ;;
        2) step2_install_amnezia ;;
        3) step3_check_module; current_step=4 ;;
        4) step4_setup_firewall; current_step=5 ;;
        5) step5_download_scripts; current_step=6 ;;
        6) step6_generate_configs; current_step=7 ;;
        7) step7_start_service; current_step=99 ;;
        *) die "Error: Unknown step $current_step." ;;
    esac
done

if (( current_step == 99 )); then step99_finish; fi
exit 0
