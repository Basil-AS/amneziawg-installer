#!/usr/bin/env python3
"""Per-client AmneziaWG sender profile: unique junk/CPS parameters, MTU and keepalive.

Only parameters that are local to the sending side are varied per client:
Jc, Jmin, Jmax, I1-I5 (CPS packets the client sends before the handshake), MTU,
PersistentKeepalive and, for AWG 3.x, the local timers and content padding.  S1-S4 and H1-H4 must stay identical on both ends of an
interface, so they are never touched here.  Giving every client its own junk
sizes and its own I1 removes the shared, repeated pattern that makes a server
easy to fingerprint.

Sub-commands (stdlib only, keys are never handled):
  presets                              list presets
  classify --asn AS8359 --org "..."    guess network type / carrier from ASN and org name
  generate --os android --network mobile [--carrier slug] [--device phone] [--preset name]
  env FILE                             print key=value lines for the shell from a saved profile
  validate FILE                        check a profile (the web editor uses the same rules)
  i1 --style dns|quic                  generate one CPS packet
"""
from __future__ import annotations

import argparse
import json
import re
import secrets
import sys

# Suggestions only: labels are free-form slugs, so "openwrt", "keenetic" or any custom value is fine.
OS_VALUES = ("android", "ios", "windows", "macos", "linux", "openwrt", "router", "other")
DEVICE_VALUES = ("phone", "tablet", "laptop", "desktop", "router", "tv", "other")
NETWORK_VALUES = ("mobile", "home", "office", "hosting", "unknown")
ROUTER_OS = ("router", "openwrt", "keenetic", "mikrotik", "pfsense", "opnsense")
I_STYLES = ("dns", "quic")
LIMITS = {"jc": (0, 16), "jmin": (0, 1200), "jmax": (1, 1280), "mtu": (576, 1500), "keepalive": (0, 600)}
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")

# Best-effort classification.  ASN numbers change hands; the org-name patterns are
# the primary signal and the result is always marked as a heuristic.
# Generic words only: an operator brand in the name says nothing about the kind of access (mobile and wired
# customers share ASes and names).
MOBILE_ORG_RE = re.compile(r"\b(mobile|mobil|cellular|wireless|gsm|lte)\b", re.I)
CARRIERS = (
    ("mts", re.compile(r"\b(mts|mobile telesystems)\b", re.I)),
    ("megafon", re.compile(r"\bmegafon\b", re.I)),
    ("beeline", re.compile(r"\b(beeline|vimpelcom|vympelcom|corbina)\b", re.I)),
    ("tele2", re.compile(r"\b(tele2|t2 mobile)\b", re.I)),
    ("yota", re.compile(r"\byota\b", re.I)),
    ("rostelecom", re.compile(r"\b(rostelecom|rostelekom)\b", re.I)),
    ("domru", re.compile(r"\b(dom\.?ru|er-telecom|ertelecom)\b", re.I)),
    ("mgts", re.compile(r"\bmgts\b", re.I)),
)
HOSTING_ORG_RE = re.compile(
    r"\b(hosting|hetzner|ovh|digitalocean|vultr|linode|amazon|google cloud|microsoft|azure|contabo|"
    r"leaseweb|choopa|m247|datacamp|cloud|colo|vps|server)\b",
    re.I,
)
# ASN -> (carrier, network) hints for well-known networks.
ASN_HINTS = {
    # carrier only: mobile and wired customers can share an AS, so the AS never decides the network type
    "AS8359": ("mts", ""),
    "AS31133": ("megafon", ""),
    "AS3216": ("beeline", ""),
    "AS8402": ("beeline", ""),
    "AS16345": ("beeline", ""),
    "AS41330": ("tele2", ""),
    "AS12958": ("tele2", ""),
    "AS12389": ("rostelecom", ""),
    "AS31463": ("domru", ""),
}

