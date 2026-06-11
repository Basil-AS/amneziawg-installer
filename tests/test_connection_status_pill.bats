#!/usr/bin/env bats
# Tests for the header connection status pill (Online/Updating.../Paused/
# Offline/Reconnecting...) wired through the api()/apiNettest() fetch
# wrappers and the existing panel-idle tracking in web/app.js.

bats_require_minimum_version 1.5.0

load test_helper

@test "app.js: connection pill states, computeConnectionState, and updateConnectionPill are defined" {
    local app="$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'let connectionState = "online";' "$app"
    grep -qF 'function computeConnectionState()' "$app"
    grep -qF 'function updateConnectionPill()' "$app"
    grep -qF 'const CONNECTION_STATE_INFO' "$app"
    for state in online updating paused offline reconnecting; do
        grep -qF "$state:" "$app"
    done
    grep -qF 'Updating...' "$app"
    grep -qF 'Reconnecting...' "$app"
    grep -qF 'Paused' "$app"
    grep -qF 'Offline' "$app"
    grep -qF 'Online' "$app"
    grep -qF 'id="connectionStatusPill"' "$app"
}

@test "app.js: computeConnectionState priority is offline > reconnecting > updating > paused > online" {
    local app="$BATS_TEST_DIRNAME/../web/app.js"
    block=$(awk '/^function computeConnectionState/,/^}/' "$app")
    # offline checked first
    [[ "$block" == *'navigator.onLine'* ]]
    [[ "$block" == *'"offline"'* ]]
    [[ "$block" == *'apiConnectivityOk'* ]]
    [[ "$block" == *'"reconnecting"'* ]]
    [[ "$block" == *'apiInFlightCount'* ]]
    [[ "$block" == *'"updating"'* ]]
    [[ "$block" == *'panelIdle'* ]]
    [[ "$block" == *'"paused"'* ]]
    # offline must be the first condition, online the final fallback
    first_line=$(grep -n 'return ' <<<"$block" | head -1)
    [[ "$first_line" == *'"offline"'* ]]
    last_line=$(grep -n 'return ' <<<"$block" | tail -1)
    [[ "$last_line" == *'"online"'* ]]
}

@test "app.js: api() and apiNettest() track in-flight count and connectivity for the pill" {
    local app="$BATS_TEST_DIRNAME/../web/app.js"
    block=$(awk '/^async function api\(path/,/^}/' "$app")
    grep -qF 'apiInFlightCount += 1' <<<"$block"
    grep -qF 'updateConnectionPill()' <<<"$block"
    grep -qF 'apiConnectivityOk = true' <<<"$block"
    grep -qF 'apiConnectivityOk = false' <<<"$block"
    grep -qF 'instanceof TypeError' <<<"$block"
    grep -qF 'apiInFlightCount = Math.max(0, apiInFlightCount - 1)' <<<"$block"

    block2=$(awk '/^async function apiNettest/,/^}/' "$app")
    grep -qF 'apiInFlightCount += 1' <<<"$block2"
    grep -qF 'updateConnectionPill()' <<<"$block2"
    grep -qF 'apiConnectivityOk = true' <<<"$block2"
}

@test "app.js: panel idle/resume hooks refresh the connection pill" {
    local app="$BATS_TEST_DIRNAME/../web/app.js"
    block=$(awk '/^function updatePanelIdleNote/,/^}/' "$app")
    grep -qF 'updateConnectionPill()' <<<"$block"
    grep -qF 'window.addEventListener("online", updateConnectionPill)' "$app"
    grep -qF 'window.addEventListener("offline", updateConnectionPill)' "$app"
    grep -qF 'updateConnectionPill();' "$app"
}
