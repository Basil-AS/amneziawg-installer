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
PANELS_CONFIG="${GAULLEBOT_PANELS_CONFIG:-$BOT_ROOT/var/panels.json}"

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
the bot service; the VPN web panel remains a separate process.
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
    printf 'PANELS_CONFIG=%q\n' "$PANELS_CONFIG"
    printf 'FINLAND_SSH_HOST=194.180.189.244\nFINLAND_SSH_PORT=22\nFINLAND_SSH_USER=root\n'
    printf 'GERMANY_SSH_HOST=77.90.29.231\nGERMANY_SSH_PORT=22\nGERMANY_SSH_USER=root\n'
    if [[ -n "$SSH_KEY" ]]; then
        install -o root -g gaullebot -m 0640 "$SSH_KEY" "$BOT_ROOT/var/vpn-admin-ed25519"
        printf 'FINLAND_SSH_IDENTITY=%q\nGERMANY_SSH_IDENTITY=%q\n' "$BOT_ROOT/var/vpn-admin-ed25519" "$BOT_ROOT/var/vpn-admin-ed25519"
    fi
} > "$env_tmp"
install -o root -g gaullebot -m 0640 "$env_tmp" /etc/gaullebot.env

install -o root -g root -m 0644 "$BOT_ROOT/deploy/gaullebot.service" /etc/systemd/system/gaullebot.service
systemctl daemon-reload
systemctl enable --now gaullebot.service
systemctl is-active --quiet gaullebot.service || die "gaullebot.service failed to start"
log "GaulleBot installed and active at $BOT_ROOT"
