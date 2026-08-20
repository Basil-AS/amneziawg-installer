# Domain-First Endpoint and IPv6 Design

## Goal

Make the three-server AmneziaWG deployment resilient to public-IP changes by
using DNS names as transport endpoints, keeping panel URLs on separate HTTPS
names, deriving displayed server addresses from live state, and validating
IPv6 without exposing secrets or breaking existing client identities.

## Current topology

| Role | Transport name | Panel name | IPv4 | IPv6 |
|---|---|---|---|---|
| Finland / `hostkey` | `s1.charles.men` | `fin.charles.men` | `151.241.229.27` | none |
| Germany / `gsweb` | `s2.charles.men` | `ger.charles.men` | `77.90.29.231` | `2a09:9340:808:4::2` |
| HostUp / `hostup` | `s3.charles.men` | none | `82.197.73.253` | `2a13:7c81:1e7::3/48` |

Transport names remain DNS-only because Cloudflare proxying does not carry the
AWG UDP endpoint. Panel names remain proxied HTTPS names.

## Design

1. `web/server.py` will resolve configured domain endpoints and detect current
   global interface addresses as fallbacks. A stale literal `AWG_ENDPOINT`
   must not override a live address when the endpoint is an IP.
2. Explicit custom panel domains remain authoritative. Generated `sslip.io`
   names are treated as derived values and regenerated from the current
   endpoint rather than preserved after an IP change.
3. A server endpoint migration operation will update `AWG_ENDPOINT` to the
   transport domain, update panel-domain settings where requested, and
   regenerate derived client artifacts while preserving keys, peer addresses,
   PSKs, routing choices, and expiry metadata.
4. HostUp remains panel-free. Its custom management scripts are audited for
   literal transport addresses and changed to `s3.charles.men` only where the
   endpoint contract requires it.
5. HostUp's existing public `/48`, default route, forwarding, and ULA AWG
   subnet are validated. A public client-routed subnet is added only when the
   provider route is confirmed; otherwise the existing working IPv6 is left
   intact and the limitation is documented.
6. DNS records are inspected before mutation. Existing correct records are
   preserved; only mismatches needed for the topology are changed.

## Safety and rollout

- No private keys, PSKs, tokens, or client configuration contents are printed.
- Each server receives a root-only backup before configuration mutation.
- AWG tunnel state is not rotated; only endpoint/config-derived artifacts are
  changed, followed by a targeted web-panel restart and health checks.
- Code is pushed to a feature branch and delivered through a PR, never directly
  to `main`.

## Verification

- Unit tests cover domain resolution, live IPv4/IPv6 detection, stale-IP
  handling, and generated-domain replacement.
- Shell tests and Python compilation pass locally.
- Cloudflare DNS records, panel HTTPS responses, service states, interface
  addresses, routes, and forwarding are checked after deployment.
- Existing client key fingerprints and peer counts are compared before and
  after migration.
