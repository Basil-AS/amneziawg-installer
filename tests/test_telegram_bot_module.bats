#!/usr/bin/env bats

@test "optional Telegram module has isolated service and installer" {
    [ -f "$BATS_TEST_DIRNAME/../modules/telegram-bot/src/bot.py" ]
    [ -f "$BATS_TEST_DIRNAME/../modules/telegram-bot/deploy/gaullebot.service" ]
    [ -f "$BATS_TEST_DIRNAME/../scripts/install-telegram-bot.sh" ]
    grep -q 'User=gaullebot' "$BATS_TEST_DIRNAME/../modules/telegram-bot/deploy/gaullebot.service"
    grep -q 'TELEGRAM_API_ROOT.*api.telegram.org' "$BATS_TEST_DIRNAME/../scripts/install-telegram-bot.sh"
}
