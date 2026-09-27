#!/usr/bin/env bash
set -euo pipefail

CONF="/etc/threat-reporter/config.json"
DB="/var/lib/threat-reporter/reported.db"
LOG="/var/log/threat-reporter.log"

case "${1:-status}" in
    status)
        echo "=== THREAT PROTECTION STATUS ==="
        systemctl is-active nftables &>/dev/null && echo "nftables: ACTIVE" || echo "nftables: INACTIVE"
        systemctl is-active threat-reporter &>/dev/null && echo "threat-reporter: ACTIVE" || echo "threat-reporter: INACTIVE"
        echo ""
        echo "=== CONFIGURED PROVIDERS (/etc/threat-reporter/config.json) ==="
        python3 -c '
import json
try:
    with open("/etc/threat-reporter/config.json") as f:
        data = json.load(f)
    keys = data.get("api_keys", {})
    for p in ["abuseipdb", "twoip", "spamhaus"]:
        v = keys.get(p, "")
        if v:
            masked = v[:4] + "..." + v[-4:] if len(v) > 8 else "***"
            print(f"  [+] {p:<12}: ACTIVE ({masked})")
        else:
            print(f"  [-] {p:<12}: NOT CONFIGURED")
    d = data.get("dedup_window_seconds", 86400)
    r = data.get("rate_limit_reports_per_minute", 5)
    print(f"  Dedup window: {d}s | Rate limit: {r}/min")
except Exception as e:
    print("Error loading config:", e)
'
        echo ""
        echo "=== BANNED HOSTS (threat_banned) ==="
        nft list set inet security threat_banned 2>/dev/null || true
        echo ""
        echo "=== WHITELIST (threat_whitelist) ==="
        nft list set inet security threat_whitelist 2>/dev/null || true
        ;;
    banned)
        nft list set inet security threat_banned 2>/dev/null || true
        ;;
    reported)
        echo "=== RECENTLY REPORTED THREATS ==="
        python3 -c '
import sqlite3
try:
    conn = sqlite3.connect("/var/lib/threat-reporter/reported.db")
    for row in conn.execute("SELECT ip, provider, threat_type, datetime(last_reported_at, \"unixepoch\"), report_count FROM reports ORDER BY last_reported_at DESC LIMIT 30"):
        print(f"{row[3]} | {row[0]:<16} | {row[1]:<10} | {row[2]:<16} (count: {row[4]})")
except Exception as e:
    print("No reports database:", e)
'
        ;;
    unban)
        ip="${2:-}"
        [[ -n "$ip" ]] || { echo "Usage: threat-admin unban <IP>"; exit 1; }
        nft delete element inet security threat_banned "{ $ip }" 2>/dev/null && echo "Unbanned $ip" || echo "IP $ip was not in threat_banned"
        ;;
    ban)
        ip="${2:-}"
        [[ -n "$ip" ]] || { echo "Usage: threat-admin ban <IP>"; exit 1; }
        nft add element inet security threat_banned "{ $ip timeout 1d }" && echo "Banned $ip for 24h"
        ;;
    set-key)
        provider="${2:-}"
        key="${3:-}"
        if [[ -z "$provider" || -z "$key" ]]; then
            echo "Usage: threat-admin set-key <abuseipdb|twoip|spamhaus> <KEY>"
            exit 1
        fi
        python3 -c '
import json, sys
p, k = sys.argv[1], sys.argv[2]
with open("/etc/threat-reporter/config.json") as f:
    data = json.load(f)
data.setdefault("api_keys", {})[p] = k
with open("/etc/threat-reporter/config.json", "w") as f:
    json.dump(data, f, indent=2)
' "$provider" "$key"
        systemctl restart threat-reporter.service
        echo "Provider $provider key updated. Daemon restarted."
        ;;
    logs)
        if [[ -f "$LOG" && -s "$LOG" ]]; then
            tail -n 50 "$LOG"
        else
            journalctl -u threat-reporter.service -n 50 --no-pager
        fi
        ;;
    *)
        echo "Usage: threat-admin {status|banned|reported|unban <ip>|ban <ip>|set-key <provider> <key>|logs}"
        exit 1
        ;;
esac
