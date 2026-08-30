#!/usr/bin/env bats
# Issue #178 - explicit client isolation setting.
# Isolation used to be an implicit side effect of the routing mode; now the
# installer asks/accepts --isolation=on|off, enforces isolation server-side
# (FORWARD awg0->awg0 DROP) and, when disabled, routes the tunnel subnet to
# the clients via ALLOWED_IPS.

# ---------------------------------------------------------------------------
# CLI flag + step-0 helpers
# ---------------------------------------------------------------------------

@test "issue #178: RU/EN installer parses --isolation= into CLI_ISOLATION" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -F -- '--isolation=*)' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
        [[ "$output" == *'CLI_ISOLATION='* ]]
    done
}

@test "issue #178: RU/EN help mentions --isolation" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -c -- '--isolation=' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
        [ "$output" -ge 2 ]   # парсер + help
    done
}

@test "issue #178 functional: tunnel_network_cidr derives network from server addr" {
    fn=$(awk '/^tunnel_network_cidr\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    [ -n "$fn" ]
    run bash -c "$fn"'
        tunnel_network_cidr 10.9.9.1/24
        tunnel_network_cidr 10.9.0.1/16
        tunnel_network_cidr 172.16.5.1/30
        tunnel_network_cidr not-a-cidr || echo "rejected"
        tunnel_network_cidr 300.1.1.1/24 || echo "rejected-octet"
    '
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "10.9.9.0/24" ]]
    [[ "${lines[1]}" == "10.9.0.0/16" ]]
    [[ "${lines[2]}" == "172.16.5.0/30" ]]
    [[ "${lines[3]}" == "rejected" ]]
    [[ "${lines[4]}" == "rejected-octet" ]]
}

# ---------------------------------------------------------------------------
# CLIENT_ISOLATION resolution + ALLOWED_IPS application
# ---------------------------------------------------------------------------

@test "issue #178 functional: configure_client_isolation priority CLI > config > --yes/question" {
    fn=$(awk '/^configure_client_isolation\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    [ -n "$fn" ]
    run bash -c '
        log() { :; }; die() { echo "DIE:$*"; exit 1; }
        '"$fn"'
        CLI_ISOLATION=off AUTO_YES=0 CLIENT_ISOLATION=""
        configure_client_isolation; echo "cli-off:$CLIENT_ISOLATION"
        CLI_ISOLATION=on AUTO_YES=0 CLIENT_ISOLATION=0
        configure_client_isolation; echo "cli-on:$CLIENT_ISOLATION"
        CLI_ISOLATION=default AUTO_YES=0 CLIENT_ISOLATION=0
        configure_client_isolation; echo "cfg:$CLIENT_ISOLATION"
        CLI_ISOLATION=default AUTO_YES=1 CLIENT_ISOLATION=""
        configure_client_isolation; echo "yes:$CLIENT_ISOLATION"
        CLI_ISOLATION=default AUTO_YES=0 CLIENT_ISOLATION="" config_exists=1
        configure_client_isolation; echo "legacy:$CLIENT_ISOLATION"
        CLI_ISOLATION=bogus configure_client_isolation
    '
    [[ "$output" == *'cli-off:0'* ]]
    [[ "$output" == *'cli-on:1'* ]]
    [[ "$output" == *'cfg:0'* ]]
    [[ "$output" == *'yes:1'* ]]
    [[ "$output" == *'legacy:1'* ]]
    [[ "$output" == *'DIE:'* ]]
}

@test "issue #178 functional: _apply_isolation_to_allowed_ips add/remove semantics" {
    fns=$(awk '/^tunnel_network_cidr\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
          awk '/^_apply_isolation_to_allowed_ips\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    [ -n "$fns" ]
    run bash -c '
        log() { :; }
        '"$fns"'
        AWG_TUNNEL_SUBNET=10.9.9.1/24
        # off + mode 2: append once, idempotent
        CLIENT_ISOLATION=0 ALLOWED_IPS_MODE=2 ALLOWED_IPS="1.0.0.0/8, 8.8.8.8/32"
        _apply_isolation_to_allowed_ips; echo "A:$ALLOWED_IPS"
        _apply_isolation_to_allowed_ips; echo "B:$ALLOWED_IPS"
        # off + mode 1: 0.0.0.0/0 already covers the subnet
        CLIENT_ISOLATION=0 ALLOWED_IPS_MODE=1 ALLOWED_IPS="0.0.0.0/0"
        _apply_isolation_to_allowed_ips; echo "C:$ALLOWED_IPS"
        # off + mode 3: append to custom list too
        CLIENT_ISOLATION=0 ALLOWED_IPS_MODE=3 ALLOWED_IPS="192.168.50.0/24"
        _apply_isolation_to_allowed_ips; echo "D:$ALLOWED_IPS"
        # on + mode 2: our token is stripped (round-trip off->on)
        CLIENT_ISOLATION=1 ALLOWED_IPS_MODE=2 ALLOWED_IPS="1.0.0.0/8, 10.9.9.0/24, 8.8.8.8/32"
        _apply_isolation_to_allowed_ips; echo "E:$ALLOWED_IPS"
        # on + mode 3: user-owned custom list is left intact
        CLIENT_ISOLATION=1 ALLOWED_IPS_MODE=3 ALLOWED_IPS="192.168.50.0/24, 10.9.9.0/24"
        _apply_isolation_to_allowed_ips; echo "F:$ALLOWED_IPS"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *'A:1.0.0.0/8, 8.8.8.8/32, 10.9.9.0/24'* ]]
    [[ "$output" == *'B:1.0.0.0/8, 8.8.8.8/32, 10.9.9.0/24'* ]]
    [[ "$output" == *'C:0.0.0.0/0'* ]]
    [[ "$output" == *'D:192.168.50.0/24, 10.9.9.0/24'* ]]
    [[ "$output" == *'E:1.0.0.0/8, 8.8.8.8/32'* ]]
    [[ "$output" == *'F:192.168.50.0/24, 10.9.9.0/24'* ]]
}

