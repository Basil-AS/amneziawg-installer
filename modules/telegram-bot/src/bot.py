#!/usr/bin/env python3
"""GaulleBot Telegram control plane with explicit RBAC and SSH allowlists."""

from __future__ import annotations

import json
import atexit
import hmac
import html
import logging
import os
import queue
import sqlite3
import subprocess
import threading
import time
import ssl
import hashlib
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import parse_qsl, parse_qs, urlencode, quote, urlparse
from urllib.error import HTTPError
from urllib.request import Request, urlopen

LOG = logging.getLogger("gaullebot")
PANEL_TOKEN = object()


@dataclass(frozen=True)
class Settings:
    token: str
    admin_chat_id: int
    api_root: str
    db_path: Path
    poll_timeout: int
    panels_path: Path
    mini_app_url: str
    webhook_url: str
    webhook_secret: str
    webhook_bind: str
    webhook_port: int
    mini_app_bind: str
    mini_app_port: int

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
            mini_app_url=os.environ.get("MINI_APP_URL", "").strip(),
            webhook_url=os.environ.get("WEBHOOK_URL", "").strip().rstrip("/"),
            webhook_secret=os.environ.get("WEBHOOK_SECRET", "").strip(),
            webhook_bind=os.environ.get("WEBHOOK_BIND", "127.0.0.1"),
            webhook_port=max(1, min(int(os.environ.get("WEBHOOK_PORT", "8788")), 65535)),
            mini_app_bind=os.environ.get("MINI_APP_BIND", "127.0.0.1"),
            mini_app_port=max(1, min(int(os.environ.get("MINI_APP_PORT", "8789")), 65535)),
        )


