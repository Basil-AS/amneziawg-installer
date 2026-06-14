#!/usr/bin/env python3
"""Download free GeoIP MMDB databases used by the Web Panel's GeoIP providers.

By default this fetches:
  - GeoLite2-ASN.mmdb, GeoLite2-City.mmdb, GeoLite2-Country.mmdb from the
    P3TERX/GeoLite.mmdb community mirror (rebuilt daily from MaxMind's
    GeoLite2 data, no license key required), and
  - dbip-city-lite.mmdb from the DB-IP City Lite npm/jsdelivr mirror.

into <AWG_DIR>/geoip/, validating each file looks like a real MMDB (checks
for the MaxMind.com metadata marker), atomically replacing any existing
file, and recording sha256/size/source/timestamp metadata in
<AWG_DIR>/geoip/geoip_db_versions.json.

These files feed web/server.py's "maxmind" and "dbip_mmdb" GeoIP providers
(_fetch_mmdb_provider / _fetch_dbip_mmdb_provider), which are tried before
any external (2ip/ipinfo/dbip/ip-api) provider. A missing or stale MMDB is
not fatal: lookups fall back to ip-api.com (no token required) and any
configured external providers.

Download URLs can be overridden per-database via the "databases" section of
<AWG_DIR>/web/geoip_providers.json, e.g.:
  {"databases": {"maxmind_city": {"url": "https://example/City.mmdb"}}}
"""
import argparse
import gzip
import hashlib
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

MMDB_METADATA_MARKER = b"\xab\xcd\xefMaxMind.com"
MMDB_METADATA_SEARCH_WINDOW = 128 * 1024

DEFAULT_SOURCES = {
    "maxmind_asn": {
        "urls": ["https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-ASN.mmdb"],
        "filename": "GeoLite2-ASN.mmdb",
    },
    "maxmind_city": {
        "urls": ["https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-City.mmdb"],
        "filename": "GeoLite2-City.mmdb",
    },
    "maxmind_country": {
        "urls": ["https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-Country.mmdb"],
        "filename": "GeoLite2-Country.mmdb",
    },
    "dbip_city_lite": {
        "urls": ["https://cdn.jsdelivr.net/npm/dbip-city-lite/dbip-city-lite.mmdb.gz"],
        "filename": "dbip-city-lite.mmdb",
    },
}


def dbip_url_for(year, month):
    return f"https://download.db-ip.com/free/dbip-city-lite-{year:04d}-{month:02d}.mmdb.gz"


def dbip_candidate_urls(now=None):
    """DB-IP publishes one free city-lite release per month. Try the current
    month first, then fall back to the previous month (covers the first
    days of a new month before that release is published)."""
    now = now or datetime.now(timezone.utc)
    prev_month = now.month - 1 or 12
    prev_year = now.year if now.month > 1 else now.year - 1
    return [dbip_url_for(now.year, now.month), dbip_url_for(prev_year, prev_month)]


