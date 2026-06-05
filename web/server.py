#!/usr/bin/env python3
import errno
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import shlex
import socket
import ssl
import subprocess
import sys
import threading
import time
from collections import deque
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, unquote, urlparse

AWG_DIR = Path(os.environ.get("AWG_DIR", "/root/awg"))
WEB_DIR = AWG_DIR / "web"
MANAGE = AWG_DIR / "manage_amneziawg.sh"
SERVER_CONF = Path(os.environ.get("SERVER_CONF_FILE", "/etc/amnezia/amneziawg/awg0.conf"))
TOKEN_FILE = WEB_DIR / "tokens.json"
IMPORT_TOKEN_FILE = WEB_DIR / "import_tokens.json"
ACCESS_POLICY_FILE = WEB_DIR / "access_policy.json"
TRAFFIC_FILE = WEB_DIR / "traffic_history.json"
CLIENT_METADATA_FILE = WEB_DIR / "client_metadata.json"
LEGACY_TOKEN_FILE = WEB_DIR / "auth_token"
NAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")
TOKEN_HASH_RE = re.compile(r"^[0-9a-f]{64}$")
RAW_IMPORT_TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{32,256}$")
I1_RE = re.compile(r"^[<>a-fA-F0-9xbr\s]+$")
STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/style.css": ("style.css", "text/css; charset=utf-8"),
    "/app.js": ("app.js", "application/javascript; charset=utf-8"),
    "/i1.js": ("awg_i1.js", "application/javascript; charset=utf-8"),
    "/favicon.svg": ("favicon.svg", "image/svg+xml"),
    "/vendor/tailwindcss.js": ("vendor/tailwindcss.js", "application/javascript; charset=utf-8"),
    "/vendor/apexcharts.min.js": ("vendor/apexcharts.min.js", "application/javascript; charset=utf-8"),
}
RATE = {}
RATE_LOCK = threading.Lock()
RATE_WINDOW = 60
RATE_LIMIT = 100
RATE_CLEANUP_INTERVAL = 60
RATE_LAST_CLEANUP = 0
MAX_JSON_BODY = 64 * 1024
TOKENS_LOCK = threading.RLock()
IMPORT_TOKENS_LOCK = threading.RLock()
ACCESS_POLICY_LOCK = threading.RLock()
TRAFFIC_LOCK = threading.Lock()
REJECTED_HOST_LOCK = threading.Lock()
RECENT_REJECTED_HOSTS = deque(maxlen=25)
SERVER_NAME_RE = re.compile(r"^[\w .,!?\-()]{1,128}$", re.UNICODE)
DELETED_TRAFFIC_KEY = "_deleted_clients_total"
PANEL_TITLE = "AmneziaWG Panel"
PANEL_SHORT_LABEL = "AW"
REPOSITORY_URL = "https://github.com/Basil-AS/amneziawg-installer"
HELP_CLIENT_GROUPS = [
    {
        "name": "Windows",
        "icon": "windows",
        "subtitle": "Main options: WireSock for split tunneling, AmneziaWG for official compatibility.",
        "clients": [
            {
                "name": "WireSock Secure Connect",
                "status": "Recommended / Advanced",
                "trafficSplit": "App split / NDIS / routes",
                "description": "Advanced Windows client with per-app split tunneling, KillSwitch and custom DPI simulation.",
                "support": ["supported", {"state": "custom", "text": "◇ AWG 1.5 custom"}, "supported"],
                "links": [{"label": "Download", "url": "https://www.wiresock.net/wiresock-secure-connect/download/"}],
                "platforms": "Windows",
                "setupMethod": ".conf + WireSock simulation settings",
                "bestFor": "Fine-grained routing by apps, routes and networks on Windows.",
                "limitation": "Standard AWG 1.5 I1-I5 parameters are not imported directly; WireSock uses custom simulation settings.",
            },
            {
                "name": "AmneziaWG for Windows",
                "status": "Recommended",
                "trafficSplit": "Routes only",
                "description": "Lightweight official AWG client for Windows.",
                "support": ["supported", "supported", "supported"],
                "links": [{"label": "GitHub Releases", "url": "https://github.com/amnezia-vpn/amneziawg-windows-client/releases"}],
                "platforms": "Windows x64, ARM64, x86",
                "setupMethod": ".conf",
                "bestFor": "Official compatibility with generated AmneziaWG configs.",
                "limitation": "Split tunneling is mostly route-based.",
            },
        ],
    },
    {
        "name": "Android",
        "icon": "android",
        "subtitle": "Main options: WG Tunnel for advanced routing, AmneziaWG for a lightweight official flow.",
        "clients": [
            {
                "name": "WG Tunnel",
                "status": "Recommended / Advanced",
                "trafficSplit": "App split / auto tunnel",
                "description": "Advanced Android client for auto-tunnel, split tunneling, Always-On, lockdown and Android TV.",
                "support": ["supported", "supported", {"state": "supported", "text": "✅ AWG 2.0 userspace"}],
                "links": [{"label": "Website", "url": "https://wgtunnel.com/"}, {"label": "GitHub", "url": "https://github.com/wgtunnel/android/releases"}],
                "platforms": "Android phones, tablets, Android TV",
                "setupMethod": ".conf, QR, manual import",
                "bestFor": "App-based routing, auto-connect and Android TV scenarios.",
                "limitation": "AmneziaWG support requires the Userspace/Go backend.",
            },
            {
                "name": "AmneziaWG Android",
                "status": "Recommended",
                "trafficSplit": "App split",
                "description": "Lightweight official AWG client for Android.",
                "support": ["supported", "supported", "supported"],
                "links": [{"label": "Google Play", "url": "https://play.google.com/store/apps/details?id=org.amnezia.awg"}],
                "platforms": "Android phones, tablets",
                "setupMethod": ".conf, QR",
                "bestFor": "Official lightweight client flow.",
                "limitation": "For advanced auto-tunnel scenarios, WG Tunnel is usually more flexible.",
            },
        ],
    },
    {
        "name": "iOS / iPadOS",
        "icon": "apple",
        "subtitle": "iOS limits per-app split tunneling for generic VPN clients.",
        "clients": [
            {
                "name": "AmneziaWG",
                "status": "Recommended",
                "trafficSplit": "No app split / OS-limited",
                "description": "Lightweight AWG client for iOS and iPadOS.",
                "support": ["supported", "supported", "supported"],
                "links": [{"label": "App Store", "url": "https://apps.apple.com/app/amneziawg/id6478942365"}],
                "platforms": "iPhone, iPad",
                "setupMethod": ".conf, QR",
                "bestFor": "Lightweight AWG connectivity on iOS.",
                "limitation": "No normal per-app split tunneling due to iOS limitations.",
            },
            {
                "name": "AmneziaVPN",
                "status": "Full client",
                "trafficSplit": "No app split / OS-limited",
                "description": "Full Amnezia client for iOS.",
                "support": ["supported", "supported", "supported"],
                "links": [{"label": "Official", "url": "https://amnezia.org/downloads"}],
                "platforms": "iPhone, iPad",
                "setupMethod": "vpn:// URI, QR, app flow",
                "bestFor": "Full Amnezia client flow on iOS.",
                "limitation": "Availability can depend on App Store region.",
            },
        ],
    },
    {
        "name": "macOS / Linux Desktop",
        "icon": "linux",
        "subtitle": "GUI clients for desktop systems; proxy clients remain alternatives.",
        "clients": [
            {
                "name": "AmneziaVPN",
                "status": "Recommended / Full client",
                "trafficSplit": "Routes / app features",
                "description": "Full desktop client.",
                "support": ["supported", "supported", "supported"],
                "links": [{"label": "Official", "url": "https://amnezia.org/downloads"}, {"label": "GitHub", "url": "https://github.com/amnezia-vpn/amnezia-client/releases"}],
                "platforms": "macOS, Linux Desktop",
                "setupMethod": "vpn:// URI, QR, app flow",
                "bestFor": "Full GUI onboarding and desktop use.",
                "limitation": "Heavier than lightweight AWG-only clients.",
            },
            {
                "name": "AmneziaWG",
                "status": "Recommended",
                "trafficSplit": "Routes only",
                "description": "Lightweight AWG client for Apple ecosystem.",
                "support": ["supported", "supported", "supported"],
                "links": [{"label": "App Store", "url": "https://apps.apple.com/app/amneziawg/id6478942365"}],
                "platforms": "macOS",
                "setupMethod": ".conf, QR",
                "bestFor": "Lightweight AWG-only setup.",
                "limitation": "Split tunneling is mostly route-based.",
            },
        ],
    },
]


