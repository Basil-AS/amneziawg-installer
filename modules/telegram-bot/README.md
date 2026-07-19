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
An approved user can also press “➕ Добавить устройство”, choose Finland or
Germany and enter a profile name. The bot calls `POST /api/clients` with that
user's bound bearer token; the panel assigns the new client to the same token.
The super token is used only for the administrator account.
Large device lists are paginated at 12 cards per screen; opening a device keeps
the originating page for Back/Cancel actions and never puts a client name or
secret into callback data.
The “Настроить порт P2P” action asks for a numeric port and calls the panel's
RBAC-protected `POST /api/clients/<name>/p2p`; both bot-side and panel-side
validation reject values outside `1..65535`.
Each device card can issue a short-lived, one-time import link through the
panel API (`POST /api/clients/<name>/access-link`). The link is sent as a
Telegram URL button or opened by the Mini App; the bot does not persist or log
the secret URL. The panel invalidates it after expiry or first use.
Diagnostics are rendered as Telegram cards (health metrics, services, DNS,
readiness, audit summaries, load history, latency and provider traffic, plus
redacted token counts); raw panel JSON is not sent to users.
Two-panel summary screens fan out concurrently and preserve Finland/Germany
ordering, so a slow region does not add its latency to the other result.
Load history now includes compact Unicode CPU/RAM/load charts, and user traffic
cards include relative volume bars so trends are readable directly in Telegram.
The admin diagnostics menu also reads GeoIP provider/database status, nettest
reports, web access policy and certificate metadata through their authenticated
panel APIs; secret tokens and private key material are never rendered.
The separate “Обслуживание” screen exposes API-only DNS/NDP restarts, GeoIP
database refresh and TLS renewal; server reboot is hidden behind a server
choice and explicit confirmation.

Administrators can create a client from the inline menu: choose the target
server, enter the profile name in the prompted reply, and the bot calls
`POST /api/clients` with the dedicated API credential. No shell command is
constructed or executed.

Users without a binding can press “🔐 Запросить доступ”. The request is
rate-limited in SQLite and sent to the administrator with a button that opens
the access decision screen. The administrator can approve it with one button:
the bot then creates separate scoped panel tokens through `POST /api/tokens`,
stores them in SQLite and notifies the user without displaying either secret.
The request can also be rejected and becomes eligible for a later request.

Users can mark any device as `⭐ Избранное`. Favorites are stored per Telegram
account in SQLite, survive bot restarts and preserve their navigation context;
they never alter panel configuration or leak another user's device list.

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
fallback. The pending screen offers a signed `POST /api/access-request` action;
SQLite makes it idempotent and rate-limited, and the administrator receives the
same callback-based review flow as requests made in the bot chat.

The Mini App is a dependency-free Telegram Web App: it presents server cards,
online counts, per-client traffic, QR preview, config downloads and client
state/P2P/port controls. Artifact
requests go through the bot's signed `/api/artifact` gateway; panel URLs and
bearer tokens are never exposed to browser JavaScript.
For the administrator, each server card additionally exposes API-backed
health, load history, latency, update check and confirmed restart controls;
diagnostic results open as parsed cards rather than raw JSON.
The Mini App device action bar also supports setting a P2P port; it validates
the numeric range in the browser and sends the value through the signed API
session to the panel's RBAC endpoint.
It also downloads the `vpn://` URI through `/api/artifact`, alongside QR and
`.conf`; the panel URL and bearer token remain server-side.