@test "issue #178: RU/EN installer persists CLIENT_ISOLATION into awgsetup_cfg.init" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -F 'export CLIENT_ISOLATION=${CLIENT_ISOLATION:-1}' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
    done
}

# ---------------------------------------------------------------------------
# Task 8: stale route-token cleanup on tunnel-subnet change (CLIENT_ISOLATION_NET)
# ---------------------------------------------------------------------------

@test "issue #178 functional: _apply_isolation_to_allowed_ips drops stale CLIENT_ISOLATION_NET on subnet change" {
    fns=$(awk '/^tunnel_network_cidr\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
          awk '/^_apply_isolation_to_allowed_ips\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    [ -n "$fns" ]
    run bash -c '
        log() { :; }
        '"$fns"'
        AWG_TUNNEL_SUBNET=10.9.9.1/24
        # (a) off + subnet changed: old token removed, new token added, ownership updated
        CLIENT_ISOLATION=0 ALLOWED_IPS_MODE=2 ALLOWED_IPS="1.0.0.0/8, 10.9.8.0/24, 8.8.8.8/32" CLIENT_ISOLATION_NET=10.9.8.0/24
        _apply_isolation_to_allowed_ips; echo "A:$ALLOWED_IPS|NET=$CLIENT_ISOLATION_NET"
        # (b) on + subnet changed, current net ALSO present (mode 2): pre-strip removes
        # the old token AND the on-branch strips the current-net token - both gone
        CLIENT_ISOLATION=1 ALLOWED_IPS_MODE=2 ALLOWED_IPS="1.0.0.0/8, 10.9.8.0/24, 10.9.9.0/24, 8.8.8.8/32" CLIENT_ISOLATION_NET=10.9.8.0/24
        _apply_isolation_to_allowed_ips; echo "B:$ALLOWED_IPS|NET=$CLIENT_ISOLATION_NET"
        # (c) mode 3 + on, user-owned token (CLIENT_ISOLATION_NET empty): list untouched
        CLIENT_ISOLATION=1 ALLOWED_IPS_MODE=3 ALLOWED_IPS="192.168.50.0/24, 10.9.9.0/24" CLIENT_ISOLATION_NET=""
        _apply_isolation_to_allowed_ips; echo "C:$ALLOWED_IPS|NET=$CLIENT_ISOLATION_NET"
        # (d) mode 3 + on, our own token (CLIENT_ISOLATION_NET==net): token removed
        CLIENT_ISOLATION=1 ALLOWED_IPS_MODE=3 ALLOWED_IPS="192.168.50.0/24, 10.9.9.0/24" CLIENT_ISOLATION_NET=10.9.9.0/24
        _apply_isolation_to_allowed_ips; echo "D:$ALLOWED_IPS|NET=$CLIENT_ISOLATION_NET"
        # (e) off + our token already present (no-op branch): list unchanged AND
        # ownership SURVIVES - a reset here would re-strand the token on the
        # next subnet change (regression guard for the ":" branch)
        CLIENT_ISOLATION=0 ALLOWED_IPS_MODE=2 ALLOWED_IPS="1.0.0.0/8, 10.9.9.0/24" CLIENT_ISOLATION_NET=10.9.9.0/24
        _apply_isolation_to_allowed_ips; echo "E:$ALLOWED_IPS|NET=$CLIENT_ISOLATION_NET"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *'A:1.0.0.0/8, 8.8.8.8/32, 10.9.9.0/24|NET=10.9.9.0/24'* ]]
    [[ "$output" == *'B:1.0.0.0/8, 8.8.8.8/32|NET='* ]]
    [[ "$output" == *'C:192.168.50.0/24, 10.9.9.0/24|NET='* ]]
    [[ "$output" == *'D:192.168.50.0/24|NET='* ]]
    [[ "$output" == *'E:1.0.0.0/8, 10.9.9.0/24|NET=10.9.9.0/24'* ]]
}