def audit_log(message):
    print(message, file=sys.stderr, flush=True)


BENIGN_DISCONNECT_ERRNOS = {errno.ECONNRESET, errno.EPIPE, errno.ETIMEDOUT}
BENIGN_DISCONNECT_TYPES = (
    BrokenPipeError,
    ConnectionResetError,
    TimeoutError,
    socket.timeout,
    ssl.SSLEOFError,
    ssl.SSLZeroReturnError,
    ssl.SSLWantReadError,
)


def is_benign_disconnect_error(exc):
    while exc is not None:
        if isinstance(exc, BENIGN_DISCONNECT_TYPES):
            return True
        if isinstance(exc, OSError) and exc.errno in BENIGN_DISCONNECT_ERRNOS:
            return True
        exc = getattr(exc, "__cause__", None) or getattr(exc, "__context__", None)
    return False


def split_host(host):
    host = (host or "").strip().lower()
    if not host or any(ch in host for ch in "/\\\r\n\t "):
        return ""
    if host.startswith("["):
        end = host.find("]")
        return host[1:end] if end > 0 else host
    if host.count(":") == 1:
        return host.rsplit(":", 1)[0]
    return host


def host_is_ip(value):
    try:
        ipaddress.ip_address(value)
        return True
    except ValueError:
        return False


def default_allowed_hosts():
    domain = (os.environ.get("AWG_WEB_DOMAIN") or "").strip().lower()
    bind = os.environ.get("AWG_WEB_BIND") or "10.9.9.1"
    endpoint = (os.environ.get("AWG_ENDPOINT") or "").strip().lower()
    hosts = ["localhost", "127.0.0.1", "194-180-189-244.sslip.io", "194.180.189.244"]
    for value in (domain, endpoint, bind):
        host = split_host(value)
        if host and host not in {"0.0.0.0", "::", "mastus.online"} and host not in hosts:
            hosts.append(host)
    return hosts


def default_access_policy():
    bind = os.environ.get("AWG_WEB_BIND") or "10.9.9.1"
    if bind in {"0.0.0.0", "::"}:
        mode = "public"
        source_cidrs = ["0.0.0.0/0", "::/0"]
    elif bind in {"127.0.0.1", "::1"}:
        mode = "localhost_only"
        bind = "127.0.0.1"
        source_cidrs = ["127.0.0.0/8", "::1/128"]
    elif bind == "10.9.9.1":
        mode = "vpn_only"
        source_cidrs = ["10.0.0.0/8", "127.0.0.0/8"]
    else:
        mode = "custom"
        source_cidrs = ["0.0.0.0/0", "::/0"]
    return {
        "bind_mode": mode,
        "bind_host": bind,
        "allowed_hosts": default_allowed_hosts(),
        "allowed_source_cidrs": source_cidrs,
        "host_check_enabled": True,
        "source_check_enabled": False,
    }


def clean_policy_string_list(value, field):
    if isinstance(value, str):
        items = [line.strip() for line in value.splitlines()]
    elif isinstance(value, list):
        items = [str(item).strip() for item in value]
    else:
        raise ValueError(f"invalid {field}")
    out, seen = [], set()
    for item in items:
        if not item:
            continue
        if any(ord(ch) < 32 or ord(ch) == 127 for ch in item):
            raise ValueError(f"invalid {field}")
        if item not in seen:
            out.append(item)
            seen.add(item)
    return out


def clean_allowed_host(value):
    host = split_host(value)
    if not host or any(ch in host for ch in "/\\\r\n\t "):
        raise ValueError("invalid allowed host")
    return host


def clean_allowed_hosts(value):
    out, seen = [], set()
    for item in clean_policy_string_list(value, "allowed_hosts"):
        host = clean_allowed_host(item)
        if host not in seen:
            out.append(host)
            seen.add(host)
    return out


def ensure_items(values, required):
    out = list(values)
    seen = set(out)
    for item in required:
        if item and item not in seen:
            out.append(item)
            seen.add(item)
    return out


def clean_cidr_list(value, field="allowed_source_cidrs"):
    out, seen = [], set()
    for item in clean_policy_string_list(value, field):
        try:
            cidr = str(ipaddress.ip_network(item, strict=False))
        except ValueError as exc:
            raise ValueError(f"invalid {field}") from exc
        if cidr not in seen:
            out.append(cidr)
            seen.add(cidr)
    return out


def clean_bind_host(value):
    value = str(value or "").strip().lower()
    if value == "localhost":
        return "127.0.0.1"
    try:
        return str(ipaddress.ip_address(value))
    except ValueError as exc:
        raise ValueError("invalid bind_host") from exc


def clean_access_policy(value):
    defaults = default_access_policy()
    data = value if isinstance(value, dict) else {}
    mode = data.get("bind_mode", defaults["bind_mode"])
    if mode not in {"public", "vpn_only", "localhost_only", "custom"}:
        raise ValueError("invalid bind_mode")
    if mode == "public":
        bind_host = "0.0.0.0"
    elif mode == "localhost_only":
        bind_host = "127.0.0.1"
    elif mode == "vpn_only":
        bind_host = clean_bind_host(data.get("bind_host") or "0.0.0.0")
    else:
        bind_host = clean_bind_host(data.get("bind_host"))
    host_check_enabled = bool(data.get("host_check_enabled", defaults["host_check_enabled"]))
    source_check_enabled = bool(data.get("source_check_enabled", defaults["source_check_enabled"]))
    allowed_hosts = clean_allowed_hosts(data.get("allowed_hosts", defaults["allowed_hosts"]))
    allowed_source_cidrs = clean_cidr_list(data.get("allowed_source_cidrs", defaults["allowed_source_cidrs"]))
    if mode == "public":
        source_check_enabled = False
        allowed_hosts = ensure_items(allowed_hosts, ["194-180-189-244.sslip.io", "194.180.189.244", "localhost", "127.0.0.1"])
    elif mode == "vpn_only":
        source_check_enabled = True
        if not allowed_source_cidrs or any(cidr in {"0.0.0.0/0", "::/0"} for cidr in allowed_source_cidrs):
            allowed_source_cidrs = ["10.0.0.0/8", "127.0.0.0/8"]
    elif mode == "localhost_only":
        source_check_enabled = True
        allowed_source_cidrs = ["127.0.0.0/8", "::1/128"]
    if host_check_enabled and not allowed_hosts:
        raise ValueError("allowed_hosts cannot be empty when host check is enabled")
    if source_check_enabled and not allowed_source_cidrs:
        raise ValueError("allowed_source_cidrs cannot be empty when source check is enabled")
    return {
        "bind_mode": mode,
        "bind_host": bind_host,
        "allowed_hosts": allowed_hosts,
        "allowed_source_cidrs": allowed_source_cidrs,
        "host_check_enabled": host_check_enabled,
        "source_check_enabled": source_check_enabled,
    }


def load_access_policy():
    with ACCESS_POLICY_LOCK:
        data = {}
        if ACCESS_POLICY_FILE.exists():
            try:
                data = json.loads(ACCESS_POLICY_FILE.read_text(encoding="utf-8"))
            except Exception:
                data = {}
        try:
            clean = clean_access_policy(data)
        except ValueError:
            clean = default_access_policy()
        if clean != data or not ACCESS_POLICY_FILE.exists():
            write_access_policy(clean)
        return clean


