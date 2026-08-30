#!/usr/bin/env python3
"""Render an Amnezia ``vpn://`` import URI from a client config.

The generator deliberately keeps private material in the environment.  Only
the config path is passed on the command line, so keys never appear in the
process argument list.  The output is the canonical URI on stdout.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import struct
import sys
import zlib
from pathlib import Path


def values(text: str) -> dict[str, str]:
    result: dict[str, str] = {}
    section = ""
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith(";"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip().lower()
            continue
        if section not in {"interface", "peer"} or "=" not in line:
            continue
        key, value = line.split("=", 1)
        result.setdefault(key.strip().lower(), value.strip())
    return result


def endpoint_host(endpoint: str) -> str:
    if endpoint.startswith("["):
        host, separator, _port = endpoint[1:].partition("]:")
        if not separator:
            raise ValueError("invalid bracketed endpoint")
        return host
    if ":" not in endpoint:
        raise ValueError("endpoint has no port")
    return endpoint.rsplit(":", 1)[0]


def env_required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise ValueError(f"missing {name}")
    return value


def render(conf_path: Path) -> str:
    raw = conf_path.read_text(encoding="utf-8")
    cfg = values(raw)
    port = os.environ.get("AWG_PORT", "")
    if not port.isdigit():
        raise ValueError("AWG_PORT must be numeric")
    protocol = os.environ.get("AWG_PROTOCOL_VERSION", "2.0")
    if protocol not in {"1.5", "2.0", "3.0", "3.1"}:
        raise ValueError("unsupported AWG protocol version")

    addresses = [item.strip() for item in cfg.get("address", "").split(",") if item.strip()]
    if not addresses:
        raise ValueError("client Address is missing")
    client_ip = addresses[0].split("/", 1)[0]
    client_ipv6 = addresses[1].split("/", 1)[0] if len(addresses) > 1 else ""
    endpoint = endpoint_host(cfg.get("endpoint", ""))
    allowed = [item.strip() for item in cfg.get("allowedips", "").split(",") if item.strip()]
    if not allowed:
        allowed = ["0.0.0.0/0"]
    dns = [item.strip() for item in cfg.get("dns", "").split(",") if item.strip()]
    dns1 = dns[0] if dns else "1.1.1.1"
    dns2 = dns[1] if len(dns) > 1 else dns1

    fields = {key: os.environ.get(key, "") for key in
              ("AWG_H1", "AWG_H2", "AWG_H3", "AWG_H4", "AWG_Jc", "AWG_Jmin",
               "AWG_Jmax", "AWG_S1", "AWG_S2", "AWG_S3", "AWG_S4", "AWG_I1",
               "AWG_I2", "AWG_I3", "AWG_I4", "AWG_I5")}
    inner: dict[str, object] = {
        "H1": fields["AWG_H1"], "H2": fields["AWG_H2"],
        "H3": fields["AWG_H3"], "H4": fields["AWG_H4"],
        "Jc": fields["AWG_Jc"], "Jmin": fields["AWG_Jmin"],
        "Jmax": fields["AWG_Jmax"], "S1": fields["AWG_S1"],
        "S2": fields["AWG_S2"],
        "allowed_ips": allowed, "client_ip": client_ip, "client_ipv6": client_ipv6,
        "client_priv_key": env_required("AWG_URI_CPK"), "config": raw.rstrip("\r\n"),
        "hostName": endpoint, "mtu": cfg.get("mtu", "1280"),
        "persistent_keep_alive": cfg.get("persistentkeepalive", "33"),
        "port": int(port), "server_pub_key": env_required("AWG_URI_SPK"),
    }
    if cfg.get("presharedkey"):
        inner["psk_key"] = cfg["presharedkey"]
    if protocol != "1.5":
        inner["S3"] = fields["AWG_S3"]
        inner["S4"] = fields["AWG_S4"]
    if protocol in ("3.0", "3.1"):
        required = {
            "ContentPaddingAddition": "contentpaddingaddition",
            "HeaderProtectionKey": "headerprotectionkey",
            "MaxHandshakeAttempts": "maxhandshakeattempts",
            "KeepaliveTimeout": "keepalivetimeout",
            "RejectAfterTime": "rejectaftertime",
            "RekeyAfterTime": "rekeyaftertime",
            "RekeyTimeout": "rekeytimeout",
            "RandomTrailers": "randomtrailers",
            "DisableCookies": "disablecookies",
        }
        for output, input_key in required.items():
            value = cfg.get(input_key, "")
            if not value:
                raise ValueError(f"missing AWG {protocol} field {output}")
            inner[output] = value
    if protocol != "1.5" and any(fields[f"AWG_I{i}"] for i in range(1, 6)):
        for i in range(1, 6):
            inner[f"I{i}"] = fields[f"AWG_I{i}"]

    inner_json = json.dumps(inner, ensure_ascii=False, separators=(",", ":"))
    outer = {
        "containers": [{"awg": {"isThirdPartyConfig": True,
                                  "last_config": inner_json, "port": port,
                                  "protocol_version": protocol, "transport_proto": "udp"},
                        "container": "amnezia-awg"}],
        "defaultContainer": "amnezia-awg",
        "name": os.environ.get("AWG_SERVER_NAME", "AWG Server"),
        "defaultName": os.environ.get("AWG_SERVER_NAME", "AWG Server"),
        "description": os.environ.get("AWG_SERVER_NAME", "AWG Server"),
        "dns1": dns1, "dns2": dns2, "hostName": endpoint,
    }
    outer_json = json.dumps(outer, ensure_ascii=False, separators=(",", ":"))
    payload = struct.pack(">I", len(outer_json.encode("utf-8"))) + zlib.compress(outer_json.encode("utf-8"))
    return "vpn://" + base64.urlsafe_b64encode(payload).decode("ascii").rstrip("=")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--conf", required=True, type=Path)
    args = parser.parse_args()
    try:
        print(render(args.conf))
    except (OSError, ValueError, UnicodeError) as exc:
        print(f"vpn:// generation failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
