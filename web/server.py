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
from urllib.error import URLError
from urllib.request import urlopen

AWG_DIR = Path(os.environ.get("AWG_DIR", "/root/awg"))
WEB_DIR = AWG_DIR / "web"
MANAGE = AWG_DIR / "manage_amneziawg.sh"
SERVER_CONF = Path(os.environ.get("SERVER_CONF_FILE", "/etc/amnezia/amneziawg/awg0.conf"))
TOKEN_FILE = WEB_DIR / "tokens.json"
IMPORT_TOKEN_FILE = WEB_DIR / "import_tokens.json"
ACCESS_POLICY_FILE = WEB_DIR / "access_policy.json"
TRAFFIC_FILE = WEB_DIR / "traffic_history.json"
CLIENT_METADATA_FILE = WEB_DIR / "client_metadata.json"
IP_INFO_CACHE_FILE = WEB_DIR / "ip_cache.json"
NETTEST_REPORT_DIR = WEB_DIR / "nettest_reports"
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
IP_INFO_CACHE_LOCK = threading.Lock()
REJECTED_HOST_LOCK = threading.Lock()
RECENT_REJECTED_HOSTS = deque(maxlen=25)
STATS_CACHE_LOCK = threading.Lock()
STATS_CACHE_COND = threading.Condition(STATS_CACHE_LOCK)
STATS_CACHE_VALUE = None
STATS_CACHE_TS = 0.0
STATS_CACHE_INFLIGHT = False
STATS_CACHE_TTL = 3.0
STATS_CACHE_WAIT_TIMEOUT = 2.0
SERVER_PROCESS_STARTED_AT = time.time()
SERVER_HEALTH_CACHE_TTL = 5.0
SERVER_HEALTH_LOCK = threading.Lock()
SERVER_HEALTH_CACHE = None
SERVER_HEALTH_CACHE_TS = 0.0
SERVER_HEALTH_PREV_CPU = None
SERVER_HEALTH_PREV_NET = {}
NETTEST_LOCK = threading.Lock()
NETTEST_ACTIVE = {}
NETTEST_LAST_REPORT = {}
NETTEST_REPORT_TIMES = {}
NETTEST_ACTIVE_TTL = 120.0
NETTEST_REPORT_COOLDOWN = 60.0
NETTEST_REPORTS_PER_HOUR = 12
NETTEST_DEFAULT_DOWNLOAD_SIZE = 256 * 1024
NETTEST_MAX_DOWNLOAD_SIZE = 1024 * 1024
NETTEST_MAX_UPLOAD_SIZE = 512 * 1024
NETTEST_MAX_REPORT_JSON = 256 * 1024
IP_INFO_CACHE_TTL = 7 * 24 * 3600
IP_INFO_NEGATIVE_TTL = 3600
IP_INFO_LOOKUP_TIMEOUT = 2.0
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


def auth_fingerprint(auth):
    return (auth.get("hash") or "")[:8] if isinstance(auth, dict) else ""


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
        if host and host not in {"0.0.0.0", "::"} and host not in hosts:
            hosts.append(host)
    return hosts


def default_access_policy():
    bind = os.environ.get("AWG_WEB_BIND") or "10.9.9.1"
    if bind in {"0.0.0.0", "::"}:
        mode = "public"
        source_cidrs = ["0.0.0.0/0", "::/0"]
    elif bind in {"127.0.0.1", "::1"}:
        mode = "public_nginx"
        bind = "127.0.0.1"
        source_cidrs = ["0.0.0.0/0", "::/0"]
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
        "trusted_proxy_cidrs": ["127.0.0.0/8", "::1/128"],
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
    modes = {
        "public", "vpn_only", "localhost_only", "custom",
        "public_nginx", "restricted_nginx", "vpn_only_nginx", "localhost_maintenance",
    }
    if mode not in modes:
        raise ValueError("invalid bind_mode")
    if mode == "public":
        bind_host = "0.0.0.0"
    elif mode in {"localhost_only", "public_nginx", "restricted_nginx", "vpn_only_nginx", "localhost_maintenance"}:
        bind_host = "127.0.0.1"
    elif mode == "vpn_only":
        bind_host = clean_bind_host(data.get("bind_host") or "0.0.0.0")
    else:
        bind_host = clean_bind_host(data.get("bind_host"))
    host_check_enabled = bool(data.get("host_check_enabled", defaults["host_check_enabled"]))
    source_check_enabled = bool(data.get("source_check_enabled", defaults["source_check_enabled"]))
    allowed_hosts = clean_allowed_hosts(data.get("allowed_hosts", defaults["allowed_hosts"]))
    allowed_source_cidrs = clean_cidr_list(data.get("allowed_source_cidrs", defaults["allowed_source_cidrs"]))
    trusted_proxy_cidrs = clean_cidr_list(data.get("trusted_proxy_cidrs", defaults["trusted_proxy_cidrs"]), "trusted_proxy_cidrs")
    if mode == "public":
        source_check_enabled = False
        allowed_hosts = ensure_items(allowed_hosts, ["194-180-189-244.sslip.io", "194.180.189.244", "localhost", "127.0.0.1"])
    elif mode == "public_nginx":
        source_check_enabled = False
        allowed_hosts = ensure_items(allowed_hosts, ["194-180-189-244.sslip.io", "194.180.189.244", "localhost", "127.0.0.1"])
        trusted_proxy_cidrs = ensure_items(trusted_proxy_cidrs, ["127.0.0.0/8", "::1/128"])
        if not allowed_source_cidrs:
            allowed_source_cidrs = ["0.0.0.0/0", "::/0"]
    elif mode == "restricted_nginx":
        source_check_enabled = True
        trusted_proxy_cidrs = ensure_items(trusted_proxy_cidrs, ["127.0.0.0/8", "::1/128"])
        allowed_hosts = ensure_items(allowed_hosts, ["194-180-189-244.sslip.io", "194.180.189.244", "localhost", "127.0.0.1"])
    elif mode == "vpn_only_nginx":
        source_check_enabled = True
        trusted_proxy_cidrs = ensure_items(trusted_proxy_cidrs, ["127.0.0.0/8", "::1/128"])
        allowed_hosts = ensure_items(allowed_hosts, ["194-180-189-244.sslip.io", "194.180.189.244", "localhost", "127.0.0.1"])
        if not allowed_source_cidrs or any(cidr in {"0.0.0.0/0", "::/0"} for cidr in allowed_source_cidrs):
            allowed_source_cidrs = ["10.9.9.0/24", "127.0.0.0/8", "::1/128"]
    elif mode == "localhost_maintenance":
        source_check_enabled = True
        trusted_proxy_cidrs = ensure_items(trusted_proxy_cidrs, ["127.0.0.0/8", "::1/128"])
        allowed_hosts = ensure_items(allowed_hosts, ["localhost", "127.0.0.1"])
        allowed_source_cidrs = ["127.0.0.0/8", "::1/128"]
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
        "trusted_proxy_cidrs": trusted_proxy_cidrs,
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


def trusted_proxy_allowed(socket_remote_addr, policy):
    try:
        remote_ip = ipaddress.ip_address(socket_remote_addr)
    except ValueError:
        return False
    for cidr in policy.get("trusted_proxy_cidrs", []):
        try:
            if remote_ip in ipaddress.ip_network(cidr, strict=False):
                return True
        except ValueError:
            continue
    return False


def first_forwarded_ip(headers):
    raw_xff = ""
    if headers:
        raw_xff = headers.get("X-Forwarded-For", "") if hasattr(headers, "get") else ""
    for part in str(raw_xff or "").split(","):
        candidate = part.strip()
        if not candidate:
            continue
        try:
            return str(ipaddress.ip_address(split_host(candidate)))
        except ValueError:
            continue
    raw_real = headers.get("X-Real-IP", "") if headers and hasattr(headers, "get") else ""
    try:
        return str(ipaddress.ip_address(split_host(str(raw_real or "").strip())))
    except ValueError:
        return ""


