#!/usr/bin/env python3
"""Apply IPv4-only DNS hardening to an AdGuard Home config.

Surgical, line-based edits to the top-level `dns:` section of
AdGuardHome.yaml — avoids a full YAML round-trip so comments, key order
and unrelated sections (filters, clients, query_log, ...) are preserved
byte-for-byte outside of the touched lines.

Changes applied inside `dns:`:
  - aaaa_disabled: true
  - bootstrap_prefer_ipv6: false
  - use_dns64: false
  - dns64_prefixes: []
  - bootstrap_dns: drop any entry containing ':' (IPv6 literal),
    keep IPv4 entries and the surrounding upstream_dns/DoH list untouched.

By default refuses to run if this host appears to have usable IPv6
(global address present and IPv6 not disabled at the kernel level);
pass --force to override that guard.
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path

DISABLE_IPV6_PATH = os.environ.get(
    "ADGUARD_IPV4_ONLY_DISABLE_IPV6_PATH", "/proc/sys/net/ipv6/conf/all/disable_ipv6"
)
IF_INET6_PATH = os.environ.get("ADGUARD_IPV4_ONLY_IF_INET6_PATH", "/proc/net/if_inet6")


def ipv6_usable():
    """Best-effort detection of a usable (global, enabled) IPv6 path."""
    try:
        if Path(DISABLE_IPV6_PATH).read_text(encoding="utf-8").strip() == "1":
            return False
    except OSError:
        pass
    try:
        lines = Path(IF_INET6_PATH).read_text(encoding="utf-8").splitlines()
    except OSError:
        return False
    for line in lines:
        parts = line.split()
        if len(parts) < 6:
            continue
        _addr, _idx, _plen, scope, _flags, name = parts[:6]
        if scope == "00" and name != "lo":
            return True
    return False


def process_dns_section(lines):
    """Return (new_lines, summary, dns_section_found)."""
    summary = {
        "aaaa_disabled": False,
        "bootstrap_prefer_ipv6": False,
        "use_dns64": False,
        "dns64_prefixes": False,
        "removed_bootstrap_ipv6": [],
        "kept_bootstrap_ipv4": [],
    }

    dns_start = None
    for idx, line in enumerate(lines):
        if re.match(r"^dns:\s*$", line):
            dns_start = idx
            break
    if dns_start is None:
        return lines, summary, False

    dns_end = len(lines)
    for idx in range(dns_start + 1, len(lines)):
        if re.match(r"^\S", lines[idx]):
            dns_end = idx
            break

    out = []
    in_bootstrap = False
    bootstrap_indent = None
    for idx, line in enumerate(lines):
        if dns_start < idx < dns_end:
            m = re.match(r"^(\s*aaaa_disabled:\s*)(\S+)\s*$", line)
            if m:
                if m.group(2) != "true":
                    out.append(f"{m.group(1)}true")
                    summary["aaaa_disabled"] = True
                else:
                    out.append(line)
                continue
            m = re.match(r"^(\s*bootstrap_prefer_ipv6:\s*)(\S+)\s*$", line)
            if m:
                if m.group(2) != "false":
                    out.append(f"{m.group(1)}false")
                    summary["bootstrap_prefer_ipv6"] = True
                else:
                    out.append(line)
                continue
            m = re.match(r"^(\s*use_dns64:\s*)(\S+)\s*$", line)
            if m:
                if m.group(2) != "false":
                    out.append(f"{m.group(1)}false")
                    summary["use_dns64"] = True
                else:
                    out.append(line)
                continue
            m = re.match(r"^(\s*dns64_prefixes:\s*)(\S.*)$", line)
            if m:
                if m.group(2).strip() != "[]":
                    out.append(f"{m.group(1)}[]")
                    summary["dns64_prefixes"] = True
                else:
                    out.append(line)
                continue
            m = re.match(r"^(\s*)bootstrap_dns:\s*$", line)
            if m:
                bootstrap_indent = len(m.group(1))
                in_bootstrap = True
                out.append(line)
                continue
            if in_bootstrap:
                item_m = re.match(r"^(\s*)- (.*)$", line)
                if item_m and len(item_m.group(1)) > bootstrap_indent:
                    value = item_m.group(2).strip().strip("'\"")
                    if ":" in value:
                        summary["removed_bootstrap_ipv6"].append(value)
                        continue
                    summary["kept_bootstrap_ipv4"].append(value)
                    out.append(line)
                    continue
                in_bootstrap = False
        out.append(line)
    return out, summary, True


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", help="Path to AdGuardHome.yaml")
    parser.add_argument("--apply", action="store_true", help="Write changes back to the config file")
    parser.add_argument("--force", action="store_true", help="Apply even if this host appears to have usable IPv6")
    args = parser.parse_args(argv)

    if ipv6_usable() and not args.force:
        print("IPv6 looks usable on this host; refusing to disable AAAA without --force.")
        return 3

    path = Path(args.config)
    text = path.read_text(encoding="utf-8")
    trailing_newline = text.endswith("\n")
    lines = text.split("\n")
    if trailing_newline:
        lines = lines[:-1]

    new_lines, summary, found = process_dns_section(lines)
    if not found:
        print("dns: section not found; no changes made.")
        return 1

    changed = any([
        summary["aaaa_disabled"],
        summary["bootstrap_prefer_ipv6"],
        summary["use_dns64"],
        summary["dns64_prefixes"],
        summary["removed_bootstrap_ipv6"],
    ])
    print(json.dumps(summary, indent=2))

    if not changed:
        print("No changes needed; dns: section is already IPv4-only.")
        return 0

    if args.apply:
        new_text = "\n".join(new_lines) + ("\n" if trailing_newline else "")
        path.write_text(new_text, encoding="utf-8")
        print(f"Updated {path}")
    else:
        print("Dry run; pass --apply to write changes.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