@test "issue #178: RU/EN installer persists CLIENT_ISOLATION_NET into awgsetup_cfg.init" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -F "export CLIENT_ISOLATION_NET='\${CLIENT_ISOLATION_NET:-}'" "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
    done
}

@test "issue #178: CLIENT_ISOLATION whitelisted in safe_load_config (all four copies)" {
    for f in awg_common.sh awg_common_en.sh install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -c 'PREV_AWG_PORT|CLIENT_ISOLATION|CLIENT_ISOLATION_NET' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
        [ "$output" -ge 1 ]
    done
}

@test "issue #178: resume rollback guard covers CLI_ISOLATION (RU/EN)" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        block=$(awk '/current_step > 4/,/update_state 4/' "$BATS_TEST_DIRNAME/../$f")
        [[ "$block" == *'CLI_ISOLATION'* ]]
    done
}

@test "issue #178: RU/EN installer warns about regen --reset-routes on isolation change" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -c '_cfg_client_isolation' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
        [ "$output" -ge 2 ]   # захват + сравнение
    done
    # Legacy-конфиг (без ключа) должен захватываться как 1, а не как пусто.
    run grep -F '_cfg_client_isolation="${CLIENT_ISOLATION:-1}"' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Server-side isolation rules
# ---------------------------------------------------------------------------

@test "issue #178: render_server_config adds isolation DROP to PostUp/PostDown (RU/EN)" {
    for f in awg_common.sh awg_common_en.sh; do
        block=$(awk '/^render_server_config\(\)/,/^}/' "$BATS_TEST_DIRNAME/../$f")
        [[ "$block" == *'iptables -I FORWARD -i %i -o %i -j DROP'* ]]
        # PostDown guarded: rule may be absent after an on->off reinstall.
        [[ "$block" == *'iptables -D FORWARD -i %i -o %i -j DROP 2>/dev/null || true'* ]]
        [[ "$block" == *'ip6tables -I FORWARD -i %i -o %i -j DROP'* ]]
        [[ "$block" == *'CLIENT_ISOLATION'* ]]
    done
}

