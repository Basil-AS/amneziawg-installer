#!/usr/bin/env bats
# shellcheck disable=SC2016

@test "installer uses randomized default AWG port" {
    grep -q 'generate_random_awg_port()' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'default_port=$(generate_random_awg_port)' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    if grep -q 'local default_port=39743' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"; then
        fail "RU installer must not hard-code the legacy default port"
    fi
}

@test "EN installer uses randomized default AWG port" {
    grep -q 'generate_random_awg_port()' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -q 'default_port=$(generate_random_awg_port)' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    if grep -q 'local default_port=39743' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"; then
        fail "EN installer must not hard-code the legacy default port"
    fi
}

@test "installer supports single-file bootstrap from raw main with local-first assets" {
    grep -q 'AWG_REPO="${AWG_REPO:-Basil-AS/amneziawg-installer}"' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'AWG_BRANCH="${AWG_BRANCH:-main}"' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'raw.githubusercontent.com/${AWG_REPO}/${AWG_BRANCH}/${asset_path}' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'src="${INSTALLER_DIR}/${asset_path}"' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF '_deploy_asset "awg_common.sh" "$COMMON_SCRIPT_PATH" 700' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF '_deploy_asset "manage_amneziawg.sh" "$MANAGE_SCRIPT_PATH" 700' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'AWG_ALLOW_UNVERIFIED_DOWNLOAD=1' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    if grep -qF 'используйте release bundle' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"; then
        fail "single-file install must not require a release bundle"
    fi
}

@test "installer SHA manifest covers required bootstrap assets" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    for asset in \
        '["awg_common.sh"]' \
        '["manage_amneziawg.sh"]' \
        '["web/server.py"]' \
        '["web/index.html"]' \
        '["web/app.js"]' \
        '["web/style.css"]' \
        '["web/vendor/tailwindcss.js"]' \
        '["web/vendor/apexcharts.min.js"]'
    do
        grep -qF "$asset" "$installer"
    done
    if sed -n '/declare -A AWG_ASSET_SHA256=(/,/^)/p' "$installer" | grep -qF 'RELEASE_PLACEHOLDER'; then
        echo "main installer must pin SHA256 values for bootstrap assets" >&2
        return 1
    fi
}

@test "installer secure download enforces hashes and explicit unverified opt-in" {
    command -v sha256sum &>/dev/null || skip "sha256sum not available"
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    local good_sha
    good_sha=$(printf good | sha256sum | awk '{print $1}')

    run bash -c '
        set -e
        tmp=$(mktemp -d)
        mkdir -p "$tmp/bin"
        cat > "$tmp/bin/curl" <<'"'"'STUB'"'"'
#!/usr/bin/env bash
out=""
while (($#)); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -fLso) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf bad > "$out"
STUB
        chmod +x "$tmp/bin/curl"
        PATH="$tmp/bin:$PATH"
        log_error(){ echo "$*" >&2; }
        log_warn(){ echo "$*" >&2; }
        log_debug(){ :; }
        log(){ :; }
        die(){ echo "$*" >&2; exit 97; }
        source <(sed -n "/^verify_sha256() {$/,/^step5_download_scripts() {$/p" "$1" | head -n -1)
        _secure_download "https://example.invalid/asset" "$tmp/out" "$2" "asset" 644
    ' _ "$installer" "$good_sha"
    [ "$status" -eq 97 ]
    [[ "$output" == *"SHA256"* ]]

    run bash -c '
        set -e
        tmp=$(mktemp -d)
        mkdir -p "$tmp/bin"
        cat > "$tmp/bin/curl" <<'"'"'STUB'"'"'
#!/usr/bin/env bash
out=""
while (($#)); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -fLso) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf ok > "$out"
STUB
        chmod +x "$tmp/bin/curl"
        PATH="$tmp/bin:$PATH"
        log_error(){ echo "$*" >&2; }
        log_warn(){ echo "$*" >&2; }
        log_debug(){ :; }
        log(){ :; }
        die(){ echo "$*" >&2; exit 97; }
        source <(sed -n "/^verify_sha256() {$/,/^step5_download_scripts() {$/p" "$1" | head -n -1)
        _secure_download "https://example.invalid/asset" "$tmp/out" "" "asset" 644
    ' _ "$installer"
    [ "$status" -eq 97 ]
    [[ "$output" == *"SHA256"* ]]

    run bash -c '
        set -e
        tmp=$(mktemp -d)
        mkdir -p "$tmp/bin"
        cat > "$tmp/bin/curl" <<'"'"'STUB'"'"'
#!/usr/bin/env bash
out=""
while (($#)); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -fLso) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf ok > "$out"
STUB
        chmod +x "$tmp/bin/curl"
        PATH="$tmp/bin:$PATH"
        export AWG_ALLOW_UNVERIFIED_DOWNLOAD=1
        log_error(){ echo "$*" >&2; }
        log_warn(){ echo "$*" >&2; }
        log_debug(){ :; }
        log(){ :; }
        die(){ echo "$*" >&2; exit 97; }
        source <(sed -n "/^verify_sha256() {$/,/^step5_download_scripts() {$/p" "$1" | head -n -1)
        _secure_download "https://example.invalid/asset" "$tmp/out" "" "asset" 644
        test "$(cat "$tmp/out")" = ok
    ' _ "$installer"
    [ "$status" -eq 0 ]
    [[ "$output" == *"AWG_ALLOW_UNVERIFIED_DOWNLOAD=1"* ]]
}

@test "README quickstart uses fork raw GitHub main, not upstream release tag" {
    grep -q 'raw.githubusercontent.com/Basil-AS/amneziawg-installer/main/install_amneziawg.sh' "$BATS_TEST_DIRNAME/../README.md"
    grep -q 'raw.githubusercontent.com/Basil-AS/amneziawg-installer/main/install_amneziawg.sh' "$BATS_TEST_DIRNAME/../README.en.md"
    grep -qF 'sudo bash ./install_amneziawg.sh --yes --route-all --server-name="my-vpn"' "$BATS_TEST_DIRNAME/../README.md"
    grep -qF 'sudo bash ./install_amneziawg.sh --yes --route-all --server-name="my-vpn"' "$BATS_TEST_DIRNAME/../README.en.md"
    if grep -q 'raw.githubusercontent.com/bivlked/amneziawg-installer/v5.13.0/install_amneziawg.sh' "$BATS_TEST_DIRNAME/../README.md"; then
        fail "README quickstart must not point at upstream release installer"
    fi
    if grep -qF '<OWNER>/<REPO>/<BRANCH>' "$BATS_TEST_DIRNAME/../README.md" "$BATS_TEST_DIRNAME/../README.en.md"; then
        fail "README must not expose placeholder quickstart URLs"
    fi
}