# Presets: ranges are inclusive.  MTU values are deliberately conservative defaults; they are
# not measured on the client's path (probe with `ping -M do -s N` to raise them).
PRESETS = {
    "mobile": {
        "jc": (3, 4), "jmin": (32, 64), "jspan": (24, 72), "mtu": 1280, "keepalive": 25,
        "i1": "dns", "why": "cellular NAT rebinding and small path MTU: few, short junk packets, keepalive 25",
    },
    "ios": {
        "jc": (3, 4), "jmin": (32, 64), "jspan": (24, 72), "mtu": 1280, "keepalive": 25,
        "i1": "dns", "why": "iOS clients: conservative MTU, short junk",
    },
    "home": {
        "jc": (4, 6), "jmin": (40, 90), "jspan": (50, 150), "mtu": 1280, "keepalive": 25,
        "i1": "dns", "why": "wired/Wi-Fi ISP path; 1280 keeps padded packets below 1500 bytes (no fragmentation)",
    },
    "desktop": {
        "jc": (4, 6), "jmin": (48, 96), "jspan": (60, 160), "mtu": 1280, "keepalive": 25,
        "i1": "quic", "why": "desktop clients on home/office links; 1280 keeps padded packets below 1500 bytes",
    },
    "router": {
        "jc": (4, 7), "jmin": (48, 110), "jspan": (80, 220), "mtu": 1280, "keepalive": 25,
        "i1": "dns", "why": "always-on gateway: fixed 1280, more junk variety",
    },
    "stealth": {
        "jc": (4, 8), "jmin": (64, 160), "jspan": (120, 320), "mtu": 1280, "keepalive": 20,
        "i1": "dns", "why": "maximum packet-size variety, more overhead",
    },
}
DEFAULT_PRESET = "home"

# AWG 3.x local timers and content padding.  They are sender-side, so they can differ per client; the
# ranges stay inside what the reference profile uses so that no client becomes an outlier in the
# other direction.
EXTRA_RANGES = {
    "content_padding": ((8, 24), (40, 126)),     # low bound range, span range; high end stays <= 150
    "keepalive_timeout": ((20, 30), (6, 14)),
    "rekey_after_time": ((90, 115), (6, 20)),
    "rekey_timeout": ((2, 4), (1, 4)),
}
RANGE_RE = re.compile(r"^(\d{1,4})-(\d{1,4})$")

# Domains for the shape of the I1 packet.  Neutral, popular names; never SNIs that are known to be
# filtered (a filtered name in the very first packet would defeat the purpose).
DNS_DOMAINS = (
    "ya.ru", "yandex.ru", "mail.ru", "ozon.ru", "wildberries.ru", "gosuslugi.ru", "avito.ru",
    "sberbank.ru", "mos.ru", "kinopoisk.ru", "rbc.ru", "lenta.ru", "hh.ru", "2gis.ru",
)


def rand_range(lo: int, hi: int) -> int:
    return lo + secrets.randbelow(hi - lo + 1)


def dns_i1() -> str:
    """A DNS response-shaped packet: unique transaction id, TTL and address on every call."""
    domain = secrets.choice(DNS_DOMAINS)
    txid = bytearray(secrets.token_bytes(2))
    txid[0] |= 1  # odd first byte survives the even-first-byte drop seen on UDP/443 and UDP/80
    header = bytes(txid) + bytes.fromhex("8180") + bytes.fromhex("0001000100000000")
    qname = b"".join(bytes([len(p)]) + p.encode() for p in domain.split(".")) + b"\x00"
    question = qname + bytes.fromhex("00010001")
    ttl = rand_range(30, 3600).to_bytes(4, "big")
    while True:
        ip = bytes([rand_range(5, 223), rand_range(0, 255), rand_range(0, 255), rand_range(1, 254)])
        if ip[0] not in (10, 127) and not (ip[0] == 172 and 16 <= ip[1] <= 31) and not (ip[0] == 192 and ip[1] == 168):
            break
    answer = bytes.fromhex("c00c00010001") + ttl + bytes.fromhex("0004") + ip
    return "<b 0x" + (header + question + answer).hex() + ">"


def random_tags(n: int, limit: int = 1000) -> str:
    """`<r N>` tags that add up to n random bytes; one tag may not exceed `limit` bytes."""
    out = []
    while n > 0:
        part = min(n, limit)
        out.append("<r " + str(part) + ">")
        n -= part
    return "".join(out)


def quic_i1() -> str:
    """A QUIC Initial shaped packet: real long-header layout, then random bytes up to a realistic size.

    Real Initial packets are padded to at least 1200 bytes, so a 100-byte "QUIC" packet is itself an
    anomaly.  The random tail uses the `<r N>` tag, which keeps the CPS string short.
    """
    first = 0xC0 | (secrets.randbelow(4) << 4) | secrets.randbelow(4)
    first |= 1  # keep the first byte odd
    dcid = secrets.token_bytes(8)
    total = rand_range(1200, 1252)
    # version, dcid len + dcid, scid len 0, token length 0
    head = bytes([first]) + bytes.fromhex("00000001") + bytes([len(dcid)]) + dcid + bytes.fromhex("0000")
    length = total - len(head) - 2
    head += bytes([0x40 | (length >> 8), length & 0xFF])  # 2-byte QUIC varint payload length
    return "<b 0x" + head.hex() + ">" + random_tags(total - len(head))


