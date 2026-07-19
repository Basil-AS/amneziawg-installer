# GaulleBot

Telegram administration bot for the two AmneziaWG servers. Python standard
library only; state is stored in SQLite. The bot uses the official HTTPS
Telegram Bot API for its own token and keeps administrator commands separate
from user commands. The local Bot API service is not required.

SQLite stores user bindings and the current navigation message. WAL mode,
busy-timeout and a process lock protect concurrent polling/Mini App requests.
Panel operations always use a bearer token over the panel HTTPS API. SSH is
used only to keep loopback tunnels to private panel HTTPS listeners; the bot
never executes shell commands on a VPN server and has no SSH fallback.

## Configuration

Copy `.env.example` to `/etc/gaullebot.env` (mode `0640`, group `gaullebot`);
the panel connector file is `/etc/gaullebot-panels.json` by default.
Never commit the real token or SSH keys.
For production, set `SSH_KNOWN_HOSTS` to the pinned host-key file; this makes
the tunnel use `StrictHostKeyChecking=yes` instead of accepting a new key.

## Commands

Admin: `/status`, `/health`, `/info`, `/readiness`, `/dns`, `/resolver`,
`/audit`, `/tokens`, `/servers`, `/clients [finland|germany]`,
`/logs [finland|germany]`, `/users`, `/bind <tg_id> <fin_token> <ger_token>`,
`/add`, `/remove`, `/regenerate`, `/restart <finland|germany>`.
User: `/me`, `/servers`, `/clients`, `/menu`, `/help`.

The bot uses the compact `/api/bot/snapshot` endpoint for status and client
views. Requests to both panels run concurrently and read-only snapshots are
cached for five seconds. `/start` opens the persistent bottom keyboard and an
inline main menu; tapping a button sends a callback (it does not create a
manual `/command` message). The callback is acknowledged immediately and
supports a separate administrator submenu for diagnostics. `/menu` remains a
text fallback. Configure `var/panels.json` with one bearer token per panel to
keep every operation on the authenticated panel API. The administrator uses
the panel token, while a regular user can only use the token explicitly bound
to that Telegram account.

The button-first interface provides a persistent bottom keyboard, one editable
navigation message, per-user device cards and inline actions for QR images,
`.conf` files, `vpn://` URIs and traffic statistics. Device callbacks use
short SQLite-backed references, so Telegram's 64-byte callback limit is never
exceeded even for long client names. Administrative screens also expose
health, logs, token audit, safe restart confirmation and the panel's verified
update check/apply API.
Diagnostics are rendered as Telegram cards (health metrics, services, DNS,
readiness, audit summaries, load history, latency and provider traffic, plus
redacted token counts); raw panel JSON is not sent to users.

Administrators can create a client from the inline menu: choose the target
server, enter the profile name in the prompted reply, and the bot calls
`POST /api/clients` with the dedicated API credential. No shell command is
constructed or executed.

Users without a binding can press “🔐 Запросить доступ”. The request is
rate-limited in SQLite and sent to the administrator with a button that opens
the exact `/bind <telegram_id> <finland_token> <germany_token>` instruction;
panel tokens themselves are never sent through the notification.

## Storage and stack decision

SQLite is the source of truth for bot users, panel-token bindings and
navigation state (WAL mode, busy timeout and process locking are enabled).
The VPN panel keeps its existing JSON files for secrets, configuration and
export/cache artifacts. Moving all of those files into one database would mix
unrelated lifecycles and requires a separate, reversible migration with
backups; it is not an automatic stack upgrade.

Every Mini App action validates signed Telegram `initData`, resolves the
Telegram ID from SQLite, enforces the admin/user scope, and sends either the
dedicated super API token or the user's bound panel token. Unbound users get
`access_pending`; they never receive a panel credential or a privileged
fallback.

The Mini App is a dependency-free Telegram Web App: it presents server cards,
online counts, per-client traffic, QR preview, config downloads and client
state/P2P/port controls. Artifact
requests go through the bot's signed `/api/artifact` gateway; panel URLs and
bearer tokens are never exposed to browser JavaScript.
