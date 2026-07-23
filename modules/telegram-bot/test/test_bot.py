import os
import tempfile
import unittest
import hashlib
import hmac
import json
import time
from unittest.mock import patch
from urllib.parse import urlencode
from pathlib import Path

from src.bot import PANEL_TOKEN, PanelManager, ServerManager, Settings, Store, admin_keyboard, callback_command, callback_message_is_media, client_stats_card, compact_snapshot, created_client_name, ensure_user_panel_token, format_metric_number, format_panel_payload, help_text, maintenance_keyboard, menu_keyboard, navigation_keyboard, panel_client_names, panel_token_records, provisioning_keyboard, provisioning_text, reply_keyboard, render_navigation, result_navigation_keyboard, send_client_bundle, snapshot_health, token_client_scope, token_record_by_prefix, uri_keyboard, valid_bearer_candidate, verify_init_data, client_keyboard, clients_keyboard, format_bytes, format_timestamp, merge_client_help_payloads, parallel_payloads, sparkline, usage_bar


class BotTests(unittest.TestCase):
    def test_health_metrics_use_one_decimal_place(self):
        payload = {
            "panel": "Sunny-Finland",
            "status": "ok",
            "cpu": {"usage_percent": 8.616187989556135, "status": "ok"},
            "memory": {"used_percent": 31.444932335820965, "status": "ok"},
            "disk": {"used_percent": 32.28923028306412, "status": "ok"},
            "load": {"one": 0.27, "five": 0.36, "status": "ok"},
            "services": {"web_edge": {"status": "unknown"}},
            "network": {"drops_delta": 0, "errors_delta": 0},
        }
        rendered = format_panel_payload(payload, "health")
        self.assertIn("8.6%", rendered)
        self.assertIn("31.4%", rendered)
        self.assertIn("32.3%", rendered)
        self.assertIn("0.3 / 0.4", rendered)
        self.assertNotIn("8.616187989556135", rendered)

    def test_new_client_bundle_sends_qr_and_config(self):
        class FakePanels:
            def artifact(self, server, name, kind, token):
                return (b"qr" if kind == "qr" else b"conf", "image/png" if kind == "qr" else "text/plain", f"{name}.{kind}")

        class FakeTelegram:
            def __init__(self):
                self.sent = []

            def send_photo(self, chat_id, filename, content, caption=""):
                self.sent.append(("photo", filename, content, caption))

            def send_document(self, chat_id, filename, content, caption=""):
                self.sent.append(("document", filename, content, caption))

        telegram = FakeTelegram()
        self.assertEqual(send_client_bundle(telegram, FakePanels(), 42, "finland", "phone", "scoped"), (True, True))
        self.assertEqual([item[0] for item in telegram.sent], ["photo", "document"])
        self.assertEqual(created_client_name({"id": "phone-2"}, "phone"), "phone-2")

    def test_stale_navigation_cleanup_never_classifies_media_as_menu(self):
        self.assertFalse(callback_message_is_media({"text": "Меню", "reply_markup": {}}))
        self.assertTrue(callback_message_is_media({"document": {"file_id": "opaque"}}))
        self.assertTrue(callback_message_is_media({"photo": [{"file_id": "opaque"}]}))

    def test_admin_help_does_not_advertise_insecure_bind_command(self):
        self.assertNotIn("/bind", help_text(True))

    def test_navigation_refresh_edits_current_menu_without_sending(self):
        class FakeTelegram:
            def __init__(self):
                self.edits = []
                self.deleted = []
                self.sent = []

            def edit_message(self, chat_id, message_id, text, *, keyboard=None):
                self.edits.append((chat_id, message_id, text, keyboard))
                return {"message_id": message_id}

            def delete_message(self, chat_id, message_id):
                self.deleted.append((chat_id, message_id))

            def send(self, chat_id, text, *, keyboard=None, reply_keyboard=None, force_reply=False):
                self.sent.append((chat_id, text, keyboard))
                return {"message_id": 99}

        with tempfile.TemporaryDirectory() as directory:
            store = Store(Path(directory) / "state.sqlite3")
            store.set_navigation(42, 17, "server:status:all")
            telegram = FakeTelegram()
            render_navigation(telegram, store, 42, "fresh", [[{"text": "🔄", "callback_data": "server:status:all"}]], "server:status:all", callback_message_id=17)
            self.assertEqual([item[1] for item in telegram.edits], [17])
            self.assertEqual(telegram.deleted, [])
            self.assertEqual(telegram.sent, [])
            store.close()

    def test_background_result_can_edit_current_menu_without_callback(self):
        class FakeTelegram:
            def __init__(self):
                self.edits = []
                self.sent = []

            def edit_message(self, chat_id, message_id, text, *, keyboard=None):
                self.edits.append(message_id)
                return {"message_id": message_id}

            def delete_message(self, *args):
                raise AssertionError("current menu must not be deleted")

            def send(self, *args, **kwargs):
                self.sent.append(args)
                return {"message_id": 99}

        with tempfile.TemporaryDirectory() as directory:
            store = Store(Path(directory) / "state.sqlite3")
            store.set_navigation(42, 17, "server:drops-sample:all")
            telegram = FakeTelegram()
            render_navigation(telegram, store, 42, "result", [], "server:drops-sample:all", edit_current=True)
            self.assertEqual(telegram.edits, [17])
            self.assertEqual(telegram.sent, [])
            store.close()

    def test_navigation_edit_failure_removes_old_menu_before_replacement(self):
        class FakeTelegram:
            def __init__(self):
                self.deleted = []
                self.sent = []

            def edit_message(self, *args, **kwargs):
                raise RuntimeError("message can't be edited")

            def delete_message(self, chat_id, message_id):
                self.deleted.append((chat_id, message_id))

            def send(self, chat_id, text, *, keyboard=None, reply_keyboard=None, force_reply=False):
                self.sent.append((chat_id, text))
                return {"message_id": 18}

        with tempfile.TemporaryDirectory() as directory:
            store = Store(Path(directory) / "state.sqlite3")
            store.set_navigation(42, 17, "server:status:all")
            telegram = FakeTelegram()
            render_navigation(telegram, store, 42, "replacement", [], "server:status:all", callback_message_id=17)
            self.assertEqual(telegram.deleted, [(42, 17)])
            self.assertEqual(len(telegram.sent), 1)
            self.assertEqual(store.navigation(42)["message_id"], 18)
            store.close()

    def test_store_bind_and_update(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(Path(directory) / "state.sqlite3")
            store.bind(151599744, "basil", "Vasily", "fin-1", "ger-1")
            store.bind(151599744, "basil", "Vasily", "fin-2", "ger-2")
            row = store.get(151599744)
            self.assertEqual(row["finland_token"], "fin-2")
            self.assertEqual(len(store.all()), 1)
            store.close()

    def test_approved_user_gets_scoped_panel_token_on_first_server_use(self):
        class FakePanels:
            def __init__(self):
                self.calls = []

            def request(self, server, action, token=None, value="", extra=None):
                self.calls.append((server, action, token, value, extra))
                if action == "clients":
                    return {"clients": [{"name": "existing-device"}]}
                if action == "create-user-token":
                    if token is not PANEL_TOKEN or value != "telegram-42-finland" or extra != {"clients": ["existing-device"]}:
                        raise AssertionError("unexpected token provisioning request")
                    return {"token": "scoped-secret"}
                raise AssertionError(action)

        with tempfile.TemporaryDirectory() as directory:
            store = Store(Path(directory) / "state.sqlite3")
            store.bind(42, "new_user", "New", "", "", resolve_request=False)
            store.request_access(42)
            store.resolve_access_request(42, "approved")
            token, error = ensure_user_panel_token(store, FakePanels(), 42, "finland")
            self.assertEqual((token, error), ("scoped-secret", None))
            self.assertEqual(store.get(42)["finland_token"], "scoped-secret")
            store.close()

    def test_unapproved_user_cannot_auto_provision_panel_token(self):
        class NoCalls:
            def request(self, *args, **kwargs):
                raise AssertionError("panel must not be contacted")

        with tempfile.TemporaryDirectory() as directory:
            store = Store(Path(directory) / "state.sqlite3")
            store.bind(43, "pending", "Pending", "", "", resolve_request=False)
            store.request_access(43)
            token, error = ensure_user_panel_token(store, NoCalls(), 43, "germany")
            self.assertIsNone(token)
            self.assertEqual(error, "access is not approved")
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

    def test_partial_provisioning_does_not_approve_until_finish(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(Path(directory) / "state.sqlite3")
            self.assertTrue(store.request_access(42))
            store.bind(42, "user", "Name", "fin", "", resolve_request=False)
            self.assertEqual(store.access_request_status(42), "pending")
            store.resolve_access_request(42, "approved")
            self.assertEqual(store.access_request_status(42), "approved")
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
            store.request_access(42)
            store.touch(42, "user", "Name")
            row = store.get(42)
            self.assertEqual(row["username"], "user")
            self.assertEqual(row["finland_token"], "")
            self.assertEqual(row["germany_token"], "")
            self.assertEqual(store.access_request_status(42), "pending")
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

    def test_generic_api_fallback_is_rendered_as_card_not_json(self):
        rendered = format_panel_payload({"panel": "Sunny-Germany", "message": "Обновление завершено", "details": {"service": "active"}}, "restart")
        self.assertIn("Обновление завершено", rendered)
        self.assertNotIn('"details"', rendered)

    def test_web_policy_flattens_nested_values(self):
        rendered = format_panel_payload({"panel": "Sunny-Finland", "mode": "vpn", "allowed_networks": ["10.9.0.0/16", "fd00::/8"]}, "web-policy")
        self.assertIn("10.9.0.0/16, fd00::/8", rendered)
        self.assertNotIn('"allowed_networks"', rendered)

    def test_rotate_token_uses_hash_path_and_never_logs_secret(self):
        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def read(self): return b'{"token":"new-secret","token_hash":"new-hash"}'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "panels.json"
            path.write_text('{"panels":[{"id":"finland","url":"https://vpn.invalid","token":"super-secret"}]}', encoding="utf-8")
            manager = PanelManager(path)
            with patch("src.bot.urlopen", return_value=Response()) as opened:
                result = manager.request("finland", "rotate-token", PANEL_TOKEN, value="a" * 64)
            self.assertEqual(result["token"], "new-secret")
            self.assertIn("/api/tokens/" + "a" * 64 + "/rotate", opened.call_args.args[0].full_url)
            self.assertNotIn("super-secret", str(result))

    def test_update_token_name_uses_hash_path_and_payload(self):
        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def read(self): return b'{"ok":true,"name":"Phone"}'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "panels.json"
            path.write_text('{"panels":[{"id":"finland","url":"https://vpn.invalid","token":"super-secret"}]}', encoding="utf-8")
            manager = PanelManager(path)
            with patch("src.bot.urlopen", return_value=Response()) as opened:
                result = manager.request("finland", "update-token-name", PANEL_TOKEN, value="a" * 64, extra={"name": "Phone"})
            self.assertTrue(result["ok"])
            request = opened.call_args.args[0]
            self.assertIn("/api/tokens/" + "a" * 64 + "/name", request.full_url)
            self.assertEqual(json.loads(request.data), {"name": "Phone"})

    def test_token_name_response_is_a_card(self):
        rendered = format_panel_payload({"panel": "Sunny-Finland", "ok": True, "name": "Phone"}, "update-token-name")
        self.assertIn("Имя:", rendered)
        self.assertIn("Phone", rendered)
        self.assertNotIn('"name"', rendered)

    def test_nettest_report_delete_is_confirmed_payload_and_card(self):
        rendered = format_panel_payload({"panel": "Sunny-Germany", "ok": True, "deleted": 3}, "nettest-reports-delete")
        self.assertIn("Удалено отчётов", rendered)
        self.assertIn("3", rendered)
        self.assertNotIn('"deleted"', rendered)

    def test_nettest_ping_is_allowlisted_and_query_scoped(self):
        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def read(self, _limit=-1): return b'{"ok":true,"server_time":"now"}'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "panels.json"
            path.write_text('{"panels":[{"id":"finland","url":"https://vpn.invalid","token":"super-secret"}]}', encoding="utf-8")
            manager = PanelManager(path)
            with patch("src.bot.urlopen", return_value=Response()) as opened:
                result = manager.nettest("finland", "ping", PANEL_TOKEN, test_id="mini-123")
            self.assertTrue(result["ok"])
            self.assertIn("/api/nettest/ping?test_id=mini-123", opened.call_args.args[0].full_url)

    def test_nettest_download_is_capped_at_four_megabytes(self):
        class Headers:
            def get_content_type(self): return "application/octet-stream"
        class Response:
            headers = Headers()
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def read(self, _limit=-1): return b"payload"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "panels.json"
            path.write_text('{"panels":[{"id":"finland","url":"https://vpn.invalid","token":"super-secret"}]}', encoding="utf-8")
            manager = PanelManager(path)
            with patch("src.bot.urlopen", return_value=Response()) as opened:
                result = manager.nettest("finland", "download", PANEL_TOKEN, test_id="mini-123", size=99_000_000)
            self.assertEqual(result[0], b"payload")
            self.assertIn("size=4000000", opened.call_args.args[0].full_url)

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

    def test_snapshot_marks_service_failure_as_down(self):
        payload = {"panel": "Sunny-Finland", "service": "failed", "summary": {"online": 5, "total": 5}}
        self.assertEqual(snapshot_health(payload), ("down", "🔴"))
        self.assertTrue(compact_snapshot(payload).startswith("🔴"))

    def test_snapshot_marks_zero_recent_handshakes_as_degraded(self):
        payload = {"panel": "Sunny-Finland", "service": "active", "summary": {"online": 0, "total": 63, "disabled": 0}}
        self.assertEqual(snapshot_health(payload), ("degraded", "⚠️"))
        self.assertIn("⚠️", compact_snapshot(payload))

    def test_format_bytes_is_human_readable(self):
        self.assertEqual(format_bytes(0), "0 B")
        self.assertEqual(format_bytes(1024 * 1024), "1.0 MiB")

    def test_telemetry_visuals_are_compact(self):
        self.assertEqual(len(sparkline([1, 2, 3, 4], width=12)), 4)
        self.assertEqual(sparkline([5, 5, 5]), "▁▁▁")
        self.assertEqual(usage_bar(50, 100, width=10), "█████░░░░░")

    def test_client_stats_card_contains_visual_traffic_and_connectivity(self):
        rendered = client_stats_card("Телефон <test>", "germany", {
            "online": True,
            "ipv4": "10.9.10.36",
            "latestHandshakeAt": "2026-07-19T12:00:00Z",
            "p2p_ports": [20045],
            "traffic_total": {"rx": 10 * 1024 * 1024, "tx": 2 * 1024 * 1024},
            "traffic_30d": {"rx": 5 * 1024 * 1024, "tx": 1 * 1024 * 1024},
        })
        self.assertIn("🟢 онлайн", rendered)
        self.assertIn("20045", rendered)
        self.assertIn("████", rendered)
        self.assertNotIn("<test>", rendered)
        self.assertNotIn('"traffic_total"', rendered)

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

    def test_nettest_ping_is_rendered_as_availability_card(self):
        rendered = format_panel_payload({"panel": "Sunny-Finland", "ok": True, "server_time": "2026-07-19T12:00:00Z"}, "nettest-ping")
        self.assertIn("Доступность API", rendered)
        self.assertIn("Sunny-Finland", rendered)
        self.assertNotIn('"server_time"', rendered)

    def test_packet_loss_sample_is_rendered_as_diagnostic_card(self):
        rendered = format_panel_payload({"panel": "Sunny-Germany", "duration_seconds": 10, "wan": {"drops_delta": 2, "drop_pct": 0.5, "errors_delta": 1}, "vpn": {"drops_delta": 0, "drop_pct": 0, "errors_delta": 0}, "qdisc": {"drop_delta": 1, "sent_delta": 100, "drop_pct": 0.99}, "tcp": {"retrans_delta": 3, "timeout_delta": 1}, "ipv6": {"no_route_delta": 0, "no_route_pct": 0}}, "drops-sample")
        self.assertIn("Длительность", rendered)
        self.assertIn("WAN", rendered)
        self.assertIn("retrans", rendered)
        self.assertNotIn('"wan"', rendered)

    def test_infrastructure_cards_do_not_dump_nested_json(self):
        rendered = format_panel_payload({"panel": "Sunny-Finland", "providers": {"maxmind": {"status": "ready"}}, "databases": {"city": {"status": "fresh"}}}, "geoip-status")
        self.assertIn("maxmind", rendered)
        self.assertNotIn('"providers"', rendered)

    def test_menu_contains_admin_actions(self):
        callback_data = {item["callback_data"] for row in menu_keyboard(True) for item in row}
        admin_data = {item["callback_data"] for row in admin_keyboard() for item in row}
        self.assertTrue({"server:status:all", "server:health:all", "server:clients:all", "admin:users:0"}.issubset(callback_data))
        self.assertTrue({"server:geoip-status:all", "server:web-cert:all", "server:drops-sample:all"}.issubset(admin_data))
        maintenance_data = {item["callback_data"] for row in maintenance_keyboard() for item in row}
        self.assertTrue({"admin:dns-restart:finland", "admin:reboot:all", "admin:geoip-update:all"}.issubset(maintenance_data))

    def test_menu_contains_user_controls(self):
        callback_data = {item["callback_data"] for row in menu_keyboard(False) for item in row}
        self.assertTrue({"user:clients", "user:traffic", "user:favorites", "user:nettest", "user:help", "user:add", "menu:profile"}.issubset(callback_data))

    def test_client_callbacks_fit_telegram_limit(self):
        buttons = client_keyboard("germany", "a" * 48, "0123456789", admin=False)
        callbacks = [button["callback_data"] for row in buttons for button in row]
        self.assertTrue(all(len(value.encode()) <= 64 for value in callbacks))
        self.assertTrue(all(len(button["callback_data"].encode()) <= 64 for row in clients_keyboard([("germany", "a" * 48, "0123456789")]) for button in row))
        self.assertTrue({"client:artifact:0123456789:qr:1", "client:artifact:0123456789:config:1", "client:stats:0123456789:1", "client:favorite-add:0123456789:1"}.issubset({button["callback_data"] for row in buttons for button in row}))
        self.assertNotIn("client:remove:0123456789:1", {button["callback_data"] for row in buttons for button in row})
        self.assertTrue({"client:toggle:0123456789:1", "client:p2p-toggle:0123456789:1", "client:remove:0123456789:1"}.issubset({button["callback_data"] for row in client_keyboard("germany", "client", "0123456789", admin=True) for button in row}))
        self.assertIn("client:path-check:0123456789:1", {button["callback_data"] for row in client_keyboard("germany", "client", "0123456789", admin=True) for button in row})
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
        keyboard = reply_keyboard(False)
        self.assertEqual(sum(len(row) for row in keyboard), 5)
        self.assertIn("🏠 Меню", keyboard[0])
        self.assertNotIn("⚙️ Админка", [item for row in keyboard for item in row])
        admin_keyboard_rows = reply_keyboard(True)
        self.assertEqual(sum(len(row) for row in admin_keyboard_rows), 6)
        self.assertIn("⚙️ Админка", admin_keyboard_rows[-1])

    def test_result_navigation_has_refresh_action(self):
        keyboard = result_navigation_keyboard("health", "all", False)
        self.assertEqual(keyboard[0][0]["callback_data"], "server:health:all")
        self.assertIn("menu:home", {item["callback_data"] for row in keyboard for item in row})
        admin_keyboard_rows = result_navigation_keyboard("health", "all", True)
        self.assertIn("menu:admin", {item["callback_data"] for row in admin_keyboard_rows for item in row})

    def test_maintenance_exposes_scoped_dns_mode_controls(self):
        callbacks = {item["callback_data"] for row in maintenance_keyboard() for item in row}
        self.assertIn("admin:dns-mode:finland", callbacks)
        self.assertIn("admin:dns-mode:germany", callbacks)

    def test_maintenance_exposes_geoip_operations(self):
        callbacks = {item["callback_data"] for row in maintenance_keyboard() for item in row}
        self.assertIn("admin:geoip-providers-test:all", callbacks)
        self.assertIn("admin:geoip-auto-update:all", callbacks)

    def test_maintenance_routes_ndp_to_scoped_menu(self):
        callbacks = {item["callback_data"] for row in maintenance_keyboard() for item in row}
        self.assertEqual(callbacks.intersection({"admin:ndp:finland", "admin:ndp:germany"}), {"admin:ndp:finland", "admin:ndp:germany"})

    def test_maintenance_exposes_profile_rotation_per_server(self):
        callbacks = {item["callback_data"] for row in maintenance_keyboard() for item in row}
        self.assertIn("admin:rotate-profile:finland", callbacks)
        self.assertIn("admin:rotate-profile:germany", callbacks)

    def test_timestamp_card_is_human_readable(self):
        self.assertEqual(format_timestamp(0), "1970-01-01 00:00 UTC")

    def test_scoped_token_client_names_are_validated(self):
        payload = {"clients": [{"name": "phone"}, {"config_name": "laptop"}, {"name": "phone"}]}
        self.assertEqual(panel_client_names(payload), ["phone", "laptop"])
        self.assertIsNone(panel_client_names({"error": "unavailable"}))

    def test_token_scope_lookup_does_not_expose_unknown_tokens(self):
        payload = {"users": [{"hash": "abc", "clients": ["phone", "laptop"]}]}
        self.assertEqual(token_client_scope(payload, "abc"), ["phone", "laptop"])
        self.assertIsNone(token_client_scope(payload, "missing"))

    def test_provisioning_choices_are_per_server_and_callback_safe(self):
        keyboard = provisioning_keyboard(151599744, None)
        callbacks = {button["callback_data"] for row in keyboard for button in row}
        self.assertIn("admin:provision-create:151599744:finland", callbacks)
        self.assertIn("admin:provision-input:151599744:germany", callbacks)
        self.assertTrue(all(len(value.encode()) <= 64 for value in callbacks))
        self.assertIn("не настроен", provisioning_text(151599744, None))

    def test_adguard_admin_controls_are_present(self):
        callbacks = {button["callback_data"] for row in maintenance_keyboard() for button in row}
        self.assertIn("admin:adguard-filter-refresh:finland", callbacks)
        self.assertIn("admin:adguard-filter-add:germany", callbacks)
        self.assertIn("admin:adguard-filter-remove:finland", callbacks)

    def test_token_selection_uses_unambiguous_hash_prefix_and_no_secret(self):
        records = panel_token_records({"users": [{"hash": "a" * 64, "name": "Telegram user", "clients": ["phone"]}, {"hash": "b" * 64, "name": "Other", "clients": []}]})
        self.assertEqual(token_record_by_prefix(records, "a" * 12)["name"], "Telegram user")
        self.assertIsNone(token_record_by_prefix(records, ""))
        self.assertTrue(valid_bearer_candidate("x" * 32))
        self.assertFalse(valid_bearer_candidate("short"))
        self.assertFalse(valid_bearer_candidate("x" * 10 + " " + "x" * 10))
        self.assertNotIn("bearer-токен", provisioning_text(151599744, None).lower())

    def test_client_app_guide_is_rendered_as_links_and_cards(self):
        text = format_panel_payload({"panel": "Finland", "groups": [{"name": "Android", "subtitle": "Выбор", "clients": [{"name": "WG Tunnel", "status": "Recommended", "platforms": "Android", "setupMethod": "QR", "links": [{"label": "Сайт", "url": "https://example.test/app"}]}]}]}, "help-clients")
        self.assertIn("WG Tunnel", text)
        self.assertIn("Сайт", text)
        self.assertIn('href="https://example.test/app"', text)
        self.assertNotIn('"groups"', text)

    def test_client_app_catalog_merges_duplicate_panel_groups(self):
        payload = {"groups": [{"name": "Linux Desktop", "clients": [{"name": "AmneziaVPN", "platforms": "Linux x64", "links": [{"label": "Official", "url": "https://amnezia.org/downloads"}]}]}]}
        merged = merge_client_help_payloads([payload, payload])
        self.assertEqual(len(merged["groups"]), 1)
        self.assertEqual(len(merged["groups"][0]["clients"]), 1)

    def test_uri_keyboard_uses_copy_text_button(self):
        keyboard = uri_keyboard("vpn://example", "ref123")
        self.assertEqual(keyboard[0][0]["copy_text"]["text"], "vpn://example")
        self.assertEqual(keyboard[1][0]["callback_data"], "client:open:ref123")

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
