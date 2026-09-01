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

@test "protocol generation emits only fields supported by the selected version" {
    run "$PYTHON_BIN" "$SCRIPT" generate --version 1.5 --seed 7
    [ "$status" -eq 0 ]
    run "$PYTHON_BIN" -c 'import json,sys; p=json.loads(sys.argv[1]); assert "s3" not in p and "s4" not in p and "headerProtectionKey" not in p; assert all("-" not in p[k] for k in ("h1","h2","h3","h4"))' "$output"
    [ "$status" -eq 0 ]

    run "$PYTHON_BIN" "$SCRIPT" generate --version 2.0 --seed 7
    [ "$status" -eq 0 ]
    run "$PYTHON_BIN" -c 'import json,sys; p=json.loads(sys.argv[1]); assert all(k in p for k in ("s3","s4")); assert "headerProtectionKey" not in p' "$output"
    [ "$status" -eq 0 ]

    run "$PYTHON_BIN" "$SCRIPT" generate --version 3.0 --seed 7
    [ "$status" -eq 0 ]
    run "$PYTHON_BIN" -c 'import json,sys; p=json.loads(sys.argv[1]); assert all(k in p for k in ("s3","s4","headerProtectionKey","contentPaddingAddition","keepaliveTimeout")); assert "randomTrailers" not in p and "disableCookies" not in p' "$output"
    [ "$status" -eq 0 ]
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

@test "AWG 3.1 generation uses safe S bounds and unique packet lengths" {
    run "$PYTHON_BIN" "$SCRIPT" generate --seed 11
    [ "$status" -eq 0 ]
    run "$PYTHON_BIN" -c 'import json,sys; p=json.loads(sys.argv[1]); s=[p["s1"],p["s2"],p["s3"],p["s4"]]; assert s[0] >= 12 and s[1] >= 12 and s[2] >= 12 and s[3] == 12; assert len({148+s[0],92+s[1],64+s[2],32+s[3]}) == 4; assert max(int(x.split("-")[-1]) for x in [p["h1"],p["h2"],p["h3"],p["h4"]]) <= 2147483647' "$output"
    [ "$status" -eq 0 ]
}

@test "AWG 3.1 generated profiles enable bilateral random trailers but keep cookies" {
    run "$PYTHON_BIN" "$SCRIPT" generate --seed 19
    [ "$status" -eq 0 ]
    run "$PYTHON_BIN" -c 'import json,sys; p=json.loads(sys.argv[1]); assert p["randomTrailers"] is True; assert p["disableCookies"] is False' "$output"
    [ "$status" -eq 0 ]
    printf '%s' "$output" > "$BATS_TEST_TMPDIR/profile.json"
    run "$PYTHON_BIN" "$SCRIPT" render --input "$BATS_TEST_TMPDIR/profile.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'RandomTrailers = true'* ]]
    [[ "$output" == *$'DisableCookies = false'* ]]
}

@test "named profiles are deterministic and keep H ranges disjoint" {
    for profile in mobile balanced stealth compatibility; do
        run "$PYTHON_BIN" "$SCRIPT" generate --version 3.1 --profile "$profile" --seed 123
        [ "$status" -eq 0 ]
        generated="$output"
        run "$PYTHON_BIN" -c 'import json,sys; p=json.loads(sys.argv[1]); assert p["profile"] == sys.argv[2]; r=[tuple(map(int,p[k].split("-"))) for k in ("h1","h2","h3","h4")]; assert all(a[1] < b[0] or b[1] < a[0] for i,a in enumerate(r) for b in r[i+1:]); assert max(x[1] for x in r) <= 2147483647' "$generated" "$profile"
        [ "$status" -eq 0 ]
        run "$PYTHON_BIN" "$SCRIPT" generate --version 3.1 --profile "$profile" --seed 123
        [ "$status" -eq 0 ]
        [ "$output" = "$generated" ]
    done
}

@test "compatibility profile keeps AWG 1.5 legacy fields" {
    run "$PYTHON_BIN" "$SCRIPT" generate --version 1.5 --profile compatibility --seed 123
    [ "$status" -eq 0 ]
    run "$PYTHON_BIN" -c 'import json,sys; p=json.loads(sys.argv[1]); assert p["profile"] == "compatibility"; assert all(p[k].isdigit() for k in ("h1","h2","h3","h4")); assert "s3" not in p and "s4" not in p' "$output"
    [ "$status" -eq 0 ]
}

@test "render includes HeaderProtectionKey for AWG 3.1" {
    run "$PYTHON_BIN" "$SCRIPT" generate --seed 7
    printf '%s' "$output" > "$BATS_TEST_TMPDIR/profile.json"
    run "$PYTHON_BIN" "$SCRIPT" render --input "$BATS_TEST_TMPDIR/profile.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'HeaderProtectionKey = '* ]]
}
