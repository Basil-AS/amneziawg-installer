import os
import tempfile
import unittest
import hashlib
import hmac
import json
import time
from urllib.parse import urlencode
from pathlib import Path

from src.bot import PanelManager, ServerManager, Settings, Store, admin_keyboard, callback_command, compact_snapshot, help_text, menu_keyboard, reply_keyboard, verify_init_data


class BotTests(unittest.TestCase):
    def test_store_bind_and_update(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(Path(directory) / "state.sqlite3")
            store.bind(151599744, "basil", "Vasily", "fin-1", "ger-1")
            store.bind(151599744, "basil", "Vasily", "fin-2", "ger-2")
            row = store.get(151599744)
            self.assertEqual(row["finland_token"], "fin-2")
            self.assertEqual(len(store.all()), 1)
            store.close()

    def test_touch_registers_unbound_user_without_tokens(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(Path(directory) / "state.sqlite3")
            store.touch(42, "user", "Name")
            row = store.get(42)
            self.assertEqual(row["username"], "user")
            self.assertEqual(row["finland_token"], "")
            self.assertEqual(row["germany_token"], "")
            store.close()

    def test_settings_rejects_missing_token(self):
        old = os.environ.pop("BOT_TOKEN", None)
        try:
            with self.assertRaises(RuntimeError):
                Settings.from_env()
        finally:
            if old is not None:
                os.environ["BOT_TOKEN"] = old

    def test_panel_config_is_loaded_without_exposing_token(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "panels.json"
            path.write_text('{"panels":[{"id":"finland","name":"Sunny-Finland","url":"https://vpn.invalid","token":"secret"}]}', encoding="utf-8")
            manager = PanelManager(path)
            self.assertEqual(manager.keys(), ["finland"])
            self.assertNotIn("secret", manager.run("finland", "unsupported") or "")

    def test_compact_snapshot_is_small_and_human_readable(self):
        text = compact_snapshot({
            "panel": "Sunny-Finland",
            "display_name": "Sunny-Finland",
            "version": "5.19.2-bas.3",
            "service": "active",
            "summary": {"online": 2, "total": 5},
        })
        self.assertIn("Sunny-Finland", text)
        self.assertIn("2/5", text)
        self.assertLess(len(text), 500)

    def test_menu_contains_admin_actions(self):
        callback_data = {item["callback_data"] for row in menu_keyboard(True) for item in row}
        self.assertTrue({"server:status:all", "server:health:all", "server:clients:all", "admin:users:0"}.issubset(callback_data))

    def test_tunnel_argv_uses_loopback_forward(self):
        old = {key: os.environ.get(key) for key in ("FINLAND_SSH_HOST", "FINLAND_SSH_IDENTITY")}
        os.environ["FINLAND_SSH_HOST"] = "vpn.example"
        os.environ["FINLAND_SSH_IDENTITY"] = "/tmp/key"
        try:
            argv = ServerManager().tunnel_argv("finland", 18443)
            self.assertIn("127.0.0.1:18443:127.0.0.1:8443", argv)
        finally:
            for key, value in old.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

    def test_admin_help_lists_panel_diagnostics(self):
        text = help_text(True)
        for command in ("/info", "/readiness", "/dns", "/resolver", "/audit", "/tokens"):
            self.assertIn(command, text)

    def test_reply_keyboard_is_compact(self):
        keyboard = reply_keyboard()
        self.assertEqual(sum(len(row) for row in keyboard), 5)
        self.assertIn("🏠 Меню", keyboard[0])

    def test_callback_payloads_are_command_safe(self):
        self.assertEqual(callback_command("nav:status"), "/status")
        self.assertEqual(callback_command("nav:logs finland"), "/logs finland")
        self.assertEqual(callback_command("clients"), "/clients")
        self.assertIn("menu:home", {item["callback_data"] for row in admin_keyboard() for item in row})

    def test_mini_app_init_data_signature(self):
        token = "123456:secret"
        pairs = {"auth_date": str(int(time.time())), "user": json.dumps({"id": 151599744, "username": "basil"}, separators=(",", ":"))}
        check = "\n".join(f"{key}={pairs[key]}" for key in sorted(pairs))
        secret = hmac.new(b"WebAppData", token.encode(), hashlib.sha256).digest()
        pairs["hash"] = hmac.new(secret, check.encode(), hashlib.sha256).hexdigest()
        user = verify_init_data(urlencode(pairs), token)
        self.assertEqual(user["id"], 151599744)
        pairs["hash"] = "0" * 64
        with self.assertRaises(ValueError):
            verify_init_data(urlencode(pairs), token)


if __name__ == "__main__":
    unittest.main()
