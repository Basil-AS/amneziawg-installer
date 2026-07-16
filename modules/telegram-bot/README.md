# GaulleBot

Telegram administration bot for the two AmneziaWG servers. Python standard
library only; state is stored in SQLite. The bot uses the official HTTPS
Telegram Bot API for its own token and keeps administrator commands separate
from user commands. The local Bot API service is not required.

## Configuration

Copy `.env.example` to `/etc/gaullebot.env` (mode `0640`, group `gaullebot`).
Never commit the real token or SSH keys.

## Commands

Admin: `/status`, `/servers`, `/clients`, `/users`, `/bind <tg_id> <fin_token> <ger_token>`, `/restart <finland|germany>`.
User: `/me`, `/servers`, `/help`.