def client_ip_context(socket_remote_addr, headers, policy):
    socket_remote_ip = str(socket_remote_addr or "")
    trusted = trusted_proxy_allowed(socket_remote_ip, policy)
    forwarded_ip = first_forwarded_ip(headers) if trusted else ""
    client_ip = forwarded_ip or socket_remote_ip
    return {
        "socket_remote_ip": socket_remote_ip,
        "client_ip": client_ip,
        "proxy_ip": socket_remote_ip if trusted and forwarded_ip else "",
        "trusted_proxy_used": bool(trusted and forwarded_ip),
    }


def host_allowed(raw_host, remote_addr, policy, trusted_proxy_used=False):
    host = split_host(raw_host)
    if not host:
        return False
    if not policy.get("host_check_enabled"):
        return True
    if remote_addr in {"127.0.0.1", "::1"} and not trusted_proxy_used:
        return True
    if policy.get("bind_host") in {"127.0.0.1", "::1"} and not trusted_proxy_used:
        return host in {"localhost", "127.0.0.1", "::1"}
    return host in set(policy.get("allowed_hosts") or [])


def request_allowed_by_policy(raw_host, remote_addr, policy, client_addr=None, trusted_proxy_used=False):
    source_addr = client_addr or remote_addr
    return host_allowed(raw_host, remote_addr, policy, trusted_proxy_used) and source_allowed(source_addr, policy)


def policy_uses_local_nginx_proxy(policy, headers=None, trusted_proxy_used=False):
    bind_host = str(policy.get("bind_host") or "")
    mode = str(policy.get("bind_mode") or "")
    if mode in {"public_nginx", "restricted_nginx", "vpn_only_nginx", "localhost_maintenance"}:
        return True
    if bind_host not in {"127.0.0.1", "::1"}:
        return False
    if trusted_proxy_used:
        return True
    if headers and hasattr(headers, "get") and headers.get("X-Forwarded-Proto"):
        return True
    return any(cidr in set(policy.get("trusted_proxy_cidrs") or []) for cidr in ("127.0.0.0/8", "::1/128"))


def web_access_edge_info(policy, headers=None, trusted_proxy_used=False):
    port = str(os.environ.get("AWG_WEB_PORT") or "8443")
    bind = str(os.environ.get("AWG_WEB_BIND") or policy.get("bind_host") or "")
    nginx_mode = policy_uses_local_nginx_proxy(policy, headers, trusted_proxy_used)
    if nginx_mode:
        return {
            "mode": "nginx_reverse_proxy",
            "label": "nginx reverse proxy",
            "nginx_active": True,
            "public_listener": "0.0.0.0:443",
            "backend_listener": f"127.0.0.1:{port}",
            "backend_protocol": "HTTPS",
            "source_check_target": "client_ip",
        }
    return {
        "mode": "legacy_direct",
        "label": "legacy direct Python listener",
        "nginx_active": False,
        "public_listener": f"{bind}:{port}" if bind else f":{port}",
        "backend_listener": f"{bind}:{port}" if bind else f":{port}",
        "backend_protocol": "HTTPS",
        "source_check_target": "remote_ip",
    }


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
    policy = load_access_policy()
    return host_allowed(raw_host, remote_addr, policy)


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


def read_text_file(path, default=""):
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except (OSError, UnicodeDecodeError):
        return default


def read_int_file(path):
    try:
        return int(read_text_file(path, ""))
    except (TypeError, ValueError):
        return None


def status_from_percent(value, warn, critical):
    if value is None:
        return "unknown"
    if value >= critical:
        return "critical"
    if value >= warn:
        return "warn"
    return "ok"


def status_from_available_percent(value, warn_below, critical_below):
    if value is None:
        return "unknown"
    if value <= critical_below:
        return "critical"
    if value <= warn_below:
        return "warn"
    return "ok"


def combine_status(*statuses):
    order = {"unknown": 0, "ok": 1, "warn": 2, "critical": 3}
    reverse = {0: "unknown", 1: "ok", 2: "warn", 3: "critical"}
    return reverse[max(order.get(status, 0) for status in statuses if status)]


def read_loadavg():
    raw = read_text_file("/proc/loadavg")
    parts = raw.split()
    try:
        one, five, fifteen = (float(parts[0]), float(parts[1]), float(parts[2]))
    except (IndexError, ValueError):
        one = five = fifteen = 0.0
    return {
        "one": one,
        "five": five,
        "fifteen": fifteen,
        "cpu_count": os.cpu_count() or 1,
    }


def read_cpu_times():
    raw = read_text_file("/proc/stat")
    first = raw.splitlines()[0].split() if raw else []
    if not first or first[0] != "cpu":
        return None
    values = []
    for item in first[1:]:
        try:
            values.append(int(item))
        except ValueError:
            values.append(0)
    if len(values) < 4:
        return None
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    return {"total": sum(values), "idle": idle}


def read_meminfo():
    data = {}
    for line in read_text_file("/proc/meminfo").splitlines():
        if ":" not in line:
            continue
        key, rest = line.split(":", 1)
        parts = rest.strip().split()
        if not parts:
            continue
        try:
            data[key] = int(parts[0]) * 1024
        except ValueError:
            continue
    total = data.get("MemTotal", 0)
    available = data.get("MemAvailable", 0)
    swap_total = data.get("SwapTotal", 0)
    swap_free = data.get("SwapFree", 0)
    used_percent = (100.0 * (total - available) / total) if total else None
    available_percent = (100.0 * available / total) if total else None
    swap_used_percent = (100.0 * (swap_total - swap_free) / swap_total) if swap_total else 0.0
    return {
        "total_bytes": total,
        "available_bytes": available,
        "used_percent": used_percent,
        "swap_total_bytes": swap_total,
        "swap_free_bytes": swap_free,
        "swap_used_percent": swap_used_percent,
        "status": status_from_available_percent(available_percent, 20.0, 10.0),
    }


def disk_health(path="/"):
    try:
        stats = os.statvfs(path)
    except OSError:
        return {"path": path, "status": "unknown"}
    total = stats.f_blocks * stats.f_frsize
    free = stats.f_bavail * stats.f_frsize
    used_percent = (100.0 * (total - free) / total) if total else None
    return {
        "path": path,
        "total_bytes": total,
        "free_bytes": free,
        "used_percent": used_percent,
        "status": status_from_percent(used_percent, 80.0, 90.0),
    }


def detect_wan_iface():
    route = read_text_file("/proc/net/route")
    for line in route.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "00000000":
            return parts[0]
    try:
        names = sorted(path.name for path in Path("/sys/class/net").iterdir())
    except OSError:
        return ""
    skip_prefixes = ("lo", "awg", "wg", "docker", "br-", "veth")
    for name in names:
        if not name.startswith(skip_prefixes):
            return name
    return ""


def detect_vpn_iface():
    base = Path("/sys/class/net")
    for candidate in ("awg0", "wg0"):
        if (base / candidate).exists():
            return candidate
    try:
        for path in sorted(base.iterdir()):
            if "awg" in path.name.lower() or "wg" in path.name.lower():
                return path.name
    except OSError:
        pass
    return ""


def read_iface_stats(iface):
    if not iface:
        return None
    stats_dir = Path("/sys/class/net") / iface / "statistics"
    if not stats_dir.exists():
        return None
    keys = ("rx_bytes", "tx_bytes", "rx_dropped", "tx_dropped", "rx_errors", "tx_errors")
    out = {}
    for key in keys:
        value = read_int_file(stats_dir / key)
        out[key] = 0 if value is None else value
    out["operstate"] = read_text_file(Path("/sys/class/net") / iface / "operstate", "unknown")
    return out


def iface_delta(name, current):
    global SERVER_HEALTH_PREV_NET
    previous = SERVER_HEALTH_PREV_NET.get(name) if current else None
    SERVER_HEALTH_PREV_NET[name] = dict(current or {})
    if not current or not previous:
        return {"drops_delta": 0, "errors_delta": 0}
    drop_keys = ("rx_dropped", "tx_dropped")
    error_keys = ("rx_errors", "tx_errors")
    return {
        "drops_delta": sum(max(0, int(current.get(k, 0)) - int(previous.get(k, 0))) for k in drop_keys),
        "errors_delta": sum(max(0, int(current.get(k, 0)) - int(previous.get(k, 0))) for k in error_keys),
    }


