#!/usr/bin/env python3
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import shlex
import ssl
import subprocess
import threading
import time
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

AWG_DIR = Path(os.environ.get("AWG_DIR", "/root/awg"))
WEB_DIR = AWG_DIR / "web"
MANAGE = AWG_DIR / "manage_amneziawg.sh"
SERVER_CONF = Path(os.environ.get("SERVER_CONF_FILE", "/etc/amnezia/amneziawg/awg0.conf"))
TOKEN_FILE = WEB_DIR / "tokens.json"
TRAFFIC_FILE = WEB_DIR / "traffic_history.json"
LEGACY_TOKEN_FILE = WEB_DIR / "auth_token"
NAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")
TOKEN_HASH_RE = re.compile(r"^[0-9a-f]{64}$")
RATE = {}
TOKENS_LOCK = threading.Lock()
TRAFFIC_LOCK = threading.Lock()


def run_manage(*args, timeout=60):
    env = os.environ.copy()
    env["AWG_YES"] = "1"
    return subprocess.run(
        ["/bin/bash", str(MANAGE), "--yes", *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        env=env,
    )


def token_hash(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def write_tokens(data):
    WEB_DIR.mkdir(parents=True, exist_ok=True)
    clean = {
        "super_token_hash": data["super_token_hash"],
        "users": data.get("users", {}),
    }
    tmp = TOKEN_FILE.with_name(f"{TOKEN_FILE.name}.tmp.{os.getpid()}")
    tmp.write_text(json.dumps(clean, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, TOKEN_FILE)
    os.chmod(TOKEN_FILE, 0o600)


def load_traffic_history():
    if not TRAFFIC_FILE.exists():
        return {"last": {}, "days": {}}
    try:
        data = json.loads(TRAFFIC_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {"last": {}, "days": {}}
    if not isinstance(data, dict):
        return {"last": {}, "days": {}}
    last = data.get("last") if isinstance(data.get("last"), dict) else {}
    days = data.get("days") if isinstance(data.get("days"), dict) else {}
    return {"last": last, "days": days}


def write_traffic_history(data):
    WEB_DIR.mkdir(parents=True, exist_ok=True)
    tmp = TRAFFIC_FILE.with_name(f"{TRAFFIC_FILE.name}.tmp.{os.getpid()}")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, TRAFFIC_FILE)
    os.chmod(TRAFFIC_FILE, 0o600)


def update_traffic_history(rows):
    today = time.strftime("%Y-%m-%d", time.localtime())
    cutoff = time.time() - 29 * 86400
    keep_days = {
        time.strftime("%Y-%m-%d", time.localtime(cutoff + offset * 86400))
        for offset in range(30)
    }
    with TRAFFIC_LOCK:
        data = load_traffic_history()
        last = data.setdefault("last", {})
        days = data.setdefault("days", {})
        day = days.setdefault(today, {})
        changed = False
        for row in rows:
            name = str(row.get("name", ""))
            if not NAME_RE.fullmatch(name):
                continue
            rx = max(0, int(row.get("rx") or 0))
            tx = max(0, int(row.get("tx") or 0))
            prev = last.get(name) if isinstance(last.get(name), dict) else None
            if prev is not None:
                rx_delta = max(0, rx - int(prev.get("rx") or 0))
                tx_delta = max(0, tx - int(prev.get("tx") or 0))
                if rx_delta or tx_delta:
                    entry = day.setdefault(name, {"rx": 0, "tx": 0})
                    entry["rx"] = int(entry.get("rx") or 0) + rx_delta
                    entry["tx"] = int(entry.get("tx") or 0) + tx_delta
                    changed = True
            if last.get(name) != {"rx": rx, "tx": tx}:
                last[name] = {"rx": rx, "tx": tx}
                changed = True
        for date in list(days):
            if date not in keep_days:
                del days[date]
                changed = True
        if changed:
            write_traffic_history(data)


def traffic_summary(auth, stats=None):
    stats = stats or client_stats_map()
    if Handler.is_super(auth):
        allowed = None
    else:
        allowed = set(auth.get("clients") or [])
    rows = [row for row in stats.values() if allowed is None or row.get("name") in allowed]
    current = {
        "rx": sum(max(0, int(row.get("rx") or 0)) for row in rows),
        "tx": sum(max(0, int(row.get("tx") or 0)) for row in rows),
    }
    history = load_traffic_history()
    days = []
    for offset in range(29, -1, -1):
        date = time.strftime("%Y-%m-%d", time.localtime(time.time() - offset * 86400))
        day_rows = history.get("days", {}).get(date, {})
        rx = tx = 0
        if isinstance(day_rows, dict):
            for name, values in day_rows.items():
                if allowed is not None and name not in allowed:
                    continue
                if isinstance(values, dict):
                    rx += max(0, int(values.get("rx") or 0))
                    tx += max(0, int(values.get("tx") or 0))
        days.append({"date": date, "rx": rx, "tx": tx, "total": rx + tx})
    last_30d = {"rx": sum(day["rx"] for day in days), "tx": sum(day["tx"] for day in days)}
    return {
        "current": {**current, "total": current["rx"] + current["tx"]},
        "last_30d": {**last_30d, "total": last_30d["rx"] + last_30d["tx"]},
        "days": days,
    }


def clean_client_list(value):
    if not isinstance(value, list):
        return []
    out, seen = [], set()
    for item in value:
        name = str(item)
        if NAME_RE.fullmatch(name) and name not in seen:
            out.append(name)
            seen.add(name)
    return out


def load_tokens():
    data = {}
    if TOKEN_FILE.exists():
        try:
            data = json.loads(TOKEN_FILE.read_text(encoding="utf-8"))
        except Exception:
            data = {}
    if not isinstance(data, dict):
        data = {}

    super_hash = data.get("super_token_hash") or data.get("super")
    if not isinstance(super_hash, str) or not TOKEN_HASH_RE.fullmatch(super_hash):
        legacy = LEGACY_TOKEN_FILE.read_text(errors="ignore").strip() if LEGACY_TOKEN_FILE.exists() else ""
        super_hash = token_hash(legacy) if legacy else token_hash(secrets.token_urlsafe(32))

    users = data.get("users")
    if not isinstance(users, dict):
        users = {}
    legacy_normal = data.get("normal")
    if isinstance(legacy_normal, dict):
        for value in legacy_normal.values():
            if isinstance(value, str) and TOKEN_HASH_RE.fullmatch(value):
                users.setdefault(value, [])

    clean_users = {}
    for digest, clients in users.items():
        if isinstance(digest, str) and TOKEN_HASH_RE.fullmatch(digest):
            clean_users[digest] = clean_client_list(clients)

    clean = {"super_token_hash": super_hash, "users": clean_users}
    if clean != data or not TOKEN_FILE.exists():
        write_tokens(clean)
    return clean


def authenticate(header):
    if not header.startswith("Bearer "):
        return None
    token = header.removeprefix("Bearer ").strip()
    if not token:
        return None
    digest = token_hash(token)
    data = load_tokens()
    if hmac.compare_digest(digest, data.get("super_token_hash", "")):
        return {"role": "super", "hash": digest, "clients": None}
    for user_hash, clients in data.get("users", {}).items():
        if hmac.compare_digest(digest, user_hash):
            return {"role": "user", "hash": digest, "clients": clients}
    return None


def mutate_user_clients(user_hash, client_name=None, remove=False):
    if not user_hash or not client_name:
        return
    with TOKENS_LOCK:
        data = load_tokens()
        users = data.setdefault("users", {})
        clients = clean_client_list(users.get(user_hash, []))
        if remove:
            clients = [name for name in clients if name != client_name]
        elif client_name not in clients:
            clients.append(client_name)
        users[user_hash] = clients
        write_tokens(data)


def remove_client_from_all_tokens(client_name):
    with TOKENS_LOCK:
        data = load_tokens()
        changed = False
        for user_hash, clients in list(data.get("users", {}).items()):
            clean = [name for name in clean_client_list(clients) if name != client_name]
            if clean != clients:
                data["users"][user_hash] = clean
                changed = True
        if changed:
            write_tokens(data)


def parse_config():
    cfg = AWG_DIR / "awgsetup_cfg.init"
    out = {
        "AWG_DNS_MODE": "system",
        "AWG_CUSTOM_DNS": "1.1.1.1",
        "AWG_ADGUARD_ENABLED": "0",
        "AWG_ADGUARD_PORT": "3000",
        "AWG_IPV6_ENABLED": "0",
        "AWG_IPV6_SUBNET": "",
        "AWG_SERVER_NAME": "MyVPN",
    }
    if not cfg.exists():
        return out
    for raw in cfg.read_text(errors="ignore").splitlines():
        line = raw.removeprefix("export ").strip()
        if "=" not in line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        if key not in out:
            continue
        try:
            parsed = shlex.split(value, posix=True)
            out[key] = parsed[0] if parsed else ""
        except ValueError:
            out[key] = value.strip().strip("'\"")
    return out


def parse_peers():
    peers, cur = [], None
    if not SERVER_CONF.exists():
        return peers
    for line in SERVER_CONF.read_text(errors="ignore").splitlines():
        if line in {"[Peer]", "# [Peer]"}:
            if cur:
                peers.append(cur)
            cur = {
                "name": "",
                "public_key": "",
                "ipv4": "",
                "ipv6": "",
                "p2p_ports": [],
                "disabled": line == "# [Peer]",
            }
        elif cur is not None and line.startswith("#_Name = "):
            cur["name"] = line.split("=", 1)[1].strip()
        elif cur is not None and line.startswith("#_P2PPorts"):
            value = line.split("=", 1)[1] if "=" in line else ""
            cur["p2p_ports"] = [int(x) for x in re.findall(r"\d+", value)]
        elif cur is not None and re.match(r"^#?\s*PublicKey", line):
            cur["public_key"] = line.split("=", 1)[1].strip() if "=" in line else ""
            cur["disabled"] = cur["disabled"] or line.startswith("#")
        elif cur is not None and re.match(r"^#?\s*AllowedIPs", line):
            value = line.split("=", 1)[1] if "=" in line else ""
            m4 = re.search(r"(\d+\.\d+\.\d+\.\d+)/32", value)
            m6 = re.search(r"([0-9A-Fa-f:]+)/128", value)
            if m4:
                cur["ipv4"] = m4.group(1)
            if m6:
                cur["ipv6"] = m6.group(1)
    if cur:
        peers.append(cur)
    return [p for p in peers if p.get("name")]


def dns_status():
    cfg = parse_config()
    mode = cfg["AWG_DNS_MODE"]
    client_dns = cfg["AWG_CUSTOM_DNS"] if mode == "custom" else "1.1.1.1"
    if mode == "adguard":
        client_dns = "10.9.9.1"
        if cfg["AWG_IPV6_ENABLED"] == "1" and cfg["AWG_IPV6_SUBNET"]:
            try:
                client_dns += f", {ipaddress.ip_network(cfg['AWG_IPV6_SUBNET'], strict=False).network_address + 1}"
            except ValueError:
                pass
    active = subprocess.run(
        ["systemctl", "is-active", "AdGuardHome.service"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    ).stdout.strip()
    return {
        "mode": mode,
        "client_dns": client_dns,
        "adguard_enabled": cfg["AWG_ADGUARD_ENABLED"] == "1",
        "adguard_service": active or "unknown",
        "adguard_port": cfg["AWG_ADGUARD_PORT"],
    }


def safe_name(name):
    if not NAME_RE.fullmatch(name or ""):
        raise ValueError("invalid client name")
    return name


def safe_token_hash(value):
    if not TOKEN_HASH_RE.fullmatch(value or ""):
        raise ValueError("invalid token hash")
    return value


def require_server_name(name):
    if not isinstance(name, str) or not name.strip() or "\n" in name or "\r" in name or len(name) > 128:
        raise ValueError("invalid server name")
    return name


def client_stats_map():
    p = run_manage("--json", "stats", timeout=20)
    if p.returncode != 0:
        return {}
    raw_out = p.stdout or ""
    rows = []
    for line in raw_out.splitlines():
        candidate = line.strip()
        if not (candidate.startswith("[") or candidate.startswith("{")):
            continue
        try:
            rows = json.loads(candidate)
            break
        except json.JSONDecodeError:
            continue
    else:
        return {}
    out = {}
    iterable = rows if isinstance(rows, list) else []
    for row in iterable:
        if isinstance(row, dict) and row.get("name"):
            if "last_handshake" in row:
                row["latestHandshakeAt"] = row.get("last_handshake")
            out[row["name"]] = row
    update_traffic_history(out.values())
    return out


class Handler(SimpleHTTPRequestHandler):
    server_version = "Panel/1.0 fork delta/patchset"

    def log_message(self, fmt, *args):
        return

    def api_auth(self):
        if not self.path.startswith("/api/"):
            return {"role": "static"}
        ip = self.client_address[0]
        now = time.time()
        bucket = [t for t in RATE.get(ip, []) if now - t < 60]
        bucket.append(now)
        RATE[ip] = bucket
        if len(bucket) > 100:
            self.send_error(HTTPStatus.TOO_MANY_REQUESTS)
            return None
        auth = authenticate(self.headers.get("Authorization", ""))
        if not auth:
            self.send_error(HTTPStatus.UNAUTHORIZED)
            return None
        return auth

    @staticmethod
    def is_super(auth):
        return auth.get("role") == "super"

    def require_super(self, auth):
        if not self.is_super(auth):
            self.send_error(HTTPStatus.FORBIDDEN)
            return False
        return True

    def can_access_client(self, auth, name):
        return self.is_super(auth) or name in set(auth.get("clients") or [])

    def require_client_access(self, auth, name):
        if not self.can_access_client(auth, name):
            self.send_error(HTTPStatus.FORBIDDEN)
            return False
        return True

    def visible_peers(self, auth):
        rows = parse_peers()
        if self.is_super(auth):
            return rows
        allowed = set(auth.get("clients") or [])
        return [row for row in rows if row.get("name") in allowed]

    def send_json(self, obj, status=200):
        data = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def json_body(self):
        size = int(self.headers.get("Content-Length", "0") or 0)
        return json.loads(self.rfile.read(size).decode("utf-8")) if size else {}

    def send_file(self, path, ctype):
        if not path.exists() or not path.is_file():
            self.send_error(404)
            return
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        auth = self.api_auth()
        if auth is None:
            return
        u = urlparse(self.path)
        if auth["role"] == "static":
            self.path = "/index.html" if u.path == "/" else self.path
            return super().do_GET()

        if u.path == "/api/status":
            active = subprocess.run(
                ["systemctl", "is-active", "awg-quick@awg0"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
            ).stdout.strip()
            cfg = parse_config()
            self.send_json({
                "service": active,
                "clients": len(self.visible_peers(auth)),
                "version": "5.13.0",
                "fork": "fork delta/patchset",
                "role": "super" if self.is_super(auth) else "user",
                "server_name": cfg["AWG_SERVER_NAME"],
            })
            return
        if u.path == "/api/dns":
            self.send_json(dns_status())
            return
        if u.path == "/api/clients":
            stats = client_stats_map()
            rows = []
            for peer in self.visible_peers(auth):
                item = dict(peer)
                row_stats = stats.get(peer["name"], {})
                item["rx"] = row_stats.get("rx", 0)
                item["tx"] = row_stats.get("tx", 0)
                item["latestHandshakeAt"] = row_stats.get("latestHandshakeAt", row_stats.get("last_handshake", 0))
                endpoint = row_stats.get("endpoint", "")
                item["endpoint"] = "" if endpoint in {"", "-", "(none)", "none"} else endpoint
                item["status"] = row_stats.get("status", "")
                rows.append(item)
            self.send_json({
                "role": "super" if self.is_super(auth) else "user",
                "clients": rows,
                "traffic": traffic_summary(auth, stats),
            })
            return
        if u.path == "/api/stats":
            rows = list(client_stats_map().values())
            if not self.is_super(auth):
                allowed = set(auth.get("clients") or [])
                rows = [row for row in rows if row.get("name") in allowed]
            self.send_json(rows)
            return
        if u.path == "/api/traffic":
            self.send_json(traffic_summary(auth))
            return
        if u.path == "/api/tokens":
            if not self.require_super(auth):
                return
            data = load_tokens()
            users = [{"hash": key, "clients": value} for key, value in sorted(data.get("users", {}).items())]
            self.send_json({"users": users})
            return
        if u.path == "/api/server/logs":
            if not self.require_super(auth):
                return
            lines = []
            for f in (AWG_DIR / "manage_amneziawg.log", AWG_DIR / "install_amneziawg.log"):
                if f.exists():
                    lines.extend(f.read_text(errors="ignore").splitlines()[-100:])
            self.send_json({"lines": lines[-100:]})
            return
        m = re.match(r"^/api/clients/([^/]+)/(config|qr|vpnuri|p2p)$", u.path)
        if not m:
            self.send_error(404)
            return
        name, kind = safe_name(m.group(1)), m.group(2)
        if not self.require_client_access(auth, name):
            return
        if kind == "config":
            self.send_file(AWG_DIR / f"{name}.conf", "text/plain; charset=utf-8")
        elif kind == "qr":
            self.send_file(AWG_DIR / f"{name}.png", "image/png")
        elif kind == "vpnuri":
            self.send_file(AWG_DIR / f"{name}.vpnuri", "text/plain; charset=utf-8")
        else:
            peer = next((p for p in parse_peers() if p["name"] == name), None)
            self.send_json({"name": name, "ports": (peer or {}).get("p2p_ports", [])})

    def do_POST(self):
        auth = self.api_auth()
        if auth is None:
            return
        u = urlparse(self.path)
        try:
            body = self.json_body()
            if u.path == "/api/clients":
                name = safe_name(body.get("name", ""))
                args = []
                if body.get("expires"):
                    args.append(f"--expires={body['expires']}")
                p = run_manage(*args, "add", name)
                if p.returncode == 0 and not self.is_super(auth):
                    mutate_user_clients(auth["hash"], name)
            elif u.path == "/api/server/restart":
                if not self.require_super(auth):
                    return
                p = run_manage("restart", timeout=90)
            elif u.path == "/api/server/name":
                if not self.require_super(auth):
                    return
                p = run_manage("set-name", require_server_name(body.get("name", "")), timeout=180)
            elif u.path == "/api/dns/restart":
                if not self.require_super(auth):
                    return
                p = run_manage("dns", "restart", timeout=30)
            elif u.path == "/api/dns/mode":
                if not self.require_super(auth):
                    return
                mode = body.get("mode", "")
                custom = body.get("custom", "")
                args = ["dns", "set-mode", mode]
                if custom:
                    args.append(custom)
                p = run_manage(*args, timeout=120)
            elif u.path == "/api/tokens":
                if not self.require_super(auth):
                    return
                clients = clean_client_list(body.get("clients", []))
                token = secrets.token_urlsafe(32)
                digest = token_hash(token)
                with TOKENS_LOCK:
                    data = load_tokens()
                    data.setdefault("users", {})[digest] = clients
                    write_tokens(data)
                self.send_json({"token": token, "token_hash": digest, "clients": clients})
                return
            elif u.path == "/api/tokens/reset-all":
                if not self.require_super(auth):
                    return
                token = secrets.token_urlsafe(32)
                write_tokens({"super_token_hash": token_hash(token), "users": {}})
                self.send_json({"super_token": token})
                return
            else:
                m = re.match(r"^/api/clients/([^/]+)/(p2p|toggle)$", u.path)
                if not m:
                    self.send_error(404)
                    return
                name, action = safe_name(m.group(1)), m.group(2)
                if not self.require_client_access(auth, name):
                    return
                if action == "toggle":
                    p = run_manage("toggle", name, timeout=45)
                else:
                    args = ["p2p", "add", name]
                    if body.get("port"):
                        args.append(str(body["port"]))
                    p = run_manage(*args)
            self.send_json({"ok": p.returncode == 0, "stdout": p.stdout, "stderr": p.stderr}, 200 if p.returncode == 0 else 400)
        except ValueError as exc:
            self.send_json({"error": str(exc)}, 400)

    def do_DELETE(self):
        auth = self.api_auth()
        if auth is None:
            return
        u = urlparse(self.path)
        try:
            m = re.match(r"^/api/clients/([^/]+)$", u.path)
            if m:
                name = safe_name(m.group(1))
                if not self.require_client_access(auth, name):
                    return
                p = run_manage("remove", name)
                if p.returncode == 0:
                    if self.is_super(auth):
                        remove_client_from_all_tokens(name)
                    else:
                        mutate_user_clients(auth["hash"], name, remove=True)
            else:
                m = re.match(r"^/api/clients/([^/]+)/p2p$", u.path)
                if m:
                    name = safe_name(m.group(1))
                    if not self.require_client_access(auth, name):
                        return
                    port = (parse_qs(u.query).get("port") or [""])[0]
                    p = run_manage("p2p", "remove", name, port)
                else:
                    m = re.match(r"^/api/tokens/([^/]+)$", u.path)
                    if not m:
                        self.send_error(404)
                        return
                    if not self.require_super(auth):
                        return
                    digest = safe_token_hash(m.group(1))
                    with TOKENS_LOCK:
                        data = load_tokens()
                        if digest not in data.get("users", {}):
                            self.send_json({"error": "token not found"}, 404)
                            return
                        del data["users"][digest]
                        write_tokens(data)
                    self.send_json({"ok": True})
                    return
            self.send_json({"ok": p.returncode == 0, "stdout": p.stdout, "stderr": p.stderr}, 200 if p.returncode == 0 else 400)
        except ValueError as exc:
            self.send_json({"error": str(exc)}, 400)


def main():
    load_tokens()
    os.chdir(WEB_DIR)
    httpd = ThreadingHTTPServer((os.environ.get("AWG_WEB_BIND", "0.0.0.0"), int(os.environ.get("AWG_WEB_PORT", "8443"))), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(WEB_DIR / "cert.pem", WEB_DIR / "key.pem")
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
