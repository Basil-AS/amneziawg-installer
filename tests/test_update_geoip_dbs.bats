#!/usr/bin/env bats
# Tests for scripts/update_geoip_dbs.py:
#   - dbip_candidate_urls() month/fallback computation
#   - looks_like_mmdb() validation
#   - end-to-end download/validate/atomic-replace + geoip_db_versions.json,
#     against a local HTTP server (no real network access)

bats_require_minimum_version 1.5.0

load test_helper

@test "update_geoip_dbs: dbip_candidate_urls returns current and previous month" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../scripts" python3 - <<'PY'
from datetime import datetime, timezone
import update_geoip_dbs as m

urls = m.dbip_candidate_urls(datetime(2026, 1, 15, tzinfo=timezone.utc))
assert urls == [
    "https://download.db-ip.com/free/dbip-city-lite-2026-01.mmdb.gz",
    "https://download.db-ip.com/free/dbip-city-lite-2025-12.mmdb.gz",
]

urls2 = m.dbip_candidate_urls(datetime(2026, 6, 1, tzinfo=timezone.utc))
assert urls2[0].endswith("2026-06.mmdb.gz")
assert urls2[1].endswith("2026-05.mmdb.gz")
PY
}

@test "update_geoip_dbs: looks_like_mmdb validates the MaxMind metadata marker" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../scripts" python3 - <<'PY'
import update_geoip_dbs as m

good = "/tmp/_geoip_good.mmdb"
bad = "/tmp/_geoip_bad.mmdb"
with open(good, "wb") as f:
    f.write(b"fake-mmdb-data" * 10 + m.MMDB_METADATA_MARKER + b"\x00" * 16)
with open(bad, "wb") as f:
    f.write(b"<html>not a database</html>")

assert m.looks_like_mmdb(good) is True
assert m.looks_like_mmdb(bad) is False
PY
}

@test "update_geoip_dbs: end-to-end download, validation, atomic replace, and version metadata" {
    command -v python3 &>/dev/null || skip "python3 not available"
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "$tmp/awg/web" "$tmp/serve"

    PYTHONPATH="$BATS_TEST_DIRNAME/../scripts" AWG_TMP="$tmp" python3 - <<'PY'
import gzip
import hashlib
import http.server
import json
import os
import threading
import urllib.request
from pathlib import Path

import update_geoip_dbs as m

tmp = Path(os.environ["AWG_TMP"])
serve_dir = tmp / "serve"
awg_dir = tmp / "awg"

# Fake MMDB content for City/ASN/Country
mmdb_bytes = b"fake-mmdb-payload-0123456789" + m.MMDB_METADATA_MARKER + b"\x00" * 8
(serve_dir / "GeoLite2-City.mmdb").write_bytes(mmdb_bytes)
(serve_dir / "GeoLite2-ASN.mmdb").write_bytes(mmdb_bytes + b"asn")
(serve_dir / "GeoLite2-Country.mmdb").write_bytes(mmdb_bytes + b"country")

# Fake gzip'd dbip city-lite
dbip_bytes = mmdb_bytes + b"dbip"
with gzip.open(serve_dir / "dbip-city-lite.mmdb.gz", "wb") as f:
    f.write(dbip_bytes)

# A bad/non-mmdb response for failure-path testing
(serve_dir / "not-a-db.mmdb").write_bytes(b"<html>error</html>")

httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), lambda *a, **kw: http.server.SimpleHTTPRequestHandler(*a, directory=str(serve_dir), **kw))
port = httpd.server_address[1]
thread = threading.Thread(target=httpd.serve_forever, daemon=True)
thread.start()
try:
    base = f"http://127.0.0.1:{port}"
    (awg_dir / "web").mkdir(parents=True, exist_ok=True)
    (awg_dir / "web" / "geoip_providers.json").write_text(json.dumps({
        "providers": {},
        "databases": {
            "maxmind_city": {"url": f"{base}/GeoLite2-City.mmdb"},
            "maxmind_asn": {"url": f"{base}/GeoLite2-ASN.mmdb"},
            "maxmind_country": {"url": f"{base}/GeoLite2-Country.mmdb"},
            "dbip_city_lite": {"url": f"{base}/dbip-city-lite.mmdb.gz"},
        },
    }), encoding="utf-8")

    rc = m.main(["--awg-dir", str(awg_dir)])
    assert rc == 0, rc

    geoip_dir = awg_dir / "geoip"
    city = geoip_dir / "GeoLite2-City.mmdb"
    asn = geoip_dir / "GeoLite2-ASN.mmdb"
    dbip = geoip_dir / "dbip-city-lite.mmdb"
    assert city.read_bytes() == mmdb_bytes
    assert asn.read_bytes() == mmdb_bytes + b"asn"
    assert dbip.read_bytes() == dbip_bytes

    versions = json.loads((geoip_dir / "geoip_db_versions.json").read_text())
    assert versions["maxmind_city"]["sha256"] == hashlib.sha256(mmdb_bytes).hexdigest()
    assert versions["maxmind_city"]["status"] == "ok"
    assert versions["dbip_city_lite"]["sha256"] == hashlib.sha256(dbip_bytes).hexdigest()
    for name in ("maxmind_city", "maxmind_asn", "maxmind_country", "dbip_city_lite"):
        assert (geoip_dir / versions[name]["filename"]).exists()

    # Re-running with a bad URL for one db: existing file is preserved, error recorded, exit 1
    (awg_dir / "web" / "geoip_providers.json").write_text(json.dumps({
        "providers": {},
        "databases": {
            "maxmind_city": {"url": f"{base}/not-a-db.mmdb"},
        },
    }), encoding="utf-8")
    rc2 = m.main(["--awg-dir", str(awg_dir), "--only", "maxmind_city"])
    assert rc2 == 1
    assert city.read_bytes() == mmdb_bytes  # untouched
    versions2 = json.loads((geoip_dir / "geoip_db_versions.json").read_text())
    assert "last_error" in versions2["maxmind_city"]
finally:
    httpd.shutdown()
PY
    rm -rf "$tmp"
}
