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
        }
        self.assertTrue(expected.issubset(names))
        self.assertGreaterEqual(len(names), 50)

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