@test "issue #178: isolation DROP is appended after the ACCEPT insert (ends up above it)" {
    # PostUp выполняется слева направо; -I вставляет в начало цепочки, поэтому
    # DROP, идущий В СТРОКЕ ПОЗЖЕ ACCEPT, оказывается В ЦЕПОЧКЕ выше ACCEPT.
    for f in awg_common.sh awg_common_en.sh; do
        block=$(awk '/^render_server_config\(\)/,/^}/' "$BATS_TEST_DIRNAME/../$f")
        accept_first=$(grep -n 'local postup="iptables -I FORWARD -i %i -j ACCEPT' <<<"$block" | head -1 | cut -d: -f1)
        drop_line=$(grep -n 'postup=.*iptables -I FORWARD -i %i -o %i -j DROP' <<<"$block" | head -1 | cut -d: -f1)
        [ -n "$accept_first" ] && [ -n "$drop_line" ]
        [ "$drop_line" -gt "$accept_first" ]
    done
}

# ---------------------------------------------------------------------------
# Stale DROP cleanup (on->off reinstall)
# ---------------------------------------------------------------------------

@test "issue #178: step7 removes stale DROP rules when isolation is off (RU/EN)" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        block=$(awk '/^step7_start_service\(\)/,/^}/' "$BATS_TEST_DIRNAME/../$f")
        [[ "$block" == *'while iptables -D FORWARD -i awg0 -o awg0 -j DROP 2>/dev/null; do :; done'* ]]
        [[ "$block" == *'while ip6tables -D FORWARD -i awg0 -o awg0 -j DROP 2>/dev/null; do :; done'* ]]
        [[ "$block" == *'CLIENT_ISOLATION'* ]]
    done
}

@test "issue #178 functional: cleanup loop drains duplicates and only runs when off" {
    block=$(awk '/Переключение изоляции on->off/,/^    fi$/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh" | grep -v '^ *#')
    [ -n "$block" ]
    run bash -c '
        calls=0
        iptables() { calls=$((calls+1)); (( calls <= 3 )); }   # 3 stale rules, then exhausted
        ip6tables() { return 1; }
        CLIENT_ISOLATION=0
        '"$block"'
        echo "off:$calls"
        calls=0
        CLIENT_ISOLATION=1
        '"$block"'
        echo "on:$calls"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *'off:4'* ]]   # 3 успешных удаления + 1 финальная неудача
    [[ "$output" == *'on:0'* ]]    # при включённой изоляции цикл не запускается
}

@test "issue #178: uninstall drains stale isolation DROP rules (RU/EN)" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        block=$(awk '/^step_uninstall\(\)/,/^}/' "$BATS_TEST_DIRNAME/../$f")
        [[ "$block" == *'while iptables -D FORWARD -i awg0 -o awg0 -j DROP 2>/dev/null; do :; done'* ]]
        [[ "$block" == *'while ip6tables -D FORWARD -i awg0 -o awg0 -j DROP 2>/dev/null; do :; done'* ]]
    done
}

@test "issue #178: install summary logs the isolation state (RU/EN)" {
    run grep -c 'Изоляция клиентов: $(' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    [ "$status" -eq 0 ]
    run grep -c 'Client isolation: $(' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# PR #179 review: config values are untrusted - validate after safe_load_config
# ---------------------------------------------------------------------------

@test "issue #178 functional: CLIENT_ISOLATION from config is normalized to 0|1 (garbage -> warn + 1)" {
    # 'on' в арифметике [[ "on" -eq 1 ]] разыменуется как пустая переменная (=0)
    # и молча инвертирует настройку - мусор обязан нормализоваться с warn.
    block=$(awk '/CLIENT_ISOLATION из конфига/,/esac/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    [ -n "$block" ]
    run bash -c '
        warns=0
        log_warn() { warns=$((warns+1)); }
        CONFIG_FILE=/dev/null
        for v in on off yes 2 " " "0 1"; do
            CLIENT_ISOLATION="$v"
            '"$block"'
            echo "v=${v}:${CLIENT_ISOLATION}"
        done
        echo "warns:$warns"
        warns=0
        for v in "" 0 1; do
            CLIENT_ISOLATION="$v"
            '"$block"'
            echo "ok=${v}:${CLIENT_ISOLATION}"
        done
        echo "okwarns:$warns"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *'v=on:1'* ]]
    [[ "$output" == *'v=off:1'* ]]
    [[ "$output" == *'v=2:1'* ]]
    [[ "$output" == *'warns:6'* ]]      # каждый мусорный вариант дал warn
    [[ "$output" == *'ok=:'* ]]         # пусто остаётся пустым (нет ключа в конфиге)
    [[ "$output" == *'ok=0:0'* ]]
    [[ "$output" == *'ok=1:1'* ]]
    [[ "$output" == *'okwarns:0'* ]]    # валидные значения проходят молча
}