def conntrack_health():
    count = read_int_file("/proc/sys/net/netfilter/nf_conntrack_count")
    max_count = read_int_file("/proc/sys/net/netfilter/nf_conntrack_max")
    if count is None or max_count in (None, 0):
        return {"available": False, "status": "unknown"}
    used_percent = 100.0 * count / max_count
    return {
        "available": True,
        "count": count,
        "max": max_count,
        "used_percent": used_percent,
        "status": status_from_percent(used_percent, 60.0, 85.0),
    }


def process_health():
    status = read_text_file("/proc/self/status")
    values = {}
    for line in status.splitlines():
        if ":" not in line:
            continue
        key, rest = line.split(":", 1)
        values[key] = rest.strip()
    def kb_value(key):
        raw = values.get(key, "0").split()
        try:
            return int(raw[0]) * 1024
        except (IndexError, ValueError):
            return 0
    try:
        fd_count = len(list(Path("/proc/self/fd").iterdir()))
    except OSError:
        fd_count = 0
    try:
        threads = int(values.get("Threads", "0").split()[0])
    except (IndexError, ValueError):
        threads = 0
    return {
        "rss_bytes": kb_value("VmRSS"),
        "vm_size_bytes": kb_value("VmSize"),
        "fd_count": fd_count,
        "threads": threads,
        "uptime_seconds": max(0, int(time.time() - SERVER_PROCESS_STARTED_AT)),
        "status": "ok",
    }


def collect_server_health(force=False):
    global SERVER_HEALTH_CACHE, SERVER_HEALTH_CACHE_TS, SERVER_HEALTH_PREV_CPU
    now = time.time()
    with SERVER_HEALTH_LOCK:
        if not force and SERVER_HEALTH_CACHE and now - SERVER_HEALTH_CACHE_TS < SERVER_HEALTH_CACHE_TTL:
            return SERVER_HEALTH_CACHE

        load = read_loadavg()
        cpu_times = read_cpu_times()
        usage_percent = None
        if cpu_times and SERVER_HEALTH_PREV_CPU:
            total_delta = max(0, cpu_times["total"] - SERVER_HEALTH_PREV_CPU["total"])
            idle_delta = max(0, cpu_times["idle"] - SERVER_HEALTH_PREV_CPU["idle"])
            if total_delta:
                usage_percent = max(0.0, min(100.0, 100.0 * (1.0 - idle_delta / total_delta)))
        if cpu_times:
            SERVER_HEALTH_PREV_CPU = cpu_times

        memory = read_meminfo()
        disk = disk_health("/")
        conntrack = conntrack_health()
        process = process_health()
        wan_iface = detect_wan_iface()
        vpn_iface = detect_vpn_iface()
        wan_stats = read_iface_stats(wan_iface)
        vpn_stats = read_iface_stats(vpn_iface)
        wan_delta = iface_delta(wan_iface or "wan", wan_stats)
        vpn_delta = iface_delta(vpn_iface or "vpn", vpn_stats)
        drops_delta = wan_delta["drops_delta"] + vpn_delta["drops_delta"]
        errors_delta = wan_delta["errors_delta"] + vpn_delta["errors_delta"]
        network_status = "warn" if drops_delta or errors_delta else "ok"
        awg_status = "ok" if vpn_stats and vpn_stats.get("operstate") in {"up", "unknown"} else ("unknown" if not vpn_iface else "warn")
        cpu_status = status_from_percent(usage_percent, 75.0, 90.0) if usage_percent is not None else "ok"
        load_ratio = load["one"] / max(1, load["cpu_count"])
        if load_ratio >= 4.0:
            load_status = "critical"
        elif load_ratio >= 2.0:
            load_status = "warn"
        else:
            load_status = "ok"
        overall = combine_status(cpu_status, load_status, memory["status"], disk["status"], conntrack["status"], network_status, awg_status, process["status"])
        payload = {
            "ok": overall in {"ok", "unknown"},
            "timestamp": utc_now_iso(),
            "cache_ttl_seconds": SERVER_HEALTH_CACHE_TTL,
            "status": overall,
            "load": {**load, "status": load_status},
            "cpu": {"usage_percent": usage_percent, "status": cpu_status},
            "memory": memory,
            "disk": disk,
            "network": {
                "wan_iface": wan_iface,
                "vpn_iface": vpn_iface,
                "wan": wan_stats or {},
                "vpn": vpn_stats or {},
                "wan_drops_delta": wan_delta["drops_delta"],
                "vpn_drops_delta": vpn_delta["drops_delta"],
                "drops_delta": drops_delta,
                "errors_delta": errors_delta,
                "status": network_status,
            },
            "conntrack": conntrack,
            "process": process,
            "services": {
                "python_backend": {"status": "ok", "listener": "127.0.0.1:8443"},
                "nginx_edge": {"status": "unknown", "listener": "0.0.0.0:443"},
                "vpn_interface": {"status": awg_status, "name": vpn_iface},
            },
        }
        SERVER_HEALTH_CACHE = payload
        SERVER_HEALTH_CACHE_TS = now
        return payload


def json_body_from_handler(handler, max_size):
    try:
        size = int(handler.headers.get("Content-Length", "0") or 0)
    except (TypeError, ValueError):
        raise ValueError("invalid content length")
    if size < 0:
        raise ValueError("invalid content length")
    if size > max_size:
        handler.send_error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
        raise ValueError("payload too large")
    raw = handler.rfile.read(size) if size else b"{}"
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ValueError("invalid json")
    if not isinstance(value, dict):
        raise ValueError("invalid json")
    return value


def token_alias_for_auth(auth):
    if not isinstance(auth, dict) or auth.get("role") == "super":
        return "super"
    try:
        record = load_tokens().get("users", {}).get(auth.get("hash"), {})
    except Exception:
        record = {}
    if isinstance(record, dict):
        return clean_token_name(record.get("name", ""))
    return ""


def request_client_context(handler):
    policy = load_access_policy()
    remote_addr = handler.client_address[0] if getattr(handler, "client_address", None) else ""
    return client_ip_context(remote_addr, handler.headers, policy)


def clean_network_type(value):
    value = str(value or "").strip().lower()
    if value not in {"mobile", "home"}:
        raise ValueError("invalid network type")
    return value


def clean_report_comment(value):
    value = str(value or "").strip()
    value = re.sub(r"[\x00-\x1f\x7f]+", " ", value)
    return value[:240]


def clean_nettest_id(value):
    value = str(value or "").strip()
    if not value:
        return ""
    if not re.fullmatch(r"[A-Za-z0-9_-]{8,80}", value):
        raise ValueError("invalid test id")
    return value


def nettest_rate_key(auth, client_ip):
    fp = auth_fingerprint(auth)
    return fp or hashlib.sha256(str(client_ip or "unknown").encode("utf-8")).hexdigest()[:8]


def reserve_nettest_session(auth, client_ip, test_id, now=None):
    if not test_id:
        return True
    now = time.time() if now is None else now
    key = nettest_rate_key(auth, client_ip)
    with NETTEST_LOCK:
        for item_key, item in list(NETTEST_ACTIVE.items()):
            if float(item.get("expires_at") or 0) <= now:
                NETTEST_ACTIVE.pop(item_key, None)
        current = NETTEST_ACTIVE.get(key)
        if current and current.get("test_id") != test_id and float(current.get("expires_at") or 0) > now:
            return False
        NETTEST_ACTIVE[key] = {"test_id": test_id, "expires_at": now + NETTEST_ACTIVE_TTL}
        return True


