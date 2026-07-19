#!/usr/bin/env bash
# Install the optional Telegram control-plane microservice.
set -Eeuo pipefail

BOT_ROOT="${GAULLEBOT_ROOT:-/srv/code/bots/GaulleBot}"
REPO="${AWG_REPO:-Basil-AS/amneziawg-installer}"
BRANCH="${AWG_BRANCH:-main}"
TOKEN="${BOT_TOKEN:-}"
ADMIN_CHAT_ID="${ADMIN_CHAT_ID:-}"
API_ROOT="${TELEGRAM_API_ROOT:-https://api.telegram.org}"
SOURCE_DIR="${GAULLEBOT_SOURCE_DIR:-}"
SSH_KEY="${GAULLEBOT_SSH_KEY:-}"
PANELS_CONFIG="${GAULLEBOT_PANELS_CONFIG:-/etc/gaullebot-panels.json}"
PANELS_CONFIG_SOURCE="${GAULLEBOT_PANELS_CONFIG_SOURCE:-}"
FINLAND_PANEL_TOKEN="${FINLAND_PANEL_TOKEN:-}"
GERMANY_PANEL_TOKEN="${GERMANY_PANEL_TOKEN:-}"

die() { printf '[gaullebot] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[gaullebot] %s\n' "$*"; }
usage() {
    cat <<'EOF'
Usage: install-telegram-bot.sh --token TOKEN --admin-chat-id TELEGRAM_ID [options]

Options:
  --token TOKEN              Telegram bot token (never written to git)
  --admin-chat-id ID         Telegram administrator chat/user ID
  --api-root URL             Telegram API root (default: official HTTPS API)
  --source-dir DIR           Use local modules/telegram-bot files
  --ssh-key PATH             SSH private key for configured VPN panel connectors
  --help

The module is disabled unless this script is explicitly run. It installs only
the bot service; the VPN web panel remains a separate process. For low-latency
panel API access, provide GAULLEBOT_PANELS_CONFIG_SOURCE or set
FINLAND_PANEL_TOKEN and GERMANY_PANEL_TOKEN in the environment.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --token) [[ $# -ge 2 ]] || die "--token requires a value"; TOKEN="$2"; shift 2 ;;
        --admin-chat-id) [[ $# -ge 2 ]] || die "--admin-chat-id requires a value"; ADMIN_CHAT_ID="$2"; shift 2 ;;
        --api-root) [[ $# -ge 2 ]] || die "--api-root requires a value"; API_ROOT="$2"; shift 2 ;;
        --source-dir) [[ $# -ge 2 ]] || die "--source-dir requires a value"; SOURCE_DIR="$2"; shift 2 ;;
        --ssh-key) [[ $# -ge 2 ]] || die "--ssh-key requires a value"; SSH_KEY="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

[[ "$EUID" -eq 0 ]] || die "run as root"
[[ "$TOKEN" =~ ^[0-9]{6,}:[A-Za-z0-9_-]{20,}$ ]] || die "Telegram token is missing or malformed"
[[ "$ADMIN_CHAT_ID" =~ ^-?[0-9]+$ ]] || die "admin chat ID is missing or malformed"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v systemctl >/dev/null 2>&1 || die "systemd is required"

if ! getent group gaullebot >/dev/null; then groupadd --system gaullebot; fi
if ! id gaullebot >/dev/null 2>&1; then useradd --system --home-dir "$BOT_ROOT" --shell /usr/sbin/nologin --gid gaullebot gaullebot; fi
install -d -o gaullebot -g gaullebot -m 0750 "$BOT_ROOT" "$BOT_ROOT/src" "$BOT_ROOT/test" "$BOT_ROOT/deploy" "$BOT_ROOT/data" "$BOT_ROOT/var" "$BOT_ROOT/logs"

raw_base="https://raw.githubusercontent.com/${REPO}/${BRANCH}/modules/telegram-bot"
download_or_copy() {
    local name="$1" target="$BOT_ROOT/$1"
    if [[ -n "$SOURCE_DIR" && -f "$SOURCE_DIR/$name" ]]; then
        install -o root -g gaullebot -m 0640 "$SOURCE_DIR/$name" "$target"
    else
        command -v curl >/dev/null 2>&1 || die "curl is required when --source-dir is not used"
        curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
            "${raw_base}/${name}" -o "$target"
        chown root:gaullebot "$target"; chmod 0640 "$target"
    fi
}
download_or_copy src/bot.py
download_or_copy src/__init__.py
download_or_copy deploy/gaullebot.service
install -d -o root -g gaullebot -m 0750 "$BOT_ROOT/src" "$BOT_ROOT/deploy"
chmod 0750 "$BOT_ROOT/src" "$BOT_ROOT/deploy"

env_tmp="$(mktemp)"
trap 'rm -f "$env_tmp"' EXIT
{
    printf 'BOT_TOKEN=%q\n' "$TOKEN"
    printf 'ADMIN_CHAT_ID=%q\n' "$ADMIN_CHAT_ID"
    printf 'TELEGRAM_API_ROOT=%q\n' "$API_ROOT"
    printf 'DB_PATH=%q\n' "$BOT_ROOT/data/gaullebot.sqlite3"
    printf 'POLL_TIMEOUT=30\n'
    printf 'PANEL_TUNNELS_ENABLED=1\n'
    printf 'MINI_APP_URL=%q\n' "${MINI_APP_URL:-}"
    printf 'WEBHOOK_URL=%q\n' "${WEBHOOK_URL:-}"
    printf 'WEBHOOK_SECRET=%q\n' "${WEBHOOK_SECRET:-}"
    printf 'WEBHOOK_BIND=127.0.0.1\nWEBHOOK_PORT=8788\n'
    printf 'MINI_APP_BIND=127.0.0.1\nMINI_APP_PORT=8789\n'
    printf 'PANELS_CONFIG=%q\n' "$PANELS_CONFIG"
    printf 'FINLAND_SSH_HOST=194.180.189.244\nFINLAND_SSH_PORT=22\nFINLAND_SSH_USER=root\nFINLAND_WEB_PORT=8443\n'
    printf 'GERMANY_SSH_HOST=77.90.29.231\nGERMANY_SSH_PORT=22\nGERMANY_SSH_USER=root\nGERMANY_WEB_PORT=443\n'
    if [[ -n "$SSH_KEY" ]]; then
        install -o root -g gaullebot -m 0640 "$SSH_KEY" "$BOT_ROOT/var/vpn-admin-ed25519"
        printf 'FINLAND_SSH_IDENTITY=%q\nGERMANY_SSH_IDENTITY=%q\n' "$BOT_ROOT/var/vpn-admin-ed25519" "$BOT_ROOT/var/vpn-admin-ed25519"
    fi
} > "$env_tmp"
install -o root -g gaullebot -m 0640 "$env_tmp" /etc/gaullebot.env

# Prefer bearer API connectors when an operator supplied a protected config or
# both panel tokens.  Without it the bot remains functional through the
# restricted SSH fallback, but every command pays an SSH connection setup cost.
if [[ -n "$PANELS_CONFIG_SOURCE" ]]; then
    [[ -f "$PANELS_CONFIG_SOURCE" ]] || die "panel config source not found"
    install -o root -g gaullebot -m 0640 "$PANELS_CONFIG_SOURCE" "$PANELS_CONFIG"
elif [[ -n "$FINLAND_PANEL_TOKEN" && -n "$GERMANY_PANEL_TOKEN" ]]; then
    [[ "$FINLAND_PANEL_TOKEN" =~ ^[A-Za-z0-9._~+/-]+=*$ ]] || die "Finland panel token contains unsafe characters"
    [[ "$GERMANY_PANEL_TOKEN" =~ ^[A-Za-z0-9._~+/-]+=*$ ]] || die "Germany panel token contains unsafe characters"
    install -d -o root -g gaullebot -m 0750 "$(dirname "$PANELS_CONFIG")"
    panel_tmp="$(mktemp)"
    trap 'rm -f "$env_tmp" "$panel_tmp"' EXIT
    printf '{"panels":[{"id":"finland","name":"Sunny-Finland","url":"https://127.0.0.1:18443","token":"%s","verify_tls":false},{"id":"germany","name":"Sunny-German","url":"https://127.0.0.1:18444","token":"%s","verify_tls":false}]}\n' \
        "$FINLAND_PANEL_TOKEN" "$GERMANY_PANEL_TOKEN" > "$panel_tmp"
    install -o root -g gaullebot -m 0640 "$panel_tmp" "$PANELS_CONFIG"
    rm -f "$panel_tmp"
fi

install -o root -g root -m 0644 "$BOT_ROOT/deploy/gaullebot.service" /etc/systemd/system/gaullebot.service
systemctl daemon-reload
systemctl enable --now gaullebot.service
systemctl is-active --quiet gaullebot.service || die "gaullebot.service failed to start"
log "GaulleBot installed and active at $BOT_ROOT"
