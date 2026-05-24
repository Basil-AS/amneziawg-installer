#!/usr/bin/env bats

@test "web UI displays live speeds in Mbps while total traffic stays byte-based" {
  grep -qF 'function speed(n)' web/app.js
  grep -qF 'Mbps' web/app.js
  grep -qF '* 8 / 1000 / 1000' web/app.js

  grep -qF 'function bytes(n)' web/app.js

  run bash -c '! grep -qF "MiB/s" web/app.js'
  [ "$status" -eq 0 ]

  run bash -c '! grep -qF "MB/s" web/app.js'
  [ "$status" -eq 0 ]
}