def write_access_policy(data):
    with ACCESS_POLICY_LOCK:
        WEB_DIR.mkdir(parents=True, exist_ok=True)
        clean = clean_access_policy(data)
        tmp = ACCESS_POLICY_FILE.with_name(f"{ACCESS_POLICY_FILE.name}.tmp.{os.getpid()}")
        tmp.write_text(json.dumps(clean, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.chmod(tmp, 0o600)
        os.replace(tmp, ACCESS_POLICY_FILE)
        os.chmod(ACCESS_POLICY_FILE, 0o600)


def source_allowed(remote_addr, policy):
    if not policy.get("source_check_enabled"):
        return True
    try:
        remote_ip = ipaddress.ip_address(remote_addr)
    except ValueError:
        return False
    for cidr in policy.get("allowed_source_cidrs", []):
        try:
            if remote_ip in ipaddress.ip_network(cidr, strict=False):
                return True
        except ValueError:
            continue
    return False


def host_allowed(raw_host, remote_addr, policy):
    host = split_host(raw_host)
    if not host:
        return False
    if not policy.get("host_check_enabled"):
        return True
    if remote_addr in {"127.0.0.1", "::1"}:
        return True
    if policy.get("bind_host") in {"127.0.0.1", "::1"}:
        return host in {"localhost", "127.0.0.1", "::1"}
    return host in set(policy.get("allowed_hosts") or [])


def request_allowed_by_policy(raw_host, remote_addr, policy):
    return host_allowed(raw_host, remote_addr, policy) and source_allowed(remote_addr, policy)


def bind_allows_current_remote(bind_host, remote_addr):
    try:
        bind_ip = ipaddress.ip_address(bind_host)
        remote_ip = ipaddress.ip_address(remote_addr)
    except ValueError:
        return False
    if bind_ip.is_unspecified:
        return True
    if bind_ip.is_loopback:
        return remote_ip.is_loopback
    if remote_ip.is_loopback:
        return True
    if bind_ip.is_private and not remote_ip.is_private:
        return False
    return True


def allowed_host_header(raw_host, remote_addr):
    return host_allowed(raw_host, remote_addr, load_access_policy())


def record_rejected_host(raw_host, remote_addr, path):
    with REJECTED_HOST_LOCK:
        RECENT_REJECTED_HOSTS.appendleft({
            "time": int(time.time()),
            "host": str(raw_host or "")[:200],
            "remote": str(remote_addr or "")[:80],
            "path": str(path or "")[:200],
        })


def recent_rejected_hosts():
    with REJECTED_HOST_LOCK:
        return list(RECENT_REJECTED_HOSTS)


def restart_web_panel_later():
    def _restart():
        time.sleep(0.5)
        subprocess.Popen(["systemctl", "restart", "awg-web.service"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    threading.Thread(target=_restart, daemon=True).start()


def run_manage(*args, timeout=60, extra_env=None):
    env = os.environ.copy()
    env["AWG_YES"] = "1"
    if extra_env:
        env.update(extra_env)
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


def clean_expired_import_tokens(data, now=None):
    now = int(time.time() if now is None else now)
    tokens = data.get("tokens") if isinstance(data, dict) else {}
    clean = {}
    if isinstance(tokens, dict):
        for digest, record in tokens.items():
            if not isinstance(digest, str) or not TOKEN_HASH_RE.fullmatch(digest):
                continue
            if not isinstance(record, dict):
                continue
            client = record.get("client")
            expires_at = record.get("expires_at")
            if not isinstance(client, str) or not NAME_RE.fullmatch(client):
                continue
            if isinstance(expires_at, bool) or not isinstance(expires_at, int) or expires_at <= now:
                continue
            clean[digest] = {
                "client": client,
                "expires_at": expires_at,
                "one_time": bool(record.get("one_time", False)),
                "created_at": int(record.get("created_at") or now),
            }
    return {"tokens": clean}


def load_import_tokens(now=None):
    with IMPORT_TOKENS_LOCK:
        data = {}
        if IMPORT_TOKEN_FILE.exists():
            try:
                data = json.loads(IMPORT_TOKEN_FILE.read_text(encoding="utf-8"))
            except Exception:
                data = {}
        clean = clean_expired_import_tokens(data, now=now)
        if clean != data or not IMPORT_TOKEN_FILE.exists():
            write_import_tokens(clean)
        return clean


def write_import_tokens(data):
    with IMPORT_TOKENS_LOCK:
        WEB_DIR.mkdir(parents=True, exist_ok=True)
        clean = clean_expired_import_tokens(data)
        tmp = IMPORT_TOKEN_FILE.with_name(f"{IMPORT_TOKEN_FILE.name}.tmp.{os.getpid()}")
        tmp.write_text(json.dumps(clean, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.chmod(tmp, 0o600)
        os.replace(tmp, IMPORT_TOKEN_FILE)
        os.chmod(IMPORT_TOKEN_FILE, 0o600)


def remove_import_tokens_for_client(client_name):
    client_name = safe_name(client_name)
    with IMPORT_TOKENS_LOCK:
        data = load_import_tokens()
        tokens = data.setdefault("tokens", {})
        changed = False
        for digest, record in list(tokens.items()):
            if isinstance(record, dict) and record.get("client") == client_name:
                tokens.pop(digest, None)
                changed = True
        if changed:
            write_import_tokens(data)


def clear_import_tokens():
    with IMPORT_TOKENS_LOCK:
        write_import_tokens({"tokens": {}})


def require_import_ttl(value):
    if value is None:
        return 300
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError("invalid ttl")
    if value < 60 or value > 3600:
        raise ValueError("invalid ttl")
    return value


def require_import_token(value):
    if not isinstance(value, str) or not RAW_IMPORT_TOKEN_RE.fullmatch(value):
        raise ValueError("invalid import token")
    return value


def write_tokens(data):
    with TOKENS_LOCK:
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


def clean_client_metadata_record(value):
    if not isinstance(value, dict):
        return {}
    display_name = value.get("display_name")
    if not isinstance(display_name, str) or not NAME_RE.fullmatch(display_name):
        return {}
    return {"display_name": display_name}


def load_client_metadata():
    if not CLIENT_METADATA_FILE.exists():
        return {"clients": {}}
    try:
        data = json.loads(CLIENT_METADATA_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {"clients": {}}
    if not isinstance(data, dict) or not isinstance(data.get("clients"), dict):
        return {"clients": {}}
    clients = {}
    for config_name, record in data.get("clients", {}).items():
        if isinstance(config_name, str) and NAME_RE.fullmatch(config_name):
            clean = clean_client_metadata_record(record)
            if clean:
                clients[config_name] = clean
    return {"clients": clients}


def write_client_metadata(data):
    WEB_DIR.mkdir(parents=True, exist_ok=True)
    clean = load_client_metadata() if not isinstance(data, dict) else {"clients": {}}
    if isinstance(data, dict) and isinstance(data.get("clients"), dict):
        for config_name, record in data.get("clients", {}).items():
            if isinstance(config_name, str) and NAME_RE.fullmatch(config_name):
                record = clean_client_metadata_record(record)
                if record:
                    clean["clients"][config_name] = record
    tmp = CLIENT_METADATA_FILE.with_name(f"{CLIENT_METADATA_FILE.name}.tmp.{os.getpid()}")
    tmp.write_text(json.dumps(clean, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, CLIENT_METADATA_FILE)
    os.chmod(CLIENT_METADATA_FILE, 0o600)


def set_client_display_name(config_name, display_name):
    config_name = safe_name(config_name)
    display_name = safe_name(display_name)
    data = load_client_metadata()
    data.setdefault("clients", {})[config_name] = {"display_name": display_name}
    write_client_metadata(data)


def remove_client_metadata(config_name):
    config_name = safe_name(config_name)
    data = load_client_metadata()
    if data.get("clients", {}).pop(config_name, None) is not None:
        write_client_metadata(data)


def client_identity_map(peers=None):
    peers = peers if peers is not None else parse_peers()
    return {peer["name"]: peer.get("display_name") or peer["name"] for peer in peers}


def unique_client_config_name(display_name, peers=None):
    display_name = safe_name(display_name)
    peers = peers if peers is not None else parse_peers()
    existing_names = {peer["name"] for peer in peers}
    existing_names.update(path.stem for path in AWG_DIR.glob("*.conf") if NAME_RE.fullmatch(path.stem))
    display_names = set(client_identity_map(peers).values())
    if display_name not in existing_names and display_name not in display_names:
        return display_name, False
    for _ in range(40):
        candidate = f"{display_name}-{secrets.token_hex(2)}"
        if candidate not in existing_names:
            return candidate, True
    raise ValueError("could not allocate unique client name")


def token_assignments_for_clients():
    data = load_tokens()
    assignments = {}
    for digest, value in sorted(data.get("users", {}).items()):
        record = clean_user_record(value)
        label = record.get("name") or f"token: {digest[:6]}"
        item = {"alias": label, "fingerprint": digest[:6], "role": "user"}
        for client_name in record.get("clients", []):
            assignments.setdefault(client_name, []).append(dict(item))
    return assignments


def load_traffic_history():
    if not TRAFFIC_FILE.exists():
        return {"last": {}, "days": {}, "totals": {DELETED_TRAFFIC_KEY: {"rx": 0, "tx": 0}}}
    try:
        data = json.loads(TRAFFIC_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {"last": {}, "days": {}, "totals": {DELETED_TRAFFIC_KEY: {"rx": 0, "tx": 0}}}
    if not isinstance(data, dict):
        return {"last": {}, "days": {}, "totals": {DELETED_TRAFFIC_KEY: {"rx": 0, "tx": 0}}}
    last = data.get("last") if isinstance(data.get("last"), dict) else {}
    days = data.get("days") if isinstance(data.get("days"), dict) else {}
    totals = data.get("totals") if isinstance(data.get("totals"), dict) else {}
    if not isinstance(totals.get(DELETED_TRAFFIC_KEY), dict):
        totals[DELETED_TRAFFIC_KEY] = {"rx": 0, "tx": 0}
    return {"last": last, "days": days, "totals": totals}


def write_traffic_history(data):
    WEB_DIR.mkdir(parents=True, exist_ok=True)
    tmp = TRAFFIC_FILE.with_name(f"{TRAFFIC_FILE.name}.tmp.{os.getpid()}")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, TRAFFIC_FILE)
    os.chmod(TRAFFIC_FILE, 0o600)


def _traffic_pair(values):
    if not isinstance(values, dict):
        return {"rx": 0, "tx": 0}
    return {
        "rx": max(0, int(values.get("rx") or 0)),
        "tx": max(0, int(values.get("tx") or 0)),
    }


def _sum_days_for_client(days, name):
    rx = tx = 0
    if not isinstance(days, dict):
        return {"rx": 0, "tx": 0}
    for day_rows in days.values():
        values = day_rows.get(name, {}) if isinstance(day_rows, dict) else {}
        pair = _traffic_pair(values)
        rx += pair["rx"]
        tx += pair["tx"]
    return {"rx": rx, "tx": tx}


def _add_traffic_delta(bucket, name, rx_delta, tx_delta):
    entry = bucket.setdefault(name, {"rx": 0, "tx": 0})
    entry["rx"] = max(0, int(entry.get("rx") or 0)) + rx_delta
    entry["tx"] = max(0, int(entry.get("tx") or 0)) + tx_delta


def update_traffic_history(rows):
    today = time.strftime("%Y-%m-%d", time.localtime())
    cutoff = time.time() - 29 * 86400
    keep_days = {
        time.strftime("%Y-%m-%d", time.localtime(cutoff + offset * 86400))
        for offset in range(30)
    }
    with TRAFFIC_LOCK:
        history_existed = TRAFFIC_FILE.exists()
        data = load_traffic_history()
        last = data.setdefault("last", {})
        days = data.setdefault("days", {})
        totals = data.setdefault("totals", {})
        deleted_total = totals.setdefault(DELETED_TRAFFIC_KEY, {"rx": 0, "tx": 0})
        day = days.setdefault(today, {})
        changed = False
        active_names = set()
        for row in rows:
            name = str(row.get("name", ""))
            if not NAME_RE.fullmatch(name):
                continue
            active_names.add(name)
            rx = max(0, int(row.get("rx") or 0))
            tx = max(0, int(row.get("tx") or 0))
            prev = last.get(name) if isinstance(last.get(name), dict) else None
            if not isinstance(totals.get(name), dict):
                seeded = _sum_days_for_client(days, name)
                if history_existed and prev is not None:
                    prev_pair = _traffic_pair(prev)
                    seeded["rx"] = max(seeded["rx"], prev_pair["rx"])
                    seeded["tx"] = max(seeded["tx"], prev_pair["tx"])
                totals[name] = seeded
                changed = True
            if prev is not None:
                prev_pair = _traffic_pair(prev)
                rx_delta = rx - prev_pair["rx"] if rx >= prev_pair["rx"] else rx
                tx_delta = tx - prev_pair["tx"] if tx >= prev_pair["tx"] else tx
                if rx_delta or tx_delta:
                    _add_traffic_delta(day, name, rx_delta, tx_delta)
                    _add_traffic_delta(totals, name, rx_delta, tx_delta)
                    changed = True
            if last.get(name) != {"rx": rx, "tx": tx}:
                last[name] = {"rx": rx, "tx": tx}
                changed = True
        for date in list(days):
            if date not in keep_days:
                del days[date]
                changed = True
        for name in list(last):
            if name.startswith("_"):
                del last[name]
                changed = True
            elif name not in active_names:
                del last[name]
                changed = True
        for name in list(totals):
            if name.startswith("_"):
                continue
            if name not in active_names:
                pair = _traffic_pair(totals.get(name, {}))
                if pair["rx"] or pair["tx"]:
                    deleted_total["rx"] = max(0, int(deleted_total.get("rx") or 0)) + pair["rx"]
                    deleted_total["tx"] = max(0, int(deleted_total.get("tx") or 0)) + pair["tx"]
                del totals[name]
                for bucket in days.values():
                    if isinstance(bucket, dict) and name in bucket:
                        del bucket[name]
                changed = True
        if changed:
            write_traffic_history(data)


def traffic_summary(auth, stats=None, names=None):
    stats = stats or client_stats_map()
    if names is not None:
        allowed = set(names)
    elif auth.get("role") == "super":
        allowed = None
    else:
        allowed = set(auth.get("clients") or [])
    rows = [row for row in stats.values() if allowed is None or row.get("name") in allowed]
    current_live = {
        "rx": sum(max(0, int(row.get("rx") or 0)) for row in rows),
        "tx": sum(max(0, int(row.get("tx") or 0)) for row in rows),
    }
    history = load_traffic_history()
    persistent = {"rx": 0, "tx": 0}
    for name, values in history.get("totals", {}).items():
        if name.startswith("_") and allowed is not None:
            continue
        if allowed is not None and name not in allowed:
            continue
        pair = _traffic_pair(values)
        persistent["rx"] += pair["rx"]
        persistent["tx"] += pair["tx"]
    days = []
    for offset in range(29, -1, -1):
        date = time.strftime("%Y-%m-%d", time.localtime(time.time() - offset * 86400))
        day_rows = history.get("days", {}).get(date, {})
        rx = tx = 0
        if isinstance(day_rows, dict):
            for name, values in day_rows.items():
                if name.startswith("_"):
                    continue
                if allowed is not None and name not in allowed:
                    continue
                if isinstance(values, dict):
                    rx += max(0, int(values.get("rx") or 0))
                    tx += max(0, int(values.get("tx") or 0))
        days.append({"date": date, "rx": rx, "tx": tx, "total": rx + tx})
    last_30d = {"rx": sum(day["rx"] for day in days), "tx": sum(day["tx"] for day in days)}
    return {
        "current_live": {**current_live, "total": current_live["rx"] + current_live["tx"]},
        "current": {**persistent, "total": persistent["rx"] + persistent["tx"]},
        "total": {**persistent, "total": persistent["rx"] + persistent["tx"]},
        "last_30d": {**last_30d, "total": last_30d["rx"] + last_30d["tx"]},
        "days": days,
    }


def client_traffic_30d(name, history=None):
    history = history or load_traffic_history()
    rx = tx = 0
    for offset in range(29, -1, -1):
        date = time.strftime("%Y-%m-%d", time.localtime(time.time() - offset * 86400))
        values = history.get("days", {}).get(date, {}).get(name, {})
        if isinstance(values, dict):
            rx += max(0, int(values.get("rx") or 0))
            tx += max(0, int(values.get("tx") or 0))
    return {"rx": rx, "tx": tx, "total": rx + tx}


def client_traffic_total(name, history=None):
    history = history or load_traffic_history()
    if name.startswith("_"):
        return {"rx": 0, "tx": 0, "total": 0}
    pair = _traffic_pair(history.get("totals", {}).get(name, {}))
    return {"rx": pair["rx"], "tx": pair["tx"], "total": pair["rx"] + pair["tx"]}


def clean_client_list(value):
    if not isinstance(value, list):
        raise ValueError("invalid client list")
    out, seen = [], set()
    for item in value:
        if not isinstance(item, str):
            raise ValueError("invalid client list")
        name = item
        if not NAME_RE.fullmatch(name):
            raise ValueError("invalid client list")
        if name not in seen:
            out.append(name)
            seen.add(name)
    return out


def require_existing_clients(value):
    clients = clean_client_list(value)
    existing = {peer["name"] for peer in parse_peers()}
    if any(name not in existing for name in clients):
        raise ValueError("unknown client")
    return clients


def clean_token_name(value):
    if not isinstance(value, str):
        return ""
    value = value.strip()
    if len(value) > 64 or any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
        raise ValueError("invalid token name")
    return value


def clean_user_record(value, strict=False):
    if isinstance(value, list):
        try:
            clients = clean_client_list(value)
        except ValueError:
            if strict:
                raise
            clients = []
        return {"name": "", "clients": clients}
    if isinstance(value, dict):
        try:
            clients = clean_client_list(value.get("clients", []))
        except ValueError:
            if strict:
                raise
            clients = []
        return {
            "name": clean_token_name(value.get("name", "")),
            "clients": clients,
        }
    if strict:
        raise ValueError("invalid user token record")
    return {"name": "", "clients": []}


def load_tokens():
    with TOKENS_LOCK:
        data = {}
        if TOKEN_FILE.exists():
            try:
                data = json.loads(TOKEN_FILE.read_text(encoding="utf-8"))
            except Exception as exc:
                raise RuntimeError("tokens.json is invalid; run manage_amneziawg.sh web token reset-super") from exc
        if not isinstance(data, dict):
            raise RuntimeError("tokens.json is invalid; run manage_amneziawg.sh web token reset-super")

        super_hash = data.get("super_token_hash") or data.get("super")
        if not isinstance(super_hash, str) or not TOKEN_HASH_RE.fullmatch(super_hash):
            legacy = LEGACY_TOKEN_FILE.read_text(errors="ignore").strip() if LEGACY_TOKEN_FILE.exists() else ""
            if TOKEN_FILE.exists() and not legacy:
                raise RuntimeError("tokens.json is invalid; run manage_amneziawg.sh web token reset-super")
            super_hash = token_hash(legacy) if legacy else token_hash(secrets.token_urlsafe(32))

        users = data.get("users")
        if not isinstance(users, dict):
            if TOKEN_FILE.exists() and "users" in data:
                raise RuntimeError("tokens.json is invalid; run manage_amneziawg.sh web token reset-super")
            users = {}
        legacy_normal = data.get("normal")
        if isinstance(legacy_normal, dict):
            for value in legacy_normal.values():
                if isinstance(value, str) and TOKEN_HASH_RE.fullmatch(value):
                    users.setdefault(value, [])

        clean_users = {}
        for digest, value in users.items():
            if isinstance(digest, str) and TOKEN_HASH_RE.fullmatch(digest):
                try:
                    clean_users[digest] = clean_user_record(value, strict=TOKEN_FILE.exists())
                except ValueError as exc:
                    raise RuntimeError("tokens.json is invalid; run manage_amneziawg.sh web token reset-super") from exc

        clean = {"super_token_hash": super_hash, "users": clean_users}
        if clean != data or not TOKEN_FILE.exists():
            write_tokens(clean)
        return clean


def check_rate_limit(ip, now=None):
    global RATE_LAST_CLEANUP
    now = time.time() if now is None else now
    with RATE_LOCK:
        if now - RATE_LAST_CLEANUP >= RATE_CLEANUP_INTERVAL:
            for key, values in list(RATE.items()):
                bucket = [stamp for stamp in values if now - stamp < RATE_WINDOW]
                if bucket:
                    RATE[key] = bucket
                else:
                    del RATE[key]
            RATE_LAST_CLEANUP = now
        bucket = [stamp for stamp in RATE.get(ip, []) if now - stamp < RATE_WINDOW][-RATE_LIMIT:]
        if len(bucket) >= RATE_LIMIT:
            RATE[ip] = bucket[: RATE_LIMIT + 1]
            return False
        bucket.append(now)
        RATE[ip] = bucket[-(RATE_LIMIT + 1):]
        return True


def tail_lines(path, limit=100):
    try:
        result = subprocess.run(
            ["tail", "-n", str(limit), str(path)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    return result.stdout.splitlines() if result.returncode == 0 else []


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
    for user_hash, record in data.get("users", {}).items():
        if hmac.compare_digest(digest, user_hash):
            return {"role": "user", "hash": digest, "clients": record.get("clients", [])}
    return None


def auth_reject_reason(header):
    # Bearer auth audit reason values: missing / malformed / invalid / expired / insufficient scope.
    # Current bearer tokens do not expire; import tokens use separate one-time/expiry handling.
    if not header:
        return "missing", ""
    if not header.startswith("Bearer "):
        return "malformed", ""
    token = header.removeprefix("Bearer ").strip()
    if not token:
        return "missing", ""
    return "invalid", token_hash(token)[:8]


def mutate_user_clients(user_hash, client_name=None, remove=False):
    if not user_hash or not client_name:
        return
    with TOKENS_LOCK:
        data = load_tokens()
        users = data.setdefault("users", {})
        record = clean_user_record(users.get(user_hash, {}))
        clients = record["clients"]
        if remove:
            clients = [name for name in clients if name != client_name]
        elif client_name not in clients:
            clients.append(client_name)
        record["clients"] = clients
        users[user_hash] = record
        write_tokens(data)


def remove_client_from_all_tokens(client_name):
    with TOKENS_LOCK:
        data = load_tokens()
        changed = False
        for user_hash, value in list(data.get("users", {}).items()):
            record = clean_user_record(value)
            clean = [name for name in record["clients"] if name != client_name]
            if clean != record["clients"]:
                record["clients"] = clean
                data["users"][user_hash] = record
                changed = True
        if changed:
            write_tokens(data)


def rotate_user_token(old_digest):
    old_digest = safe_token_hash(old_digest)
    token = secrets.token_urlsafe(32)
    new_digest = token_hash(token)
    with TOKENS_LOCK:
        data = load_tokens()
        users = data.setdefault("users", {})
        if old_digest not in users:
            return None
        record = clean_user_record(users.pop(old_digest, {}))
        users[new_digest] = record
        write_tokens(data)
    return {"token": token, "token_hash": new_digest, "name": record["name"], "clients": record["clients"]}


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
                "p2p_enabled": True,
                "disabled": line == "# [Peer]",
            }
        elif cur is not None and line.startswith("#_Name = "):
            cur["name"] = line.split("=", 1)[1].strip()
        elif cur is not None and re.match(r"^#_P2PPorts(_Disabled)?\s*=", line):
            value = line.split("=", 1)[1] if "=" in line else ""
            cur["p2p_ports"] = [int(x) for x in re.findall(r"\d+", value)]
            cur["p2p_enabled"] = not line.startswith("#_P2PPorts_Disabled")
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
    metadata = load_client_metadata().get("clients", {})
    rows = []
    for peer in peers:
        if not peer.get("name"):
            continue
        config_name = peer["name"]
        display_name = metadata.get(config_name, {}).get("display_name") or config_name
        peer["id"] = config_name
        peer["name"] = config_name
        peer["config_name"] = config_name
        peer["display_name"] = display_name
        rows.append(peer)
    return rows


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


def resolver_status():
    status = dns_status()
    return {
        "mode": status["mode"],
        "client_resolver": status["client_dns"],
        "managed_enabled": status["adguard_enabled"],
        "managed_service": status["adguard_service"],
        "managed_port": status["adguard_port"],
    }


def safe_name(name):
    if not NAME_RE.fullmatch(name or ""):
        raise ValueError("invalid client name")
    return name


def safe_token_hash(value):
    if not TOKEN_HASH_RE.fullmatch(value or ""):
        raise ValueError("invalid token hash")
    return value


def validate_i1(value: str) -> str:
    if not isinstance(value, str):
        raise ValueError("invalid I1 format")
    value = value.strip()
    if not value:
        raise ValueError("empty I1")
    if len(value) > 2000:
        raise ValueError("I1 is too long")
    if any(ord(ch) < 32 and ch != " " for ch in value):
        raise ValueError("invalid I1 format")
    if not I1_RE.fullmatch(value):
        raise ValueError("invalid I1 format")
    if "<b 0x" not in value and "<r " not in value:
        raise ValueError("invalid I1 chunks")
    return value


def require_rotate_preset(value):
    if value not in {"default", "mobile"}:
        raise ValueError("invalid preset")
    return value


def validate_i1_overrides(value):
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise ValueError("invalid client_i1")
    peers = {peer["name"] for peer in parse_peers()}
    clean = {}
    for name, i1 in value.items():
        clean_name = safe_name(name)
        if clean_name not in peers:
            raise ValueError("unknown client in client_i1")
        clean[clean_name] = validate_i1(i1)
    return clean


def write_i1_overrides_file(overrides):
    if not overrides:
        return None
    WEB_DIR.mkdir(parents=True, exist_ok=True)
    path = WEB_DIR / f".tmp.i1-overrides.{os.getpid()}.{secrets.token_hex(6)}.json"
    path.write_text(json.dumps(overrides, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(path, 0o600)
    return path


def require_server_name(name):
    if not isinstance(name, str) or not name.strip() or not SERVER_NAME_RE.fullmatch(name):
        raise ValueError("invalid server name")
    return name


def require_expires(value):
    if not isinstance(value, str) or not re.fullmatch(r"[1-9][0-9]{0,5}[hdw]", value):
        raise ValueError("invalid expires")
    return value


def require_port(value):
    if isinstance(value, bool) or not isinstance(value, int) or not (1024 <= value <= 65535):
        raise ValueError("invalid port")
    return value


def require_dns_list(value):
    if not isinstance(value, str) or len(value) > 512:
        raise ValueError("invalid dns list")
    items = value.split(",")
    if not items or any(not item.strip() for item in items):
        raise ValueError("invalid dns list")
    out = []
    for item in items:
        try:
            out.append(str(ipaddress.ip_address(item.strip())))
        except ValueError as exc:
            raise ValueError("invalid dns list") from exc
    return ",".join(out)


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


class LimitedThreadingHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 128

    def __init__(self, *args, max_workers=32, request_timeout=8, **kwargs):
        super().__init__(*args, **kwargs)
        self._sem = threading.BoundedSemaphore(max_workers)
        self.request_timeout = request_timeout
        self.handshake_timeout = min(request_timeout, 5)
        self.ssl_context = None

    def get_request(self):
        raw_request, client_address = super().get_request()
        raw_request.settimeout(self.handshake_timeout)
        if not self.ssl_context:
            raw_request.settimeout(self.request_timeout)
            return raw_request, client_address
        try:
            request = self.ssl_context.wrap_socket(
                raw_request,
                server_side=True,
                do_handshake_on_connect=False,
            )
            request.settimeout(self.handshake_timeout)
            request.do_handshake()
            request.settimeout(self.request_timeout)
            return request, client_address
        except (OSError, ssl.SSLError):
            raw_request.close()
            raise

    def handle_error(self, request, client_address):
        exc = sys.exc_info()[1]
        if is_benign_disconnect_error(exc):
            remote = client_address[0] if client_address else "-"
            audit_log(f"Web client disconnected remote={remote} error={exc.__class__.__name__}")
            return
        super().handle_error(request, client_address)

    def process_request(self, request, client_address):
        if not self._sem.acquire(blocking=False):
            try:
                request.close()
            finally:
                return
        try:
            super().process_request(request, client_address)
        except Exception:
            self._sem.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._sem.release()


class Handler(SimpleHTTPRequestHandler):
    server_version = "Panel"
    sys_version = ""

    def log_message(self, fmt, *args):
        return

    def handle_one_request(self):
        try:
            return super().handle_one_request()
        except (socket.timeout, TimeoutError) as exc:
            self.log_client_disconnect(exc)
            self.close_connection = True
            return None
        except (OSError, ssl.SSLError) as exc:
            if not is_benign_disconnect_error(exc):
                raise
            self.log_client_disconnect(exc)
            self.close_connection = True
            return None

    def log_client_disconnect(self, exc):
        remote = self.client_address[0] if getattr(self, "client_address", None) else "-"
        path = getattr(self, "path", "")
        suffix = f" path={path}" if isinstance(path, str) and path.startswith("/") else ""
        audit_log(f"Web client disconnected remote={remote}{suffix} error={exc.__class__.__name__}")

    def write_response_body(self, data):
        try:
            self.wfile.write(data)
            return True
        except (OSError, ssl.SSLError) as exc:
            if not is_benign_disconnect_error(exc):
                raise
            self.log_client_disconnect(exc)
            self.close_connection = True
            return False

    def finish_response_headers(self):
        try:
            self.end_headers()
            return True
        except (OSError, ssl.SSLError) as exc:
            if not is_benign_disconnect_error(exc):
                raise
            self.log_client_disconnect(exc)
            self.close_connection = True
            return False

    def api_auth(self):
        policy = load_access_policy()
        raw_host = self.headers.get("Host", "")
        remote_addr = self.client_address[0]
        if not request_allowed_by_policy(raw_host, remote_addr, policy):
            record_rejected_host(raw_host, remote_addr, self.path)
            audit_log(f"Rejected Web Panel request remote={remote_addr} path={self.path} host={raw_host!r} reason=access policy")
            if self.path.startswith("/api/"):
                self.send_api_error(HTTPStatus.MISDIRECTED_REQUEST, "bad_request")
            else:
                self.send_error(HTTPStatus.MISDIRECTED_REQUEST)
            return None
        if not self.path.startswith("/api/"):
            return {"role": "static"}
        ip = self.client_address[0]
        if not check_rate_limit(ip):
            self.send_api_error(HTTPStatus.TOO_MANY_REQUESTS, "rate_limited")
            return None
        header = self.headers.get("Authorization", "")
        auth = authenticate(header)
        if not auth:
            reason, fingerprint = auth_reject_reason(header)
            suffix = f" fingerprint={fingerprint}" if fingerprint else ""
            audit_log(f"Rejected bearer token remote={ip} path={self.path} reason={reason}{suffix}")
            self.send_api_error(HTTPStatus.UNAUTHORIZED, "unauthorized")
            return None
        return auth

    @staticmethod
    def is_super(auth):
        return auth.get("role") == "super"

    def require_super(self, auth):
        if not self.is_super(auth):
            audit_log(f"Rejected bearer token remote={self.client_address[0]} path={self.path} reason=insufficient scope")
            self.send_api_error(HTTPStatus.FORBIDDEN, "forbidden")
            return False
        return True

    def can_access_client(self, auth, name):
        return self.is_super(auth) or name in set(auth.get("clients") or [])

    def require_client_access(self, auth, name):
        if not self.can_access_client(auth, name):
            audit_log(f"Rejected bearer token remote={self.client_address[0]} path={self.path} reason=insufficient scope")
            self.send_api_error(HTTPStatus.FORBIDDEN, "forbidden")
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
        self.send_security_headers()
        if not self.finish_response_headers():
            return
        self.write_response_body(data)

    def send_api_error(self, status, error):
        self.send_json({"error": error}, status)

    def send_security_headers(self):
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
            "img-src 'self' data: blob:; connect-src 'self'; object-src 'none'; "
            "base-uri 'none'; frame-ancestors 'none'",
        )
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cache-Control", "no-store")

    def json_body(self):
        try:
            size = int(self.headers.get("Content-Length", "0") or 0)
        except (TypeError, ValueError):
            raise ValueError("invalid content length")
        if size < 0:
            raise ValueError("invalid content length")
        if size > MAX_JSON_BODY:
            self.send_error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
            raise ValueError("payload too large")
        return json.loads(self.rfile.read(size).decode("utf-8")) if size else {}

    def send_file(self, path, ctype):
        if not path.exists() or not path.is_file():
            self.send_error(404)
            return
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_security_headers()
        if not self.finish_response_headers():
            return
        self.write_response_body(data)

    def send_config_download(self, name):
        path = AWG_DIR / f"{name}.conf"
        if not path.exists() or not path.is_file():
            self.send_error(404)
            return
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", f'attachment; filename="{name}.conf"')
        self.send_header("Content-Length", str(len(data)))
        self.send_security_headers()
        if not self.finish_response_headers():
            return
        self.write_response_body(data)

    def send_raw_import_config(self, name, token):
        try:
            name = safe_name(name)
            token = require_import_token(token)
        except ValueError:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        if not check_rate_limit(self.client_address[0]):
            self.send_error(HTTPStatus.TOO_MANY_REQUESTS)
            return
        digest = token_hash(token)
        now = int(time.time())
        with IMPORT_TOKENS_LOCK:
            data = load_import_tokens(now=now)
            record = data.get("tokens", {}).get(digest)
            if not record or record.get("client") != name or int(record.get("expires_at") or 0) <= now:
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            path = AWG_DIR / f"{name}.conf"
            if not path.exists() or not path.is_file():
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            text = path.read_text(encoding="utf-8", errors="replace")
            if not text.startswith("[Interface]"):
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            if record.get("one_time"):
                data["tokens"].pop(digest, None)
                write_import_tokens(data)
        body = text.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        if not self.finish_response_headers():
            return
        self.write_response_body(body)

    def do_HEAD(self):
        u = urlparse(self.path)
        if not u.path.startswith("/api/"):
            self.send_error(404)
            return
        auth = self.api_auth()
        if auth is None:
            return
        if u.path != "/api/status":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", "0")
        self.send_security_headers()
        self.finish_response_headers()

    def send_static_file(self, url_path):
        static = STATIC_FILES.get(url_path)
        if static is None:
            self.send_error(404)
            return
        filename, ctype = static
        self.send_file(WEB_DIR / filename, ctype)

    def request_base_url(self):
        host = (self.headers.get("Host") or "").strip()
        if not host or any(ch in host for ch in "/\\\r\n\t "):
            host = f"10.9.9.1:{os.environ.get('AWG_WEB_PORT', '8443')}"
        return f"https://{host}"

    def web_access_policy_payload(self, policy=None):
        policy = policy or load_access_policy()
        raw_host = self.headers.get("Host", "")
        remote_addr = self.client_address[0]
        return {
            "policy": policy,
            "current": {
                "host": raw_host,
                "normalized_host": split_host(raw_host),
                "remote_ip": remote_addr,
                "allowed": request_allowed_by_policy(raw_host, remote_addr, policy),
            },
            "recent_rejected_hosts": recent_rejected_hosts(),
            "requires_restart": policy.get("bind_host") != (os.environ.get("AWG_WEB_BIND") or ""),
        }

    def validate_policy_for_current_request(self, body):
        policy = clean_access_policy(body.get("policy", body))
        raw_host = self.headers.get("Host", "")
        remote_addr = self.client_address[0]
        if not request_allowed_by_policy(raw_host, remote_addr, policy):
            raise ValueError("policy would block the current request")
        if not bind_allows_current_remote(policy.get("bind_host", ""), remote_addr):
            raise ValueError("bind mode would block the current connection after restart")
        return policy

    def create_import_link(self, auth, name, body):
        name = safe_name(name)
        if not self.require_client_access(auth, name):
            return
        path = AWG_DIR / f"{name}.conf"
        if not path.exists() or not path.is_file():
            self.send_json({"error": "client config not found"}, 404)
            return
        ttl = require_import_ttl(body.get("ttl"))
        one_time = body.get("one_time", True)
        if not isinstance(one_time, bool):
            raise ValueError("invalid one_time")
        token = secrets.token_urlsafe(48)
        digest = token_hash(token)
        now = int(time.time())
        with IMPORT_TOKENS_LOCK:
            data = load_import_tokens(now=now)
            data.setdefault("tokens", {})[digest] = {
                "client": name,
                "expires_at": now + ttl,
                "one_time": one_time,
                "created_at": now,
            }
            write_import_tokens(data)
        url = f"{self.request_base_url()}/import/{quote(name)}/{quote(token)}"
        self.send_json({"url": url, "expires_at": now + ttl, "ttl": ttl, "one_time": one_time})

    def do_GET(self):
        auth = self.api_auth()
        if auth is None:
            return
        u = urlparse(self.path)
        if auth["role"] == "static":
            m_import = re.match(r"^/import/([^/]+)/([^/]+)$", u.path)
            if m_import:
                self.send_raw_import_config(unquote(m_import.group(1)), unquote(m_import.group(2)))
                return
            self.send_static_file(u.path)
            return

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
                "display_name": cfg["AWG_SERVER_NAME"],
                "title": PANEL_TITLE,
                "short_label": PANEL_SHORT_LABEL,
                "repository_url": REPOSITORY_URL,
            })
            return
        if u.path == "/api/help/clients":
            self.send_json({"groups": HELP_CLIENT_GROUPS})
            return
        if u.path == "/api/resolver":
            self.send_json(resolver_status())
            return
        if u.path == "/api/dns":
            self.send_json(dns_status())
            return
        if u.path == "/api/clients":
            stats = client_stats_map()
            history = load_traffic_history()
            visible = self.visible_peers(auth)
            all_peers = parse_peers()
            display_counts = {}
            for peer in all_peers:
                display_counts[peer.get("display_name") or peer["name"]] = display_counts.get(peer.get("display_name") or peer["name"], 0) + 1
            assignments = token_assignments_for_clients() if self.is_super(auth) else {}
            rows = []
            for peer in visible:
                item = dict(peer)
                row_stats = stats.get(peer["name"], {})
                item["id"] = peer["name"]
                item["config_name"] = peer["name"]
                item["display_name"] = peer.get("display_name") or peer["name"]
                item["assigned_tokens"] = assignments.get(peer["name"], []) if self.is_super(auth) else []
                item["is_unassigned"] = self.is_super(auth) and not item["assigned_tokens"]
                item["is_duplicate_display_name"] = display_counts.get(item["display_name"], 0) > 1
                item["rx"] = row_stats.get("rx", 0)
                item["tx"] = row_stats.get("tx", 0)
                item["traffic_30d"] = client_traffic_30d(peer["name"], history)
                item["traffic_total"] = client_traffic_total(peer["name"], history)
                item["latestHandshakeAt"] = row_stats.get("latestHandshakeAt", row_stats.get("last_handshake", 0))
                endpoint = row_stats.get("endpoint", "")
                item["endpoint"] = "" if endpoint in {"", "-", "(none)", "none"} else endpoint
                item["status"] = row_stats.get("status", "")
                item["open_ports"] = item.get("p2p_ports", [])
                item["ports_enabled"] = item.get("p2p_enabled", True)
                rows.append(item)
            self.send_json({
                "role": "super" if self.is_super(auth) else "user",
                "clients": rows,
                "traffic": traffic_summary(auth, stats, [peer["name"] for peer in visible]),
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
            self.send_json(traffic_summary(auth, names=[peer["name"] for peer in self.visible_peers(auth)]))
            return
        if u.path == "/api/tokens":
            if not self.require_super(auth):
                return
            data = load_tokens()
            users = [{"hash": key, "name": value["name"], "clients": value["clients"]} for key, value in sorted(data.get("users", {}).items())]
            self.send_json({"users": users})
            return
        if u.path == "/api/web-access-policy":
            if not self.require_super(auth):
                return
            self.send_json(self.web_access_policy_payload())
            return
        if u.path == "/api/server/logs":
            if not self.require_super(auth):
                return
            lines = []
            for f in (AWG_DIR / "manage_amneziawg.log", AWG_DIR / "install_amneziawg.log"):
                if f.exists():
                    lines.extend(tail_lines(f, 100))
            self.send_json({"lines": lines[-100:]})
            return
        m_download = re.match(r"^/api/clients/([^/]+)/config/download$", u.path)
        if m_download:
            name = safe_name(m_download.group(1))
            if not self.require_client_access(auth, name):
                return
            self.send_config_download(name)
            return

        m = re.match(r"^/api/clients/([^/]+)/(config|qr|vpnuri|uri|p2p|ports)$", u.path)
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
        elif kind in {"vpnuri", "uri"}:
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
                display_name = safe_name(body.get("name", ""))
                name, collision = unique_client_config_name(display_name)
                args = []
                if body.get("expires"):
                    args.append(f"--expires={require_expires(body['expires'])}")
                p = run_manage(*args, "add", name)
                if p.returncode == 0:
                    set_client_display_name(name, display_name)
                    if collision:
                        audit_log(
                            "Client display name collision: "
                            f"requested={display_name} created_config={name} "
                            f"actor_role={auth.get('role')} actor_token_fp={(auth.get('hash') or '')[:8]}"
                        )
                    if not self.is_super(auth):
                        mutate_user_clients(auth["hash"], name)
                    self.send_json({
                        "ok": True,
                        "stdout": p.stdout,
                        "stderr": p.stderr,
                        "id": name,
                        "name": name,
                        "config_name": name,
                        "display_name": display_name,
                        "is_duplicate_display_name": collision,
                    })
                    return
            elif u.path == "/api/server/restart":
                if not self.require_super(auth):
                    return
                p = run_manage("restart", timeout=90)
            elif u.path == "/api/server/name":
                if not self.require_super(auth):
                    return
                p = run_manage("set-name", require_server_name(body.get("name", "")), timeout=180)
            elif u.path in {"/api/server/rotate-profile", "/api/profile/rotate"}:
                if not self.require_super(auth):
                    return
                if body.get("confirm") != "ROTATE":
                    raise ValueError("confirmation required")
                preset = require_rotate_preset(body.get("preset", "default"))
                overrides_path = None
                extra_env = {}
                try:
                    overrides = validate_i1_overrides(body.get("client_i1"))
                    overrides_path = write_i1_overrides_file(overrides)
                    if overrides_path is not None:
                        extra_env["AWG_I1_OVERRIDES_FILE"] = str(overrides_path)
                    p = run_manage("server", "rotate-profile", "--preset", preset, timeout=240, extra_env=extra_env)
                finally:
                    if overrides_path is not None:
                        try:
                            overrides_path.unlink()
                        except FileNotFoundError:
                            pass
                if p.returncode == 0:
                    clear_import_tokens()
                    self.send_json({"ok": True, "preset": preset, "message": "Server AWG profile rotated"})
                    return
                self.send_json({"error": "rotate-profile failed"}, 500)
                return
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
                    args.append(require_dns_list(custom))
                p = run_manage(*args, timeout=120)
            elif re.match(r"^/api/clients/[^/]+/regenerate$", u.path):
                name = safe_name(re.match(r"^/api/clients/([^/]+)/regenerate$", u.path).group(1))
                if not self.require_client_access(auth, name):
                    return
                if not any(peer.get("name") == name for peer in parse_peers()):
                    self.send_json({"error": "client not found"}, 404)
                    return
                extra_env = {}
                if "i1" in body and body["i1"] is not None:
                    extra_env["AWG_I1_OVERRIDE"] = validate_i1(body["i1"])
                p = run_manage("client", "regenerate", name, timeout=120, extra_env=extra_env)
                if p.returncode == 0:
                    remove_import_tokens_for_client(name)
                    self.send_json({
                        "ok": True,
                        "client": name,
                        "message": "Config regenerated",
                        "download_url": f"/api/clients/{quote(name)}/config/download",
                    })
                    return
                self.send_json({"error": "regenerate failed"}, 500)
                return
            elif u.path == "/api/tokens":
                if not self.require_super(auth):
                    return
                clients = require_existing_clients(body.get("clients", []))
                name = clean_token_name(body.get("name", ""))
                token = secrets.token_urlsafe(32)
                digest = token_hash(token)
                with TOKENS_LOCK:
                    data = load_tokens()
                    data.setdefault("users", {})[digest] = {"name": name, "clients": clients}
                    write_tokens(data)
                self.send_json({"token": token, "token_hash": digest, "name": name, "clients": clients})
                return
            elif re.match(r"^/api/tokens/[^/]+/rotate$", u.path):
                if not self.require_super(auth):
                    return
                result = rotate_user_token(re.match(r"^/api/tokens/([^/]+)/rotate$", u.path).group(1))
                if result is None:
                    self.send_json({"error": "token not found"}, 404)
                    return
                self.send_json(result)
                return
            elif u.path == "/api/tokens/reset-all":
                if not self.require_super(auth):
                    return
                token = secrets.token_urlsafe(32)
                write_tokens({"super_token_hash": token_hash(token), "users": {}})
                self.send_json({"super_token": token})
                return
            elif u.path == "/api/web-access-policy/test":
                if not self.require_super(auth):
                    return
                policy = self.validate_policy_for_current_request(body)
                self.send_json({"ok": True, **self.web_access_policy_payload(policy)})
                return
            elif u.path == "/api/web-access-policy/restart":
                if not self.require_super(auth):
                    return
                restart_web_panel_later()
                self.send_json({"ok": True, "message": "web panel restart scheduled"})
                return
            else:
                import_link = re.match(r"^/api/clients/([^/]+)/(import-link|access-link)$", u.path)
                if import_link:
                    self.create_import_link(auth, unquote(import_link.group(1)), body)
                    return
                m = re.match(r"^/api/clients/([^/]+)/(p2p|ports|toggle)$", u.path)
                p2p_toggle = re.match(r"^/api/clients/([^/]+)/(p2p|ports)/toggle$", u.path)
                if not m and not p2p_toggle:
                    self.send_error(404)
                    return
                name = safe_name((m or p2p_toggle).group(1))
                if not self.require_client_access(auth, name):
                    return
                if p2p_toggle:
                    p = run_manage("p2p", "toggle", name, timeout=45)
                elif m.group(2) == "toggle":
                    p = run_manage("toggle", name, timeout=45)
                else:
                    args = ["p2p", "add", name]
                    if "port" in body and body["port"] is not None:
                        args.append(str(require_port(body["port"])))
                    p = run_manage(*args)
            self.send_json({"ok": p.returncode == 0, "stdout": p.stdout, "stderr": p.stderr}, 200 if p.returncode == 0 else 400)
        except ValueError as exc:
            if str(exc) == "payload too large":
                return
            self.send_json({"error": str(exc)}, 400)


    def do_PUT(self):
        auth = self.api_auth()
        if auth is None:
            return
        u = urlparse(self.path)
        try:
            if u.path == "/api/web-access-policy":
                if not self.require_super(auth):
                    return
                body = self.json_body()
                policy = self.validate_policy_for_current_request(body)
                write_access_policy(policy)
                self.send_json({"ok": True, **self.web_access_policy_payload(policy)})
                return
            name_update = re.match(r"^/api/tokens/([^/]+)/name$", u.path)
            clients_update = re.match(r"^/api/tokens/([^/]+)/clients$", u.path)
            m = name_update or clients_update
            if not m:
                self.send_error(404)
                return
            if not self.require_super(auth):
                return
            digest = safe_token_hash(m.group(1))
            body = self.json_body()
            with TOKENS_LOCK:
                data = load_tokens()
                if digest not in data.get("users", {}):
                    self.send_json({"error": "token not found"}, 404)
                    return
                record = clean_user_record(data["users"][digest])
                if name_update:
                    record["name"] = clean_token_name(body.get("name", ""))
                else:
                    record["clients"] = require_existing_clients(body.get("clients", []))
                data["users"][digest] = record
                write_tokens(data)
            self.send_json({"ok": True, "hash": digest, "name": record["name"], "clients": record["clients"]})
        except ValueError as exc:
            if str(exc) == "payload too large":
                return
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
                if self.is_super(auth):
                    p = run_manage("remove", name)
                    if p.returncode == 0:
                        remove_client_from_all_tokens(name)
                        remove_client_metadata(name)
                    self.send_json({"ok": p.returncode == 0, "stdout": p.stdout, "stderr": p.stderr}, 200 if p.returncode == 0 else 400)
                    return
                mutate_user_clients(auth["hash"], name, remove=True)
                self.send_json({"ok": True, "removed_access": True, "client": name})
                return
            else:
                m = re.match(r"^/api/clients/([^/]+)/p2p$", u.path)
                if m:
                    name = safe_name(m.group(1))
                    if not self.require_client_access(auth, name):
                        return
                    port = (parse_qs(u.query).get("port") or [""])[0]
                    if not port.isdigit():
                        raise ValueError("invalid port")
                    port = str(require_port(int(port)))
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
            if str(exc) == "payload too large":
                return
            self.send_json({"error": str(exc)}, 400)


def main():
    load_tokens()
    policy = load_access_policy()
    os.chdir(WEB_DIR)
    bind_host = policy.get("bind_host") or os.environ.get("AWG_WEB_BIND") or "10.9.9.1"
    httpd = LimitedThreadingHTTPServer((bind_host, int(os.environ.get("AWG_WEB_PORT", "8443"))), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(WEB_DIR / "cert.pem", WEB_DIR / "key.pem")
    httpd.ssl_context = ctx
    httpd.serve_forever()


if __name__ == "__main__":
    main()