class Store:
    def __init__(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.db = sqlite3.connect(path, check_same_thread=False, timeout=10)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA busy_timeout=10000")
        self.db.execute("PRAGMA foreign_keys=ON")
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
        self.db.execute(
            """CREATE TABLE IF NOT EXISTS navigation (
                telegram_id INTEGER PRIMARY KEY,
                message_id INTEGER NOT NULL,
                screen TEXT NOT NULL,
                updated_at INTEGER NOT NULL
            )"""
        )
        self.db.execute(
            """CREATE TABLE IF NOT EXISTS client_refs (
                telegram_id INTEGER NOT NULL,
                ref TEXT NOT NULL,
                server TEXT NOT NULL,
                client_name TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (telegram_id, ref)
            )"""
        )
        self.db.execute(
            """CREATE TABLE IF NOT EXISTS access_requests (
                telegram_id INTEGER PRIMARY KEY,
                requested_at INTEGER NOT NULL,
                status TEXT NOT NULL DEFAULT 'pending'
            )"""
        )
        self.db.execute(
            """CREATE TABLE IF NOT EXISTS input_prompts (
                telegram_id INTEGER PRIMARY KEY,
                action TEXT NOT NULL,
                server TEXT NOT NULL,
                updated_at INTEGER NOT NULL
            )"""
        )
        self.db.execute(
            """CREATE TABLE IF NOT EXISTS favorites (
                telegram_id INTEGER NOT NULL,
                server TEXT NOT NULL,
                client_name TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                PRIMARY KEY (telegram_id, server, client_name)
            )"""
        )
        self.db.commit()

    def close(self) -> None:
        with self.lock:
            self.db.close()

    def bind(self, telegram_id: int, username: str, first_name: str, finland: str, germany: str) -> None:
        with self.lock:
            now = int(time.time())
            self.db.execute(
                """INSERT INTO users VALUES (?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(telegram_id) DO UPDATE SET username=excluded.username,
                   first_name=excluded.first_name, finland_token=excluded.finland_token,
                   germany_token=excluded.germany_token, updated_at=excluded.updated_at""",
                (telegram_id, username, first_name, finland, germany, now, now),
            )
            self.db.execute("UPDATE access_requests SET status='approved' WHERE telegram_id=?", (telegram_id,))
            self.db.commit()

    def touch(self, telegram_id: int, username: str, first_name: str) -> None:
        row = self.get(telegram_id)
        if row and row["username"] == username and row["first_name"] == first_name:
            return
        self.bind(telegram_id, username, first_name, row["finland_token"] if row else "", row["germany_token"] if row else "")

    def get(self, telegram_id: int) -> sqlite3.Row | None:
        with self.lock:
            return self.db.execute("SELECT * FROM users WHERE telegram_id=?", (telegram_id,)).fetchone()

    def all(self) -> list[sqlite3.Row]:
        with self.lock:
            return list(self.db.execute("SELECT * FROM users ORDER BY telegram_id"))

    def request_access(self, telegram_id: int, cooldown: int = 900) -> bool:
        now = int(time.time())
        with self.lock:
            row = self.db.execute("SELECT requested_at, status FROM access_requests WHERE telegram_id=?", (telegram_id,)).fetchone()
            if row and row["status"] == "pending" and now - int(row["requested_at"]) < cooldown:
                return False
            self.db.execute("INSERT INTO access_requests VALUES (?, ?, 'pending') ON CONFLICT(telegram_id) DO UPDATE SET requested_at=excluded.requested_at, status='pending'", (telegram_id, now))
            self.db.commit()
            return True

    def resolve_access_request(self, telegram_id: int, status: str) -> None:
        if status not in {"approved", "rejected"}:
            raise ValueError("invalid access decision")
        with self.lock:
            self.db.execute("UPDATE access_requests SET status=? WHERE telegram_id=?", (status, telegram_id))
            self.db.commit()

    def set_prompt(self, telegram_id: int, action: str, server: str) -> None:
        with self.lock:
            self.db.execute("INSERT OR REPLACE INTO input_prompts VALUES (?, ?, ?, ?)", (telegram_id, action, server, int(time.time())))
            self.db.commit()

    def prompt(self, telegram_id: int) -> sqlite3.Row | None:
        with self.lock:
            return self.db.execute("SELECT * FROM input_prompts WHERE telegram_id=?", (telegram_id,)).fetchone()

    def clear_prompt(self, telegram_id: int) -> None:
        with self.lock:
            self.db.execute("DELETE FROM input_prompts WHERE telegram_id=?", (telegram_id,))
            self.db.commit()

    def navigation(self, telegram_id: int) -> sqlite3.Row | None:
        with self.lock:
            return self.db.execute("SELECT * FROM navigation WHERE telegram_id=?", (telegram_id,)).fetchone()

    def set_navigation(self, telegram_id: int, message_id: int, screen: str) -> None:
        with self.lock:
            self.db.execute(
                """INSERT INTO navigation VALUES (?, ?, ?, ?)
                   ON CONFLICT(telegram_id) DO UPDATE SET message_id=excluded.message_id,
                   screen=excluded.screen, updated_at=excluded.updated_at""",
                (telegram_id, message_id, screen, int(time.time())),
            )
            self.db.commit()

    def clear_navigation(self, telegram_id: int) -> None:
        with self.lock:
            self.db.execute("DELETE FROM navigation WHERE telegram_id=?", (telegram_id,))
            self.db.commit()

    def client_ref(self, telegram_id: int, server: str, client_name: str) -> str:
        ref = hashlib.sha256(f"{telegram_id}:{server}:{client_name}".encode()).hexdigest()[:10]
        with self.lock:
            self.db.execute("INSERT OR REPLACE INTO client_refs VALUES (?, ?, ?, ?, ?)", (telegram_id, ref, server, client_name, int(time.time())))
            self.db.commit()
        return ref

    def resolve_client_ref(self, telegram_id: int, ref: str) -> tuple[str, str] | None:
        with self.lock:
            row = self.db.execute("SELECT server, client_name FROM client_refs WHERE telegram_id=? AND ref=?", (telegram_id, ref)).fetchone()
        return (str(row["server"]), str(row["client_name"])) if row else None

    def set_favorite(self, telegram_id: int, server: str, client_name: str, enabled: bool = True) -> None:
        with self.lock:
            if enabled:
                self.db.execute("INSERT OR IGNORE INTO favorites VALUES (?, ?, ?, ?)", (telegram_id, server, client_name, int(time.time())))
            else:
                self.db.execute("DELETE FROM favorites WHERE telegram_id=? AND server=? AND client_name=?", (telegram_id, server, client_name))
            self.db.commit()

    def is_favorite(self, telegram_id: int, server: str, client_name: str) -> bool:
        with self.lock:
            return self.db.execute("SELECT 1 FROM favorites WHERE telegram_id=? AND server=? AND client_name=?", (telegram_id, server, client_name)).fetchone() is not None

    def favorites(self, telegram_id: int) -> list[sqlite3.Row]:
        with self.lock:
            return list(self.db.execute("SELECT server, client_name FROM favorites WHERE telegram_id=? ORDER BY created_at DESC", (telegram_id,)))


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
        self.known_hosts = os.getenv("SSH_KNOWN_HOSTS", "").strip()
        self.servers = {
            "finland": Server("finland", "Sunny-Finland", os.getenv("FINLAND_SSH_HOST", ""), os.getenv("FINLAND_SSH_PORT", "22"), os.getenv("FINLAND_SSH_USER", "root"), os.getenv("FINLAND_SSH_IDENTITY", ""), os.getenv("FINLAND_WEB_PORT", "8443")),
            "germany": Server("germany", "Sunny-German", os.getenv("GERMANY_SSH_HOST", ""), os.getenv("GERMANY_SSH_PORT", "22"), os.getenv("GERMANY_SSH_USER", "root"), os.getenv("GERMANY_SSH_IDENTITY", ""), os.getenv("GERMANY_WEB_PORT", "443")),
        }

    def tunnel_argv(self, key: str, local_port: int) -> list[str] | None:
        server = self.servers.get(key)
        if server is None or not server.host or not server.identity:
            return None
        argv = [
            "ssh", "-N", "-T", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
        ]
        argv.extend(["-o", "StrictHostKeyChecking=yes" if self.known_hosts else "StrictHostKeyChecking=accept-new"])
        if self.known_hosts:
            argv.extend(["-o", f"UserKnownHostsFile={self.known_hosts}"])
        argv.extend([
            "-i", server.identity,
            "-L", f"127.0.0.1:{local_port}:127.0.0.1:{server.web_port}", "-p", server.port,
            f"{server.user}@{server.host}",
        ])
        return argv

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

    def request(self, key: str, action: str, token: str | object | None = None, value: str = "", extra: dict[str, Any] | None = None) -> dict[str, Any] | None:
        panel = self.panels.get(key)
        if panel is None:
            return None
        effective_token = panel.token if token is PANEL_TOKEN else str(token or "")
        if not effective_token:
            return {"error": "panel token is not assigned", "panel": panel.label}
        cache_key = (key, action, "<panel>" if token is PANEL_TOKEN else effective_token)
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
            "stats": ("GET", "/api/stats"), "traffic": ("GET", "/api/traffic"),
            "health-history": ("GET", "/api/server-health/history?range=1h"),
            "latency": ("GET", "/api/clients/latency"),
            "provider-traffic": ("GET", "/api/provider-traffic"),
            "update": ("GET", "/api/project-update"),
            "geoip-status": ("GET", "/api/geoip/status"),
            "geoip-providers": ("GET", "/api/geoip/providers"),
            "geoip-databases": ("GET", "/api/geoip/databases/status"),
            "nettest-reports": ("GET", "/api/nettest/reports"),
            "nettest-context": ("GET", "/api/nettest/context"),
            "nettest-ping": ("GET", "/api/nettest/ping?n=gaullebot"),
            "web-policy": ("GET", "/api/web-access-policy"),
            "web-cert": ("GET", "/api/web-cert"),
            "logs": ("GET", "/api/server/logs"), "restart": ("POST", "/api/server/restart"),
        }
        body = None
        if action == "add":
            endpoint_info = ("POST", "/api/clients")
            body = json.dumps({"name": value}).encode()
        elif action == "create-user-token":
            endpoint_info = ("POST", "/api/tokens")
            body = json.dumps({"name": value, "clients": (extra or {}).get("clients", [])}).encode()
        elif action == "rotate-token":
            endpoint_info = ("POST", f"/api/tokens/{quote(value, safe='')}/rotate")
            body = b"{}"
        elif action == "regenerate":
            endpoint_info = ("POST", f"/api/clients/{quote(value, safe='')}/regenerate")
            body = b"{}"
        elif action == "access-link":
            endpoint_info = ("POST", f"/api/clients/{quote(value, safe='')}/access-link")
            body = json.dumps({"ttl": 86400, "one_time": True}).encode()
        elif action == "remove":
            endpoint_info = ("DELETE", f"/api/clients/{quote(value, safe='')}")
        elif action in {"client-toggle", "p2p-toggle", "ports-toggle"}:
            suffix = {"client-toggle": "toggle", "p2p-toggle": "p2p/toggle", "ports-toggle": "ports/toggle"}[action]
            endpoint_info = ("POST", f"/api/clients/{quote(value, safe='')}/{suffix}")
            body = b"{}"
        elif action == "p2p-add":
            endpoint_info = ("POST", f"/api/clients/{quote(value, safe='')}/p2p")
            body = json.dumps({"port": (extra or {}).get("port")}).encode()
        elif action == "p2p-remove":
            port = str((extra or {}).get("port", ""))
            if not port.isdigit() or not 1 <= int(port) <= 65535:
                return {"error": "invalid P2P port", "panel": panel.label}
            endpoint_info = ("DELETE", f"/api/clients/{quote(value, safe='')}/p2p?port={quote(port, safe='')}")
        elif action == "path-check":
            endpoint_info = ("POST", f"/api/clients/{quote(value, safe='')}/path-check")
            body = json.dumps({"target": "endpoint"}).encode()
        elif action == "update-check":
            endpoint_info = ("POST", "/api/project-update/check")
            body = b"{}"
        elif action == "update-apply":
            endpoint_info = ("POST", "/api/project-update/apply")
            body = json.dumps({"confirm": "UPDATE PROJECT"}).encode()
        elif action == "server-reboot":
            endpoint_info = ("POST", "/api/server/reboot")
            body = json.dumps({"confirm": "REBOOT"}).encode()
        elif action == "dns-restart":
            endpoint_info = ("POST", "/api/dns/restart")
            body = b"{}"
        elif action == "dns-mode":
            mode = str((extra or {}).get("mode", "")).lower()
            if mode not in {"system", "adguard"}:
                return {"error": "unsupported DNS mode", "panel": panel.label}
            endpoint_info = ("POST", "/api/dns/mode")
            body = json.dumps({"mode": mode}).encode()
        elif action == "ndp-restart":
            endpoint_info = ("POST", "/api/ipv6/ndp/restart")
            body = b"{}"
        elif action == "geoip-databases-update":
            endpoint_info = ("POST", "/api/geoip/databases/update")
            body = b"{}"
        elif action == "geoip-refresh":
            endpoint_info = ("POST", "/api/geoip/refresh")
            body = b"{}"
        elif action == "geoip-providers-test":
            endpoint_info = ("POST", "/api/geoip/providers/test")
            body = b"{}"
        elif action == "geoip-auto-update":
            endpoint_info = ("POST", "/api/geoip/auto-update")
            body = b"{}"
        elif action == "web-cert-renew":
            endpoint_info = ("POST", "/api/web-cert/renew")
            body = b"{}"
        elif action == "web-policy-test":
            endpoint_info = ("POST", "/api/web-access-policy/test")
            body = b"{}"
        else:
            endpoint_info = endpoints.get(action)
        if endpoint_info is None:
            return {"error": "unsupported API action", "panel": panel.label}
        method, endpoint = endpoint_info
        headers = {"Authorization": f"Bearer {effective_token}", "Accept": "application/json"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        request = Request(panel.base_url + endpoint, headers=headers, data=body, method=method)
        context = None if panel.verify_tls else ssl._create_unverified_context()
        try:
            with urlopen(request, timeout=15, context=context) as response:
                payload = json.loads(response.read())
        except HTTPError as exc:
            if exc.code in {401, 403}:
                LOG.info("panel API denied request panel=%s action=%s", key, action)
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
        elif action not in {"update", "update-check"}:
            # Mutations must be visible on the next card render; do not let a
            # previously cached snapshot survive add/remove/toggle actions.
            with self._cache_lock:
                for cached_key in [item for item in self._cache if item[0] == key]:
                    self._cache.pop(cached_key, None)
        return payload

    def run(self, key: str, action: str, token: str | object | None = None, value: str = "") -> str | None:
        payload = self.request(key, action, token, value)
        if payload is None:
            return None
        return f"{payload.get('panel', key)}\n{json.dumps(payload, ensure_ascii=False, indent=2)[:3500]}"

    def artifact(self, key: str, name: str, kind: str, token: str | object | None = None) -> tuple[bytes, str, str] | None:
        """Download a client artifact through the authenticated panel API."""
        panel = self.panels.get(key)
        if panel is None:
            return None
        effective_token = panel.token if token is PANEL_TOKEN else str(token or "")
        if not effective_token:
            return None
        endpoints = {
            "config": (f"/api/clients/{quote(name, safe='')}/config/download", "client.conf", "text/plain"),
            "qr": (f"/api/clients/{quote(name, safe='')}/qr", "client.png", "image/png"),
            "uri": (f"/api/clients/{quote(name, safe='')}/uri", "client.vpnuri", "text/plain"),
        }
        endpoint_info = endpoints.get(kind)
        if endpoint_info is None:
            return None
        endpoint, suffix, fallback_type = endpoint_info
        request = Request(panel.base_url + endpoint, headers={"Authorization": f"Bearer {effective_token}", "Accept": "*/*"})
        context = None if panel.verify_tls else ssl._create_unverified_context()
        try:
            with urlopen(request, timeout=20, context=context) as response:
                data = response.read(4_000_000)
                content_type = response.headers.get_content_type() or fallback_type
                disposition = response.headers.get("Content-Disposition", "")
                filename = suffix
                if "filename=" in disposition:
                    filename = disposition.split("filename=", 1)[1].strip().strip('"') or suffix
                return data, content_type, filename
        except (HTTPError, OSError, ValueError):
            LOG.warning("panel artifact failed panel=%s kind=%s", key, kind)
            return None

    def nettest(self, key: str, kind: str, token: str | object | None = None, *, test_id: str = "", size: int = 0, body: bytes | None = None, payload: dict[str, Any] | None = None) -> tuple[bytes, str] | dict[str, Any] | None:
        """Proxy the bounded network-test API without exposing panel credentials."""
        panel = self.panels.get(key)
        if panel is None:
            return None
        effective_token = panel.token if token is PANEL_TOKEN else str(token or "")
        if not effective_token or kind not in {"context", "ping", "download", "upload", "report", "cancel"}:
            return None
        query = ""
        if test_id:
            query += "?test_id=" + quote(test_id, safe="")
        if kind == "download":
            query += ("&" if query else "?") + "size=" + str(max(1, min(int(size or 1_000_000), 4_000_000)));
        endpoint = f"/api/nettest/{kind}{query}"
        request_body = body
        headers = {"Authorization": f"Bearer {effective_token}", "Accept": "application/json"}
        if payload is not None:
            request_body = json.dumps(payload, ensure_ascii=False).encode()
            headers["Content-Type"] = "application/json"
        elif kind == "upload":
            headers["Content-Type"] = "application/octet-stream"
            headers["X-Nettest-Id"] = test_id
        request = Request(panel.base_url + endpoint, headers=headers, data=request_body, method="POST" if kind in {"upload", "report", "cancel"} else "GET")
        context = None if panel.verify_tls else ssl._create_unverified_context()
        try:
            with urlopen(request, timeout=30, context=context) as response:
                data = response.read(4_000_000)
                if kind == "download":
                    return data, response.headers.get_content_type() or "application/octet-stream"
                result = json.loads(data)
                return result if isinstance(result, dict) else None
        except (HTTPError, OSError, ValueError, json.JSONDecodeError) as exc:
            LOG.info("panel nettest failed panel=%s kind=%s error=%s", key, kind, type(exc).__name__)
            return None

    def keys(self) -> list[str]:
        return list(self.panels)


def server_result(panel: PanelManager, key: str, action: str, token: str | object | None = None, value: str = "") -> str:
    """Execute a bot action exclusively through the authenticated panel API."""
    return panel_text(panel, key, action, token, value)


def parallel_results(panel: PanelManager, keys: tuple[str, ...], action: str, tokens: dict[str, str | object | None] | None = None) -> list[str]:
    """Query panels concurrently; one slow region must not block the other."""
    tokens = tokens or {}

    def fetch(key: str) -> str:
        return server_result(panel, key, action, tokens.get(key, PANEL_TOKEN))

    with ThreadPoolExecutor(max_workers=len(keys)) as pool:
        futures = [pool.submit(fetch, key) for key in keys]
        return [future.result() for future in futures]


def parallel_payloads(panel: PanelManager, keys: tuple[str, ...], action: str, tokens: dict[str, str | object | None] | None = None) -> list[dict[str, Any]]:
    """Fetch structured API payloads concurrently for multi-panel screens."""
    tokens = tokens or {}

    def fetch(key: str) -> dict[str, Any]:
        payload = panel.request(key, action, tokens.get(key, PANEL_TOKEN))
        return payload if isinstance(payload, dict) else {"panel": key, "error": "API недоступен"}

    with ThreadPoolExecutor(max_workers=max(1, len(keys))) as pool:
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

    def _upload(self, method: str, field: str, filename: str, content: bytes, *, chat_id: int, caption: str = "") -> dict[str, Any]:
        boundary = f"----GaulleBot{os.urandom(12).hex()}"
        chunks: list[bytes] = []
        def add_field(name: str, value: str) -> None:
            chunks.extend([f"--{boundary}\r\n".encode(), f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode(), value.encode(), b"\r\n"])
        add_field("chat_id", str(chat_id))
        if caption:
            add_field("caption", caption[:1024])
            add_field("parse_mode", "HTML")
        chunks.extend([f"--{boundary}\r\n".encode(), f'Content-Disposition: form-data; name="{field}"; filename="{filename}"\r\n'.encode(), b"Content-Type: application/octet-stream\r\n\r\n", content, b"\r\n", f"--{boundary}--\r\n".encode()])
        request = Request(f"{self.base}/{method}", data=b"".join(chunks), headers={"Content-Type": f"multipart/form-data; boundary={boundary}"}, method="POST")
        with urlopen(request, timeout=self.poll_timeout + 20) as response:
            payload = json.loads(response.read())
        if not payload.get("ok"):
            raise RuntimeError(f"Telegram {method} failed")
        return payload["result"]

    def send_document(self, chat_id: int, filename: str, content: bytes, caption: str = "") -> dict[str, Any]:
        return self._upload("sendDocument", "document", filename, content, chat_id=chat_id, caption=caption)

    def send_photo(self, chat_id: int, filename: str, content: bytes, caption: str = "") -> dict[str, Any]:
        return self._upload("sendPhoto", "photo", filename, content, chat_id=chat_id, caption=caption)

    def send(self, chat_id: int, text: str, *, keyboard: list[list[dict[str, str]]] | None = None, reply_keyboard: list[list[str]] | None = None, force_reply: bool = False) -> dict[str, Any]:
        params: dict[str, Any] = {"chat_id": chat_id, "text": text[:4096], "parse_mode": "HTML"}
        if keyboard:
            params["reply_markup"] = json.dumps({"inline_keyboard": keyboard}, ensure_ascii=False)
        elif reply_keyboard:
            params["reply_markup"] = json.dumps({"keyboard": [[{"text": item} for item in row] for row in reply_keyboard], "is_persistent": True, "resize_keyboard": True}, ensure_ascii=False)
        elif force_reply:
            params["reply_markup"] = json.dumps({"force_reply": True, "selective": True}, ensure_ascii=False)
        try:
            return self.call("sendMessage", **params)
        except RuntimeError as exc:
            # Logs and command output can contain arbitrary characters. Fall
            # back to plain text if Telegram rejects malformed HTML markup.
            if "parse entities" not in str(exc).lower() and "can't parse" not in str(exc).lower():
                raise
            params.pop("parse_mode", None)
            return self.call("sendMessage", **params)

    def edit_message(self, chat_id: int, message_id: int, text: str, *, keyboard: list[list[dict[str, str]]] | None = None) -> dict[str, Any]:
        params: dict[str, Any] = {
            "chat_id": chat_id,
            "message_id": message_id,
            "text": text[:4096],
            "parse_mode": "HTML",
            "reply_markup": json.dumps({"inline_keyboard": keyboard or []}, ensure_ascii=False),
        }
        try:
            return self.call("editMessageText", **params)
        except RuntimeError as exc:
            message = str(exc).lower()
            if "message is not modified" in message:
                return {"message_id": message_id}
            if "parse entities" not in message and "can't parse" not in message:
                raise
            params.pop("parse_mode", None)
            return self.call("editMessageText", **params)

    def delete_message(self, chat_id: int, message_id: int) -> None:
        try:
            self.call("deleteMessage", chat_id=chat_id, message_id=message_id)
        except RuntimeError as exc:
            if "message to delete not found" not in str(exc).lower():
                raise

    def set_commands(self, commands: list[dict[str, str]], *, chat_id: int | None = None) -> None:
        scope = {"type": "chat", "chat_id": chat_id} if chat_id is not None else {"type": "default"}
        self.call("setMyCommands", commands=json.dumps(commands, ensure_ascii=False), scope=json.dumps(scope))

    def set_menu_button(self, mini_app_url: str = "", *, chat_id: int | None = None) -> None:
        button = {"type": "web_app", "text": "Панель", "web_app": {"url": mini_app_url}} if mini_app_url else {"type": "commands"}
        params: dict[str, Any] = {"menu_button": json.dumps(button, ensure_ascii=False)}
        if chat_id is not None:
            params["chat_id"] = chat_id
        self.call("setChatMenuButton", **params)

    def set_webhook(self, url: str, secret: str, allowed_updates: list[str]) -> None:
        self.call("setWebhook", url=url, secret_token=secret, max_connections=40, allowed_updates=json.dumps(allowed_updates))

    def configure_profile(self, mini_app_url: str = "", admin_chat_id: int = 0) -> None:
        commands = [{"command": command, "description": description} for command, description in (("start", "Открыть главное меню"), ("menu", "Показать меню"), ("servers", "Статус серверов"), ("clients", "Список клиентов"), ("me", "Моя привязка"), ("help", "Помощь"))]
        admin_commands = commands + [{"command": command, "description": description} for command, description in (("health", "Глубокая проверка"), ("readiness", "Готовность VPN"), ("dns", "Состояние DNS"), ("audit", "Аудит клиентов"), ("history", "История нагрузки"), ("latency", "Latency клиентов"), ("provider", "Трафик провайдера"), ("restart", "Перезапуск сервиса"))]
        self.set_commands(commands)
        if admin_chat_id:
            self.set_commands(admin_commands, chat_id=admin_chat_id)
        self.set_menu_button(mini_app_url)
        if admin_chat_id:
            self.set_menu_button(mini_app_url, chat_id=admin_chat_id)

    def answer_callback(self, callback_id: str, text: str = "") -> None:
        self.call("answerCallbackQuery", callback_query_id=callback_id, text=text[:200])


def help_text(admin: bool) -> str:
    text = "<b>GaulleBot</b>\nВыберите действие кнопками — команды нужны только для восстановления.\n\n/me — моя привязка\n/servers — состояние серверов\n/clients — мои устройства\n/menu — главное меню\n/help — помощь"
    if admin:
        text += "\n\n<b>Администратор</b>:\n/status — быстрый сводный статус\n/health — глубокая проверка\n/info — сведения о сервере\n/readiness — готовность VPN\n/dns — DNS/AdGuard\n/resolver — состояние resolver\n/audit — аудит клиентов\n/tokens — токены панели\n/history — история нагрузки\n/latency — задержка клиентов\n/provider — трафик провайдера\n/clients [server] — клиенты\n/logs [server] — последние логи\n/users — привязки\n/bind &lt;tg_id&gt; &lt;fin_token&gt; &lt;ger_token&gt;\n/add &lt;server&gt; &lt;name&gt;\n/remove &lt;server&gt; &lt;name&gt;\n/regenerate &lt;server&gt; &lt;name&gt;\n/restart &lt;finland|germany&gt;"
    return text


def menu_keyboard(admin: bool) -> list[list[dict[str, str]]]:
    rows = [
        [{"text": "📡 Серверы", "callback_data": "menu:servers"}, {"text": "👥 Мои устройства", "callback_data": "user:clients"}],
        [{"text": "📈 Статистика", "callback_data": "user:traffic"}, {"text": "🌐 Доступность", "callback_data": "user:nettest"}],
        [{"text": "⭐ Избранное", "callback_data": "user:favorites"}],
        [{"text": "👤 Профиль", "callback_data": "menu:profile"}],
        [{"text": "➕ Добавить устройство", "callback_data": "user:add"}],
        [{"text": "🔐 Запросить доступ", "callback_data": "user:request"}],
    ]
    if admin:
        rows = [[{"text": "📊 Статус", "callback_data": "server:status:all"}, {"text": "🩺 Проверка", "callback_data": "server:health:all"}], [{"text": "✅ Готовность", "callback_data": "server:readiness:all"}, {"text": "🌐 DNS", "callback_data": "server:dns:all"}], [{"text": "👥 Клиенты", "callback_data": "server:clients:all"}, {"text": "👤 Пользователи", "callback_data": "admin:users:0"}], [{"text": "⚙️ Ещё", "callback_data": "menu:admin"}]] + rows
    return rows


def admin_keyboard() -> list[list[dict[str, str]]]:
    return [
        [{"text": "ℹ️ Информация", "callback_data": "server:info:all"}, {"text": "🧪 Аудит", "callback_data": "server:audit:all"}],
        [{"text": "🧭 Resolver", "callback_data": "server:resolver:all"}, {"text": "🔑 Токены", "callback_data": "server:tokens:all"}],
        [{"text": "📉 Нагрузка", "callback_data": "server:health-history:all"}, {"text": "📶 Latency", "callback_data": "server:latency:all"}],
        [{"text": "🌐 Provider traffic", "callback_data": "server:provider-traffic:all"}],
        [{"text": "🧰 GeoIP", "callback_data": "server:geoip-status:all"}, {"text": "🧪 Nettest", "callback_data": "server:nettest-reports:all"}],
        [{"text": "🛡 Web policy", "callback_data": "server:web-policy:all"}, {"text": "🔒 TLS-сертификат", "callback_data": "server:web-cert:all"}],
        [{"text": "📈 Трафик", "callback_data": "user:traffic"}, {"text": "🌐 Доступность", "callback_data": "user:nettest"}, {"text": "🔄 Обновления", "callback_data": "admin:update"}],
        [{"text": "🛠 Обслуживание", "callback_data": "admin:maintenance"}],
        [{"text": "➕ Клиент Финляндии", "callback_data": "admin:add:finland"}, {"text": "➕ Клиент Германии", "callback_data": "admin:add:germany"}],
        [{"text": "♻️ Перезапуск Финляндии", "callback_data": "admin:restart:finland"}, {"text": "♻️ Перезапуск Германии", "callback_data": "admin:restart:germany"}],
        [{"text": "📜 Логи Финляндии", "callback_data": "server:logs:finland"}, {"text": "📜 Логи Германии", "callback_data": "server:logs:germany"}],
        [{"text": "⬅️ Главное меню", "callback_data": "menu:home"}],
    ]


def maintenance_keyboard() -> list[list[dict[str, str]]]:
    return [
        [{"text": "♻️ DNS Финляндии", "callback_data": "admin:dns-restart:finland"}, {"text": "♻️ DNS Германии", "callback_data": "admin:dns-restart:germany"}],
        [{"text": "🧭 DNS режим FI", "callback_data": "admin:dns-mode:finland"}, {"text": "🧭 DNS режим DE", "callback_data": "admin:dns-mode:germany"}],
        [{"text": "🌐 NDP Финляндии", "callback_data": "admin:ndp-restart:finland"}, {"text": "🌐 NDP Германии", "callback_data": "admin:ndp-restart:germany"}],
        [{"text": "🗺 Обновить GeoIP", "callback_data": "admin:geoip-update:all"}, {"text": "🔒 Продлить TLS", "callback_data": "admin:cert-renew:all"}],
        [{"text": "🔎 Проверить GeoIP", "callback_data": "admin:geoip-providers-test:all"}, {"text": "⚙️ Авто-GeoIP", "callback_data": "admin:geoip-auto-update:all"}],
        [{"text": "🛡 Проверить web policy", "callback_data": "admin:policy-test:all"}],
        [{"text": "⚠️ Перезагрузка сервера", "callback_data": "admin:reboot:all"}],
        [{"text": "⬅️ Админка", "callback_data": "menu:admin"}],
    ]


def callback_command(data: str) -> str:
    """Translate button payloads to the same internal command namespace."""
    value = str(data or "").strip()
    if value.startswith("nav:"):
        value = value[4:]
    return f"/{value}" if value and not value.startswith("/") else value


def navigation_keyboard(action: str, admin: bool) -> list[list[dict[str, str]]]:
    if action == "servers":
        return [[{"text": "🇫🇮 Финляндия", "callback_data": "server:status:finland"}, {"text": "🇩🇪 Германия", "callback_data": "server:status:germany"}], [{"text": "📊 Оба сервера", "callback_data": "server:status:all"}], [{"text": "⬅️ Главное меню", "callback_data": "menu:home"}]]
    if action == "profile":
        return [[{"text": "📡 Состояние серверов", "callback_data": "server:status:all"}], [{"text": "👥 Мои устройства", "callback_data": "user:clients"}, {"text": "⭐ Избранное", "callback_data": "user:favorites"}], [{"text": "⬅️ Главное меню", "callback_data": "menu:home"}]]
    if action == "admin":
        return admin_keyboard()
    return [[{"text": "⬅️ Серверы", "callback_data": "menu:servers"}, {"text": "🏠 Меню", "callback_data": "menu:home"}]]


def result_navigation_keyboard(action: str, server: str, admin: bool) -> list[list[dict[str, str]]]:
    """Add an inline refresh action to every rendered server result card."""
    return [[{"text": "🔄 Обновить", "callback_data": f"server:{action}:{server}"}], *navigation_keyboard("result", admin)]


def client_keyboard(server: str, name: str, ref: str, *, admin: bool, favorite: bool = False, back: str = "user:clients") -> list[list[dict[str, str]]]:
    page = back.rsplit(":", 1)[-1] if back.startswith("user:clients:") else "1"
    suffix = f":{page}{':favorites' if back == 'user:favorites' else ''}"
    rows = [
        [{"text": "📷 QR-код", "callback_data": f"client:artifact:{ref}:qr{suffix}"}, {"text": "📄 Конфиг", "callback_data": f"client:artifact:{ref}:config{suffix}"}],
        [{"text": "🔗 VPN URI", "callback_data": f"client:artifact:{ref}:uri{suffix}"}, {"text": "📈 Статистика", "callback_data": f"client:stats:{ref}{suffix}"}],
        [{"text": "💔 Убрать из избранного" if favorite else "⭐ В избранное", "callback_data": f"client:favorite-{'remove' if favorite else 'add'}:{ref}{suffix}"}],
        [{"text": "♻️ Перегенерировать конфиг", "callback_data": f"client:regenerate:{ref}{suffix}"}],
        [{"text": "🔗 Одноразовая ссылка импорта", "callback_data": f"client:access-link:{ref}{suffix}"}],
        [{"text": "⏻ VPN", "callback_data": f"client:toggle:{ref}{suffix}"}, {"text": "🔌 P2P", "callback_data": f"client:p2p-toggle:{ref}{suffix}"}, {"text": "🔗 Порты", "callback_data": f"client:ports-toggle:{ref}{suffix}"}],
        [{"text": "🔧 Добавить P2P порт", "callback_data": f"client:p2p-port:{ref}{suffix}"}, {"text": "🗑 Удалить P2P", "callback_data": f"client:p2p-remove:{ref}{suffix}"}],
        *([[{"text": "🧭 Проверить путь", "callback_data": f"client:path-check:{ref}{suffix}"}]] if admin else []),
        [{"text": "🗑 Удалить", "callback_data": f"client:remove:{ref}{suffix}"}],
        [{"text": "⬅️ Назад", "callback_data": back}, {"text": "🏠 Меню", "callback_data": "menu:home"}],
    ]
    return rows


def clients_keyboard(rows: list[tuple[str, str, str]], *, page: int = 1, pages: int = 1, source: str = "clients") -> list[list[dict[str, str]]]:
    keyboard: list[list[dict[str, str]]] = []
    for server, name, ref in rows:
        keyboard.append([{"text": f"{('🇫🇮' if server == 'finland' else '🇩🇪')} {name}", "callback_data": f"client:open:{ref}:{page}:{source}"}])
    if pages > 1:
        pager: list[dict[str, str]] = []
        if page > 1:
            pager.append({"text": "◀️", "callback_data": f"user:{'favorites' if source == 'favorites' else 'clients'}:{page - 1}"})
        pager.append({"text": f"{page}/{pages}", "callback_data": f"user:{'favorites' if source == 'favorites' else 'clients'}:{page}"})
        if page < pages:
            pager.append({"text": "▶️", "callback_data": f"user:{'favorites' if source == 'favorites' else 'clients'}:{page + 1}"})
        keyboard.append(pager)
    keyboard.extend([[{"text": "📈 Статистика", "callback_data": "user:traffic"}, {"text": "🌐 Доступность", "callback_data": "user:nettest"}, {"text": "⭐ Избранное", "callback_data": "user:favorites"}], [{"text": "🏠 Меню", "callback_data": "menu:home"}]])
    return keyboard


def render_navigation(telegram: Telegram, store: Store, chat_id: int, text: str, keyboard: list[list[dict[str, str]]], screen: str, *, callback_message_id: int | None = None, reply: bool = True) -> None:
    """Keep one editable navigation message per chat; never touch media messages."""
    previous = store.navigation(chat_id)
    previous_id = int(previous["message_id"]) if previous else None
    target_id = callback_message_id if callback_message_id and callback_message_id == previous_id else None
    if target_id:
        try:
            telegram.edit_message(chat_id, target_id, text, keyboard=keyboard)
            store.set_navigation(chat_id, target_id, screen)
            return
        except (OSError, RuntimeError, ValueError) as exc:
            LOG.info("navigation edit failed chat=%s screen=%s error=%s", chat_id, screen, type(exc).__name__)
    if previous_id and previous_id != callback_message_id:
        try:
            telegram.delete_message(chat_id, previous_id)
        except (OSError, RuntimeError, ValueError):
            pass
    result = telegram.send(chat_id, text, keyboard=keyboard, reply_keyboard=reply_keyboard() if reply else None)
    message_id = int(result.get("message_id", 0)) if isinstance(result, dict) else 0
    if message_id:
        store.set_navigation(chat_id, message_id, screen)


def handle_navigation(telegram: Telegram, store: Store, panels: PanelManager, chat_id: int, is_admin: bool, data: str, *, actor_id: int | None = None, callback_message_id: int | None = None) -> bool:
    """Render button-first VPN screens and edit the current menu in place."""
    parts = [part for part in str(data or "").split(":")]
    principal_id = actor_id or chat_id
    if len(parts) < 2 or parts[0] not in {"menu", "server", "admin", "user", "client"}:
        return False
    kind, action = parts[0], parts[1]
    if kind == "menu":
        if action == "home":
            text = "<b>GaulleBot</b>\nУправление VPN-серверами без ручного ввода команд."
            render_navigation(telegram, store, chat_id, text, menu_keyboard(is_admin), "home", callback_message_id=callback_message_id)
            return True
        if action in {"servers", "profile", "admin"}:
            if action == "profile":
                row = store.get(principal_id)
                text = "<b>Ваш профиль</b>\nTelegram ID: <code>%s</code>\nFinland: %s\nGermany: %s" % (chat_id, "✅" if row and row["finland_token"] else "—", "✅" if row and row["germany_token"] else "—")
            elif action == "admin":
                if not is_admin:
                    render_navigation(telegram, store, chat_id, "Недостаточно прав.", menu_keyboard(False), "home", callback_message_id=callback_message_id)
                    return True
                text = "<b>Администрирование</b>\nДиагностика и служебные действия:"
            else:
                text = "<b>Серверы</b>\nВыберите сервер или сводный статус."
            render_navigation(telegram, store, chat_id, text, navigation_keyboard(action, is_admin), action, callback_message_id=callback_message_id)
            return True
    if kind == "admin" and action == "users":
        if not is_admin:
            render_navigation(telegram, store, chat_id, "Недостаточно прав.", menu_keyboard(False), "home", callback_message_id=callback_message_id)
            return True
        rows = store.all()
        lines = [f"<code>{r['telegram_id']}</code> @{html.escape(r['username'] or '-')} · 🇫🇮 {'✅' if r['finland_token'] else '—'} · 🇩🇪 {'✅' if r['germany_token'] else '—'}" for r in rows[:30]]
        text = "<b>Пользователи</b>\nРотация токена создаёт новый секрет и инвалидирует старый.\n\n" + ("\n".join(lines) or "Пользователей пока нет.")
        keyboard = []
        for row in rows[:30]:
            controls = [{"text": f"👤 {row['telegram_id']}", "callback_data": f"admin:user:{row['telegram_id']}"}]
            if row["finland_token"] or row["germany_token"]:
                controls.append({"text": "🔄 Ротировать", "callback_data": f"admin:rotate:{row['telegram_id']}"})
            keyboard.append(controls)
        keyboard.append([{"text": "⬅️ Главное меню", "callback_data": "menu:home"}])
        render_navigation(telegram, store, chat_id, text[:4096], keyboard, "admin:users", callback_message_id=callback_message_id)
        return True
    if kind == "admin" and action == "user":
        if not is_admin or len(parts) < 3:
            render_navigation(telegram, store, chat_id, "Недостаточно прав.", menu_keyboard(False), "home", callback_message_id=callback_message_id)
            return True
        try:
            target_id = int(parts[2])
        except (TypeError, ValueError):
            return True
        target = store.get(target_id)
        if target is None:
            render_navigation(telegram, store, chat_id, "Пользователь не найден.", admin_keyboard(), "admin:users", callback_message_id=callback_message_id)
            return True
        text = (f"<b>👤 Пользователь</b>\nTelegram ID: <code>{target_id}</code>\n"
                f"Username: @{html.escape(target['username'] or '—')}\n"
                f"Имя: {html.escape(target['first_name'] or '—')}\n\n"
                f"🇫🇮 Finland: {'✅ привязан' if target['finland_token'] else '— нет токена'}\n"
                f"🇩🇪 Germany: {'✅ привязан' if target['germany_token'] else '— нет токена'}\n"
                f"Создан: <code>{format_timestamp(target['created_at'])}</code>\n"
                f"Изменён: <code>{format_timestamp(target['updated_at'])}</code>")
        controls = []
        if target["finland_token"] or target["germany_token"]:
            controls.append({"text": "🔄 Ротировать токены", "callback_data": f"admin:rotate:{target_id}"})
        keyboard = [controls] if controls else []
        keyboard.append([{"text": "👥 Пользователи", "callback_data": "admin:users:0"}, {"text": "⬅️ Админка", "callback_data": "menu:admin"}])
        render_navigation(telegram, store, chat_id, text, keyboard, "admin:user", callback_message_id=callback_message_id)
        return True
    if kind == "admin" and action in {"rotate", "rotate-confirm"}:
        if not is_admin or len(parts) < 3:
            render_navigation(telegram, store, chat_id, "Недостаточно прав.", menu_keyboard(False), "home", callback_message_id=callback_message_id)
            return True
        try:
            target_id = int(parts[2])
        except (TypeError, ValueError):
            return True
        target = store.get(target_id)
        if target is None or not (target["finland_token"] or target["germany_token"]):
            render_navigation(telegram, store, chat_id, "У пользователя нет привязанных токенов.", admin_keyboard(), "admin:users", callback_message_id=callback_message_id)
            return True
        if action == "rotate":
            render_navigation(telegram, store, chat_id, f"<b>🔄 Ротация токенов</b>\nПользователь: <code>{target_id}</code>\nСтарые секреты сразу перестанут работать. Продолжить?", [[{"text": "✅ Да, ротировать", "callback_data": f"admin:rotate-confirm:{target_id}"}], [{"text": "Отмена", "callback_data": "admin:users:0"}]], "admin:rotate-confirm", callback_message_id=callback_message_id)
            return True
        rotated: dict[str, str] = {}
        failures: list[str] = []
        for server, column in (("finland", "finland_token"), ("germany", "germany_token")):
            old_token = str(target[column] or "")
            if not old_token:
                continue
            digest = hashlib.sha256(old_token.encode("utf-8")).hexdigest()
            payload = panels.request(server, "rotate-token", PANEL_TOKEN, value=digest) or {}
            new_token = str(payload.get("token") or "")
            if new_token:
                rotated[column] = new_token
            else:
                failures.append(server)
        store.bind(target_id, str(target["username"] or ""), str(target["first_name"] or ""), rotated.get("finland_token", str(target["finland_token"] or "")), rotated.get("germany_token", str(target["germany_token"] or "")))
        if rotated:
            try:
                telegram.send(target_id, "<b>🔐 Доступ обновлён</b>\nТокены доступа были ротированы администратором. Старые ссылки/сессии необходимо обновить.")
            except (OSError, RuntimeError, ValueError):
                LOG.info("token rotation notification failed user=%s", target_id)
        detail = "Ротированы: " + ", ".join(rotated) if rotated else "Ротация не выполнена"
        if failures:
            detail += "; ошибка: " + ", ".join(failures)
        render_navigation(telegram, store, chat_id, f"<b>🔐 Ротация завершена</b>\nПользователь: <code>{target_id}</code>\n{html.escape(detail)}\nСекреты не выводятся.", admin_keyboard(), "admin:rotate-done", callback_message_id=callback_message_id)
        return True
    if kind == "admin" and action == "request":
        if not is_admin or len(parts) < 3:
            render_navigation(telegram, store, chat_id, "Недостаточно прав.", menu_keyboard(False), "home", callback_message_id=callback_message_id)
            return True
        try:
            requested_id = int(parts[2])
        except ValueError:
            return True
        requested = store.get(requested_id)
        if requested is None:
            render_navigation(telegram, store, chat_id, "Заявка устарела или пользователь ещё не написал боту.", admin_keyboard(), "admin", callback_message_id=callback_message_id)
            return True
        text = (f"<b>🔐 Запрос доступа</b>\nTelegram ID: <code>{requested_id}</code>\n"
                f"Пользователь: @{html.escape(requested['username'] or 'без username')}\n\n"
                "Бот может автоматически создать отдельные scoped-токены на обеих панелях и привязать их к пользователю.")
        render_navigation(telegram, store, chat_id, text, [[{"text": "✅ Выдать доступ", "callback_data": f"admin:approve:{requested_id}"}, {"text": "↩️ Отклонить", "callback_data": f"admin:reject:{requested_id}"}], [{"text": "👥 Пользователи", "callback_data": "admin:users:0"}, {"text": "⬅️ Админка", "callback_data": "menu:admin"}]], "admin:request", callback_message_id=callback_message_id)
        return True
    if kind == "admin" and action in {"approve", "reject"}:
        if not is_admin or len(parts) < 3:
            render_navigation(telegram, store, chat_id, "Недостаточно прав.", menu_keyboard(False), "home", callback_message_id=callback_message_id)
            return True
        try:
            requested_id = int(parts[2])
        except (TypeError, ValueError):
            return True
        requested = store.get(requested_id)
        if requested is None:
            render_navigation(telegram, store, chat_id, "Заявка устарела или пользователь ещё не написал боту.", admin_keyboard(), "admin", callback_message_id=callback_message_id)
            return True
        if action == "reject":
            store.resolve_access_request(requested_id, "rejected")
            try:
                telegram.send(requested_id, "<b>🔐 Запрос доступа отклонён</b>\nЕсли это ошибка, отправьте новую заявку позже.")
            except (OSError, RuntimeError, ValueError):
                LOG.info("access rejection notification failed user=%s", requested_id)
            render_navigation(telegram, store, chat_id, f"<b>↩️ Запрос отклонён</b>\nTelegram ID: <code>{requested_id}</code>", admin_keyboard(), "admin:request-rejected", callback_message_id=callback_message_id)
            return True
        if requested["finland_token"] or requested["germany_token"]:
            render_navigation(telegram, store, chat_id, "<b>✅ Доступ уже привязан</b>\nПовторная выдача токенов не выполнена.", admin_keyboard(), "admin:request-approved", callback_message_id=callback_message_id)
            return True
        token_name = f"telegram-{requested_id}"
        created: dict[str, str] = {}
        failures: list[str] = []
        def create_token(server: str) -> tuple[str, str]:
            payload = panels.request(server, "create-user-token", PANEL_TOKEN, value=token_name, extra={"clients": []}) or {}
            token = str(payload.get("token") or "")
            return server, token
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(create_token, server) for server in ("finland", "germany")]
            for future in futures:
                server, token = future.result()
                if token:
                    created[server] = token
                else:
                    failures.append(server)
        finland_token = created.get("finland", "")
        germany_token = created.get("germany", "")
        if created:
            store.bind(requested_id, str(requested["username"] or ""), str(requested["first_name"] or ""), finland_token, germany_token)
            store.resolve_access_request(requested_id, "approved")
            try:
                telegram.send(requested_id, "<b>✅ Доступ выдан</b>\nДля вас созданы персональные права на доступные панели. Откройте меню → «Мои устройства».", keyboard=menu_keyboard(False), reply_keyboard=reply_keyboard())
            except (OSError, RuntimeError, ValueError):
                LOG.info("access approval notification failed user=%s", requested_id)
        detail = "Обе панели привязаны." if not failures else f"Частичная выдача: готово {', '.join(sorted(created))}; ошибка: {', '.join(failures)}."
        render_navigation(telegram, store, chat_id, f"<b>✅ Доступ обработан</b>\nTelegram ID: <code>{requested_id}</code>\n{html.escape(detail)}\nСекреты токенов не выводятся.", admin_keyboard(), "admin:request-approved", callback_message_id=callback_message_id)
        return True
    if kind == "admin" and action == "add":
        if not is_admin or len(parts) < 3 or parts[2].lower() not in {"finland", "germany"}:
            render_navigation(telegram, store, chat_id, "Недостаточно прав.", menu_keyboard(False), "home", callback_message_id=callback_message_id)
            return True
        server = parts[2].lower()
        store.set_prompt(principal_id, "add_client", server)
        telegram.send(chat_id, f"<b>➕ Новый клиент · {html.escape(server)}</b>\nВведите короткое имя (латиница, цифры, `-` или `_`, до 48 символов).", force_reply=True)
        return True
    if kind == "admin" and action == "maintenance":
        if not is_admin:
            render_navigation(telegram, store, chat_id, "Недостаточно прав.", menu_keyboard(False), "home", callback_message_id=callback_message_id)
            return True
        render_navigation(telegram, store, chat_id, "<b>🛠 Обслуживание инфраструктуры</b>\nОперации выполняются только через API панели. Перезагрузка требует отдельного подтверждения.", maintenance_keyboard(), "admin:maintenance", callback_message_id=callback_message_id)
        return True
    if kind == "admin" and action in {"dns-restart", "dns-mode", "dns-mode-apply", "ndp-restart", "geoip-update", "geoip-refresh", "geoip-providers-test", "geoip-auto-update", "cert-renew", "policy-test", "reboot", "reboot-confirm"}:
        if not is_admin:
            render_navigation(telegram, store, chat_id, "Недостаточно прав.", menu_keyboard(False), "home", callback_message_id=callback_message_id)
            return True
        server = parts[2].lower() if len(parts) > 2 else "all"
        if action == "reboot":
            if server == "all":
                render_navigation(telegram, store, chat_id, "<b>⚠️ Выберите сервер для перезагрузки</b>", [[{"text": "🇫🇮 Финляндия", "callback_data": "admin:reboot:finland"}, {"text": "🇩🇪 Германия", "callback_data": "admin:reboot:germany"}], [{"text": "Отмена", "callback_data": "admin:maintenance"}]], "admin:reboot", callback_message_id=callback_message_id)
                return True
            if server not in {"finland", "germany"}:
                return True
            render_navigation(telegram, store, chat_id, f"<b>⚠️ Перезагрузить {html.escape(server)}?</b>\nVPN и панель будут временно недоступны.", [[{"text": "✅ Да, перезагрузить", "callback_data": f"admin:reboot-confirm:{server}"}], [{"text": "Отмена", "callback_data": "admin:maintenance"}]], "admin:reboot-confirm", callback_message_id=callback_message_id)
            return True
        if action == "reboot-confirm" and server in {"finland", "germany"}:
            result = panel_text(panels, server, "server-reboot", PANEL_TOKEN)
            render_navigation(telegram, store, chat_id, f"<b>♻️ Перезагрузка запланирована</b>\n{result}", maintenance_keyboard(), "admin:reboot-done", callback_message_id=callback_message_id)
            return True
        if action == "dns-mode":
            if server not in {"finland", "germany"}:
                return True
            render_navigation(telegram, store, chat_id, f"<b>🧭 DNS режим · {html.escape(server)}</b>\nВыберите безопасный режим:", [[{"text": "🛡 AdGuard Home", "callback_data": f"admin:dns-mode-apply:{server}:adguard"}, {"text": "🧩 Системный DNS", "callback_data": f"admin:dns-mode-apply:{server}:system"}], [{"text": "Отмена", "callback_data": "admin:maintenance"}]], "admin:dns-mode", callback_message_id=callback_message_id)
            return True
        if action == "dns-mode-apply" and server in {"finland", "germany"} and len(parts) > 3 and parts[3].lower() in {"system", "adguard"}:
            mode = parts[3].lower()
            payload = panels.request(server, "dns-mode", PANEL_TOKEN, extra={"mode": mode}) or {}
            result = format_panel_payload(payload, "dns")
            render_navigation(telegram, store, chat_id, f"<b>✅ DNS режим обновлён</b>\n{result}", maintenance_keyboard(), "admin:dns-mode-done", callback_message_id=callback_message_id)
            return True
        if action in {"dns-restart", "ndp-restart"} and server in {"finland", "germany"}:
            result = panel_text(panels, server, action, PANEL_TOKEN)
            render_navigation(telegram, store, chat_id, f"<b>✅ Операция отправлена</b>\n{result}", maintenance_keyboard(), f"admin:{action}-done", callback_message_id=callback_message_id)
            return True
        if action in {"geoip-update", "geoip-refresh", "geoip-providers-test", "geoip-auto-update", "cert-renew"}:
            panel_action = {"geoip-update": "geoip-databases-update", "geoip-refresh": "geoip-refresh", "geoip-providers-test": "geoip-providers-test", "geoip-auto-update": "geoip-auto-update", "cert-renew": "web-cert-renew"}[action]
            results = parallel_results(panels, ("finland", "germany"), panel_action, {"finland": PANEL_TOKEN, "germany": PANEL_TOKEN})
            render_navigation(telegram, store, chat_id, f"<b>✅ Операция отправлена</b>\n" + "\n\n".join(results), maintenance_keyboard(), f"admin:{action}-done", callback_message_id=callback_message_id)
            return True
        if action == "policy-test":
            results = parallel_results(panels, ("finland", "germany"), "web-policy-test", {"finland": PANEL_TOKEN, "germany": PANEL_TOKEN})
            render_navigation(telegram, store, chat_id, "<b>🛡 Проверка web policy</b>\n\n" + "\n\n".join(results), maintenance_keyboard(), "admin:policy-test-done", callback_message_id=callback_message_id)
            return True
    if kind == "admin" and action in {"update", "update-check", "update-apply", "restart", "restart-confirm"}:
        if not is_admin:
            render_navigation(telegram, store, chat_id, "Недостаточно прав.", menu_keyboard(False), "home", callback_message_id=callback_message_id)
            return True
        if action == "update":
            blocks = []
            for key in ("finland", "germany"):
                payload = panels.request(key, "update", PANEL_TOKEN) or {}
                blocks.append(f"<b>{html.escape(str(payload.get('panel', key)))}</b>\nТекущая: <code>{html.escape(str(payload.get('current_version', payload.get('version', '—'))))}</code>\nДоступна: <code>{html.escape(str(payload.get('latest_version', payload.get('latest', '—'))))}</code>")
            keyboard = [[{"text": "🔎 Проверить обновления", "callback_data": "admin:update-check"}], [{"text": "⬆️ Применить найденное", "callback_data": "admin:update-apply"}], [{"text": "⬅️ Админка", "callback_data": "menu:admin"}]]
            render_navigation(telegram, store, chat_id, "<b>🔄 Обновления проекта</b>\n\n" + "\n\n".join(blocks), keyboard, "admin:update", callback_message_id=callback_message_id)
            return True
        if action == "update-check":
            results = [panel_text(panels, key, "update-check", PANEL_TOKEN) for key in ("finland", "germany")]
            render_navigation(telegram, store, chat_id, "<b>🔎 Проверка обновлений запущена</b>\n\n" + "\n\n".join(results), [[{"text": "🔄 Обновления", "callback_data": "admin:update"}, {"text": "⬅️ Админка", "callback_data": "menu:admin"}]], "admin:update-check", callback_message_id=callback_message_id)
            return True
        server = parts[2].lower() if len(parts) > 2 else ""
        if action == "restart":
            if server not in {"finland", "germany"}:
                return True
            render_navigation(telegram, store, chat_id, f"<b>Перезапустить {html.escape(server)}?</b>\nВсе VPN-клиенты временно потеряют соединение.", [[{"text": "✅ Подтвердить", "callback_data": f"admin:restart-confirm:{server}"}], [{"text": "Отмена", "callback_data": "menu:admin"}]], "admin:restart", callback_message_id=callback_message_id)
            return True
        if action == "restart-confirm" and server in {"finland", "germany"}:
            result = panel_text(panels, server, "restart", PANEL_TOKEN)
            render_navigation(telegram, store, chat_id, f"<b>♻️ Перезапуск отправлен</b>\n{result}", [[{"text": "⬅️ Админка", "callback_data": "menu:admin"}]], "admin:restart-done", callback_message_id=callback_message_id)
            return True
        if action == "update-apply":
            results = [panel_text(panels, key, "update-apply", PANEL_TOKEN) for key in ("finland", "germany")]
            render_navigation(telegram, store, chat_id, "<b>⬆️ Обновление запущено</b>\nОно выполняется безопасным updater-ом панели.\n\n" + "\n\n".join(results), [[{"text": "🔄 Обновления", "callback_data": "admin:update"}, {"text": "⬅️ Админка", "callback_data": "menu:admin"}]], "admin:update-apply", callback_message_id=callback_message_id)
            return True
    row = store.get(principal_id)
    tokens = {"finland": row["finland_token"] if row else None, "germany": row["germany_token"] if row else None}
    if kind == "user" and action == "request":
        if is_admin:
            render_navigation(telegram, store, chat_id, "Администратору доступ выдаётся автоматически.", menu_keyboard(True), "home", callback_message_id=callback_message_id)
            return True
        if row and (tokens["finland"] or tokens["germany"]):
            render_navigation(telegram, store, chat_id, "Доступ уже выдан. Откройте устройства или статистику.", menu_keyboard(False), "home", callback_message_id=callback_message_id)
            return True
        created = store.request_access(principal_id)
        admin_id = int(os.environ.get("ADMIN_CHAT_ID", "0"))
        if created and admin_id:
            telegram.send(admin_id, f"<b>Новая заявка на доступ</b>\nTelegram ID: <code>{principal_id}</code>\nПользователь: @{html.escape(str(row['username'] if row and row['username'] else 'без username'))}", keyboard=[[{"text": "👤 Открыть заявку", "callback_data": f"admin:request:{principal_id}"}]])
        message = "Заявка отправлена администратору. После привязки токенов здесь появятся устройства." if created else "Заявка уже ожидает обработки. Повторная отправка будет доступна позже."
        render_navigation(telegram, store, chat_id, f"<b>🔐 Доступ</b>\n{message}", [[{"text": "🔄 Проверить снова", "callback_data": "user:clients"}, {"text": "🏠 Меню", "callback_data": "menu:home"}]], "user:request", callback_message_id=callback_message_id)
        return True
    if kind == "user" and action == "add":
        if not is_admin and (not row or not (tokens["finland"] or tokens["germany"])):
            render_navigation(telegram, store, chat_id, "<b>Доступ ещё не выдан</b>\nСначала получите привязку токена панели.", menu_keyboard(False), "home", callback_message_id=callback_message_id)
            return True
        server = parts[2].lower() if len(parts) > 2 else ""
        if server not in {"finland", "germany"}:
            render_navigation(telegram, store, chat_id, "<b>➕ Новое устройство</b>\nВыберите сервер для нового профиля:", [[{"text": "🇫🇮 Финляндия", "callback_data": "user:add:finland"}, {"text": "🇩🇪 Германия", "callback_data": "user:add:germany"}], [{"text": "⬅️ Устройства", "callback_data": "user:clients"}]], "user:add", callback_message_id=callback_message_id)
            return True
        store.set_prompt(principal_id, "add_client", server)
        telegram.send(chat_id, f"<b>➕ Новое устройство · {html.escape(server)}</b>\nВведите имя профиля (латиница, цифры, <code>-</code> или <code>_</code>, до 48 символов).", force_reply=True)
        return True
    if kind == "user" and action in {"clients", "favorites", "traffic", "nettest"}:
        if not is_admin and (not row or not (tokens["finland"] or tokens["germany"])):
            render_navigation(telegram, store, chat_id, "<b>Доступ ещё не выдан</b>\nОбратитесь к администратору для привязки токена.", menu_keyboard(False), "home", callback_message_id=callback_message_id)
            return True
        if action == "nettest":
            results = parallel_results(panels, ("finland", "germany"), "nettest-ping", {key: PANEL_TOKEN if is_admin else tokens[key] for key in ("finland", "germany")})
            render_navigation(telegram, store, chat_id, "<b>🌐 Доступность панелей</b>\nПроверяется лёгкий API-запрос; это не замер RTT вашего устройства.\n\n" + "\n\n".join(results), [[{"text": "📈 Статистика", "callback_data": "user:traffic"}, {"text": "👥 Устройства", "callback_data": "user:clients"}], [{"text": "🏠 Меню", "callback_data": "menu:home"}]], "user:nettest", callback_message_id=callback_message_id)
            return True
        if action == "traffic":
            rows = []
            traffic_payloads = parallel_payloads(panels, ("finland", "germany"), "traffic", {key: PANEL_TOKEN if is_admin else tokens[key] for key in ("finland", "germany")})
            for key, payload in zip(("finland", "germany"), traffic_payloads):
                total = payload.get("total") or payload.get("current") or {}
                rx, tx = total.get("rx", total.get("download", 0)), total.get("tx", total.get("upload", 0))
                rows.append((payload, rx, tx))
            peak_values = []
            for _payload, rx, tx in rows:
                try:
                    peak_values.append(float(rx or 0) + float(tx or 0))
                except (TypeError, ValueError):
                    peak_values.append(0.0)
            peak = max(peak_values, default=0)
            blocks = [f"<b>{html.escape(str(payload.get('panel', key)))}</b>\n<code>{usage_bar(float(rx or 0) + float(tx or 0), peak)}</code>\n↓ {html.escape(format_bytes(rx))}  ·  ↑ {html.escape(format_bytes(tx))}" for (payload, rx, tx), key in zip(rows, ("finland", "germany"))]
            render_navigation(telegram, store, chat_id, "<b>📈 Статистика трафика</b>\nШкала: относительный объём между серверами.\n\n" + "\n\n".join(blocks), [[{"text": "👥 Устройства", "callback_data": "user:clients"}, {"text": "🏠 Меню", "callback_data": "menu:home"}]], "user:traffic", callback_message_id=callback_message_id)
            return True
        if action == "favorites":
            favorite_rows = store.favorites(principal_id)
            available = [(str(item["server"]), str(item["client_name"]), store.client_ref(principal_id, str(item["server"]), str(item["client_name"]))) for item in favorite_rows if str(item["server"]) in {"finland", "germany"} and str(item["client_name"]).strip()]
            try:
                page = max(1, int(parts[2])) if len(parts) > 2 else 1
            except (TypeError, ValueError):
                page = 1
            page_size = 12
            pages = max(1, (len(available) + page_size - 1) // page_size)
            page = min(page, pages)
            start = (page - 1) * page_size
            visible = available[start:start + page_size]
            text = (f"<b>⭐ Избранное</b>\nСтраница <b>{page}/{pages}</b> · всего: <b>{len(available)}</b>" if available else "<b>⭐ Избранное</b>\nДобавляйте устройства кнопкой «В избранное», чтобы быстро находить их здесь.")
            render_navigation(telegram, store, chat_id, text, clients_keyboard(visible, page=page, pages=pages, source="favorites"), f"user:favorites:{page}", callback_message_id=callback_message_id)
            return True
        available: list[tuple[str, str, str]] = []
        for key in ("finland", "germany"):
            payload = panels.request(key, "clients", PANEL_TOKEN if is_admin else tokens[key]) or {}
            for client in payload.get("clients", []):
                name = str(client.get("name") or client.get("config_name") or client.get("id") or "").strip()
                if name:
                    available.append((key, name, store.client_ref(principal_id, key, name)))
        try:
            page = max(1, int(parts[2])) if len(parts) > 2 else 1
        except (TypeError, ValueError):
            page = 1
        page_size = 12
        pages = max(1, (len(available) + page_size - 1) // page_size)
        page = min(page, pages)
        start = (page - 1) * page_size
        visible = available[start:start + page_size]
        text = (f"<b>👥 Мои устройства</b>\nВыберите устройство для QR, конфига, URI или статистики.\nСтраница <b>{page}/{pages}</b> · всего: <b>{len(available)}</b>" if available else "<b>👥 Мои устройства</b>\nПока нет доступных конфигураций.")
        render_navigation(telegram, store, chat_id, text, clients_keyboard(visible, page=page, pages=pages), f"user:clients:{page}", callback_message_id=callback_message_id)
        return True
    if kind == "client" and action in {"open", "artifact", "stats", "regenerate", "regenerate-confirm", "access-link", "toggle", "p2p-toggle", "ports-toggle", "p2p-port", "p2p-remove", "path-check", "favorite-add", "favorite-remove", "remove", "remove-confirm"}:
        if len(parts) < 3:
            return True
        ref = parts[2]
        resolved = store.resolve_client_ref(principal_id, ref)
        if not resolved:
            render_navigation(telegram, store, chat_id, "Ссылка на устройство устарела. Откройте список устройств заново.", menu_keyboard(is_admin), "home", callback_message_id=callback_message_id)
            return True
        server, name = resolved
        try:
            source_page = max(1, int(parts[4] if action == "artifact" and len(parts) > 4 else parts[3])) if len(parts) > 3 else 1
        except (TypeError, ValueError):
            source_page = 1
        source = parts[4] if action not in {"artifact"} and len(parts) > 4 else (parts[5] if action == "artifact" and len(parts) > 5 else "clients")
        back_screen = "user:favorites" if source == "favorites" else f"user:clients:{source_page}"
        if server not in {"finland", "germany"} or not name or not is_admin and not tokens.get(server):
            render_navigation(telegram, store, chat_id, "Недостаточно прав или неверная конфигурация.", menu_keyboard(is_admin), "home", callback_message_id=callback_message_id)
            return True
        token = PANEL_TOKEN if is_admin else tokens[server]
        if action == "path-check":
            if not is_admin:
                render_navigation(telegram, store, chat_id, "Недостаточно прав для проверки маршрута.", client_keyboard(server, name, ref, admin=False, favorite=store.is_favorite(principal_id, server, name), back=back_screen), f"client:path-check-denied:{ref}", callback_message_id=callback_message_id)
                return True
            result = panel_text(panels, server, "path-check", PANEL_TOKEN, value=name)
            render_navigation(telegram, store, chat_id, f"<b>🧭 Проверка пути · {html.escape(name)}</b>\n{result}", client_keyboard(server, name, ref, admin=True, favorite=store.is_favorite(principal_id, server, name), back=back_screen), f"client:path-check:{ref}", callback_message_id=callback_message_id)
            return True
        if action in {"favorite-add", "favorite-remove"}:
            enabled = action == "favorite-add"
            store.set_favorite(principal_id, server, name, enabled)
            label = "добавлено в избранное" if enabled else "удалено из избранного"
            render_navigation(telegram, store, chat_id, f"<b>⭐ Избранное</b>\nУстройство <code>{html.escape(name)}</code> {label}.", client_keyboard(server, name, ref, admin=is_admin, favorite=enabled, back=back_screen), f"client:{action}:{ref}", callback_message_id=callback_message_id)
            return True
        if action == "regenerate":
            render_navigation(telegram, store, chat_id, f"<b>Перегенерировать конфиг {html.escape(name)}?</b>\nСтарый конфиг перестанет работать до повторного скачивания.", [[{"text": "✅ Подтвердить", "callback_data": f"client:regenerate-confirm:{ref}:{source_page}"}], [{"text": "Отмена", "callback_data": f"client:open:{ref}:{source_page}"}]], f"client:regenerate:{ref}", callback_message_id=callback_message_id)
            return True
        if action == "p2p-port":
            store.set_prompt(principal_id, "p2p_port", f"{server}|{name}|{source_page}")
            telegram.send(chat_id, f"<b>🔧 Порт P2P · {html.escape(name)}</b>\nВведите TCP/UDP-порт от <code>1</code> до <code>65535</code>. Панель сама проверит доступность и применит правило.", force_reply=True)
            return True
        if action == "p2p-remove":
            store.set_prompt(principal_id, "p2p_remove", f"{server}|{name}|{source_page}")
            telegram.send(chat_id, f"<b>🗑 Удалить P2P-порт · {html.escape(name)}</b>\nВведите точный порт от <code>1</code> до <code>65535</code>. Будет удалено только это правило.", force_reply=True)
            return True
        if action == "regenerate-confirm":
            result = panel_text(panels, server, "regenerate", token, value=name)
            render_navigation(telegram, store, chat_id, f"<b>♻️ Конфиг обновлён</b>\n{result}", client_keyboard(server, name, ref, admin=is_admin), f"client:regenerate-done:{ref}", callback_message_id=callback_message_id)
            return True
        if action == "access-link":
            payload = panels.request(server, "access-link", token, value=name) or {}
            link = str(payload.get("url") or "")
            if not link.startswith(("https://", "http://")):
                render_navigation(telegram, store, chat_id, "Не удалось создать ссылку импорта. Проверьте API панели и права токена.", client_keyboard(server, name, ref, admin=is_admin), f"client:access-link-error:{ref}", callback_message_id=callback_message_id)
                return True
            ttl = int(payload.get("ttl") or 86400)
            hours = max(1, ttl // 3600)
            telegram.send(chat_id, f"<b>🔗 Одноразовая ссылка импорта</b>\nУстройство: <code>{html.escape(name)}</code>\nСрок действия: {hours} ч.\nСсылка не сохраняется ботом и станет недействительной после использования.", keyboard=[[{"text": "🔗 Открыть импорт", "url": link}], [{"text": "⬅️ К устройству", "callback_data": f"client:open:{ref}"}]])
            return True
        if action == "remove":
            render_navigation(telegram, store, chat_id, f"<b>Удалить устройство {html.escape(name)}?</b>\nДействие необратимо для этого профиля.", [[{"text": "✅ Подтвердить удаление", "callback_data": f"client:remove-confirm:{ref}:{source_page}"}], [{"text": "Отмена", "callback_data": f"client:open:{ref}:{source_page}"}]], f"client:remove:{ref}", callback_message_id=callback_message_id)
            return True
        if action == "remove-confirm":
            result = panel_text(panels, server, "remove", token, value=name)
            render_navigation(telegram, store, chat_id, f"<b>🗑 Устройство удалено</b>\n{result}", [[{"text": "👥 К устройствам", "callback_data": "user:clients"}, {"text": "🏠 Меню", "callback_data": "menu:home"}]], "client:remove-done", callback_message_id=callback_message_id)
            return True
        if action in {"toggle", "p2p-toggle", "ports-toggle"}:
            result = panel_text(panels, server, f"{action}", token, value=name)
            render_navigation(telegram, store, chat_id, f"<b>⚙️ Настройка обновлена</b>\n{result}", client_keyboard(server, name, ref, admin=is_admin), f"client:{action}-done:{ref}", callback_message_id=callback_message_id)
            return True
        if action == "artifact":
            kind_name = parts[3].lower() if len(parts) > 3 else "config"
            artifact = panels.artifact(server, name, kind_name, token)
            if artifact is None:
                telegram.send(chat_id, "Не удалось получить файл. Проверьте доступность панели и права токена.", keyboard=client_keyboard(server, name, ref, admin=is_admin, favorite=store.is_favorite(principal_id, server, name), back=back_screen))
            else:
                try:
                    if kind_name == "qr":
                        telegram.send_photo(chat_id, artifact[2], artifact[0], f"📷 <b>{html.escape(name)}</b> · {server}")
                    else:
                        telegram.send_document(chat_id, artifact[2], artifact[0], f"📄 <b>{html.escape(name)}</b> · {server}")
                except (OSError, RuntimeError, ValueError):
                    telegram.send(chat_id, "Файл получен с панели, но Telegram не принял отправку. Повторите попытку.")
            return True
        payload = panels.request(server, "clients", token) or {}
        client = next((item for item in payload.get("clients", []) if str(item.get("name") or item.get("id") or item.get("config_name")) == name), None)
        if action == "stats":
            client = client or {}
            total = client.get("traffic_total") or client.get("traffic") or {}
            recent = client.get("traffic_30d") or {}
            text = (f"<b>📈 {html.escape(name)}</b>\nСервер: {html.escape(server)}\n"
                    f"Всего: ↓ {html.escape(format_bytes(total.get('rx', total.get('download', 0))))} · ↑ {html.escape(format_bytes(total.get('tx', total.get('upload', 0))))}\n"
                    f"За 30 дней: ↓ {html.escape(format_bytes(recent.get('rx', recent.get('download', 0))))} · ↑ {html.escape(format_bytes(recent.get('tx', recent.get('upload', 0))))}")
        else:
            client = client or {}
            marker = "🟢 онлайн" if client.get("online") else "⚪ не в сети"
            text = (f"<b>🛡 {html.escape(name)}</b>\n{marker}\nСервер: <code>{html.escape(server)}</code>\n"
                    f"IPv4: <code>{html.escape(str(client.get('ipv4', '—')))}</code>\n"
                    f"Последний handshake: <code>{html.escape(str(client.get('latestHandshakeAt', client.get('last_handshake', '—'))))}</code>")
        render_navigation(telegram, store, chat_id, text, client_keyboard(server, name, ref, admin=is_admin, favorite=store.is_favorite(principal_id, server, name), back=back_screen), f"client:{action}:{ref}", callback_message_id=callback_message_id)
        return True
    if kind == "server" and action in {"status", "health", "readiness", "dns", "info", "resolver", "audit", "tokens", "clients", "logs", "health-history", "latency", "provider-traffic", "geoip-status", "geoip-providers", "geoip-databases", "nettest-reports", "web-policy", "web-cert"}:
        access_row = store.get(principal_id)
        if not is_admin and not access_row or (not is_admin and not (access_row["finland_token"] or access_row["germany_token"])):
            render_navigation(telegram, store, chat_id, "<b>Доступ ещё не выдан</b>\nОбратитесь к администратору для привязки токена.", menu_keyboard(False), "home", callback_message_id=callback_message_id)
            return True
        if action not in {"status", "clients"} and not is_admin:
            render_navigation(telegram, store, chat_id, "Недостаточно прав.", menu_keyboard(False), "home", callback_message_id=callback_message_id)
            return True
        server = parts[2] if len(parts) > 2 else "all"
        keys = (server,) if server in {"finland", "germany"} else ("finland", "germany")
        row = store.get(principal_id)
        tokens = {"finland": row["finland_token"] if row else None, "germany": row["germany_token"] if row else None}
        if action == "status":
            output = "\n\n".join(compact_snapshot(payload) for payload in parallel_payloads(panels, keys, "snapshot", {key: PANEL_TOKEN if is_admin else tokens[key] for key in keys}))
        elif action == "clients":
            output = "\n\n".join(compact_clients(payload) for payload in parallel_payloads(panels, keys, "snapshot", {key: PANEL_TOKEN if is_admin else tokens[key] for key in keys}))
        else:
            output = "\n\n".join(parallel_results(panels, keys, action, {key: PANEL_TOKEN if is_admin else tokens[key] for key in keys}))
        title = {"status": "Статус", "clients": "Клиенты", "health": "Проверка", "readiness": "Готовность VPN", "dns": "DNS", "info": "Информация", "resolver": "Resolver", "audit": "Аудит", "tokens": "Токены", "logs": "Логи", "health-history": "История нагрузки", "latency": "Latency клиентов", "provider-traffic": "Provider traffic", "geoip-status": "GeoIP", "geoip-providers": "GeoIP providers", "geoip-databases": "GeoIP databases", "nettest-reports": "Nettest отчёты", "web-policy": "Web access policy", "web-cert": "TLS-сертификат"}[action]
        result_keyboard = result_navigation_keyboard(action, server, is_admin)
        render_navigation(telegram, store, chat_id, f"<b>{title}</b>\n{output[:3900]}", result_keyboard, f"server:{action}:{server}", callback_message_id=callback_message_id)
        return True
    return False


def reply_keyboard() -> list[list[str]]:
    return [["🏠 Меню", "📡 Серверы"], ["📊 Статус", "⭐ Избранное"], ["👤 Профиль", "⚙️ Админка"]]


def compact_snapshot(payload: dict[str, Any]) -> str:
    if payload.get("error"):
        return f"<b>{html.escape(str(payload.get('panel', 'panel')))}</b>: {html.escape(str(payload['error']))}"
    summary = payload.get("summary") or {}
    service = html.escape(str(payload.get("service", "unknown")))
    return (f"<b>{html.escape(str(payload.get('display_name') or payload.get('panel', 'server')))}</b> "
            f"<code>{html.escape(str(payload.get('version', '?')))}</code>\n"
            f"Сервис: <b>{service}</b> · онлайн: <b>{summary.get('online', 0)}/{summary.get('total', 0)}</b>")


def format_bytes(value: Any) -> str:
    try:
        amount = float(value or 0)
    except (TypeError, ValueError):
        return "—"
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    index = 0
    while abs(amount) >= 1024 and index < len(units) - 1:
        amount /= 1024
        index += 1
    return f"{amount:.1f} {units[index]}" if index else f"{int(amount)} B"


def format_timestamp(value: Any) -> str:
    try:
        return time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(int(value)))
    except (TypeError, ValueError, OverflowError):
        return "—"


def sparkline(values: Any, width: int = 12) -> str:
    """Render numeric telemetry as a compact Telegram-safe Unicode chart."""
    try:
        numbers = [float(value) for value in (values or []) if value is not None]
    except (TypeError, ValueError):
        return "—"
    if not numbers:
        return "—"
    if len(numbers) > width:
        step = len(numbers) / width
        numbers = [numbers[min(len(numbers) - 1, int(index * step))] for index in range(width)]
    low, high = min(numbers), max(numbers)
    glyphs = "▁▂▃▄▅▆▇█"
    if high <= low:
        return glyphs[0] * len(numbers)
    return "".join(glyphs[min(len(glyphs) - 1, int((value - low) / (high - low) * (len(glyphs) - 1)))] for value in numbers)


def usage_bar(value: Any, maximum: Any, width: int = 10) -> str:
    try:
        current, limit = max(0.0, float(value or 0)), max(0.0, float(maximum or 0))
    except (TypeError, ValueError):
        return "░" * width
    filled = 0 if limit <= 0 else min(width, round(current / limit * width))
    return "█" * filled + "░" * (width - filled)


def status_icon(value: Any) -> str:
    normalized = str(value or "unknown").lower()
    if normalized in {"ok", "active", "healthy", "ready", "up", "enabled", "running", "pass"}:
        return "✅"
    if normalized in {"warn", "warning", "degraded", "unknown", "pending"}:
        return "⚠️"
    if normalized in {"error", "failed", "inactive", "down", "critical", "fail"}:
        return "❌"
    return "◽"


def metric_line(label: str, value: Any, state: Any = None) -> str:
    suffix = f" {status_icon(state)}" if state is not None else ""
    return f"{html.escape(label)}: <b>{html.escape(str(value))}</b>{suffix}"


def format_panel_payload(payload: dict[str, Any], action: str) -> str:
    """Render API diagnostics as compact Telegram cards, never raw JSON."""
    panel = html.escape(str(payload.get("panel", "Сервер")))
    if payload.get("error"):
        return f"<b>{panel}</b>\n❌ {html.escape(str(payload['error']))}"
    lines: list[str] = [f"<b>{panel}</b>"]
    if action in {"status", "snapshot"}:
        return compact_snapshot(payload)
    if action == "health":
        lines.append(f"Общий статус: {status_icon(payload.get('status'))} <b>{html.escape(str(payload.get('status', 'unknown')))}</b>")
        cpu, memory, disk = payload.get("cpu") or {}, payload.get("memory") or {}, payload.get("disk") or {}
        load = payload.get("load") or {}
        lines.extend([metric_line("CPU", f"{cpu.get('usage_percent', '—')}%", cpu.get("status")), metric_line("RAM", f"{memory.get('used_percent', '—')}%", memory.get("status")), metric_line("Диск", f"{disk.get('used_percent', '—')}%", disk.get("status")), metric_line("Load", f"{load.get('one', '—')} / {load.get('five', '—')}", load.get("status"))])
        services = payload.get("services") or {}
        if services:
            lines.append("<b>Сервисы</b>")
            for name, service in list(services.items())[:8]:
                service = service if isinstance(service, dict) else {"status": service}
                lines.append(f"{status_icon(service.get('status'))} {html.escape(str(name))}: {html.escape(str(service.get('status', 'unknown')))}")
        network = payload.get("network") or {}
        lines.append(f"Сеть: drops {network.get('drops_delta', 0)} · errors {network.get('errors_delta', 0)}")
    elif action == "info":
        for label, key in (("Публичный IPv4", "public_ipv4"), ("Публичный IPv6", "public_ipv6"), ("VPN IPv4", "vpn_ipv4"), ("Шлюз", "vpn_gateway_ipv4"), ("DNS", "dns_resolver"), ("Route mode", "route_mode")):
            lines.append(metric_line(label, payload.get(key) or "—"))
    elif action == "readiness":
        lines.append(f"Готовность: {status_icon(payload.get('status'))} <b>{html.escape(str(payload.get('status', 'unknown')))}</b>")
        for section in ("kernel", "crypto", "virtualization", "ip_forwarding", "udp_buffers", "ipv6_routing", "ndp_proxy"):
            item = payload.get(section) or {}
            if isinstance(item, dict):
                detail = item.get("detail") or item.get("release") or item.get("mode") or item.get("type") or item.get("status", "unknown")
                lines.append(f"{status_icon(item.get('status'))} {html.escape(section.replace('_', ' '))}: {html.escape(str(detail))}")
    elif action in {"dns", "resolver"}:
        for label, key in (("Mode", "mode"), ("Client DNS", "client_dns"), ("Service", "adguard_service" if action == "dns" else "managed_service"), ("Port", "adguard_port" if action == "dns" else "managed_port"), ("URL", "managed_url")):
            if key in payload:
                lines.append(metric_line(label, payload.get(key) or "—"))
    elif action == "audit":
        summary = payload.get("summary") or {}
        lines.append("<b>Сводка аудита</b>")
        for label, key in (("Всего", "total"), ("Активных", "active"), ("Без назначения", "unassigned"), ("Сиротские файлы", "orphan_files"), ("Проблемы firewall", "orphan_firewall_rules")):
            lines.append(metric_line(label, summary.get(key, 0)))
        bad = [item for item in payload.get("clients", []) if str(item.get("status", "")).lower() not in {"ok", "active", "healthy", ""}]
        if bad:
            lines.append("<b>Проблемные клиенты</b>")
            lines.extend(f"⚠️ <code>{html.escape(str(item.get('config_name', '?')))}</code>: {html.escape(str(item.get('status')))}" for item in bad[:8])
    elif action == "tokens":
        users = payload.get("users") or []
        lines.append(f"Пользовательских токенов: <b>{len(users)}</b>")
        for item in users[:12]:
            clients = item.get("clients") or []
            lines.append(f"🔐 {html.escape(str(item.get('name') or 'Без имени'))} · клиентов: {len(clients)}")
    elif action == "logs":
        log_lines = payload.get("lines") or []
        lines.append("<pre>" + html.escape("\n".join(str(line) for line in log_lines[-18:]))[:3000] + "</pre>")
    elif action == "health-history":
        summary = payload.get("summary") or {}
        lines.append(f"Период: <b>{html.escape(str(payload.get('range', '1h')))}</b> · samples: <b>{summary.get('counts', {}).get('samples', 0)}</b>")
        cpu, memory, disk, load = summary.get("cpu") or {}, summary.get("memory") or {}, summary.get("disk") or {}, summary.get("load") or {}
        lines.extend([metric_line("CPU average/max", f"{cpu.get('avg', '—')}% / {cpu.get('max', '—')}%"), metric_line("RAM average/max", f"{memory.get('avg_used_percent', '—')}% / {memory.get('max_used_percent', '—')}%"), metric_line("Disk", f"{disk.get('current_used_percent', '—')}%"), metric_line("Load avg/max", f"{load.get('avg1', '—')} / {load.get('max1', '—')}")])
        series = payload.get("series") or []
        if series:
            lines.append("<b>Динамика</b>")
            lines.append(f"CPU   <code>{sparkline([item.get('cpu') for item in series])}</code>")
            lines.append(f"RAM   <code>{sparkline([item.get('memory') for item in series])}</code>")
            lines.append(f"Load  <code>{sparkline([item.get('load1') for item in series])}</code>")
        lines.append(f"События: ⚠️ {summary.get('counts', {}).get('warn', 0)} · ❌ {summary.get('counts', {}).get('critical', 0)}")
    elif action == "latency":
        overview = payload.get("overview") or payload.get("diagnostics") or {}
        lines.append(f"Активных: <b>{overview.get('active', overview.get('active_peers', 0))}</b> · reachable: <b>{overview.get('reachable', overview.get('reachable_clients', 0))}</b>")
        lines.append(f"Средний RTT: <b>{overview.get('avg_rtt_ms', '—')} ms</b> · P95: <b>{overview.get('p95_rtt_ms', '—')} ms</b>")
        clients = payload.get("clients") or {}
        if clients:
            lines.append("<b>Проблемные устройства</b>")
            problematic = [(name, item) for name, item in clients.items() if str(item.get("status", "")).lower() not in {"ok", "active", "healthy", "reachable", ""}]
            for name, item in problematic[:10]:
                lines.append(f"⚠️ <code>{html.escape(str(name))}</code> · RTT {html.escape(str(item.get('rtt_ms', '—')))} ms · {html.escape(str(item.get('status', 'unknown')))}")
            if not problematic:
                lines.append("✅ Явных проблем не обнаружено")
    elif action == "provider-traffic":
        traffic = payload.get("traffic") or {}
        quota = payload.get("quota") or {}
        remaining = payload.get("remaining") or {}
        lines.append(f"Провайдер: <b>{html.escape(str(payload.get('label') or payload.get('provider') or '—'))}</b> · {status_icon(payload.get('status'))}")
        lines.append(f"Всего: <b>{html.escape(format_bytes(traffic.get('total_bytes')))}</b> · вход: {html.escape(format_bytes(traffic.get('in_bytes')))} · выход: {html.escape(format_bytes(traffic.get('out_bytes')))}")
        if quota.get("total_bytes") is not None:
            lines.append(f"Остаток квоты: <b>{html.escape(format_bytes(remaining.get('total_bytes')))}</b> / {html.escape(format_bytes(quota.get('total_bytes')))}")
    elif action in {"geoip-status", "geoip-providers", "geoip-databases"}:
        providers = payload.get("providers") or {}
        databases = payload.get("databases") or {}
        lines.append(f"Состояние: {status_icon(payload.get('status') or payload.get('ok'))} <b>{html.escape(str(payload.get('status') or payload.get('message') or 'доступно'))}</b>")
        if providers:
            lines.append("<b>Провайдеры</b>")
            for name, item in list(providers.items())[:12]:
                item = item if isinstance(item, dict) else {"status": item}
                lines.append(f"{status_icon(item.get('status') or item.get('ok'))} {html.escape(str(name))}: {html.escape(str(item.get('status') or item.get('type') or 'configured'))}")
        if databases:
            lines.append("<b>Базы</b>")
            for name, item in list(databases.items())[:8]:
                item = item if isinstance(item, dict) else {"status": item}
                lines.append(f"{status_icon(item.get('status') or item.get('ok'))} {html.escape(str(name))}: {html.escape(str(item.get('status') or item.get('updated_at') or '—'))}")
    elif action in {"nettest-reports", "nettest-context", "nettest-ping"}:
        reports = payload.get("reports") or []
        if action == "nettest-reports":
            lines.append(f"Отчётов: <b>{len(reports)}</b>")
            for report in reports[-8:]:
                report = report if isinstance(report, dict) else {"value": report}
                lines.append(f"🧪 <code>{html.escape(str(report.get('id') or report.get('test_id') or 'report'))}</code> · {html.escape(str(report.get('status') or report.get('created_at') or 'готов'))}")
        elif action == "nettest-ping":
            lines.append(f"Доступность API: {status_icon(payload.get('ok'))} <b>{'доступно' if payload.get('ok') else 'ошибка'}</b>")
            lines.append(metric_line("Время сервера", payload.get("server_time") or "—"))
        else:
            lines.append(f"Nettest: {status_icon(payload.get('ok', True))} <b>{html.escape(str(payload.get('nettest_url') or payload.get('nettest_vpn_url') or 'доступен'))}</b>")
            for label, key in (("Макс. download", "max_download_size"), ("Макс. upload", "max_upload_size"), ("VPN URL", "nettest_vpn_url")):
                if payload.get(key) is not None:
                    lines.append(metric_line(label, payload.get(key)))
    elif action == "web-policy":
        for label, key in (("Режим", "mode"), ("Публичный listener", "public_listener"), ("Trusted proxy", "trusted_proxy"), ("Разрешённые сети", "allowed_networks")):
            if key in payload:
                value = payload.get(key)
                if isinstance(value, (list, dict)):
                    value = json.dumps(value, ensure_ascii=False, separators=(", ", ":"))
                lines.append(metric_line(label, value or "—"))
    elif action == "web-cert":
        certificate = payload.get("certificate") or payload
        if isinstance(certificate, dict):
            for label, key in (("Статус", "status"), ("Subject", "subject"), ("Issuer", "issuer"), ("Истекает", "expires_at"), ("SAN", "san")):
                if key in certificate:
                    value = certificate.get(key)
                    if isinstance(value, list):
                        value = ", ".join(str(item) for item in value)
                    lines.append(metric_line(label, value or "—", certificate.get("status") if key == "status" else None))
    else:
        if payload.get("message"):
            lines.append(html.escape(str(payload["message"])))
        elif payload.get("ok") is not None:
            lines.append(f"Результат: {status_icon(payload.get('ok'))} {html.escape(str(payload.get('ok')))}")
    return "\n".join(lines)[:4096]


def panel_text(panel: PanelManager, key: str, action: str, token: str | object | None = None, value: str = "") -> str:
    payload = panel.request(key, action, token, value)
    if payload is None:
        return f"{html.escape(key)}: API недоступен или токен не имеет права"
    return format_panel_payload(payload, action)


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


def verify_init_data(raw: str, bot_token: str, max_age: int = 86400) -> dict[str, Any]:
    """Validate Telegram Mini App initData and return the trusted user."""
    pairs = dict(parse_qsl(raw, keep_blank_values=True))
    received = pairs.pop("hash", "")
    if not received:
        raise ValueError("missing init data hash")
    check = "\n".join(f"{key}={pairs[key]}" for key in sorted(pairs))
    secret = hmac.new(b"WebAppData", bot_token.encode(), hashlib.sha256).digest()
    expected = hmac.new(secret, check.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, received):
        raise ValueError("invalid init data signature")
    try:
        auth_date = int(pairs.get("auth_date", "0"))
    except ValueError as exc:
        raise ValueError("invalid init data timestamp") from exc
    if auth_date <= 0 or time.time() - auth_date > max_age:
        raise ValueError("expired init data")
    try:
        user = json.loads(pairs.get("user", "{}"))
    except json.JSONDecodeError as exc:
        raise ValueError("invalid init data user") from exc
    if not isinstance(user, dict) or not isinstance(user.get("id"), int):
        raise ValueError("invalid init data user")
    return user


class MiniAppServer:
    """Local Mini App/API gateway, normally published through an HTTPS proxy."""

    def __init__(self, bind: str, port: int, token: str, store: Store, panels: PanelManager, telegram: Telegram | None = None) -> None:
        root = Path(__file__).resolve().parents[1] / "web"
        self.store, self.panels, self.token = store, panels, token
        store_ref, panels_ref, token_ref, telegram_ref = store, panels, token, telegram

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, fmt: str, *args: Any) -> None:
                return

            def reply(self, payload: dict[str, Any], status: int = 200) -> None:
                data = json.dumps(payload, ensure_ascii=False).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(data)

            def user(self) -> dict[str, Any]:
                return verify_init_data(self.headers.get("X-Telegram-Init-Data", ""), token_ref)

            def do_GET(self) -> None:
                if self.path in {"/", "/mini-app", "/mini-app/"}:
                    data = (root / "index.html").read_bytes()
                    self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data); return
                if self.path in {"/mini-app/app.js", "/app.js"}:
                    data = (root / "app.js").read_bytes()
                    self.send_response(200); self.send_header("Content-Type", "text/javascript; charset=utf-8"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data); return
                if self.path in {"/mini-app/style.css", "/style.css"}:
                    data = (root / "style.css").read_bytes()
                    self.send_response(200); self.send_header("Content-Type", "text/css; charset=utf-8"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data); return
                parsed = urlparse(self.path)
                if parsed.path == "/api/nettest":
                    try:
                        user = self.user(); query = parse_qs(parsed.query)
                        server = str((query.get("server") or [""])[0]).lower()
                        kind = str((query.get("kind") or [""])[0]).lower()
                        test_id = str((query.get("test_id") or [""])[0])[:64]
                        if server not in {"finland", "germany"} or kind not in {"context", "ping", "download"} or (kind == "download" and not test_id) or (test_id and not re.fullmatch(r"[A-Za-z0-9_.-]+", test_id)):
                            raise ValueError("invalid nettest request")
                        row = store_ref.get(int(user["id"])); is_admin = int(user["id"]) == int(os.environ.get("ADMIN_CHAT_ID", "0"))
                        token = PANEL_TOKEN if is_admin else (row[f"{server}_token"] if row else "")
                        if not token:
                            self.reply({"error": "panel_not_bound"}, 403); return
                        try:
                            size = int((query.get("size") or ["1000000"])[0])
                        except (TypeError, ValueError):
                            raise ValueError("invalid nettest size")
                        result = panels_ref.nettest(server, kind, token, test_id=test_id, size=size)
                        if result is None:
                            self.reply({"error": "nettest_unavailable"}, 502); return
                        if isinstance(result, tuple):
                            content, content_type = result
                            self.send_response(200); self.send_header("Content-Type", content_type); self.send_header("Cache-Control", "no-store"); self.send_header("Content-Length", str(len(content))); self.end_headers(); self.wfile.write(content); return
                        self.reply(result)
                    except ValueError as exc:
                        unauthorized = "init data" in str(exc).lower()
                        self.reply({"error": "unauthorized" if unauthorized else "bad_request"}, 401 if unauthorized else 400)
                    except OSError:
                        self.reply({"error": "backend_unavailable"}, 503)
                    return
                if parsed.path == "/api/artifact":
                    try:
                        user = self.user()
                        query = parse_qs(parsed.query)
                        server = str((query.get("server") or [""])[0]).lower()
                        name = str((query.get("name") or [""])[0]).strip()
                        kind = str((query.get("kind") or [""])[0]).lower()
                        if server not in {"finland", "germany"} or not name or kind not in {"config", "qr", "uri"}:
                            raise ValueError("invalid artifact")
                        row = store_ref.get(int(user["id"]))
                        is_admin = int(user["id"]) == int(os.environ.get("ADMIN_CHAT_ID", "0"))
                        token = PANEL_TOKEN if is_admin else (row[f"{server}_token"] if row else "")
                        if not token:
                            self.reply({"error": "panel_not_bound"}, 403)
                            return
                        artifact = panels_ref.artifact(server, name, kind, token)
                        if artifact is None:
                            self.reply({"error": "artifact_not_found"}, 404)
                            return
                        content, content_type, filename = artifact
                        self.send_response(200)
                        self.send_header("Content-Type", content_type)
                        self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
                        self.send_header("Cache-Control", "no-store")
                        self.send_header("Content-Length", str(len(content)))
                        self.end_headers()
                        self.wfile.write(content)
                    except ValueError:
                        self.reply({"error": "bad_request"}, 400)
                    except OSError:
                        self.reply({"error": "backend_unavailable"}, 503)
                    return
                if self.path != "/api/session":
                    self.reply({"error": "not_found"}, 404); return
                try:
                    user = self.user(); row = store_ref.get(int(user["id"])); is_admin = int(user["id"]) == int(os.environ.get("ADMIN_CHAT_ID", "0"))
                    if not is_admin and (not row or not (row["finland_token"] or row["germany_token"])):
                        self.reply({"user": {"id": user["id"], "username": user.get("username", "")}, "role": "pending", "access_pending": True, "panels": {}})
                        return
                    tokens = {"finland": row["finland_token"] if row and not is_admin else None, "germany": row["germany_token"] if row and not is_admin else None}
                    if is_admin:
                        tokens = {"finland": None, "germany": None}
                    def fetch(key: str) -> dict[str, Any]:
                        payload = panels_ref.request(key, "snapshot", PANEL_TOKEN if is_admin else tokens[key])
                        return payload or {"panel": key, "error": "panel_unavailable"}
                    with ThreadPoolExecutor(max_workers=2) as pool:
                        snapshots = {key: pool.submit(fetch, key) for key in ("finland", "germany")}
                    self.reply({"user": {"id": user["id"], "username": user.get("username", "")}, "role": "super" if is_admin else "user", "panels": {key: future.result() for key, future in snapshots.items()}})
                except (ValueError, RuntimeError, OSError) as exc:
                    self.reply({"error": "unauthorized" if isinstance(exc, ValueError) else "backend_unavailable"}, 401 if isinstance(exc, ValueError) else 503)

            def do_POST(self) -> None:
                parsed = urlparse(self.path)
                if parsed.path == "/api/nettest":
                    try:
                        user = self.user(); query = parse_qs(parsed.query)
                        server = str((query.get("server") or [""])[0]).lower()
                        kind = str((query.get("kind") or [""])[0]).lower()
                        test_id = str((query.get("test_id") or [""])[0])[:64]
                        if server not in {"finland", "germany"} or kind not in {"upload", "report", "cancel"} or not test_id or not re.fullmatch(r"[A-Za-z0-9_.-]+", test_id):
                            raise ValueError("invalid nettest request")
                        row = store_ref.get(int(user["id"])); is_admin = int(user["id"]) == int(os.environ.get("ADMIN_CHAT_ID", "0"))
                        token = PANEL_TOKEN if is_admin else (row[f"{server}_token"] if row else "")
                        if not token:
                            self.reply({"error": "panel_not_bound"}, 403); return
                        try:
                            size = int(self.headers.get("Content-Length", "0") or 0)
                        except (TypeError, ValueError):
                            raise ValueError("invalid nettest payload")
                        if kind == "upload":
                            if size <= 0 or size > 4_000_000:
                                raise ValueError("nettest upload is limited to 4 MiB")
                            body = self.rfile.read(size)
                            result = panels_ref.nettest(server, kind, token, test_id=test_id, body=body)
                        else:
                            if size <= 0 or size > 32_000:
                                raise ValueError("invalid nettest report")
                            payload = json.loads(self.rfile.read(size))
                            if not isinstance(payload, dict):
                                raise ValueError("invalid nettest report")
                            payload["test_id"] = test_id
                            result = panels_ref.nettest(server, kind, token, test_id=test_id, payload=payload)
                        if result is None:
                            self.reply({"error": "nettest_unavailable"}, 502); return
                        self.reply(result if isinstance(result, dict) else {"ok": True})
                    except (ValueError, json.JSONDecodeError) as exc:
                        unauthorized = "init data" in str(exc).lower()
                        self.reply({"error": "unauthorized" if unauthorized else "bad_request"}, 401 if unauthorized else 400)
                    except OSError:
                        self.reply({"error": "backend_unavailable"}, 503)
                    return
                if self.path == "/api/access-request":
                    try:
                        user = self.user()
                        user_id = int(user["id"])
                        is_admin = user_id == int(os.environ.get("ADMIN_CHAT_ID", "0"))
                        if is_admin:
                            self.reply({"ok": True, "status": "approved"})
                            return
                        row = store_ref.get(user_id)
                        if row and (row["finland_token"] or row["germany_token"]):
                            self.reply({"ok": True, "status": "approved"})
                            return
                        created = store_ref.request_access(user_id)
                        admin_id = int(os.environ.get("ADMIN_CHAT_ID", "0"))
                        if created and admin_id and telegram_ref is not None:
                            try:
                                telegram_ref.send(admin_id, f"<b>Новая заявка на доступ</b>\nTelegram ID: <code>{user_id}</code>\nПользователь: @{html.escape(str(user.get('username') or 'без username'))}", keyboard=[[{"text": "👤 Открыть заявку", "callback_data": f"admin:request:{user_id}"}]])
                            except (OSError, RuntimeError, ValueError):
                                LOG.info("Mini App access request notification failed user=%s", user_id)
                        self.reply({"ok": True, "status": "pending", "created": created})
                    except ValueError:
                        self.reply({"error": "unauthorized"}, 401)
                    except OSError:
                        self.reply({"error": "backend_unavailable"}, 503)
                    return
                if self.path != "/api/action":
                    self.reply({"error": "not_found"}, 404)
                    return
                try:
                    user = self.user()
                    size = int(self.headers.get("Content-Length", "0"))
                    if size <= 0 or size > 64_000:
                        raise ValueError("invalid request size")
                    request = json.loads(self.rfile.read(size))
                    if not isinstance(request, dict):
                        raise ValueError("invalid request")
                    action = str(request.get("action", "")).strip().lower()
                    server = str(request.get("server", "")).strip().lower()
                    if server not in {"finland", "germany"}:
                        raise ValueError("invalid server")
                    # User-bound tokens are intentionally limited to the two
                    # read-only data views. Diagnostics, logs, token lists and
                    # mutations require the administrator identity below.
                    read_actions = {"status", "snapshot", "clients", "nettest-ping", "nettest-context", "regenerate", "access-link", "client-toggle", "p2p-toggle", "ports-toggle", "p2p-add", "remove"}
                    admin_actions = read_actions | {"path-check", "web-policy-test", "restart", "add", "remove", "regenerate", "health", "health-history", "latency", "provider-traffic", "geoip-status", "geoip-providers", "geoip-databases", "nettest-reports", "web-policy", "web-cert", "update", "update-check", "update-apply"}
                    admin_id = int(os.environ.get("ADMIN_CHAT_ID", "0"))
                    is_admin = int(user["id"]) == admin_id
                    if action not in (admin_actions if is_admin else read_actions):
                        self.reply({"error": "forbidden"}, 403)
                        return
                    row = store_ref.get(int(user["id"]))
                    token = PANEL_TOKEN if is_admin else (row[f"{server}_token"] if row else "")
                    if not is_admin and not token:
                        self.reply({"error": "panel_not_bound", "server": server}, 403)
                        return
                    value = str(request.get("name", "")).strip()
                    extra = {"port": request.get("port")} if action == "p2p-add" else None
                    payload = panels_ref.request(server, action, token or None, value, extra=extra)
                    if payload is None:
                        self.reply({"error": "panel_api_unauthorized", "server": server}, 502)
                        return
                    self.reply(payload)
                except (ValueError, json.JSONDecodeError, KeyError, TypeError) as exc:
                    self.reply({"error": "unauthorized" if isinstance(exc, ValueError) and "init data" in str(exc) else "bad_request"}, 401 if isinstance(exc, ValueError) and "init data" in str(exc) else 400)
                except OSError:
                    self.reply({"error": "backend_unavailable"}, 503)

        self.server = ThreadingHTTPServer((bind, port), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, name="mini-app-api", daemon=True)

    def start(self) -> None:
        self.thread.start()

    def close(self) -> None:
        self.server.shutdown()


