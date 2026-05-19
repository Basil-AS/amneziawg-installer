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
from urllib.parse import parse_qs, quote, unquote, urlparse

AWG_DIR = Path(os.environ.get("AWG_DIR", "/root/awg"))
WEB_DIR = AWG_DIR / "web"
MANAGE = AWG_DIR / "manage_amneziawg.sh"
SERVER_CONF = Path(os.environ.get("SERVER_CONF_FILE", "/etc/amnezia/amneziawg/awg0.conf"))
TOKEN_FILE = WEB_DIR / "tokens.json"
IMPORT_TOKEN_FILE = WEB_DIR / "import_tokens.json"
TRAFFIC_FILE = WEB_DIR / "traffic_history.json"
LEGACY_TOKEN_FILE = WEB_DIR / "auth_token"
NAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")
TOKEN_HASH_RE = re.compile(r"^[0-9a-f]{64}$")
RAW_IMPORT_TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{32,256}$")
STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/style.css": ("style.css", "text/css; charset=utf-8"),
    "/app.js": ("app.js", "application/javascript; charset=utf-8"),
    "/favicon.svg": ("favicon.svg", "image/svg+xml"),
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
TRAFFIC_LOCK = threading.Lock()
SERVER_NAME_RE = re.compile(r"^[\w .,!?\-()]{1,128}$", re.UNICODE)
DELETED_TRAFFIC_KEY = "_deleted_clients_total"


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


def require_import_ttl(value):
    if value is None:
        return 3600
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError("invalid ttl")
    if value < 60 or value > 604800:
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


def clean_token_name(value):
    if not isinstance(value, str):
        return ""
    value = value.strip()
    if "\n" in value or "\r" in value or len(value) > 128:
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
    request_queue_size = 32

    def __init__(self, *args, max_workers=16, **kwargs):
        super().__init__(*args, **kwargs)
        self._sem = threading.BoundedSemaphore(max_workers)
        self.socket.settimeout(10)

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

    def api_auth(self):
        if not self.path.startswith("/api/"):
            return {"role": "static"}
        ip = self.client_address[0]
        if not check_rate_limit(ip):
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
        self.send_security_headers()
        self.end_headers()
        self.wfile.write(data)

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
        self.end_headers()
        self.wfile.write(data)

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
        self.end_headers()
        self.wfile.write(data)

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
        self.end_headers()
        self.wfile.write(body)

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

    def create_import_link(self, auth, name, body):
        name = safe_name(name)
        if not self.require_client_access(auth, name):
            return
        path = AWG_DIR / f"{name}.conf"
        if not path.exists() or not path.is_file():
            self.send_json({"error": "client config not found"}, 404)
            return
        ttl = require_import_ttl(body.get("ttl"))
        one_time = body.get("one_time", False)
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
            })
            return
        if u.path == "/api/dns":
            self.send_json(dns_status())
            return
        if u.path == "/api/clients":
            stats = client_stats_map()
            history = load_traffic_history()
            visible = self.visible_peers(auth)
            rows = []
            for peer in visible:
                item = dict(peer)
                row_stats = stats.get(peer["name"], {})
                item["rx"] = row_stats.get("rx", 0)
                item["tx"] = row_stats.get("tx", 0)
                item["traffic_30d"] = client_traffic_30d(peer["name"], history)
                item["traffic_total"] = client_traffic_total(peer["name"], history)
                item["latestHandshakeAt"] = row_stats.get("latestHandshakeAt", row_stats.get("last_handshake", 0))
                endpoint = row_stats.get("endpoint", "")
                item["endpoint"] = "" if endpoint in {"", "-", "(none)", "none"} else endpoint
                item["status"] = row_stats.get("status", "")
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
                if not self.require_super(auth):
                    return
                name = safe_name(body.get("name", ""))
                args = []
                if body.get("expires"):
                    args.append(f"--expires={require_expires(body['expires'])}")
                p = run_manage(*args, "add", name)
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
                    args.append(require_dns_list(custom))
                p = run_manage(*args, timeout=120)
            elif u.path == "/api/tokens":
                if not self.require_super(auth):
                    return
                clients = clean_client_list(body.get("clients", []))
                token = secrets.token_urlsafe(32)
                digest = token_hash(token)
                with TOKENS_LOCK:
                    data = load_tokens()
                    data.setdefault("users", {})[digest] = {"name": "", "clients": clients}
                    write_tokens(data)
                self.send_json({"token": token, "token_hash": digest, "name": "", "clients": clients})
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
            else:
                import_link = re.match(r"^/api/clients/([^/]+)/import-link$", u.path)
                if import_link:
                    self.create_import_link(auth, unquote(import_link.group(1)), body)
                    return
                m = re.match(r"^/api/clients/([^/]+)/(p2p|toggle)$", u.path)
                p2p_toggle = re.match(r"^/api/clients/([^/]+)/p2p/toggle$", u.path)
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
            m = re.match(r"^/api/tokens/([^/]+)/name$", u.path)
            if not m:
                self.send_error(404)
                return
            if not self.require_super(auth):
                return
            digest = safe_token_hash(m.group(1))
            body = self.json_body()
            name = clean_token_name(body.get("name", ""))
            with TOKENS_LOCK:
                data = load_tokens()
                if digest not in data.get("users", {}):
                    self.send_json({"error": "token not found"}, 404)
                    return
                record = clean_user_record(data["users"][digest])
                record["name"] = name
                data["users"][digest] = record
                write_tokens(data)
            self.send_json({"ok": True, "hash": digest, "name": name, "clients": record["clients"]})
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
    os.chdir(WEB_DIR)
    httpd = LimitedThreadingHTTPServer((os.environ.get("AWG_WEB_BIND") or "10.9.9.1", int(os.environ.get("AWG_WEB_PORT", "8443"))), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(WEB_DIR / "cert.pem", WEB_DIR / "key.pem")
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
