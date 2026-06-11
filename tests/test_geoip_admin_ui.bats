#!/usr/bin/env bats
# Tests for the GeoIP Sources admin UI in web/app.js:
#   - state vars, panel section, providers form, databases panel
#   - save/test/update/auto-update wiring against the GeoIP admin API

bats_require_minimum_version 1.5.0

load test_helper

@test "app.js: GeoIP admin state vars and panel section are defined" {
    local app="$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'let geoipProvidersState = null;' "$app"
    grep -qF 'let geoipDatabasesState = null;' "$app"
    grep -qF 'id="geoipPanel"' "$app"
    grep -qF 'id="geoipProvidersForm"' "$app"
    grep -qF 'id="geoipDatabasesPanel"' "$app"
    grep -qF 'id="saveGeoipProviders"' "$app"
    # super-only visibility, like the other admin panels
    grep -qF 'statusState.role === "super" ? "" : "hidden"' "$app"
}

@test "app.js: loadGeoipAdmin fetches providers+databases status and renders both" {
    local app="$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'async function loadGeoipAdmin()' "$app"
    block=$(awk '/^async function loadGeoipAdmin/,/^}/' "$app")
    grep -qF '/api/geoip/providers' <<<"$block"
    grep -qF '/api/geoip/databases/status' <<<"$block"
    grep -qF 'renderGeoipProviders()' <<<"$block"
    grep -qF 'renderGeoipDatabases()' <<<"$block"
    # wired into the super-only init load
    grep -qF 'loadGeoipAdmin()' "$app"
}

@test "app.js: renderGeoipProviders covers all providers, masks tokens, and wires Test buttons" {
    local app="$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'function renderGeoipProviders()' "$app"
    grep -qF 'const GEOIP_PROVIDER_INFO' "$app"
    for provider in maxmind dbip_mmdb 2ip 2ip_whois ipinfo dbip ip-api; do
        grep -qF "\"$provider\"" "$app"
    done
    block=$(awk '/^function renderGeoipProviders/,/^}/' "$app")
    grep -qF 'GEOIP_TOKEN_MASK' <<<"$block"
    grep -qF 'has_token' <<<"$block"
    grep -qF 'allow_free' <<<"$block"
    grep -qF 'only_on_refresh' <<<"$block"
    grep -qF '/api/geoip/providers/test' <<<"$block"
    grep -qF '"POST"' <<<"$block"
}

@test "app.js: saveGeoipProviders reads the form and PUTs /api/geoip/providers" {
    local app="$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'function readGeoipProvidersForm()' "$app"
    grep -qF 'async function saveGeoipProviders()' "$app"
    block=$(awk '/^async function saveGeoipProviders/,/^}/' "$app")
    grep -qF 'readGeoipProvidersForm()' <<<"$block"
    grep -qF '/api/geoip/providers' <<<"$block"
    grep -qF '"PUT"' <<<"$block"
    grep -qF 'document.querySelector("#saveGeoipProviders").onclick = saveGeoipProviders;' "$app"
}

@test "app.js: renderGeoipDatabases shows MMDB status and wires update/auto-update actions" {
    local app="$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'function renderGeoipDatabases()' "$app"
    grep -qF 'const GEOIP_DB_LABELS' "$app"
    for db in maxmind_asn maxmind_city maxmind_country dbip_city_lite; do
        grep -qF "$db" "$app"
    done
    block=$(awk '/^function renderGeoipDatabases/,/^}/' "$app")
    grep -qF '/api/geoip/databases/update' <<<"$block"
    grep -qF '/api/geoip/auto-update' <<<"$block"
    grep -qF 'confirmModal(' <<<"$block"
    grep -qF '"POST"' <<<"$block"
}
