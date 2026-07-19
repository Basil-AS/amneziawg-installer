import os
import tempfile
import unittest
from pathlib import Path

from src.bot import PanelManager, ServerManager, Settings, Store, compact_snapshot, help_text, menu_keyboard


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
        self.assertTrue({"status", "health", "clients", "users"}.issubset(callback_data))

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


if __name__ == "__main__":
    unittest.main()
