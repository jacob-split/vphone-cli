import unittest
from unittest.mock import patch

from vphone_mcp import server as module


class VPhoneMCPTests(unittest.TestCase):
    def test_expected_tools_are_registered(self):
        names = {tool.name for tool in module.server._tool_manager.list_tools()}
        expected = {
            "doctor", "vm_create", "vm_launch", "screenshot", "tap", "swipe",
            "app_launch", "install_ipa", "file_download", "clipboard_get",
            "location_set", "camera_start", "recording_start", "touchid_set",
            "battery_set", "guest_request", "keychain_list",
            "ui_status", "ui_bootstrap", "ui_tree", "ui_find", "ui_tap",
            "ui_type", "ui_wait", "ui_at_point",
        }
        self.assertTrue(expected.issubset(names))
        self.assertGreaterEqual(len(names), 58)


    def test_ui_selector_requires_semantic_identity(self):
        with self.assertRaises(ValueError):
            module._ui_selector()
        selector = module._ui_selector(label="Start recording", role="button", clickable=True)
        self.assertEqual(selector["label"], "Start recording")
        self.assertEqual(selector["role"], "button")
        self.assertTrue(selector["clickable"])

    def test_ui_type_taps_then_types_then_verifies(self):
        calls = []
        def fake_rpc(op, vm=None, **kwargs):
            calls.append((op, kwargs))
            if op == "accessibility_action":
                return {"ok": True, "node": {"semantic_id": "g1:c.0"}}
            if op == "type_text":
                return {"typed": True, "characters": 5, "method": "paste"}
            if op == "accessibility_find":
                return {"ok": True, "node": {"value": "hello"}}
            raise AssertionError(op)
        with patch.object(module, "_rpc", side_effect=fake_rpc), patch.object(module.time, "sleep"):
            result = module.ui_type("hello", label="Name", role="text_field")
        self.assertTrue(result["ok"])
        self.assertEqual([call[0] for call in calls], ["accessibility_action", "type_text", "accessibility_find"])
        self.assertEqual(calls[1][1]["method"], "paste")

    def test_ui_wait_returns_ambiguity_without_guessing(self):
        ambiguous = {"ok": False, "error": "ambiguous", "candidates": [{}, {}]}
        with patch.object(module, "_rpc", return_value=ambiguous):
            result = module.ui_wait(label="Save", role="button", timeout=1)
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "ambiguous")

    def test_keychain_values_are_redacted_by_default(self):
        fake = {"items": [{"account": "a", "value": "secret"}], "diagnostics": ["ok"]}
        with patch.object(module, "_rpc", return_value=fake):
            result = module.keychain_list()
        self.assertEqual(result["items"][0]["value"], "<redacted>")

    def test_keychain_values_require_explicit_opt_in(self):
        fake = {"items": [{"account": "a", "value": "secret"}], "diagnostics": []}
        with patch.object(module, "_rpc", return_value=fake):
            result = module.keychain_list(include_values=True)
        self.assertEqual(result["items"][0]["value"], "secret")


if __name__ == "__main__":
    unittest.main()