def clear_nettest_session(auth, client_ip, test_id):
    if not test_id:
        return
    key = nettest_rate_key(auth, client_ip)
    with NETTEST_LOCK:
        current = NETTEST_ACTIVE.get(key)
        if current and current.get("test_id") == test_id:
            NETTEST_ACTIVE.pop(key, None)


def check_nettest_report_rate(auth, client_ip, now=None):
    now = time.time() if now is None else now
    key = nettest_rate_key(auth, client_ip)
    with NETTEST_LOCK:
        recent = [stamp for stamp in NETTEST_REPORT_TIMES.get(key, []) if now - stamp < 3600]
        last = NETTEST_LAST_REPORT.get(key, 0)
        if now - last < NETTEST_REPORT_COOLDOWN or len(recent) >= NETTEST_REPORTS_PER_HOUR:
            NETTEST_REPORT_TIMES[key] = recent
            return False
        recent.append(now)
        NETTEST_LAST_REPORT[key] = now
        NETTEST_REPORT_TIMES[key] = recent
        return True


def nettest_context_payload():
    mtu = None
    keepalive = None
    try:
        text = SERVER_CONF.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        text = ""
    mtu_match = re.search(r"(?im)^\s*MTU\s*=\s*(\d+)\s*$", text)
    keepalive_match = re.search(r"(?im)^\s*PersistentKeepalive\s*=\s*(\d+)\s*$", text)
    if mtu_match:
        mtu = int(mtu_match.group(1))
    if keepalive_match:
        keepalive = int(keepalive_match.group(1))
    return {
        "preset": "mobile" if mtu == 1280 or keepalive == 25 else "default",
        "mtu": mtu,
        "persistent_keepalive": keepalive,
        "route_mode": "amnezia-routes",
        "ipv6_mode": "routed",
        "p2p_ports_per_client": 3,
    }


def nettest_assessment(report):
    latency = report.get("latency") if isinstance(report.get("latency"), dict) else {}
    download_probe = report.get("download_probe") if isinstance(report.get("download_probe"), dict) else {}
    upload_probe = report.get("upload_probe") if isinstance(report.get("upload_probe"), dict) else {}
    loss = float(latency.get("loss_percent") or 0)
    jitter = float(latency.get("jitter_ms") or 0)
    stalls = int(latency.get("stall_events") or 0)
    quality = "good"
    summary = "Parameters look OK"
    recommendations = []
    if loss > 10 or stalls >= 3:
        quality = "poor"
        summary = "Repeated timeout bursts detected"
    elif loss >= 2 or jitter >= 30 or stalls:
        quality = "warning"
        summary = "Burst loss or jitter detected"
    if download_probe.get("ok") is False and upload_probe.get("ok") is not False:
        recommendations.append("Download probe is weak while upload is OK; check client receive path and tunnel stability.")
    if upload_probe.get("ok") is False and download_probe.get("ok") is not False:
        recommendations.append("Upload probe is weak while download is OK; check client uplink and local network.")
    if loss > 0 or stalls:
        recommendations.append("Run ping to VPN server IP and 1.1.1.1 during the same stall window.")
    if not recommendations:
        recommendations.append("No obvious browser-side issue detected.")
    return {"quality": quality, "summary": summary, "recommendations": recommendations[:4]}


def save_nettest_report(auth, handler, body):
    network_type = clean_network_type(body.get("network_type"))
    test_id = clean_nettest_id(body.get("test_id", ""))
    client_ctx = request_client_context(handler)
    client_ip = client_ctx.get("client_ip") or ""
    if not check_nettest_report_rate(auth, client_ip):
        raise ValueError("nettest report rate limited")
    token_fp = auth_fingerprint(auth) or hashlib.sha256(client_ip.encode("utf-8")).hexdigest()[:8]
    created_at = utc_now_iso()
    stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    NETTEST_REPORT_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(NETTEST_REPORT_DIR, 0o700)
    browser = body.get("browser_connection") if isinstance(body.get("browser_connection"), dict) else {}
    latency = body.get("latency") if isinstance(body.get("latency"), dict) else {}
    download_probe = body.get("download_probe") if isinstance(body.get("download_probe"), dict) else {}
    upload_probe = body.get("upload_probe") if isinstance(body.get("upload_probe"), dict) else {}
    report = {
        "version": 1,
        "created_at": created_at,
        "test_id": test_id,
        "network_type": network_type,
        "comment": clean_report_comment(body.get("comment", "")),
        "token_fp": token_fp,
        "token_alias": token_alias_for_auth(auth),
        "token_role": auth.get("role"),
        "client_ip": client_ip,
        "socket_remote_ip": client_ctx.get("socket_remote_ip"),
        "trusted_proxy_used": bool(client_ctx.get("trusted_proxy_used")),
        "user_agent": str(body.get("user_agent") or handler.headers.get("User-Agent", ""))[:500],
        "browser_connection": browser,
        "latency": latency,
        "download_probe": download_probe,
        "upload_probe": upload_probe,
        "context": nettest_context_payload(),
    }
    report["assessment"] = nettest_assessment(report)
    filename = f"nettest_{network_type}_{stamp}_{token_fp}.json"
    path = NETTEST_REPORT_DIR / filename
    tmp = NETTEST_REPORT_DIR / f".{filename}.tmp.{os.getpid()}"
    tmp.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    os.chmod(path, 0o600)
    clear_nettest_session(auth, client_ip, test_id)
    audit_log(f"Saved network test report type={network_type} actor_role={auth.get('role')} actor_fp={token_fp} client_ip={client_ip}")
    return {"ok": True, "filename": filename, "report": report}


def list_nettest_reports(limit=30):
    if not NETTEST_REPORT_DIR.exists():
        return []
    rows = []
    for path in sorted(NETTEST_REPORT_DIR.glob("nettest_*.json"), key=lambda item: item.stat().st_mtime, reverse=True)[:limit]:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            continue
        if not isinstance(data, dict):
            continue
        rows.append({
            "filename": path.name,
            "created_at": data.get("created_at"),
            "network_type": data.get("network_type"),
            "token_fp": data.get("token_fp"),
            "token_alias": data.get("token_alias"),
            "client_ip": data.get("client_ip"),
            "assessment": data.get("assessment", {}),
            "latency": data.get("latency", {}),
            "download_probe": data.get("download_probe", {}),
            "upload_probe": data.get("upload_probe", {}),
        })
    return rows


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
    clean = {"display_name": display_name}
    for key in ("created_by_fp", "last_unassigned_by_fp"):
        raw = value.get(key)
        if isinstance(raw, str) and re.fullmatch(r"[0-9a-f]{6,16}", raw):
            clean[key] = raw
    for key in ("created_by_role",):
        raw = value.get(key)
        if raw in {"user", "super", "admin"}:
            clean[key] = raw
    for key in ("created_at", "last_unassigned_at"):
        raw = value.get(key)
        if isinstance(raw, str) and re.fullmatch(r"[0-9T:Z+.-]{10,40}", raw):
            clean[key] = raw
    return clean


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


def utc_now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def set_client_metadata(config_name, display_name, auth=None):
    config_name = safe_name(config_name)
    display_name = safe_name(display_name)
    data = load_client_metadata()
    record = data.setdefault("clients", {}).get(config_name, {})
    if not isinstance(record, dict):
        record = {}
    record["display_name"] = display_name
    if auth is not None:
        record["created_by_fp"] = auth_fingerprint(auth)
        record["created_by_role"] = auth.get("role", "")
        record["created_at"] = utc_now_iso()
    data.setdefault("clients", {})[config_name] = record
    write_client_metadata(data)


def set_client_display_name(config_name, display_name):
    set_client_metadata(config_name, display_name)


def remove_client_metadata(config_name):
    config_name = safe_name(config_name)
    data = load_client_metadata()
    if data.get("clients", {}).pop(config_name, None) is not None:
        write_client_metadata(data)


def rollback_created_client(config_name):
    config_name = safe_name(config_name)
    p = run_manage("remove", config_name, timeout=90)
    if p.returncode == 0:
        remove_client_metadata(config_name)
        remove_import_tokens_for_client(config_name)
        remove_client_from_all_tokens(config_name)
        return True
    return False


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