class WebhookReceiver:
    """Small stdlib webhook ingress; a reverse proxy provides public TLS."""

    def __init__(self, bind: str, port: int, secret: str) -> None:
        updates: queue.Queue[dict[str, Any]] = queue.Queue(maxsize=256)
        self.updates = updates
        expected = secret

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, fmt: str, *args: Any) -> None:
                return

            def do_POST(self) -> None:
                if self.path != "/telegram/webhook" or self.headers.get("X-Telegram-Bot-Api-Secret-Token", "") != expected:
                    self.send_response(404)
                    self.end_headers()
                    return
                try:
                    size = min(int(self.headers.get("Content-Length", "0")), 1_000_000)
                    payload = json.loads(self.rfile.read(size))
                    if not isinstance(payload, dict):
                        raise ValueError("invalid update")
                    updates.put_nowait(payload)
                except (ValueError, queue.Full, json.JSONDecodeError):
                    self.send_response(400)
                    self.end_headers()
                    return
                self.send_response(200)
                self.end_headers()

        self.server = ThreadingHTTPServer((bind, port), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, name="telegram-webhook", daemon=True)

    def start(self) -> None:
        self.thread.start()

    def get(self, timeout: float = 25) -> dict[str, Any] | None:
        try:
            return self.updates.get(timeout=timeout)
        except queue.Empty:
            return None

    def close(self) -> None:
        self.server.shutdown()


