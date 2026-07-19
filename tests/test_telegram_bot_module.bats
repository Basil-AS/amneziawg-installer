#!/usr/bin/env bats

@test "optional Telegram module has isolated service and installer" {
    [ -f "$BATS_TEST_DIRNAME/../modules/telegram-bot/src/bot.py" ]
    [ -f "$BATS_TEST_DIRNAME/../modules/telegram-bot/deploy/gaullebot.service" ]
    [ -f "$BATS_TEST_DIRNAME/../scripts/install-telegram-bot.sh" ]
    grep -q 'User=gaullebot' "$BATS_TEST_DIRNAME/../modules/telegram-bot/deploy/gaullebot.service"
    grep -q 'TELEGRAM_API_ROOT.*api.telegram.org' "$BATS_TEST_DIRNAME/../scripts/install-telegram-bot.sh"
}

@test "panel exposes compact bot snapshot without browser-only enrichment" {
    grep -q 'u.path == "/api/bot/snapshot"' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -q 'def bot_snapshot_payload' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -q 'GET", "/api/bot/snapshot"' "$BATS_TEST_DIRNAME/../modules/telegram-bot/src/bot.py"
}

@test "web static assets negotiate gzip when it saves bandwidth" {
    grep -q 'gzip.compress' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -q 'Content-Encoding.*gzip' "$BATS_TEST_DIRNAME/../web/server.py"
}
