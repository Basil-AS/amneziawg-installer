# Telegram bot and panel API

The Telegram bot is an optional microservice. It is a separate systemd
process and does not replace or embed the web panel. It can run on the VPN
host or on another host and can connect to any number of project panels.

## Panel connector

Panels are configured in a root-readable, bot-group-readable JSON file named
by `PANELS_CONFIG` (default `var/panels.json`). Each entry contains `id`,
`name`, `url`, `token`, and optional `verify_tls`. The connector uses the
existing bearer-authenticated project endpoints; no new public API is needed:

| Bot operation | Panel endpoint | Required scope |
| --- | --- | --- |
| status | `GET /api/status` | user or super |
| health | `GET /api/server-health` | super |
| clients | `GET /api/clients` | user or super |
| restart | `POST /api/server/restart` | super |

The file and SQLite database must be mode `0600`/`0640` and must never be
committed. TLS verification should remain enabled; disabling it is only for
private VPN addresses with a deliberately self-signed certificate.

User bindings map one Telegram ID to one Finland bearer token and one Germany
bearer token. The bot uses those tokens only for read operations. Admin
operations use the panel tokens from the protected panel configuration.

If a panel is not present in `PANELS_CONFIG`, the bot uses its restricted SSH
connector as a compatibility fallback. SSH commands are fixed allowlisted
actions; arbitrary shell execution is not exposed through Telegram.
