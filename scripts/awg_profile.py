#!/usr/bin/env python3
"""Canonical AmneziaWG profile validation and rendering."""
from __future__ import annotations

import argparse
import base64
import json
import os
import random
import sys
from pathlib import Path

VERSIONS = ("1.5", "2.0", "3.0", "3.1")
UINT16_MAX = 65535
UINT32_MAX = 4294967295


def _integer(value: object, name: str, maximum: int = UINT32_MAX) -> int:
    if isinstance(value, bool):
        raise ValueError(f"{name} must be an integer")
    try:
        result = int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} must be an integer") from exc
    if result < 0 or result > maximum:
        raise ValueError(f"{name} is outside the supported range")
    return result


def _range(value: object, name: str, maximum: int = UINT32_MAX) -> str:
    if isinstance(value, int) and not isinstance(value, bool):
        return str(_integer(value, name, maximum))
    if not isinstance(value, str) or not value.isascii():
        raise ValueError(f"{name} must be an integer or min-max range")
    parts = value.split("-")
    if len(parts) not in (1, 2) or any(not part.isdigit() for part in parts):
        raise ValueError(f"{name} must be an integer or min-max range")
    low = _integer(parts[0], name, maximum)
    high = _integer(parts[-1], name, maximum)
    if low > high:
        raise ValueError(f"{name} range minimum exceeds maximum")
    return str(low) if low == high else f"{low}-{high}"


