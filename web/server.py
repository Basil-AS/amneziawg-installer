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
import time
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

AWG_DIR = Path(os.environ.get("AWG_DIR", "/root/awg"))
WEB_DIR = AWG_DIR / "web"
MANAGE = AWG_DIR / "manage_amneziawg.sh"
SERVER_CONF = Path(os.environ.get("SERVER_CONF_FILE", "/etc/amnezia/amneziawg/awg0.conf"))
TOKEN_FILE = WEB_DIR / "tokens.json"
LEGACY_TOKEN_FILE = WEB_DIR / "auth_token"
NAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")
TOKEN_NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,63}$")
RATE = {}


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
    tmp = TOKEN_FILE.with_name(f"{TOKEN_FILE.name}.tmp.{os.getpid()}")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, TOKEN_FILE)
    os.chmod(TOKEN_FILE, 0o600)


def load_tokens():
    data = {}
    if TOKEN_FILE.exists():
        try:
            data = json.loads(TOKEN_FILE.read_text(encoding="utf-8"))
        except Exception:
            data = {}
    if not isinstance(data, dict):
        data = {}

    normal = data.get("normal")
    if not isinstance(normal, dict):
        normal = {}
    normal = {str(k): str(v) for k, v in normal.items() if TOKEN_NAME_RE.fullmatch(str(k))}

    super_hash = data.get("super")
    if not isinstance(super_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", super_hash):
        legacy = LEGACY_TOKEN_FILE.read_text(errors="ignore").strip() if LEGACY_TOKEN_FILE.exists() else ""
        if legacy:
            super_hash = token_hash(legacy)
        else:
            super_hash = token_hash(secrets.token_urlsafe(32))
    clean = {"super": super_hash, "normal": normal}
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
    if hmac.compare_digest(digest, data.get("super", "")):
        return "super"
    for name, item in data.get("normal", {}).items():
        if hmac.compare_digest(digest, item):
            return f"normal:{name}"
    return None


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
        if line == "[Peer]":
            if cur:
                peers.append(cur)
            cur = {"name": "", "public_key": "", "ipv4": "", "ipv6": "", "p2p_ports": []}
        elif cur is not None and line.startswith("#_Name = "):
            cur["name"] = line.split("=", 1)[1].strip()
        elif cur is not None and line.startswith("#_P2PPorts"):
            cur["p2p_ports"] = [int(x) for x in re.findall(r"\d+", line)]
        elif cur is not None and line.startswith("PublicKey"):
            cur["public_key"] = line.split("=", 1)[1].strip()
        elif cur is not None and line.startswith("AllowedIPs"):
            value = line.split("=", 1)[1]
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


def safe_token_name(name):
    if not TOKEN_NAME_RE.fullmatch(name or ""):
        raise ValueError("invalid token name")
    return name


def require_server_name(name):
    if not isinstance(name, str) or not name.strip() or "\n" in name or "\r" in name or len(name) > 128:
        raise ValueError("invalid server name")
    return name


def client_stats_map():
    p = run_manage("--json", "stats", timeout=20)
    if p.returncode != 0:
        return {}
    try:
        rows = json.loads(p.stdout or "[]")
    except json.JSONDecodeError:
        return {}
    return {row.get("name"): row for row in rows if isinstance(row, dict)}


class Handler(SimpleHTTPRequestHandler):
    server_version = "Panel/1.0"

    def log_message(self, fmt, *args):
        return

    def api_role(self):
        if not self.path.startswith("/api/"):
            return "static"
        ip = self.client_address[0]
        now = time.time()
        bucket = [t for t in RATE.get(ip, []) if now - t < 60]
        bucket.append(now)
        RATE[ip] = bucket
        if len(bucket) > 100:
            self.send_error(HTTPStatus.TOO_MANY_REQUESTS)
            return None
        role = authenticate(self.headers.get("Authorization", ""))
        if not role:
            self.send_error(HTTPStatus.UNAUTHORIZED)
            return None
        return role

    @staticmethod
    def is_super(role):
        return role == "super"

    def require_super(self, role):
        if not self.is_super(role):
            self.send_error(HTTPStatus.FORBIDDEN)
            return False
        return True

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
        role = self.api_role()
        if role is None:
            return
        u = urlparse(self.path)
        if role == "static":
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
                "clients": len(parse_peers()),
                "version": "5.13.0",
                "fork": "fork delta/patchset",
                "role": "super" if self.is_super(role) else "normal",
                "server_name": cfg["AWG_SERVER_NAME"],
            })
            return
        if u.path == "/api/dns":
            self.send_json(dns_status())
            return
        if u.path == "/api/clients":
            stats = client_stats_map()
            rows = []
            for peer in parse_peers():
                item = dict(peer)
                item.update(stats.get(peer["name"], {}))
                rows.append(item)
            self.send_json(rows)
            return
        if u.path == "/api/stats":
            p = run_manage("--json", "stats", timeout=20)
            self.send_json(json.loads(p.stdout or "[]") if p.returncode == 0 else {"error": p.stderr or p.stdout}, 200 if p.returncode == 0 else 500)
            return
        if u.path == "/api/tokens":
            if not self.require_super(role):
                return
            data = load_tokens()
            self.send_json({"normal": sorted(data.get("normal", {}).keys())})
            return
        if u.path == "/api/server/logs":
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
        role = self.api_role()
        if role is None:
            return
        u = urlparse(self.path)
        try:
            body = self.json_body()
            if u.path == "/api/clients":
                args = []
                if body.get("expires"):
                    args.append(f"--expires={body['expires']}")
                p = run_manage(*args, "add", safe_name(body.get("name", "")))
            elif u.path == "/api/server/restart":
                p = run_manage("restart", timeout=90)
            elif u.path == "/api/server/name":
                p = run_manage("set-name", require_server_name(body.get("name", "")), timeout=180)
            elif u.path == "/api/dns/restart":
                p = run_manage("dns", "restart", timeout=30)
            elif u.path == "/api/dns/mode":
                mode = body.get("mode", "")
                custom = body.get("custom", "")
                args = ["dns", "set-mode", mode]
                if custom:
                    args.append(custom)
                p = run_manage(*args, timeout=120)
            elif u.path == "/api/tokens":
                if not self.require_super(role):
                    return
                data = load_tokens()
                name = safe_token_name(body.get("name", ""))
                if name in data["normal"]:
                    self.send_json({"error": "token exists"}, 400)
                    return
                token = secrets.token_urlsafe(32)
                data["normal"][name] = token_hash(token)
                write_tokens(data)
                self.send_json({"name": name, "token": token})
                return
            elif u.path == "/api/tokens/reset-all":
                if not self.require_super(role):
                    return
                token = secrets.token_urlsafe(32)
                write_tokens({"super": token_hash(token), "normal": {}})
                self.send_json({"super_token": token})
                return
            else:
                m = re.match(r"^/api/clients/([^/]+)/p2p$", u.path)
                if not m:
                    self.send_error(404)
                    return
                args = ["p2p", "add", safe_name(m.group(1))]
                if body.get("port"):
                    args.append(str(body["port"]))
                p = run_manage(*args)
            self.send_json({"ok": p.returncode == 0, "stdout": p.stdout, "stderr": p.stderr}, 200 if p.returncode == 0 else 400)
        except ValueError as exc:
            self.send_json({"error": str(exc)}, 400)

    def do_DELETE(self):
        role = self.api_role()
        if role is None:
            return
        u = urlparse(self.path)
        try:
            m = re.match(r"^/api/clients/([^/]+)$", u.path)
            if m:
                p = run_manage("remove", safe_name(m.group(1)))
            else:
                m = re.match(r"^/api/clients/([^/]+)/p2p$", u.path)
                if m:
                    port = (parse_qs(u.query).get("port") or [""])[0]
                    p = run_manage("p2p", "remove", safe_name(m.group(1)), port)
                else:
                    m = re.match(r"^/api/tokens/([^/]+)$", u.path)
                    if not m:
                        self.send_error(404)
                        return
                    if not self.require_super(role):
                        return
                    data = load_tokens()
                    name = safe_token_name(m.group(1))
                    if name not in data["normal"]:
                        self.send_json({"error": "token not found"}, 404)
                        return
                    del data["normal"][name]
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
