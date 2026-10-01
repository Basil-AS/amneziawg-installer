# Panel gate (reference)

An nginx front for the web panel that looks like an ordinary static site to everybody who does not know the
secret URL. It is a reference, not an installer step: copy the files, replace the placeholders, test with
`nginx -t` and `fail2ban-regex`.

- `nginx-site.conf.example` - decoy site, secret URL that sets a 12 h cookie, 404 for wrong guesses.
- `fail2ban/` - bans repeated wrong guesses and scanner probes.

Layers, outermost first: secret URL -> cookie -> panel token login (always required) -> role check.
Every login, failed login and every non-GET API call is written to `/var/log/awg-web-access.log`
(JSON lines with time, client ip and a coarse device); the panel shows it under Advanced -> Access log.
Gate hits are in `/var/log/nginx/gate.log`.

Panel side: bind the panel to `127.0.0.1` and set the access policy mode `public_nginx`.
