#!/usr/bin/env python3
"""
threat-reporter.py - Multi-Provider Kernel Threat Reporter Daemon
Monitors in-kernel nftables logs (THREAT_*) and reports malicious actors
to AbuseIPDB, 2ip.io, and Spamhaus with deduplication and rate limiting.
"""

import collections
import datetime
import ipaddress
import json
import os
import re
import signal
import socket
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CONF_PATH = os.environ.get("THREAT_REPORTER_CONF", "/etc/threat-reporter/config.json")
DB_PATH = os.environ.get("THREAT_REPORTER_DB", "/var/lib/threat-reporter/reported.db")
LOG_PATH = os.environ.get("THREAT_REPORTER_LOG", "/var/log/threat-reporter.log")

SERVICE_NAMES = {
    21: "FTP",
    22: "SSH",
    23: "Telnet",
    25: "SMTP",
    53: "DNS",
    80: "HTTP",
    110: "POP3",
    143: "IMAP",
    443: "HTTPS",
    445: "SMB",
    1433: "MSSQL",
    1521: "Oracle",
    3306: "MySQL",
    3389: "RDP",
    5432: "PostgreSQL",
    5900: "VNC",
    6379: "Redis",
    8080: "HTTP-Alt",
    8443: "HTTPS-Alt",
    9056: "Tor-Alt",
    12121: "SSH",
}

ABUSEIPDB_CATEGORIES = {
    "THREAT_HONEYPOT": "14",      # Port Scan / Unauthorized probe
    "THREAT_PORTSCAN": "14",      # Port Scan
    "THREAT_SSH_BRUTE": "18,22",  # Brute-Force, SSH
    "THREAT_FLOOD": "4",          # DDoS Attack
    "THREAT_QUIC_FLOOD": "4",     # DDoS Attack
}

TWOIP_TYPES = {
    "THREAT_HONEYPOT": 6,          # Port scan / probe
    "THREAT_PORTSCAN": 6,          # Port scan / probe
    "THREAT_SSH_BRUTE": 2,         # Brute-force
    "THREAT_FLOOD": 5,             # DoS / Flood
    "THREAT_QUIC_FLOOD": 5,        # DoS / Flood
}


class RateLimiter:
    """Sliding-window rate limiter for outbound API calls."""

    def __init__(self, max_per_minute=5):
        self.max_per_minute = max(1, max_per_minute)
        self.timestamps = collections.deque()

    def acquire(self):
        now = time.time()
        while self.timestamps and self.timestamps[0] <= now - 60.0:
            self.timestamps.popleft()
        if len(self.timestamps) >= self.max_per_minute:
            sleep_time = (self.timestamps[0] + 60.0) - now + 0.1
            if sleep_time > 0:
                time.sleep(sleep_time)
            now = time.time()
            while self.timestamps and self.timestamps[0] <= now - 60.0:
                self.timestamps.popleft()
        self.timestamps.append(time.time())


def log_msg(msg):
    print(msg, flush=True)
    if LOG_PATH:
        try:
            with open(LOG_PATH, "a", encoding="utf-8") as f:
                f.write(msg + "\n")
        except Exception:
            pass


def get_service_name(proto, port):
    if port in SERVICE_NAMES:
        return SERVICE_NAMES[port]
    try:
        return socket.getservbyport(port, proto.lower()).upper()
    except (OSError, OverflowError):
        return None


def get_target_str(proto, port):
    svc = get_service_name(proto, port)
    if svc:
        return f"{proto}/{port} ({svc})"
    return f"{proto}/{port}"


def load_config():
    default_conf = {
        "api_keys": {
            "abuseipdb": "",
            "twoip": "",
            "spamhaus": "",
        },
        "dedup_window_seconds": 86400,
        "rate_limit_reports_per_minute": 5,
    }

    if os.path.exists(CONF_PATH):
        try:
            with open(CONF_PATH, "r", encoding="utf-8") as f:
                user_conf = json.load(f)
                if isinstance(user_conf, dict):
                    api_keys = default_conf["api_keys"].copy()
                    if isinstance(user_conf.get("api_keys"), dict):
                        api_keys.update(user_conf["api_keys"])
                    default_conf["api_keys"] = api_keys
                    if "dedup_window_seconds" in user_conf:
                        default_conf["dedup_window_seconds"] = int(user_conf["dedup_window_seconds"])
                    if "rate_limit_reports_per_minute" in user_conf:
                        default_conf["rate_limit_reports_per_minute"] = int(user_conf["rate_limit_reports_per_minute"])
        except Exception as exc:
            now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            log_msg(f"[{now_str}] Warning: Error reading config {CONF_PATH}: {exc}")
    return default_conf


