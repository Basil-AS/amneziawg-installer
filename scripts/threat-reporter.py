#!/usr/bin/env python3
"""
threat-reporter.py - Kernel Threat Reporter Daemon for AbuseIPDB
Monitors in-kernel nftables logs (THREAT_*) and reports malicious actors
following strict AbuseIPDB guidelines and RFC best practices.
"""

import configparser
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

CONF_PATH = os.environ.get("THREAT_REPORTER_CONF", "/etc/threat-reporter/threat-reporter.conf")
DB_PATH = os.environ.get("THREAT_REPORTER_DB", "/var/lib/threat-reporter/reported.db")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("threat-reporter")

# Category mapping according to AbuseIPDB taxonomy:
# 4  = DDoS Attack
# 14 = Port Scan
# 15 = Hacking
# 18 = Brute-Force
# 22 = SSH
CATEGORIES = {
    "THREAT_HONEYPOT": "14,15",    # Port Scan, Hacking
    "THREAT_PORTSCAN": "14",       # Port Scan
    "THREAT_SSH_BRUTE": "18,22",   # Brute-Force, SSH
    "THREAT_FLOOD": "4",           # DDoS Attack
    "THREAT_QUIC_FLOOD": "4",      # DDoS Attack
}


def load_config():
    cp = configparser.ConfigParser()
    if os.path.exists(CONF_PATH):
        try:
            cp.read(CONF_PATH, encoding="utf-8")
        except Exception as e:
            logger.warning("Error reading %s: %s", CONF_PATH, e)
    api_key = cp.get("abuseipdb", "api_key", fallback="").strip()
    enabled = cp.getboolean("abuseipdb", "enabled", fallback=True)
    min_interval = cp.getint("filter", "min_report_interval", fallback=86400)
    return {
        "api_key": api_key,
        "enabled": enabled,
        "min_report_interval": min_interval,
    }


def init_db(db_path):
    os.makedirs(os.path.dirname(db_path), exist_ok=True)
    conn = sqlite3.connect(db_path)
    with conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS reports (
                ip TEXT PRIMARY KEY,
                threat_type TEXT,
                last_reported_at INTEGER,
                report_count INTEGER DEFAULT 1
            )
        """)
        conn.execute("CREATE INDEX IF NOT EXISTS idx_reports_time ON reports(last_reported_at)")
    return conn


def can_report_ip(conn, ip_str, min_interval):
    try:
        ip_obj = ipaddress.ip_address(ip_str)
        if not ip_obj.is_global or ip_obj.is_private or ip_obj.is_loopback or ip_obj.is_reserved or ip_obj.is_multicast:
            return False, "non-global/private IP"
    except ValueError:
        return False, "invalid IP format"

    now = int(time.time())
    cur = conn.cursor()
    cur.execute("SELECT last_reported_at FROM reports WHERE ip = ?", (ip_str,))
    row = cur.fetchone()
    if row:
        last_time = row[0]
        if now - last_time < min_interval:
            return False, f"already reported within last {min_interval}s"
    return True, ""


def record_report(conn, ip_str, threat_type):
    now = int(time.time())
    with conn:
        conn.execute("""
            INSERT INTO reports (ip, threat_type, last_reported_at, report_count)
            VALUES (?, ?, ?, 1)
            ON CONFLICT(ip) DO UPDATE SET
                threat_type = excluded.threat_type,
                last_reported_at = excluded.last_reported_at,
                report_count = report_count + 1
        """, (ip_str, threat_type, now))


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


def send_abuseipdb_report(api_key, ip_str, categories, comment):
    url = "https://api.abuseipdb.com/api/v2/report"
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

    with urllib.request.urlopen(req, timeout=10) as resp:
        body = resp.read().decode("utf-8", errors="replace")
        data = json.loads(body)
        score = data.get("data", {}).get("abuseConfidenceScore", "unknown")
        return True, f"ConfidenceScore={score}"


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
    last_cfg_check = time.time()

    if not cfg["api_key"]:
        logger.warning("No AbuseIPDB API key configured in %s. Running in standby mode (logging threats only).", CONF_PATH)
    else:
        logger.info("AbuseIPDB reporting ACTIVE with key length %d.", len(cfg["api_key"]))

    for line in proc.stdout:
        if time.time() - last_cfg_check > 30:
            cfg = load_config()
            last_cfg_check = time.time()

        m = pattern.search(line)
        if not m:
            continue

        threat_type, ip_str, proto, port = m.groups()
        ok_report, reason = can_report_ip(conn, ip_str, cfg["min_report_interval"])
        if not ok_report:
            logger.debug("Skipping %s (%s): %s", ip_str, threat_type, reason)
            continue

        comment = build_comment(threat_type, proto, port)
        categories = CATEGORIES.get(threat_type, "14")
        logger.info("THREAT DETECTED: %s from %s:%s on %s | %s", threat_type, ip_str, port, proto, comment)

        if not cfg["enabled"]:
            logger.info("Reporting disabled in config for %s", ip_str)
            continue

        if not cfg["api_key"]:
            logger.info("Standby: skipping AbuseIPDB report for %s (no API key in %s)", ip_str, CONF_PATH)
            record_report(conn, ip_str, threat_type)
            continue

        try:
            success, result_msg = send_abuseipdb_report(cfg["api_key"], ip_str, categories, comment)
            if success:
                logger.info("REPORTED %s to AbuseIPDB (%s): %s", ip_str, categories, result_msg)
                record_report(conn, ip_str, threat_type)
        except urllib.error.HTTPError as he:
            err_msg = he.read().decode("utf-8", errors="replace")
            logger.warning("AbuseIPDB HTTP error for %s (%d): %s", ip_str, he.code, err_msg)
        except Exception as e:
            logger.warning("Failed to report %s to AbuseIPDB: %s", ip_str, e)


if __name__ == "__main__":
    main()
