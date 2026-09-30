#!/usr/bin/env python3
"""Per-client AmneziaWG sender profile: unique junk/CPS parameters, MTU and keepalive.

Only parameters that are local to the sending side are varied per client:
Jc, Jmin, Jmax, I1 (a CPS packet the client sends before the handshake), MTU and
PersistentKeepalive.  S1-S4 and H1-H4 must stay identical on both ends of an
interface, so they are never touched here.  Giving every client its own junk
sizes and its own I1 removes the shared, repeated pattern that makes a server
easy to fingerprint.

Sub-commands (stdlib only, keys are never handled):
  presets                              list presets
  classify --asn AS8359 --org "..."    guess network type / carrier from ASN and org name
  generate --os android --network mobile [--carrier slug] [--device phone] [--preset name]
  env FILE                             print key=value lines for the shell from a saved profile
"""
from __future__ import annotations

import argparse
import json
import re
import secrets
import sys

OS_VALUES = ("android", "ios", "windows", "macos", "linux", "router", "other")
DEVICE_VALUES = ("phone", "tablet", "laptop", "desktop", "router", "tv", "other")
NETWORK_VALUES = ("mobile", "home", "office", "hosting", "unknown")
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")

# Best-effort classification.  ASN numbers change hands; the org-name patterns are
# the primary signal and the result is always marked as a heuristic.
MOBILE_ORG_RE = re.compile(
    r"\b(mobile|mobil|cellular|wireless|gsm|lte|mts|megafon|vimpelcom|beeline|tele2|t2 mobile|yota|"
    r"motiv|sbermobile|vodafone|orange|telefonica|verizon|t-mobile)\b",
    re.I,
)
CARRIERS = (
    ("mts", re.compile(r"\b(mts|mobile telesystems)\b", re.I)),
    ("megafon", re.compile(r"\bmegafon\b", re.I)),
    ("beeline", re.compile(r"\b(beeline|vimpelcom|vympelcom)\b", re.I)),
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
    "AS8359": ("mts", "mobile"),
    "AS31133": ("megafon", "mobile"),
    "AS3216": ("beeline", "mobile"),
    "AS16345": ("beeline", "mobile"),
    "AS41330": ("tele2", "mobile"),
    "AS12958": ("tele2", "mobile"),
    "AS12389": ("rostelecom", "home"),
    "AS31463": ("domru", "home"),
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
        "jc": (4, 6), "jmin": (40, 90), "jspan": (50, 150), "mtu": 1380, "keepalive": 25,
        "i1": "dns", "why": "wired/Wi-Fi ISP path, room for PPPoE and tunnel overhead",
    },
    "desktop": {
        "jc": (4, 6), "jmin": (48, 96), "jspan": (60, 160), "mtu": 1380, "keepalive": 25,
        "i1": "quic", "why": "desktop clients on home/office links",
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
    return "<b 0x" + head.hex() + "><r " + str(total - len(head)) + ">"


I1_STYLES = {"dns": dns_i1, "quic": quic_i1}


def classify(asn: str = "", org: str = "") -> dict:
    asn = (asn or "").upper().strip()
    if asn and not asn.startswith("AS"):
        asn = "AS" + asn
    org = org or ""
    network, carrier, basis = "unknown", "", "none"
    if asn in ASN_HINTS:
        carrier, network = ASN_HINTS[asn]
        basis = "asn"
    else:
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
        elif carrier in ("rostelecom", "domru", "mgts"):
            network = "home"
        elif org:
            network = "home"
            basis = "org-default"
    return {"network": network, "carrier": carrier, "basis": basis, "confidence": "heuristic"}


def suggest_preset(os_name: str = "", network: str = "", device: str = "") -> str:
    if os_name == "router" or device == "router":
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


def generate(os_name="", device="", network="", carrier="", preset="") -> dict:
    os_name, device, network = (os_name or "").lower(), (device or "").lower(), (network or "").lower()
    if os_name and os_name not in OS_VALUES:
        raise ValueError(f"os must be one of {', '.join(OS_VALUES)}")
    if device and device not in DEVICE_VALUES:
        raise ValueError(f"device must be one of {', '.join(DEVICE_VALUES)}")
    if network and network not in NETWORK_VALUES:
        raise ValueError(f"network must be one of {', '.join(NETWORK_VALUES)}")
    carrier = clean_slug(carrier)
    preset = preset or suggest_preset(os_name, network, device)
    if preset not in PRESETS:
        raise ValueError(f"unknown preset {preset!r}")
    spec = PRESETS[preset]
    jc = rand_range(*spec["jc"])
    jmin = rand_range(*spec["jmin"])
    jmax = jmin + rand_range(*spec["jspan"])
    return {
        "preset": preset,
        "tags": {"os": os_name, "device": device, "network": network, "carrier": carrier},
        "jc": jc, "jmin": jmin, "jmax": jmax,
        "mtu": spec["mtu"], "keepalive": spec["keepalive"],
        "i1": I1_STYLES[spec["i1"]](),
        "why": spec["why"],
    }


def env_lines(profile: dict) -> list[str]:
    """Only validated numeric fields and the I1 string are emitted for the shell."""
    out = []
    for key in ("jc", "jmin", "jmax", "mtu", "keepalive"):
        value = profile.get(key)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0 or value > 65535:
            raise ValueError(f"bad {key}")
        out.append(f"{key}={value}")
    if profile["jmin"] >= profile["jmax"]:
        raise ValueError("jmin must be below jmax")
    i1 = profile.get("i1", "")
    if i1:
        if not re.fullmatch(r"[ 0-9a-fA-Fx<>br]+", i1) or len(i1) > 2000:
            raise ValueError("bad i1")
        out.append(f"i1={i1}")
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
    a = ap.parse_args()
    try:
        if a.cmd == "presets":
            print(json.dumps({k: {**v, "jc": list(v["jc"]), "jmin": list(v["jmin"]), "jspan": list(v["jspan"])} for k, v in PRESETS.items()}, indent=2))
        elif a.cmd == "classify":
            print(json.dumps(classify(a.asn, a.org)))
        elif a.cmd == "generate":
            print(json.dumps(generate(a.os, a.device, a.network, a.carrier, a.preset)))
        else:
            with open(a.file, encoding="utf-8") as fh:
                print("\n".join(env_lines(json.load(fh))))
    except (ValueError, KeyError, OSError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
