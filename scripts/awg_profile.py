#!/usr/bin/env python3
"""Canonical AmneziaWG profile validation and rendering."""
from __future__ import annotations

import argparse
import base64
import json
import random
import sys
from pathlib import Path

VERSIONS = ("1.5", "2.0", "3.0", "3.1")
PROFILES = ("mobile", "balanced", "stealth", "compatibility")
UINT16_MAX = 65535
UINT32_MAX = 4294967295
INT32_MAX = 2147483647

# Profiles describe traffic-shape choices, not protocol versions.  Keep the
# ranges deliberately broad and generate H ranges per installation so two
# servers do not receive the same static fingerprint.  The values are kept in
# one canonical generator so the installer, management commands, and tests do
# not slowly acquire different parameter rules.
PROFILE_SPECS = {
    "mobile": {
        "jc": (3, 3), "jmin": (30, 50), "jspan": (20, 80),
        "s12": (12, 149), "s3": (12, 63), "h_width": 32768,
        "keepalive": (25, 35), "padding": (8, 64),
    },
    "balanced": {
        "jc": (4, 6), "jmin": (40, 89), "jspan": (50, 150),
        "s12": (12, 149), "s3": (12, 63), "h_width": 65536,
        "keepalive": (25, 35), "padding": (10, 100),
    },
    "stealth": {
        "jc": (3, 8), "jmin": (64, 160), "jspan": (160, 420),
        "s12": (20, 149), "s3": (16, 63), "h_width": 131072,
        "keepalive": (20, 35), "padding": (16, 160),
    },
    "compatibility": {
        "jc": (3, 5), "jmin": (20, 64), "jspan": (20, 80),
        "s12": (15, 150), "s3": (12, 63), "h_width": 4096,
        "keepalive": (25, 35), "padding": (4, 32),
    },
}


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


def _generate_h_ranges(rng: random.Random, width: int) -> tuple[str, str, str, str]:
    """Generate four non-overlapping ranges in the Windows-safe int32 space."""
    minimum = 5
    available = INT32_MAX - minimum + 1
    segment = available // 4
    starts = []
    for index in range(4):
        segment_start = minimum + index * segment
        segment_end = minimum + (index + 1) * segment - 1
        latest = segment_end - width + 1
        start = rng.randrange(segment_start, max(segment_start, latest) + 1)
        starts.append(start)
    return tuple(f"{start}-{start + width - 1}" for start in starts)  # type: ignore[return-value]


def generate(version: str, seed: int | None = None, profile: str = "balanced") -> dict[str, object]:
    if profile not in PROFILES:
        raise ValueError("unsupported profile")
    rng = random.SystemRandom() if seed is None else random.Random(seed)
    spec = PROFILE_SPECS[profile]
    if version in ("3.0", "3.1"):
        s1, s2, s3 = _generate_s_values(rng, spec["s12"], spec["s3"])
        h_ranges = _generate_h_ranges(rng, spec["h_width"])
    elif version == "1.5":
        s1, s2 = (rng.randrange(15, 151), rng.randrange(15, 151))
        s3 = s4 = None
        h_ranges = ("1", "2", "3", "4")
    else:
        s1, s2, s3 = _generate_s_values(rng, spec["s12"], spec["s3"])
        h_ranges = _generate_h_ranges(rng, spec["h_width"])
    jmin = rng.randrange(spec["jmin"][0], spec["jmin"][1] + 1)
    jmax = min(UINT32_MAX, jmin + rng.randrange(spec["jspan"][0], spec["jspan"][1] + 1))
    profile: dict[str, object] = {
        "profile": profile, "jc": rng.randrange(spec["jc"][0], spec["jc"][1] + 1),
        "jmin": jmin, "jmax": jmax,
        "s1": s1, "s2": s2,
        "h1": h_ranges[0], "h2": h_ranges[1],
        "h3": h_ranges[2], "h4": h_ranges[3],
    }
    if version != "1.5":
        profile.update({"s3": s3, "s4": 12})
    if version in ("3.0", "3.1"):
        profile.update({
            # SystemRandom remains cryptographically strong for normal runs;
            # using the selected RNG here also makes --seed fully reproducible
            # for CI fixtures without ever printing or logging the key.
            "headerProtectionKey": base64.b64encode(bytes(rng.randrange(256) for _ in range(32))).decode("ascii"),
            "contentPaddingAddition": f"{spec['padding'][0]}-{spec['padding'][1]}",
            "rekeyAfterTime": "100-120",
            "rekeyTimeout": "3-7", "rejectAfterTime": "150-180",
            "keepaliveTimeout": f"{spec['keepalive'][0]}-{spec['keepalive'][1]}",
            "maxHandshakeAttempts": "15-20",
        })
        if version == "3.1":
            # Random trailers are part of the bilateral 3.1 profile: both
            # peers receive the same setting through the canonical renderer.
            # Keep cookies enabled for the default profile because disabling
            # them removes WireGuard's handshake-flood protection.
            profile.update({"randomTrailers": True, "disableCookies": False})
    return validate(profile, version)


def _generate_s_values(rng: random.Random, s12_range: tuple[int, int], s3_range: tuple[int, int]) -> tuple[int, int, int]:
    """Choose 3.1 S values whose resulting handshake lengths cannot collide."""
    for _ in range(128):
        values = (rng.randrange(s12_range[0], s12_range[1] + 1),
                  rng.randrange(s12_range[0], s12_range[1] + 1),
                  rng.randrange(s3_range[0], s3_range[1] + 1))
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
    parser.add_argument("--profile", default="balanced", choices=PROFILES)
    args = parser.parse_args()
    try:
        if args.command == "generate":
            value = generate(args.version, args.seed, args.profile)
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
