# Fork Patchset

This repository is a fork of `bivlked/amneziawg-installer`.

Current upstream sync marker is `5.15.3` (`upstream/main` short hash `13203c6`) with selected upstream fixes manually ported on top of the fork; this file is the fork-delta map for future sync work.

Fork releases use `<upstream-sync>-bas.<revision>`. Current fork version is `5.15.3-bas.1`; `bas.N` increments for fork-only releases and resets to `bas.1` when the upstream sync marker changes. The marker does not imply a full upstream merge.

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
- `5.14.5`: `detect_ssh_ports` and UFW SSH lockout guard, adapted to keep fork Web/AdGuard firewall rules. The fork also includes the current `SSH_CONNECTION` server port as a safety source when available.

## Upstream Sync Notes

### 2026-06-04 sync from upstream `13203c6` (`v5.15.3`)

- Strategy: selective/manual port. A full merge would remove fork-only `web/` panel files and many fork-specific tests, so it was intentionally not used.
- Upstream base before sync: merge-base `edf4f7b`; fork HEAD before sync: `460b9c9`.
- Accepted upstream changes:
  - `e016bb6` / v5.14.5 SSH lockout fix: added `detect_ssh_ports`, `--ssh-port=PORT[,PORT]`, and UFW loops over detected SSH ports in both RU and EN installers.
  - Added regression coverage in `tests/test_ssh_port_detect.bats` for CLI overrides, `sshd -T`, `ss`, current `SSH_CONNECTION`, UFW inactive/active branches, RU/EN parity, and `sshd_config.d/*.conf` structural support.
- Already preserved from earlier fork sync work:
  - Ubuntu 25.10 / 26.04 support and docs.
  - `--force` / `AWG_FORCE_REINSTALL=1` reinstall safety guard.
  - PPA `noble` fallback logic for Ubuntu non-LTS releases, intentionally gated behind `AWG_ALLOW_PPA_CODENAME_FALLBACK=1` / `--allow-ppa-codename-fallback` in this fork.
  - v5.14.0-v5.14.3 public IP, diagnose, MTU, QR, ARM, and cleanup/network safety fixes listed above.
- Preserved fork delta:
  - Python stdlib Web Panel, HTTPS, bearer/RBAC/user self-service, Web Access Policy, AdGuard, IPv6 modes, P2P/DNAT hooks, metadata comments, `vpn://`, QR, WireSock hints, and voice UDP optimizations.
- Conflicts/resolution:
  - No Git merge conflicts because this was a manual port.
  - `setup_improved_firewall` was not replaced from upstream; only SSH detection was integrated so fork-specific Web/AdGuard firewall behavior remains intact.
- Tests run:
  - See final sync commit/report for the exact command list and results.

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
- `tests/test_ssh_port_detect.bats`

## Sync Rule

Do not full-merge upstream changes into hot files blindly. Accept upstream bug fixes, OS support, dependency fixes, and security improvements only after checking that Web Panel, AdGuard, IPv6, P2P/DNAT, WireSock, QR/vpn URI, regenerate, cleanup, and bootstrap SHA behavior are preserved in both RU and EN runtime branches.