def main() -> None:
    logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(message)s")
    settings = Settings.from_env()
    store = Store(settings.db_path)
    telegram = Telegram(settings)
    try:
        telegram.configure_profile(settings.mini_app_url, settings.admin_chat_id)
    except (OSError, RuntimeError, ValueError) as exc:
        LOG.warning("Telegram profile configuration failed error=%s", type(exc).__name__)
    manager = ServerManager()
    tunnels = TunnelManager(manager, enabled=os.getenv("PANEL_TUNNELS_ENABLED", "1").lower() not in {"0", "false", "no"})
    panels = PanelManager(settings.panels_path)
    mini_app = MiniAppServer(settings.mini_app_bind, settings.mini_app_port, settings.token, store, panels, telegram)
    mini_app.start()
    LOG.info("Mini App/API gateway listening bind=%s port=%s", settings.mini_app_bind, settings.mini_app_port)
    webhook = None
    allowed_updates = ["message", "callback_query"]
    if settings.webhook_url:
        if not settings.webhook_secret:
            raise RuntimeError("WEBHOOK_SECRET is required when WEBHOOK_URL is set")
        webhook = WebhookReceiver(settings.webhook_bind, settings.webhook_port, settings.webhook_secret)
        webhook.start()
        telegram.set_webhook(settings.webhook_url + "/telegram/webhook", settings.webhook_secret, allowed_updates)
        LOG.info("Telegram webhook enabled url=%s", settings.webhook_url)
    offset = 0
    LOG.info("GaulleBot started")
    while True:
        try:
            tunnels.ensure()
            if webhook is not None:
                update = webhook.get(settings.poll_timeout)
                updates = [update] if update else []
            else:
                updates = telegram.call("getUpdates", offset=offset, timeout=settings.poll_timeout, allowed_updates=json.dumps(allowed_updates))
            for update in updates:
                offset = max(offset, int(update["update_id"]) + 1)
                callback = update.get("callback_query") or {}
                message = update.get("message") or callback.get("message") or {}
                chat = message.get("chat") or {}
                # In a callback update, message.from is the bot itself;
                # authorization must use callback.from (the clicking user).
                sender = (callback.get("from") if callback else message.get("from")) or {}
                chat_id = int(chat.get("id", 0))
                actor_id = int(sender.get("id", 0) or 0)
                if actor_id:
                    store.touch(actor_id, str(sender.get("username", "")), str(sender.get("first_name", "")))
                command = (message.get("text") or callback.get("data") or "").strip()
                reply_action = {"🏠 Меню": "menu:home", "📡 Серверы": "menu:servers", "📊 Статус": "server:status:all", "👥 Мои устройства": "user:clients", "📈 Статистика": "user:traffic", "⭐ Избранное": "user:favorites", "👤 Профиль": "menu:profile", "⚙️ Админка": "menu:admin"}.get(command)
                command = reply_action or command
                if callback:
                    callback_id = str(callback.get("id", ""))
                    try:
                        telegram.answer_callback(callback_id, "Открываю…")
                    except (OSError, RuntimeError, ValueError) as exc:
                        LOG.warning("callback acknowledgement failed id=%s error=%s", callback_id[:12], type(exc).__name__)
                    command = callback_command(command)
                    LOG.info("callback received chat=%s action=%s", chat_id, command)
                is_admin = actor_id == settings.admin_chat_id
                if not callback and not reply_action and actor_id and not command.startswith("/"):
                    prompt = store.prompt(actor_id)
                    if prompt and prompt["action"] == "add_client":
                        candidate = command.strip()
                        prompt_server = str(prompt["server"]).lower()
                        prompt_row = store.get(actor_id)
                        prompt_token = PANEL_TOKEN if is_admin else (prompt_row[f"{prompt_server}_token"] if prompt_row and prompt_server in {"finland", "germany"} else "")
                        if prompt_server not in {"finland", "germany"} or not prompt_token or not candidate or len(candidate) > 48 or not all(char.isalnum() or char in "_-" for char in candidate):
                            telegram.send(chat_id, "Имя клиента некорректно. Используйте латиницу, цифры, <code>-</code> или <code>_</code> (до 48 символов). Повторите ввод.", force_reply=True)
                            continue
                        result = panel_text(panels, prompt_server, "add", prompt_token, value=candidate)
                        store.clear_prompt(actor_id)
                        keyboard = admin_keyboard() if is_admin else menu_keyboard(False)
                        render_navigation(telegram, store, chat_id, f"<b>✅ Клиент создан</b>\n{result}", keyboard, "client:add-done", reply=True)
                        continue
                    if prompt and prompt["action"] in {"p2p_port", "p2p_remove"}:
                        prompt_parts = str(prompt["server"]).split("|", 2)
                        prompt_server, prompt_name = (prompt_parts + ["", ""])[:2]
                        try:
                            source_page = max(1, int(prompt_parts[2])) if len(prompt_parts) > 2 else 1
                            port = int(command.strip())
                        except (TypeError, ValueError):
                            source_page, port = 1, 0
                        prompt_row = store.get(actor_id)
                        prompt_token = PANEL_TOKEN if is_admin else (prompt_row[f"{prompt_server}_token"] if prompt_row and prompt_server in {"finland", "germany"} else "")
                        if prompt_server not in {"finland", "germany"} or not prompt_name or not prompt_token or not 1 <= port <= 65535:
                            telegram.send(chat_id, "Порт должен быть целым числом от 1 до 65535. Повторите ввод.", force_reply=True)
                            continue
                        panel_action = "p2p-add" if prompt["action"] == "p2p_port" else "p2p-remove"
                        result = panel_text(panels, prompt_server, panel_action, prompt_token, value=prompt_name, extra={"port": port})
                        store.clear_prompt(actor_id)
                        ref = store.client_ref(actor_id, prompt_server, prompt_name)
                        title = "Порт P2P добавлен" if panel_action == "p2p-add" else "Порт P2P удалён"
                        render_navigation(telegram, store, chat_id, f"<b>✅ {title}</b>\n{result}", client_keyboard(prompt_server, prompt_name, ref, admin=is_admin, back=f"user:clients:{source_page}"), f"client:p2p-port-done:{ref}", reply=True)
                        continue
                if not command.startswith("/"):
                    continue
                parts = command.split()
                name = parts[0].split("@", 1)[0].lower()
                if callback and handle_navigation(telegram, store, panels, chat_id, is_admin, str(callback.get("data", "")), actor_id=actor_id, callback_message_id=int((callback.get("message") or {}).get("message_id", 0) or 0)):
                    continue
                if reply_action and handle_navigation(telegram, store, panels, chat_id, is_admin, reply_action, actor_id=actor_id):
                    continue
                try:
                    def snapshot_text(key: str, token: str | None = None, clients: bool = False) -> str:
                        payload = panels.request(key, "snapshot", PANEL_TOKEN if is_admin and token is None else token)
                        if payload is not None:
                            return compact_clients(payload) if clients else compact_snapshot(payload)
                        return server_result(panels, key, "status", token)

                    if name == "/start":
                        render_navigation(telegram, store, chat_id, "<b>GaulleBot</b>\nУправление VPN-серверами без ручного ввода команд.", menu_keyboard(is_admin), "home")
                    elif name == "/help":
                        telegram.send(chat_id, help_text(is_admin), keyboard=menu_keyboard(is_admin), reply_keyboard=reply_keyboard())
                    elif name == "/menu":
                        render_navigation(telegram, store, chat_id, "<b>Главное меню</b>\nВыберите нужное действие:", menu_keyboard(is_admin), "home", reply=True)
                    elif name == "/admin" and is_admin:
                        render_navigation(telegram, store, chat_id, "<b>Администрирование</b>\nДиагностика и служебные действия:", admin_keyboard(), "admin", reply=True)
                    elif name == "/restart" and len(parts) == 1:
                        render_navigation(telegram, store, chat_id, "<b>Главное меню восстановлено</b>", menu_keyboard(is_admin), "home", reply=True)
                    elif name == "/me":
                        row = store.get(actor_id)
                        telegram.send(chat_id, "Привязка отсутствует." if row is None else f"<b>Ваш профиль</b>\nTelegram ID: <code>{actor_id}</code>\nFinland: {'✅' if row['finland_token'] else '—'}\nGermany: {'✅' if row['germany_token'] else '—'}")
                    elif name == "/servers":
                        row = store.get(actor_id)
                        if not is_admin and not row or (not is_admin and not (row["finland_token"] or row["germany_token"])):
                            render_navigation(telegram, store, chat_id, "<b>Доступ ещё не выдан</b>\nОбратитесь к администратору для привязки токена.", menu_keyboard(False), "home", reply=True)
                            continue
                        tokens = {"finland": row["finland_token"] if row else None, "germany": row["germany_token"] if row else None}
                        telegram.send(chat_id, "\n\n".join(snapshot_text(key, tokens[key]) for key in ("finland", "germany")))
                    elif not is_admin and name not in {"/clients"}:
                        telegram.send(chat_id, "Недостаточно прав. Обратитесь к администратору.")
                    elif name in {"/status", "/health"}:
                        if name == "/status":
                            telegram.send(chat_id, "\n\n".join(snapshot_text(key) for key in ("finland", "germany")))
                        else:
                            telegram.send(chat_id, "\n\n".join(parallel_results(panels, ("finland", "germany"), "health", {"finland": PANEL_TOKEN, "germany": PANEL_TOKEN})))
                    elif name in {"/info", "/readiness", "/dns", "/resolver", "/audit", "/tokens", "/history", "/latency", "/provider"}:
                        action = {"/history": "health-history", "/provider": "provider-traffic"}.get(name, name[1:])
                        raw = "\n\n".join(parallel_results(panels, ("finland", "germany"), action, {"finland": PANEL_TOKEN, "germany": PANEL_TOKEN}))
                        telegram.send(chat_id, raw[:4096])
                    elif name == "/restart" and len(parts) == 2:
                        telegram.send(chat_id, server_result(panels, parts[1].lower(), "restart", PANEL_TOKEN))
                    elif name in {"/add", "/remove", "/regenerate"} and len(parts) == 3:
                        action = name[1:]
                        telegram.send(chat_id, server_result(panels, parts[1].lower(), action, PANEL_TOKEN, value=parts[2]))
                    elif name == "/bind" and len(parts) == 4:
                        store.bind(int(parts[1]), str(sender.get("username", "")), str(sender.get("first_name", "")), parts[2], parts[3])
                        telegram.send(chat_id, "Привязка сохранена.")
                    elif name == "/users":
                        rows = store.all()
                        telegram.send(chat_id, "\n".join(f"<code>{r['telegram_id']}</code> @{html.escape(r['username'] or '-')} fin={'✅' if r['finland_token'] else '—'} ger={'✅' if r['germany_token'] else '—'}" for r in rows) or "Пользователей пока нет.")
                    elif name == "/clients":
                        row = store.get(actor_id)
                        if not is_admin and (not row or not (row["finland_token"] or row["germany_token"])):
                            render_navigation(telegram, store, chat_id, "<b>Доступ ещё не выдан</b>\nОбратитесь к администратору для привязки токена.", menu_keyboard(False), "home", reply=True)
                            continue
                        keys = (parts[1].lower(),) if len(parts) == 2 and parts[1].lower() in {"finland", "germany"} else ("finland", "germany")
                        tokens = {"finland": row["finland_token"] if row else None, "germany": row["germany_token"] if row else None}
                        telegram.send(chat_id, "\n\n".join(snapshot_text(key, tokens[key], clients=True) for key in keys))
                    elif name == "/logs":
                        keys = (parts[1].lower(),) if len(parts) == 2 and parts[1].lower() in {"finland", "germany"} else ("finland", "germany")
                        telegram.send(chat_id, "\n\n".join(parallel_results(panels, keys, "logs")))
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
