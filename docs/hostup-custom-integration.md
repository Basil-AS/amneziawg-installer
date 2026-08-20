# HostUp custom integration

HostUp is intentionally panel-free. Its custom bot and P2P management remain
outside the web-panel deployment, but their endpoint and firewall state must
not contain a historical server IP.

`scripts/hostup-update-rules.sh` derives the current global IPv4 from the
configured external interface and reads client IPv4/P2P-port pairs from
`client_ports.json`. It can be installed as
`/root/amnezia_management/update_rules.sh` and run after a provider address
change. It does not assign public IPv6 addresses to AWG peers: the current
HostUp route provides a public IPv6 for the host and forwarding, while the AWG
peer subnet is `fd10:10::/64`. A provider-routed `/64` must be confirmed before
changing that design.