def assignment_records_for_client(config_name):
    config_name = safe_name(config_name)
    data = load_tokens()
    out = []
    for digest, value in sorted(data.get("users", {}).items()):
        record = clean_user_record(value)
        if config_name in record.get("clients", []):
            out.append({"hash": digest, "fingerprint": digest[:6], "alias": record.get("name") or f"token: {digest[:6]}", "role": "user"})
    return out


def client_metadata_record(config_name):
    return load_client_metadata().get("clients", {}).get(safe_name(config_name), {})


def is_client_created_by_token(config_name, token_fp):
    record = client_metadata_record(config_name)
    return record.get("created_by_role") == "user" and record.get("created_by_fp") == token_fp


def can_user_delete_client(config_name, auth):
    if not auth or auth.get("role") == "super":
        return False, "not_user"
    config_name = safe_name(config_name)
    actor_fp = auth_fingerprint(auth)
    if not is_client_created_by_token(config_name, actor_fp):
        return False, "missing_metadata"
    assignments = assignment_records_for_client(config_name)
    if len(assignments) != 1:
        return False, "shared" if assignments else "unassigned"
    if assignments[0].get("hash") != auth.get("hash"):
        return False, "not_owner"
    return True, "ok"


def mark_client_unassigned(config_name, auth):
    config_name = safe_name(config_name)
    data = load_client_metadata()
    record = data.setdefault("clients", {}).get(config_name)
    if not isinstance(record, dict):
        record = {"display_name": config_name}
    record["last_unassigned_by_fp"] = auth_fingerprint(auth)
    record["last_unassigned_at"] = utc_now_iso()
    data.setdefault("clients", {})[config_name] = record
    write_client_metadata(data)


def remove_client_from_token(config_name, auth):
    config_name = safe_name(config_name)
    removed = mutate_user_clients(auth.get("hash"), config_name, remove=True)
    mark_client_unassigned(config_name, auth)
    remaining = len(assignment_records_for_client(config_name))
    audit_log(
        "User removed client access "
        f"config_name={config_name} actor_fp={auth_fingerprint(auth)} "
        f"remaining_user_assignments={remaining} deleted=false"
    )
    return removed, remaining


CLIENT_AUDIT_SUFFIXES = (".conf", ".png", ".vpnuri", ".vpnuri.png")
KEY_AUDIT_SUFFIXES = (".private", ".public")


def file_stem_for_suffix(path, suffix):
    name = path.name
    if not name.endswith(suffix):
        return ""
    stem = name[: -len(suffix)]
    return stem if NAME_RE.fullmatch(stem) else ""


def read_text_safe(path, max_bytes=2 * 1024 * 1024):
    try:
        if not path.exists() or path.stat().st_size > max_bytes:
            return ""
        return path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return ""


def client_file_refs():
    refs = {}
    for suffix in CLIENT_AUDIT_SUFFIXES:
        for path in AWG_DIR.glob(f"*{suffix}"):
            name = file_stem_for_suffix(path, suffix)
            if name:
                refs.setdefault(name, set()).add(suffix.lstrip(".").replace(".", "_"))
    keys_dir = AWG_DIR / "keys"
    if keys_dir.exists():
        for suffix in KEY_AUDIT_SUFFIXES:
            for path in keys_dir.glob(f"*{suffix}"):
                name = file_stem_for_suffix(path, suffix)
                if name:
                    refs.setdefault(name, set()).add(f"key_{suffix.lstrip('.')}")
    return refs


def p2p_rule_refs():
    text = read_text_safe(AWG_DIR / "p2p_rules.sh")
    refs = {}
    if not text:
        return refs
    for name, ipv4, ports in re.findall(r"# Client: ([A-Za-z0-9_-]+) \((\d+\.\d+\.\d+\.\d+), P2P: ([0-9,]+)\)", text):
        refs[name] = {
            "ipv4": ipv4,
            "ports": [int(port) for port in ports.split(",") if port.isdigit()],
        }
    return refs


def adguard_refs():
    root = AWG_DIR / "adguard"
    refs = {}
    if not root.exists():
        return refs
    for path in root.rglob("*"):
        if not path.is_file() or path.stat().st_size > 2 * 1024 * 1024:
            continue
        text = read_text_safe(path)
        for name in re.findall(r"\b([A-Za-z0-9_-]{1,64})\b", text):
            if NAME_RE.fullmatch(name):
                refs.setdefault(name, set()).add(str(path.relative_to(root)))
    return refs


def traffic_history_refs():
    data = load_traffic_history()
    refs = set()
    def add_history_name(name):
        if isinstance(name, str) and name != DELETED_TRAFFIC_KEY and NAME_RE.fullmatch(name):
            refs.add(name)
    for bucket_name in ("last", "totals"):
        bucket = data.get(bucket_name, {})
        if isinstance(bucket, dict):
            for name in bucket:
                add_history_name(name)
    days = data.get("days", {})
    if isinstance(days, dict):
        for day in days.values():
            if isinstance(day, dict):
                for name in day:
                    add_history_name(name)
    return refs


def active_client_audit_status(row):
    status = []
    if row["server_peer_present"]:
        status.append("active")
        if row["is_unassigned"]:
            status.append("unassigned")
        missing = [key for key in ("conf", "png", "vpnuri") if key not in row["files"]]
        if missing:
            status.append("missing_files")
    else:
        if row["metadata_present"]:
            status.append("orphan_metadata")
        if row["files"]:
            status.append("orphan_files")
        if row["token_assignments"]:
            status.append("orphan_token_binding")
        if row["p2p_rules_present"]:
            status.append("orphan_firewall_rule")
        if row["adguard_refs"]:
            status.append("orphan_adguard_ref")
        if not status and row["traffic_history_present"]:
            status.append("history_only")
    return status or ["unknown"]


def audit_client_state():
    peers = {peer["name"]: peer for peer in parse_peers()}
    metadata = load_client_metadata().get("clients", {})
    files = client_file_refs()
    p2p_refs = p2p_rule_refs()
    dns_refs = adguard_refs()
    history_refs = traffic_history_refs()
    token_refs = {}
    for client_name, records in token_assignments_for_clients().items():
        token_refs[client_name] = records

    names = set(peers) | set(metadata) | set(files) | set(p2p_refs) | set(dns_refs) | set(history_refs) | set(token_refs)
    clients = []
    for name in sorted(names):
        peer = peers.get(name, {})
        record = metadata.get(name, {})
        row = {
            "config_name": name,
            "display_name": record.get("display_name") or peer.get("display_name") or name,
            "server_peer_present": name in peers,
            "metadata_present": name in metadata,
            "files": sorted(files.get(name, set())),
            "client_conf_present": "conf" in files.get(name, set()),
            "qr_present": "png" in files.get(name, set()),
            "vpnuri_present": "vpnuri" in files.get(name, set()),
            "vpnuri_qr_present": "vpnuri_png" in files.get(name, set()),
            "token_assignments": [
                {"alias": item.get("alias", ""), "fingerprint": item.get("fingerprint", ""), "role": item.get("role", "user")}
                for item in token_refs.get(name, [])
            ],
            "p2p_rules_present": name in p2p_refs,
            "p2p_rule_ports": p2p_refs.get(name, {}).get("ports", []),
            "adguard_refs": sorted(dns_refs.get(name, set())),
            "traffic_history_present": name in history_refs,
            "vpn_ip": peer.get("ipv4") or p2p_refs.get(name, {}).get("ipv4", ""),
            "p2p_ports": peer.get("p2p_ports", []),
        }
        row["is_unassigned"] = row["server_peer_present"] and not row["token_assignments"]
        row["status"] = active_client_audit_status(row)
        clients.append(row)

    summary = {
        "total": len(clients),
        "active": sum(1 for row in clients if "active" in row["status"]),
        "unassigned": sum(1 for row in clients if "unassigned" in row["status"]),
        "orphan_metadata": sum(1 for row in clients if "orphan_metadata" in row["status"]),
        "orphan_files": sum(1 for row in clients if "orphan_files" in row["status"]),
        "orphan_token_bindings": sum(1 for row in clients if "orphan_token_binding" in row["status"]),
        "orphan_firewall_rules": sum(1 for row in clients if "orphan_firewall_rule" in row["status"]),
        "history_only": sum(1 for row in clients if row["status"] == ["history_only"]),
    }
    return {"clients": clients, "summary": summary}


