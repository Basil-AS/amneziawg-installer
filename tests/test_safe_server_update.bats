#!/usr/bin/env bats

setup() {
    ROOT="$BATS_TEST_DIRNAME/.."
    UPDATER="$ROOT/scripts/update-installed.sh"
}

@test "safe updater has valid Bash syntax and a source-safe entrypoint" {
    run bash -n "$UPDATER"
    [ "$status" -eq 0 ]
    run bash -c 'source "$1"; validate_repo; validate_tag v5.19.1-bas.2' _ "$UPDATER"
    [ "$status" -eq 0 ]
}

@test "installer deploys the updater with a pinned digest in both languages" {
    local file
    for file in install_amneziawg.sh install_amneziawg_en.sh; do
        grep -Eq '\["scripts/update-installed\.sh"\]="[0-9a-f]{64}"' "$ROOT/$file"
        grep -qF '_deploy_asset "scripts/update-installed.sh" "$AWG_DIR/update-installed.sh" 700' "$ROOT/$file"
    done
}

@test "release workflow builds bundle before publishing it with checksum" {
    local workflow build_line release_line
    workflow="$ROOT/.github/workflows/release.yml"
    build_line=$(grep -n 'name: Build deterministic safe-update bundle' "$workflow" | cut -d: -f1)
    release_line=$(grep -n 'name: Create Release' "$workflow" | cut -d: -f1)
    [ "$build_line" -lt "$release_line" ]
    grep -qF '/tmp/amneziawg-update-*.tar.gz.sha256' "$workflow"
    grep -qF -- "--sort=name --mtime='UTC 1970-01-01'" "$workflow"
}

@test "archive validator accepts regular files and rejects symlinks" {
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "$tmp/good" "$tmp/out-good" "$tmp/out-bad"
    printf 'ok\n' > "$tmp/good/VERSION"
    tar -czf "$tmp/good.tar.gz" -C "$tmp/good" VERSION
    run bash -c 'source "$1"; extract_release_bundle "$2" "$3"' _ "$UPDATER" "$tmp/good.tar.gz" "$tmp/out-good"
    [ "$status" -eq 0 ]
    [ "$(cat "$tmp/out-good/VERSION")" = "ok" ]

    ln -s /etc/passwd "$tmp/good/escape"
    tar -czf "$tmp/bad.tar.gz" -C "$tmp/good" escape
    run bash -c 'source "$1"; extract_release_bundle "$2" "$3"' _ "$UPDATER" "$tmp/bad.tar.gz" "$tmp/out-bad"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsupported archive entry type"* ]]
    rm -rf "$tmp"
}

@test "payload allowlist excludes configuration, keys, tokens, and generated firewall hooks" {
    run bash -c 'source "$1"; required_payload_files' _ "$UPDATER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"web/server.py"* ]]
    [[ "$output" == *"scripts/update-installed.sh"* ]]
    [[ "$output" != *"tokens.json"* ]]
    [[ "$output" != *"server_private"* ]]
    [[ "$output" != *"awg0.conf"* ]]
    [[ "$output" != *"postup.sh"* ]]
    [[ "$output" != *"p2p_rules.sh"* ]]
}

@test "updater includes lock, preflight, snapshot, rollback, and post-update health guards" {
    grep -qF 'flock -n 9' "$UPDATER"
    grep -qF 'awg-quick strip awg0' "$UPDATER"
    grep -qF 'snapshot_targets' "$UPDATER"
    grep -qF 'starting automatic rollback' "$UPDATER"
    grep -qF 'systemctl is-active --quiet awg-quick@awg0' "$UPDATER"
    grep -qF 'net.ipv4.ip_forward' "$UPDATER"
    grep -qF 'AWG_PROJECT_VERSION=${TARGET_TAG#v}' "$UPDATER"
}

@test "weekly timer is opt-in, persistent, and randomized" {
    grep -qF -- '--install-timer' "$UPDATER"
    grep -qF 'OnCalendar=weekly' "$UPDATER"
    grep -qF 'Persistent=true' "$UPDATER"
    grep -qF 'RandomizedDelaySec=6h' "$UPDATER"
    if grep -qF 'systemctl enable --now awg-project-update.timer' "$ROOT/install_amneziawg.sh"; then
        false
    fi
}

@test "version guard refuses release downgrades" {
    local tmp
    tmp=$(mktemp -d)
    printf '5.15.3-bas.2\n' > "$tmp/VERSION"
    run env AWG_DIR="$tmp" bash -c 'source "$1"; TARGET_TAG=v5.15.3-bas.1; installed_is_newer_than_target' _ "$UPDATER"
    [ "$status" -eq 0 ]
    run env AWG_DIR="$tmp" bash -c 'source "$1"; TARGET_TAG=v5.15.3-bas.3; installed_is_newer_than_target' _ "$UPDATER"
    [ "$status" -ne 0 ]
    rm -rf "$tmp"
}

@test "file transaction rollback restores old runtime and preserves secrets" {
    local tmp
    tmp=$(mktemp -d)
    run env TEST_ROOT="$tmp" UPDATER="$UPDATER" bash -c '
        source "$UPDATER"
        AWG_DIR="$TEST_ROOT/awg"
        SERVER_CONF_FILE="$TEST_ROOT/etc/amnezia/amneziawg/awg0.conf"
        SYSTEMD_DIR="$TEST_ROOT/etc/systemd/system"
        BACKUP_ROOT="$TEST_ROOT/backups"
        WORK_DIR="$TEST_ROOT/work"
        TARGET_TAG=v5.15.3-bas.2
        WEB_WAS_ACTIVE=1
        systemctl() { return 0; }

        mkdir -p "$AWG_DIR/web" "$(dirname "$SERVER_CONF_FILE")" "$SYSTEMD_DIR" "$WORK_DIR/payload"
        printf "old-version\n" > "$AWG_DIR/VERSION"
        printf "secret\n" > "$AWG_DIR/web/tokens.json"
        printf "[Interface]\nPrivateKey = secret\n" > "$SERVER_CONF_FILE"
        printf "[Service]\nEnvironment=AWG_PROJECT_VERSION=old-version\n" > "$SYSTEMD_DIR/awg-web.service"
        while IFS= read -r rel; do
            mkdir -p "$WORK_DIR/payload/$(dirname "$rel")"
            printf "new payload: %s\n" "$rel" > "$WORK_DIR/payload/$rel"
        done < <(required_payload_files)
        printf "5.15.3-bas.2\n" > "$WORK_DIR/payload/VERSION"

        apply_payload
        [[ "$(cat "$AWG_DIR/VERSION")" == "5.15.3-bas.2" ]]
        [[ "$(cat "$AWG_DIR/web/tokens.json")" == "secret" ]]
        rollback_snapshot
        [[ "$(cat "$AWG_DIR/VERSION")" == "old-version" ]]
        [[ "$(cat "$AWG_DIR/web/tokens.json")" == "secret" ]]
        grep -qF "AWG_PROJECT_VERSION=old-version" "$SYSTEMD_DIR/awg-web.service"
        [[ ! -e "$AWG_DIR/update-installed.sh" ]]
    '
    [ "$status" -eq 0 ]
    rm -rf "$tmp"
}
