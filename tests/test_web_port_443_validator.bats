#!/usr/bin/env bats

@test "interactive Web Panel HTTPS port prompt uses system-port validator helper" {
  grep -qF 'ask_web_port()' install_amneziawg.sh
  grep -qF 'ask_web_port()' install_amneziawg_en.sh

  grep -qF 'ask_web_port input_port "Введите HTTPS порт Web Panel' install_amneziawg.sh
  grep -qF 'ask_web_port input_port "Enter HTTPS Web Panel port' install_amneziawg_en.sh

  # shellcheck disable=SC2016
  grep -qF 'validate_port_system "$value"' install_amneziawg.sh
  # shellcheck disable=SC2016
  grep -qF 'validate_port_system "$value"' install_amneziawg_en.sh

  run bash -c '! grep -qF '"'"'ask_port input_port "Введите HTTPS порт Web Panel'"'"' install_amneziawg.sh'
  [ "$status" -eq 0 ]

  run bash -c '! grep -qF '"'"'ask_port input_port "Enter HTTPS Web Panel port'"'"' install_amneziawg_en.sh'
  [ "$status" -eq 0 ]
}

@test "Web HTTPS validator allows 1-65535 while VPN UDP validator keeps 1024-65535" {
  grep -qF 'validate_web_port()' install_amneziawg.sh
  grep -qF 'validate_web_port()' install_amneziawg_en.sh

  # shellcheck disable=SC2016
  grep -A8 '^validate_web_port()' install_amneziawg.sh | grep -qF 'validate_port_system "$port"'
  # shellcheck disable=SC2016
  grep -A8 '^validate_web_port()' install_amneziawg_en.sh | grep -qF 'validate_port_system "$port"'

  grep -A8 '^validate_port_user()' install_amneziawg.sh | grep -qF '1024-65535'
  grep -A8 '^validate_port_user()' install_amneziawg_en.sh | grep -qF '1024-65535'

  grep -A10 '^validate_port_system()' install_amneziawg.sh | grep -qF '1-65535'
  grep -A10 '^validate_port_system()' install_amneziawg_en.sh | grep -qF '1-65535'
}
