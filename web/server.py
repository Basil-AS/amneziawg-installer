#!/usr/bin/env python3
import errno
import hashlib
import gzip
import hmac
import ipaddress
import json
import os
import re
import secrets
import shlex
import shutil
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
from urllib.parse import parse_qs, quote, unquote, urlencode, urlparse
from urllib.error import URLError
from urllib.request import Request, urlopen

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
HEALTH_HISTORY_DIR = WEB_DIR / "health_history"
PROVIDER_TRAFFIC_FILE = WEB_DIR / "provider_traffic.json"
LEGACY_TOKEN_FILE = WEB_DIR / "auth_token"
NAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")
TOKEN_HASH_RE = re.compile(r"^[0-9a-f]{64}$")
RAW_IMPORT_TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{32,256}$")
I1_RE = re.compile(r"^[<>a-fA-F0-9xbr\s]+$")
PROJECT_VERSION_RE = re.compile(r"^[0-9A-Za-z][0-9A-Za-z.+-]{0,63}$")


def load_project_version():
    """Return the deployed fork version without hard-coding it in the panel."""
    configured = os.environ.get("AWG_PROJECT_VERSION", "").strip()
    if PROJECT_VERSION_RE.fullmatch(configured):
        return configured
    candidates = (AWG_DIR / "VERSION", Path(__file__).resolve().parent.parent / "VERSION")
    for candidate in candidates:
        try:
            value = candidate.read_text(encoding="utf-8").strip()
        except OSError:
            continue
        if PROJECT_VERSION_RE.fullmatch(value):
            return value
    return "unknown"


PROJECT_VERSION = load_project_version()


def project_update_status():
    """Return a non-secret, UI-safe status for the isolated updater unit."""
    installed = load_project_version()
    status = "unavailable"
    active = "inactive"
    result = "success"
    if PROJECT_UPDATE_SCRIPT.is_file() and os.access(PROJECT_UPDATE_SCRIPT, os.X_OK):
        try:
            probe = subprocess.run(
                ["systemctl", "is-active", PROJECT_UPDATE_UNIT],
                text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                timeout=3, check=False,
            )
            active = probe.stdout.strip() or "inactive"
            status = "running" if active in {"active", "activating"} else ("failed" if active == "failed" else "ready")
            details = subprocess.run(
                ["systemctl", "show", PROJECT_UPDATE_UNIT, "--property=Result", "--value"],
                text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                timeout=3, check=False,
            ).stdout.strip()
            result = details or "success"
        except (OSError, subprocess.TimeoutExpired):
            status = "unavailable"
    target = ""
    output = ""
    try:
        journal = subprocess.run(
            ["journalctl", "-u", PROJECT_UPDATE_UNIT, "-n", "80", "--no-pager", "-o", "cat"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=5, check=False,
        ).stdout
        output = journal[-6000:]
        match = re.findall(r"Installed:\s*([^;\n]+);\s*target:\s*([^\n]+)", journal)
        if match:
            installed, target = match[-1][0].strip(), match[-1][1].strip()
    except (OSError, subprocess.TimeoutExpired):
        output = ""
    available = bool(target and installed != target)
    return {
        "ok": status != "unavailable",
        "status": status,
        "active_state": active,
        "result": result,
        "installed": installed,
        "target": target,
        "available": available,
        "unit": PROJECT_UPDATE_UNIT,
        "last_output": output,
    }


def start_project_update(mode):
    """Start check/update outside awg-web.service so a panel restart cannot kill it."""
    global PROJECT_UPDATE_LAST_START
    if mode not in {"check", "apply"}:
        raise ValueError("invalid update mode")
    if not PROJECT_UPDATE_SCRIPT.is_file() or not os.access(PROJECT_UPDATE_SCRIPT, os.X_OK):
        raise RuntimeError("update script is not installed")
    with PROJECT_UPDATE_LOCK:
        now = time.time()
        if now - PROJECT_UPDATE_LAST_START < 5:
            raise RuntimeError("update request throttled")
        probe = subprocess.run(
            ["systemctl", "is-active", "--quiet", PROJECT_UPDATE_UNIT],
            timeout=3, check=False,
        )
        if probe.returncode == 0:
            raise RuntimeError("another update operation is already running")
        args = ["systemd-run", "--quiet", "--collect", f"--unit={PROJECT_UPDATE_UNIT}",
                "--property=Type=oneshot", "--property=TimeoutStartSec=1800",
                str(PROJECT_UPDATE_SCRIPT)]
        if mode == "check":
            args.append("--check")
        result = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=15, check=False)
        if result.returncode != 0:
            detail = (result.stderr or result.stdout).strip()[-500:]
            raise RuntimeError(f"cannot start update operation{(': ' + detail) if detail else ''}")
        PROJECT_UPDATE_LAST_START = now
    return {"ok": True, "started": True, "mode": mode, "unit": PROJECT_UPDATE_UNIT}
STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/nettest": ("index.html", "text/html; charset=utf-8"),
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
PROJECT_UPDATE_UNIT = "awg-project-update-manual.service"
PROJECT_UPDATE_SCRIPT = AWG_DIR / "update-installed.sh"
PROJECT_UPDATE_LOCK = threading.Lock()
PROJECT_UPDATE_LAST_START = 0.0
SERVER_HEALTH_CACHE_TTL = 5.0
SERVER_HEALTH_LOCK = threading.Lock()
SERVER_HEALTH_CACHE = None
SERVER_HEALTH_CACHE_TS = 0.0
SERVER_HEALTH_PREV_CPU = None
SERVER_HEALTH_PREV_NET = {}
SERVER_HEALTH_PREV_COUNTERS = {}
SERVER_HEALTH_CLIENT_TRAFFIC_PREV = None
SERVER_HEALTH_CLIENT_TRAFFIC_PEAK = {"server_rx_bps": 0.0, "server_tx_bps": 0.0, "total_bps": 0.0}
QDISC_CACHE_LOCK = threading.Lock()
QDISC_CACHE = {"ts": 0.0, "dropped": None, "iface": ""}
QDISC_CACHE_TTL = 60.0
VPN_READINESS_CACHE_TTL = 300.0
VPN_READINESS_LOCK = threading.Lock()
VPN_READINESS_CACHE = None
VPN_READINESS_CACHE_TS = 0.0
SERVER_HEALTH_HISTORY_CACHE = {}
SERVER_HEALTH_HISTORY_CACHE_TTL = 15.0
SERVER_HEALTH_SAMPLE_INTERVAL = 10.0
SERVER_HEALTH_RETENTION_DAYS = 30
SERVER_HEALTH_COLLECTOR_STARTED = False
PROVIDER_TRAFFIC_LOCK = threading.Lock()
PROVIDER_TRAFFIC_CACHE = None
PROVIDER_TRAFFIC_CACHE_TS = 0.0
PROVIDER_TRAFFIC_CACHE_KEY = ""
HOSTKEY_SESSION_LOCK = threading.Lock()
HOSTKEY_SESSION_TOKEN = ""
HOSTKEY_SESSION_EXPIRE = 0.0
HOSTKEY_SESSION_KEY = ""
SERVER_HEALTH_RANGES = {
    "10m": 10 * 60,
    "1h": 60 * 60,
    "6h": 6 * 60 * 60,
    "12h": 12 * 60 * 60,
    "24h": 24 * 60 * 60,
    "3d": 3 * 24 * 60 * 60,
    "7d": 7 * 24 * 60 * 60,
    "30d": 30 * 24 * 60 * 60,
}
NETTEST_LOCK = threading.Lock()
NETTEST_ACTIVE = {}
NETTEST_LAST_REPORT = {}
NETTEST_REPORT_TIMES = {}
NETTEST_ACTIVE_TTL = 720.0
NETTEST_REPORT_COOLDOWN = 60.0
NETTEST_REPORTS_PER_HOUR = 12
NETTEST_DEFAULT_DOWNLOAD_SIZE = 256 * 1024
NETTEST_MAX_DOWNLOAD_SIZE = 1024 * 1024
NETTEST_MAX_UPLOAD_SIZE = 512 * 1024
NETTEST_MAX_REPORT_JSON = 512 * 1024
VPN_NETTEST_PORT = 8088
CLIENT_LATENCY_CACHE_TTL = 30.0
CLIENT_LATENCY_FORCE_MIN_INTERVAL = 10.0
CLIENT_LATENCY_STALE_AFTER = 15 * 60
CLIENT_LATENCY_MAX_SCAN = 20
CLIENT_LATENCY_LOCK = threading.Lock()
CLIENT_LATENCY_CACHE = {"ts": 0.0, "value": None}
CLIENT_TRANSFER_PREV = {}
CLIENT_ENDPOINT_HISTORY_FILE = WEB_DIR / "client_endpoint_history.json"
CLIENT_ENDPOINT_HISTORY_LOCK = threading.Lock()
CLIENT_ENDPOINT_HISTORY_MAX = 100
CLIENT_ENDPOINT_HISTORY_RETENTION = 24 * 3600
CLIENT_ENDPOINT_HISTORY_WRITE_INTERVAL = 30.0
CLIENT_ENDPOINT_HISTORY_LAST_WRITE = 0.0
CLIENT_PATH_CHECK_LOCK = threading.Lock()
CLIENT_PATH_CHECK_SEM = threading.BoundedSemaphore(1)
CLIENT_PATH_CHECK_LAST = {}
CLIENT_PATH_CHECK_INTERVAL = 600.0
CLIENT_PATH_CHECK_RESULTS = {}
CLIENT_PATH_CHECK_RESULT_TTL = 600
CLIENT_PATH_BATCH_LOCK = threading.Lock()
CLIENT_PATH_BATCH_LAST = 0.0
CLIENT_PATH_BATCH_COOLDOWN = 300.0
CLIENT_PATH_BATCH_MAX_CLIENTS = 20
CLIENT_PATH_BATCH_MAX_DURATION = 60.0
CLIENT_PATH_BATCH_STALE_AFTER = 900
IP_INFO_CACHE_TTL = 30 * 24 * 3600
IP_INFO_NEGATIVE_TTL = 3600
IP_INFO_ERROR_CACHE_TTL = 30 * 60
IP_INFO_LOOKUP_TIMEOUT = 3.0
GEOIP_PROVIDERS_FILE = WEB_DIR / "geoip_providers.json"
GEOIP_PROVIDERS_LOCK = threading.RLock()
GEOIP_TOKEN_MASK = "********"
GEOIP_PROVIDER_NAMES = {"2ip", "2ip_whois", "ipinfo", "maxmind", "dbip_mmdb", "dbip", "ip-api"}
GEOIP_PROVIDER_FIELDS = {
    "enabled": bool,
    "token": str,
    "base_url": str,
    "mmdb_path": str,
    "city_mmdb_path": str,
    "asn_mmdb_path": str,
    "allow_free": bool,
    "only_on_refresh": bool,
}
GEOIP_DATABASE_NAMES = {"maxmind_asn", "maxmind_city", "maxmind_country", "dbip_city_lite"}
GEOIP_DB_FILES = {
    "maxmind_asn": "GeoLite2-ASN.mmdb",
    "maxmind_city": "GeoLite2-City.mmdb",
    "maxmind_country": "GeoLite2-Country.mmdb",
    "dbip_city_lite": "dbip-city-lite.mmdb",
}
GEOIP_TEST_IP = "8.8.8.8"
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
        "name": "macOS",
        "icon": "apple",
        "subtitle": "GUI clients for macOS; import the generated profile or QR code.",
        "clients": [
            {
                "name": "AmneziaVPN",
                "status": "Recommended / Full client",
                "trafficSplit": "Routes / app features",
                "description": "Full desktop client.",
                "support": ["supported", "supported", "supported"],
                "links": [{"label": "Official", "url": "https://amnezia.org/downloads"}, {"label": "GitHub", "url": "https://github.com/amnezia-vpn/amnezia-client/releases"}],
                "platforms": "macOS",
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
    {
        "name": "Linux Desktop",
        "icon": "linux",
        "subtitle": "Official desktop client for Linux; use the app flow for the simplest setup.",
        "clients": [
            {
                "name": "AmneziaVPN",
                "status": "Recommended / Full client",
                "trafficSplit": "Routes / app features",
                "description": "Official Linux desktop client with a guided import flow.",
                "support": ["supported", "supported", "supported"],
                "links": [{"label": "Official", "url": "https://amnezia.org/downloads"}, {"label": "GitHub", "url": "https://github.com/amnezia-vpn/amnezia-client/releases"}],
                "platforms": "Linux x64",
                "setupMethod": "vpn:// URI, QR, app flow",
                "bestFor": "Linux desktop users who want a maintained GUI.",
                "limitation": "The app is heavier than a command-line tunnel and may require desktop dependencies.",
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


def web_access_required_hosts(extra_host=""):
    hosts = ["localhost", "127.0.0.1"]
    values = [
        configured_vpn_ipv4()[0],
        os.environ.get("AWG_WEB_DOMAIN") or "",
        os.environ.get("AWG_WEB_PUBLIC_URL") or "",
        os.environ.get("AWG_ENDPOINT") or "",
        os.environ.get("AWG_WEB_BIND") or "",
        extra_host or "",
    ]
    for value in values:
        host = split_host(urlparse(str(value)).netloc or str(value))
        if not host or host in {"0.0.0.0", "::"} or host in hosts:
            continue
        hosts.append(host)
        try:
            ip = ipaddress.ip_address(host)
        except ValueError:
            continue
        if ip.version == 4:
            sslip = f"{str(ip).replace('.', '-')}.sslip.io"
            if sslip not in hosts:
                hosts.append(sslip)
    return hosts


def default_allowed_hosts():
    return web_access_required_hosts()


def default_access_policy():
    vpn_gateway, vpn_network = configured_vpn_ipv4()
    bind = os.environ.get("AWG_WEB_BIND") or vpn_gateway
    if bind in {"0.0.0.0", "::"}:
        mode = "public"
        source_cidrs = ["0.0.0.0/0", "::/0"]
    elif bind in {"127.0.0.1", "::1"}:
        mode = "public_nginx"
        bind = "127.0.0.1"
        source_cidrs = ["0.0.0.0/0", "::/0"]
    elif bind == vpn_gateway:
        mode = "vpn_only"
        source_cidrs = [vpn_network, "127.0.0.0/8"]
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
        allowed_hosts = ensure_items(allowed_hosts, web_access_required_hosts())
    elif mode == "public_nginx":
        source_check_enabled = False
        allowed_hosts = ensure_items(allowed_hosts, web_access_required_hosts())
        trusted_proxy_cidrs = ensure_items(trusted_proxy_cidrs, ["127.0.0.0/8", "::1/128"])
        if not allowed_source_cidrs:
            allowed_source_cidrs = ["0.0.0.0/0", "::/0"]
    elif mode == "restricted_nginx":
        source_check_enabled = True
        trusted_proxy_cidrs = ensure_items(trusted_proxy_cidrs, ["127.0.0.0/8", "::1/128"])
        allowed_hosts = ensure_items(allowed_hosts, web_access_required_hosts())
    elif mode == "vpn_only_nginx":
        source_check_enabled = True
        trusted_proxy_cidrs = ensure_items(trusted_proxy_cidrs, ["127.0.0.0/8", "::1/128"])
        allowed_hosts = ensure_items(allowed_hosts, web_access_required_hosts())
        if not allowed_source_cidrs or any(cidr in {"0.0.0.0/0", "::/0"} for cidr in allowed_source_cidrs):
            allowed_source_cidrs = [configured_vpn_ipv4()[1], "127.0.0.0/8", "::1/128"]
    elif mode == "localhost_maintenance":
        source_check_enabled = True
        trusted_proxy_cidrs = ensure_items(trusted_proxy_cidrs, ["127.0.0.0/8", "::1/128"])
        allowed_hosts = ensure_items(allowed_hosts, ["localhost", "127.0.0.1"])
        allowed_source_cidrs = ["127.0.0.0/8", "::1/128"]
    elif mode == "vpn_only":
        source_check_enabled = True
        if not allowed_source_cidrs or any(cidr in {"0.0.0.0/0", "::/0"} for cidr in allowed_source_cidrs):
            allowed_source_cidrs = [configured_vpn_ipv4()[1], "127.0.0.0/8"]
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


def web_cert_status():
    cert_path = WEB_DIR / "cert.pem"
    key_path = WEB_DIR / "key.pem"
    data = {
        "cert_path": str(cert_path),
        "key_path": str(key_path),
        "cert_exists": cert_path.exists(),
        "key_exists": key_path.exists(),
        "mode": os.environ.get("AWG_WEB_CERT_MODE", ""),
        "domain": os.environ.get("AWG_WEB_DOMAIN", ""),
        "letsencrypt_live_path": "",
        "letsencrypt_available": shutil.which("certbot") is not None,
        "renew_available": False,
    }
    domain = data["domain"]
    if domain:
        live_path = Path("/etc/letsencrypt/live") / domain
        data["letsencrypt_live_path"] = str(live_path)
        data["renew_available"] = data["letsencrypt_available"] and live_path.exists()
    if cert_path.exists():
        try:
            decoded = ssl._ssl._test_decode_cert(str(cert_path))  # type: ignore[attr-defined]
            data.update({
                "subject": ", ".join("=".join(part) for group in decoded.get("subject", []) for part in group),
                "issuer": ", ".join("=".join(part) for group in decoded.get("issuer", []) for part in group),
                "not_before": decoded.get("notBefore", ""),
                "not_after": decoded.get("notAfter", ""),
                "serial_number": decoded.get("serialNumber", ""),
                "dns_names": [item[1] for item in decoded.get("subjectAltName", []) if item[0].lower() == "dns"],
            })
        except Exception as exc:
            data["parse_error"] = str(exc)
        try:
            st = cert_path.stat()
            data["cert_mtime"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(st.st_mtime))
            data["cert_size_bytes"] = st.st_size
        except OSError:
            pass
    return data


def _openssl_pubkey(path, args):
    p = subprocess.run(["openssl", *args, "-in", str(path), "-pubout"], capture_output=True, text=True, timeout=10)
    if p.returncode != 0:
        raise ValueError("openssl could not read certificate/key")
    return p.stdout.strip()


def validate_cert_key_pair(cert_path, key_path):
    cert = Path(cert_path)
    key = Path(key_path)
    if not cert.is_absolute() or not key.is_absolute():
        raise ValueError("certificate and key paths must be absolute")
    if not cert.exists() or not cert.is_file():
        raise ValueError("certificate file not found")
    if not key.exists() or not key.is_file():
        raise ValueError("private key file not found")
    ssl._ssl._test_decode_cert(str(cert))  # type: ignore[attr-defined]
    cert_pub = _openssl_pubkey(cert, ["x509"])
    key_pub = _openssl_pubkey(key, ["pkey"])
    if not cert_pub or cert_pub != key_pub:
        raise ValueError("certificate and private key do not match")


def install_custom_web_certificate(cert_path, key_path):
    validate_cert_key_pair(cert_path, key_path)
    WEB_DIR.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    backups = []
    for path in (WEB_DIR / "cert.pem", WEB_DIR / "key.pem"):
        if path.exists():
            backup = path.with_name(f"{path.name}.bak.{stamp}")
            shutil.copy2(path, backup)
            backups.append(str(backup))
    tmp_cert = WEB_DIR / f".cert.pem.tmp.{os.getpid()}"
    tmp_key = WEB_DIR / f".key.pem.tmp.{os.getpid()}"
    try:
        shutil.copyfile(cert_path, tmp_cert)
        shutil.copyfile(key_path, tmp_key)
        os.chmod(tmp_cert, 0o644)
        os.chmod(tmp_key, 0o600)
        os.replace(tmp_cert, WEB_DIR / "cert.pem")
        os.replace(tmp_key, WEB_DIR / "key.pem")
    finally:
        tmp_cert.unlink(missing_ok=True)
        tmp_key.unlink(missing_ok=True)
    return {"ok": True, "backups": backups, "certificate": web_cert_status()}


def renew_web_certificate():
    if shutil.which("certbot") is None:
        raise ValueError("certbot is not installed")
    domain = os.environ.get("AWG_WEB_DOMAIN", "")
    if domain and not (Path("/etc/letsencrypt/live") / domain).exists():
        raise ValueError("no Let's Encrypt live certificate for configured domain")
    p = subprocess.run(
        ["certbot", "renew", "--deploy-hook", "systemctl restart awg-web.service"],
        capture_output=True, text=True, timeout=300,
    )
    if p.returncode != 0:
        raise ValueError("certbot renew failed")
    return {
        "ok": True,
        "stdout": "\n".join((p.stdout or "").splitlines()[-20:]),
        "certificate": web_cert_status(),
    }


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


def host_uptime_seconds():
    raw = read_text_file("/proc/uptime")
    try:
        return max(0, int(float(raw.split()[0])))
    except (IndexError, ValueError):
        return 0


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
    keys = ("rx_bytes", "tx_bytes", "rx_packets", "tx_packets", "rx_dropped", "tx_dropped", "rx_errors", "tx_errors")
    out = {}
    for key in keys:
        value = read_int_file(stats_dir / key)
        out[key] = 0 if value is None else value
    out["operstate"] = read_text_file(Path("/sys/class/net") / iface / "operstate", "unknown")
    return out


def pct(numerator, denominator, digits=2):
    """Return numerator/denominator as a percentage rounded to `digits`, or
    None if the denominator is not a positive number."""
    try:
        denominator = float(denominator)
        numerator = float(numerator)
    except (TypeError, ValueError):
        return None
    if denominator <= 0:
        return None
    return round(100.0 * numerator / denominator, digits)


def iface_delta(name, current):
    global SERVER_HEALTH_PREV_NET
    previous = SERVER_HEALTH_PREV_NET.get(name) if current else None
    SERVER_HEALTH_PREV_NET[name] = dict(current or {})
    if not current or not previous:
        return {"drops_delta": 0, "errors_delta": 0, "packets_delta": 0, "drop_pct": None, "error_pct": None}
    drop_keys = ("rx_dropped", "tx_dropped")
    error_keys = ("rx_errors", "tx_errors")
    packet_keys = ("rx_packets", "tx_packets")
    drops_delta = sum(max(0, int(current.get(k, 0)) - int(previous.get(k, 0))) for k in drop_keys)
    errors_delta = sum(max(0, int(current.get(k, 0)) - int(previous.get(k, 0))) for k in error_keys)
    packets_delta = sum(max(0, int(current.get(k, 0)) - int(previous.get(k, 0))) for k in packet_keys)
    return {
        "drops_delta": drops_delta,
        "errors_delta": errors_delta,
        "packets_delta": packets_delta,
        "drop_pct": pct(drops_delta, packets_delta + drops_delta),
        "error_pct": pct(errors_delta, packets_delta + errors_delta),
    }


def counter_value_delta(key, current_value):
    global SERVER_HEALTH_PREV_COUNTERS
    previous = SERVER_HEALTH_PREV_COUNTERS.get(key)
    SERVER_HEALTH_PREV_COUNTERS[key] = current_value
    if previous is None or current_value is None:
        return 0
    return max(0, int(current_value) - int(previous))


def read_proc_net_table(path):
    """Parse /proc/net/{snmp,netstat}-style tables into a flat Prefix+Field -> int dict."""
    result = {}
    lines = read_text_file(path).splitlines()
    i = 0
    while i + 1 < len(lines):
        header = lines[i].split()
        values = lines[i + 1].split()
        if (
            len(header) >= 2
            and len(values) >= 2
            and header[0] == values[0]
            and header[0].endswith(":")
        ):
            prefix = header[0][:-1]
            for key, val in zip(header[1:], values[1:]):
                try:
                    result[prefix + key] = int(val)
                except ValueError:
                    pass
            i += 2
        else:
            i += 1
    return result


def read_snmp6_counters(path="/proc/net/snmp6"):
    result = {}
    for line in read_text_file(path).splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        try:
            result[parts[0]] = int(parts[1])
        except ValueError:
            continue
    return result


def qdisc_stats(iface):
    """Return {"dropped": int|None, "sent_packets": int|None} from `tc -s qdisc`
    for iface, cached for QDISC_CACHE_TTL."""
    global QDISC_CACHE
    if not iface:
        return {"dropped": None, "sent_packets": None}
    now = time.time()
    with QDISC_CACHE_LOCK:
        if QDISC_CACHE["iface"] == iface and now - QDISC_CACHE["ts"] < QDISC_CACHE_TTL:
            return {"dropped": QDISC_CACHE["dropped"], "sent_packets": QDISC_CACHE.get("sent_packets")}
        dropped = None
        sent_packets = None
        try:
            out = subprocess.run(
                ["tc", "-s", "qdisc", "show", "dev", iface],
                capture_output=True, text=True, timeout=2.0, check=False,
            )
            if out.returncode == 0:
                match = re.search(r"dropped (\d+)", out.stdout)
                if match:
                    dropped = int(match.group(1))
                match = re.search(r"Sent \d+ bytes (\d+) pkt", out.stdout)
                if match:
                    sent_packets = int(match.group(1))
        except (OSError, subprocess.SubprocessError, ValueError):
            dropped = None
            sent_packets = None
        QDISC_CACHE = {"ts": now, "dropped": dropped, "sent_packets": sent_packets, "iface": iface}
        return {"dropped": dropped, "sent_packets": sent_packets}


def qdisc_dropped(iface):
    """Return the qdisc-level 'dropped' counter for iface, cached for QDISC_CACHE_TTL."""
    return qdisc_stats(iface)["dropped"]


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


def schedule_server_reboot(auth, delay_seconds=1.0):
    actor_fp = auth_fingerprint(auth)
    audit_log(f"Server reboot requested actor_role={auth.get('role')} actor_fp={actor_fp}")

    def reboot_later():
        time.sleep(max(0.1, float(delay_seconds)))
        try:
            subprocess.Popen(["systemctl", "reboot"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception as exc:
            audit_log(f"Server reboot command failed error={exc.__class__.__name__}")

    threading.Thread(target=reboot_later, name="server-reboot", daemon=True).start()


def client_traffic_load(stats=None, now=None):
    """Summarize all WireGuard peer counters as current aggregate client load."""
    global SERVER_HEALTH_CLIENT_TRAFFIC_PREV
    now = time.time() if now is None else float(now)
    rows = stats if isinstance(stats, dict) else client_stats_map()
    server_rx = 0
    server_tx = 0
    client_count = 0
    active_count = 0
    for row in rows.values():
        if not isinstance(row, dict):
            continue
        client_count += 1
        pair = _traffic_pair(row)
        server_rx += pair["rx"]
        server_tx += pair["tx"]
        if int(row.get("latestHandshakeAt", row.get("last_handshake", 0)) or 0) > 0:
            active_count += 1

    server_rx_bps = 0.0
    server_tx_bps = 0.0
    prev = SERVER_HEALTH_CLIENT_TRAFFIC_PREV
    if prev:
        elapsed = max(0.0, now - float(prev.get("ts") or 0))
        if elapsed > 0:
            if server_rx >= int(prev.get("server_rx") or 0):
                server_rx_bps = (server_rx - int(prev.get("server_rx") or 0)) / elapsed
            if server_tx >= int(prev.get("server_tx") or 0):
                server_tx_bps = (server_tx - int(prev.get("server_tx") or 0)) / elapsed
    SERVER_HEALTH_CLIENT_TRAFFIC_PREV = {"ts": now, "server_rx": server_rx, "server_tx": server_tx}

    total_bps = server_rx_bps + server_tx_bps
    SERVER_HEALTH_CLIENT_TRAFFIC_PEAK["server_rx_bps"] = max(SERVER_HEALTH_CLIENT_TRAFFIC_PEAK["server_rx_bps"], server_rx_bps)
    SERVER_HEALTH_CLIENT_TRAFFIC_PEAK["server_tx_bps"] = max(SERVER_HEALTH_CLIENT_TRAFFIC_PEAK["server_tx_bps"], server_tx_bps)
    SERVER_HEALTH_CLIENT_TRAFFIC_PEAK["total_bps"] = max(SERVER_HEALTH_CLIENT_TRAFFIC_PEAK["total_bps"], total_bps)
    return {
        "server_rx_bytes": server_rx,
        "server_tx_bytes": server_tx,
        "server_rx_bps": round(server_rx_bps, 2),
        "server_tx_bps": round(server_tx_bps, 2),
        "server_total_bps": round(total_bps, 2),
        "client_upload_bps": round(server_rx_bps, 2),
        "client_download_bps": round(server_tx_bps, 2),
        "client_total_bps": round(total_bps, 2),
        "peak_server_rx_bps": round(SERVER_HEALTH_CLIENT_TRAFFIC_PEAK["server_rx_bps"], 2),
        "peak_server_tx_bps": round(SERVER_HEALTH_CLIENT_TRAFFIC_PEAK["server_tx_bps"], 2),
        "peak_total_bps": round(SERVER_HEALTH_CLIENT_TRAFFIC_PEAK["total_bps"], 2),
        "client_count": client_count,
        "active_count": active_count,
        "direction": {
            "server_rx": "client_upload",
            "server_tx": "client_download",
        },
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
        client_load = client_traffic_load(now=now)
        drops_delta = wan_delta["drops_delta"] + vpn_delta["drops_delta"]
        errors_delta = wan_delta["errors_delta"] + vpn_delta["errors_delta"]
        network_status = "warn" if drops_delta or errors_delta else "ok"

        snmp = read_proc_net_table("/proc/net/snmp")
        netstat = read_proc_net_table("/proc/net/netstat")
        snmp6 = read_snmp6_counters()
        wan_qdisc = qdisc_stats(wan_iface)
        qdisc_drop_delta = counter_value_delta("qdisc_dropped", wan_qdisc["dropped"])
        qdisc_sent_delta = counter_value_delta("qdisc_sent_packets", wan_qdisc["sent_packets"])
        tcp_retrans_delta = counter_value_delta("tcp_retrans", snmp.get("TcpRetransSegs"))
        tcp_segs_out_delta = counter_value_delta("tcp_segs_out", snmp.get("TcpOutSegs"))
        tcp_timeout_delta = counter_value_delta("tcp_timeouts", netstat.get("TcpExtTCPTimeouts"))
        ip6_no_route_delta = counter_value_delta("ip6_out_no_routes", snmp6.get("Ip6OutNoRoutes"))
        ip6_out_requests_delta = counter_value_delta("ip6_out_requests", snmp6.get("Ip6OutRequests"))
        qdisc_drop_pct = pct(qdisc_drop_delta, qdisc_drop_delta + qdisc_sent_delta)
        tcp_retrans_pct = pct(tcp_retrans_delta, tcp_segs_out_delta)
        tcp_timeout_pct = pct(tcp_timeout_delta, tcp_segs_out_delta)
        ip6_no_route_pct = pct(ip6_no_route_delta, ip6_no_route_delta + ip6_out_requests_delta)
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
            "host": {"uptime_seconds": host_uptime_seconds()},
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
                "wan_packets_delta": wan_delta["packets_delta"],
                "wan_drop_pct": wan_delta["drop_pct"],
                "wan_errors_delta": wan_delta["errors_delta"],
                "wan_error_pct": wan_delta["error_pct"],
                "vpn_drops_delta": vpn_delta["drops_delta"],
                "vpn_packets_delta": vpn_delta["packets_delta"],
                "vpn_drop_pct": vpn_delta["drop_pct"],
                "vpn_errors_delta": vpn_delta["errors_delta"],
                "vpn_error_pct": vpn_delta["error_pct"],
                "drops_delta": drops_delta,
                "errors_delta": errors_delta,
                "qdisc_drop_delta": qdisc_drop_delta,
                "qdisc_sent_delta": qdisc_sent_delta,
                "qdisc_drop_pct": qdisc_drop_pct,
                "tcp_retrans_delta": tcp_retrans_delta,
                "tcp_retrans_pct": tcp_retrans_pct,
                "tcp_timeout_delta": tcp_timeout_delta,
                "tcp_timeout_pct": tcp_timeout_pct,
                "tcp_segs_out_delta": tcp_segs_out_delta,
                "ip6_no_route_delta": ip6_no_route_delta,
                "ip6_no_route_pct": ip6_no_route_pct,
                "ip6_out_requests_delta": ip6_out_requests_delta,
                "clients": client_load,
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


def raw_drop_counters():
    """Read a raw, point-in-time snapshot of drop/error/retransmit counters,
    independent of the SERVER_HEALTH_PREV_* delta-tracking globals so it can
    be used for an isolated before/after sample."""
    wan_iface = detect_wan_iface()
    vpn_iface = detect_vpn_iface()
    wan_stats = read_iface_stats(wan_iface) or {}
    vpn_stats = read_iface_stats(vpn_iface) or {}
    snmp = read_proc_net_table("/proc/net/snmp")
    netstat = read_proc_net_table("/proc/net/netstat")
    snmp6 = read_snmp6_counters()
    qdisc = qdisc_stats(wan_iface)
    return {
        "timestamp": utc_now_iso(),
        "wan_iface": wan_iface,
        "vpn_iface": vpn_iface,
        "wan_rx_dropped": int(wan_stats.get("rx_dropped", 0)),
        "wan_tx_dropped": int(wan_stats.get("tx_dropped", 0)),
        "wan_rx_errors": int(wan_stats.get("rx_errors", 0)),
        "wan_tx_errors": int(wan_stats.get("tx_errors", 0)),
        "wan_rx_packets": int(wan_stats.get("rx_packets", 0)),
        "wan_tx_packets": int(wan_stats.get("tx_packets", 0)),
        "vpn_rx_dropped": int(vpn_stats.get("rx_dropped", 0)),
        "vpn_tx_dropped": int(vpn_stats.get("tx_dropped", 0)),
        "vpn_rx_errors": int(vpn_stats.get("rx_errors", 0)),
        "vpn_tx_errors": int(vpn_stats.get("tx_errors", 0)),
        "vpn_rx_packets": int(vpn_stats.get("rx_packets", 0)),
        "vpn_tx_packets": int(vpn_stats.get("tx_packets", 0)),
        "qdisc_dropped": qdisc["dropped"] or 0,
        "qdisc_sent_packets": qdisc["sent_packets"] or 0,
        "tcp_retrans_segs": int(snmp.get("TcpRetransSegs", 0) or 0),
        "tcp_out_segs": int(snmp.get("TcpOutSegs", 0) or 0),
        "tcp_timeouts": int(netstat.get("TcpExtTCPTimeouts", 0) or 0),
        "ip6_out_no_routes": int(snmp6.get("Ip6OutNoRoutes", 0) or 0),
        "ip6_out_requests": int(snmp6.get("Ip6OutRequests", 0) or 0),
    }


def drops_sample_report(before, after, duration_seconds):
    """Build a before/after delta + percentage report from two raw_drop_counters() snapshots."""
    wan_drops_before = before["wan_rx_dropped"] + before["wan_tx_dropped"]
    wan_drops_after = after["wan_rx_dropped"] + after["wan_tx_dropped"]
    wan_packets_before = before["wan_rx_packets"] + before["wan_tx_packets"]
    wan_packets_after = after["wan_rx_packets"] + after["wan_tx_packets"]
    wan_errors_before = before["wan_rx_errors"] + before["wan_tx_errors"]
    wan_errors_after = after["wan_rx_errors"] + after["wan_tx_errors"]

    vpn_drops_before = before["vpn_rx_dropped"] + before["vpn_tx_dropped"]
    vpn_drops_after = after["vpn_rx_dropped"] + after["vpn_tx_dropped"]
    vpn_packets_before = before["vpn_rx_packets"] + before["vpn_tx_packets"]
    vpn_packets_after = after["vpn_rx_packets"] + after["vpn_tx_packets"]
    vpn_errors_before = before["vpn_rx_errors"] + before["vpn_tx_errors"]
    vpn_errors_after = after["vpn_rx_errors"] + after["vpn_tx_errors"]

    wan_drops_delta = max(0, wan_drops_after - wan_drops_before)
    wan_packets_delta = max(0, wan_packets_after - wan_packets_before)
    wan_errors_delta = max(0, wan_errors_after - wan_errors_before)
    vpn_drops_delta = max(0, vpn_drops_after - vpn_drops_before)
    vpn_packets_delta = max(0, vpn_packets_after - vpn_packets_before)
    vpn_errors_delta = max(0, vpn_errors_after - vpn_errors_before)
    qdisc_drop_delta = max(0, after["qdisc_dropped"] - before["qdisc_dropped"])
    qdisc_sent_delta = max(0, after["qdisc_sent_packets"] - before["qdisc_sent_packets"])
    tcp_retrans_delta = max(0, after["tcp_retrans_segs"] - before["tcp_retrans_segs"])
    tcp_out_segs_delta = max(0, after["tcp_out_segs"] - before["tcp_out_segs"])
    tcp_timeout_delta = max(0, after["tcp_timeouts"] - before["tcp_timeouts"])
    ip6_no_route_delta = max(0, after["ip6_out_no_routes"] - before["ip6_out_no_routes"])
    ip6_out_requests_delta = max(0, after["ip6_out_requests"] - before["ip6_out_requests"])

    return {
        "duration_seconds": duration_seconds,
        "before": before,
        "after": after,
        "wan": {
            "drops_delta": wan_drops_delta,
            "packets_delta": wan_packets_delta,
            "drop_pct": pct(wan_drops_delta, wan_drops_delta + wan_packets_delta),
            "errors_delta": wan_errors_delta,
            "error_pct": pct(wan_errors_delta, wan_errors_delta + wan_packets_delta),
        },
        "vpn": {
            "drops_delta": vpn_drops_delta,
            "packets_delta": vpn_packets_delta,
            "drop_pct": pct(vpn_drops_delta, vpn_drops_delta + vpn_packets_delta),
            "errors_delta": vpn_errors_delta,
            "error_pct": pct(vpn_errors_delta, vpn_errors_delta + vpn_packets_delta),
        },
        "qdisc": {
            "drop_delta": qdisc_drop_delta,
            "sent_delta": qdisc_sent_delta,
            "drop_pct": pct(qdisc_drop_delta, qdisc_drop_delta + qdisc_sent_delta),
        },
        "tcp": {
            "retrans_delta": tcp_retrans_delta,
            "timeout_delta": tcp_timeout_delta,
            "out_segs_delta": tcp_out_segs_delta,
            "retrans_pct": pct(tcp_retrans_delta, tcp_out_segs_delta),
            "timeout_pct": pct(tcp_timeout_delta, tcp_out_segs_delta),
        },
        "ipv6": {
            "no_route_delta": ip6_no_route_delta,
            "out_requests_delta": ip6_out_requests_delta,
            "no_route_pct": pct(ip6_no_route_delta, ip6_no_route_delta + ip6_out_requests_delta),
        },
    }


def read_cpu_flags():
    for line in read_text_file("/proc/cpuinfo").splitlines():
        if line.startswith("flags") or line.startswith("Features"):
            _, _, rest = line.partition(":")
            return set(rest.split())
    return set()


def kernel_module_check():
    names = set()
    for line in read_text_file("/proc/modules").splitlines():
        parts = line.split()
        if parts:
            names.add(parts[0])
    has_awg = "amneziawg" in names or Path("/sys/module/amneziawg").exists()
    has_wg = "wireguard" in names or Path("/sys/module/wireguard").exists()
    if has_awg or has_wg:
        status = "ok"
        detail = "amneziawg kernel module loaded" if has_awg else "wireguard kernel module loaded"
    else:
        status = "warn"
        detail = "no amneziawg/wireguard kernel module detected (userspace implementation may be in use)"
    return {
        "status": status,
        "amneziawg_loaded": has_awg,
        "wireguard_loaded": has_wg,
        "detail": detail,
    }


def crypto_features_check():
    machine = os.uname().machine.lower()
    flags = read_cpu_flags()
    if machine in ("x86_64", "amd64", "i386", "i686"):
        accel = {"aes", "avx", "avx2", "bmi2", "adx", "rdrand", "pclmulqdq"} & flags
        fast = {"aes", "avx2"} <= flags
    elif machine.startswith("arm") or machine.startswith("aarch64"):
        accel = {"aes", "pmull", "sha1", "sha2", "asimd"} & flags
        fast = {"aes", "asimd"} <= flags
    else:
        accel = set()
        fast = False
    status = "ok" if fast else ("info" if accel else "warn")
    return {
        "status": status,
        "arch": machine,
        "accelerated_flags": sorted(accel),
        "detail": (
            "hardware crypto acceleration available"
            if fast
            else "limited or no hardware crypto acceleration detected (AmneziaWG falls back to software crypto)"
        ),
    }


def virtualization_check():
    name = "unknown"
    try:
        out = subprocess.run(
            ["systemd-detect-virt"], capture_output=True, text=True, timeout=2.0, check=False,
        )
        name = (out.stdout or "").strip() or "none"
    except (OSError, subprocess.SubprocessError):
        name = "unknown"
    return {"status": "info", "type": name}


def ip_forwarding_check():
    v4 = read_text_file("/proc/sys/net/ipv4/ip_forward", "0").strip()
    v6 = read_text_file("/proc/sys/net/ipv6/conf/all/forwarding", "0").strip()
    status = "ok" if v4 == "1" else "critical"
    return {
        "status": status,
        "ipv4_forwarding": v4 == "1",
        "ipv6_forwarding": v6 == "1",
    }


def udp_buffer_check():
    rmem = read_int_file("/proc/sys/net/core/rmem_max") or 0
    wmem = read_int_file("/proc/sys/net/core/wmem_max") or 0
    recommended = 2_500_000
    status = "ok" if rmem >= recommended and wmem >= recommended else "warn"
    return {
        "status": status,
        "rmem_max": rmem,
        "wmem_max": wmem,
        "recommended_min": recommended,
    }


def wan_offload_check(iface):
    if not iface:
        return {"status": "info", "iface": "", "offloads": {}}
    offloads = {}
    interesting = {
        "tcp-segmentation-offload",
        "generic-segmentation-offload",
        "generic-receive-offload",
        "large-receive-offload",
        "udp-fragmentation-offload",
    }
    try:
        out = subprocess.run(
            ["ethtool", "-k", iface], capture_output=True, text=True, timeout=2.0, check=False,
        )
        for line in out.stdout.splitlines():
            line = line.strip()
            if ":" not in line:
                continue
            key, _, value = line.partition(":")
            key = key.strip()
            if key in interesting:
                offloads[key] = value.strip().split()[0] if value.strip() else "unknown"
    except (OSError, subprocess.SubprocessError):
        pass
    return {"status": "info", "iface": iface, "offloads": offloads}


def ipv6_routing_check():
    disabled = read_text_file("/proc/sys/net/ipv6/conf/all/disable_ipv6", "0").strip() == "1"
    has_global = False
    for line in read_text_file("/proc/net/if_inet6").splitlines():
        parts = line.split()
        if len(parts) >= 6 and parts[3] == "00" and parts[5] != "lo":
            has_global = True
            break
    mode = "enabled" if (not disabled and has_global) else "disabled"
    return {"status": "info", "mode": mode, "global_address": has_global}


def ipv6_default_route_present():
    for line in read_text_file("/proc/net/ipv6_route").splitlines():
        parts = line.split()
        if parts and parts[0] == "00000000000000000000000000000000":
            return True
    return False


def validate_ipv6_prefix(value):
    """Validate an IPv6 CIDR prefix (e.g. '2001:db8:abcd::/64'). Returns the
    normalized string form, or raises ValueError."""
    value = str(value or "").strip()
    if not value:
        raise ValueError("IPv6 prefix is required")
    try:
        net = ipaddress.ip_network(value, strict=True)
    except ValueError as exc:
        raise ValueError(f"invalid IPv6 prefix: {exc}") from exc
    if net.version != 6:
        raise ValueError("prefix must be an IPv6 network")
    return str(net)


def ipv6_ndp_state(ipv6_routing, cfg):
    """Classify the IPv6/NDP situation of this host. See manage_amneziawg.sh
    ipv6_ndp_state() for the matching shell-side classification."""
    if ipv6_routing.get("mode") == "disabled" or not ipv6_routing.get("global_address"):
        return "ipv6_disabled"
    mode = str(cfg.get("AWG_IPV6_MODE_EFFECTIVE") or cfg.get("AWG_IPV6_MODE") or "legacy").lower()
    if mode == "ndp":
        return "ipv6_prefix_onlink_needs_ndp_proxy"
    if mode in ("routed", "nat66"):
        return "ipv6_prefix_routed_to_server"
    if cfg.get("AWG_IPV6_SUBNET"):
        return "ipv6_unknown_manual_review"
    return "ipv6_public_single_address_only"


def ndppd_service_active():
    try:
        out = subprocess.run(
            ["systemctl", "is-active", "ndppd"], capture_output=True, text=True, timeout=2.0, check=False,
        )
        return (out.stdout or "").strip() == "active"
    except (OSError, subprocess.SubprocessError):
        return False


def systemctl_is_enabled(unit):
    try:
        out = subprocess.run(
            ["systemctl", "is-enabled", unit], capture_output=True, text=True, timeout=2.0, check=False,
        )
        return (out.stdout or "").strip() in {"enabled", "static"}
    except (OSError, subprocess.SubprocessError):
        return False


def ipv6_address_collisions(prefix, wan_iface):
    try:
        net = ipaddress.ip_network(prefix, strict=False) if prefix else None
    except ValueError:
        net = None
    owners = {}

    def add(addr, owner):
        try:
            ip = ipaddress.ip_address(str(addr).split("/", 1)[0])
        except ValueError:
            return
        if ip.version != 6 or (net is not None and ip not in net):
            return
        owners.setdefault(str(ip), []).append(owner)

    try:
        out = subprocess.run(["ip", "-6", "-o", "addr", "show", "dev", wan_iface, "scope", "global"], capture_output=True, text=True, timeout=2.0, check=False)
        for token in re.findall(r"inet6\s+([0-9A-Fa-f:]+)/\d+", out.stdout or ""):
            add(token, f"WAN:{wan_iface}")
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        out = subprocess.run(["ip", "-6", "route", "show", "default"], capture_output=True, text=True, timeout=2.0, check=False)
        for token in re.findall(r"\bvia\s+([0-9A-Fa-f:]+)", out.stdout or ""):
            add(token, "WAN:gateway")
    except (OSError, subprocess.SubprocessError):
        pass
    paths = [Path(SERVER_CONF)]
    try:
        paths.extend(Path(AWG_DIR).glob("*.conf"))
    except OSError:
        pass
    for path in paths:
        data = read_text_file(path)
        in_interface = False
        for line in data.splitlines():
            stripped = line.strip()
            if stripped == "[Interface]":
                in_interface = True
                continue
            if stripped.startswith("[") and stripped != "[Interface]":
                in_interface = False
            if in_interface and path == Path(SERVER_CONF) and stripped.startswith("Address"):
                for token in re.findall(r"([0-9A-Fa-f:]+/\d+)", stripped):
                    add(token, f"server:{path}")
        for token in re.findall(r"(?:AllowedIPs|Address)\s*=\s*[^\n#]*?([0-9A-Fa-f:]+)/128", data):
            add(token, f"client:{path}")

    collisions = []
    for addr, owner_list in owners.items():
        client = [x for x in owner_list if x.startswith("client:")]
        non_client = [x for x in owner_list if not x.startswith("client:")]
        if client and non_client:
            collisions.append({"address": addr, "owners": owner_list})
    return sorted(collisions, key=lambda item: ipaddress.ip_address(item["address"]))


def ndp_proxy_check(ipv6_mode, has_global_ipv6, cfg=None, wan_iface=""):
    cfg = cfg or {}
    effective = str(cfg.get("AWG_IPV6_MODE_EFFECTIVE") or cfg.get("AWG_IPV6_MODE") or "legacy").lower()
    binary = shutil.which("ndppd")
    config_exists = Path("/etc/ndppd.conf").exists()
    enabled = systemctl_is_enabled("ndppd")
    active = ndppd_service_active()

    if ipv6_mode == "disabled":
        return {
            "status": "info",
            "state": "not_needed",
            "detail": "IPv6 is disabled on this host; NDP proxy is not applicable.",
            "installed": bool(binary),
            "configured": config_exists,
            "enabled": enabled,
            "ndppd_active": active,
        }

    if effective == "ndp":
        missing = []
        if not binary:
            missing.append("package missing")
        if not config_exists:
            missing.append("config missing")
        if not active:
            missing.append("service inactive")
        if missing:
            detail = "NDP proxy is needed for the on-link IPv6 prefix: " + ", ".join(missing) + "."
            status = "error" if not binary or not config_exists else "warn"
        else:
            detail = "NDP proxy is needed and ndppd is installed, configured, and active."
            status = "ok"
        return {
            "status": status,
            "state": "needed",
            "detail": detail,
            "installed": bool(binary),
            "configured": config_exists,
            "enabled": enabled,
            "ndppd_active": active,
            "needed": True,
        }

    if has_global_ipv6 and not ipv6_default_route_present():
        if binary and config_exists and enabled:
            return {
                "status": "ok",
                "state": "configured",
                "detail": "ndppd is installed and enabled.",
                "installed": True,
                "configured": True,
                "enabled": enabled,
                "ndppd_active": active,
            }
        return {
            "status": "warn",
            "state": "may_be_needed",
            "detail": "Global IPv6 address present without a default route; NDP proxy (ndppd) may be needed.",
            "installed": bool(binary),
            "configured": config_exists,
            "enabled": enabled,
            "ndppd_active": active,
        }

    return {
        "status": "info",
        "state": "not_needed",
        "detail": "A routed IPv6 prefix is present; NDP proxy is not needed.",
        "installed": bool(binary),
        "configured": config_exists,
        "enabled": enabled,
        "ndppd_active": active,
        "needed": False,
    }


def vpn_readiness_payload(force=False):
    global VPN_READINESS_CACHE, VPN_READINESS_CACHE_TS
    now = time.time()
    with VPN_READINESS_LOCK:
        if not force and VPN_READINESS_CACHE and now - VPN_READINESS_CACHE_TS < VPN_READINESS_CACHE_TTL:
            return VPN_READINESS_CACHE

        wan_iface = detect_wan_iface()
        kernel = kernel_module_check()
        crypto = crypto_features_check()
        virt = virtualization_check()
        ip_fwd = ip_forwarding_check()
        udp_buf = udp_buffer_check()
        offloads = wan_offload_check(wan_iface)
        ipv6_routing = ipv6_routing_check()
        cfg = parse_config()
        ndp = ndp_proxy_check(ipv6_routing["mode"], ipv6_routing["global_address"], cfg, wan_iface)
        ndp["mode"] = ipv6_ndp_state(ipv6_routing, cfg)
        ndp["wan_iface"] = wan_iface
        ndp["vpn_iface"] = detect_vpn_iface()
        ndp["prefix"] = cfg.get("AWG_IPV6_SUBNET") or ""
        ndp["proxy_ndp_sysctl"] = read_text_file("/proc/sys/net/ipv6/conf/all/proxy_ndp", "0").strip()
        ndp["proxy_ndp_wan_sysctl"] = read_text_file(f"/proc/sys/net/ipv6/conf/{wan_iface}/proxy_ndp", "0").strip()
        ndp["forwarding_sysctl"] = read_text_file("/proc/sys/net/ipv6/conf/all/forwarding", "0").strip()
        ndp["collisions"] = ipv6_address_collisions(ndp["prefix"], wan_iface)

        overall = combine_status(
            kernel["status"],
            ip_fwd["status"],
            udp_buf["status"],
            "ok" if crypto["status"] == "info" else crypto["status"],
            "ok" if ndp["status"] == "info" else ndp["status"],
        )
        payload = {
            "timestamp": utc_now_iso(),
            "cache_ttl_seconds": VPN_READINESS_CACHE_TTL,
            "status": overall,
            "kernel": {"release": os.uname().release, **kernel},
            "crypto": crypto,
            "virtualization": virt,
            "ip_forwarding": ip_fwd,
            "udp_buffers": udp_buf,
            "wan_offloads": offloads,
            "ipv6_routing": ipv6_routing,
            "ndp_proxy": ndp,
        }
        VPN_READINESS_CACHE = payload
        VPN_READINESS_CACHE_TS = now
        return payload


def safe_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def safe_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def flatten_health_sample(payload):
    now = time.time()
    load = payload.get("load") if isinstance(payload.get("load"), dict) else {}
    cpu = payload.get("cpu") if isinstance(payload.get("cpu"), dict) else {}
    memory = payload.get("memory") if isinstance(payload.get("memory"), dict) else {}
    disk = payload.get("disk") if isinstance(payload.get("disk"), dict) else {}
    conntrack = payload.get("conntrack") if isinstance(payload.get("conntrack"), dict) else {}
    network = payload.get("network") if isinstance(payload.get("network"), dict) else {}
    process = payload.get("process") if isinstance(payload.get("process"), dict) else {}
    wan = network.get("wan") if isinstance(network.get("wan"), dict) else {}
    vpn = network.get("vpn") if isinstance(network.get("vpn"), dict) else {}
    clients = network.get("clients") if isinstance(network.get("clients"), dict) else {}
    return {
        "ts": int(now),
        "timestamp": payload.get("timestamp") or utc_now_iso(),
        "status": payload.get("status") or "unknown",
        "cpu_usage_percent": safe_float(cpu.get("usage_percent")),
        "load1": safe_float(load.get("one")),
        "load5": safe_float(load.get("five")),
        "load15": safe_float(load.get("fifteen")),
        "cpu_count": safe_int(load.get("cpu_count")) or 1,
        "memory_used_percent": safe_float(memory.get("used_percent")),
        "memory_available_bytes": safe_int(memory.get("available_bytes")) or 0,
        "swap_used_percent": safe_float(memory.get("swap_used_percent")),
        "disk_used_percent": safe_float(disk.get("used_percent")),
        "disk_free_bytes": safe_int(disk.get("free_bytes")) or 0,
        "conntrack_count": safe_int(conntrack.get("count")),
        "conntrack_used_percent": safe_float(conntrack.get("used_percent")),
        "wan_iface": network.get("wan_iface") or "",
        "wan_rx_bytes": safe_int(wan.get("rx_bytes")) or 0,
        "wan_tx_bytes": safe_int(wan.get("tx_bytes")) or 0,
        "wan_rx_dropped": safe_int(wan.get("rx_dropped")) or 0,
        "wan_tx_dropped": safe_int(wan.get("tx_dropped")) or 0,
        "wan_rx_errors": safe_int(wan.get("rx_errors")) or 0,
        "wan_tx_errors": safe_int(wan.get("tx_errors")) or 0,
        "vpn_iface": network.get("vpn_iface") or "",
        "vpn_rx_bytes": safe_int(vpn.get("rx_bytes")) or 0,
        "vpn_tx_bytes": safe_int(vpn.get("tx_bytes")) or 0,
        "vpn_rx_dropped": safe_int(vpn.get("rx_dropped")) or 0,
        "vpn_tx_dropped": safe_int(vpn.get("tx_dropped")) or 0,
        "vpn_rx_errors": safe_int(vpn.get("rx_errors")) or 0,
        "vpn_tx_errors": safe_int(vpn.get("tx_errors")) or 0,
        "client_server_rx_bytes": safe_int(clients.get("server_rx_bytes")) or 0,
        "client_server_tx_bytes": safe_int(clients.get("server_tx_bytes")) or 0,
        "python_rss_bytes": safe_int(process.get("rss_bytes")) or 0,
        "python_fd_count": safe_int(process.get("fd_count")) or 0,
        "python_threads": safe_int(process.get("threads")) or 0,
    }


def health_sample_path(ts=None):
    ts = time.time() if ts is None else ts
    return HEALTH_HISTORY_DIR / f"samples-{time.strftime('%Y%m%d', time.gmtime(ts))}.jsonl"


def prune_health_history(now=None):
    now = time.time() if now is None else now
    cutoff = now - (SERVER_HEALTH_RETENTION_DAYS + 1) * 86400
    try:
        for path in HEALTH_HISTORY_DIR.glob("samples-*.jsonl"):
            if path.stat().st_mtime < cutoff:
                path.unlink()
    except OSError as exc:
        audit_log(f"Health history prune warning error={type(exc).__name__}")


def write_health_sample(sample):
    try:
        HEALTH_HISTORY_DIR.mkdir(parents=True, exist_ok=True)
        os.chmod(HEALTH_HISTORY_DIR, 0o700)
        path = health_sample_path(sample.get("ts") or time.time())
        with path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(sample, sort_keys=True, separators=(",", ":")) + "\n")
        os.chmod(path, 0o600)
        if int(sample.get("ts") or 0) % 3600 < SERVER_HEALTH_SAMPLE_INTERVAL:
            prune_health_history()
    except OSError as exc:
        audit_log(f"Health history write warning error={type(exc).__name__}")


def health_collector_loop():
    while True:
        try:
            write_health_sample(flatten_health_sample(collect_server_health(force=True)))
        except Exception as exc:
            audit_log(f"Health collector warning error={type(exc).__name__}")
        time.sleep(SERVER_HEALTH_SAMPLE_INTERVAL)


def start_server_health_collector():
    global SERVER_HEALTH_COLLECTOR_STARTED
    with SERVER_HEALTH_LOCK:
        if SERVER_HEALTH_COLLECTOR_STARTED:
            return
        SERVER_HEALTH_COLLECTOR_STARTED = True
    threading.Thread(target=health_collector_loop, name="health-history", daemon=True).start()


def clear_health_history():
    """Delete all stored server load/health history samples and the cached
    history responses. Returns the number of sample files removed."""
    count = 0
    if HEALTH_HISTORY_DIR.exists():
        for path in HEALTH_HISTORY_DIR.glob("samples-*.jsonl"):
            try:
                path.unlink()
                count += 1
            except OSError:
                continue
    with SERVER_HEALTH_LOCK:
        SERVER_HEALTH_HISTORY_CACHE.clear()
    return count


def read_health_samples(range_seconds):
    now = int(time.time())
    start_ts = now - int(range_seconds)
    rows = []
    if not HEALTH_HISTORY_DIR.exists():
        return rows
    start_day = int((start_ts - 86400) // 86400)
    end_day = int(now // 86400)
    paths = []
    for day in range(start_day, end_day + 1):
        paths.append(HEALTH_HISTORY_DIR / f"samples-{time.strftime('%Y%m%d', time.gmtime(day * 86400))}.jsonl")
    for path in paths:
        if not path.exists():
            continue
        try:
            with path.open("r", encoding="utf-8") as fh:
                for line in fh:
                    if not line.strip():
                        continue
                    try:
                        row = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    ts = safe_int(row.get("ts")) or 0
                    if start_ts <= ts <= now:
                        rows.append(row)
        except OSError:
            continue
    rows.sort(key=lambda item: safe_int(item.get("ts")) or 0)
    return rows


def avg_value(rows, key):
    values = [safe_float(row.get(key)) for row in rows]
    values = [value for value in values if value is not None]
    return sum(values) / len(values) if values else None


def max_value(rows, key):
    values = [safe_float(row.get(key)) for row in rows]
    values = [value for value in values if value is not None]
    return max(values) if values else None


def min_value(rows, key):
    values = [safe_float(row.get(key)) for row in rows]
    values = [value for value in values if value is not None]
    return min(values) if values else None


def counter_delta(rows, key):
    values = [(safe_int(row.get("ts")) or 0, safe_int(row.get(key))) for row in rows if safe_int(row.get(key)) is not None]
    if len(values) < 2:
        return 0
    return max(0, int(values[-1][1]) - int(values[0][1]))


def counter_rate_summary(rows, key):
    values = [(safe_int(row.get("ts")) or 0, safe_int(row.get(key))) for row in rows if safe_int(row.get(key)) is not None]
    if len(values) < 2:
        return {"avg_bps": 0, "peak_bps": 0, "current_bps": 0}
    first_ts, first_value = values[0]
    last_ts, last_value = values[-1]
    duration = max(1, last_ts - first_ts)
    avg_bps = max(0, int(last_value) - int(first_value)) / duration
    peak_bps = 0
    current_bps = 0
    for idx in range(1, len(values)):
        prev_ts, prev_value = values[idx - 1]
        ts, value = values[idx]
        elapsed = ts - prev_ts
        if elapsed <= 0 or int(value) < int(prev_value):
            continue
        rate = (int(value) - int(prev_value)) / elapsed
        peak_bps = max(peak_bps, rate)
        current_bps = rate
    return {
        "avg_bps": round(avg_bps, 2),
        "peak_bps": round(peak_bps, 2),
        "current_bps": round(current_bps, 2),
    }


def bucket_seconds_for_range(range_seconds):
    if range_seconds <= 3600:
        return 60
    if range_seconds <= 24 * 3600:
        return 300
    if range_seconds <= 7 * 24 * 3600:
        return 1800
    return 3600


def bucket_health_series(rows, bucket_seconds):
    buckets = {}
    for row in rows:
        ts = safe_int(row.get("ts")) or 0
        key = ts - (ts % bucket_seconds)
        buckets.setdefault(key, []).append(row)
    series = []
    for bucket_ts in sorted(buckets):
        items = buckets[bucket_ts]
        series.append({
            "t": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(bucket_ts)),
            "cpu": avg_value(items, "cpu_usage_percent"),
            "memory": avg_value(items, "memory_used_percent"),
            "load1": avg_value(items, "load1"),
            "conntrack": avg_value(items, "conntrack_used_percent"),
            "python_rss": max_value(items, "python_rss_bytes"),
            "python_fd": max_value(items, "python_fd_count"),
        })
    return series


def summarize_health_history(rows):
    warn_count = sum(1 for row in rows if row.get("status") == "warn")
    critical_count = sum(1 for row in rows if row.get("status") == "critical")
    drops_delta = sum(counter_delta(rows, key) for key in (
        "wan_rx_dropped", "wan_tx_dropped", "vpn_rx_dropped", "vpn_tx_dropped",
    ))
    errors_delta = sum(counter_delta(rows, key) for key in (
        "wan_rx_errors", "wan_tx_errors", "vpn_rx_errors", "vpn_tx_errors",
    ))
    max_rss = max_value(rows, "python_rss_bytes")
    current_rss = safe_int(rows[-1].get("python_rss_bytes")) if rows else None
    rss_growth_ratio = (max_rss / current_rss) if current_rss else None
    status = "ok"
    if critical_count or (max_value(rows, "cpu_usage_percent") or 0) >= 90 or (max_value(rows, "memory_used_percent") or 0) >= 90:
        status = "critical"
    elif warn_count or drops_delta or errors_delta or (max_value(rows, "cpu_usage_percent") or 0) >= 75 or (max_value(rows, "memory_used_percent") or 0) >= 80:
        status = "warn"
    notes = []
    if drops_delta:
        notes.append(f"Interface drops increased +{drops_delta}.")
    if errors_delta:
        notes.append(f"Interface errors increased +{errors_delta}.")
    if rss_growth_ratio and rss_growth_ratio >= 2:
        notes.append("Python RSS peak is more than 2x current RSS.")
    return {
        "cpu": {"avg": avg_value(rows, "cpu_usage_percent"), "max": max_value(rows, "cpu_usage_percent")},
        "load": {"avg1": avg_value(rows, "load1"), "max1": max_value(rows, "load1")},
        "memory": {
            "avg_used_percent": avg_value(rows, "memory_used_percent"),
            "max_used_percent": max_value(rows, "memory_used_percent"),
            "min_available_bytes": min_value(rows, "memory_available_bytes"),
        },
        "swap": {"max_used_percent": max_value(rows, "swap_used_percent")},
        "disk": {"current_used_percent": rows[-1].get("disk_used_percent") if rows else None, "min_free_bytes": min_value(rows, "disk_free_bytes")},
        "conntrack": {"max_count": max_value(rows, "conntrack_count"), "max_used_percent": max_value(rows, "conntrack_used_percent")},
        "network": {
            "wan_rx_dropped_delta": counter_delta(rows, "wan_rx_dropped"),
            "wan_tx_dropped_delta": counter_delta(rows, "wan_tx_dropped"),
            "vpn_rx_dropped_delta": counter_delta(rows, "vpn_rx_dropped"),
            "vpn_tx_dropped_delta": counter_delta(rows, "vpn_tx_dropped"),
            "wan_errors_delta": counter_delta(rows, "wan_rx_errors") + counter_delta(rows, "wan_tx_errors"),
            "vpn_errors_delta": counter_delta(rows, "vpn_rx_errors") + counter_delta(rows, "vpn_tx_errors"),
            "drops_delta": drops_delta,
            "errors_delta": errors_delta,
            "rates": {
                "wan_rx": counter_rate_summary(rows, "wan_rx_bytes"),
                "wan_tx": counter_rate_summary(rows, "wan_tx_bytes"),
                "vpn_rx": counter_rate_summary(rows, "vpn_rx_bytes"),
                "vpn_tx": counter_rate_summary(rows, "vpn_tx_bytes"),
                "clients_rx": counter_rate_summary(rows, "client_server_rx_bytes"),
                "clients_tx": counter_rate_summary(rows, "client_server_tx_bytes"),
            },
        },
        "process": {"max_rss_bytes": max_rss, "max_fd_count": max_value(rows, "python_fd_count"), "max_threads": max_value(rows, "python_threads")},
        "counts": {"samples": len(rows), "warn": warn_count, "critical": critical_count},
        "status": status,
        "notes": notes[:6],
    }


def server_health_history(range_key):
    if range_key not in SERVER_HEALTH_RANGES:
        raise ValueError("invalid history range")
    now = time.time()
    with SERVER_HEALTH_LOCK:
        cached = SERVER_HEALTH_HISTORY_CACHE.get(range_key)
        if cached and now - cached.get("ts", 0) < SERVER_HEALTH_HISTORY_CACHE_TTL:
            return cached["value"]
    range_seconds = SERVER_HEALTH_RANGES[range_key]
    rows = read_health_samples(range_seconds)
    if not rows:
        rows = [flatten_health_sample(collect_server_health())]
    bucket_seconds = bucket_seconds_for_range(range_seconds)
    summary = summarize_health_history(rows)
    payload = {
        "range": range_key,
        "range_seconds": range_seconds,
        "bucket_seconds": bucket_seconds,
        "sample_interval_seconds": SERVER_HEALTH_SAMPLE_INTERVAL,
        "retention_days": SERVER_HEALTH_RETENTION_DAYS,
        "summary": summary,
        "series": bucket_health_series(rows, bucket_seconds),
        "status": summary["status"],
    }
    with SERVER_HEALTH_LOCK:
        SERVER_HEALTH_HISTORY_CACHE[range_key] = {"ts": now, "value": payload}
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


def first_ip_in_subnet(cidr):
    try:
        net = ipaddress.ip_network(cidr, strict=False)
    except ValueError:
        return ""
    try:
        return str(net.network_address + 1)
    except Exception:
        return str(net.network_address)


def configured_vpn_ipv4():
    try:
        interface = ipaddress.ip_interface(parse_config().get("AWG_TUNNEL_SUBNET") or "10.9.9.1/24")
        if interface.version != 4:
            raise ValueError("not IPv4")
        return str(interface.ip), str(interface.network)
    except (OSError, ValueError):
        return "10.9.9.1", "10.9.9.0/24"


def detect_public_ipv6(iface=""):
    try:
        lines = Path("/proc/net/if_inet6").read_text(encoding="utf-8").splitlines()
    except OSError:
        return ""
    for line in lines:
        parts = line.split()
        if len(parts) < 6:
            continue
        raw, _idx, _plen, scope, _flags, name = parts[:6]
        if iface and name != iface:
            continue
        if scope != "00" or name == "lo":
            continue
        try:
            return str(ipaddress.IPv6Address(":".join(raw[i:i + 4] for i in range(0, 32, 4))))
        except ValueError:
            continue
    return ""


def server_info_payload():
    cfg = parse_config()
    endpoint = cfg.get("AWG_ENDPOINT") or ""
    public_ipv4 = ""
    public_ipv6 = ""
    try:
        endpoint_ip = ipaddress.ip_address(endpoint)
        if endpoint_ip.version == 4:
            public_ipv4 = str(endpoint_ip)
        else:
            public_ipv6 = str(endpoint_ip)
    except ValueError:
        pass
    public_ipv6 = public_ipv6 or detect_public_ipv6(detect_wan_iface())
    vpn_ipv4 = cfg.get("AWG_TUNNEL_SUBNET") or "10.9.9.1/24"
    vpn_ipv4_host = first_ip_in_subnet(vpn_ipv4) or "10.9.9.1"
    vpn_ipv6 = cfg.get("AWG_IPV6_SUBNET") if cfg.get("AWG_IPV6_ENABLED") == "1" else ""
    web_host = cfg.get("AWG_WEB_DOMAIN") or (f"{endpoint.replace('.', '-')}.sslip.io" if public_ipv4 else endpoint) or "localhost"
    web_public_url = cfg.get("AWG_WEB_PUBLIC_URL") or f"https://{web_host}/"
    adguard_enabled = cfg.get("AWG_ADGUARD_ENABLED") == "1"
    adguard_url = f"http://{vpn_ipv4_host}:{cfg.get('AWG_ADGUARD_PORT') or '3000'}/" if adguard_enabled else ""
    dns_mode = cfg.get("AWG_DNS_MODE", "system")
    if dns_mode == "adguard":
        dns_resolver = vpn_ipv4_host
    elif dns_mode == "custom":
        dns_resolver = cfg.get("AWG_CUSTOM_DNS", "1.1.1.1")
    else:
        dns_resolver = "1.1.1.1"
    nettest_vpn_url = f"http://{vpn_ipv4_host}:{VPN_NETTEST_PORT}/nettest"
    return {
        "public_ipv4": public_ipv4,
        "public_ipv6": public_ipv6,
        "vpn_ipv4": vpn_ipv4,
        "vpn_ipv6": vpn_ipv6,
        "vpn_gateway_ipv4": vpn_ipv4_host,
        "vpn_ipv4_network": str(ipaddress.ip_interface(vpn_ipv4).network),
        "internal_gateway_ipv4": vpn_ipv4_host,
        "internal_ipv4_network": str(ipaddress.ip_interface(vpn_ipv4).network),
        "dns_resolver": dns_resolver,
        "web_public_url": web_public_url,
        "web_current_url": web_public_url,
        "adguard_url": adguard_url,
        "adguard_enabled": adguard_enabled,
        "nettest_url": "/nettest",
        "nettest_vpn_url": nettest_vpn_url,
        "nettest_vpn_url_available": True,
        "nettest_vpn_note": "",
        "route_mode": "amnezia-routes",
        "ipv6_mode": cfg.get("AWG_IPV6_MODE_EFFECTIVE") or cfg.get("AWG_IPV6_MODE") or "legacy",
        "preset": cfg.get("AWG_PRESET") or "",
    }


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


def reserve_nettest_session(auth, client_ip, test_id, now=None, force=False):
    if not test_id:
        return True
    now = time.time() if now is None else now
    key = nettest_rate_key(auth, client_ip)
    with NETTEST_LOCK:
        for item_key, item in list(NETTEST_ACTIVE.items()):
            if float(item.get("expires_at") or 0) <= now:
                if item.get("test_id") and item.get("test_id") != test_id:
                    audit_log(f"nettest: stale active session expired key={item_key} test_id={item.get('test_id')}")
                NETTEST_ACTIVE.pop(item_key, None)
        current = NETTEST_ACTIVE.get(key)
        if current and current.get("test_id") != test_id and float(current.get("expires_at") or 0) > now:
            if not force:
                return False
            audit_log(f"nettest: active test replaced for client key={key} old_test_id={current.get('test_id')} new_test_id={test_id}")
        NETTEST_ACTIVE[key] = {"test_id": test_id, "expires_at": now + NETTEST_ACTIVE_TTL}
        return True


def clear_nettest_session(auth, client_ip, test_id):
    if not test_id:
        return False
    key = nettest_rate_key(auth, client_ip)
    with NETTEST_LOCK:
        current = NETTEST_ACTIVE.get(key)
        if current and current.get("test_id") == test_id:
            NETTEST_ACTIVE.pop(key, None)
            return True
    return False


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


def awg_param_int(cfg, key):
    value = safe_int(cfg.get(key))
    return value if value is not None else None


def assess_amnezia_params(awg):
    notes_mobile = []
    notes_home = []
    mobile_status = "ok"
    home_status = "ok"
    preset = awg.get("preset") or "unknown"
    mtu = awg.get("mtu")
    keepalive = awg.get("persistent_keepalive")
    if preset == "mobile":
        notes_mobile.append("mobile preset selected")
        notes_home.append("mobile preset is stable for home networks but may reduce peak throughput")
    elif preset == "default":
        notes_mobile.append("default preset can work, but mobile networks often prefer conservative parameters")
        notes_home.append("default preset is suitable for stable home networks")
        mobile_status = "warn"
    else:
        notes_mobile.append("preset is unknown; check generated client profile if stalls persist")
        notes_home.append("preset is unknown; check generated client profile if stalls persist")
        mobile_status = home_status = "warn"
    if mtu == 1280:
        notes_mobile.append("MTU 1280 is conservative")
        notes_home.append("MTU 1280 prioritizes stability over maximum throughput")
    elif mtu and mtu > 1380:
        notes_mobile.append("MTU is high for mobile paths; watch for fragmentation stalls")
        mobile_status = "warn"
    elif mtu:
        notes_mobile.append(f"MTU {mtu} is in a moderate range")
    else:
        notes_mobile.append("MTU is not detected")
        mobile_status = "warn"
    if keepalive == 25:
        notes_mobile.append("PersistentKeepalive 25 helps NAT mappings")
    elif keepalive:
        notes_mobile.append(f"PersistentKeepalive {keepalive} differs from the usual mobile-friendly 25")
        mobile_status = "warn"
    else:
        notes_mobile.append("PersistentKeepalive is not detected")
        mobile_status = "warn"
    if awg.get("h_ranges_present"):
        notes_mobile.append("H ranges are present")
    else:
        notes_mobile.append("H ranges are not detected")
        mobile_status = "warn"
    if awg.get("ipv6_mode") in {"legacy", "disabled", ""}:
        notes_home.append("IPv6 is disabled or legacy; this is OK when clients use IPv4-only routing")
    else:
        notes_home.append(f"IPv6 mode: {awg.get('ipv6_mode')}")
    return {
        "mobile": {"status": mobile_status, "notes": notes_mobile[:6]},
        "home": {"status": home_status, "notes": notes_home[:6]},
    }


def nettest_context_payload():
    cfg = parse_config()
    info = server_info_payload()
    mtu = awg_param_int(cfg, "AWG_MTU")
    keepalive = 25 if mtu == 1280 else None
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
    preset = cfg.get("AWG_PRESET") or ("mobile" if mtu == 1280 or keepalive == 25 else "default")
    awg = {
        "preset": preset,
        "jc": awg_param_int(cfg, "AWG_Jc"),
        "jmin": awg_param_int(cfg, "AWG_Jmin"),
        "jmax": awg_param_int(cfg, "AWG_Jmax"),
        "s1": awg_param_int(cfg, "AWG_S1"),
        "s2": awg_param_int(cfg, "AWG_S2"),
        "s3": awg_param_int(cfg, "AWG_S3"),
        "s4": awg_param_int(cfg, "AWG_S4"),
        "h_ranges_present": all(cfg.get(key) for key in ("AWG_H1", "AWG_H2", "AWG_H3", "AWG_H4")),
        "mtu": mtu,
        "persistent_keepalive": keepalive,
        "route_mode": "amnezia-routes",
        "ipv6_mode": cfg.get("AWG_IPV6_MODE_EFFECTIVE") or cfg.get("AWG_IPV6_MODE") or "legacy",
        "p2p_ports_per_client": awg_param_int(cfg, "AWG_P2P_PORTS_PER_CLIENT") or 3,
    }
    return {
        "preset": awg["preset"],
        "mtu": awg["mtu"],
        "persistent_keepalive": awg["persistent_keepalive"],
        "route_mode": awg["route_mode"],
        "ipv6_mode": awg["ipv6_mode"],
        "ipv6_leak_protection": cfg.get("AWG_IPV6_LEAK_PROTECTION") or ("route" if awg["ipv6_mode"] not in {"legacy", "disabled", ""} else "warn"),
        "server_public_ipv4": info.get("public_ipv4", ""),
        "server_public_ipv6": info.get("public_ipv6", ""),
        "vpn_ipv6": info.get("vpn_ipv6", ""),
        "p2p_ports_per_client": awg["p2p_ports_per_client"],
        "awg": awg,
        "assessment": assess_amnezia_params(awg),
    }


def nettest_assessment(report):
    latency = report.get("latency") if isinstance(report.get("latency"), dict) else {}
    download_probe = report.get("download_probe") if isinstance(report.get("download_probe"), dict) else {}
    upload_probe = report.get("upload_probe") if isinstance(report.get("upload_probe"), dict) else {}
    timeline = report.get("timeline_summary") if isinstance(report.get("timeline_summary"), dict) else {}
    context = report.get("context") if isinstance(report.get("context"), dict) else {}
    leak_checks = report.get("leak_checks") if isinstance(report.get("leak_checks"), dict) else {}
    awg = context.get("awg") if isinstance(context.get("awg"), dict) else context
    loss = float(latency.get("loss_percent") or 0)
    jitter = float(latency.get("jitter_ms") or 0)
    stalls = int(latency.get("stall_events") or 0)
    longest_stall_ms = int(timeline.get("longest_stall_ms") or 0)
    max_consecutive = int(timeline.get("max_consecutive_timeouts") or 0)
    mtu = int(awg.get("mtu") or 0) if isinstance(awg, dict) else 0
    keepalive = int(awg.get("persistent_keepalive") or 0) if isinstance(awg, dict) else 0
    quality = "good"
    summary = "Parameters look OK"
    recommendations = []
    findings = []
    if loss > 15 or stalls >= 4 or longest_stall_ms >= 8000:
        quality = "critical"
        summary = "Severe repeated stalls detected"
    elif loss > 10 or stalls >= 3 or longest_stall_ms >= 5000:
        quality = "poor"
        summary = "Repeated timeout bursts detected"
    elif loss >= 2 or jitter >= 30 or stalls or longest_stall_ms >= 2000:
        quality = "warning"
        summary = "Burst loss or jitter detected"
    if stalls:
        findings.append(f"timeout bursts={stalls}, longest={round(longest_stall_ms / 1000, 1)}s")
    if max_consecutive:
        findings.append(f"max consecutive timeouts={max_consecutive}")
    if loss:
        findings.append(f"loss={round(loss, 1)}%")
    if jitter >= 30:
        findings.append(f"jitter={round(jitter, 1)}ms")
    if mtu and mtu <= 1280:
        findings.append("MTU is conservative")
    if keepalive == 25:
        findings.append("keepalive helps NAT mappings")
    if leak_checks.get("ipv6_leak_suspected"):
        quality = "critical" if quality in {"good", "warning"} else quality
        summary = "IPv6 leak suspected"
        findings.append("browser public IPv6 differs from VPN/server IPv6")
        recommendations.append("Enable IPv6 routing through VPN or IPv6 leak-block mode; on Android enable Always-on VPN and Block connections without VPN.")
    if leak_checks.get("webrtc_ipv6_risk"):
        findings.append("WebRTC IPv6 candidate observed")
        recommendations.append("Limit or disable WebRTC host candidates in the browser if browser leaks matter.")
    if download_probe.get("ok") is False and upload_probe.get("ok") is not False:
        recommendations.append("Download probe is weak while upload is OK; check client receive path and tunnel stability.")
    if upload_probe.get("ok") is False and download_probe.get("ok") is not False:
        recommendations.append("Upload probe is weak while download is OK; check client uplink and local network.")
    if loss > 0 or stalls:
        recommendations.append("Run ping to VPN server IP and 1.1.1.1 during the same stall window.")
    if stalls >= 2 and jitter < 30:
        recommendations.append("Pattern may indicate UDP path interference or unstable NAT; not conclusive.")
    elif stalls:
        recommendations.append("Pattern suggests general network instability; DPI cannot be proven from this test alone.")
    if not recommendations:
        recommendations.append("No obvious browser-side issue detected.")
    return {"quality": quality, "summary": summary, "findings": findings[:8], "recommendations": recommendations[:5]}


def sanitize_browser_report(value):
    return value if isinstance(value, dict) else {}


def sanitize_leak_checks(value, context=None):
    if not isinstance(value, dict):
        value = {}
    context = context if isinstance(context, dict) else {}
    server_public_ipv4 = str(context.get("server_public_ipv4") or "")[:80]
    server_public_ipv6 = str(context.get("server_public_ipv6") or "")[:120]
    vpn_ipv6 = str(context.get("vpn_ipv6") or "")[:120]
    browser_ipv4 = str(value.get("browser_public_ipv4") or "")[:80]
    browser_ipv6 = str(value.get("browser_public_ipv6") or "")[:120]
    webrtc_ipv6 = [str(item)[:120] for item in value.get("webrtc_ipv6_candidates", []) if isinstance(item, str)][:20]
    webrtc_private = [str(item)[:120] for item in value.get("webrtc_private_candidates", []) if isinstance(item, str)][:20]
    notes = [str(item)[:240] for item in value.get("notes", []) if isinstance(item, str)][:12]
    ipv6_mode = str(context.get("ipv6_mode") or "")
    expected_v6 = {item for item in (server_public_ipv6, vpn_ipv6) if item and item not in {"-", "IPv6 disabled"}}
    ipv6_leak = bool(browser_ipv6 and (not expected_v6 or browser_ipv6 not in expected_v6))
    webrtc_ipv6_risk = bool(webrtc_ipv6)
    if ipv6_leak:
        notes.append("Browser public IPv6 is visible and does not match the VPN/server IPv6 context.")
        if ipv6_mode in {"", "legacy", "disabled"}:
            notes.append("IPv4-only mode: AAAA disabled in AdGuard recommended to stop apps/browsers resolving non-VPN IPv6 addresses.")
    if webrtc_ipv6_risk or webrtc_private:
        notes.append("Disable WebRTC local IP exposure in browser (e.g. browser privacy/WebRTC settings) to stop ICE candidates revealing real addresses.")
    if ipv6_leak or webrtc_ipv6_risk:
        notes.append("Use VPN DNS for all queries (avoid system/public DNS fallbacks that can bypass the tunnel).")
    return {
        "browser_public_ipv4": browser_ipv4,
        "browser_public_ipv6": browser_ipv6,
        "server_public_ipv4": server_public_ipv4,
        "server_public_ipv6": server_public_ipv6,
        "vpn_ipv6": vpn_ipv6,
        "ipv6_leak_suspected": ipv6_leak,
        "webrtc_available": bool(value.get("webrtc_available")),
        "webrtc_ipv6_risk": webrtc_ipv6_risk,
        "webrtc_ipv6_candidates": webrtc_ipv6,
        "webrtc_private_candidates": webrtc_private,
        "notes": notes,
    }


def public_geo_for_ip(ip, allow_refresh=True):
    if not ip:
        return _empty_endpoint_info("", source="local")
    return lookup_endpoint_ip_info(ip, allow_refresh=allow_refresh)


def peer_endpoint_for_vpn_ip(vpn_ip):
    vpn_ip = (vpn_ip or "").strip()
    if not vpn_ip:
        return "", {}
    for cmd in (("awg", "show", "all", "dump"), ("wg", "show", "all", "dump")):
        try:
            result = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=3)
        except (OSError, subprocess.SubprocessError):
            continue
        if result.returncode != 0:
            continue
        for line in result.stdout.splitlines():
            parts = line.split("\t")
            if len(parts) < 9:
                continue
            endpoint = parts[3]
            allowed_ips = parts[4]
            if not endpoint or endpoint in {"(none)", "none"}:
                continue
            for item in allowed_ips.split(","):
                item = item.strip()
                if not item:
                    continue
                try:
                    network = ipaddress.ip_network(item, strict=False)
                    addr = ipaddress.ip_address(vpn_ip)
                except ValueError:
                    continue
                if addr in network:
                    endpoint_ip, endpoint_port = split_endpoint(endpoint)
                    return endpoint_ip, {
                        "endpoint": endpoint,
                        "endpoint_ip": endpoint_ip,
                        "endpoint_port": endpoint_port,
                        "latest_handshake": parts[5],
                        "transfer_rx": parts[6],
                        "transfer_tx": parts[7],
                        "persistent_keepalive": parts[8],
                    }
    return "", {}


def enriched_nettest_network_context(handler, client_ip, vpn_client_ip=""):
    public_ip = ""
    peer = {}
    if vpn_client_ip:
        public_ip, peer = peer_endpoint_for_vpn_ip(vpn_client_ip)
    if not public_ip and client_ip and not _is_private_endpoint_ip(client_ip):
        public_ip = client_ip
    geo = public_geo_for_ip(public_ip, allow_refresh=True) if public_ip else _empty_endpoint_info("", source="local")
    return {
        "vpn_client_ip": vpn_client_ip or "",
        "public_ip": public_ip or "",
        "geo": {
            "country": geo.get("country", ""),
            "country_code": geo.get("country_code", ""),
            "flag": geo.get("flag", ""),
            "region": geo.get("region", ""),
            "city": geo.get("city", ""),
            "provider": geo.get("provider") or geo.get("org") or "",
            "provider_display": geo.get("provider_display", ""),
            "isp": geo.get("provider") or "",
            "asn": geo.get("asn", ""),
            "asn_id": geo.get("asn_id", ""),
            "org": geo.get("org", ""),
            "sources": geo.get("sources", []),
            "source_details": geo.get("source_details", {}),
            "confidence": geo.get("confidence", "low"),
            "source": geo.get("source", ""),
            "updated_at": geo.get("updated_at", ""),
        },
        "peer": peer,
    }


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
    browser = sanitize_browser_report(body.get("browser_connection"))
    latency = body.get("latency") if isinstance(body.get("latency"), dict) else {}
    download_probe = body.get("download_probe") if isinstance(body.get("download_probe"), dict) else {}
    upload_probe = body.get("upload_probe") if isinstance(body.get("upload_probe"), dict) else {}
    stall_events = body.get("stall_events") if isinstance(body.get("stall_events"), list) else []
    timeline_summary = body.get("timeline_summary") if isinstance(body.get("timeline_summary"), dict) else {}
    duration_seconds = int(body.get("duration_seconds") or 0)
    probe_interval_ms = int(body.get("probe_interval_ms") or 1000)
    started_at = str(body.get("started_at") or created_at)[:30]
    finished_at = str(body.get("finished_at") or created_at)[:30]
    context_payload = nettest_context_payload()
    leak_checks = sanitize_leak_checks(body.get("leak_checks"), context_payload)
    network_context = enriched_nettest_network_context(handler, client_ip)
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
        "vpn_client_ip": network_context.get("vpn_client_ip", ""),
        "public_ip": network_context.get("public_ip", client_ip),
        "geo": network_context.get("geo", {}),
        "peer": network_context.get("peer", {}),
        "socket_remote_ip": client_ctx.get("socket_remote_ip"),
        "trusted_proxy_used": bool(client_ctx.get("trusted_proxy_used")),
        "user_agent": str(body.get("user_agent") or handler.headers.get("User-Agent", ""))[:500],
        "browser": browser,
        "browser_connection": browser,
        "duration_seconds": duration_seconds,
        "probe_interval_ms": probe_interval_ms,
        "started_at": started_at,
        "finished_at": finished_at,
        "latency": latency,
        "download_probe": download_probe,
        "upload_probe": upload_probe,
        "stall_events": stall_events[:100],
        "timeline_summary": timeline_summary,
        "leak_checks": leak_checks,
        "context": context_payload,
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
            "vpn_client_ip": data.get("vpn_client_ip"),
            "public_ip": data.get("public_ip"),
            "geo": data.get("geo", {}),
            "duration_seconds": data.get("duration_seconds"),
            "timeline_summary": data.get("timeline_summary", {}),
            "stall_events": data.get("stall_events", [])[:5],
            "browser": data.get("browser") or data.get("browser_connection", {}),
            "user_agent": data.get("user_agent"),
            "context": data.get("context", {}),
            "assessment": data.get("assessment", {}),
            "latency": data.get("latency", {}),
            "download_probe": data.get("download_probe", {}),
            "upload_probe": data.get("upload_probe", {}),
            "leak_checks": data.get("leak_checks", {}),
        })
    return rows


def delete_nettest_report(filename):
    """Delete a single nettest report file by name. Returns True if a file was
    removed, False if it did not exist. Raises ValueError on an invalid name."""
    name = str(filename or "")
    if not re.match(r"^nettest_[A-Za-z0-9_.-]+\.json$", name):
        raise ValueError("invalid report filename")
    path = NETTEST_REPORT_DIR / name
    if not path.is_file():
        return False
    path.unlink()
    return True


def delete_all_nettest_reports():
    """Delete every saved nettest report. Returns the number of files removed."""
    count = 0
    if not NETTEST_REPORT_DIR.exists():
        return count
    for path in NETTEST_REPORT_DIR.glob("nettest_*.json"):
        try:
            path.unlink()
            count += 1
        except OSError:
            continue
    return count


def is_vpn_internal_nettest(handler):
    """Return True only when request arrives via the VPN-only nginx listener."""
    socket_ip = handler.client_address[0] if getattr(handler, "client_address", None) else ""
    if socket_ip not in ("127.0.0.1", "::1"):
        return False
    return handler.headers.get("X-AWG-Internal-Nettest") == "1"


def vpn_client_ip_from_handler(handler):
    """Return VPN client IP from X-Real-IP (set by nginx from $remote_addr)."""
    raw = (handler.headers.get("X-Real-IP") or "").strip()
    try:
        return str(ipaddress.ip_address(raw))
    except ValueError:
        return ""


def _vpn_ip_safe(ip):
    """Convert IP to filename-safe string: 10.9.9.5 -> 10-9-9-5."""
    return (ip or "").replace(".", "-").replace(":", "-") or "unknown"


def save_nettest_report_vpn(handler, body):
    """Save a network test report for VPN-only (unauthenticated) mode."""
    network_type = clean_network_type(body.get("network_type"))
    test_id = clean_nettest_id(body.get("test_id", ""))
    vpn_ip = vpn_client_ip_from_handler(handler)
    client_ip = vpn_ip or "unknown"
    rate_stub = {"role": "vpn_anon", "hash": hashlib.sha256(client_ip.encode("utf-8")).hexdigest()[:8]}
    if not check_nettest_report_rate(rate_stub, client_ip):
        raise ValueError("nettest report rate limited")
    created_at = utc_now_iso()
    stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    NETTEST_REPORT_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(NETTEST_REPORT_DIR, 0o700)
    browser = sanitize_browser_report(body.get("browser_connection"))
    latency = body.get("latency") if isinstance(body.get("latency"), dict) else {}
    download_probe = body.get("download_probe") if isinstance(body.get("download_probe"), dict) else {}
    upload_probe = body.get("upload_probe") if isinstance(body.get("upload_probe"), dict) else {}
    stall_events = body.get("stall_events") if isinstance(body.get("stall_events"), list) else []
    timeline_summary = body.get("timeline_summary") if isinstance(body.get("timeline_summary"), dict) else {}
    duration_seconds = int(body.get("duration_seconds") or 0)
    probe_interval_ms = int(body.get("probe_interval_ms") or 1000)
    started_at = str(body.get("started_at") or created_at)[:30]
    finished_at = str(body.get("finished_at") or created_at)[:30]
    context_payload = nettest_context_payload()
    leak_checks = sanitize_leak_checks(body.get("leak_checks"), context_payload)
    network_context = enriched_nettest_network_context(handler, client_ip, vpn_client_ip=client_ip)
    report = {
        "version": 2,
        "created_at": created_at,
        "test_id": test_id,
        "network_type": network_type,
        "comment": clean_report_comment(body.get("comment", "")),
        "vpn_client_ip": client_ip,
        "client_ip": client_ip,
        "public_ip": network_context.get("public_ip", ""),
        "geo": network_context.get("geo", {}),
        "peer": network_context.get("peer", {}),
        "socket_remote_ip": handler.client_address[0] if getattr(handler, "client_address", None) else "",
        "trusted_proxy_used": True,
        "vpn_only_mode": True,
        "user_agent": str(body.get("user_agent") or handler.headers.get("User-Agent", ""))[:500],
        "browser": browser,
        "browser_connection": browser,
        "duration_seconds": duration_seconds,
        "probe_interval_ms": probe_interval_ms,
        "started_at": started_at,
        "finished_at": finished_at,
        "latency": latency,
        "download_probe": download_probe,
        "upload_probe": upload_probe,
        "stall_events": stall_events[:100],
        "timeline_summary": timeline_summary,
        "leak_checks": leak_checks,
        "context": context_payload,
    }
    report["assessment"] = nettest_assessment(report)
    ip_safe = _vpn_ip_safe(client_ip)
    filename = f"nettest_{network_type}_{stamp}_{ip_safe}.json"
    path = NETTEST_REPORT_DIR / filename
    tmp = NETTEST_REPORT_DIR / f".{filename}.tmp.{os.getpid()}"
    tmp.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    os.chmod(path, 0o600)
    clear_nettest_session(rate_stub, client_ip, test_id)
    audit_log(f"Saved VPN-only network test report type={network_type} vpn_client_ip={client_ip}")
    return {"ok": True, "filename": filename, "report": report}


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
        return data if isinstance(data, dict) else {}
    except Exception:
        _backup_corrupt_cache()
        return {}


def _backup_corrupt_cache():
    try:
        stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
        bak = IP_INFO_CACHE_FILE.with_name(f"{IP_INFO_CACHE_FILE.name}.corrupt.{stamp}")
        if IP_INFO_CACHE_FILE.exists():
            IP_INFO_CACHE_FILE.rename(bak)
            os.chmod(bak, 0o600)
    except Exception:
        pass


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


def _safe_float(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


# Small alias map for common Russian ASN/provider names -> human-friendly display
PROVIDER_ALIASES = {
    "BEE": "Beeline",
    "BEELINE": "Beeline",
    "VIMPELCOM": "Beeline",
    "MEGAFON": "Megafon",
    "MEGAFON-AS": "Megafon",
    "MTS": "MTS",
    "MGTS": "MGTS",
    "ROSTELECOM": "Rostelecom",
    "SINP-MSU": "SINP-MSU",
    "MCC": "MCC",
}

_PROVIDER_AS_SUFFIX_RE = re.compile(r"[-_ ]AS\d*$", re.IGNORECASE)
_PROVIDER_STANDALONE_AS_RE = re.compile(r"^AS\d+$", re.IGNORECASE)


def clean_provider_display(provider="", org="", asn=""):
    """Produce a human-friendly provider/org name for compact UI display.

    Strips technical "-AS"/"-AS1234" suffixes and applies a small alias
    map for common Russian ISPs (e.g. "BEE-AS" -> "Beeline"). Falls back
    to the cleaned source string when no alias is known.
    """
    raw = str(provider or "").strip() or str(org or "").strip()
    if not raw:
        return ""
    if _PROVIDER_STANDALONE_AS_RE.match(raw):
        return ""
    cleaned = raw
    while True:
        m = _PROVIDER_AS_SUFFIX_RE.search(cleaned)
        if not m:
            break
        cleaned = cleaned[:m.start()].rstrip(" -_")
    if not cleaned:
        cleaned = raw
    return PROVIDER_ALIASES.get(cleaned.upper(), cleaned)


def _empty_endpoint_info(ip, source="local", provider=""):
    return {
        "ip": ip,
        "country": "",
        "country_code": "",
        "flag": "",
        "region": "",
        "city": "",
        "asn": "",
        "asn_id": "",
        "org": "",
        "provider": provider,
        "sources": [],
        "confidence": "low",
        "source": source,
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }


def load_geoip_providers_config():
    """Load providers config from runtime file. Returns empty providers dict if missing."""
    try:
        if GEOIP_PROVIDERS_FILE.exists():
            data = json.loads(GEOIP_PROVIDERS_FILE.read_text(encoding="utf-8"))
            if isinstance(data, dict) and isinstance(data.get("providers"), dict):
                return data
    except Exception:
        pass
    return {"providers": {}}


def _geoip_provider_cfg(name):
    return load_geoip_providers_config().get("providers", {}).get(name, {})


def _clean_geoip_provider_entry(entry):
    """Whitelist-filter a single provider config entry to known fields/types."""
    if not isinstance(entry, dict):
        return {}
    clean = {}
    for key, value in entry.items():
        expected = GEOIP_PROVIDER_FIELDS.get(key)
        if expected is None:
            continue
        if expected is bool:
            clean[key] = bool(value)
        elif expected is str and isinstance(value, str):
            clean[key] = value.strip()[:500]
    return clean


def _clean_geoip_database_entry(entry):
    """Whitelist-filter a single database override entry (URL only)."""
    if not isinstance(entry, dict):
        return {}
    clean = {}
    url = entry.get("url")
    if isinstance(url, str) and url.strip():
        clean["url"] = url.strip()[:500]
    return clean


def geoip_providers_config_for_admin():
    """Return providers+databases config for the admin UI, with tokens masked."""
    cfg = load_geoip_providers_config()
    providers = {}
    for name, pcfg in (cfg.get("providers") or {}).items():
        if name not in GEOIP_PROVIDER_NAMES:
            continue
        entry = _clean_geoip_provider_entry(pcfg)
        if "token" in entry:
            entry["has_token"] = bool(entry["token"])
            entry["token"] = GEOIP_TOKEN_MASK if entry["token"] else ""
        providers[name] = entry
    databases = {}
    for name, dcfg in (cfg.get("databases") or {}).items():
        if name not in GEOIP_DATABASE_NAMES:
            continue
        databases[name] = _clean_geoip_database_entry(dcfg)
    return {"providers": providers, "databases": databases}


def write_geoip_providers_config(new_data):
    """Validate and atomically write geoip_providers.json. Tokens equal to
    GEOIP_TOKEN_MASK are treated as "keep existing value" so the masked
    placeholder returned by GET never overwrites a real token."""
    if not isinstance(new_data, dict):
        raise ValueError("invalid geoip providers payload")
    with GEOIP_PROVIDERS_LOCK:
        current = load_geoip_providers_config()
        cur_providers = current.get("providers") or {}
        new_providers = {}
        for name, pcfg in (new_data.get("providers") or {}).items():
            if name not in GEOIP_PROVIDER_NAMES:
                continue
            entry = _clean_geoip_provider_entry(pcfg)
            if entry.get("token") == GEOIP_TOKEN_MASK:
                entry["token"] = (cur_providers.get(name) or {}).get("token", "")
            new_providers[name] = entry
        new_databases = {}
        databases_in = new_data.get("databases")
        if isinstance(databases_in, dict):
            for name, dcfg in databases_in.items():
                if name not in GEOIP_DATABASE_NAMES:
                    continue
                cleaned = _clean_geoip_database_entry(dcfg)
                if cleaned:
                    new_databases[name] = cleaned
        else:
            new_databases = {
                name: dcfg for name, dcfg in (current.get("databases") or {}).items()
                if name in GEOIP_DATABASE_NAMES
            }
        out = {"providers": new_providers, "databases": new_databases}
        WEB_DIR.mkdir(parents=True, exist_ok=True)
        tmp = GEOIP_PROVIDERS_FILE.with_name(f"{GEOIP_PROVIDERS_FILE.name}.tmp.{os.getpid()}")
        tmp.write_text(json.dumps(out, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.chmod(tmp, 0o600)
        os.replace(tmp, GEOIP_PROVIDERS_FILE)
        os.chmod(GEOIP_PROVIDERS_FILE, 0o600)
        return out


def geoip_test_provider(name):
    """Run a live test lookup for a single configured provider against
    GEOIP_TEST_IP. Returns {"ok": True, "result": {...}} or {"ok": False, "error": ...}."""
    fetchers = {
        "2ip": _fetch_2ip_provider,
        "2ip_whois": _fetch_2ip_whois_provider,
        "ipinfo": _fetch_ipinfo_provider,
        "dbip": _fetch_dbip_provider,
        "dbip_mmdb": _fetch_dbip_mmdb_provider,
        "maxmind": _fetch_mmdb_provider,
        "ip-api": _fetch_ipapi_provider,
    }
    fetcher = fetchers.get(name)
    if fetcher is None:
        return {"ok": False, "error": "unknown provider"}
    try:
        result = fetcher(GEOIP_TEST_IP)
    except Exception as exc:
        return {"ok": False, "error": str(exc)}
    if result is None:
        return {"ok": False, "error": "no result (disabled, missing token, or lookup failed)"}
    return {"ok": True, "result": result}


def geoip_databases_status():
    """Return on-disk MMDB file status (size/mtime/sha256/source) plus the
    weekly auto-update timer status."""
    geoip_dir = AWG_DIR / "geoip"
    versions_file = geoip_dir / "geoip_db_versions.json"
    try:
        versions = json.loads(versions_file.read_text(encoding="utf-8"))
        if not isinstance(versions, dict):
            versions = {}
    except (OSError, ValueError):
        versions = {}
    databases = {}
    for name, filename in GEOIP_DB_FILES.items():
        entry = dict(versions.get(name, {}))
        path = geoip_dir / filename
        if path.exists():
            st = path.stat()
            entry["present"] = True
            entry["size_bytes"] = st.st_size
            entry["mtime"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(st.st_mtime))
        else:
            entry["present"] = False
        databases[name] = entry
    return {"databases": databases, "auto_update": geoip_auto_update_timer_status()}


def geoip_auto_update_timer_status():
    """Query systemd directly for the awg-geoip-update.timer state."""
    def _systemctl(args):
        try:
            p = subprocess.run(
                ["systemctl", *args, "awg-geoip-update.timer"],
                capture_output=True, text=True, timeout=10,
            )
            return p.stdout.strip()
        except Exception:
            return ""
    enabled_state = _systemctl(["is-enabled"]) or "unknown"
    active_state = _systemctl(["is-active"]) or "unknown"
    return {
        "enabled": enabled_state == "enabled",
        "active": active_state == "active",
        "enabled_state": enabled_state,
        "active_state": active_state,
    }


def _fetch_2ip_provider(ip):
    cfg = _geoip_provider_cfg("2ip")
    if not cfg.get("enabled"):
        return None
    token = (cfg.get("token") or os.environ.get("AWG_GEOIP_2IP_TOKEN", "")).strip()
    if not token:
        return None
    base = (cfg.get("base_url") or "https://api.2ip.io").rstrip("/")
    url = f"{base}/{quote(ip)}?token={quote(token)}"
    try:
        with urlopen(url, timeout=IP_INFO_LOOKUP_TIMEOUT) as resp:
            payload = resp.read(32768)
    except Exception:
        return None
    try:
        data = json.loads(payload.decode("utf-8"))
    except Exception:
        return None
    # Empty {} response means no data; fall through to next provider
    if not isinstance(data, dict) or not data.get("ip"):
        return None
    asn_data = data.get("asn") or {}
    asn_id = str(asn_data.get("id") or "").strip()
    asn = f"AS{asn_id}" if asn_id else ""
    provider = str(asn_data.get("name") or "").strip()
    country_code = str(data.get("code") or "").upper().strip()
    return {
        "ip": ip,
        "country": str(data.get("country") or "").strip(),
        "country_code": country_code,
        "flag": str(data.get("emoji") or country_code_to_flag(country_code)).strip(),
        "region": str(data.get("region") or "").strip(),
        "city": str(data.get("city") or "").strip(),
        "lat": _safe_float(data.get("lat")),
        "lon": _safe_float(data.get("lon")),
        "timezone": str(data.get("timezone") or "").strip(),
        "asn": asn,
        "asn_id": asn_id,
        "provider": provider,
        "org": provider,
        "hosting": bool(asn_data.get("hosting")),
        "_source_name": "2ip",
    }


def _fetch_2ip_whois_provider(ip):
    """Optional WHOIS enrichment via 2ip.io. Provides org/network details, no city."""
    cfg = _geoip_provider_cfg("2ip_whois")
    if not cfg.get("enabled"):
        return None
    token = (cfg.get("token") or _geoip_provider_cfg("2ip").get("token")
             or os.environ.get("AWG_GEOIP_2IP_TOKEN", "")).strip()
    if not token:
        return None
    base = (cfg.get("base_url") or "https://api.2ip.io/whois").rstrip("/")
    url = f"{base}/{quote(ip)}?token={quote(token)}"
    try:
        with urlopen(url, timeout=IP_INFO_LOOKUP_TIMEOUT) as resp:
            payload = resp.read(32768)
    except Exception:
        return None
    try:
        data = json.loads(payload.decode("utf-8"))
    except Exception:
        return None
    if not isinstance(data, dict):
        return None
    whois = data.get("whois") or {}
    network = whois.get("network") or {}
    route = whois.get("route") or {}
    country_code = str(network.get("country") or "").upper().strip()
    asn = str(route.get("asn") or "").strip().upper()
    if asn and not asn.startswith("AS"):
        asn = f"AS{asn}"
    asn_id = asn[2:] if asn.startswith("AS") else ""
    provider = str(network.get("name") or "").strip()
    org = str(network.get("description") or "").strip()
    if not provider and not org and not asn:
        return None
    return {
        "ip": ip,
        "country_code": country_code,
        "flag": country_code_to_flag(country_code),
        "region": "",
        "city": "",
        "asn": asn,
        "asn_id": asn_id,
        "provider": provider,
        "org": org,
        "network": str(network.get("range") or "").strip(),
        "route": str(route.get("range") or "").strip(),
        "_source_name": "2ip_whois",
    }


def _fetch_ipinfo_provider(ip):
    cfg = _geoip_provider_cfg("ipinfo")
    if not cfg.get("enabled"):
        return None
    token = (cfg.get("token") or os.environ.get("AWG_GEOIP_IPINFO_TOKEN", "")).strip()
    if not token:
        return None
    url = f"https://ipinfo.io/{ip}?token={token}"
    try:
        with urlopen(url, timeout=IP_INFO_LOOKUP_TIMEOUT) as resp:
            payload = resp.read(32768)
    except Exception:
        return None
    try:
        data = json.loads(payload.decode("utf-8"))
    except Exception:
        return None
    if not isinstance(data, dict) or not data.get("ip"):
        return None
    country_code = str(data.get("country") or "").upper().strip()
    org_raw = str(data.get("org") or "").strip()
    org_parts = org_raw.split(" ", 1)
    asn = org_parts[0] if org_parts and org_parts[0].startswith("AS") else ""
    asn_id = asn[2:] if asn.startswith("AS") and asn[2:].isdigit() else ""
    org_name = org_parts[1] if len(org_parts) > 1 else org_raw
    loc = str(data.get("loc") or "").split(",")
    lat = _safe_float(loc[0]) if len(loc) >= 1 else None
    lon = _safe_float(loc[1]) if len(loc) >= 2 else None
    return {
        "ip": ip,
        "country": "",
        "country_code": country_code,
        "flag": country_code_to_flag(country_code),
        "region": str(data.get("region") or "").strip(),
        "city": str(data.get("city") or "").strip(),
        "lat": lat,
        "lon": lon,
        "timezone": str(data.get("timezone") or "").strip(),
        "asn": asn,
        "asn_id": asn_id,
        "provider": org_name,
        "org": org_name,
        "hosting": bool(data.get("bogon")),
        "_source_name": "ipinfo",
    }


def _read_mmdb_city(geoip2_mod, city_path, asn_path, ip, source_name):
    """Shared MMDB reader for city + optional ASN. Returns dict or None."""
    result = {}
    try:
        with geoip2_mod.Reader(city_path) as reader:
            r = reader.city(ip)
            country_code = str(r.country.iso_code or "").upper()
            subdiv = r.subdivisions.most_specific.name if r.subdivisions else ""
            result.update({
                "ip": ip,
                "country": str(r.country.name or "").strip(),
                "country_code": country_code,
                "flag": country_code_to_flag(country_code),
                "region": str(subdiv or "").strip(),
                "city": str(r.city.name or "").strip(),
                "lat": float(r.location.latitude) if r.location.latitude is not None else None,
                "lon": float(r.location.longitude) if r.location.longitude is not None else None,
                "timezone": str(r.location.time_zone or "").strip(),
                "_source_name": source_name,
            })
    except Exception:
        return None
    if asn_path and Path(asn_path).exists():
        try:
            with geoip2_mod.Reader(asn_path) as reader:
                r = reader.asn(ip)
                asn_id = str(r.autonomous_system_number or "")
                asn = f"AS{asn_id}" if asn_id else ""
                org = str(r.autonomous_system_organization or "").strip()
                result.update({"asn": asn, "asn_id": asn_id, "provider": org, "org": org})
        except Exception:
            pass
    return result or None


def _fetch_mmdb_provider(ip):
    cfg = _geoip_provider_cfg("maxmind")
    if not cfg.get("enabled"):
        return None
    try:
        import geoip2.database as _geoip2  # type: ignore
    except ImportError:
        return None
    city_path = cfg.get("city_mmdb_path") or cfg.get("mmdb_path") or str(AWG_DIR / "geoip/GeoLite2-City.mmdb")
    asn_path = cfg.get("asn_mmdb_path") or str(AWG_DIR / "geoip/GeoLite2-ASN.mmdb")
    return _read_mmdb_city(_geoip2, city_path, asn_path, ip, "maxmind")


def _fetch_dbip_mmdb_provider(ip):
    cfg = _geoip_provider_cfg("dbip_mmdb")
    if not cfg.get("enabled"):
        return None
    try:
        import geoip2.database as _geoip2  # type: ignore
    except ImportError:
        return None
    mmdb_path = cfg.get("mmdb_path") or str(AWG_DIR / "geoip/dbip-city-lite.mmdb")
    if not Path(mmdb_path).exists():
        return None
    return _read_mmdb_city(_geoip2, mmdb_path, None, ip, "dbip_mmdb")


def _fetch_dbip_provider(ip):
    cfg = _geoip_provider_cfg("dbip")
    if not cfg.get("enabled"):
        return None
    token = (cfg.get("token") or os.environ.get("AWG_GEOIP_DBIP_TOKEN", "")).strip()
    base_url = (cfg.get("base_url") or "https://api.db-ip.com/v2").rstrip("/")
    if token:
        url = f"{base_url}/{token}/{ip}"
    elif cfg.get("allow_free"):
        url = f"{base_url}/free/{ip}"
    else:
        return None
    try:
        with urlopen(url, timeout=IP_INFO_LOOKUP_TIMEOUT) as resp:
            payload = resp.read(32768)
    except Exception:
        return None
    try:
        data = json.loads(payload.decode("utf-8"))
    except Exception:
        return None
    if not isinstance(data, dict) or not data.get("ipAddress"):
        return None
    country_code = str(data.get("countryCode") or "").upper().strip()
    asn_num = data.get("asNumber")
    asn_id = str(asn_num) if asn_num else ""
    asn = f"AS{asn_id}" if asn_id else ""
    org = str(data.get("organization") or data.get("isp") or "").strip()
    return {
        "ip": ip,
        "country": str(data.get("countryName") or "").strip(),
        "country_code": country_code,
        "flag": country_code_to_flag(country_code),
        "region": str(data.get("stateProv") or "").strip(),
        "city": str(data.get("city") or "").strip(),
        "lat": _safe_float(data.get("latitude")),
        "lon": _safe_float(data.get("longitude")),
        "timezone": str(data.get("timeZone") or data.get("timezone") or "").strip(),
        "asn": asn,
        "asn_id": asn_id,
        "provider": org,
        "org": org,
        "hosting": bool(data.get("isHostingProvider")),
        "_source_name": "dbip",
    }


def _build_source_detail(r):
    """Sanitized per-source detail for source_details (no tokens/URLs/lat/lon)."""
    provider = str(r.get("provider") or "").strip()
    org = str(r.get("org") or "").strip()
    asn = str(r.get("asn") or "").strip()
    detail = {
        "city": str(r.get("city") or "").strip(),
        "region": str(r.get("region") or "").strip(),
        "country_code": str(r.get("country_code") or "").upper().strip(),
        "provider": provider,
        "provider_display": clean_provider_display(provider, org, asn),
        "org": org,
        "asn": asn,
    }
    network = str(r.get("network") or "").strip()
    route = str(r.get("route") or "").strip()
    if network:
        detail["network"] = network
    if route:
        detail["route"] = route
    return detail


def _geoip_consensus(results):
    """Merge provider results into consensus dict with confidence score."""
    if not results:
        return None, "low", []
    source_names = [r.get("_source_name", "unknown") for r in results]
    if len(results) == 1:
        merged = {k: v for k, v in results[0].items() if not k.startswith("_")}
        src = results[0].get("_source_name", "unknown")
        _free_only = {"ip-api"}
        conf = "low" if src in _free_only else "medium"
        return merged, conf, source_names

    merged = {}
    for field in ("country", "country_code", "region", "city", "asn", "asn_id", "provider", "org", "timezone", "flag"):
        vals = [str(r.get(field) or "").strip() for r in results if str(r.get(field) or "").strip()]
        if not vals:
            merged[field] = ""
            continue
        counts = {}
        for v in vals:
            k = v.lower()
            if k not in counts:
                counts[k] = {"count": 0, "val": v}
            counts[k]["count"] += 1
        best = max(counts.values(), key=lambda x: x["count"])
        merged[field] = best["val"]
    for field in ("lat", "lon"):
        for r in results:
            if r.get(field) is not None:
                merged[field] = r[field]
                break
    for r in results:
        if r.get("hosting") is not None:
            merged["hosting"] = r["hosting"]
            break

    cc_vals = [str(r.get("country_code") or "").upper() for r in results if r.get("country_code")]
    city_vals = [str(r.get("city") or "").strip().lower() for r in results if r.get("city")]
    cc_match = len(set(cc_vals)) <= 1 and len(cc_vals) >= 2
    city_match = len(set(city_vals)) <= 1 and len(city_vals) >= 2

    if cc_match and city_match:
        confidence = "high"
    elif cc_match:
        confidence = "medium"
    else:
        confidence = "low"
    return merged, confidence, source_names


def lookup_ip_enriched(ip, purpose="endpoint", multi_source=False, force_refresh=False, want_whois=False):
    """Multi-provider GeoIP: cache → MMDBs → external provider(s) → consensus.

    multi_source=True collects from all known external providers (2ip, dbip,
    ip-api, ipinfo) for richer per-source detail; disabled/unconfigured
    providers (e.g. ipinfo without a token) return None immediately and cost
    nothing. Normal lookup uses max 1 external call. force_refresh=True
    bypasses a fresh cache hit (used for controlled endpoint enrichment).
    want_whois=True additionally fetches 2ip WHOIS details (if enabled) to
    enrich source_details with org/network info; it never affects the
    primary consensus/compact source.
    """
    ip = (ip or "").strip()
    if not ip:
        return _empty_endpoint_info(ip, source="local")
    if _is_private_endpoint_ip(ip):
        return _empty_endpoint_info(ip, source="local", provider="private")

    now = time.time()
    cached_entry = None
    with IP_INFO_CACHE_LOCK:
        cache = load_ip_info_cache()
        cached = cache.get(ip)
        if isinstance(cached, dict):
            cached_entry = cached
            ts = float(cached.get("_cache_ts") or 0)
            status = cached.get("status", "ok")
            ttl = (IP_INFO_NEGATIVE_TTL if status == "negative"
                   else IP_INFO_ERROR_CACHE_TTL if status == "error"
                   else IP_INFO_CACHE_TTL)
            if not force_refresh and ts and now - ts < ttl:
                info = dict(cached.get("info") or _empty_endpoint_info(ip, source="cache"))
                info["source"] = "cache"
                return info

    results = []
    # Local MMDBs first (no network, unlimited, fast)
    for mmdb_fetch in (_fetch_mmdb_provider, _fetch_dbip_mmdb_provider):
        r = mmdb_fetch(ip)
        if r:
            results.append(r)

    if multi_source:
        # Forced refresh: collect from every external provider for richer
        # detail. Disabled/unconfigured providers (e.g. ipinfo without a
        # token) return None immediately, so this stays cheap.
        _ext_order = (_fetch_2ip_provider, _fetch_dbip_provider, _fetch_ipapi_provider, _fetch_ipinfo_provider)
        for fetcher in _ext_order:
            r = fetcher(ip)
            if r:
                results.append(r)
    else:
        # Normal lookup: one external call only
        ext = (
            _fetch_2ip_provider(ip)
            or _fetch_dbip_provider(ip)
            or _fetch_ipinfo_provider(ip)
            or _fetch_ipapi_provider(ip)
        )
        if ext:
            results.append(ext)

    whois_result = None
    if results and want_whois:
        whois_result = _fetch_2ip_whois_provider(ip)

    if not results:
        info = _empty_endpoint_info(ip, source="provider")
        with IP_INFO_CACHE_LOCK:
            cache = load_ip_info_cache()
            cache[ip] = {"status": "negative", "_cache_ts": now, "info": info}
            try:
                write_ip_info_cache(cache)
            except Exception:
                pass
        return info

    merged, confidence, source_names = _geoip_consensus(results)
    flag = str(merged.get("flag") or "").strip()
    if not flag and merged.get("country_code"):
        flag = country_code_to_flag(str(merged["country_code"]))

    # Compact sanitized per-source details (no tokens, URLs, lat/lon)
    source_details = {}
    for r in results:
        src = r.get("_source_name", "unknown")
        source_details[src] = _build_source_detail(r)
    if whois_result:
        source_details["2ip_whois"] = _build_source_detail(whois_result)

    # Preserve previously cached per-source details for sources not refreshed
    # this round (e.g. WHOIS fetched on an earlier manual refresh).
    if cached_entry:
        old_details = (cached_entry.get("info") or {}).get("source_details")
        if isinstance(old_details, dict):
            for src, detail in old_details.items():
                source_details.setdefault(src, detail)

    provider = str(merged.get("provider") or "").strip()
    org = str(merged.get("org") or "").strip()
    asn = str(merged.get("asn") or "").strip()

    info = {
        "ip": ip,
        "country": str(merged.get("country") or "").strip(),
        "country_code": str(merged.get("country_code") or "").upper().strip(),
        "flag": flag,
        "region": str(merged.get("region") or "").strip(),
        "city": str(merged.get("city") or "").strip(),
        "asn": asn,
        "asn_id": str(merged.get("asn_id") or "").strip(),
        "provider": provider,
        "provider_display": clean_provider_display(provider, org, asn),
        "org": org,
        "timezone": str(merged.get("timezone") or "").strip(),
        "hosting": merged.get("hosting"),
        "sources": source_names,
        "confidence": confidence,
        "source_details": source_details,
        "multi_source": bool(multi_source),
        "source": "provider",
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    if merged.get("lat") is not None:
        info["lat"] = merged["lat"]
    if merged.get("lon") is not None:
        info["lon"] = merged["lon"]

    with IP_INFO_CACHE_LOCK:
        cache = load_ip_info_cache()
        cache[ip] = {"status": "ok", "_cache_ts": now, "info": info}
        try:
            write_ip_info_cache(cache)
        except Exception:
            pass
    return info


def geoip_cache_stats():
    with IP_INFO_CACHE_LOCK:
        cache = load_ip_info_cache()
    return len(cache)


def geoip_providers_status():
    """Return provider status without exposing tokens."""
    cfg = load_geoip_providers_config().get("providers", {})
    providers = {}
    for name, pcfg in (cfg or {}).items():
        entry = {"enabled": bool(pcfg.get("enabled"))}
        if "token" in pcfg:
            entry["has_token"] = bool(pcfg.get("token"))
        if name == "dbip":
            entry["allow_free"] = bool(pcfg.get("allow_free"))
            if "token" not in pcfg:
                entry["has_token"] = False
        if name in ("maxmind", "dbip_mmdb"):
            mmdb = (pcfg.get("city_mmdb_path") or pcfg.get("mmdb_path") or
                    str(AWG_DIR / ("geoip/GeoLite2-City.mmdb" if name == "maxmind" else "geoip/dbip-city-lite.mmdb")))
            entry["mmdb_present"] = Path(mmdb).exists()
        if name == "2ip_whois":
            entry["only_on_refresh"] = bool(pcfg.get("only_on_refresh", True))
            entry["has_token"] = bool(pcfg.get("token")) or bool((cfg.get("2ip") or {}).get("token"))
        providers[name] = entry
    if "ip-api" not in providers:
        providers["ip-api"] = {"enabled": True}
    if "2ip_whois" not in providers:
        providers["2ip_whois"] = {
            "enabled": False,
            "has_token": bool((cfg.get("2ip") or {}).get("token")),
            "only_on_refresh": True,
        }
    return {"cache_entries": geoip_cache_stats(), "providers": providers}


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


def _fetch_ipapi_provider(ip):
    cfg = _geoip_provider_cfg("ip-api")
    if cfg.get("enabled") is False:
        return None
    url = f"http://ip-api.com/json/{ip}?fields=status,country,countryCode,regionName,city,lat,lon,timezone,isp,org,as,query,message"
    try:
        with urlopen(url, timeout=IP_INFO_LOOKUP_TIMEOUT) as resp:
            payload = resp.read(16384)
    except (OSError, URLError, TimeoutError, ValueError):
        return None
    try:
        data = json.loads(payload.decode("utf-8"))
    except Exception:
        return None
    if not isinstance(data, dict) or data.get("status") != "success":
        return None
    country_code = str(data.get("countryCode") or "").upper().strip()
    org = str(data.get("org") or "").strip()
    isp = str(data.get("isp") or "").strip()
    asn_raw = str(data.get("as") or "").strip()
    asn_parts = asn_raw.split(" ", 1)
    asn = asn_parts[0] if asn_parts else ""
    asn_id = asn[2:] if asn.startswith("AS") and asn[2:].isdigit() else ""
    return {
        "ip": ip,
        "country": str(data.get("country") or "").strip(),
        "country_code": country_code,
        "flag": country_code_to_flag(country_code),
        "region": str(data.get("regionName") or "").strip(),
        "city": str(data.get("city") or "").strip(),
        "lat": _safe_float(data.get("lat")),
        "lon": _safe_float(data.get("lon")),
        "timezone": str(data.get("timezone") or "").strip(),
        "asn": asn,
        "asn_id": asn_id,
        "provider": org or isp,
        "org": org,
        "hosting": None,
        "_source_name": "ip-api",
    }


def lookup_endpoint_ip_info(ip, allow_refresh=True):
    """Endpoint-card lookup with controlled multi-source enrichment.

    - Cache hit with >=3 real (non-WHOIS) sources, including ipinfo or
      ip-api, and current source_details format: return cache as-is.
    - Cache hit that is "thin" (fewer than 3 real sources, missing both
      ipinfo and ip-api, or predates the provider_display field) and
      refresh is allowed: do one controlled multi-source lookup.
    - Cache miss: multi-source lookup if refresh is allowed, else empty info.
    """
    ip = (ip or "").strip()
    if not ip:
        return _empty_endpoint_info(ip, source="local")
    if _is_private_endpoint_ip(ip):
        return _empty_endpoint_info(ip, source="local", provider="private")

    now = time.time()
    with IP_INFO_CACHE_LOCK:
        cache = load_ip_info_cache()
        cached = cache.get(ip)
        cached_info = None
        fresh = False
        if isinstance(cached, dict):
            ts = float(cached.get("_cache_ts") or 0)
            status = cached.get("status", "ok")
            ttl = (IP_INFO_NEGATIVE_TTL if status == "negative"
                   else IP_INFO_ERROR_CACHE_TTL if status == "error"
                   else IP_INFO_CACHE_TTL)
            cached_info = dict(cached.get("info") or _empty_endpoint_info(ip, source="cache"))
            fresh = bool(ts) and (now - ts < ttl)

    whois_cfg = _geoip_provider_cfg("2ip_whois")
    want_whois = bool(whois_cfg.get("enabled")) and not whois_cfg.get("only_on_refresh", True)

    if cached_info is not None:
        source_details = cached_info.get("source_details") or {}
        real_sources = [src for src in source_details if src != "2ip_whois"]
        old_format = any(
            not isinstance(detail, dict) or "provider_display" not in detail
            for detail in source_details.values()
        )
        thin = (
            len(real_sources) < 3
            or not ({"ipinfo", "ip-api"} & set(real_sources))
            or old_format
        )
        if fresh and not thin:
            cached_info["source"] = "cache"
            return cached_info
        if not allow_refresh:
            cached_info["source"] = "cache"
            return cached_info
        # Fresh-but-thin or stale, and refresh allowed: do one controlled
        # multi-source enrichment pass.
        return lookup_ip_enriched(ip, purpose="endpoint", multi_source=True, force_refresh=True, want_whois=want_whois)

    if not allow_refresh:
        return _empty_endpoint_info(ip, source="cache")
    return lookup_ip_enriched(ip, purpose="endpoint", multi_source=True, want_whois=want_whois)


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


def _provider_positive_int(value, default, minimum=1, maximum=86400):
    try:
        n = int(value)
    except (TypeError, ValueError):
        return default
    return max(minimum, min(maximum, n))


def _provider_optional_gb(value):
    if value in (None, ""):
        return None
    try:
        n = float(value)
    except (TypeError, ValueError):
        return None
    return n if n >= 0 else None


def load_provider_traffic_config():
    if not PROVIDER_TRAFFIC_FILE.exists():
        return {"enabled": False, "provider": "", "label": "Provider Traffic"}
    try:
        data = json.loads(PROVIDER_TRAFFIC_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {"enabled": False, "provider": "", "label": "Provider Traffic"}
    if not isinstance(data, dict):
        return {"enabled": False, "provider": "", "label": "Provider Traffic"}
    provider = str(data.get("provider") or "").strip().lower()
    if provider not in {"hostkey"}:
        provider = ""
    label = str(data.get("label") or "Provider Traffic").strip()[:60] or "Provider Traffic"
    return {
        "enabled": bool(data.get("enabled")) and bool(provider),
        "provider": provider,
        "label": label,
        "token": str(data.get("token") or os.environ.get("HOSTKEY_TOKEN") or "").strip(),
        "ip": str(data.get("ip") or "").strip(),
        "server_id": str(data.get("server_id") or "").strip(),
        "period_days": _provider_positive_int(data.get("period_days"), 30, 1, 366),
        "cache_ttl_seconds": _provider_positive_int(data.get("cache_ttl_seconds"), 600, 30, 86400),
        "unit": str(data.get("unit") or "gb").strip().lower(),
        "limit_total_gb": _provider_optional_gb(data.get("limit_total_gb")),
        "limit_in_gb": _provider_optional_gb(data.get("limit_in_gb")),
        "limit_out_gb": _provider_optional_gb(data.get("limit_out_gb")),
        "unbilled": 1 if str(data.get("unbilled", "0")).lower() in {"1", "true", "yes"} else 0,
    }


def provider_value_to_bytes(value, unit="gb"):
    try:
        n = float(value)
    except (TypeError, ValueError):
        return 0
    unit = (unit or "gb").lower()
    if unit in {"bytes", "byte", "b"}:
        return max(0, int(n))
    if unit in {"mb", "mib"}:
        factor = 1024 ** 2 if unit == "mib" else 1000 ** 2
    elif unit == "gib":
        factor = 1024 ** 3
    else:
        factor = 1000 ** 3
    return max(0, int(n * factor))


def provider_gb_to_bytes(value):
    if value is None:
        return None
    return max(0, int(float(value) * 1000 ** 3))


def hostkey_post(endpoint, params, timeout=8.0):
    data = urlencode(params).encode("utf-8")
    request = Request(
        f"https://invapi.hostkey.ru/{endpoint}",
        data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urlopen(request, timeout=timeout) as response:
        raw = response.read(256 * 1024)
    return json.loads(raw.decode("utf-8", errors="replace"))


def hostkey_login(api_key, ttl=3600):
    payload = hostkey_post("auth.php", {
        "action": "login",
        "key": api_key,
        "ttl": ttl,
        "base": "https://invapi.hostkey.ru",
    })
    result = payload.get("result") if isinstance(payload, dict) else None
    if not isinstance(result, dict) or not result.get("token"):
        raise ValueError(str((payload or {}).get("error") or "login failed")[:160])
    return result


def hostkey_session_token(api_key):
    global HOSTKEY_SESSION_TOKEN, HOSTKEY_SESSION_EXPIRE, HOSTKEY_SESSION_KEY
    with HOSTKEY_SESSION_LOCK:
        if (
            HOSTKEY_SESSION_TOKEN
            and HOSTKEY_SESSION_KEY == api_key
            and time.time() < HOSTKEY_SESSION_EXPIRE - 60
        ):
            return HOSTKEY_SESSION_TOKEN, None
        result = hostkey_login(api_key)
        HOSTKEY_SESSION_TOKEN = result["token"]
        HOSTKEY_SESSION_KEY = api_key
        HOSTKEY_SESSION_EXPIRE = float(result.get("token_expire") or (time.time() + 3600))
        servers = result.get("servers") or []
        default_server_id = str(servers[0]) if servers else None
        return HOSTKEY_SESSION_TOKEN, default_server_id


def hostkey_invalidate_session():
    global HOSTKEY_SESSION_TOKEN, HOSTKEY_SESSION_EXPIRE
    with HOSTKEY_SESSION_LOCK:
        HOSTKEY_SESSION_TOKEN = ""
        HOSTKEY_SESSION_EXPIRE = 0.0


def hostkey_traffic_payload(cfg):
    api_key = cfg.get("token", "")
    if not api_key:
        return {"enabled": True, "provider": "hostkey", "label": cfg["label"], "status": "error", "error": "missing token"}
    period_days = int(cfg.get("period_days", 30))
    cutoff = time.strftime("%Y-%m-%d", time.gmtime(time.time() - period_days * 86400))

    def fetch(force_relogin=False):
        if force_relogin:
            hostkey_invalidate_session()
        session_token, default_server_id = hostkey_session_token(api_key)
        server_id = cfg.get("server_id") or default_server_id
        if not server_id:
            raise ValueError("missing server_id")
        payload = hostkey_post("eq.php", {
            "action": "get_traffic",
            "token": session_token,
            "id": server_id,
        })
        return payload

    try:
        payload = fetch()
        if not isinstance(payload, dict) or payload.get("result") != "OK":
            payload = fetch(force_relogin=True)
    except (OSError, URLError, TimeoutError, json.JSONDecodeError, ValueError) as exc:
        return {"enabled": True, "provider": "hostkey", "label": cfg["label"], "status": "error", "error": str(exc)[:160] or exc.__class__.__name__}
    if not isinstance(payload, dict) or payload.get("result") != "OK":
        message = str((payload or {}).get("error") or "request failed")[:160] if isinstance(payload, dict) else "request failed"
        return {"enabled": True, "provider": "hostkey", "label": cfg["label"], "status": "warn", "error": message}
    traffic = payload.get("traffic")
    rows = traffic if isinstance(traffic, list) else [traffic] if isinstance(traffic, dict) else []
    include_unbilled = bool(cfg.get("unbilled", 0))
    in_bytes = out_bytes = 0
    for row in rows:
        if not isinstance(row, dict):
            continue
        if row.get("updated") and str(row.get("updated")) < cutoff:
            continue
        if not include_unbilled and not row.get("billed", 1):
            continue
        volume_bytes = provider_value_to_bytes(row.get("volume"), "gb")
        if row.get("direction") == 1:
            in_bytes += volume_bytes
        else:
            out_bytes += volume_bytes
    total = in_bytes + out_bytes
    limit_total = provider_gb_to_bytes(cfg.get("limit_total_gb"))
    limit_in = provider_gb_to_bytes(cfg.get("limit_in_gb"))
    limit_out = provider_gb_to_bytes(cfg.get("limit_out_gb"))
    return {
        "enabled": True,
        "provider": "hostkey",
        "label": cfg["label"],
        "status": "ok",
        "period_days": period_days,
        "refreshed_at": utc_now_iso(),
        "traffic": {"in_bytes": in_bytes, "out_bytes": out_bytes, "total_bytes": total},
        "quota": {"total_bytes": limit_total, "in_bytes": limit_in, "out_bytes": limit_out},
        "remaining": {
            "total_bytes": None if limit_total is None else max(0, limit_total - total),
            "in_bytes": None if limit_in is None else max(0, limit_in - in_bytes),
            "out_bytes": None if limit_out is None else max(0, limit_out - out_bytes),
        },
    }


def provider_traffic_payload(force=False):
    global PROVIDER_TRAFFIC_CACHE, PROVIDER_TRAFFIC_CACHE_TS, PROVIDER_TRAFFIC_CACHE_KEY
    cfg = load_provider_traffic_config()
    if not cfg.get("enabled"):
        return {"enabled": False}
    cache_key = json.dumps({k: v for k, v in cfg.items() if k != "token"}, sort_keys=True)
    now = time.time()
    with PROVIDER_TRAFFIC_LOCK:
        if (
            not force
            and PROVIDER_TRAFFIC_CACHE is not None
            and PROVIDER_TRAFFIC_CACHE_KEY == cache_key
            and now - PROVIDER_TRAFFIC_CACHE_TS < int(cfg.get("cache_ttl_seconds", 600))
        ):
            return dict(PROVIDER_TRAFFIC_CACHE)
        payload = hostkey_traffic_payload(cfg) if cfg.get("provider") == "hostkey" else {"enabled": False}
        PROVIDER_TRAFFIC_CACHE = dict(payload)
        PROVIDER_TRAFFIC_CACHE_TS = time.time()
        PROVIDER_TRAFFIC_CACHE_KEY = cache_key
        return payload


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
        current_peer_names = {peer["name"] for peer in parse_peers()}
        for name in list(last):
            if name.startswith("_"):
                del last[name]
                changed = True
            elif name not in active_names and name not in current_peer_names:
                del last[name]
                changed = True
        for name in list(totals):
            if name.startswith("_"):
                continue
            if name not in active_names and name not in current_peer_names:
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


def latest_client_endpoint_snapshot(history_rows):
    if not isinstance(history_rows, list):
        return {}
    for row in reversed(history_rows):
        if isinstance(row, dict):
            return row
    return {}


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
    # Optional dedicated machine/API credential.  It is configured as a
    # SHA-256 digest in the service environment, never as a plaintext secret
    # in the repository.  This keeps bot automation on the HTTP API while
    # preserving the regular super/user token model.
    bot_hash = os.environ.get("AWG_BOT_API_TOKEN_HASH", "").strip().lower()
    if TOKEN_HASH_RE.fullmatch(bot_hash) and hmac.compare_digest(digest, bot_hash):
        return {"role": "super", "hash": digest, "clients": None, "source": "bot-api"}
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
        "AWG_ENDPOINT": "",
        "AWG_TUNNEL_SUBNET": "10.9.9.1/24",
        "AWG_MTU": "",
        "AWG_IPV6_ENABLED": "0",
        "AWG_IPV6_MODE": "legacy",
        "AWG_IPV6_MODE_EFFECTIVE": "",
        "AWG_IPV6_SUBNET": "",
        "AWG_P2P_PORTS_PER_CLIENT": "3",
        "AWG_WEB_PUBLIC_URL": "",
        "AWG_WEB_DOMAIN": "",
        "AWG_WEB_PORT": "8443",
        "AWG_WEB_BIND": "",
        "AWG_PRESET": "",
        "AWG_Jc": "",
        "AWG_Jmin": "",
        "AWG_Jmax": "",
        "AWG_S1": "",
        "AWG_S2": "",
        "AWG_S3": "",
        "AWG_S4": "",
        "AWG_H1": "",
        "AWG_H2": "",
        "AWG_H3": "",
        "AWG_H4": "",
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
    vpn_gateway, _vpn_network = configured_vpn_ipv4()
    mode = cfg["AWG_DNS_MODE"]
    client_dns = cfg["AWG_CUSTOM_DNS"] if mode == "custom" else "1.1.1.1"
    if mode == "adguard":
        client_dns = vpn_gateway
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
    vpn_gateway, _vpn_network = configured_vpn_ipv4()
    return {
        "mode": status["mode"],
        "client_resolver": status["client_dns"],
        "managed_enabled": status["adguard_enabled"],
        "managed_service": status["adguard_service"],
        "managed_port": status["adguard_port"],
        "managed_url": f"http://{vpn_gateway}:{status['adguard_port']}/" if status["adguard_enabled"] else "",
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


def vpn_ipv4_network():
    cfg = parse_config()
    try:
        return ipaddress.ip_network(cfg.get("AWG_TUNNEL_SUBNET") or "10.9.9.1/24", strict=False)
    except ValueError:
        return ipaddress.ip_network("10.9.9.0/24", strict=False)


def validate_vpn_latency_target(value, network=None):
    network = network or vpn_ipv4_network()
    try:
        ip = ipaddress.ip_address(str(value or "").strip())
    except ValueError as exc:
        raise ValueError("invalid vpn ip") from exc
    if ip.version != 4 or ip not in network:
        raise ValueError("vpn ip outside subnet")
    if ip == network.network_address or ip == network.broadcast_address:
        raise ValueError("invalid vpn ip")
    return str(ip)


def parse_ping_output(stdout):
    text = stdout or ""
    loss_match = re.search(r"(\d+(?:\.\d+)?)%\s*packet loss", text)
    loss = float(loss_match.group(1)) if loss_match else 100.0
    rtt = None
    rtt_match = re.search(r"(?:rtt|round-trip) [^=]+ = ([0-9.]+)/([0-9.]+)/([0-9.]+)", text)
    if rtt_match:
        rtt = float(rtt_match.group(2))
    else:
        samples = [float(item) for item in re.findall(r"time[=<]([0-9.]+)\s*ms", text)]
        if samples:
            rtt = sum(samples) / len(samples)
    if rtt is None and loss >= 100:
        return {"status": "timeout", "rtt_ms": None, "loss_pct": 100.0, "samples": 0, "label": "timeout"}
    status = "ok" if rtt is not None else "timeout"
    samples = len(re.findall(r"bytes from ", text)) or (0 if rtt is None else 1)
    label = f"{round(rtt):.0f} ms" if rtt is not None else "timeout"
    return {"status": status, "rtt_ms": round(rtt, 1) if rtt is not None else None, "loss_pct": loss, "samples": samples, "label": label}


def ping_vpn_client(ip):
    target = validate_vpn_latency_target(ip)
    try:
        p = subprocess.run(
            ["ping", "-n", "-c", "3", "-W", "1", "-i", "0.2", target],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=4,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {"status": "timeout", "rtt_ms": None, "loss_pct": 100.0, "samples": 3, "label": "timeout"}
    parsed = parse_ping_output(p.stdout)
    if p.returncode != 0 and parsed["rtt_ms"] is None:
        parsed.update({"status": "timeout", "label": "timeout"})
    return parsed


def public_key_fingerprint(value):
    raw = str(value or "").strip()
    if not raw:
        return ""
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:12]


def load_client_endpoint_history():
    try:
        if CLIENT_ENDPOINT_HISTORY_FILE.exists():
            data = json.loads(CLIENT_ENDPOINT_HISTORY_FILE.read_text(encoding="utf-8"))
            if isinstance(data, dict) and isinstance(data.get("clients"), dict):
                return data
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        pass
    return {"clients": {}}


def prune_endpoint_history(data, now=None):
    now = now or time.time()
    cutoff = now - CLIENT_ENDPOINT_HISTORY_RETENTION
    clients = data.setdefault("clients", {})
    for name in list(clients):
        rows = clients.get(name)
        if not isinstance(rows, list):
            clients.pop(name, None)
            continue
        clean = []
        for row in rows:
            if not isinstance(row, dict):
                continue
            observed = float(row.get("observed_at") or 0)
            if observed >= cutoff:
                clean.append(row)
        if clean:
            clients[name] = clean[-CLIENT_ENDPOINT_HISTORY_MAX:]
        else:
            clients.pop(name, None)
    return data


def write_client_endpoint_history(data):
    WEB_DIR.mkdir(parents=True, exist_ok=True)
    tmp = CLIENT_ENDPOINT_HISTORY_FILE.with_name(f"{CLIENT_ENDPOINT_HISTORY_FILE.name}.tmp.{os.getpid()}")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, CLIENT_ENDPOINT_HISTORY_FILE)
    os.chmod(CLIENT_ENDPOINT_HISTORY_FILE, 0o600)


def endpoint_geo_snapshot(endpoint_ip):
    if not endpoint_ip:
        return {}
    try:
        cache = load_ip_info_cache()
        entry = cache.get(endpoint_ip) if isinstance(cache, dict) else None
        info = entry.get("info") if isinstance(entry, dict) else None
        if not isinstance(info, dict):
            return {}
        return {
            "asn": str(info.get("asn") or info.get("asn_id") or ""),
            "country": str(info.get("country_code") or info.get("country") or ""),
            "city": str(info.get("city") or ""),
            "provider": str(info.get("provider") or info.get("org") or ""),
        }
    except Exception:
        return {}


def record_client_endpoint_history(peers, stats, now=None, force=False):
    global CLIENT_ENDPOINT_HISTORY_LAST_WRITE
    now = now or time.time()
    changed = False
    with CLIENT_ENDPOINT_HISTORY_LOCK:
        data = prune_endpoint_history(load_client_endpoint_history(), now)
        clients = data.setdefault("clients", {})
        for peer in peers:
            name = peer.get("name") or peer.get("config_name") or ""
            if not name:
                continue
            row_stats = stats.get(name, {}) if isinstance(stats, dict) else {}
            endpoint = row_stats.get("endpoint") or ""
            endpoint_ip, endpoint_port = split_endpoint(endpoint)
            last_handshake = int(row_stats.get("latestHandshakeAt", row_stats.get("last_handshake", 0)) or 0)
            rx = int(row_stats.get("rx") or 0)
            tx = int(row_stats.get("tx") or 0)
            if not endpoint_ip and not last_handshake:
                continue
            rows = clients.setdefault(name, [])
            last = rows[-1] if rows else {}
            fp = public_key_fingerprint(peer.get("public_key", ""))
            observation = {
                "observed_at": int(now),
                "endpoint_ip": endpoint_ip,
                "endpoint_port": endpoint_port,
                "latest_handshake": last_handshake,
                "rx": rx,
                "tx": tx,
                "public_key_fp": fp,
            }
            geo = endpoint_geo_snapshot(endpoint_ip)
            if geo:
                observation["geo"] = geo
            meaningful_change = (
                not rows
                or last.get("endpoint_ip") != endpoint_ip
                or last.get("endpoint_port") != endpoint_port
                or int(last.get("latest_handshake") or 0) != last_handshake
                or int(last.get("rx") or 0) != rx
                or int(last.get("tx") or 0) != tx
            )
            if meaningful_change:
                rows.append(observation)
                clients[name] = rows[-CLIENT_ENDPOINT_HISTORY_MAX:]
                changed = True
        if changed and (force or now - CLIENT_ENDPOINT_HISTORY_LAST_WRITE >= CLIENT_ENDPOINT_HISTORY_WRITE_INTERVAL):
            write_client_endpoint_history(data)
            CLIENT_ENDPOINT_HISTORY_LAST_WRITE = now
        return data


def shared_profile_detection(history_rows, now=None):
    now = now or time.time()
    rows = [row for row in (history_rows or []) if isinstance(row, dict) and now - float(row.get("observed_at") or 0) <= 30 * 60]
    rows.sort(key=lambda row: float(row.get("observed_at") or 0))
    recent10 = [row for row in rows if now - float(row.get("observed_at") or 0) <= 10 * 60]
    base = {
        "severity": "none",
        "distinct_endpoint_ips_10m": 0,
        "endpoint_changes_10m": 0,
        "distinct_asns_10m": 0,
        "last_change_at": "",
        "summary": "",
        "evidence": [],
    }
    if len(recent10) < 2:
        return base
    ips = [row.get("endpoint_ip") or "" for row in recent10 if row.get("endpoint_ip")]
    distinct_ips = sorted(set(ips))
    changes = 0
    last_change = 0
    flip_chain = []
    prev_ip = None
    for row in recent10:
        ip = row.get("endpoint_ip") or ""
        if not ip:
            continue
        if prev_ip and ip != prev_ip:
            changes += 1
            last_change = int(row.get("observed_at") or 0)
            flip_chain.append(ip)
        prev_ip = ip
    asns = set()
    countries = set()
    for row in recent10:
        geo = row.get("geo") if isinstance(row.get("geo"), dict) else {}
        if geo.get("asn"):
            asns.add(str(geo["asn"]))
        if geo.get("country"):
            countries.add(str(geo["country"]))
    severity = "none"
    summary = ""
    evidence = []
    if len(distinct_ips) >= 2 and changes >= 3 and (len(asns) >= 2 or len(countries) >= 2):
        severity = "high"
        summary = "Likely same profile on multiple devices: endpoint alternates across networks."
        evidence.append("different ASNs/countries observed")
    elif len(distinct_ips) >= 2 and changes >= 3:
        severity = "suspected"
        summary = f"Possible same config on multiple devices: endpoint alternated between {len(distinct_ips)} public IPs."
    elif len(distinct_ips) >= 2 and changes >= 1:
        severity = "watch"
        summary = "Endpoint changed recently; watch for repeated flips."
    if changes:
        chain = [ips[0]] + flip_chain
        evidence.insert(0, " -> ".join(chain[-5:]))
    base.update({
        "severity": severity,
        "distinct_endpoint_ips_10m": len(distinct_ips),
        "endpoint_changes_10m": changes,
        "distinct_asns_10m": len(asns),
        "last_change_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(last_change)) if last_change else "",
        "summary": summary,
        "evidence": evidence,
    })
    return base


def recent_nettest_latency_by_vpn_ip(max_age=3600):
    now = time.time()
    out = {}
    try:
        paths = sorted(NETTEST_REPORT_DIR.glob("nettest_*.json"), key=lambda item: item.stat().st_mtime, reverse=True)[:50]
    except OSError:
        return out
    for path in paths:
        try:
            if now - path.stat().st_mtime > max_age:
                continue
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError, UnicodeDecodeError):
            continue
        vpn_ip = str(data.get("vpn_client_ip") or data.get("network_context", {}).get("vpn_client_ip") or "")
        latency = data.get("latency") if isinstance(data.get("latency"), dict) else {}
        avg = latency.get("avg_ms")
        if vpn_ip and avg is not None and vpn_ip not in out:
            observed_at = path.stat().st_mtime
            out[vpn_ip] = {
                "rtt_ms": round(float(avg), 1),
                "loss_pct": float(latency.get("loss_percent") or 0),
                "samples": int(latency.get("samples") or latency.get("ok") or 0),
                "stalls": int(data.get("stall_events") or latency.get("stall_events") or data.get("stalls") or 0),
                "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(observed_at)),
                "observed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(observed_at)),
                "age_sec": max(0, int(now - observed_at)),
                "source": "nettest",
            }
    return out


def recent_nettest_latency_for_client(client_name, vpn_ip, max_age_minutes=60):
    del client_name
    return recent_nettest_latency_by_vpn_ip(max_age=max_age_minutes * 60).get(vpn_ip)


def connectivity_from_signals(age, transfer_active, ping_result, nettest_result=None):
    notes = []
    ping_status = (ping_result or {}).get("status") or "unknown"
    rtt = (ping_result or {}).get("rtt_ms")
    loss = (ping_result or {}).get("loss_pct")
    if age is None:
        notes.append("no handshake observed")
        return "offline", "unavailable", "low", "never", "offline", notes
    if age < 180:
        handshake_state = "fresh"
        notes.append("fresh handshake")
    elif age < CLIENT_LATENCY_STALE_AFTER:
        handshake_state = "recent"
        notes.append("recent handshake")
    else:
        notes.append("stale handshake")
        return "stale", "unavailable", "low", "stale", "offline", notes
    if transfer_active:
        notes.append("traffic observed in last sample")
    if rtt is not None:
        notes.append("ICMP reachable")
        connectivity = "online"
        status = "high" if float(rtt) > 200 or float(loss or 0) >= 50 else "ok"
        return connectivity, "icmp", "high", status, f"{round(float(rtt)):.0f} ms", notes
    if nettest_result:
        notes.append("recent browser network test available")
        notes.append("ICMP did not answer; using browser-side network test as fallback")
        net_rtt = float(nettest_result["rtt_ms"])
        net_loss = float(nettest_result.get("loss_pct") or 0)
        status = "high" if net_rtt > 200 or net_loss >= 50 else "ok"
        return "online", "nettest", "medium", status, f"net {round(net_rtt):.0f} ms", notes
    if ping_status == "timeout" and transfer_active:
        notes.append("ICMP did not answer, but recent traffic suggests the client is online")
        notes.append("client may block ICMP or sleep between checks")
        return "online", "traffic", "low", "icmp_blocked_possible", "no ping", notes
    if ping_status == "timeout" and handshake_state == "fresh":
        notes.append("ICMP did not answer, but handshake is fresh; client is probably idle or blocks ICMP")
        return "online", "handshake", "low", "idle", "idle", notes
    if ping_status == "timeout" and handshake_state == "recent":
        notes.append("ICMP did not answer, but handshake is recent; client may block ICMP or sleep")
        return "online", "handshake", "low", "icmp_blocked_possible", "no ping", notes
    notes.append("ICMP timeout")
    return "unknown", "unavailable", "low", "timeout", "timeout", notes


def percentile(values, pct):
    if not values:
        return None
    ordered = sorted(float(v) for v in values)
    idx = min(len(ordered) - 1, max(0, int(round((pct / 100.0) * (len(ordered) - 1)))))
    return round(ordered[idx], 1)


def parse_path_check_output(stdout, target):
    hops = []
    by_hop = {}
    for raw in (stdout or "").splitlines():
        line = raw.strip()
        if not line:
            continue
        m = re.match(r"^\s*(\d+)[:\s]+(?:\?:\s+)?(?:\[[^\]]+\]\s+)?([0-9.]+|\*)", line)
        if not m:
            continue
        hop = int(m.group(1))
        address = "" if m.group(2) == "*" else m.group(2)
        times = [float(x) for x in re.findall(r"([0-9]+(?:\.[0-9]+)?)\s*ms", line)]
        by_hop[hop] = {"hop": hop, "address": address, "rtt_ms": round(times[0], 1) if times else None, "raw": line[:240]}
    hops = [by_hop[key] for key in sorted(by_hop)]
    if not hops and target:
        m = re.search(r"([0-9]+(?:\.[0-9]+)?)\s*ms", stdout or "")
        if m:
            hops.append({"hop": 1, "address": target, "rtt_ms": round(float(m.group(1)), 1), "raw": (stdout or "").strip()[:240]})
    return hops


PUBLIC_ENDPOINT_PATH_NOTE = "Public endpoint path shows route to the client's NAT/carrier endpoint, not necessarily the device itself."
TUNNEL_PATH_NOTE = "Tunnel path checks the private VPN IP. It is usually 1 hop and does not show the public Internet route."


def validate_public_endpoint_path_target(ip):
    try:
        parsed = ipaddress.ip_address(str(ip).strip())
    except ValueError as exc:
        raise ValueError("invalid endpoint IP") from exc
    if parsed.version != 4:
        raise ValueError("IPv6 endpoint path is unsupported")
    if (
        parsed.is_loopback
        or parsed.is_link_local
        or parsed.is_multicast
        or parsed.is_private
        or parsed.is_unspecified
        or parsed.is_reserved
    ):
        raise ValueError("unsafe endpoint IP")
    return str(parsed)


def path_check_summary(status, hops):
    if status == "no_endpoint":
        return "no endpoint"
    if status == "unsupported":
        return "path n/a"
    if status in {"blocked", "rate_limited", "stale"}:
        return "try later"
    if status == "timeout":
        return "path timeout"
    if not hops:
        return "path n/a"
    count = len(hops)
    last_rtt = next((item.get("rtt_ms") for item in reversed(hops) if item.get("rtt_ms") is not None), None)
    suffix = f", last {round(float(last_rtt)):.0f} ms" if last_rtt is not None else ""
    return f"{count} hop{'s' if count != 1 else ''}{suffix}"


def make_path_check_result(name, target, status, method="none", path=None, note="", retry_after=None, target_type="endpoint", vpn_ip="", endpoint="", endpoint_stale=False):
    path = path or []
    result = {
        "client": name,
        "target_type": target_type,
        "target_ip": target,
        "vpn_ip": vpn_ip or (target if target_type == "tunnel" else ""),
        "endpoint": endpoint,
        "endpoint_stale": bool(endpoint_stale),
        "timestamp": utc_now_iso(),
        "status": status,
        "method": method,
        "hop_count": len(path) if path else None,
        "hops": len(path) if path else None,
        "path": path,
        "summary": path_check_summary(status, path),
        "note": note or (TUNNEL_PATH_NOTE if target_type == "tunnel" else PUBLIC_ENDPOINT_PATH_NOTE),
    }
    if retry_after is not None:
        result["retry_after"] = max(1, int(retry_after))
    return result


def remember_path_check_result(name, result):
    if result.get("target_type") == "endpoint":
        CLIENT_PATH_CHECK_RESULTS[name] = {"ts": time.time(), "value": json.loads(json.dumps(result))}
    return result


def endpoint_cache_key(name, endpoint):
    return f"{safe_name(name)}:endpoint:{endpoint or '-'}"


def path_result_matches_endpoint(result, endpoint):
    if not isinstance(result, dict):
        return False
    if result.get("target_type") != "endpoint":
        return True
    return (result.get("endpoint") or "") == (endpoint or "")


def recent_path_check_results(now=None, current_endpoints=None):
    now = now or time.time()
    current_endpoints = current_endpoints or {}
    out = {}
    for name, item in list(CLIENT_PATH_CHECK_RESULTS.items()):
        if now - item.get("ts", 0) > CLIENT_PATH_CHECK_RESULT_TTL:
            CLIENT_PATH_CHECK_RESULTS.pop(name, None)
            continue
        value = json.loads(json.dumps(item.get("value") or {}))
        if name in current_endpoints and not path_result_matches_endpoint(value, current_endpoints.get(name, "")):
            continue
        out[name] = value
    return out


def client_latency_snapshot_signature(peers, stats):
    rows = []
    for peer in peers:
        name = peer.get("name") or peer.get("config_name") or ""
        if not name:
            continue
        row = stats.get(name, {}) if isinstance(stats, dict) else {}
        rows.append([
            name,
            peer.get("ipv4") or "",
            row.get("endpoint") or "",
            int(row.get("latestHandshakeAt", row.get("last_handshake", 0)) or 0),
            int(row.get("rx") or 0),
            int(row.get("tx") or 0),
        ])
    return rows


def client_path_check(name, target_type="endpoint"):
    name = safe_name(name)
    target_type = (target_type or "endpoint").strip().lower()
    if target_type not in {"endpoint", "tunnel"}:
        raise ValueError("invalid path target")
    peer = next((item for item in parse_peers() if item.get("name") == name), None)
    if not peer:
        raise ValueError("unknown client")
    vpn_ip = peer.get("ipv4") or ""
    row_stats = client_stats_map().get(name, {})
    endpoint = row_stats.get("endpoint") or ""
    endpoint_ip, _endpoint_port = split_endpoint(endpoint)
    last = int(row_stats.get("latestHandshakeAt", row_stats.get("last_handshake", 0)) or 0)
    age = None if last <= 0 else max(0, int(time.time() - last))
    endpoint_stale = bool(age is None or age > CLIENT_LATENCY_STALE_AFTER)
    if target_type == "tunnel":
        target = validate_vpn_latency_target(vpn_ip)
        max_hops = "8"
        note = TUNNEL_PATH_NOTE
    else:
        if not endpoint_ip:
            return make_path_check_result(name, "", "no_endpoint", "none", note="Client has no current public endpoint.", target_type=target_type, vpn_ip=vpn_ip, endpoint="")
        target = validate_public_endpoint_path_target(endpoint_ip)
        max_hops = "16"
        note = PUBLIC_ENDPOINT_PATH_NOTE
        if endpoint_stale:
            note += " Endpoint may be stale because latest handshake is old."
    now = time.time()
    rate_key = endpoint_cache_key(name, endpoint) if target_type == "endpoint" else f"{name}:{target_type}"
    with CLIENT_PATH_CHECK_LOCK:
        last_check = CLIENT_PATH_CHECK_LAST.get(rate_key, 0)
        if now - last_check < CLIENT_PATH_CHECK_INTERVAL:
            return make_path_check_result(
                name,
                target,
                "blocked",
                "none",
                note="Path check is rate-limited per client.",
                retry_after=CLIENT_PATH_CHECK_INTERVAL - (now - last_check),
                target_type=target_type,
                vpn_ip=vpn_ip,
                endpoint=endpoint,
                endpoint_stale=endpoint_stale,
            )
        CLIENT_PATH_CHECK_LAST[rate_key] = now
    method = "none"
    if shutil.which("tracepath"):
        method = "tracepath"
        cmd = ["tracepath", "-n", "-m", max_hops, target]
    elif shutil.which("traceroute"):
        method = "traceroute"
        cmd = ["traceroute", "-n", "-m", max_hops, "-w", "1", target]
    else:
        return remember_path_check_result(name, make_path_check_result(
            name,
            target,
            "unsupported",
            "none",
            note="tracepath/traceroute is not installed.",
            target_type=target_type,
            vpn_ip=vpn_ip,
            endpoint=endpoint,
            endpoint_stale=endpoint_stale,
        ))
    if not CLIENT_PATH_CHECK_SEM.acquire(blocking=False):
        return make_path_check_result(name, target, "blocked", method, note="Another path check is already running.", target_type=target_type, vpn_ip=vpn_ip, endpoint=endpoint, endpoint_stale=endpoint_stale)
    try:
        p = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    except subprocess.TimeoutExpired:
        return remember_path_check_result(name, make_path_check_result(name, target, "timeout", method, note=f"Path check timed out. {note}", target_type=target_type, vpn_ip=vpn_ip, endpoint=endpoint, endpoint_stale=endpoint_stale))
    except OSError:
        return remember_path_check_result(name, make_path_check_result(name, target, "unsupported", "none", note="Path check command is unavailable.", target_type=target_type, vpn_ip=vpn_ip, endpoint=endpoint, endpoint_stale=endpoint_stale))
    finally:
        try:
            CLIENT_PATH_CHECK_SEM.release()
        except ValueError:
            pass
    path = parse_path_check_output((p.stdout or "") + "\n" + (p.stderr or ""), target)
    status = "ok" if path else ("timeout" if p.returncode != 0 else "unknown")
    return remember_path_check_result(name, make_path_check_result(name, target, status, method, path, note, target_type=target_type, vpn_ip=vpn_ip, endpoint=endpoint, endpoint_stale=endpoint_stale))


def batch_client_path_check(target_type="endpoint", scope="active"):
    global CLIENT_PATH_BATCH_LAST
    target_type = (target_type or "endpoint").strip().lower()
    scope = (scope or "active").strip().lower()
    if target_type != "endpoint":
        raise ValueError("invalid batch path target")
    if scope != "active":
        raise ValueError("invalid batch path scope")

    if not CLIENT_PATH_BATCH_LOCK.acquire(blocking=False):
        return {
            "status": "running",
            "timestamp": utc_now_iso(),
            "target": target_type,
            "scope": scope,
            "checked": 0,
            "skipped": 0,
            "total_candidates": 0,
            "results": {},
            "skipped_clients": {},
            "retry_after": 30,
        }

    results = {}
    skipped = {}
    try:
        now = time.time()
        with CLIENT_PATH_CHECK_LOCK:
            if now - CLIENT_PATH_BATCH_LAST < CLIENT_PATH_BATCH_COOLDOWN:
                retry = CLIENT_PATH_BATCH_COOLDOWN - (now - CLIENT_PATH_BATCH_LAST)
                return {
                    "status": "rate_limited",
                    "timestamp": utc_now_iso(),
                    "target": target_type,
                    "scope": scope,
                    "checked": 0,
                    "skipped": 0,
                    "total_candidates": 0,
                    "results": {},
                    "skipped_clients": {},
                    "retry_after": max(1, int(retry)),
                }
            CLIENT_PATH_BATCH_LAST = now

        peers = parse_peers()
        stats = client_stats_map(force=True)
        current_endpoints = {}
        started = time.time()
        candidates = []

        for peer in peers:
            name = peer.get("name") or peer.get("config_name") or ""
            if not name:
                continue
            row_stats = stats.get(name, {})
            endpoint = row_stats.get("endpoint") or ""
            current_endpoints[name] = endpoint
            endpoint_ip, _endpoint_port = split_endpoint(endpoint)
            last = int(row_stats.get("latestHandshakeAt", row_stats.get("last_handshake", 0)) or 0)
            age = None if last <= 0 else max(0, int(now - last))
            if not endpoint_ip:
                skipped[name] = "no_endpoint"
                continue
            if age is None or age > CLIENT_PATH_BATCH_STALE_AFTER:
                skipped[name] = "stale"
                continue
            try:
                validate_public_endpoint_path_target(endpoint_ip)
            except ValueError as exc:
                skipped[name] = str(exc)
                continue
            candidates.append(name)

        total_candidates = len(candidates)
        cached = recent_path_check_results(now, current_endpoints)
        for name in candidates[:CLIENT_PATH_BATCH_MAX_CLIENTS]:
            cached_result = cached.get(name)
            if cached_result:
                results[name] = cached_result
                continue
            if time.time() - started > CLIENT_PATH_BATCH_MAX_DURATION:
                skipped[name] = "time_budget"
                continue
            with CLIENT_PATH_CHECK_LOCK:
                last_check = CLIENT_PATH_CHECK_LAST.get(endpoint_cache_key(name, current_endpoints.get(name, "")), 0)
            if now - last_check < CLIENT_PATH_CHECK_INTERVAL:
                skipped[name] = "cooldown"
                continue
            try:
                results[name] = client_path_check(name, "endpoint")
            except ValueError as exc:
                skipped[name] = str(exc)
        for name in candidates[CLIENT_PATH_BATCH_MAX_CLIENTS:]:
            skipped[name] = "scan_limit"

        status = "ok"
        if skipped and results:
            status = "partial"
        elif skipped and not results:
            status = "partial"
        return {
            "status": status,
            "timestamp": utc_now_iso(),
            "target": target_type,
            "scope": scope,
            "checked": len(results),
            "skipped": len(skipped),
            "total_candidates": total_candidates,
            "max_clients": CLIENT_PATH_BATCH_MAX_CLIENTS,
            "results": results,
            "skipped_clients": skipped,
        }
    finally:
        try:
            CLIENT_PATH_BATCH_LOCK.release()
        except RuntimeError:
            pass


def client_latency_payload(force=False):
    now = time.time()
    with CLIENT_LATENCY_LOCK:
        peers = parse_peers()
        stats = client_stats_map(force=force)
        snapshot_signature = client_latency_snapshot_signature(peers, stats)
        cached = CLIENT_LATENCY_CACHE.get("value")
        cached_signature = CLIENT_LATENCY_CACHE.get("signature")
        cache_same_snapshot = cached_signature == snapshot_signature
        if not force and cached and cache_same_snapshot and now - CLIENT_LATENCY_CACHE.get("ts", 0) <= CLIENT_LATENCY_CACHE_TTL:
            return json.loads(json.dumps(cached))
        if force and cached and cache_same_snapshot and now - CLIENT_LATENCY_CACHE.get("ts", 0) < CLIENT_LATENCY_FORCE_MIN_INTERVAL:
            return json.loads(json.dumps(cached))

        endpoint_history = record_client_endpoint_history(peers, stats, now)
        history_clients = endpoint_history.get("clients", {}) if isinstance(endpoint_history, dict) else {}
        nettest_latency = recent_nettest_latency_by_vpn_ip()
        current_endpoints = {}
        for peer in peers:
            name = peer.get("name") or peer.get("config_name") or ""
            if name:
                current_endpoints[name] = (stats.get(name, {}) or {}).get("endpoint") or ""
        path_results = recent_path_check_results(now, current_endpoints)
        network = vpn_ipv4_network()
        clients = {}
        scanned = 0
        reachable = []
        path_hops = []
        path_checked_count = 0
        path_timeout_count = 0
        path_unsupported = False
        no_ping_count = 0
        timeout_count = 0
        stale_count = 0
        high_count = 0
        active_count = 0
        shared_count = 0
        flapping_count = 0
        top_issues = []

        for peer in peers:
            name = peer.get("name") or peer.get("config_name") or ""
            if not name:
                continue
            vpn_ip = peer.get("ipv4") or ""
            row_stats = stats.get(name, {})
            last = int(row_stats.get("latestHandshakeAt", row_stats.get("last_handshake", 0)) or 0)
            age = None if last <= 0 else max(0, int(now - last))
            rx = int(row_stats.get("rx") or 0)
            tx = int(row_stats.get("tx") or 0)
            prev_transfer = CLIENT_TRANSFER_PREV.get(name)
            transfer_active = bool(prev_transfer and (rx > prev_transfer.get("rx", 0) or tx > prev_transfer.get("tx", 0)))
            CLIENT_TRANSFER_PREV[name] = {"rx": rx, "tx": tx, "ts": now}
            endpoint = row_stats.get("endpoint") or ""
            endpoint_ip, endpoint_port = split_endpoint(endpoint)
            shared_profile = shared_profile_detection(history_clients.get(name, []), now)
            if shared_profile.get("severity") in {"suspected", "high"}:
                shared_count += 1
            if shared_profile.get("severity") in {"watch", "suspected", "high"}:
                flapping_count += 1
            base = {
                "vpn_ip": vpn_ip,
                "latest_handshake_age": age,
                "handshake_age_sec": age,
                "endpoint": endpoint,
                "endpoint_ip": endpoint_ip,
                "endpoint_port": endpoint_port,
                "public_key_fp": public_key_fingerprint(peer.get("public_key", "")),
                "transfer_active": transfer_active,
                "endpoint_changed_recently": shared_profile.get("severity") in {"watch", "suspected", "high"},
                "shared_profile": shared_profile,
                "rtt_ms": None,
                "loss_pct": None,
                "samples": 0,
                "connectivity": "unknown",
                "latency_method": "unavailable",
                "latency_confidence": "low",
                "ping_status": "unknown",
                "notes": [],
            }
            if name in path_results:
                base["path_check"] = path_results[name]
                path_checked_count += 1
                path_status = path_results[name].get("status")
                if path_status == "timeout":
                    path_timeout_count += 1
                if path_status == "unsupported":
                    path_unsupported = True
                if path_results[name].get("hop_count") is not None:
                    path_hops.append(int(path_results[name].get("hop_count") or 0))
            try:
                target = validate_vpn_latency_target(vpn_ip, network)
            except ValueError:
                base.update({"status": "unknown", "label": "unknown"})
                clients[name] = base
                continue
            if age is None or age > CLIENT_LATENCY_STALE_AFTER:
                stale_count += 1
                connectivity, method, confidence, ping_status, label, notes = connectivity_from_signals(age, transfer_active, None)
                base.update({
                    "status": ping_status,
                    "connectivity": connectivity,
                    "latency_method": method,
                    "latency_confidence": confidence,
                    "ping_status": ping_status,
                    "label": label,
                    "notes": notes,
                })
                if shared_profile.get("severity") in {"suspected", "high"}:
                    top_issues.append({"client": name, "type": "shared_profile", "severity": shared_profile.get("severity"), "summary": shared_profile.get("summary")})
                clients[name] = base
                continue
            active_count += 1
            if scanned >= CLIENT_LATENCY_MAX_SCAN:
                base.update({"status": "skipped", "label": "queued"})
                clients[name] = base
                continue
            scanned += 1
            result = ping_vpn_client(target)
            base.update(result)
            nettest_result = nettest_latency.get(target)
            connectivity, method, confidence, ping_status, label, notes = connectivity_from_signals(age, transfer_active, result, nettest_result)
            if nettest_result:
                base["nettest_latency"] = nettest_result
            if nettest_result and method == "nettest":
                base["rtt_ms"] = nettest_result["rtt_ms"]
                base["loss_pct"] = nettest_result["loss_pct"]
                base["samples"] = nettest_result["samples"]
            base.update({
                "status": ping_status,
                "connectivity": connectivity,
                "latency_method": method,
                "latency_confidence": confidence,
                "ping_status": result.get("status", "unknown"),
                "label": label,
                "notes": notes,
            })
            clients[name] = base
            if base.get("rtt_ms") is not None:
                rtt = float(base["rtt_ms"])
                reachable.append(rtt)
                if rtt > 200:
                    high_count += 1
                    top_issues.append({"client": name, "type": "high_latency", "rtt_ms": round(rtt, 1), "loss_pct": base.get("loss_pct"), "summary": f"{round(rtt):.0f} ms"})
            elif result.get("status") == "timeout":
                timeout_count += 1
                if base.get("status") == "icmp_blocked_possible":
                    no_ping_count += 1
                    top_issues.append({"client": name, "type": "no_ping", "summary": "ICMP timeout with fresh handshake/traffic"})
                elif base.get("status") == "idle":
                    no_ping_count += 1
                    top_issues.append({"client": name, "type": "idle_no_ping", "summary": "ICMP timeout with fresh handshake"})
                else:
                    top_issues.append({"client": name, "type": "timeout", "summary": "ICMP timeout"})
            if shared_profile.get("severity") in {"suspected", "high"}:
                top_issues.append({"client": name, "type": "shared_profile", "severity": shared_profile.get("severity"), "summary": shared_profile.get("summary")})

        payload = {
            "timestamp": utc_now_iso(),
            "ttl_seconds": int(CLIENT_LATENCY_CACHE_TTL),
            "clients": clients,
            "diagnostics": {
                "active_peers": active_count,
                "stale_peers": stale_count,
                "reachable_clients": len(reachable),
                "no_ping_clients": no_ping_count,
                "timeout_clients": timeout_count,
                "high_latency_clients": high_count,
                "shared_profile_suspected": shared_count,
                "endpoint_flapping_clients": flapping_count,
                "path_checked_clients": path_checked_count,
                "average_hops": round(sum(path_hops) / len(path_hops), 1) if path_hops else None,
                "path_timeout_clients": path_timeout_count,
                "path_unsupported": path_unsupported,
                "average_rtt_ms": round(sum(reachable) / len(reachable), 1) if reachable else None,
                "p95_rtt_ms": percentile(reachable, 95),
                "scanned_clients": scanned,
                "scan_cap": CLIENT_LATENCY_MAX_SCAN,
                "top_issues": top_issues[:8],
            },
            "overview": {
                "active": active_count,
                "reachable": len(reachable),
                "no_ping": no_ping_count,
                "high_latency": high_count,
                "stale": stale_count,
                "shared_profile_suspected": shared_count,
                "endpoint_flapping": flapping_count,
                "path_checked": path_checked_count,
                "avg_hops": round(sum(path_hops) / len(path_hops), 1) if path_hops else None,
                "path_timeout": path_timeout_count,
                "path_unsupported": path_unsupported,
                "avg_rtt_ms": round(sum(reachable) / len(reachable), 1) if reachable else None,
                "p95_rtt_ms": percentile(reachable, 95),
                "top_issues": top_issues[:8],
            },
        }
        CLIENT_LATENCY_CACHE["ts"] = now
        CLIENT_LATENCY_CACHE["value"] = payload
        CLIENT_LATENCY_CACHE["signature"] = snapshot_signature
        return json.loads(json.dumps(payload))


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


def bot_snapshot_payload(auth):
    """Return a compact single-request payload for the Telegram control plane.

    The browser client enriches peers with geo-IP and history information;
    automation only needs current service and peer state.  Keeping this path
    intentionally cheap avoids request cascades and SSH fallbacks.
    """
    peers = parse_peers()
    if auth.get("role") != "super":
        allowed = set(auth.get("clients") or [])
        peers = [peer for peer in peers if peer.get("name") in allowed]
    stats = client_stats_map()
    cfg = parse_config()
    try:
        service = subprocess.run(
            ["systemctl", "is-active", "awg-quick@awg0"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=2,
            check=False,
        ).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        service = "unknown"
    now = int(time.time())
    clients = []
    for peer in peers:
        name = peer.get("name", "")
        row = stats.get(name, {})
        handshake = safe_int(row.get("latestHandshakeAt") or row.get("last_handshake")) or 0
        clients.append({
            "name": name,
            "display_name": peer.get("display_name") or name,
            "ipv4": peer.get("ipv4", ""),
            "ipv6": peer.get("ipv6", ""),
            "status": row.get("status", "offline"),
            "online": bool(handshake and now - handshake < 180),
            "latest_handshake": handshake,
            "endpoint": row.get("endpoint", ""),
            "rx": safe_int(row.get("rx")) or 0,
            "tx": safe_int(row.get("tx")) or 0,
            "p2p_ports": peer.get("p2p_ports", []),
            "disabled": bool(peer.get("disabled")),
        })
    return {
        "ok": True,
        "timestamp": now,
        "version": PROJECT_VERSION,
        "fork": "fork delta/patchset",
        "role": "super" if auth.get("role") == "super" else "user",
        "server_name": cfg.get("AWG_SERVER_NAME", ""),
        "display_name": cfg.get("AWG_SERVER_NAME", ""),
        "service": service,
        "clients": clients,
        "summary": {
            "total": len(clients),
            "online": sum(1 for item in clients if item["online"]),
            "disabled": sum(1 for item in clients if item["disabled"]),
        },
    }


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
            "img-src 'self' data: blob:; connect-src 'self' https://api.ipify.org https://api6.ipify.org; object-src 'none'; "
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
        compressed = False
        if "gzip" in (self.headers.get("Accept-Encoding") or "").lower() and not ctype.startswith("image/") and len(data) >= 1024:
            packed = gzip.compress(data, compresslevel=6, mtime=0)
            if len(packed) < len(data):
                data = packed
                compressed = True
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        if compressed:
            self.send_header("Content-Encoding", "gzip")
            self.send_header("Vary", "Accept-Encoding")
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
            static = STATIC_FILES.get(u.path)
            if static is None:
                self.send_error(404)
                return
            filename, ctype = static
            path = WEB_DIR / filename
            try:
                size = path.stat().st_size
            except OSError:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(size))
            self.send_security_headers()
            self.send_header("Cache-Control", "no-store")
            self.finish_response_headers()
            return
        if u.path.startswith("/api/nettest-public/"):
            if not is_vpn_internal_nettest(self):
                self.send_error(HTTPStatus.FORBIDDEN)
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", "0")
            self.send_security_headers()
            self.finish_response_headers()
            return
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
            host = f"{configured_vpn_ipv4()[0]}:{os.environ.get('AWG_WEB_PORT', '8443')}"
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
            "required_hosts": web_access_required_hosts(split_host(raw_host)),
            "certificate": web_cert_status(),
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

    def _handle_vpn_nettest_get(self, u):
        vpn_ip = vpn_client_ip_from_handler(self)
        if not check_rate_limit(vpn_ip or self.client_address[0]):
            self.send_api_error(HTTPStatus.TOO_MANY_REQUESTS, "rate_limited")
            return
        query = parse_qs(u.query)
        stub = {"role": "vpn_anon", "hash": hashlib.sha256((vpn_ip or "").encode()).hexdigest()[:8]}
        if u.path == "/api/nettest-public/context":
            self.send_json(nettest_context_payload())
            return
        if u.path == "/api/nettest-public/ping":
            nonce = str((query.get("n") or [""])[0])[:64]
            force = (query.get("force") or [""])[0] in ("1", "true", "yes")
            try:
                test_id = clean_nettest_id((query.get("test_id") or [""])[0])
            except ValueError as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            if test_id and not reserve_nettest_session(stub, vpn_ip, test_id, force=force):
                self.send_json({"error": "nettest already active"}, HTTPStatus.TOO_MANY_REQUESTS)
                return
            self.send_json({"ok": True, "server_time": utc_now_iso(), "nonce": nonce, "vpn_client_ip": vpn_ip})
            return
        if u.path == "/api/nettest-public/download":
            try:
                test_id = clean_nettest_id((query.get("test_id") or [""])[0])
            except ValueError as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            if test_id and not reserve_nettest_session(stub, vpn_ip, test_id):
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
        self.send_error(404)

    def _handle_vpn_nettest_post(self, u):
        vpn_ip = vpn_client_ip_from_handler(self)
        if not check_rate_limit(vpn_ip or self.client_address[0]):
            self.send_api_error(HTTPStatus.TOO_MANY_REQUESTS, "rate_limited")
            return
        stub = {"role": "vpn_anon", "hash": hashlib.sha256((vpn_ip or "").encode()).hexdigest()[:8]}
        if u.path == "/api/nettest-public/upload":
            try:
                test_id = clean_nettest_id(self.headers.get("X-Nettest-Id", ""))
            except ValueError:
                test_id = ""
            if test_id and not reserve_nettest_session(stub, vpn_ip, test_id):
                self.send_json({"error": "nettest already active"}, HTTPStatus.TOO_MANY_REQUESTS)
                return
            try:
                size = int(self.headers.get("Content-Length", "0") or 0)
            except (TypeError, ValueError):
                size = 0
            if size < 0 or size > NETTEST_MAX_UPLOAD_SIZE:
                self.send_error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
                return
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
        if u.path == "/api/nettest-public/report":
            try:
                body = json_body_from_handler(self, NETTEST_MAX_REPORT_JSON)
            except ValueError as exc:
                if str(exc) == "payload too large":
                    return
                self.send_json({"error": str(exc)}, 400)
                return
            try:
                self.send_json(save_nettest_report_vpn(self, body))
            except ValueError as exc:
                if str(exc) == "nettest report rate limited":
                    self.send_json({"error": "rate limited"}, HTTPStatus.TOO_MANY_REQUESTS)
                    return
                self.send_json({"error": str(exc)}, 400)
            return
        if u.path == "/api/nettest-public/cancel":
            try:
                body = json_body_from_handler(self, 1024)
            except ValueError as exc:
                if str(exc) == "payload too large":
                    return
                self.send_json({"error": str(exc)}, 400)
                return
            try:
                test_id = clean_nettest_id(body.get("test_id", ""))
            except ValueError as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            if test_id and clear_nettest_session(stub, vpn_ip, test_id):
                audit_log(f"nettest: cancelled by client vpn_ip={vpn_ip} test_id={test_id}")
            self.send_json({"ok": True})
            return
        self.send_error(404)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path.startswith("/api/nettest-public/"):
            if not is_vpn_internal_nettest(self):
                self.send_api_error(HTTPStatus.FORBIDDEN, "forbidden")
                return
            self._handle_vpn_nettest_get(u)
            return
        auth = self.api_auth()
        if auth is None:
            return
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
                "version": PROJECT_VERSION,
                "fork": "fork delta/patchset",
                "role": "super" if self.is_super(auth) else "user",
                "server_name": cfg["AWG_SERVER_NAME"],
                "display_name": cfg["AWG_SERVER_NAME"],
                "title": PANEL_TITLE,
                "short_label": PANEL_SHORT_LABEL,
                "repository_url": REPOSITORY_URL,
            })
            return
        if u.path == "/api/project-update":
            if not self.require_super(auth):
                return
            self.send_json(project_update_status())
            return
        if u.path == "/api/bot/snapshot":
            self.send_json(bot_snapshot_payload(auth))
            return
        if u.path == "/api/server-info":
            self.send_json(server_info_payload())
            return
        if u.path == "/api/server-health":
            if not self.require_super(auth):
                return
            health = json.loads(json.dumps(collect_server_health()))
            client_ctx = request_client_context(self)
            edge = web_access_edge_info(load_access_policy(), self.headers, client_ctx.get("trusted_proxy_used"))
            edge_status = "ok" if edge.get("mode") != "nginx_reverse_proxy" else ("ok" if client_ctx.get("trusted_proxy_used") else "unknown")
            health.setdefault("services", {})["web_edge"] = {
                "status": edge_status,
                "mode": edge.get("mode"),
                "label": edge.get("label"),
                "listener": edge.get("public_listener"),
            }
            health.setdefault("services", {}).setdefault("nginx_edge", {})["status"] = edge_status
            health["request"] = {
                "host": split_host(self.headers.get("Host", "")),
                "client_ip": client_ctx.get("client_ip"),
                "socket_remote_ip": client_ctx.get("socket_remote_ip"),
                "proxy_ip": client_ctx.get("proxy_ip"),
                "trusted_proxy_used": bool(client_ctx.get("trusted_proxy_used")),
            }
            self.send_json(health)
            return
        if u.path == "/api/server-health/history":
            if not self.require_super(auth):
                return
            query = parse_qs(u.query)
            range_key = str((query.get("range") or ["1h"])[0])
            try:
                self.send_json(server_health_history(range_key))
            except ValueError as exc:
                self.send_json({"error": str(exc)}, 400)
            return
        if u.path == "/api/provider-traffic":
            if not self.require_super(auth):
                return
            query = parse_qs(u.query)
            force = (query.get("refresh") or [""])[0] in {"1", "true", "yes"}
            self.send_json(provider_traffic_payload(force=force))
            return
        if u.path == "/api/vpn-readiness":
            if not self.require_super(auth):
                return
            self.send_json(vpn_readiness_payload())
            return
        if u.path == "/api/nettest/context":
            self.send_json(nettest_context_payload())
            return
        if u.path == "/api/nettest/ping":
            query = parse_qs(u.query)
            nonce = str((query.get("n") or [""])[0])[:64]
            force = (query.get("force") or [""])[0] in ("1", "true", "yes")
            try:
                test_id = clean_nettest_id((query.get("test_id") or [""])[0])
            except ValueError as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            client_ctx = request_client_context(self)
            if test_id and not reserve_nettest_session(auth, client_ctx.get("client_ip"), test_id, force=force):
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
        if u.path == "/api/geoip/status":
            if not self.require_super(auth):
                return
            self.send_json(geoip_providers_status())
            return
        if u.path == "/api/geoip/providers":
            if not self.require_super(auth):
                return
            self.send_json(geoip_providers_config_for_admin())
            return
        if u.path == "/api/geoip/databases/status":
            if not self.require_super(auth):
                return
            self.send_json(geoip_databases_status())
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
        if u.path == "/api/clients/latency":
            if not self.require_super(auth):
                return
            query = parse_qs(u.query)
            force = (query.get("refresh") or query.get("force") or [""])[0] in ("1", "true", "yes")
            self.send_json(client_latency_payload(force=force))
            return
        if u.path == "/api/clients":
            stats = client_stats_map()
            endpoint_history = record_client_endpoint_history(parse_peers(), stats)
            history_clients = endpoint_history.get("clients", {}) if isinstance(endpoint_history, dict) else {}
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
                endpoint_snapshot = latest_client_endpoint_snapshot(history_clients.get(peer["name"], []))
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
                item["latestHandshakeAt"] = row_stats.get(
                    "latestHandshakeAt",
                    row_stats.get("last_handshake", endpoint_snapshot.get("latest_handshake", 0)),
                )
                endpoint = row_stats.get("endpoint", "")
                if endpoint in {"", "-", "(none)", "none"} and endpoint_snapshot:
                    endpoint_ip = endpoint_snapshot.get("endpoint_ip", "")
                    endpoint_port = endpoint_snapshot.get("endpoint_port", "")
                    endpoint = f"{endpoint_ip}:{endpoint_port}" if endpoint_ip and endpoint_port else endpoint_ip
                item["endpoint"] = "" if endpoint in {"", "-", "(none)", "none"} else endpoint
                endpoint_ip, endpoint_port = split_endpoint(item["endpoint"])
                item["endpoint_ip"] = endpoint_ip
                item["endpoint_port"] = endpoint_port
                item["public_key_fp"] = public_key_fingerprint(peer.get("public_key", ""))
                item["shared_profile"] = shared_profile_detection(history_clients.get(peer["name"], []))
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
        if u.path == "/api/web-cert":
            if not self.require_super(auth):
                return
            self.send_json({"ok": True, "certificate": web_cert_status()})
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
        u = urlparse(self.path)
        if u.path.startswith("/api/nettest-public/"):
            if not is_vpn_internal_nettest(self):
                self.send_api_error(HTTPStatus.FORBIDDEN, "forbidden")
                return
            self._handle_vpn_nettest_post(u)
            return
        auth = self.api_auth()
        if auth is None:
            return
        try:
            if u.path == "/api/project-update/check":
                if not self.require_super(auth):
                    return
                try:
                    self.send_json(start_project_update("check"), HTTPStatus.ACCEPTED)
                except RuntimeError as exc:
                    self.send_json({"error": str(exc)}, HTTPStatus.CONFLICT)
                return
            if u.path == "/api/project-update/apply":
                if not self.require_super(auth):
                    return
                body = json_body_from_handler(self, 1024)
                if body.get("confirm") != "UPDATE PROJECT":
                    self.send_json({"error": "confirmation required"}, HTTPStatus.BAD_REQUEST)
                    return
                try:
                    self.send_json(start_project_update("apply"), HTTPStatus.ACCEPTED)
                except RuntimeError as exc:
                    self.send_json({"error": str(exc)}, HTTPStatus.CONFLICT)
                return
            if u.path == "/api/clients/path-check":
                if not self.require_super(auth):
                    return
                try:
                    body = json_body_from_handler(self, 1024)
                    self.send_json(batch_client_path_check(str(body.get("target") or "endpoint"), str(body.get("scope") or "active")))
                except ValueError as exc:
                    self.send_json({"error": str(exc)}, HTTPStatus.BAD_REQUEST)
                return
            m = re.match(r"^/api/clients/([^/]+)/path-check$", u.path)
            if m:
                if not self.require_super(auth):
                    return
                try:
                    body = json_body_from_handler(self, 1024)
                    self.send_json(client_path_check(unquote(m.group(1)), str(body.get("target") or "endpoint")))
                except ValueError as exc:
                    self.send_json({"error": str(exc)}, HTTPStatus.BAD_REQUEST)
                return
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
            if u.path == "/api/nettest/cancel":
                body = json_body_from_handler(self, 1024)
                test_id = clean_nettest_id(body.get("test_id", ""))
                client_ctx = request_client_context(self)
                if test_id and clear_nettest_session(auth, client_ctx.get("client_ip"), test_id):
                    audit_log(f"nettest: cancelled by client actor_fp={auth_fingerprint(auth)} test_id={test_id}")
                self.send_json({"ok": True})
                return
            if u.path == "/api/server-health/drops-sample":
                if not self.require_super(auth):
                    return
                body = json_body_from_handler(self, 1024)
                try:
                    duration = int(body.get("duration_seconds", 60))
                except (TypeError, ValueError):
                    duration = 60
                duration = max(1, min(60, duration))
                before = raw_drop_counters()
                time.sleep(duration)
                after = raw_drop_counters()
                self.send_json(drops_sample_report(before, after, duration))
                return
            if u.path == "/api/server/reboot":
                if not self.require_super(auth):
                    return
                body = json_body_from_handler(self, 1024)
                if body.get("confirm") != "REBOOT":
                    self.send_json({"error": "confirmation required"}, HTTPStatus.BAD_REQUEST)
                    return
                schedule_server_reboot(auth)
                self.send_json({"ok": True, "scheduled": True})
                return
            if u.path == "/api/geoip/refresh":
                if not self.require_super(auth):
                    return
                body = json_body_from_handler(self, 1024)
                raw_ip = str(body.get("ip") or "").strip()
                try:
                    validated_ip = str(ipaddress.ip_address(raw_ip))
                except ValueError:
                    self.send_json({"error": "invalid ip"}, 400)
                    return
                if _is_private_endpoint_ip(validated_ip):
                    self.send_json({"error": "private/reserved ip"}, 400)
                    return
                with IP_INFO_CACHE_LOCK:
                    cache = load_ip_info_cache()
                    if validated_ip in cache:
                        del cache[validated_ip]
                    try:
                        write_ip_info_cache(cache)
                    except Exception:
                        pass
                info = lookup_ip_enriched(validated_ip, multi_source=True, force_refresh=True, want_whois=True)
                self.send_json({"ok": True, "ip": validated_ip, "info": info})
                return
            if u.path == "/api/geoip/providers/test":
                if not self.require_super(auth):
                    return
                body = json_body_from_handler(self, 1024)
                name = str(body.get("provider") or "").strip()
                if name not in GEOIP_PROVIDER_NAMES:
                    self.send_json({"error": "unknown provider"}, 400)
                    return
                self.send_json(geoip_test_provider(name))
                return
            if u.path == "/api/geoip/databases/update":
                if not self.require_super(auth):
                    return
                p = run_manage("geoip", "update-dbs", timeout=300)
                if p.returncode == 0:
                    self.send_json({"ok": True, "message": "GeoIP databases updated", "stdout": p.stdout, **geoip_databases_status()})
                    return
                self.send_json({"error": "geoip update-dbs failed", "stdout": p.stdout, "stderr": p.stderr, **geoip_databases_status()}, 500)
                return
            if u.path == "/api/geoip/auto-update":
                if not self.require_super(auth):
                    return
                body = json_body_from_handler(self, 1024)
                enable = bool(body.get("enabled"))
                action = "enable" if enable else "disable"
                p = run_manage("geoip", "auto-update", action, timeout=60)
                if p.returncode == 0:
                    self.send_json({"ok": True, "auto_update": geoip_auto_update_timer_status()})
                    return
                self.send_json({"error": f"geoip auto-update {action} failed", "stderr": p.stderr}, 500)
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
            elif u.path == "/api/ipv6/ndp/generate":
                if not self.require_super(auth):
                    return
                cfg = parse_config()
                prefix = body.get("prefix") or cfg.get("AWG_IPV6_SUBNET") or ""
                try:
                    prefix = validate_ipv6_prefix(prefix)
                except ValueError as exc:
                    self.send_json({"error": str(exc)}, 400)
                    return
                p = run_manage("ipv6", "ndp", "generate", prefix, timeout=60)
                if p.returncode == 0:
                    self.send_json({"ok": True, "prefix": prefix, "message": "ndppd config generated"})
                    return
                self.send_json({"error": "ndp generate failed", "stderr": p.stderr}, 500)
                return
            elif u.path == "/api/ipv6/ndp/enable":
                if not self.require_super(auth):
                    return
                p = run_manage("ipv6", "ndp", "enable", timeout=180)
                if p.returncode == 0:
                    self.send_json({"ok": True, "message": "ndppd enabled"})
                    return
                self.send_json({"error": "ndp enable failed", "stderr": p.stderr}, 500)
                return
            elif u.path == "/api/ipv6/ndp/disable":
                if not self.require_super(auth):
                    return
                p = run_manage("ipv6", "ndp", "disable", timeout=60)
                if p.returncode == 0:
                    self.send_json({"ok": True, "message": "ndppd disabled"})
                    return
                self.send_json({"error": "ndp disable failed", "stderr": p.stderr}, 500)
                return
            elif u.path == "/api/ipv6/ndp/restart":
                if not self.require_super(auth):
                    return
                p = run_manage("ipv6", "ndp", "restart", timeout=60)
                if p.returncode == 0:
                    self.send_json({"ok": True, "message": "ndppd restarted"})
                    return
                self.send_json({"error": "ndp restart failed", "stderr": p.stderr}, 500)
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
            elif u.path == "/api/web-cert/install-custom":
                if not self.require_super(auth):
                    return
                cert_path = str(body.get("cert_path") or "").strip()
                key_path = str(body.get("key_path") or "").strip()
                result = install_custom_web_certificate(cert_path, key_path)
                restart_web_panel_later()
                self.send_json(result)
                return
            elif u.path == "/api/web-cert/renew":
                if not self.require_super(auth):
                    return
                result = renew_web_certificate()
                self.send_json(result)
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
            if u.path == "/api/geoip/providers":
                if not self.require_super(auth):
                    return
                body = self.json_body()
                write_geoip_providers_config(body)
                self.send_json({"ok": True, **geoip_providers_config_for_admin()})
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
            m = re.match(r"^/api/nettest/reports/([^/]+)$", u.path)
            if m:
                if not self.require_super(auth):
                    return
                filename = m.group(1)
                try:
                    deleted = delete_nettest_report(filename)
                except ValueError as exc:
                    self.send_json({"error": str(exc)}, 400)
                    return
                if not deleted:
                    self.send_json({"error": "report not found"}, 404)
                    return
                audit_log(f"Deleted network test report filename={filename} actor_role={auth.get('role')} actor_fp={auth_fingerprint(auth)}")
                self.send_json({"ok": True})
                return
            if u.path == "/api/nettest/reports":
                if not self.require_super(auth):
                    return
                body = self.json_body()
                if body.get("confirm") != "DELETE ALL NETTEST REPORTS":
                    self.send_json({"error": "confirmation required"}, 400)
                    return
                count = delete_all_nettest_reports()
                audit_log(f"Deleted all network test reports count={count} actor_role={auth.get('role')} actor_fp={auth_fingerprint(auth)}")
                self.send_json({"ok": True, "deleted": count})
                return
            if u.path == "/api/server-health/history":
                if not self.require_super(auth):
                    return
                body = self.json_body()
                if body.get("confirm") != "CLEAR LOAD STATISTICS":
                    self.send_json({"error": "confirmation required"}, 400)
                    return
                count = clear_health_history()
                audit_log(f"Cleared server load statistics files={count} actor_role={auth.get('role')} actor_fp={auth_fingerprint(auth)}")
                self.send_json({"ok": True, "deleted": count})
                return
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
    start_server_health_collector()
    os.chdir(WEB_DIR)
    bind_host = policy.get("bind_host") or os.environ.get("AWG_WEB_BIND") or configured_vpn_ipv4()[0]
    httpd = LimitedThreadingHTTPServer((bind_host, int(os.environ.get("AWG_WEB_PORT", "8443"))), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(WEB_DIR / "cert.pem", WEB_DIR / "key.pem")
    httpd.ssl_context = ctx
    httpd.serve_forever()


if __name__ == "__main__":
    main()
