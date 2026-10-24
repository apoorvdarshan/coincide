"""Local CLI recovery contracts; no app, HTTP server, or provider is launched."""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch


CLIENT = Path(__file__).resolve().parents[2] / "script" / "coincide"


def client_module():
    loader = importlib.machinery.SourceFileLoader("coincide_error_cli", str(CLIENT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class LocalControlErrorTests(unittest.TestCase):
    def test_documented_configuration_error_reaches_cli_without_resubmitting(self):
        module = client_module()
        message = "The configuration changed while saving. Read configuration again before retrying."
        requests = []

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self, limit):
                return json.dumps({"result": {"isError": True, "structuredContent": {
                    "error": {"code": "configuration_changed", "message": message}
                }}}).encode()

        class Opener:
            def open(self, request, timeout):
                requests.append(json.loads(request.data))
                return Response()

        command = [str(CLIENT), "configuration-set", "00000000-0000-0000-0000-000000000001", "model", "fixture-model"]
        with patch.object(module, "connection", return_value={"endpoint": "http://127.0.0.1:1234/mcp", "authorization": "Bearer synthetic-test-only"}):
            with patch.object(module.urllib.request, "build_opener", return_value=Opener()), patch.object(module.sys, "argv", command):
                with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(ValueError) as failure:
                    module.main()
        self.assertEqual(str(failure.exception), message)
        self.assertEqual([request["method"] for request in requests], ["initialize", "notifications/initialized", "tools/call"])
        self.assertEqual(requests[-1]["params"]["arguments"]["value"], "fixture-model")

    def test_only_action_matched_error_codes_expose_the_safe_contract(self):
        module = client_module()
        for command, codes in {
            "configuration": ["configuration_review_required", "configuration_invalid", "configuration_changed"],
            "configuration-set": ["configuration_review_required", "configuration_invalid", "configuration_changed"],
            "integrations": ["integration_refresh_required"],
            "integration-import": ["integration_refresh_required"],
            "integration-remove": ["integration_refresh_required"],
            "integration-use": ["integration_refresh_required"],
        }.items():
            for code in codes:
                with self.subTest(command=command, code=code):
                    result = {"structuredContent": {"error": {"code": code, "message": "Review the current source before retrying."}}}
                    self.assertEqual(module.local_action_error(command, result), "Review the current source before retrying.")
                    self.assertEqual(module.local_action_error("status", result), "Coincide could not complete the command.")

    def test_unknown_malformed_and_terminal_control_messages_remain_generic(self):
        module = client_module()
        canary = "SYNTHETIC_PRIVATE_ERROR_CANARY"
        payloads = [None, [], {}, {"error": canary}, {"error": {"code": {}, "message": canary}},
                    {"error": {"code": "provider_error", "message": canary}},
                    {"error": {"code": "integration_refresh_required", "message": canary}}]
        payloads.extend({"error": {"code": "configuration_invalid", "message": message}}
                        for message in [None, [], "", "x" * 4097, "line\n" + canary, "\x1b[31m" + canary, "\x7f" + canary])
        for payload in payloads:
            with self.subTest(payload=payload):
                self.assertEqual(module.local_action_error("configuration-set", {
                    "content": [{"type": "text", "text": canary}], "structuredContent": payload,
                }), "Coincide could not complete the command.")


if __name__ == "__main__":
    unittest.main()
