#!/usr/bin/env bats
# shellcheck disable=SC2016

@test "UFW prompt defaults to yes and refusal is warning path" {
    local ru="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    local en="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -qF 'Включить UFW? [Y/n]:' "$ru"
    grep -qF 'Enable UFW? [Y/n]:' "$en"
    grep -qF 'confirm_ufw="${confirm_ufw:-y}"' "$ru"
    grep -qF 'confirm_ufw="${confirm_ufw:-y}"' "$en"
    grep -qF 'UFW не включён. Убедитесь' "$ru"
    grep -qF 'UFW not enabled. Ensure' "$en"
}

@test "--disable-ufw and AWG_DISABLE_UFW are explicit firewall opt-out" {
    local ru="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    local en="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -qF -- '--disable-ufw)' "$ru"
    grep -qF -- '--disable-ufw)' "$en"
    grep -qF 'AWG_DISABLE_UFW' "$ru"
    grep -qF 'AWG_DISABLE_UFW' "$en"
    grep -qF 'Firewall responsibility: ${firewall_resp}' "$ru"
    grep -qF 'Firewall responsibility: ${firewall_resp}' "$en"
}

@test "trusted web cert modes are optional and selfsigned remains default" {
    local ru="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'AWG_WEB_CERT_MODE="${AWG_WEB_CERT_MODE:-selfsigned}"' "$ru"
    grep -qF 'selfsigned|custom|letsencrypt|ip-domain' "$ru"
    grep -qF 'certbot certonly --standalone --non-interactive --agree-tos' "$ru"
    grep -qF 'chmod 600 "$web_dir/key.pem"' "$ru"
    grep -qF 'web_ip_domain()' "$ru"
}