def delete_client_global(config_name, actor):
    config_name = safe_name(config_name)
    before = audit_client_state()
    p = run_manage("remove", config_name)
    if p.returncode == 0:
        remove_client_from_all_tokens(config_name)
        remove_client_metadata(config_name)
        remove_import_tokens_for_client(config_name)
        after = audit_client_state()
        before_row = next((row for row in before["clients"] if row["config_name"] == config_name), {})
        after_row = next((row for row in after["clients"] if row["config_name"] == config_name), {})
        leftovers = [status for status in after_row.get("status", []) if status != "history_only"]
        audit_log(
            "Deleted web client "
            f"config_name={config_name} actor_role={actor.get('role')} actor_fp={auth_fingerprint(actor)} "
            f"files_before={len(before_row.get('files', []))} leftovers={','.join(leftovers) if leftovers else 'none'}"
        )
    return p


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


def load_ip_info_cache():
    if not IP_INFO_CACHE_FILE.exists():
        return {}
    try:
        data = json.loads(IP_INFO_CACHE_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def write_ip_info_cache(data):
    WEB_DIR.mkdir(parents=True, exist_ok=True)
    tmp = IP_INFO_CACHE_FILE.with_name(f"{IP_INFO_CACHE_FILE.name}.tmp.{os.getpid()}")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, IP_INFO_CACHE_FILE)
    os.chmod(IP_INFO_CACHE_FILE, 0o600)


def country_code_to_flag(code):
    code = (code or "").strip().upper()
    if not re.fullmatch(r"[A-Z]{2}", code):
        return ""
    return "".join(chr(0x1F1E6 + ord(char) - ord("A")) for char in code)


def _empty_endpoint_info(ip, source="local", provider=""):
    return {
        "ip": ip,
        "country": "",
        "country_code": "",
        "flag": "",
        "city": "",
        "asn": "",
        "org": "",
        "provider": provider,
        "source": source,
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }


def _is_private_endpoint_ip(ip):
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return True
    private_networks = (
        ipaddress.ip_network("100.64.0.0/10"),
        ipaddress.ip_network("fc00::/7"),
        ipaddress.ip_network("fe80::/10"),
    )
    if any(addr in network for network in private_networks):
        return True
    return (
        addr.is_private
        or addr.is_loopback
        or addr.is_link_local
        or addr.is_multicast
        or addr.is_reserved
        or addr.is_unspecified
    )


def _fetch_endpoint_ip_info(ip):
    url = f"http://ip-api.com/json/{ip}?fields=status,country,countryCode,city,isp,org,as,query,message"
    try:
        with urlopen(url, timeout=IP_INFO_LOOKUP_TIMEOUT) as response:
            payload = response.read(16384)
    except (OSError, URLError, TimeoutError, ValueError):
        return None
    try:
        data = json.loads(payload.decode("utf-8"))
    except Exception:
        return None
    if not isinstance(data, dict) or data.get("status") != "success":
        return None
    country_code = str(data.get("countryCode") or "").upper()
    org = str(data.get("org") or "").strip()
    isp = str(data.get("isp") or "").strip()
    provider = org or isp
    return {
        "ip": ip,
        "country": str(data.get("country") or "").strip(),
        "country_code": country_code,
        "flag": country_code_to_flag(country_code),
        "city": str(data.get("city") or "").strip(),
        "asn": str(data.get("as") or "").strip(),
        "org": org,
        "provider": provider,
        "source": "provider",
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }


def lookup_endpoint_ip_info(ip, allow_refresh=True):
    ip = (ip or "").strip()
    if not ip:
        return _empty_endpoint_info(ip, source="local")
    if _is_private_endpoint_ip(ip):
        return _empty_endpoint_info(ip, source="local", provider="private")

    now = time.time()
    with IP_INFO_CACHE_LOCK:
        cache = load_ip_info_cache()
        cached = cache.get(ip)
        if isinstance(cached, dict):
            updated_at = float(cached.get("_cache_ts") or 0)
            ttl = IP_INFO_NEGATIVE_TTL if cached.get("status") == "negative" else IP_INFO_CACHE_TTL
            info = dict(cached.get("info") or _empty_endpoint_info(ip, source="cache"))
            if updated_at and now - updated_at < ttl:
                info["source"] = "cache"
                return info
            if not allow_refresh:
                info["source"] = "cache"
                return info

    if not allow_refresh:
        return _empty_endpoint_info(ip, source="cache")

    info = _fetch_endpoint_ip_info(ip)
    if info is None:
        info = _empty_endpoint_info(ip, source="provider")
        status = "negative"
    else:
        status = "ok"

    with IP_INFO_CACHE_LOCK:
        cache = load_ip_info_cache()
        cache[ip] = {"status": status, "_cache_ts": now, "info": info}
        try:
            write_ip_info_cache(cache)
        except Exception:
            pass
    return info


def split_endpoint(endpoint):
    endpoint = (endpoint or "").strip()
    if not endpoint or endpoint in {"-", "(none)", "none"}:
        return "", None
    host = endpoint
    port = None
    if endpoint.startswith("[") and "]" in endpoint:
        host, rest = endpoint[1:].split("]", 1)
        if rest.startswith(":") and rest[1:].isdigit():
            port = int(rest[1:])
    elif ":" in endpoint and endpoint.count(":") == 1:
        candidate_host, candidate_port = endpoint.rsplit(":", 1)
        host = candidate_host
        if candidate_port.isdigit():
            port = int(candidate_port)
    return host.strip(), port


def _traffic_pair(values):
    if not isinstance(values, dict):
        return {"rx": 0, "tx": 0}
    return {
        "rx": max(0, int(values.get("rx") or 0)),
        "tx": max(0, int(values.get("tx") or 0)),
    }


def client_perspective_traffic(values):
    # WireGuard counters are server-perspective: rx is received from the client,
    # tx is sent to the client. The web UI reports client-perspective traffic.
    pair = _traffic_pair(values)
    return {
        **pair,
        "total": pair["rx"] + pair["tx"],
        "server_rx": pair["rx"],
        "server_tx": pair["tx"],
        "client_upload": pair["rx"],
        "client_download": pair["tx"],
    }


