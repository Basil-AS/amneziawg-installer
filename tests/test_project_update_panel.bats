#!/usr/bin/env bats

setup() {
    ROOT="$BATS_TEST_DIRNAME/.."
}

@test "project updater keeps a protected payload and rollback contract" {
    grep -qF 'sha256sum' "$ROOT/scripts/update-installed.sh"
    grep -qF 'starting automatic rollback' "$ROOT/scripts/update-installed.sh"
    grep -qF 'flock -n 9' "$ROOT/scripts/update-installed.sh"
    grep -qF 'systemctl daemon-reload' "$ROOT/scripts/update-installed.sh"
}

@test "panel update API is super-only and runs outside awg-web service" {
    grep -qF 'PROJECT_UPDATE_UNIT = "awg-project-update-manual.service"' "$ROOT/web/server.py"
    grep -qF 'systemd-run' "$ROOT/web/server.py"
    grep -qF 'u.path == "/api/project-update"' "$ROOT/web/server.py"
    grep -qF 'u.path == "/api/project-update/check"' "$ROOT/web/server.py"
    grep -qF 'u.path == "/api/project-update/apply"' "$ROOT/web/server.py"
    grep -qF 'UPDATE PROJECT' "$ROOT/web/server.py"
    grep -qF 'require_super(auth)' "$ROOT/web/server.py"
}

@test "web panel exposes check and safe update controls" {
    grep -qF 'id="checkProjectUpdate"' "$ROOT/web/app.js"
    grep -qF 'id="applyProjectUpdate"' "$ROOT/web/app.js"
    grep -qF '/api/project-update/check' "$ROOT/web/app.js"
    grep -qF '/api/project-update/apply' "$ROOT/web/app.js"
    grep -qF 'rolls back automatically' "$ROOT/web/app.js"
}
