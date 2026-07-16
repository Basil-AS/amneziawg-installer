#!/usr/bin/env python3
"""GaulleBot Telegram control plane with explicit RBAC and SSH allowlists."""

from __future__ import annotations

import json
import base64
import logging
import os
import shlex
import sqlite3
import subprocess
import time
import ssl
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlencode
from urllib.request import Request, urlopen

LOG = logging.getLogger("gaullebot")


@dataclass(frozen=True)
class Settings:
    token: str
    admin_chat_id: int
    api_root: str
    db_path: Path
    poll_timeout: int
    panels_path: Path

    @classmethod
    def from_env(cls) -> "Settings":
        token = os.environ.get("BOT_TOKEN", "").strip()
        if not token or ":" not in token:
            raise RuntimeError("BOT_TOKEN is missing or malformed")
        return cls(
            token=token,
            admin_chat_id=int(os.environ.get("ADMIN_CHAT_ID", "0")),
            api_root=os.environ.get("TELEGRAM_API_ROOT", "https://api.telegram.org").rstrip("/"),
            db_path=Path(os.environ.get("DB_PATH", "data/gaullebot.sqlite3")),
            poll_timeout=max(1, min(int(os.environ.get("POLL_TIMEOUT", "30")), 50)),
            panels_path=Path(os.environ.get("PANELS_CONFIG", "var/panels.json")),
        )


class Store:
    def __init__(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path)
        self.db.row_factory = sqlite3.Row
        self.db.execute(
            """CREATE TABLE IF NOT EXISTS users (
                telegram_id INTEGER PRIMARY KEY,
                username TEXT,
                first_name TEXT,
                finland_token TEXT,
                germany_token TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            )"""
        )
        self.db.commit()

    def close(self) -> None:
        self.db.close()

    def bind(self, telegram_id: int, username: str, first_name: str, finland: str, germany: str) -> None:
        now = int(time.time())
        self.db.execute(
            """INSERT INTO users VALUES (?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(telegram_id) DO UPDATE SET username=excluded.username,
               first_name=excluded.first_name, finland_token=excluded.finland_token,
               germany_token=excluded.germany_token, updated_at=excluded.updated_at""",
            (telegram_id, username, first_name, finland, germany, now, now),
        )
        self.db.commit()

    def get(self, telegram_id: int) -> sqlite3.Row | None:
        return self.db.execute("SELECT * FROM users WHERE telegram_id=?", (telegram_id,)).fetchone()

    def all(self) -> list[sqlite3.Row]:
        return list(self.db.execute("SELECT * FROM users ORDER BY telegram_id"))


@dataclass(frozen=True)
class Server:
    key: str
    label: str
    host: str
    port: str
    user: str
    identity: str


