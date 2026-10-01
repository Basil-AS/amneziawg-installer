# Panel gate (reference)

An nginx front for the web panel that looks like an ordinary static site to everybody who does not hold a
personal access cookie. It is a reference, not an installer step: copy the files, replace the placeholders, test
with `nginx -t` and `fail2ban-regex`.

- `nginx-site.conf.example` - decoy site, personal links `/i/<random>`, cookie check through `auth_request`.
- `fail2ban/` - bans repeated wrong links and scanner probes.

How people get in
1. `manage web gate create <name>` (or panel -> Advanced -> Access links) prints a personal link.
2. Opening the link once stores a signed cookie (`__Host-sid`, 180 days, HttpOnly, Secure, SameSite=Strict).
3. After that the plain address shows the panel; the panel still asks for a token. No token ever goes into a URL.
4. `manage web gate revoke <id>` (or Revoke in the panel) cuts that browser off immediately.

Layers, outermost first: personal link -> cookie -> panel token login -> role check. Every gate event, login,
failed login and every non-GET API call is written to `/var/log/awg-web-access.log` (JSON lines with time,
client ip and a coarse device) and shown under Advanced -> Access log. Link redemptions are also in
`/var/log/nginx/gate.log`.

Panel side: bind it to `127.0.0.1`, access policy mode `public_nginx`, and set `AWG_WEB_PUBLIC_URL` to the public
address without a port so the printed links are right.