I1_STYLES = {"dns": dns_i1, "quic": quic_i1}


def classify(asn: str = "", org: str = "") -> dict:
    asn = (asn or "").upper().strip()
    if asn and not asn.startswith("AS"):
        asn = "AS" + asn
    org = org or ""
    network, carrier, basis = "unknown", "", "none"
    if asn in ASN_HINTS:
        carrier = ASN_HINTS[asn][0]
        basis = "asn"
    if not carrier:
        for slug, rx in CARRIERS:
            if rx.search(org):
                carrier = slug
                basis = "org"
                break
    if MOBILE_ORG_RE.search(org):
        network = "mobile"
        basis = basis if basis != "none" else "org"
    elif HOSTING_ORG_RE.search(org):
        network = "hosting"
        basis = "org"
    elif org and not carrier:
        network = "home"
        basis = "org-default"
    return {"network": network, "carrier": carrier, "basis": basis, "confidence": "heuristic"}


def suggest_preset(os_name: str = "", network: str = "", device: str = "") -> str:
    if os_name in ROUTER_OS or device == "router":
        return "router"
    if network == "mobile" or (os_name in ("android", "ios") and network in ("", "unknown")):
        return "ios" if os_name == "ios" else "mobile"
    if os_name in ("windows", "macos", "linux") or device in ("laptop", "desktop"):
        return "desktop"
    return DEFAULT_PRESET


def clean_slug(value: str) -> str:
    value = (value or "").strip().lower()
    if value and not SLUG_RE.fullmatch(value):
        raise ValueError(f"invalid label {value!r}: use [a-z0-9_-], up to 32 chars")
    return value


def extra_values() -> dict:
    out = {}
    for key, (low, span) in EXTRA_RANGES.items():
        lo = rand_range(*low)
        out[key] = f"{lo}-{lo + rand_range(*span)}"
    return out


def generate(os_name="", device="", network="", carrier="", preset="", style="") -> dict:
    os_name, device, network = clean_slug(os_name), clean_slug(device), clean_slug(network)
    carrier = clean_slug(carrier)
    preset = preset or suggest_preset(os_name, network, device)
    if preset not in PRESETS:
        raise ValueError(f"unknown preset {preset!r}")
    spec = PRESETS[preset]
    style = style or spec["i1"]
    if style not in I1_STYLES:
        raise ValueError(f"unknown I1 style {style!r}")
    jc = rand_range(*spec["jc"])
    jmin = rand_range(*spec["jmin"])
    jmax = jmin + rand_range(*spec["jspan"])
    return {
        "preset": preset,
        "tags": {"os": os_name, "device": device, "network": network, "carrier": carrier},
        "jc": jc, "jmin": jmin, "jmax": jmax,
        "mtu": spec["mtu"], "keepalive": spec["keepalive"],
        "i1": I1_STYLES[style](),
        "extra": extra_values(),
        "why": spec["why"],
    }


def outer_packet_estimate(profile: dict, server_padding_hi: int = 100) -> int:
    """Worst-case size of an outer UDP/IPv4 packet carrying a full-MTU inner packet.

    inner MTU + 32 bytes AWG data header + 8 UDP + 20 IPv4 + the largest content padding either side adds.
    """
    mtu = int(profile.get("mtu") or 0)
    pad = server_padding_hi
    rng = (profile.get("extra") or {}).get("content_padding", "")
    m = RANGE_RE.fullmatch(str(rng))
    if m:
        pad = max(pad, int(m.group(2)))
    return mtu + 32 + 28 + pad


def mtu_warnings(profile: dict) -> list:
    out = []
    est = outer_packet_estimate(profile)
    if est > 1500:
        out.append(f"worst-case outer packet is about {est} bytes (> 1500): full-size packets with maximum padding will be "
                   "fragmented, which some networks drop. Lower the MTU or the content padding.")
    return out


