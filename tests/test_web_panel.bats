#!/usr/bin/env bats

@test "web/server.py compiles with Python stdlib" {
    command -v python3 &>/dev/null || skip "python3 not available"
    python3 -m py_compile "$BATS_TEST_DIRNAME/../web/server.py"
}

@test "installer deploys awg-web.service and token store" {
    grep -qF 'awg-web.service' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'tokens.json' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'Authorization' "$BATS_TEST_DIRNAME/../web/server.py"
}

@test "web index is stealth before auth" {
    ! grep -qF 'AmneziaWG' "$BATS_TEST_DIRNAME/../web/index.html"
    grep -qF 'type="password"' "$BATS_TEST_DIRNAME/../web/index.html"
    grep -qF 'id="app" hidden' "$BATS_TEST_DIRNAME/../web/index.html"
}

@test "web panel exposes token role controls after auth" {
    grep -qF 'tokens.json' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF '/api/tokens' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'Reset All' "$BATS_TEST_DIRNAME/../web/app.js"
}
