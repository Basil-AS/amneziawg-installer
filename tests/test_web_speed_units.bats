#!/usr/bin/env bats
# shellcheck disable=SC2016

@test "web UI displays live speeds in Mbps while total traffic stays byte-based" {
  grep -qF 'function speed(n)' web/app.js
  grep -qF 'Mbps' web/app.js
  grep -qF '* 8 / 1000 / 1000' web/app.js

  grep -qF 'function bytes(n)' web/app.js
  grep -qF 'function clientTraffic(data = {})' web/app.js
  grep -qF 'clientUploadSpeedBps: rxSpeed' web/app.js
  grep -qF 'clientDownloadSpeedBps: txSpeed' web/app.js
  grep -qF 'Download ${bytes(stats.download)} · Upload ${bytes(stats.upload)}' web/app.js
  grep -qF '↓ ${esc(speed(client.clientDownloadSpeedBps))}' web/app.js
  grep -qF '↑ ${esc(speed(client.clientUploadSpeedBps))}' web/app.js
  grep -qF 'trafficMetricRow("Total", clientTotal)' web/app.js
  grep -qF 'trafficMetricRow("30 days", client30d)' web/app.js
  grep -qF '.traffic-metric-row' web/style.css

  run bash -c '! grep -qF "Total ↓" web/app.js'
  [ "$status" -eq 0 ]

  run bash -c '! grep -qF "30d ↓" web/app.js'
  [ "$status" -eq 0 ]

  run bash -c '! grep -qF '\''Down ${bytes'\'' web/app.js'
  [ "$status" -eq 0 ]

  run bash -c '! grep -qF "MiB/s" web/app.js'
  [ "$status" -eq 0 ]

  run bash -c '! grep -qF "MB/s" web/app.js'
  [ "$status" -eq 0 ]
}