def _int_field(profile: dict, key: str, default=None) -> int:
    value = profile.get(key, default)
    if value is None:
        raise ValueError(f"{key} is required")
    if isinstance(value, bool) or not isinstance(value, (int, str)) or (isinstance(value, str) and not value.strip().lstrip("-").isdigit()):
        raise ValueError(f"{key} must be an integer")
    value = int(value)
    lo, hi = LIMITS[key]
    if not lo <= value <= hi:
        raise ValueError(f"{key} must be between {lo} and {hi}")
    return value


def _cps(value: str, name: str) -> str:
    value = (value or "").strip()
    if not value:
        return ""
    if len(value) > 2000 or not re.fullmatch(r"[ 0-9a-fA-Fx<>br]+", value) or not ("<b 0x" in value or "<r " in value):
        raise ValueError(f"{name} must be a CPS string made of <b 0x..> and <r N> parts (up to 2000 chars)")
    return value


def validate_params(profile: dict) -> dict:
    """Return a cleaned profile or raise ValueError.  Only sender-side fields are accepted."""
    if not isinstance(profile, dict):
        raise ValueError("profile must be an object")
    out = {
        "jc": _int_field(profile, "jc"),
        "jmin": _int_field(profile, "jmin"),
        "jmax": _int_field(profile, "jmax"),
        "mtu": _int_field(profile, "mtu"),
        "keepalive": _int_field(profile, "keepalive"),
    }
    if out["jmin"] >= out["jmax"]:
        raise ValueError("jmin must be below jmax")
    for i in range(1, 6):
        v = _cps(str(profile.get(f"i{i}") or ""), f"i{i}")
        if v:
            out[f"i{i}"] = v
    extra_in = profile.get("extra") or {}
    if not isinstance(extra_in, dict):
        raise ValueError("extra must be an object")
    extra = {}
    for key in EXTRA_RANGES:
        v = str(extra_in.get(key) or "").strip()
        if not v:
            continue
        m = RANGE_RE.fullmatch(v)
        if not m or int(m.group(1)) > int(m.group(2)):
            raise ValueError(f"{key} must look like 10-100")
        extra[key] = v
    if extra:
        out["extra"] = extra
    preset = str(profile.get("preset") or "custom")
    out["preset"] = preset if (preset in PRESETS or preset == "custom") else "custom"
    tags = profile.get("tags")
    if isinstance(tags, dict):
        out["tags"] = {k: clean_slug(str(tags.get(k) or "")) for k in ("os", "device", "network", "carrier")}
    return out


def env_lines(profile: dict) -> list[str]:
    """Only validated fields are emitted for the shell, one key=value per line."""
    p = validate_params(profile)
    out = [f"{k}={p[k]}" for k in ("jc", "jmin", "jmax", "mtu", "keepalive")]
    for i in range(1, 6):
        if p.get(f"i{i}"):
            out.append(f"i{i}={p[f'i{i}']}")
    for key, value in (p.get("extra") or {}).items():
        out.append(f"{key}={value}")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("presets")
    c = sub.add_parser("classify")
    c.add_argument("--asn", default="")
    c.add_argument("--org", default="")
    g = sub.add_parser("generate")
    for opt in ("os", "device", "network", "carrier", "preset"):
        g.add_argument(f"--{opt}", default="")
    e = sub.add_parser("env")
    e.add_argument("file")
    v = sub.add_parser("validate")
    v.add_argument("file")
    i = sub.add_parser("i1")
    i.add_argument("--style", default="dns")
    a = ap.parse_args()
    try:
        if a.cmd == "presets":
            print(json.dumps({k: {**v, "jc": list(v["jc"]), "jmin": list(v["jmin"]), "jspan": list(v["jspan"])} for k, v in PRESETS.items()}, indent=2))
        elif a.cmd == "classify":
            print(json.dumps(classify(a.asn, a.org)))
        elif a.cmd == "generate":
            print(json.dumps(generate(a.os, a.device, a.network, a.carrier, a.preset)))
        elif a.cmd == "i1":
            if a.style not in I1_STYLES:
                raise ValueError(f"style must be one of {', '.join(I_STYLES)}")
            print(I1_STYLES[a.style]())
        elif a.cmd == "validate":
            with open(a.file, encoding="utf-8") as fh:
                print(json.dumps(validate_params(json.load(fh))))
        else:
            with open(a.file, encoding="utf-8") as fh:
                print("\n".join(env_lines(json.load(fh))))
    except (ValueError, KeyError, OSError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