def load_database_overrides(config_path):
    try:
        data = json.loads(Path(config_path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    overrides = data.get("databases")
    return overrides if isinstance(overrides, dict) else {}


def resolve_sources(config_path):
    overrides = load_database_overrides(config_path)
    sources = {}
    for name, default in DEFAULT_SOURCES.items():
        cfg = dict(default)
        override = overrides.get(name) or {}
        if override.get("url"):
            cfg["urls"] = [override["url"]]
        elif override.get("urls"):
            cfg["urls"] = list(override["urls"])
        elif cfg.get("urls") is None:
            cfg["urls"] = dbip_candidate_urls()
        if override.get("filename"):
            cfg["filename"] = override["filename"]
        sources[name] = cfg
    return sources


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def looks_like_mmdb(path):
    """Return True if `path` ends with the MaxMind DB metadata marker
    within the last MMDB_METADATA_SEARCH_WINDOW bytes."""
    size = os.path.getsize(path)
    if size < len(MMDB_METADATA_MARKER):
        return False
    with open(path, "rb") as fh:
        fh.seek(max(0, size - MMDB_METADATA_SEARCH_WINDOW))
        tail = fh.read()
    return MMDB_METADATA_MARKER in tail


def download_to_file(url, dest, timeout):
    req = urllib.request.Request(url, headers={"User-Agent": "awg-geoip-updater/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as resp, open(dest, "wb") as out:
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)


def fetch_database(name, cfg, geoip_dir, timeout, dry_run=False):
    """Download, (optionally) decompress, validate and atomically install one
    MMDB. Returns a metadata dict on success, or {"error": "..."}."""
    final_path = geoip_dir / cfg["filename"]
    last_error = "no URL configured"
    for url in cfg["urls"] or []:
        if dry_run:
            return {"url": url, "status": "dry-run"}
        tmp_fd, tmp_name = tempfile.mkstemp(prefix=f".{name}.", suffix=".tmp", dir=str(geoip_dir))
        os.close(tmp_fd)
        tmp_path = Path(tmp_name)
        try:
            download_to_file(url, tmp_path, timeout)
            if url.endswith(".gz"):
                decompressed = tmp_path.with_suffix(".decompressed")
                with gzip.open(tmp_path, "rb") as src, open(decompressed, "wb") as dst:
                    while True:
                        chunk = src.read(1 << 20)
                        if not chunk:
                            break
                        dst.write(chunk)
                tmp_path.unlink(missing_ok=True)
                tmp_path = decompressed
            if not looks_like_mmdb(tmp_path):
                last_error = f"downloaded file from {url} does not look like an MMDB"
                tmp_path.unlink(missing_ok=True)
                continue
            digest = sha256_file(tmp_path)
            size = os.path.getsize(tmp_path)
            os.chmod(tmp_path, 0o644)
            os.replace(tmp_path, final_path)
            return {
                "url": url,
                "filename": cfg["filename"],
                "sha256": digest,
                "size_bytes": size,
                "downloaded_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "status": "ok",
            }
        except (OSError, urllib.error.URLError, urllib.error.HTTPError) as exc:
            last_error = f"{url}: {exc}"
            tmp_path.unlink(missing_ok=True)
            continue
    return {"error": last_error, "status": "error"}


def write_versions_file(versions_file, versions):
    tmp = versions_file.with_name(f"{versions_file.name}.tmp.{os.getpid()}")
    tmp.write_text(json.dumps(versions, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, versions_file)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--awg-dir", default=os.environ.get("AWG_DIR", "/root/awg"))
    parser.add_argument("--config", default=None, help="Path to geoip_providers.json (default: <awg-dir>/web/geoip_providers.json)")
    parser.add_argument("--only", action="append", choices=sorted(DEFAULT_SOURCES), help="Only update this database (repeatable)")
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--dry-run", action="store_true", help="Resolve URLs without downloading")
    args = parser.parse_args(argv)

    awg_dir = Path(args.awg_dir)
    geoip_dir = awg_dir / "geoip"
    geoip_dir.mkdir(parents=True, exist_ok=True)
    config_path = Path(args.config) if args.config else awg_dir / "web" / "geoip_providers.json"
    versions_file = geoip_dir / "geoip_db_versions.json"

    try:
        versions = json.loads(versions_file.read_text(encoding="utf-8"))
        if not isinstance(versions, dict):
            versions = {}
    except (OSError, ValueError):
        versions = {}

    sources = resolve_sources(config_path)
    names = args.only or sorted(sources)

    failures = 0
    for name in names:
        cfg = sources[name]
        result = fetch_database(name, cfg, geoip_dir, args.timeout, dry_run=args.dry_run)
        if result.get("status") == "error":
            failures += 1
            print(f"update_geoip_dbs: {name}: FAILED: {result.get('error')}", file=sys.stderr)
            versions.setdefault(name, {})["last_error"] = result.get("error")
            versions[name]["last_attempt_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        elif result.get("status") == "dry-run":
            print(f"update_geoip_dbs: {name}: would fetch {result.get('url')}")
        else:
            print(f"update_geoip_dbs: {name}: updated ({result.get('size_bytes')} bytes, sha256={result.get('sha256')[:12]}...)")
            versions[name] = result

    if not args.dry_run:
        write_versions_file(versions_file, versions)

    return 1 if failures and not args.dry_run else 0


if __name__ == "__main__":
    sys.exit(main())
