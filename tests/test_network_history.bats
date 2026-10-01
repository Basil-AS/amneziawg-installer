#!/usr/bin/env bats
# Web panel: long-term network history per client and mobile/home inference.

setup() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/scripts" "$TMP/web"
    cp "$BATS_TEST_DIRNAME/../scripts/awg_client_profile.py" "$TMP/scripts/"
    export AWG_DIR="$TMP"
}

teardown() { rm -rf "$TMP"; }

@test "network history: a manual rule wins and the most specific rule is used" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import server
rules = [{"cidr": "198.51.100.0/24", "type": "home", "note": ""}, {"cidr": "198.51.100.64/26", "type": "mobile", "note": "cgnat pool"}]
rec = {"ip": "198.51.100.70", "asn": "AS1", "org": "Some Hosting", "ptr": "x.lte.example"}
v = server.infer_network_type(rec, {}, [], {}, rules)
assert v["type"] == "mobile" and v["confidence"] == 1.0 and "198.51.100.64/26" in v["signals"][0], v
v = server.infer_network_type({"ip": "198.51.100.5"}, {}, [], {}, rules)
assert v["type"] == "home", v
PY
}

@test "network history: same AS, different verdicts from ptr, behaviour and neighbours" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import time, server
now = time.time()
base = {"asn": "AS3216", "org": "PJSC VimpelCom"}
# 1) reverse dns says mobile
v = server.infer_network_type({**base, "ip": "203.0.113.10", "ptr": "10-113-0-203.lte.example.net", "first_seen": now, "last_seen": now, "sessions": 1}, {}, [], {}, [], now)
assert v["type"] == "mobile", v
# 2) reverse dns says wired
v = server.infer_network_type({**base, "ip": "203.0.113.20", "ptr": "pppoe-203-0-113-20.example.net", "first_seen": now, "last_seen": now, "sessions": 1}, {}, [], {}, [], now)
assert v["type"] == "home", v
# 3) no names: churn inside one /16 means carrier-grade NAT
events = [{"t": now - 3600 * i, "ip": f"203.0.{i}.9", "port": 1000 + i} for i in range(1, 5)]
v = server.infer_network_type({**base, "ip": "203.0.1.9", "first_seen": now - 4 * 3600, "last_seen": now, "sessions": 4, "ports": [1, 2, 3, 4]}, {}, events, {}, [], now)
assert v["type"] == "mobile" and any("/16" in s for s in v["signals"]), v
# 4) the same address for days with few sessions is a fixed line
v = server.infer_network_type({**base, "ip": "203.0.113.30", "first_seen": now - 5 * 86400, "last_seen": now, "sessions": 2}, {}, [], {}, [], now)
assert v["type"] == "home", v
# 5) neighbours that are already classified lend weight
v = server.infer_network_type({**base, "ip": "203.0.113.40", "first_seen": now, "last_seen": now, "sessions": 1}, {}, [], {"mobile": 0.5}, [], now)
assert v["type"] == "mobile", v
# 6) nothing to go on: unknown, never a coin flip
v = server.infer_network_type({**base, "ip": "203.0.113.50", "first_seen": now, "last_seen": now, "sessions": 1}, {}, [], {}, [], now)
assert v["type"] == "unknown", v
# 7) the client label alone is too weak to decide
v = server.infer_network_type({**base, "ip": "203.0.113.60", "first_seen": now, "last_seen": now, "sessions": 1}, {"network": "mobile"}, [], {}, [], now)
assert v["type"] == "unknown", v
# 8) conflicting signals are reported as unknown, with the conflict spelled out
v = server.infer_network_type({"ip": "203.0.113.80", "asn": "AS16345", "org": "16345 Mobile Region", "ptr": "128-71-170-153.broadband.example.ru", "first_seen": now, "last_seen": now, "sessions": 1}, {}, [], {}, [], now)
assert v["type"] == "unknown" and any("conflict" in x for x in v["signals"]), v
# hosting providers are recognised from the organisation
v = server.infer_network_type({"ip": "203.0.113.70", "asn": "AS24940", "org": "Hetzner Online GmbH", "first_seen": now, "last_seen": now, "sessions": 1}, {}, [], {}, [], now)
assert v["type"] == "hosting", v
PY
}

@test "network history: observations count sessions only when the address changes" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import server
h = {"clients": {}}
r, new = server.network_observe(h, "phone", "203.0.113.5", 40001, 100, 1000)
assert new and r["sessions"] == 1 and r["first_seen"] == 1000
r, new = server.network_observe(h, "phone", "203.0.113.5", 40001, 110, 1060)
assert not new and r["sessions"] == 1 and r["observations"] == 2 and r["last_seen"] == 1060
r, new = server.network_observe(h, "phone", "203.0.113.99", 41000, 120, 1120)
assert new and r["sessions"] == 1
r, new = server.network_observe(h, "phone", "203.0.113.5", 42000, 130, 1180)
assert new and r["sessions"] == 2 and r["ports"] == [40001, 42000], r
assert [e["ip"] for e in h["clients"]["phone"]["events"]] == ["203.0.113.5", "203.0.113.99", "203.0.113.5"]
PY
}