@test "issue #178 functional: CLIENT_ISOLATION_NET from config must be a single canonical CIDR" {
    # Значение с запятыми в substring-замене _apply_isolation_to_allowed_ips
    # съело бы соседние пользовательские маршруты одной заменой.
    fns=$(awk '/^tunnel_network_cidr\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    block=$(awk '/ownership-маркер: ровно один/,/^        fi$/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    [ -n "$fns" ] && [ -n "$block" ]
    run bash -c '
        warns=0
        log_warn() { warns=$((warns+1)); }
        CONFIG_FILE=/dev/null
        '"$fns"'
        for v in "1.0.0.0/8,8.0.0.0/8" "10.9.9.1/24" "not-a-cidr" "10.9.9.0/24 8.0.0.0/8"; do
            CLIENT_ISOLATION_NET="$v"
            '"$block"'
            echo "bad=${v}:<${CLIENT_ISOLATION_NET}>"
        done
        echo "warns:$warns"
        warns=0
        for v in "" "10.9.9.0/24" "10.9.0.0/16"; do
            CLIENT_ISOLATION_NET="$v"
            '"$block"'
            echo "ok=${v}:<${CLIENT_ISOLATION_NET}>"
        done
        echo "okwarns:$warns"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *'bad=1.0.0.0/8,8.0.0.0/8:<>'* ]]
    [[ "$output" == *'bad=10.9.9.1/24:<>'* ]]        # не канонический (не network-адрес)
    [[ "$output" == *'bad=not-a-cidr:<>'* ]]
    [[ "$output" == *'warns:4'* ]]
    [[ "$output" == *'ok=:<>'* ]]
    [[ "$output" == *'ok=10.9.9.0/24:<10.9.9.0/24>'* ]]
    [[ "$output" == *'ok=10.9.0.0/16:<10.9.0.0/16>'* ]]
    [[ "$output" == *'okwarns:0'* ]]
}

@test "issue #178: initialize_setup hard-resets CLIENT_ISOLATION_NET (no env inheritance, RU/EN)" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        block=$(awk '/^initialize_setup\(\)/,/^}/' "$BATS_TEST_DIRNAME/../$f")
        # Наследование из окружения запрещено: экспортированная снаружи
        # переменная иначе дотянется до удаления маршрутов из AllowedIPs.
        [[ "$block" != *'CLIENT_ISOLATION_NET="${CLIENT_ISOLATION_NET:-}"'* ]]
    done
}

@test "issue #178: config-load validation for CLIENT_ISOLATION/_NET present in RU/EN" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        block=$(awk '/^initialize_setup\(\)/,/^}/' "$BATS_TEST_DIRNAME/../$f")
        [[ "$block" == *'case "${CLIENT_ISOLATION:-}" in'* ]]
        [[ "$block" == *'""|0|1)'* ]]
        [[ "$block" == *'tunnel_network_cidr "$CLIENT_ISOLATION_NET"'* ]]
    done
}

