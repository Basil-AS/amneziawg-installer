#!/usr/bin/env python3
"""GaulleBot Telegram control plane with explicit RBAC and SSH allowlists."""

from __future__ import annotations

import json
import base64
import atexit
import html
import logging
import os
import shlex
import sqlite3
import subprocess
import threading
import time
import ssl
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlencode
from urllib.error import HTTPError
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

    def touch(self, telegram_id: int, username: str, first_name: str) -> None:
        row = self.get(telegram_id)
        if row and row["username"] == username and row["first_name"] == first_name:
            return
        self.bind(telegram_id, username, first_name, row["finland_token"] if row else "", row["germany_token"] if row else "")

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
    web_port: str


class ServerManager:
    def __init__(self) -> None:
        self.servers = {
            "finland": Server("finland", "Sunny-Finland", os.getenv("FINLAND_SSH_HOST", ""), os.getenv("FINLAND_SSH_PORT", "22"), os.getenv("FINLAND_SSH_USER", "root"), os.getenv("FINLAND_SSH_IDENTITY", ""), os.getenv("FINLAND_WEB_PORT", "8443")),
            "germany": Server("germany", "Sunny-German", os.getenv("GERMANY_SSH_HOST", ""), os.getenv("GERMANY_SSH_PORT", "22"), os.getenv("GERMANY_SSH_USER", "root"), os.getenv("GERMANY_SSH_IDENTITY", ""), os.getenv("GERMANY_WEB_PORT", "443")),
        }

    def tunnel_argv(self, key: str, local_port: int) -> list[str] | None:
        server = self.servers.get(key)
        if server is None or not server.host or not server.identity:
            return None
        return [
            "ssh", "-N", "-T", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new", "-i", server.identity,
            "-L", f"127.0.0.1:{local_port}:127.0.0.1:{server.web_port}", "-p", server.port,
            f"{server.user}@{server.host}",
        ]

    def run(self, key: str, action: str, value: str = "") -> str:
        server = self.servers.get(key)
        if server is None:
            return "unknown server"
        if not server.host or not server.identity:
            return f"{server.label}: SSH connector is not configured"
        commands = {
            "status": "version=$(cat /root/awg/VERSION); printf 'VERSION=%s\\n' \"$version\"; ip -brief addr show awg0; systemctl is-active awg-quick@awg0 awg-web AdGuardHome",
            "health": "/root/awg/update-installed.sh --check",
            "info": "version=$(cat /root/awg/VERSION); printf 'VERSION=%s\\n' \"$version\"; ip -brief addr show awg0; uname -srmo",
            "readiness": "/root/awg/update-installed.sh --check; systemctl is-active awg-quick@awg0 awg-web AdGuardHome",
            "dns": "systemctl is-active AdGuardHome; resolvectl status 2>/dev/null | head -n 24",
            "resolver": "systemctl is-active AdGuardHome; ss -lunp | grep -E ':(53|5353)\\b' || true",
            "audit": "printf 'CONFIGS='; find /root/awg -maxdepth 1 -type f -name '*.conf' ! -name awg0.conf | wc -l; systemctl is-active awg-quick@awg0 awg-web AdGuardHome",
            "tokens": "printf 'PANEL_TOKEN_STORE='; stat -c '%a %s bytes' /root/awg/web/tokens.json 2>/dev/null || true; grep -c '^[[:space:]]*\"[0-9a-f]\\{64\\}\"' /root/awg/web/tokens.json 2>/dev/null || true",
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
        self._cache: dict[tuple[str, str, str], tuple[float, dict[str, Any]]] = {}
        self._cache_lock = threading.Lock()
        if path.is_file():
            try:
                raw = json.loads(path.read_text(encoding="utf-8"))
                for item in raw if isinstance(raw, list) else raw.get("panels", []):
                    key = str(item["id"])
                    self.panels[key] = Panel(key, str(item.get("name", key)), str(item["url"]).rstrip("/"), str(item["token"]), bool(item.get("verify_tls", True)))
            except (OSError, ValueError, KeyError, TypeError) as exc:
                LOG.warning("panel config ignored: %s", exc)

    def request(self, key: str, action: str, token: str | None = None, value: str = "") -> dict[str, Any] | None:
        panel = self.panels.get(key)
        if panel is None:
            return None
        cache_key = (key, action, token or panel.token)
        if action in {"status", "snapshot", "clients"}:
            with self._cache_lock:
                cached = self._cache.get(cache_key)
                if cached and time.monotonic() - cached[0] < 5:
                    return dict(cached[1])
        endpoints = {
            "status": ("GET", "/api/status"), "snapshot": ("GET", "/api/bot/snapshot"),
            "health": ("GET", "/api/server-health"), "info": ("GET", "/api/server-info"),
            "readiness": ("GET", "/api/vpn-readiness"), "dns": ("GET", "/api/dns"),
            "resolver": ("GET", "/api/resolver"), "audit": ("GET", "/api/clients/audit"),
            "tokens": ("GET", "/api/tokens"), "clients": ("GET", "/api/clients"),
            "logs": ("GET", "/api/server/logs"), "restart": ("POST", "/api/server/restart"),
        }
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
            return {"error": "unsupported API action", "panel": panel.label}
        method, endpoint = endpoint_info
        headers = {"Authorization": f"Bearer {token or panel.token}", "Accept": "application/json"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        request = Request(panel.base_url + endpoint, headers=headers, data=body, method=method)
        context = None if panel.verify_tls else ssl._create_unverified_context()
        try:
            with urlopen(request, timeout=15, context=context) as response:
                payload = json.loads(response.read())
        except HTTPError as exc:
            if exc.code in {401, 403}:
                LOG.info("panel action requires elevated scope; using SSH fallback panel=%s action=%s", key, action)
                return None
            LOG.warning("panel request failed panel=%s action=%s status=%s", key, action, exc.code)
            return {"error": f"API HTTP {exc.code}", "panel": panel.label}
        except Exception as exc:
            LOG.warning("panel request failed panel=%s action=%s error=%s", key, action, type(exc).__name__)
            return {"error": f"API connector error: {type(exc).__name__}", "panel": panel.label}
        if not isinstance(payload, dict):
            return {"error": "invalid API response", "panel": panel.label}
        payload.setdefault("panel", panel.label)
        if action in {"status", "snapshot", "clients"}:
            with self._cache_lock:
                self._cache[cache_key] = (time.monotonic(), dict(payload))
        return payload

    def run(self, key: str, action: str, token: str | None = None, value: str = "") -> str | None:
        payload = self.request(key, action, token, value)
        if payload is None:
            return None
        return f"{payload.get('panel', key)}\n{json.dumps(payload, ensure_ascii=False, indent=2)[:3500]}"

    def keys(self) -> list[str]:
        return list(self.panels)


def server_result(panel: PanelManager, ssh: ServerManager, key: str, action: str, token: str | None = None, value: str = "") -> str:
    """Prefer the panel API; retain SSH as an explicit compatibility fallback."""
    result = panel.run(key, action, token, value)
    return result if result is not None else ssh.run(key, action, value)


def parallel_results(panel: PanelManager, ssh: ServerManager, keys: tuple[str, ...], action: str, tokens: dict[str, str | None] | None = None) -> list[str]:
    """Query panels concurrently; one slow region must not block the other."""
    tokens = tokens or {}

    def fetch(key: str) -> str:
        return server_result(panel, ssh, key, action, tokens.get(key))

    with ThreadPoolExecutor(max_workers=len(keys)) as pool:
        futures = [pool.submit(fetch, key) for key in keys]
        return [future.result() for future in futures]


class TunnelManager:
    """Keep panel API forwards alive inside the bot process.

    The central host cannot route the VPN-only panel addresses directly.  A
    child SSH process is deliberately started by the already confined bot
    service (rather than a separate systemd unit, which is denied by Fedora's
    SELinux policy) and is restarted if it exits.
    """

    def __init__(self, manager: ServerManager, enabled: bool = True) -> None:
        self.manager = manager
        self.enabled = enabled
        self.processes: dict[str, tuple[list[str], int, subprocess.Popen | None]] = {}
        if enabled:
            self.processes = {
                "finland": (manager.tunnel_argv("finland", 18443) or [], 18443, None),
                "germany": (manager.tunnel_argv("germany", 18444) or [], 18444, None),
            }
            self.ensure()
            atexit.register(self.close)

    def ensure(self) -> None:
        if not self.enabled:
            return
        for key, (argv, port, process) in list(self.processes.items()):
            if not argv or (process is not None and process.poll() is None):
                continue
            try:
                child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True)
                self.processes[key] = (argv, port, child)
                LOG.info("panel API tunnel started panel=%s local_port=%s", key, port)
            except OSError as exc:
                LOG.warning("panel API tunnel failed panel=%s error=%s", key, type(exc).__name__)

    def close(self) -> None:
        for key, (argv, _port, process) in self.processes.items():
            if process is not None and process.poll() is None:
                process.terminate()
                LOG.info("panel API tunnel stopped panel=%s", key)


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

    def send(self, chat_id: int, text: str, *, keyboard: list[list[dict[str, str]]] | None = None) -> None:
        params: dict[str, Any] = {"chat_id": chat_id, "text": text[:4096], "parse_mode": "HTML"}
        if keyboard:
            params["reply_markup"] = json.dumps({"inline_keyboard": keyboard}, ensure_ascii=False)
        try:
            self.call("sendMessage", **params)
        except RuntimeError as exc:
            # Logs and command output can contain arbitrary characters. Fall
            # back to plain text if Telegram rejects malformed HTML markup.
            if "parse entities" not in str(exc).lower() and "can't parse" not in str(exc).lower():
                raise
            params.pop("parse_mode", None)
            self.call("sendMessage", **params)

    def answer_callback(self, callback_id: str, text: str = "") -> None:
        self.call("answerCallbackQuery", callback_query_id=callback_id, text=text[:200])


def help_text(admin: bool) -> str:
    text = "<b>GaulleBot</b>\n/me — моя привязка\n/servers — состояние серверов\n/menu — быстрые действия\n/help — помощь"
    if admin:
        text += "\n\n<b>Администратор</b>:\n/status — быстрый сводный статус\n/health — глубокая проверка\n/info — сведения о сервере\n/readiness — готовность VPN\n/dns — DNS/AdGuard\n/resolver — состояние resolver\n/audit — аудит клиентов\n/tokens — токены панели\n/clients [server] — клиенты\n/logs [server] — последние логи\n/users — привязки\n/bind &lt;tg_id&gt; &lt;fin_token&gt; &lt;ger_token&gt;\n/add &lt;server&gt; &lt;name&gt;\n/remove &lt;server&gt; &lt;name&gt;\n/regenerate &lt;server&gt; &lt;name&gt;\n/restart &lt;finland|germany&gt;"
    return text


def menu_keyboard(admin: bool) -> list[list[dict[str, str]]]:
    rows = [[{"text": "📊 Серверы", "callback_data": "servers"}], [{"text": "👤 Моя привязка", "callback_data": "me"}]]
    if admin:
        rows = [[{"text": "📊 Статус", "callback_data": "status"}, {"text": "🩺 Health", "callback_data": "health"}], [{"text": "✅ Readiness", "callback_data": "readiness"}, {"text": "🌐 DNS", "callback_data": "dns"}], [{"text": "👥 Клиенты", "callback_data": "clients"}, {"text": "👤 Пользователи", "callback_data": "users"}]] + rows
    return rows


def compact_snapshot(payload: dict[str, Any]) -> str:
    if payload.get("error"):
        return f"<b>{html.escape(str(payload.get('panel', 'panel')))}</b>: {html.escape(str(payload['error']))}"
    summary = payload.get("summary") or {}
    service = html.escape(str(payload.get("service", "unknown")))
    return (f"<b>{html.escape(str(payload.get('display_name') or payload.get('panel', 'server')))}</b> "
            f"<code>{html.escape(str(payload.get('version', '?')))}</code>\n"
            f"Сервис: <b>{service}</b> · онлайн: <b>{summary.get('online', 0)}/{summary.get('total', 0)}</b>")


def compact_clients(payload: dict[str, Any]) -> str:
    if payload.get("error"):
        return compact_snapshot(payload)
    lines = [f"<b>{html.escape(str(payload.get('display_name') or payload.get('panel', 'server')))}</b>"]
    for item in payload.get("clients", []):
        marker = "🟢" if item.get("online") else "⚪"
        ports = ", ".join(str(port) for port in item.get("p2p_ports") or [])
        suffix = f" · ports: {html.escape(ports)}" if ports else ""
        lines.append(f"{marker} <code>{html.escape(str(item.get('name', '')))}</code> · {html.escape(str(item.get('ipv4', '')))}{suffix}")
    return "\n".join(lines)[:4096]


def main() -> None:
    logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(message)s")
    settings = Settings.from_env()
    store = Store(settings.db_path)
    telegram = Telegram(settings)
    manager = ServerManager()
    tunnels = TunnelManager(manager, enabled=os.getenv("PANEL_TUNNELS_ENABLED", "1").lower() not in {"0", "false", "no"})
    panels = PanelManager(settings.panels_path)
    offset = 0
    LOG.info("GaulleBot started")
    while True:
        try:
            tunnels.ensure()
            updates = telegram.call("getUpdates", offset=offset, timeout=settings.poll_timeout, allowed_updates=json.dumps(["message", "callback_query"]))
            for update in updates:
                offset = max(offset, int(update["update_id"]) + 1)
                callback = update.get("callback_query") or {}
                message = update.get("message") or callback.get("message") or {}
                chat = message.get("chat") or {}
                sender = (message.get("from") or callback.get("from") or {})
                chat_id = int(chat.get("id", 0))
                if chat_id:
                    store.touch(chat_id, str(sender.get("username", "")), str(sender.get("first_name", "")))
                command = (message.get("text") or callback.get("data") or "").strip()
                if callback:
                    telegram.answer_callback(str(callback.get("id", "")))
                    command = "/" + command
                if not command.startswith("/"):
                    continue
                parts = command.split()
                name = parts[0].split("@", 1)[0].lower()
                is_admin = chat_id == settings.admin_chat_id
                try:
                    def snapshot_text(key: str, token: str | None = None, clients: bool = False) -> str:
                        payload = panels.request(key, "snapshot", token)
                        if payload is not None:
                            return compact_clients(payload) if clients else compact_snapshot(payload)
                        return server_result(panels, manager, key, "status", token)

                    if name in {"/start", "/help"}:
                        telegram.send(chat_id, help_text(is_admin), keyboard=menu_keyboard(is_admin) if name == "/start" else None)
                    elif name == "/menu":
                        telegram.send(chat_id, "Выберите действие:", keyboard=menu_keyboard(is_admin))
                    elif name == "/me":
                        row = store.get(chat_id)
                        telegram.send(chat_id, "Привязка отсутствует." if row is None else f"<b>Ваш профиль</b>\nTelegram ID: <code>{chat_id}</code>\nFinland: {'✅' if row['finland_token'] else '—'}\nGermany: {'✅' if row['germany_token'] else '—'}")
                    elif name == "/servers":
                        row = store.get(chat_id)
                        tokens = {"finland": row["finland_token"] if row else None, "germany": row["germany_token"] if row else None}
                        telegram.send(chat_id, "\n\n".join(snapshot_text(key, tokens[key]) for key in ("finland", "germany")))
                    elif not is_admin:
                        telegram.send(chat_id, "Недостаточно прав. Обратитесь к администратору.")
                    elif name in {"/status", "/health"}:
                        if name == "/status":
                            telegram.send(chat_id, "\n\n".join(snapshot_text(key) for key in ("finland", "germany")))
                        else:
                            telegram.send(chat_id, "\n\n".join(parallel_results(panels, manager, ("finland", "germany"), "health")))
                    elif name in {"/info", "/readiness", "/dns", "/resolver", "/audit", "/tokens"}:
                        action = name[1:]
                        raw = "\n\n".join(parallel_results(panels, manager, ("finland", "germany"), action))
                        telegram.send(chat_id, html.escape(raw)[:4096])
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
                        telegram.send(chat_id, "\n".join(f"<code>{r['telegram_id']}</code> @{html.escape(r['username'] or '-')} fin={'✅' if r['finland_token'] else '—'} ger={'✅' if r['germany_token'] else '—'}" for r in rows) or "Пользователей пока нет.")
                    elif name == "/clients":
                        keys = (parts[1].lower(),) if len(parts) == 2 and parts[1].lower() in {"finland", "germany"} else ("finland", "germany")
                        telegram.send(chat_id, "\n\n".join(snapshot_text(key, clients=True) for key in keys))
                    elif name == "/logs":
                        keys = (parts[1].lower(),) if len(parts) == 2 and parts[1].lower() in {"finland", "germany"} else ("finland", "germany")
                        telegram.send(chat_id, "\n\n".join(parallel_results(panels, manager, keys, "logs")))
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