def client_traffic_api(total_pair=None, last_30d_pair=None):
    total_pair = client_perspective_traffic(total_pair or {})
    last_30d_pair = client_perspective_traffic(last_30d_pair or {})
    return {
        "client_download_total": total_pair["client_download"],
        "client_upload_total": total_pair["client_upload"],
        "client_download_30d": last_30d_pair["client_download"],
        "client_upload_30d": last_30d_pair["client_upload"],
        "server_rx_total": total_pair["server_rx"],
        "server_tx_total": total_pair["server_tx"],
        "server_rx_30d": last_30d_pair["server_rx"],
        "server_tx_30d": last_30d_pair["server_tx"],
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
    if stats is None:
        stats = client_stats_map()
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
        days.append({"date": date, **client_perspective_traffic({"rx": rx, "tx": tx})})
    last_30d = {"rx": sum(day["rx"] for day in days), "tx": sum(day["tx"] for day in days)}
    return {
        "current_live": client_perspective_traffic(current_live),
        "current": client_perspective_traffic(persistent),
        "total": client_perspective_traffic(persistent),
        "last_30d": client_perspective_traffic(last_30d),
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
    return client_perspective_traffic({"rx": rx, "tx": tx})


def client_traffic_total(name, history=None):
    history = history or load_traffic_history()
    if name.startswith("_"):
        return {"rx": 0, "tx": 0, "total": 0}
    pair = _traffic_pair(history.get("totals", {}).get(name, {}))
    return client_perspective_traffic(pair)


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
        return False
    with TOKENS_LOCK:
        data = load_tokens()
        users = data.setdefault("users", {})
        if user_hash not in users:
            return False
        record = clean_user_record(users[user_hash])
        clients = record["clients"]
        if remove:
            clients = [name for name in clients if name != client_name]
        elif client_name not in clients:
            clients.append(client_name)
        record["clients"] = clients
        users[user_hash] = record
        write_tokens(data)
        return True


def assign_client_to_user_token(user_hash, client_name):
    user_hash = safe_token_hash(user_hash)
    client_name = safe_name(client_name)
    with TOKENS_LOCK:
        data = load_tokens()
        users = data.setdefault("users", {})
        if user_hash not in users:
            raise ValueError("user token not found")
        record = clean_user_record(users[user_hash])
        if client_name not in record["clients"]:
            record["clients"].append(client_name)
        users[user_hash] = record
        write_tokens(data)
        verified = load_tokens().get("users", {}).get(user_hash)
        if not isinstance(verified, dict):
            raise RuntimeError("user token assignment verification failed")
        verified_clients = clean_user_record(verified).get("clients", [])
        if client_name not in verified_clients:
            raise RuntimeError("user token assignment verification failed")
        return True


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


def parse_stats_rows(raw_out):
    raw_out = raw_out or ""
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
    return out


def refresh_client_stats():
    started = time.time()
    try:
        p = run_manage("--json", "stats", timeout=8)
    except (OSError, subprocess.SubprocessError) as exc:
        audit_log(f"Stats cache refresh failed error={exc.__class__.__name__}")
        return {}
    elapsed = time.time() - started
    if elapsed > 2.0:
        audit_log(f"Stats cache refresh slow seconds={elapsed:.2f}")
    if p.returncode != 0:
        audit_log(f"Stats cache refresh failed returncode={p.returncode}")
        return {}
    try:
        out = parse_stats_rows(p.stdout or "")
        update_traffic_history(out.values())
    except Exception as exc:
        audit_log(f"Stats cache refresh failed error={exc.__class__.__name__}")
        return {}
    return out


def client_stats_map(force=False):
    global STATS_CACHE_VALUE, STATS_CACHE_TS, STATS_CACHE_INFLIGHT
    now = time.time()
    with STATS_CACHE_COND:
        if not force and STATS_CACHE_VALUE is not None and now - STATS_CACHE_TS <= STATS_CACHE_TTL:
            return dict(STATS_CACHE_VALUE)
        if STATS_CACHE_INFLIGHT:
            deadline = now + STATS_CACHE_WAIT_TIMEOUT
            while STATS_CACHE_INFLIGHT and time.time() < deadline:
                STATS_CACHE_COND.wait(max(0.0, deadline - time.time()))
            now = time.time()
            if STATS_CACHE_VALUE is not None and now - STATS_CACHE_TS <= STATS_CACHE_TTL:
                return dict(STATS_CACHE_VALUE)
            if STATS_CACHE_VALUE is not None:
                audit_log("Stats cache stale served while refresh in-flight")
                return dict(STATS_CACHE_VALUE)
            audit_log("Stats cache empty while refresh in-flight")
            return {}
        STATS_CACHE_INFLIGHT = True
    try:
        refreshed = refresh_client_stats()
    except Exception as exc:
        audit_log(f"Stats cache refresh failed error={exc.__class__.__name__}")
        refreshed = {}
    finally:
        with STATS_CACHE_COND:
            if "refreshed" in locals() and refreshed:
                STATS_CACHE_VALUE = dict(refreshed)
                STATS_CACHE_TS = time.time()
            elif STATS_CACHE_VALUE is None:
                STATS_CACHE_VALUE = {}
                STATS_CACHE_TS = 0.0
            STATS_CACHE_INFLIGHT = False
            STATS_CACHE_COND.notify_all()
    return dict(refreshed) if refreshed else dict(STATS_CACHE_VALUE or {})


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
            request.close()
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
        client_ctx = client_ip_context(remote_addr, self.headers, policy)
        client_ip = client_ctx["client_ip"]
        if not request_allowed_by_policy(raw_host, remote_addr, policy, client_ip, client_ctx["trusted_proxy_used"]):
            record_rejected_host(raw_host, client_ip, self.path)
            proxy_suffix = f" proxy={remote_addr}" if client_ctx["trusted_proxy_used"] else ""
            audit_log(f"Rejected Web Panel request remote={client_ip}{proxy_suffix} path={self.path} host={raw_host!r} reason=access policy")
            if self.path.startswith("/api/"):
                self.send_api_error(HTTPStatus.MISDIRECTED_REQUEST, "bad_request")
            else:
                self.send_error(HTTPStatus.MISDIRECTED_REQUEST)
            return None
        if not self.path.startswith("/api/"):
            return {"role": "static"}
        ip = client_ip
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
        client_ctx = client_ip_context(remote_addr, self.headers, policy)
        edge = web_access_edge_info(policy, self.headers, client_ctx["trusted_proxy_used"])
        restart_required = policy.get("bind_host") != (os.environ.get("AWG_WEB_BIND") or "")
        if edge.get("mode") == "nginx_reverse_proxy":
            restart_required = False
        return {
            "policy": policy,
            "edge": edge,
            "current": {
                "host": raw_host,
                "normalized_host": split_host(raw_host),
                "remote_ip": client_ctx["client_ip"],
                "client_ip": client_ctx["client_ip"],
                "socket_remote_ip": client_ctx["socket_remote_ip"],
                "proxy_ip": client_ctx["proxy_ip"],
                "trusted_proxy_used": client_ctx["trusted_proxy_used"],
                "allowed": request_allowed_by_policy(raw_host, remote_addr, policy, client_ctx["client_ip"], client_ctx["trusted_proxy_used"]),
            },
            "recent_rejected_hosts": recent_rejected_hosts(),
            "requires_restart": restart_required,
        }

    def validate_policy_for_current_request(self, body):
        policy = clean_access_policy(body.get("policy", body))
        raw_host = self.headers.get("Host", "")
        remote_addr = self.client_address[0]
        client_ctx = client_ip_context(remote_addr, self.headers, policy)
        if not request_allowed_by_policy(raw_host, remote_addr, policy, client_ctx["client_ip"], client_ctx["trusted_proxy_used"]):
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
        if u.path == "/api/server-health":
            if not self.require_super(auth):
                return
            health = json.loads(json.dumps(collect_server_health()))
            client_ctx = request_client_context(self)
            health.setdefault("services", {}).setdefault("nginx_edge", {})["status"] = "ok" if client_ctx.get("trusted_proxy_used") else "unknown"
            health["request"] = {
                "host": split_host(self.headers.get("Host", "")),
                "client_ip": client_ctx.get("client_ip"),
                "socket_remote_ip": client_ctx.get("socket_remote_ip"),
                "proxy_ip": client_ctx.get("proxy_ip"),
                "trusted_proxy_used": bool(client_ctx.get("trusted_proxy_used")),
            }
            self.send_json(health)
            return
        if u.path == "/api/nettest/context":
            self.send_json(nettest_context_payload())
            return
        if u.path == "/api/nettest/ping":
            query = parse_qs(u.query)
            nonce = str((query.get("n") or [""])[0])[:64]
            try:
                test_id = clean_nettest_id((query.get("test_id") or [""])[0])
            except ValueError as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            client_ctx = request_client_context(self)
            if test_id and not reserve_nettest_session(auth, client_ctx.get("client_ip"), test_id):
                self.send_json({"error": "nettest already active"}, HTTPStatus.TOO_MANY_REQUESTS)
                return
            self.send_json({"ok": True, "server_time": utc_now_iso(), "nonce": nonce})
            return
        if u.path == "/api/nettest/download":
            query = parse_qs(u.query)
            try:
                test_id = clean_nettest_id((query.get("test_id") or [""])[0])
            except ValueError as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            client_ctx = request_client_context(self)
            if test_id and not reserve_nettest_session(auth, client_ctx.get("client_ip"), test_id):
                self.send_json({"error": "nettest already active"}, HTTPStatus.TOO_MANY_REQUESTS)
                return
            try:
                size = int((query.get("size") or [str(NETTEST_DEFAULT_DOWNLOAD_SIZE)])[0])
            except (TypeError, ValueError):
                size = NETTEST_DEFAULT_DOWNLOAD_SIZE
            size = max(1, min(size, NETTEST_MAX_DOWNLOAD_SIZE))
            pattern = b"amneziawg-nettest-" * 1024
            data = (pattern * ((size // len(pattern)) + 1))[:size]
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(data)))
            self.send_security_headers()
            if not self.finish_response_headers():
                return
            self.write_response_body(data)
            return
        if u.path == "/api/nettest/reports":
            if not self.require_super(auth):
                return
            self.send_json({"reports": list_nettest_reports()})
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
        if u.path == "/api/clients/audit":
            if not self.require_super(auth):
                return
            self.send_json(audit_client_state())
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
            endpoint_lookup_budget = 1
            for peer in visible:
                item = dict(peer)
                row_stats = stats.get(peer["name"], {})
                item["id"] = peer["name"]
                item["config_name"] = peer["name"]
                item["display_name"] = peer.get("display_name") or peer["name"]
                item["assigned_tokens"] = assignments.get(peer["name"], []) if self.is_super(auth) else []
                item["is_unassigned"] = self.is_super(auth) and not item["assigned_tokens"]
                item["is_duplicate_display_name"] = display_counts.get(item["display_name"], 0) > 1
                item["created_by_current_token"] = False
                item["can_remove_from_my_access"] = False
                item["can_delete_self_created"] = False
                if not self.is_super(auth):
                    can_delete, _reason = can_user_delete_client(peer["name"], auth)
                    item["created_by_current_token"] = is_client_created_by_token(peer["name"], auth_fingerprint(auth))
                    item["can_remove_from_my_access"] = peer["name"] in set(auth.get("clients") or [])
                    item["can_delete_self_created"] = can_delete
                item["rx"] = row_stats.get("rx", 0)
                item["tx"] = row_stats.get("tx", 0)
                item["server_rx"] = item["rx"]
                item["server_tx"] = item["tx"]
                item["client_upload"] = item["rx"]
                item["client_download"] = item["tx"]
                item["traffic_30d"] = client_traffic_30d(peer["name"], history)
                item["traffic_total"] = client_traffic_total(peer["name"], history)
                item["traffic"] = client_traffic_api(item["traffic_total"], item["traffic_30d"])
                item["latestHandshakeAt"] = row_stats.get("latestHandshakeAt", row_stats.get("last_handshake", 0))
                endpoint = row_stats.get("endpoint", "")
                item["endpoint"] = "" if endpoint in {"", "-", "(none)", "none"} else endpoint
                endpoint_ip, endpoint_port = split_endpoint(item["endpoint"])
                item["endpoint_ip"] = endpoint_ip
                item["endpoint_port"] = endpoint_port
                if endpoint_ip:
                    item["endpoint_info"] = lookup_endpoint_ip_info(endpoint_ip, allow_refresh=endpoint_lookup_budget > 0)
                    if item["endpoint_info"].get("source") == "provider":
                        endpoint_lookup_budget -= 1
                else:
                    item["endpoint_info"] = {}
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
            if u.path == "/api/nettest/upload":
                test_id = clean_nettest_id(self.headers.get("X-Nettest-Id", ""))
                client_ctx = request_client_context(self)
                if test_id and not reserve_nettest_session(auth, client_ctx.get("client_ip"), test_id):
                    self.send_json({"error": "nettest already active"}, HTTPStatus.TOO_MANY_REQUESTS)
                    return
                try:
                    size = int(self.headers.get("Content-Length", "0") or 0)
                except (TypeError, ValueError):
                    raise ValueError("invalid content length")
                if size < 0:
                    raise ValueError("invalid content length")
                if size > NETTEST_MAX_UPLOAD_SIZE:
                    self.send_error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
                    raise ValueError("payload too large")
                remaining = size
                received = 0
                while remaining > 0:
                    chunk = self.rfile.read(min(remaining, 65536))
                    if not chunk:
                        break
                    received += len(chunk)
                    remaining -= len(chunk)
                self.send_json({"ok": True, "bytes": received, "max_bytes": NETTEST_MAX_UPLOAD_SIZE})
                return
            if u.path == "/api/nettest/report":
                body = json_body_from_handler(self, NETTEST_MAX_REPORT_JSON)
                try:
                    self.send_json(save_nettest_report(auth, self, body))
                except ValueError as exc:
                    if str(exc) == "nettest report rate limited":
                        self.send_json({"error": "rate limited"}, HTTPStatus.TOO_MANY_REQUESTS)
                        return
                    raise
                return
            body = self.json_body()
            if u.path == "/api/clients":
                display_name = safe_name(body.get("name", ""))
                name, collision = unique_client_config_name(display_name)
                args = []
                if body.get("expires"):
                    args.append(f"--expires={require_expires(body['expires'])}")
                p = run_manage(*args, "add", name)
                if p.returncode == 0:
                    set_client_metadata(name, display_name, auth)
                    assigned_to_current_token = False
                    if collision:
                        audit_log(
                            "Client display name collision: "
                            f"requested={display_name} created_config={name} "
                            f"actor_role={auth.get('role')} actor_fp={auth_fingerprint(auth)}"
                        )
                    if not self.is_super(auth):
                        try:
                            assigned_to_current_token = assign_client_to_user_token(auth["hash"], name)
                        except Exception as exc:
                            rollback_ok = rollback_created_client(name)
                            audit_log(
                                "ERROR User-created client assignment failed "
                                f"config_name={name} actor_fp={auth_fingerprint(auth)} "
                                f"rollback={'ok' if rollback_ok else 'failed'} error={exc.__class__.__name__}"
                            )
                            self.send_json({"error": "client assignment failed"}, 500)
                            return
                    audit_log(
                        "Created web client "
                        f"requested_display={display_name} config_name={name} "
                        f"actor_role={auth.get('role')} actor_fp={auth_fingerprint(auth)} "
                        f"assigned={'true' if assigned_to_current_token else 'false'}"
                    )
                    self.send_json({
                        "ok": True,
                        "stdout": p.stdout,
                        "stderr": p.stderr,
                        "id": name,
                        "name": name,
                        "config_name": name,
                        "display_name": display_name,
                        "is_duplicate_display_name": collision,
                        "assigned_to_current_token": assigned_to_current_token,
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
                    p = delete_client_global(name, auth)
                    self.send_json({"ok": p.returncode == 0, "stdout": p.stdout, "stderr": p.stderr}, 200 if p.returncode == 0 else 400)
                    return
                action = (parse_qs(u.query).get("action") or ["remove_access"])[0]
                if action in {"remove_access", ""}:
                    _removed, remaining = remove_client_from_token(name, auth)
                    self.send_json({"ok": True, "removed_access": True, "deleted": False, "client": name, "remaining_user_assignments": remaining})
                    return
                if action == "delete_owned":
                    allowed, reason = can_user_delete_client(name, auth)
                    if not allowed:
                        audit_log(f"Denied user-owned delete config_name={name} actor_fp={auth_fingerprint(auth)} reason={reason}")
                        self.send_json({"error": "delete not allowed", "reason": reason}, 403)
                        return
                    p = delete_client_global(name, auth)
                    if p.returncode == 0:
                        audit_log(f"User deleted own client config_name={name} actor_fp={auth_fingerprint(auth)} deleted=true")
                    self.send_json({"ok": p.returncode == 0, "deleted": p.returncode == 0, "removed_access": False, "stdout": p.stdout, "stderr": p.stderr}, 200 if p.returncode == 0 else 400)
                    return
                raise ValueError("invalid delete action")
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
