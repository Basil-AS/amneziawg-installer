#!/usr/bin/env bats
# shellcheck disable=SC2016

@test "public HTML has neutral pre-auth title and no product identifiers" {
    local html="$BATS_TEST_DIRNAME/../web/index.html"
    grep -qF '<title>Control</title>' "$html"
    run grep -Eiq 'amnezia|wireguard|wg tunnel|vpn|adguard|client config|server rotate-profile|token management|p2p|dns|tunnel' "$html"
    [ "$status" -ne 0 ]
}

@test "public static assets do not disclose service purpose before auth" {
    for asset in web/app.js web/style.css web/favicon.svg web/awg_i1.js; do
        run grep -Eiq 'amnezia|wireguard|wg tunnel|vpn|adguard|client config|server rotate-profile|token management|p2p|dns|tunnel' "$BATS_TEST_DIRNAME/../$asset"
        [ "$status" -ne 0 ]
    done
}

@test "login UI strings are generic" {
    local app="$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'document.title = "Control"' "$app"
    grep -qF '>Control</h1>' "$app"
    grep -qF 'Access required' "$app"
    grep -qF 'placeholder="Access token"' "$app"
    grep -qF 'showToast("Access denied", "error")' "$app"
}

@test "server banner and unauthenticated API errors are generic" {
    local server="$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'server_version = "Panel"' "$server"
    grep -qF 'sys_version = ""' "$server"
    grep -qF 'self.send_api_error(HTTPStatus.UNAUTHORIZED, "unauthorized")' "$server"
    grep -qF 'def send_api_error(self, status, error):' "$server"
}

@test "I1 helper is exposed under a neutral static path" {
    local server="$BATS_TEST_DIRNAME/../web/server.py"
    local html="$BATS_TEST_DIRNAME/../web/index.html"
    grep -qF '<script src="/i1.js"></script>' "$html"
    grep -qF '"/i1.js": ("awg_i1.js", "application/javascript; charset=utf-8")' "$server"
    run grep -qF '"/awg_i1.js":' "$server"
    [ "$status" -ne 0 ]
}