class ServerManager:
    def __init__(self) -> None:
        self.servers = {
            "finland": Server("finland", "Sunny-Finland", os.getenv("FINLAND_SSH_HOST", ""), os.getenv("FINLAND_SSH_PORT", "22"), os.getenv("FINLAND_SSH_USER", "root"), os.getenv("FINLAND_SSH_IDENTITY", "")),
            "germany": Server("germany", "Sunny-German", os.getenv("GERMANY_SSH_HOST", ""), os.getenv("GERMANY_SSH_PORT", "22"), os.getenv("GERMANY_SSH_USER", "root"), os.getenv("GERMANY_SSH_IDENTITY", "")),
        }

    def run(self, key: str, action: str, value: str = "") -> str:
        server = self.servers.get(key)
        if server is None:
            return "unknown server"
        if not server.host or not server.identity:
            return f"{server.label}: SSH connector is not configured"
        commands = {
            "status": "version=$(cat /root/awg/VERSION); printf 'VERSION=%s\\n' \"$version\"; ip -brief addr show awg0; systemctl is-active awg-quick@awg0 awg-web AdGuardHome",
            "health": "/root/awg/update-installed.sh --check",
            "restart": "systemctl restart awg-quick@awg0 awg-web AdGuardHome",
            "clients": "for f in /root/awg/*.conf; do n=$(basename \"$f\" .conf); [ \"$n\" = awg0 ] && continue; a=$(awk -F'= *' '/^Address/{print $2; exit}' \"$f\"); printf '%s|%s\\n' \"$n\" \"$a\"; done",
            "logs": "tail -n 100 /root/awg/manage_amneziawg.log /root/awg/install_amneziawg.log 2>/dev/null",
        }
        if action in {"add", "remove", "regenerate"}:
            if not value or not value.replace("_", "").replace("-", "").isalnum() or len(value) > 48:
                return f"{server.label}: invalid client name"
            command = {"add": f"/root/awg/manage_amneziawg.sh client add --yes {shlex.quote(value)}", "remove": f"AWG_YES=1 /root/awg/manage_amneziawg.sh client remove --yes {shlex.quote(value)}", "regenerate": f"/root/awg/manage_amneziawg.sh client regenerate {shlex.quote(value)}"}[action]
        else:
            command = commands.get(action)
        if command is None:
            return "unsupported action"
        encoded = base64.b64encode(command.encode()).decode("ascii")
        remote = f"printf '%s' {encoded} | base64 -d | bash"
        argv = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=accept-new", "-i", server.identity, "-p", server.port, f"{server.user}@{server.host}", remote]
        try:
            completed = subprocess.run(argv, capture_output=True, text=True, timeout=30, check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            return f"{server.label}: connector error: {type(exc).__name__}"
        output = (completed.stdout + completed.stderr).strip()
        if completed.returncode:
            return f"{server.label}: command failed ({completed.returncode})\n{output[-1200:]}"
        limit = 3500 if action == "clients" else 1200
        return f"{server.label}\n{output[-limit:]}"


@dataclass(frozen=True)
class Panel:
    key: str
    label: str
    base_url: str
    token: str
    verify_tls: bool = True


class PanelManager:
    """Allowlisted connector for the project's bearer-authenticated panel API."""

    def __init__(self, path: Path) -> None:
        self.panels: dict[str, Panel] = {}
        if path.is_file():
            try:
                raw = json.loads(path.read_text(encoding="utf-8"))
                for item in raw if isinstance(raw, list) else raw.get("panels", []):
                    key = str(item["id"])
                    self.panels[key] = Panel(key, str(item.get("name", key)), str(item["url"]).rstrip("/"), str(item["token"]), bool(item.get("verify_tls", True)))
            except (OSError, ValueError, KeyError, TypeError) as exc:
                LOG.warning("panel config ignored: %s", exc)

    def run(self, key: str, action: str, token: str | None = None, value: str = "") -> str | None:
        panel = self.panels.get(key)
        if panel is None:
            return None
        endpoints = {"status": ("GET", "/api/status"), "health": ("GET", "/api/server-health"), "clients": ("GET", "/api/clients"), "logs": ("GET", "/api/server/logs"), "restart": ("POST", "/api/server/restart")}
        body = None
        if action == "add":
            endpoint_info = ("POST", "/api/clients")
            body = json.dumps({"name": value}).encode()
        elif action == "regenerate":
            endpoint_info = ("POST", f"/api/clients/{value}/regenerate")
            body = b"{}"
        elif action == "remove":
            endpoint_info = ("DELETE", f"/api/clients/{value}")
        else:
            endpoint_info = endpoints.get(action)
        if endpoint_info is None:
            return f"{panel.label}: unsupported API action"
        method, endpoint = endpoint_info
        headers = {"Authorization": f"Bearer {token or panel.token}", "Accept": "application/json"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        request = Request(panel.base_url + endpoint, headers=headers, data=body, method=method)
        context = None if panel.verify_tls else ssl._create_unverified_context()
        try:
            with urlopen(request, timeout=15, context=context) as response:
                payload = json.loads(response.read())
        except Exception as exc:
            return f"{panel.label}: API connector error: {type(exc).__name__}"
        if not isinstance(payload, dict):
            return f"{panel.label}: invalid API response"
        return f"{panel.label}\n{json.dumps(payload, ensure_ascii=False, indent=2)[:3500]}"

    def keys(self) -> list[str]:
        return list(self.panels)


def server_result(panel: PanelManager, ssh: ServerManager, key: str, action: str, token: str | None = None, value: str = "") -> str:
    """Prefer the panel API; retain SSH as an explicit compatibility fallback."""
    result = panel.run(key, action, token, value)
    return result if result is not None else ssh.run(key, action, value)


class Telegram:
    def __init__(self, settings: Settings) -> None:
        self.base = f"{settings.api_root}/bot{settings.token}"
        self.poll_timeout = settings.poll_timeout

    def call(self, method: str, **params: Any) -> dict[str, Any]:
        body = urlencode({k: str(v) for k, v in params.items()}).encode()
        request = Request(f"{self.base}/{method}", data=body, method="POST")
        with urlopen(request, timeout=self.poll_timeout + 10) as response:
            payload = json.loads(response.read())
        if not payload.get("ok"):
            raise RuntimeError(f"Telegram {method} failed: {payload}")
        return payload["result"]

    def send(self, chat_id: int, text: str) -> None:
        self.call("sendMessage", chat_id=chat_id, text=text[:4096])


def help_text(admin: bool) -> str:
    text = "Команды пользователя:\n/me — моя привязка\n/servers — состояние серверов\n/help — помощь"
    if admin:
        text += "\n\nАдминистратор:\n/status — оба сервера\n/health — проверки\n/clients — список клиентов\n/logs — последние логи\n/users — привязки\n/bind <tg_id> <fin_token> <ger_token>\n/add <server> <name>\n/remove <server> <name>\n/regenerate <server> <name>\n/restart <finland|germany>"
    return text


def main() -> None:
    logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(message)s")
    settings = Settings.from_env()
    store = Store(settings.db_path)
    telegram = Telegram(settings)
    manager = ServerManager()
    panels = PanelManager(settings.panels_path)
    offset = 0
    LOG.info("GaulleBot started")
    while True:
        try:
            updates = telegram.call("getUpdates", offset=offset, timeout=settings.poll_timeout, allowed_updates=json.dumps(["message"]))
            for update in updates:
                offset = max(offset, int(update["update_id"]) + 1)
                message = update.get("message") or {}
                chat = message.get("chat") or {}
                sender = message.get("from") or {}
                chat_id = int(chat.get("id", 0))
                command = (message.get("text") or "").strip()
                if not command.startswith("/"):
                    continue
                parts = command.split()
                name = parts[0].split("@", 1)[0].lower()
                is_admin = chat_id == settings.admin_chat_id
                try:
                    if name in {"/start", "/help"}:
                        telegram.send(chat_id, help_text(is_admin))
                    elif name == "/me":
                        row = store.get(chat_id)
                        telegram.send(chat_id, "Привязка отсутствует." if row is None else f"Telegram ID: {chat_id}\nFinland: {'есть' if row['finland_token'] else 'нет'}\nGermany: {'есть' if row['germany_token'] else 'нет'}")
                    elif name == "/servers":
                        row = store.get(chat_id)
                        tokens = {"finland": row["finland_token"] if row else None, "germany": row["germany_token"] if row else None}
                        telegram.send(chat_id, "\n\n".join(server_result(panels, manager, key, "status", tokens[key]) for key in ("finland", "germany")))
                    elif not is_admin:
                        telegram.send(chat_id, "Недостаточно прав. Обратитесь к администратору.")
                    elif name in {"/status", "/health"}:
                        action = "status" if name == "/status" else "health"
                        telegram.send(chat_id, "\n\n".join(server_result(panels, manager, key, action) for key in ("finland", "germany")))
                    elif name == "/restart" and len(parts) == 2:
                        telegram.send(chat_id, server_result(panels, manager, parts[1].lower(), "restart"))
                    elif name in {"/add", "/remove", "/regenerate"} and len(parts) == 3:
                        action = name[1:]
                        telegram.send(chat_id, server_result(panels, manager, parts[1].lower(), action, value=parts[2]))
                    elif name == "/bind" and len(parts) == 4:
                        store.bind(int(parts[1]), str(sender.get("username", "")), str(sender.get("first_name", "")), parts[2], parts[3])
                        telegram.send(chat_id, "Привязка сохранена.")
                    elif name == "/users":
                        rows = store.all()
                        telegram.send(chat_id, "\n".join(f"{r['telegram_id']} @{r['username'] or '-'} fin={'yes' if r['finland_token'] else 'no'} ger={'yes' if r['germany_token'] else 'no'}" for r in rows) or "Пользователей пока нет.")
                    elif name == "/clients":
                        telegram.send(chat_id, "\n\n".join(server_result(panels, manager, key, "clients") for key in ("finland", "germany")))
                    elif name == "/logs":
                        telegram.send(chat_id, "\n\n".join(server_result(panels, manager, key, "logs") for key in ("finland", "germany")))
                    else:
                        telegram.send(chat_id, help_text(True))
                except (ValueError, RuntimeError) as exc:
                    LOG.warning("command failed: %s", exc)
                    telegram.send(chat_id, "Команда не выполнена: проверьте формат и настройки.")
        except Exception:
            LOG.exception("polling iteration failed")
            time.sleep(3)


if __name__ == "__main__":
    main()
