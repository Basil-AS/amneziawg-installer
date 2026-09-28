#!/usr/bin/env python3
"""
threat-stats.py - Advanced Kernel Threat Defense Dashboard & Telemetry
Displays real-time status of nftables in-kernel protection, threat-reporter daemon,
reputation provider dispatches (AbuseIPDB, 2ip.io, Spamhaus), and live threat metrics.
"""

import argparse
import datetime
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time

CONF_PATH = os.environ.get("THREAT_REPORTER_CONF", "/etc/threat-reporter/config.json")
DB_PATH = os.environ.get("THREAT_REPORTER_DB", "/var/lib/threat-reporter/reported.db")


class C:
    """ANSI color sequences."""
    RESET = "\033[0m"
    BOLD = "\033[1m"
    DIM = "\033[2m"
    ITALIC = "\033[3m"
    UNDERLINE = "\033[4m"

    RED = "\033[31m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    BLUE = "\033[34m"
    MAGENTA = "\033[35m"
    CYAN = "\033[36m"
    WHITE = "\033[37m"
    GRAY = "\033[90m"

    B_RED = "\033[91m"
    B_GREEN = "\033[92m"
    B_YELLOW = "\033[93m"
    B_BLUE = "\033[94m"
    B_MAGENTA = "\033[95m"
    B_CYAN = "\033[96m"
    B_WHITE = "\033[97m"

    @classmethod
    def disable(cls):
        for attr in list(cls.__dict__.keys()):
            if not attr.startswith("_") and attr != "disable":
                setattr(cls, attr, "")


def format_bytes(n):
    if n < 1024:
        return f"{n} B"
    elif n < 1024 * 1024:
        return f"{n / 1024:.1f} KB"
    elif n < 1024 * 1024 * 1024:
        return f"{n / (1024 * 1024):.1f} MB"
    else:
        return f"{n / (1024 * 1024 * 1024):.2f} GB"


def format_seconds(sec):
    if sec <= 0:
        return "expired"
    h = sec // 3600
    m = (sec % 3600) // 60
    s = sec % 60
    if h > 0:
        return f"{h}h {m:02d}m {s:02d}s"
    elif m > 0:
        return f"{m}m {s:02d}s"
    else:
        return f"{s}s"


def make_bar(value, total, width=28):
    if total <= 0 or value <= 0:
        return "░" * width
    ratio = min(1.0, value / total)
    filled = int(round(ratio * width))
    empty = width - filled
    return "█" * filled + "░" * empty


def get_service_info(unit):
    res = subprocess.run(
        ["systemctl", "show", unit, "-p", "ActiveState,SubState,MainPID,ExecMainStartTimestamp"],
        capture_output=True,
        text=True,
    )
    info = {}
    for line in res.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            info[k] = v
    pid = int(info.get("MainPID", 0))
    mem_mb = 0.0
    if pid > 0:
        try:
            with open(f"/proc/{pid}/status") as f:
                for l in f:
                    if l.startswith("VmRSS:"):
                        mem_mb = int(l.split()[1]) / 1024.0
        except Exception:
            pass
    info["mem_mb"] = mem_mb
    return info


def get_config():
    default_conf = {
        "api_keys": {},
        "dedup_window_seconds": 86400,
        "rate_limit_reports_per_minute": 5,
    }
    if os.path.exists(CONF_PATH):
        try:
            with open(CONF_PATH, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, dict):
                    default_conf.update(data)
        except Exception:
            pass
    return default_conf


def collect_nft_telemetry():
    telemetry = {
        "active": False,
        "banned_ips": [],
        "scan_meter_count": 0,
        "flood_meter_count": 0,
        "whitelist_count": 0,
        "counters": {
            "banned_drops": {"packets": 0, "bytes": 0},
            "honeypot_triggers": {"packets": 0, "bytes": 0},
            "honeypot_drops": {"packets": 0, "bytes": 0},
            "ssh_brute_triggers": {"packets": 0, "bytes": 0},
            "flood_triggers": {"packets": 0, "bytes": 0},
            "quic_flood_triggers": {"packets": 0, "bytes": 0},
            "portscan_triggers": {"packets": 0, "bytes": 0},
            "closed_port_drops": {"packets": 0, "bytes": 0},
        },
    }

    try:
        res = subprocess.run(["nft", "-j", "list", "table", "inet", "security"], capture_output=True, text=True)
        if res.returncode != 0:
            return telemetry

        data = json.loads(res.stdout)
        telemetry["active"] = True
        nft_items = data.get("nftables", [])

        for item in nft_items:
            if "set" in item:
                s = item["set"]
                s_name = s.get("name")
                elems = s.get("elem", [])
                if s_name == "threat_banned":
                    for e in elems:
                        if isinstance(e, dict):
                            edata = e.get("elem", {})
                            val = edata.get("val")
                            exp = edata.get("expires", 0)
                            if val:
                                telemetry["banned_ips"].append({"ip": val, "expires": exp})
                elif s_name == "threat_scan_meter":
                    telemetry["scan_meter_count"] = len(elems)
                elif s_name == "threat_flood_meter":
                    telemetry["flood_meter_count"] = len(elems)
                elif s_name == "threat_whitelist":
                    telemetry["whitelist_count"] = len(elems)

            elif "rule" in item:
                r = item["rule"]
                exprs = r.get("expr", [])
                prefix = ""
                cnt = None
                has_banned_match = False
                is_closed_drop = False

                for ex in exprs:
                    if "match" in ex:
                        right = ex["match"].get("right")
                        if right == "@threat_banned":
                            has_banned_match = True
                        left_meta = ex["match"].get("left", {}).get("meta", {}).get("key")
                        if left_meta == "iifname":
                            is_closed_drop = True
                    if "log" in ex:
                        prefix = ex["log"].get("prefix", "")
                    if "counter" in ex:
                        cnt = ex["counter"]

                if cnt:
                    if has_banned_match:
                        telemetry["counters"]["banned_drops"] = cnt
                    elif prefix == "THREAT_HONEYPOT: ":
                        telemetry["counters"]["honeypot_triggers"] = cnt
                    elif prefix == "THREAT_PORTSCAN: ":
                        telemetry["counters"]["portscan_triggers"] = cnt
                    elif prefix == "THREAT_SSH_BRUTE: ":
                        telemetry["counters"]["ssh_brute_triggers"] = cnt
                    elif prefix == "THREAT_FLOOD: ":
                        telemetry["counters"]["flood_triggers"] = cnt
                    elif prefix == "THREAT_QUIC_FLOOD: ":
                        telemetry["counters"]["quic_flood_triggers"] = cnt
                    elif is_closed_drop and not prefix:
                        telemetry["counters"]["closed_port_drops"] = cnt
                    elif not prefix and not has_banned_match:
                        # honeypot decoy drops
                        if r.get("handle") == 18:
                            telemetry["counters"]["honeypot_drops"] = cnt

    except Exception:
        pass

    telemetry["banned_ips"].sort(key=lambda x: x["expires"], reverse=True)
    return telemetry


def collect_db_reports():
    db_stats = {
        "total_reports": 0,
        "provider_counts": {},
        "threat_type_counts": {},
        "recent_reports": [],
        "top_offenders": [],
    }

    if not os.path.exists(DB_PATH):
        return db_stats

    try:
        conn = sqlite3.connect(DB_PATH)
        with conn:
            cur = conn.cursor()
            # Providers
            for row in cur.execute("SELECT provider, count(*), sum(report_count) FROM reports GROUP BY provider"):
                db_stats["provider_counts"][row[0]] = {"unique_ips": row[1], "total_dispatches": row[2]}
                db_stats["total_reports"] += row[2]

            # Threat types
            for row in cur.execute("SELECT threat_type, count(*) FROM reports GROUP BY threat_type"):
                db_stats["threat_type_counts"][row[0]] = row[1]

            # Recent reports grouped by IP
            query = """
                SELECT ip, threat_type, group_concat(provider, ', ') as providers,
                       datetime(max(last_reported_at), 'unixepoch', 'localtime') as last_time_loc,
                       max(last_reported_at) as last_ts,
                       sum(report_count) as total_count
                FROM reports
                GROUP BY ip, threat_type
                ORDER BY last_ts DESC
                LIMIT 10
            """
            for row in cur.execute(query):
                db_stats["recent_reports"].append({
                    "ip": row[0],
                    "threat_type": row[1],
                    "providers": row[2],
                    "time": row[3],
                    "timestamp": row[4],
                    "count": row[5],
                })

            # Top offenders
            top_query = """
                SELECT ip, sum(report_count) as total, group_concat(DISTINCT threat_type)
                FROM reports
                GROUP BY ip
                ORDER BY total DESC
                LIMIT 5
            """
            for row in cur.execute(top_query):
                db_stats["top_offenders"].append({"ip": row[0], "total": row[1], "types": row[2]})

    except Exception:
        pass

    return db_stats


def render_dashboard():
    term_width = min(100, max(76, shutil.get_terminal_size((80, 24)).columns))
    inner_width = term_width - 4

    cfg = get_config()
    nft_info = get_service_info("nftables")
    rep_info = get_service_info("threat-reporter")
    nft_data = collect_nft_telemetry()
    db_data = collect_db_reports()

    # Title header
    border_top = "╭" + "─" * (term_width - 2) + "╮"
    border_bot = "╰" + "─" * (term_width - 2) + "╯"
    div_line = "  " + "─" * (term_width - 4)

    lines = []
    lines.append("")
    lines.append(f"{C.B_CYAN}{border_top}{C.RESET}")
    title1 = "🛡️   AMNEZIAWG KERNEL THREAT DEFENSE & INCIDENT TELEMETRY"
    title2 = f"Live Security Monitoring Dashboard • {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"
    lines.append(f"{C.B_CYAN}│{C.RESET} {title1.center(term_width - 4)} {C.B_CYAN}│{C.RESET}")
    lines.append(f"{C.B_CYAN}│{C.RESET} {C.GRAY}{title2.center(term_width - 4)}{C.RESET} {C.B_CYAN}│{C.RESET}")
    lines.append(f"{C.B_CYAN}{border_bot}{C.RESET}")
    lines.append("")

    # Section 1: System Services & Provider Health
    lines.append(f" {C.BOLD}{C.CYAN}◆ SYSTEM & REPUTATION ENGINE STATUS{C.RESET}")
    lines.append(div_line)

    nft_st = nft_info.get("ActiveState", "inactive")
    nft_badge = f"{C.B_GREEN}[● ACTIVE]{C.RESET}" if nft_st == "active" else f"{C.B_RED}[● INACTIVE]{C.RESET}"
    lines.append(f"   {C.BOLD}Firewall (nftables):{C.RESET} {nft_badge} {C.GRAY}In-kernel dynamic set timeouts & zero-drop drops{C.RESET}")

    rep_st = rep_info.get("ActiveState", "inactive")
    if rep_st == "active":
        rep_badge = f"{C.B_GREEN}[● ACTIVE]{C.RESET}"
        pid = rep_info.get("MainPID", "?")
        mem = rep_info.get("mem_mb", 0.0)
        rep_details = f"{C.GRAY}(PID: {pid} | Memory: {mem:.1f} MB){C.RESET}"
    else:
        rep_badge = f"{C.B_RED}[● INACTIVE]{C.RESET}"
        rep_details = ""
    lines.append(f"   {C.BOLD}Reporter Daemon:{C.RESET}     {rep_badge} {rep_details}")

    # Providers
    keys = cfg.get("api_keys", {})
    p_lines = []
    for p_name, label in [("abuseipdb", "AbuseIPDB"), ("twoip", "2ip.io"), ("spamhaus", "Spamhaus")]:
        key_val = keys.get(p_name, "")
        p_stat = db_data["provider_counts"].get(p_name, {"unique_ips": 0, "total_dispatches": 0})
        if key_val:
            masked = key_val[:4] + "..." + key_val[-4:] if len(key_val) > 8 else "***"
            badge = f"{C.B_GREEN}🟢 ACTIVE{C.RESET}"
            p_lines.append(f"{C.BOLD}{label:<10}{C.RESET}: {badge} {C.GRAY}(Key: {masked} | Sent: {p_stat['total_dispatches']}){C.RESET}")
        else:
            badge = f"{C.YELLOW}⚪ UNSET{C.RESET}"
            p_lines.append(f"{C.BOLD}{label:<10}{C.RESET}: {badge}")

    lines.append(f"   {C.BOLD}Public Feeds:{C.RESET}        " + f"   ".join(p_lines[:2]))
    lines.append(f"                        {p_lines[2]}")
    lines.append("")

    # Section 2: In-Kernel Defense Telemetry
    cnt = nft_data["counters"]
    banned_p = cnt["banned_drops"]["packets"]
    banned_b = format_bytes(cnt["banned_drops"]["bytes"])
    honey_trig = cnt["honeypot_triggers"]["packets"]
    honey_drops = cnt["honeypot_drops"]["packets"]
    scan_trig = cnt["portscan_triggers"]["packets"]
    closed_p = cnt["closed_port_drops"]["packets"]
    closed_b = format_bytes(cnt["closed_port_drops"]["bytes"])
    ssh_trig = cnt["ssh_brute_triggers"]["packets"]
    flood_trig = cnt["flood_triggers"]["packets"] + cnt["quic_flood_triggers"]["packets"]

    lines.append(f" {C.BOLD}{C.CYAN}◆ IN-KERNEL DEFENSE TELEMETRY (nftables table inet security){C.RESET}")
    lines.append(div_line)
    lines.append(f"   ┌──────────────────────────────────────────────┬──────────────────┬──────────────────┐")
    lines.append(f"   │ {C.BOLD}{'DEFENSE LAYER / METRIC':<44}{C.RESET} │ {C.BOLD}{'PACKETS / HITS':<16}{C.RESET} │ {C.BOLD}{'TRAFFIC VOLUME':<16}{C.RESET} │")
    lines.append(f"   ├──────────────────────────────────────────────┼──────────────────┼──────────────────┤")
    lines.append(f"   │ {C.B_RED}⛔ Kernel Blacklist Drops (@threat_banned){C.RESET}    │ {banned_p:<16,d} │ {banned_b:<16} │")
    lines.append(f"   │ {C.B_YELLOW}🍯 Honeypot Traps (Ports 21,22,23,445,1433,etc){C.RESET}│ {f'{honey_trig} triggers ({honey_drops} pkts)':<16} │ {format_bytes(cnt['honeypot_triggers']['bytes'] + cnt['honeypot_drops']['bytes']):<16} │")
    lines.append(f"   │ {C.B_MAGENTA}🔍 Rapid Port Scan Sweeps Triggers{C.RESET}             │ {f'{scan_trig} triggers':<16} │ {format_bytes(cnt['portscan_triggers']['bytes']):<16} │")
    lines.append(f"   │ {C.BLUE}🛡️  Closed Ports SYN Scans Dropped{C.RESET}             │ {closed_p:<16,d} │ {closed_b:<16} │")
    lines.append(f"   │ {C.CYAN}⚡ SSH Rate Limit Violations (Port 12121){C.RESET}     │ {f'{ssh_trig} blocked':<16} │ {format_bytes(cnt['ssh_brute_triggers']['bytes']):<16} │")
    lines.append(f"   │ {C.B_BLUE}🌊 HTTP/HTTPS/QUIC Flood Violations{C.RESET}           │ {f'{flood_trig} blocked':<16} │ {format_bytes(cnt['flood_triggers']['bytes'] + cnt['quic_flood_triggers']['bytes']):<16} │")
    lines.append(f"   └──────────────────────────────────────────────┴──────────────────┴──────────────────┘")
    lines.append("")

    # Section 3: Kernel Sets & Attack Distribution
    banned_count = len(nft_data["banned_ips"])
    scan_meter_count = nft_data["scan_meter_count"]
    flood_meter_count = nft_data["flood_meter_count"]
    whitelist_count = nft_data["whitelist_count"]

    tt_counts = db_data["threat_type_counts"]
    total_incidents = sum(tt_counts.values())
    honey_c = tt_counts.get("THREAT_HONEYPOT", 0)
    scan_c = tt_counts.get("THREAT_PORTSCAN", 0)
    ssh_c = tt_counts.get("THREAT_SSH_BRUTE", 0)
    flood_c = tt_counts.get("THREAT_FLOOD", 0) + tt_counts.get("THREAT_QUIC_FLOOD", 0)

    lines.append(f" {C.BOLD}{C.CYAN}◆ KERNEL DYNAMIC SETS & ATTACK VECTORS{C.RESET}")
    lines.append(div_line)
    lines.append(f"   {C.BOLD}Active Dynamic Sets:{C.RESET}")
    lines.append(f"     • {C.B_RED}threat_banned{C.RESET}:       {C.BOLD}{banned_count}{C.RESET} malicious IPs blocked for 24h")
    lines.append(f"     • {C.YELLOW}threat_scan_meter{C.RESET}:   {C.BOLD}{scan_meter_count}{C.RESET} scanner IPs monitored (>15 pkts/min threshold)")
    lines.append(f"     • {C.BLUE}threat_flood_meter{C.RESET}:  {C.BOLD}{flood_meter_count}{C.RESET} high-rate IPs monitored (>600 pkts/min threshold)")
    lines.append(f"     • {C.GREEN}threat_whitelist{C.RESET}:   {C.BOLD}{whitelist_count}{C.RESET} protected subnets/gateways (RFC 1918 + Admin IP)")
    lines.append("")
    lines.append(f"   {C.BOLD}Incident Vector Breakdown (Total: {total_incidents}):{C.RESET}")
    h_pct = (honey_c / total_incidents * 100) if total_incidents else 0
    s_pct = (scan_c / total_incidents * 100) if total_incidents else 0
    ssh_pct = (ssh_c / total_incidents * 100) if total_incidents else 0
    f_pct = (flood_c / total_incidents * 100) if total_incidents else 0

    lines.append(f"     🍯 Honeypot Decoy  {C.B_YELLOW}[{make_bar(honey_c, total_incidents)}]{C.RESET}  {honey_c:>3d} ({h_pct:>5.1f}%)")
    lines.append(f"     🔍 Port Scan Sweep {C.B_MAGENTA}[{make_bar(scan_c, total_incidents)}]{C.RESET}  {scan_c:>3d} ({s_pct:>5.1f}%)")
    lines.append(f"     🔑 SSH Brute-Force {C.CYAN}[{make_bar(ssh_c, total_incidents)}]{C.RESET}  {ssh_c:>3d} ({ssh_pct:>5.1f}%)")
    lines.append(f"     🌊 Network Floods  {C.B_BLUE}[{make_bar(flood_c, total_incidents)}]{C.RESET}  {flood_c:>3d} ({f_pct:>5.1f}%)")
    lines.append("")

    # Section 4: Active Banned Host List
    lines.append(f" {C.BOLD}{C.CYAN}◆ CURRENTLY BANNED MALICIOUS HOSTS (threat_banned){C.RESET}")
    lines.append(div_line)
    lines.append(f"   {C.BOLD}{'IP ADDRESS':<18} {'TIME REMAINING':<16} {'ACTION':<10} {'STATUS':<14}{C.RESET}")
    lines.append(f"   {C.GRAY}{'─' * 18} {'─' * 16} {'─' * 10} {'─' * 14}{C.RESET}")

    if not nft_data["banned_ips"]:
        lines.append(f"   {C.GRAY}No active IP bans currently recorded in the kernel.{C.RESET}")
    else:
        for b in nft_data["banned_ips"][:10]:
            ip = b["ip"]
            ttl = format_seconds(b["expires"])
            lines.append(f"   {C.B_WHITE}{ip:<18}{C.RESET} {C.YELLOW}{ttl:<16}{C.RESET} {C.RED}{'DROP':<10}{C.RESET} {C.B_RED}BANNED (24h){C.RESET}")
        if len(nft_data["banned_ips"]) > 10:
            lines.append(f"   {C.GRAY}... and {len(nft_data['banned_ips']) - 10} more banned IPs (run `threat-stats --banned` for complete list){C.RESET}")
    lines.append("")

    # Section 5: Recent Forensics & Dispatches
    lines.append(f" {C.BOLD}{C.CYAN}◆ RECENT DISPATCHED FORENSIC INCIDENTS (SQLite){C.RESET}")
    lines.append(div_line)
    lines.append(f"   {C.BOLD}{'LOCAL TIME':<20} {'ATTACKER IP':<18} {'VECTOR':<16} {'DISPATCHED TO':<20}{C.RESET}")
    lines.append(f"   {C.GRAY}{'─' * 20} {'─' * 18} {'─' * 16} {'─' * 20}{C.RESET}")

    if not db_data["recent_reports"]:
        lines.append(f"   {C.GRAY}No abuse reports recorded in database yet.{C.RESET}")
    else:
        for rep in db_data["recent_reports"]:
            t_str = rep["time"]
            ip = rep["ip"]
            vector = rep["threat_type"].replace("THREAT_", "")
            provs = rep["providers"]
            lines.append(f"   {C.GRAY}{t_str:<20}{C.RESET} {C.B_WHITE}{ip:<18}{C.RESET} {C.B_YELLOW}{vector:<16}{C.RESET} {C.B_GREEN}{provs:<20}{C.RESET}")
    lines.append("")

    return "\n".join(lines)


def show_banned_full():
    nft_data = collect_nft_telemetry()
    banned = nft_data["banned_ips"]
    print(f"\n{C.BOLD}=== COMPLETE LIST OF BANNED MALICIOUS HOSTS ({len(banned)} total) ==={C.RESET}\n")
    print(f"{'#':<4} {'IP ADDRESS':<20} {'EXPIRES IN':<18} {'STATUS':<12}")
    print("-" * 56)
    for idx, b in enumerate(banned, 1):
        ttl = format_seconds(b["expires"])
        print(f"{idx:<4} {b['ip']:<20} {ttl:<18} BANNED")
    print()


def show_reported_full():
    db_data = collect_db_reports()
    if not os.path.exists(DB_PATH):
        print("No reports database found.")
        return
    conn = sqlite3.connect(DB_PATH)
    print(f"\n{C.BOLD}=== RECENT ABUSE DISPATCHES (ALL) ==={C.RESET}\n")
    print(f"{'TIMESTAMP':<20} {'IP':<18} {'PROVIDER':<12} {'THREAT TYPE':<18} {'COUNT'}")
    print("-" * 75)
    for row in conn.execute("SELECT datetime(last_reported_at, 'unixepoch', 'localtime'), ip, provider, threat_type, report_count FROM reports ORDER BY last_reported_at DESC LIMIT 50"):
        print(f"{row[0]:<20} {row[1]:<18} {row[2]:<12} {row[3]:<18} {row[4]}")
    print()


def main():
    parser = argparse.ArgumentParser(description="AmneziaWG Kernel Threat Defense Telemetry Dashboard")
    parser.add_argument("-w", "--watch", type=int, nargs="?", const=2, default=None, help="Live watch mode with refresh interval in seconds (default: 2)")
    parser.add_argument("--no-color", action="store_true", help="Disable ANSI color output")
    parser.add_argument("--json", action="store_true", help="Output raw telemetry as JSON")
    parser.add_argument("--banned", action="store_true", help="Show all banned IPs with expiration timers")
    parser.add_argument("--reported", action="store_true", help="Show all recorded reports in SQLite")
    args = parser.parse_args()

    if args.no_color or not sys.stdout.isatty():
        C.disable()

    if args.json:
        data = {
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "nftables": collect_nft_telemetry(),
            "database": collect_db_reports(),
            "services": {
                "nftables": get_service_info("nftables"),
                "threat_reporter": get_service_info("threat-reporter"),
            },
        }
        print(json.dumps(data, indent=2))
        return

    if args.banned:
        show_banned_full()
        return

    if args.reported:
        show_reported_full()
        return

    if args.watch is not None:
        interval = max(1, args.watch)
        try:
            while True:
                # Clear terminal screen cleanly
                sys.stdout.write("\033[2J\033[H")
                sys.stdout.flush()
                print(render_dashboard())
                print(f" {C.GRAY}Live monitoring mode (refreshing every {interval}s). Press Ctrl+C to exit.{C.RESET}")
                time.sleep(interval)
        except KeyboardInterrupt:
            print(f"\n{C.YELLOW}Exited live monitor.{C.RESET}")
            return

    # Default: single shot dashboard
    print(render_dashboard())


if __name__ == "__main__":
    main()
