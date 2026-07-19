# Telegram bot and panel API

The Telegram bot is an optional microservice. It is a separate systemd
process and does not replace or embed the web panel. It can run on the VPN
host or on another host and can connect to any number of project panels.

## Panel connector

Panels are configured in a root-readable, bot-group-readable JSON file named
by `PANELS_CONFIG` (default `/etc/gaullebot-panels.json`). Each entry contains `id`,
`name`, `url`, `token`, and optional `verify_tls`. The connector uses the
existing bearer-authenticated project endpoints; no new public API is needed:

| Bot operation | Panel endpoint | Required scope |
| --- | --- | --- |
| status | `GET /api/status` | user or super |
| snapshot | `GET /api/bot/snapshot` | user or super |
| health | `GET /api/server-health` | super |
| clients | `GET /api/clients` | user or super |
| restart | `POST /api/server/restart` | super |

The file and SQLite database must be mode `0600`/`0640` and must never be
committed. TLS verification should remain enabled; disabling it is only for
private VPN addresses with a deliberately self-signed certificate.

`/api/bot/snapshot` is the low-latency control-plane endpoint. It returns the
version, service state, compact peer list and online/total counters in one
request. It deliberately omits browser-only geo-IP, traffic-history and
latency enrichment. The bot caches snapshots for five seconds and queries
multiple panels concurrently; this keeps Telegram responses independent of
the slower SSH compatibility path.

User bindings map one Telegram ID to one Finland bearer token and one Germany
bearer token. The Mini App/API gateway exposes the same allowlisted operations
over HTTP: users receive read-only actions, while the configured admin receives
mutation actions (`add`, `remove`, `regenerate`, `restart`). For production,
set `AWG_BOT_API_TOKEN_HASH` (SHA-256 of a dedicated random token) in each
panel service and put the corresponding plaintext token only in protected
`PANELS_CONFIG`; this removes SSH from the normal bot path.

The central-host installer uses two loopback forwards (`127.0.0.1:18443` and
`:18444`) to reach VPN-only panel listeners. They are child processes of the
confined bot service and are automatically restarted. If a panel is not
present in `PANELS_CONFIG`, the bot uses its restricted SSH connector as a
compatibility fallback. Mini App/API requests never execute SSH; SSH is only
available to legacy command handlers when the panel API is unavailable.

The bot registers scoped commands with `setMyCommands` and configures the
chat-menu button with `setChatMenuButton`. Set `MINI_APP_URL` to an HTTPS URL
to turn the menu button into `MenuButtonWebApp`; when it is empty Telegram's
native command menu remains active. `/start` also installs a compact persistent
`ReplyKeyboardMarkup`, while operational navigation uses callback-based inline
buttons and always acknowledges callbacks with `answerCallbackQuery`.

The implementation targets the current Bot API 10.2 surface (July 2026). A
Mini App must validate `Telegram.WebApp.initData` server-side; `initDataUnsafe`
is never accepted as authentication.

## Webhook and Mini App deployment

The service serves the Mini App on `127.0.0.1:8789` and receives webhooks on
`127.0.0.1:8788`. Publish both through an HTTPS reverse proxy:

```text
https://bot.example/mini-app          -> http://127.0.0.1:8789/mini-app
https://bot.example/telegram/webhook  -> http://127.0.0.1:8788/telegram/webhook
```

Set `MINI_APP_URL=https://bot.example/mini-app`, `WEBHOOK_URL=https://bot.example`
and a random `WEBHOOK_SECRET`. Without `WEBHOOK_URL`, the bot safely falls back
to long polling. References: [Bot API](https://core.telegram.org/bots/api) and
[Mini Apps](https://core.telegram.org/bots/webapps).