def _header_key(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError("headerProtectionKey must be base64")
    try:
        decoded = base64.b64decode(value, validate=True)
    except Exception as exc:
        raise ValueError("headerProtectionKey must be base64") from exc
    if len(decoded) != 32:
        raise ValueError("headerProtectionKey must encode 32 bytes")
    return value


def validate(profile: dict[str, object], version: str = "3.1") -> dict[str, object]:
    if version not in VERSIONS:
        raise ValueError("unsupported protocol version")
    required = ["jc", "jmin", "jmax", "s1", "s2", "h1", "h2", "h3", "h4"]
    if version != "1.5":
        required.extend(("s3", "s4"))
    missing = [field for field in required if field not in profile]
    if version in ("3.0", "3.1") and "headerProtectionKey" not in profile:
        missing.append("headerProtectionKey")
    if missing:
        raise ValueError("missing required profile fields: " + ", ".join(missing))

    result: dict[str, object] = {"protocolVersion": version}
    result["jc"] = _integer(profile["jc"], "jc")
    result["jmin"] = _integer(profile["jmin"], "jmin")
    result["jmax"] = _integer(profile["jmax"], "jmax")
    if result["jmin"] > result["jmax"]:
        raise ValueError("jmin exceeds jmax")
    for field in ("s1", "s2") + (("s3", "s4") if version != "1.5" else ()):
        result[field] = _integer(profile[field], field, UINT16_MAX)
        if version in ("3.0", "3.1") and result[field] < 12:
            raise ValueError(f"{field} must be at least 12 for AWG {version} header protection")
    if version in ("3.0", "3.1"):
        packet_lengths = (148 + result["s1"], 92 + result["s2"],
                          64 + result["s3"], 32 + result["s4"])
        if len(set(packet_lengths)) != len(packet_lengths):
            raise ValueError("AWG 3.1 padded handshake lengths must be unique")

    ranges: dict[str, tuple[int, int]] = {}
    for field in ("h1", "h2", "h3", "h4"):
        text = _range(profile[field], field)
        numbers = [int(part) for part in text.split("-")]
        ranges[field] = (numbers[0], numbers[-1])
        result[field] = text
    fields = list(ranges)
    for index, left in enumerate(fields):
        for right in fields[index + 1:]:
            if ranges[left][0] <= ranges[right][1] and ranges[right][0] <= ranges[left][1]:
                raise ValueError(f"{left} and {right} ranges overlap")

    for field, value in profile.items():
        if field in result or field == "protocolVersion":
            continue
        if field in ("headerProtectionKey",):
            result[field] = _header_key(value)
        elif field in ("contentPaddingAddition", "rekeyAfterTime", "rekeyTimeout",
                       "rejectAfterTime", "keepaliveTimeout", "maxHandshakeAttempts"):
            result[field] = _range(value, field, UINT16_MAX)
        elif field in ("randomTrailers", "disableCookies"):
            if not isinstance(value, bool):
                raise ValueError(f"{field} must be boolean")
            result[field] = value
        elif isinstance(value, str) and value.isascii():
            result[field] = value
        else:
            raise ValueError(f"{field} must be an ASCII string")
    return result


def generate(version: str, seed: int | None = None) -> dict[str, object]:
    rng = random.SystemRandom() if seed is None else random.Random(seed)
    if version in ("3.0", "3.1"):
        s1, s2, s3 = _generate_s_values(rng)
        # Keep every endpoint <= INT32_MAX for standalone Windows clients.
        h_ranges = ("268435456-368435455", "536870912-636870911",
                     "1073741824-1173741823", "1610612736-1710612735")
    elif version == "1.5":
        s1, s2 = (rng.randrange(15, 151), rng.randrange(15, 151))
        s3 = s4 = None
        h_ranges = ("1", "2", "3", "4")
    else:
        s1, s2, s3 = (rng.randrange(12, 151), rng.randrange(12, 151), rng.randrange(12, 65))
        h_ranges = ("1000-1999", "3000-3999", "5000-5999", "7000-7999")
    profile: dict[str, object] = {
        "jc": rng.randrange(4, 7), "jmin": 10, "jmax": 50,
        "s1": s1, "s2": s2,
        "h1": h_ranges[0], "h2": h_ranges[1],
        "h3": h_ranges[2], "h4": h_ranges[3],
    }
    if version != "1.5":
        profile.update({"s3": s3, "s4": 12})
    if version in ("3.0", "3.1"):
        profile.update({
            "headerProtectionKey": base64.b64encode(os.urandom(32)).decode("ascii"),
            "contentPaddingAddition": "10-100", "rekeyAfterTime": "100-120",
            "rekeyTimeout": "3-7", "rejectAfterTime": "150-180",
            "keepaliveTimeout": "25-35", "maxHandshakeAttempts": "15-20",
        })
        if version == "3.1":
            profile.update({"randomTrailers": False, "disableCookies": False})
    return validate(profile, version)


def _generate_s_values(rng: random.Random) -> tuple[int, int, int]:
    """Choose 3.1 S values whose resulting handshake lengths cannot collide."""
    for _ in range(128):
        values = (rng.randrange(12, 150), rng.randrange(12, 150), rng.randrange(12, 64))
        lengths = (148 + values[0], 92 + values[1], 64 + values[2], 44)
        if len(set(lengths)) == len(lengths):
            return values
    raise RuntimeError("unable to generate unique AWG 3.1 padding lengths")


def render(profile: dict[str, object]) -> str:
    checked = validate(profile, str(profile.get("protocolVersion", "3.1")))
    names = (("jc", "Jc"), ("jmin", "Jmin"), ("jmax", "Jmax"),
             ("s1", "S1"), ("s2", "S2"), ("s3", "S3"), ("s4", "S4"),
             ("h1", "H1"), ("h2", "H2"), ("h3", "H3"), ("h4", "H4"),
             ("i1", "I1"), ("i2", "I2"), ("i3", "I3"), ("i4", "I4"), ("i5", "I5"),
             ("contentPaddingAddition", "ContentPaddingAddition"),
             ("headerProtectionKey", "HeaderProtectionKey"),
             ("maxHandshakeAttempts", "MaxHandshakeAttempts"),
             ("keepaliveTimeout", "KeepaliveTimeout"), ("rejectAfterTime", "RejectAfterTime"),
             ("rekeyAfterTime", "RekeyAfterTime"), ("rekeyTimeout", "RekeyTimeout"),
             ("randomTrailers", "RandomTrailers"), ("disableCookies", "DisableCookies"))
    lines = []
    for key, name in names:
        if key in checked:
            value = str(checked[key]).lower() if isinstance(checked[key], bool) else checked[key]
            lines.append(f"{name} = {value}")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("generate", "validate", "render"))
    parser.add_argument("--version", default="3.1", choices=VERSIONS)
    parser.add_argument("--input", type=Path)
    parser.add_argument("--seed", type=int)
    args = parser.parse_args()
    try:
        if args.command == "generate":
            value = generate(args.version, args.seed)
        else:
            if not args.input:
                raise ValueError("--input is required")
            value = json.loads(args.input.read_text(encoding="utf-8"))
            value = validate(value, args.version)
        if args.command == "render":
            sys.stdout.write(render(value))
        else:
            json.dump(value, sys.stdout, ensure_ascii=True, sort_keys=True)
            sys.stdout.write("\n")
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
