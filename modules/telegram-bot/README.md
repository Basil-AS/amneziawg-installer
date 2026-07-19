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

## Commands

Admin: `/status`, `/health`, `/info`, `/readiness`, `/dns`, `/resolver`,
`/audit`, `/tokens`, `/servers`, `/clients [finland|germany]`,
`/logs [finland|germany]`, `/users`, `/bind <tg_id> <fin_token> <ger_token>`,
`/add`, `/remove`, `/regenerate`, `/restart <finland|germany>`.
User: `/me`, `/servers`, `/menu`, `/help`.

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
