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
import logging
import os
import re
import signal
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CONF_PATH = os.environ.get("THREAT_REPORTER_CONF", "/etc/threat-reporter/config.json")
DB_PATH = os.environ.get("THREAT_REPORTER_DB", "/var/lib/threat-reporter/reported.db")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("threat-reporter")

# Provider mappings
ABUSEIPDB_CATEGORIES = {
    "THREAT_HONEYPOT": "14,15",    # Port Scan, Hacking
    "THREAT_PORTSCAN": "14",       # Port Scan
    "THREAT_SSH_BRUTE": "18,22",   # Brute-Force, SSH
    "THREAT_FLOOD": "4",           # DDoS Attack
    "THREAT_QUIC_FLOOD": "4",      # DDoS Attack
}

TWOIP_TYPES = {
    "THREAT_HONEYPOT": 6,          # Port scan / Unauthorized probe
    "THREAT_PORTSCAN": 6,          # Port scan / Unauthorized probe
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
            logger.warning("Error reading config %s: %s", CONF_PATH, exc)
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


def build_comment(threat_type, proto, port):
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    proto = proto.upper() if proto else "TCP"
    if threat_type == "THREAT_HONEYPOT":
        return f"{ts} - Connection attempt to honeypot port {proto} {port}. Action: immediate drop & 24h ban."
    elif threat_type == "THREAT_PORTSCAN":
        return f"{ts} - Port scan detected on closed ports (hits > 15/min). Action: firewall drop & 24h ban."
    elif threat_type == "THREAT_SSH_BRUTE":
        return f"{ts} - SSH brute-force attempt on port {port} (> 15 conns/min). Action: blocked by nftables."
    elif threat_type == "THREAT_FLOOD":
        return f"{ts} - SYN flood attack detected on {proto} port {port} (> 600 SYN/min). Action: 24h ban."
    elif threat_type == "THREAT_QUIC_FLOOD":
        return f"{ts} - UDP flood on QUIC port {port}. Action: blocked by nftables."
    return f"{ts} - Threat detected: {threat_type} on {proto} port {port}. Action: 24h ban."


def report_abuseipdb(api_key, ip_str, threat_type, comment):
    url = "https://api.abuseipdb.com/api/v2/report"
    categories = ABUSEIPDB_CATEGORIES.get(threat_type, "14")
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
        body = resp.read().decode("utf-8", errors="replace")
        data = json.loads(body)
        score = data.get("data", {}).get("abuseConfidenceScore", "unknown")
        return f"ConfidenceScore={score}"


def report_twoip(token, ip_str, threat_type, comment):
    url = f"https://api.2ip.io/abuse?token={urllib.parse.quote(token)}"
    attack_type = TWOIP_TYPES.get(threat_type, 6)
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
        body = resp.read().decode("utf-8", errors="replace")
        return body[:120].strip() or "OK"


def report_spamhaus(token, ip_str, comment):
    url = "https://submit.spamhaus.org/portal/api/v1/submissions/add/ip"
    payload = json.dumps({
        "threat_type": "attack",
        "reason": comment,
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
        body = resp.read().decode("utf-8", errors="replace")
        return body[:120].strip() or "OK"


def main():
    conn = init_db(DB_PATH)
    logger.info("Threat reporter daemon initialized. DB: %s", DB_PATH)

    pattern = re.compile(
        r"(THREAT_\w+):.*?SRC=([\d\.]+).*?PROTO=(\w+).*?DPT=(\d+)"
    )

    cmd = ["journalctl", "-k", "-f", "-o", "cat"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)

    def sig_handler(sig, frame):
        logger.info("Termination signal received. Exiting.")
        proc.terminate()
        sys.exit(0)

    signal.signal(signal.SIGINT, sig_handler)
    signal.signal(signal.SIGTERM, sig_handler)

    cfg = load_config()
    rate_limiter = RateLimiter(cfg.get("rate_limit_reports_per_minute", 5))
    last_cfg_check = time.time()

    active_providers = [k for k, v in cfg["api_keys"].items() if v]
    if active_providers:
        logger.info("Threat reporting ACTIVE for providers: %s", ", ".join(active_providers))
    else:
        logger.warning("No API keys found in %s. Running in standby mode (logging threats only).", CONF_PATH)

    for line in proc.stdout:
        if time.time() - last_cfg_check > 30:
            cfg = load_config()
            rate_limiter.max_per_minute = cfg.get("rate_limit_reports_per_minute", 5)
            last_cfg_check = time.time()

        m = pattern.search(line)
        if not m:
            continue

        threat_type, ip_str, proto, port = m.groups()
        ok_ip, ip_reason = is_global_ip(ip_str)
        if not ok_ip:
            logger.debug("Skipping non-global IP %s (%s): %s", ip_str, threat_type, ip_reason)
            continue

        comment = build_comment(threat_type, proto, port)
        logger.info("THREAT DETECTED: %s from %s:%s on %s | %s", threat_type, ip_str, port, proto, comment)

        # Provider: AbuseIPDB
        abuse_key = cfg["api_keys"].get("abuseipdb", "").strip()
        if abuse_key:
            can_rep, r_reason = can_report_ip(conn, ip_str, "abuseipdb", cfg["dedup_window_seconds"])
            if can_rep:
                rate_limiter.acquire()
                try:
                    res = report_abuseipdb(abuse_key, ip_str, threat_type, comment)
                    logger.info("[AbuseIPDB] REPORTED %s: %s", ip_str, res)
                    record_report(conn, ip_str, "abuseipdb", threat_type)
                except urllib.error.HTTPError as he:
                    err_b = he.read().decode("utf-8", errors="replace")
                    logger.warning("[AbuseIPDB] HTTP %d for %s: %s", he.code, ip_str, err_b)
                except Exception as e:
                    logger.warning("[AbuseIPDB] Failed to report %s: %s", ip_str, e)
            else:
                logger.debug("[AbuseIPDB] Skip %s: %s", ip_str, r_reason)

        # Provider: 2ip.io
        twoip_token = cfg["api_keys"].get("twoip", "").strip()
        if twoip_token:
            can_rep, r_reason = can_report_ip(conn, ip_str, "twoip", cfg["dedup_window_seconds"])
            if can_rep:
                rate_limiter.acquire()
                try:
                    res = report_twoip(twoip_token, ip_str, threat_type, comment)
                    logger.info("[2ip.io] REPORTED %s: %s", ip_str, res)
                    record_report(conn, ip_str, "twoip", threat_type)
                except urllib.error.HTTPError as he:
                    err_b = he.read().decode("utf-8", errors="replace")
                    logger.warning("[2ip.io] HTTP %d for %s: %s", he.code, ip_str, err_b)
                except Exception as e:
                    logger.warning("[2ip.io] Failed to report %s: %s", ip_str, e)
            else:
                logger.debug("[2ip.io] Skip %s: %s", ip_str, r_reason)

        # Provider: Spamhaus
        spamhaus_token = cfg["api_keys"].get("spamhaus", "").strip()
        if spamhaus_token:
            can_rep, r_reason = can_report_ip(conn, ip_str, "spamhaus", cfg["dedup_window_seconds"])
            if can_rep:
                rate_limiter.acquire()
                try:
                    res = report_spamhaus(spamhaus_token, ip_str, comment)
                    logger.info("[Spamhaus] REPORTED %s: %s", ip_str, res)
                    record_report(conn, ip_str, "spamhaus", threat_type)
                except urllib.error.HTTPError as he:
                    err_b = he.read().decode("utf-8", errors="replace")
                    logger.warning("[Spamhaus] HTTP %d for %s: %s", he.code, ip_str, err_b)
                except Exception as e:
                    logger.warning("[Spamhaus] Failed to report %s: %s", ip_str, e)
            else:
                logger.debug("[Spamhaus] Skip %s: %s", ip_str, r_reason)


if __name__ == "__main__":
    main()
