# Domain-First IPv6 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make endpoint and panel addressing resilient to IP changes, migrate the three live servers to domain-first endpoints, and validate routed IPv6 safely.

**Architecture:** Keep DNS-only transport names (`s1/s2/s3.charles.men`) separate from proxied HTTPS panel names (`fin/ger.charles.men`). The panel reports addresses from resolved endpoint DNS and live interface state, while explicit custom domains remain stable. A migration command updates endpoint config and regenerates derived client artifacts without rotating keys or peer addresses.

**Tech Stack:** Python stdlib web panel and unittest, Bash installer/manage scripts and Bats tests, SSH/systemd, Cloudflare DNS MCP/API.

## Global Constraints

- Never print or commit private keys, PSKs, bearer tokens, `tokens.json`, or client config contents.
- Cloudflare proxying is allowed for HTTPS panel names only; AWG transport names remain DNS-only.
- Preserve existing client keys, peer IPs, PSKs, routes, and expiry metadata during endpoint migration.
- Do not add a web panel to `hostup`.
- Do not assign the provider's unconfirmed routed IPv6 block to `hostup`; validate before changing routes.
- Work only on `agent/feat-domain-ipv6`, push through a PR, and do not commit directly to `main`.

---

### Task 1: Add failing tests for dynamic endpoint resolution

**Files:**
- Modify: `web/server.py` tests or add the existing project test location that exercises panel helpers.
- Test: `tests/test_web_panel.bats` for shell-facing behavior where applicable.

**Interfaces:**
- Produces tests for `server_info_payload()` and address helper behavior.

- [ ] Add tests proving a hostname endpoint reports its resolved A/AAAA values.
- [ ] Add tests proving a stale literal endpoint is replaced by a live detected IPv4.
- [x] Add tests proving a custom `AWG_WEB_DOMAIN` is retained while generated `sslip.io` is refreshed.
- [ ] Run the focused tests and verify they fail for the missing behavior.

### Task 2: Implement panel address detection

**Files:**
- Modify: `web/server.py` around `detect_public_ipv6()` and `server_info_payload()`.
- Test: tests from Task 1.

**Interfaces:**
- Add small pure/testable helpers for endpoint host parsing, DNS resolution, live IPv4 detection, and generated-domain detection.
- `server_info_payload()` returns the current `public_ipv4`, `public_ipv6`, stable panel URL, and transport endpoint context.

- [x] Implement non-blocking DNS resolution with bounded timeouts and no secret-bearing logs.
- [x] Implement live IPv4 detection from the default route/interface, rejecting loopback/private/link-local values.
- [x] Prefer resolved domain addresses, then live interface addresses, then a configured literal as a last-resort display value.
- [x] Preserve explicit non-generated panel domains and refresh generated `sslip.io` names.
- [x] Run focused tests and Python compilation; Bats is unavailable in this workspace.

### Task 3: Add endpoint/domain migration support

**Files:**
- Modify: `manage_amneziawg.sh`, `awg_common.sh`, and relevant installer documentation.
- Test: shell tests for endpoint migration and client artifact preservation.

**Interfaces:**
- Add a documented management operation accepting transport endpoint and optional panel domain.
- Regeneration uses existing client private keys and peer data; only derived endpoint-bearing artifacts change.

- [x] Add input validation for DNS names, IPv4, and bracketed IPv6 endpoints.
- [x] Add atomic config update with root-only backup.
- [x] Regenerate `.conf`, QR, and `vpn://` artifacts without rotating identity material.
- [x] Add rollback on failed regeneration or service health check.
- [x] Run shell syntax, targeted Bats, and preservation checks.

### Task 4: Make installer defaults domain-friendly

**Files:**
- Modify: installer endpoint/domain selection and README/ADVANCED documentation.
- Test: existing endpoint and web-panel Bats tests.

- [x] Document DNS-only transport versus proxied panel names.
- [x] Ensure generated panel domains are not persisted as the only endpoint source when a domain endpoint is configured.
- [x] Document IPv6 `A + AAAA`, `AllowedIPs = ::/0`, and fallback expectations without promising provider-routed client IPv6 where unavailable.
- [x] Run documentation consistency checks.

### Task 5: Migrate live servers with controlled checks

**Files:**
- Remote: `hostkey`, `gsweb`, `hostup` configuration and custom management scripts only.

- [x] Back up root-owned configuration and record non-secret fingerprints/counts.
- [x] `hostkey`: set `s1.charles.men`, `fin.charles.men`; migrate artifacts; restart only `awg-web`; verify HTTPS and AWG service.
- [x] `gsweb`: set `s2.charles.men`, `ger.charles.men`; preserve native IPv6/NDP; migrate artifacts; restart only `awg-web`; verify IPv4/IPv6 DNS and HTTPS.
- [x] `hostup`: audit custom scripts, set `s3.charles.men` where endpoint contracts require it, and verify IPv6 route/forwarding/AWG ULA state.
- [x] Add public routed IPv6 to `hostup` only if the provider's route is confirmed and the required `/64` is unambiguously selected; otherwise document the safe limitation.

### Task 6: Verify Cloudflare and deliver PR

- [x] Read back Cloudflare A/AAAA/proxy state for all transport and panel names.
- [x] Verify panel HTTP status, TLS hostnames, service states, endpoint values, and client key/peer preservation.
- [x] Run full local verification and inspect `git diff` for secrets or unrelated changes.
- [ ] Push the feature branch and create a PR with evidence.
- [ ] After the PR is approved/merged as authorized, delete the remote feature branch and clean the worktree.
