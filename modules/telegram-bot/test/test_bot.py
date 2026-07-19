import os
import tempfile
import unittest
import hashlib
import hmac
import json
import time
from urllib.parse import urlencode
from pathlib import Path

from src.bot import PanelManager, ServerManager, Settings, Store, admin_keyboard, callback_command, compact_snapshot, help_text, maintenance_keyboard, menu_keyboard, reply_keyboard, verify_init_data, client_keyboard, clients_keyboard, format_bytes, format_panel_payload, parallel_payloads, sparkline, usage_bar


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

    def test_client_refs_are_short_and_user_scoped(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(Path(directory) / "state.sqlite3")
            ref = store.client_ref(42, "finland", "a-name-with-a-long-but-valid-client-profile")
            self.assertLessEqual(len(ref), 10)
            self.assertEqual(store.resolve_client_ref(42, ref), ("finland", "a-name-with-a-long-but-valid-client-profile"))
            self.assertIsNone(store.resolve_client_ref(43, ref))
            store.close()

    def test_favorites_are_individual_and_toggle_idempotently(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(Path(directory) / "state.sqlite3")
            store.set_favorite(42, "germany", "phone")
            store.set_favorite(42, "germany", "phone")
            self.assertTrue(store.is_favorite(42, "germany", "phone"))
            self.assertFalse(store.is_favorite(43, "germany", "phone"))
            self.assertEqual([(row["server"], row["client_name"]) for row in store.favorites(42)], [("germany", "phone")])
            store.set_favorite(42, "germany", "phone", False)
            self.assertFalse(store.is_favorite(42, "germany", "phone"))
            store.close()

    def test_access_request_is_rate_limited_until_binding(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(Path(directory) / "state.sqlite3")
            self.assertTrue(store.request_access(42))
            self.assertFalse(store.request_access(42))
            store.bind(42, "user", "Name", "fin", "ger")
            self.assertEqual(store.get(42)["finland_token"], "fin")
            store.close()

    def test_access_request_can_be_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(Path(directory) / "state.sqlite3")
            self.assertTrue(store.request_access(42))
            store.resolve_access_request(42, "rejected")
            self.assertTrue(store.request_access(42))
            store.close()

    def test_input_prompt_is_persistent(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(Path(directory) / "state.sqlite3")
            store.set_prompt(42, "add_client", "germany")
            prompt = store.prompt(42)
            self.assertEqual((prompt["action"], prompt["server"]), ("add_client", "germany"))
            store.clear_prompt(42)
            self.assertIsNone(store.prompt(42))
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

    def test_missing_user_token_never_falls_back_to_panel_super_token(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "panels.json"
            path.write_text('{"panels":[{"id":"finland","url":"https://vpn.invalid","token":"super-secret"}]}', encoding="utf-8")
            manager = PanelManager(path)
            result = manager.request("finland", "snapshot", None)
            self.assertEqual(result["error"], "panel token is not assigned")
            self.assertNotIn("super-secret", str(result))

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

    def test_format_bytes_is_human_readable(self):
        self.assertEqual(format_bytes(0), "0 B")
        self.assertEqual(format_bytes(1024 * 1024), "1.0 MiB")

    def test_telemetry_visuals_are_compact(self):
        self.assertEqual(len(sparkline([1, 2, 3, 4], width=12)), 4)
        self.assertEqual(sparkline([5, 5, 5]), "▁▁▁")
        self.assertEqual(usage_bar(50, 100, width=10), "█████░░░░░")

    def test_parallel_payloads_preserve_panel_order(self):
        class FakePanel:
            def request(self, key, action, token):
                return {"panel": key, "action": action}
        result = parallel_payloads(FakePanel(), ("finland", "germany"), "snapshot", {"finland": "a", "germany": "b"})
        self.assertEqual([item["panel"] for item in result], ["finland", "germany"])

    def test_diagnostics_are_cards_not_raw_json(self):
        rendered = format_panel_payload({"panel": "Sunny-Finland", "status": "ok", "cpu": {"usage_percent": 12.5, "status": "ok"}, "memory": {"used_percent": 33, "status": "ok"}, "disk": {"used_percent": 44, "status": "ok"}, "load": {"one": 0.2, "five": 0.1, "status": "ok"}, "services": {"vpn_interface": {"status": "active"}}, "network": {"drops_delta": 0, "errors_delta": 0}}, "health")
        self.assertIn("Sunny-Finland", rendered)
        self.assertIn("CPU", rendered)
        self.assertNotIn('"cpu"', rendered)

    def test_infrastructure_cards_do_not_dump_nested_json(self):
        rendered = format_panel_payload({"panel": "Sunny-Finland", "providers": {"maxmind": {"status": "ready"}}, "databases": {"city": {"status": "fresh"}}}, "geoip-status")
        self.assertIn("maxmind", rendered)
        self.assertNotIn('"providers"', rendered)

    def test_menu_contains_admin_actions(self):
        callback_data = {item["callback_data"] for row in menu_keyboard(True) for item in row}
        admin_data = {item["callback_data"] for row in admin_keyboard() for item in row}
        self.assertTrue({"server:status:all", "server:health:all", "server:clients:all", "admin:users:0"}.issubset(callback_data))
        self.assertTrue({"server:geoip-status:all", "server:web-cert:all"}.issubset(admin_data))
        maintenance_data = {item["callback_data"] for row in maintenance_keyboard() for item in row}
        self.assertTrue({"admin:dns-restart:finland", "admin:reboot:all", "admin:geoip-update:all"}.issubset(maintenance_data))

    def test_menu_contains_user_controls(self):
        callback_data = {item["callback_data"] for row in menu_keyboard(False) for item in row}
        self.assertTrue({"user:clients", "user:traffic", "user:favorites", "user:add", "menu:profile"}.issubset(callback_data))

    def test_client_callbacks_fit_telegram_limit(self):
        buttons = client_keyboard("germany", "a" * 48, "0123456789", admin=False)
        callbacks = [button["callback_data"] for row in buttons for button in row]
        self.assertTrue(all(len(value.encode()) <= 64 for value in callbacks))
        self.assertTrue(all(len(button["callback_data"].encode()) <= 64 for row in clients_keyboard([("germany", "a" * 48, "0123456789")]) for button in row))
        self.assertTrue({"client:toggle:0123456789:1", "client:p2p-toggle:0123456789:1", "client:ports-toggle:0123456789:1", "client:p2p-port:0123456789:1", "client:access-link:0123456789:1", "client:favorite-add:0123456789:1", "client:remove:0123456789:1"}.issubset({button["callback_data"] for row in buttons for button in row}))
        paged = {button["callback_data"] for row in clients_keyboard([], page=2, pages=3) for button in row}
        self.assertTrue({"user:clients:1", "user:clients:2", "user:clients:3"}.issubset(paged))

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

    def test_tunnel_argv_pins_known_hosts_when_configured(self):
        old_hosts = os.environ.get("SSH_KNOWN_HOSTS")
        old_host = os.environ.get("FINLAND_SSH_HOST")
        old_identity = os.environ.get("FINLAND_SSH_IDENTITY")
        os.environ["SSH_KNOWN_HOSTS"] = "/tmp/known_hosts"
        os.environ["FINLAND_SSH_HOST"] = "vpn.example"
        os.environ["FINLAND_SSH_IDENTITY"] = "/tmp/key"
        try:
            argv = ServerManager().tunnel_argv("finland", 18443)
            self.assertIn("StrictHostKeyChecking=yes", argv)
            self.assertIn("UserKnownHostsFile=/tmp/known_hosts", argv)
        finally:
            if old_hosts is None:
                os.environ.pop("SSH_KNOWN_HOSTS", None)
            else:
                os.environ["SSH_KNOWN_HOSTS"] = old_hosts
            if old_host is None:
                os.environ.pop("FINLAND_SSH_HOST", None)
            else:
                os.environ["FINLAND_SSH_HOST"] = old_host
            if old_identity is None:
                os.environ.pop("FINLAND_SSH_IDENTITY", None)
            else:
                os.environ["FINLAND_SSH_IDENTITY"] = old_identity

    def test_ssh_manager_is_transport_only(self):
        self.assertFalse(hasattr(ServerManager, "run"))

    def test_admin_help_lists_panel_diagnostics(self):
        text = help_text(True)
        for command in ("/info", "/readiness", "/dns", "/resolver", "/audit", "/tokens", "/history", "/latency", "/provider"):
            self.assertIn(command, text)

    def test_reply_keyboard_is_compact(self):
        keyboard = reply_keyboard()
        self.assertEqual(sum(len(row) for row in keyboard), 6)
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
