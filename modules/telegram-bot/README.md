# GaulleBot

Telegram administration bot for the two AmneziaWG servers. Python standard
library only; state is stored in SQLite. The bot uses the official HTTPS
Telegram Bot API for its own token and keeps administrator commands separate
from user commands. The local Bot API service is not required.

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
avoid the slower restricted-SSH compatibility fallback.
