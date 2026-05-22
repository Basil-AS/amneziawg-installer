# Fork Patchset

This repository is a fork of `bivlked/amneziawg-installer`.

Current upstream base marker remains `5.13.0`. Selected upstream `5.14.0`-`5.14.3` fixes are manually ported on top of the fork; this file is the fork-delta map for future sync work.

## Runtime Fork Delta

- Python stdlib Web Panel in `web/` with HTTPS support, bearer token auth, RBAC/user tokens, import tokens, QR/config download, stats/logs/restart actions, client regenerate, and server rotate-profile.
- Local web assets with strict static allowlist; private files such as `tokens.json`, `import_tokens.json`, certs, keys, and configs must not be served as static files.
- Browser-side AWG I1 generation in `web/awg_i1.js` and server/client regeneration paths using `AWG_I1_OVERRIDE` / `AWG_I1_OVERRIDES_FILE`.
- AdGuard Home DNS integration without Docker, including curated config, preserved `user_rules`, client sync, local VPN DNS routing, and service management.
- IPv6 client support: routed/native, NDP, NAT66/fallback modes, aliases, client/server metadata, and split/custom route handling.
- P2P ports and DNAT support with generated firewall hooks: `postup.sh`, `postdown.sh`, `p2p_rules.sh`.
- Client metadata comments for names, IPv6, P2P ports, expiry, WireSock hints, and `vpn://` URI/QR integration.
- Safe voice/calls UDP optimization: MTU, `PersistentKeepalive = 25`, conntrack UDP timeout tuning, and read-only `voice-check` / `udp-check`.
- Single-file bootstrap with pinned SHA manifest for runtime assets, including `awg_common*.sh`, `manage_amneziawg*.sh`, and `web/**`.
- `INSTALL_SUMMARY.txt` access/secrets block with strict permissions and backup behavior.

## Manually Ported Upstream 5.14.x Fixes

- `5.14.0`: extended `get_server_public_ip` fallback services while keeping stdout as IP-only.
- `5.14.0`: compatible `manage diagnose [--carrier=NAME]`, extended with fork-specific web/AdGuard/IPv6/P2P/WireSock status sections.
- `5.14.1`: MTU resolution for regenerated client configs: live `awg0.conf` MTU, then `AWG_MTU`, then `1280`.
- `5.14.2`: high-density `vpn://` QR generation via `qrencode -t png -l L -s 6 -m 4`.
- `5.14.2`: ARM build `_resolve_kernel_version`, preserving fork atomic xz hardening.
- `5.14.3`: `cleanup_system` network safety: no cleanup autoremove, network package holds, default route check and recovery.

## Tests Protecting Fork Delta

- `tests/test_web_panel.bats`
- `tests/test_adguard_dns.bats`
- `tests/test_client_regenerate.bats`
- `tests/test_server_rotate_profile.bats`
- `tests/test_voice_udp.bats`
- `tests/test_random_port_and_raw.bats`
- `tests/test_v5140_diagnose.bats`
- `tests/test_v5140_public_ip_services.bats`
- `tests/test_v5141_mtu_resolution.bats`
- `tests/test_v5142_qr_high_density.bats`
- `tests/test_v5142_build_arm_deb.bats`
- `tests/test_v5143_cleanup_no_autoremove.bats`
- `tests/test_v5143_fork_delta_regressions.bats`

## Sync Rule

Do not full-merge upstream changes into hot files blindly. Accept upstream bug fixes, OS support, dependency fixes, and security improvements only after checking that Web Panel, AdGuard, IPv6, P2P/DNAT, WireSock, QR/vpn URI, regenerate, cleanup, and bootstrap SHA behavior are preserved in both RU and EN runtime branches.