@test "network history: info is stored, carrier is derived, retention prunes" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import time, server
h = {"clients": {}}
r, _ = server.network_observe(h, "router", "203.0.113.8", 1, 0, 1000)
server.network_apply_info(r, {"asn": "AS8402", "org": "CORBINA", "provider_display": "CORBINA", "country_code": "RU", "city": "Moscow"}, "host.example.net")
assert r["carrier"] == "beeline" and r["city"] == "Moscow" and r["ptr"] == "host.example.net" and r["provider"] == "CORBINA", r
now = time.time()
server.network_observe(h, "old", "198.51.100.1", 1, 0, now - 900 * 86400)
server.network_observe(h, "new", "198.51.100.2", 1, 0, now - 10)
server.network_prune(h, now)
assert "old" not in h["clients"] and "new" in h["clients"] and "router" not in h["clients"]
PY
}

@test "network history: CSV export neutralises formula cells and stats group by provider" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import server
h = {"clients": {"a": {"networks": {
    "203.0.113.1": {"ip": "203.0.113.1", "first_seen": 1, "last_seen": 100, "sessions": 3, "observations": 9, "carrier": "beeline", "type": "mobile", "asn": "AS16345", "org": "=cmd|' /C calc'!A0", "country_code": "RU", "city": "Moscow"},
    "203.0.113.2": {"ip": "203.0.113.2", "first_seen": 1, "last_seen": 200, "sessions": 1, "observations": 2, "carrier": "beeline", "type": "home", "asn": "AS8402", "org": "CORBINA", "country_code": "RU", "city": "Moscow"}},
    "events": []}}}
rows = server.network_rows(h)
assert [r["ip"] for r in rows] == ["203.0.113.2", "203.0.113.1"]
text = server.network_csv(rows)
assert text.splitlines()[0].startswith("client,ip,first_seen") and "'=cmd" in text and ",=cmd" not in text, text
st = server.network_stats(h)
assert st["addresses"] == 2
assert set(st["by_provider"]) == {"beeline (mobile)", "beeline (home)"}, st["by_provider"]
assert st["by_city"]["Moscow, RU"]["sessions"] == 4 and st["by_type"]["mobile"]["clients"] == ["a"]
PY
}

@test "network history: rules are validated, too-broad ones refused, labels reclassify" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import server
for bad in ([{"cidr": "0.0.0.0/0", "type": "home"}], [{"cidr": "10.0.0.0/4", "type": "home"}], [{"cidr": "nope", "type": "home"}], [{"cidr": "198.51.100.0/24", "type": "wifi"}]):
    try:
        server.write_network_rules(bad)
        raise SystemExit("accepted " + repr(bad))
    except ValueError:
        pass
server.write_network_rules([{"cidr": "198.51.100.0/24", "type": "mobile", "note": "pool"}])
assert server.load_network_rules() == [{"cidr": "198.51.100.0/24", "type": "mobile", "note": "pool"}]
assert server.network_prefix("198.51.100.77") == "198.51.100.0/24"
assert server.network_prefix("2001:db8:1:2::5") == "2001:db8:1::/48"
h = {"clients": {"c": {"networks": {"198.51.100.5": {"ip": "198.51.100.5", "first_seen": 1, "last_seen": 2, "sessions": 1}}, "events": []}}}
server.network_classify_record(h, "c", h["clients"]["c"]["networks"]["198.51.100.5"], server.load_network_rules(), {})
assert h["clients"]["c"]["networks"]["198.51.100.5"]["type"] == "mobile"
PY
}

@test "network history: classification knows Beeline wired and mobile ASNs differently" {
    command -v python3 &>/dev/null || skip "python3 not available"
    run python3 "$BATS_TEST_DIRNAME/../scripts/awg_client_profile.py" classify --asn AS8402 --org CORBINA
    [[ "$output" == *'"carrier": "beeline"'* && "$output" == *'"network": "home"'* ]]
    run python3 "$BATS_TEST_DIRNAME/../scripts/awg_client_profile.py" classify --asn AS16345 --org "16345 Mobile Region"
    [[ "$output" == *'"carrier": "beeline"'* && "$output" == *'"network": "mobile"'* ]]
    run python3 "$BATS_TEST_DIRNAME/../scripts/awg_client_profile.py" classify --asn AS3216 --org "PJSC VimpelCom"
    [[ "$output" == *'"carrier": "beeline"'* && "$output" == *'"network": "unknown"'* ]]
}

@test "network history: the panel exposes the endpoints and the collector starts" {
    grep -qF '/api/networks/stats' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF '/api/networks/export' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'start_network_history_collector()' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF '/api/networks/label' "$BATS_TEST_DIRNAME/../web/app.js"
}
