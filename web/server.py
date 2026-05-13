#!/usr/bin/env python3
import json
import os
import re
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
TOKEN_FILE = WEB_DIR / "auth_token"
NAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")
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


def safe_name(name):
    if not NAME_RE.match(name or ""):
        raise ValueError("invalid client name")
    return name


class Handler(SimpleHTTPRequestHandler):
    server_version = "AmneziaWGWeb/1.0"

    def log_message(self, fmt, *args):
        return

    def authed(self):
        if not self.path.startswith("/api/"):
            return True
        ip = self.client_address[0]
        now = time.time()
        bucket = [t for t in RATE.get(ip, []) if now - t < 60]
        bucket.append(now)
        RATE[ip] = bucket
        if len(bucket) > 100:
            self.send_error(HTTPStatus.TOO_MANY_REQUESTS)
            return False
        token = TOKEN_FILE.read_text().strip()
        if self.headers.get("Authorization", "") != f"Bearer {token}":
            self.send_error(HTTPStatus.UNAUTHORIZED)
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
        if not self.authed():
            return
        u = urlparse(self.path)
        if not u.path.startswith("/api/"):
            self.path = "/index.html" if u.path == "/" else self.path
            return super().do_GET()
        if u.path == "/api/status":
            active = subprocess.run(["systemctl", "is-active", "awg-quick@awg0"], text=True, stdout=subprocess.PIPE).stdout.strip()
            self.send_json({"service": active, "clients": len(parse_peers()), "version": "5.13.0", "fork": "ipv6-p2p-web"})
            return
        if u.path == "/api/clients":
            self.send_json(parse_peers())
            return
        if u.path == "/api/stats":
            p = run_manage("--json", "stats", timeout=20)
            self.send_json(json.loads(p.stdout or "[]") if p.returncode == 0 else {"error": p.stderr or p.stdout}, 200 if p.returncode == 0 else 500)
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
        if not self.authed():
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
        if not self.authed():
            return
        u = urlparse(self.path)
        try:
            m = re.match(r"^/api/clients/([^/]+)$", u.path)
            if m:
                p = run_manage("remove", safe_name(m.group(1)))
            else:
                m = re.match(r"^/api/clients/([^/]+)/p2p$", u.path)
                if not m:
                    self.send_error(404)
                    return
                port = (parse_qs(u.query).get("port") or [""])[0]
                p = run_manage("p2p", "remove", safe_name(m.group(1)), port)
            self.send_json({"ok": p.returncode == 0, "stdout": p.stdout, "stderr": p.stderr}, 200 if p.returncode == 0 else 400)
        except ValueError as exc:
            self.send_json({"error": str(exc)}, 400)


def main():
    os.chdir(WEB_DIR)
    httpd = ThreadingHTTPServer((os.environ.get("AWG_WEB_BIND", "0.0.0.0"), int(os.environ.get("AWG_WEB_PORT", "8443"))), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(WEB_DIR / "cert.pem", WEB_DIR / "key.pem")
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