@test "issue #178 functional: duplicated tokens in a corrupted ALLOWED_IPS are all removed" {
    fns=$(awk '/^tunnel_network_cidr\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
          awk '/^_apply_isolation_to_allowed_ips\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    [ -n "$fns" ]
    run bash -c '
        log() { :; }
        '"$fns"'
        AWG_TUNNEL_SUBNET=10.9.9.1/24
        # on + mode 2: обе копии текущего токена вычищаются
        CLIENT_ISOLATION=1 ALLOWED_IPS_MODE=2 ALLOWED_IPS="1.0.0.0/8, 10.9.9.0/24, 10.9.9.0/24, 8.8.8.8/32"
        _apply_isolation_to_allowed_ips; echo "A:$ALLOWED_IPS"
        # смена подсети: обе копии прежнего токена вычищаются
        CLIENT_ISOLATION=1 ALLOWED_IPS_MODE=2 ALLOWED_IPS="10.9.8.0/24, 1.0.0.0/8, 10.9.8.0/24" CLIENT_ISOLATION_NET=10.9.8.0/24
        _apply_isolation_to_allowed_ips; echo "B:$ALLOWED_IPS|NET=$CLIENT_ISOLATION_NET"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *'A:1.0.0.0/8, 8.8.8.8/32'* ]]
    [[ "$output" == *'B:1.0.0.0/8|NET='* ]]
}

@test "issue #178 functional: tab-separated ALLOWED_IPS token is still recognized" {
    # validate_cidr_list принимает табы как разделители - compact-нормализация
    # обязана их убирать, иначе токен с табом не матчится и задваивается.
    fns=$(awk '/^tunnel_network_cidr\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
          awk '/^_apply_isolation_to_allowed_ips\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    [ -n "$fns" ]
    run bash -c '
        log() { :; }
        '"$fns"'
        AWG_TUNNEL_SUBNET=10.9.9.1/24
        # off + mode 2: токен уже есть (за табом) - повторное добавление запрещено
        CLIENT_ISOLATION=0 ALLOWED_IPS_MODE=2 ALLOWED_IPS=$'"'"'1.0.0.0/8,\t10.9.9.0/24'"'"'
        _apply_isolation_to_allowed_ips; echo "A:$ALLOWED_IPS"
        # on + mode 2: токен за табом распознаётся и убирается
        CLIENT_ISOLATION=1 ALLOWED_IPS_MODE=2 ALLOWED_IPS=$'"'"'1.0.0.0/8,\t10.9.9.0/24, 8.8.8.8/32'"'"'
        _apply_isolation_to_allowed_ips; echo "B:$ALLOWED_IPS"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *$'A:1.0.0.0/8,\t10.9.9.0/24'* ]]   # ничего не добавлено
    [[ "$output" == *'B:1.0.0.0/8, 8.8.8.8/32'* ]]
}

@test "issue #178: render PostUp drains stale DROP copies before -I (RU/EN)" {
    # После сбойного -D в PostDown копия DROP копилась бы с каждым up. Дренаж,
    # а не -C: stale-копия лежит ниже свежего ACCEPT, -C пропустил бы вставку
    # и awg0->awg0 трафик ушёл бы в ACCEPT (изоляция молча сломана).
    for f in awg_common.sh awg_common_en.sh; do
        block=$(awk '/^render_server_config\(\)/,/^}/' "$BATS_TEST_DIRNAME/../$f")
        [[ "$block" == *'while iptables -D FORWARD -i %i -o %i -j DROP 2>/dev/null; do :; done; iptables -I FORWARD -i %i -o %i -j DROP'* ]]
        [[ "$block" == *'while ip6tables -D FORWARD -i %i -o %i -j DROP 2>/dev/null; do :; done; ip6tables -I FORWARD -i %i -o %i -j DROP'* ]]
    done
}

@test "issue #178: CLI route-mode reset also drops the isolation ownership record (RU/EN)" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        # Внутри блока сброса #170 (ALLOWED_IPS="") ownership обязан обнуляться
        # до пересчёта списка - иначе stale CLIENT_ISOLATION_NET присваивает
        # себе пользовательский токен из свежего --route-custom.
        # Проверяем наличие обоих строк в файле в нужном порядке
        grep -q 'Issue #170' "$BATS_TEST_DIRNAME/../$f"
        # После ALLOWED_IPS="" должно быть CLIENT_ISOLATION_NET="" в пределах 5 строк
        grep -A 5 'ALLOWED_IPS=""' "$BATS_TEST_DIRNAME/../$f" | grep -q 'CLIENT_ISOLATION_NET=""'
    done
}