def init_db(db_path):
    os.makedirs(os.path.dirname(db_path), exist_ok=True)
    conn = sqlite3.connect(db_path)
    with conn:
        cur = conn.cursor()
        cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='reports'")
        if cur.fetchone():
            cur.execute("PRAGMA table_info(reports)")
            cols = [col[1] for col in cur.fetchall()]
            if "provider" not in cols:
                conn.execute("DROP TABLE reports")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS reports (
                ip TEXT,
                provider TEXT,
                threat_type TEXT,
                last_reported_at INTEGER,
                report_count INTEGER DEFAULT 1,
                PRIMARY KEY (ip, provider)
            )
        """)
        conn.execute("CREATE INDEX IF NOT EXISTS idx_reports_time ON reports(last_reported_at)")
    return conn


def is_global_ip(ip_str):
    try:
        ip_obj = ipaddress.ip_address(ip_str)
        if not ip_obj.is_global or ip_obj.is_private or ip_obj.is_loopback or ip_obj.is_reserved or ip_obj.is_multicast:
            return False, "non-global/private IP"
        return True, ""
    except ValueError:
        return False, "invalid IP format"


def can_report_ip(conn, ip_str, provider, dedup_window):
    now = int(time.time())
    cur = conn.cursor()
    cur.execute("SELECT last_reported_at FROM reports WHERE ip = ? AND provider = ?", (ip_str, provider))
    row = cur.fetchone()
    if row:
        last_time = row[0]
        if now - last_time < dedup_window:
            return False, f"already reported to {provider} within last {dedup_window}s"
    return True, ""


def record_report(conn, ip_str, provider, threat_type):
    now = int(time.time())
    with conn:
        conn.execute("""
            INSERT INTO reports (ip, provider, threat_type, last_reported_at, report_count)
            VALUES (?, ?, ?, ?, 1)
            ON CONFLICT(ip, provider) DO UPDATE SET
                threat_type = excluded.threat_type,
                last_reported_at = excluded.last_reported_at,
                report_count = report_count + 1
        """, (ip_str, provider, threat_type, now))


def build_abuseipdb_comment(threat_type, ip_str, proto, port, target_str, ts_utc):
    if threat_type == "THREAT_HONEYPOT":
        event = "Unauthorized Port Probe"
    elif threat_type == "THREAT_PORTSCAN":
        event = "Network Port Scan Sweep"
    elif threat_type == "THREAT_SSH_BRUTE":
        event = "SSH Service Brute-Force Attack"
    elif threat_type in ("THREAT_FLOOD", "THREAT_QUIC_FLOOD"):
        event = "Connection Flood / Denial of Service"
    else:
        event = "Unauthorized Network Activity"

    return (
        f"Event: {event}\n"
        f"Target: {target_str}\n"
        f"Observed: {ts_utc}\n"
        f"Evidence: SRC={ip_str} PROTO={proto} DPT={port}"
    )


def build_twoip_comment(threat_type, target_str):
    if threat_type == "THREAT_HONEYPOT":
        return f"Unauthorized port probe targeting port {target_str}"
    elif threat_type == "THREAT_PORTSCAN":
        return f"Network port scan sweep probing port {target_str}"
    elif threat_type == "THREAT_SSH_BRUTE":
        return f"SSH brute-force attack targeting port {target_str}"
    elif threat_type in ("THREAT_FLOOD", "THREAT_QUIC_FLOOD"):
        return f"Connection flood / denial of service targeting port {target_str}"
    return f"Unauthorized network threat targeting port {target_str}"


def build_spamhaus_reason(threat_type, target_str):
    if threat_type in ("THREAT_HONEYPOT", "THREAT_PORTSCAN"):
        return f"Unauthorized automated network probe targeting {target_str}."
    elif threat_type == "THREAT_SSH_BRUTE":
        return f"SSH brute-force attack targeting {target_str}."
    elif threat_type in ("THREAT_FLOOD", "THREAT_QUIC_FLOOD"):
        return f"Denial of service connection flood targeting {target_str}."
    return f"Unauthorized automated network probe targeting {target_str}."


def report_abuseipdb(api_key, ip_str, threat_type, proto, port, target_str, ts_utc):
    url = "https://api.abuseipdb.com/api/v2/report"
    categories = ABUSEIPDB_CATEGORIES.get(threat_type, "14")
    comment = build_abuseipdb_comment(threat_type, ip_str, proto, port, target_str, ts_utc)
    payload = urllib.parse.urlencode({
        "ip": ip_str,
        "categories": categories,
        "comment": comment,
    }).encode("utf-8")

    req = urllib.request.Request(
        url,
        data=payload,
        headers={
            "Key": api_key,
            "Accept": "application/json",
            "User-Agent": "Antigravity-ThreatReporter/1.0",
        },
        method="POST",
    )

    with urllib.request.urlopen(req, timeout=12) as resp:
        return resp.status


def report_twoip(token, ip_str, threat_type, target_str):
    url = f"https://api.2ip.io/abuse?token={urllib.parse.quote(token)}"
    attack_type = TWOIP_TYPES.get(threat_type, 6)
    comment = build_twoip_comment(threat_type, target_str)
    payload = urllib.parse.urlencode({
        "ips": ip_str,
        "type": str(attack_type),
        "comment": comment,
    }).encode("utf-8")

    req = urllib.request.Request(
        url,
        data=payload,
        headers={
            "Accept": "application/json",
            "User-Agent": "Antigravity-ThreatReporter/1.0",
        },
        method="POST",
    )

    with urllib.request.urlopen(req, timeout=12) as resp:
        return resp.status


def report_spamhaus(token, ip_str, threat_type, target_str):
    url = "https://submit.spamhaus.org/portal/api/v1/submissions/add/ip"
    reason = build_spamhaus_reason(threat_type, target_str)
    payload = json.dumps({
        "threat_type": "attack",
        "reason": reason,
        "source": {
            "object": ip_str,
        },
    }).encode("utf-8")

    req = urllib.request.Request(
        url,
        data=payload,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "Antigravity-ThreatReporter/1.0",
        },
        method="POST",
    )

    with urllib.request.urlopen(req, timeout=12) as resp:
        return resp.status


def main():
    conn = init_db(DB_PATH)
    now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    log_msg(f"[{now_str}] Threat reporter daemon initialized. DB: {DB_PATH}")

    # Regex extracts: threat_type, iface, src_ip, dst_ip, proto, port
    pattern = re.compile(
        r"(THREAT_\w+):\s+IN=(\S*).*?SRC=([0-9a-fA-F\.:]+)\s+DST=([0-9a-fA-F\.:]+).*?PROTO=(\w+).*?DPT=(\d+)"
    )

    cmd = ["journalctl", "-k", "-f", "-o", "cat"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)

    def sig_handler(sig, frame):
        ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        log_msg(f"[{ts}] Termination signal received. Exiting.")
        proc.terminate()
        sys.exit(0)

    signal.signal(signal.SIGINT, sig_handler)
    signal.signal(signal.SIGTERM, sig_handler)

    cfg = load_config()
    rate_limiter = RateLimiter(cfg.get("rate_limit_reports_per_minute", 5))
    last_cfg_check = time.time()

    active_providers = [k for k, v in cfg["api_keys"].items() if v]
    if active_providers:
        log_msg(f"[{now_str}] Threat reporting ACTIVE for providers: {', '.join(active_providers)}")
    else:
        log_msg(f"[{now_str}] No API keys found in {CONF_PATH}. Running in standby mode (logging threats only).")

    for line in proc.stdout:
        if time.time() - last_cfg_check > 30:
            cfg = load_config()
            rate_limiter.max_per_minute = cfg.get("rate_limit_reports_per_minute", 5)
            last_cfg_check = time.time()

        m = pattern.search(line)
        if not m:
            continue

        threat_type = m.group(1)
        iface = m.group(2) or "eth0"
        ip_str = m.group(3)
        dst_ip = m.group(4)
        proto = m.group(5).upper()
        port = int(m.group(6))

        ok_ip, _ = is_global_ip(ip_str)
        if not ok_ip:
            continue

        abuse_key = cfg["api_keys"].get("abuseipdb", "").strip()
        twoip_token = cfg["api_keys"].get("twoip", "").strip()
        spamhaus_token = cfg["api_keys"].get("spamhaus", "").strip()

        dedup = cfg["dedup_window_seconds"]
        can_abuse = abuse_key and can_report_ip(conn, ip_str, "abuseipdb", dedup)[0]
        can_twoip = twoip_token and can_report_ip(conn, ip_str, "twoip", dedup)[0]
        can_spamhaus = spamhaus_token and can_report_ip(conn, ip_str, "spamhaus", dedup)[0]

        if not (can_abuse or can_twoip or can_spamhaus):
            continue

        attack_short = threat_type.replace("THREAT_", "")
        target_str = get_target_str(proto, port)
        ts_local = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        ts_utc = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

        log_msg(f"[{ts_local}] Dispatching forensic abuse reports for IP={ip_str} (attack={attack_short}, iface={iface}, bind_ip={dst_ip}, target={proto}/{port})")

        # Provider 1: AbuseIPDB
        if can_abuse:
            rate_limiter.acquire()
            ts_report = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            try:
                code = report_abuseipdb(abuse_key, ip_str, threat_type, proto, port, target_str, ts_utc)
                log_msg(f"[{ts_report}] AbuseIPDB report [{iface} -> {dst_ip}] for {ip_str}: HTTP {code}")
                record_report(conn, ip_str, "abuseipdb", threat_type)
            except urllib.error.HTTPError as he:
                err_b = he.read().decode("utf-8", errors="replace")[:100]
                log_msg(f"[{ts_report}] AbuseIPDB report [{iface} -> {dst_ip}] for {ip_str}: HTTP {he.code} ({err_b})")
            except Exception as e:
                log_msg(f"[{ts_report}] AbuseIPDB report [{iface} -> {dst_ip}] for {ip_str}: ERROR ({e})")

        # Provider 2: 2ip.io
        if can_twoip:
            rate_limiter.acquire()
            ts_report = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            try:
                code = report_twoip(twoip_token, ip_str, threat_type, target_str)
                log_msg(f"[{ts_report}] 2ip.io report [{iface} -> {dst_ip}] for {ip_str}: HTTP {code}")
                record_report(conn, ip_str, "twoip", threat_type)
            except urllib.error.HTTPError as he:
                err_b = he.read().decode("utf-8", errors="replace")[:100]
                log_msg(f"[{ts_report}] 2ip.io report [{iface} -> {dst_ip}] for {ip_str}: HTTP {he.code} ({err_b})")
            except Exception as e:
                log_msg(f"[{ts_report}] 2ip.io report [{iface} -> {dst_ip}] for {ip_str}: ERROR ({e})")

        # Provider 3: Spamhaus
        if can_spamhaus:
            rate_limiter.acquire()
            ts_report = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            try:
                code = report_spamhaus(spamhaus_token, ip_str, threat_type, target_str)
                log_msg(f"[{ts_report}] Spamhaus report [{iface} -> {dst_ip}] for {ip_str}: HTTP {code}")
                record_report(conn, ip_str, "spamhaus", threat_type)
            except urllib.error.HTTPError as he:
                err_b = he.read().decode("utf-8", errors="replace")[:100]
                log_msg(f"[{ts_report}] Spamhaus report [{iface} -> {dst_ip}] for {ip_str}: HTTP {he.code} ({err_b})")
            except Exception as e:
                log_msg(f"[{ts_report}] Spamhaus report [{iface} -> {dst_ip}] for {ip_str}: ERROR ({e})")


if __name__ == "__main__":
    main()
