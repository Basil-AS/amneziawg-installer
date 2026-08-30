#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    PYTHON_BIN="${PYTHON_BIN:-python3}"
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/awg_profile.py"
}

@test "AWG 3.1 is the default and renders the protected profile" {
    run "$PYTHON_BIN" "$SCRIPT" generate --seed 7
    [ "$status" -eq 0 ]
    [[ "$output" == *'"protocolVersion": "3.1"'* ]]
    [[ "$output" == *'"headerProtectionKey":'* ]]
}

@test "all supported protocol versions validate the legacy core" {
    for version in 1.5 2.0 3.0; do
        run "$PYTHON_BIN" "$SCRIPT" generate --version "$version" --seed 7
        [ "$status" -eq 0 ]
    done
}

@test "overlapping H ranges are rejected" {
    run "$PYTHON_BIN" "$SCRIPT" generate --seed 1
    [ "$status" -eq 0 ]
    printf '%s' "$output" > "$BATS_TEST_TMPDIR/profile.json"
    run "$PYTHON_BIN" -c 'import json,sys; p=json.load(open(sys.argv[1])); p["h2"]=p["h1"]; json.dump(p,open(sys.argv[1],"w"))' "$BATS_TEST_TMPDIR/profile.json"
    [ "$status" -eq 0 ]
    run "$PYTHON_BIN" "$SCRIPT" validate --input "$BATS_TEST_TMPDIR/profile.json"
    [ "$status" -eq 2 ]
}

@test "AWG 3.1 rejects short protected padding" {
    run "$PYTHON_BIN" "$SCRIPT" generate --seed 7
    [ "$status" -eq 0 ]
    printf '%s' "$output" > "$BATS_TEST_TMPDIR/profile.json"
    run "$PYTHON_BIN" -c 'import json,sys; p=json.load(open(sys.argv[1])); p["s4"]=4; json.dump(p,open(sys.argv[1],"w"))' "$BATS_TEST_TMPDIR/profile.json"
    [ "$status" -eq 0 ]
    run "$PYTHON_BIN" "$SCRIPT" validate --input "$BATS_TEST_TMPDIR/profile.json"
    [ "$status" -eq 2 ]
}

@test "render includes HeaderProtectionKey for AWG 3.1" {
    run "$PYTHON_BIN" "$SCRIPT" generate --seed 7
    printf '%s' "$output" > "$BATS_TEST_TMPDIR/profile.json"
    run "$PYTHON_BIN" "$SCRIPT" render --input "$BATS_TEST_TMPDIR/profile.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'HeaderProtectionKey = '* ]]
}
