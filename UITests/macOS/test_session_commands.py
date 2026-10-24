"""Exercise CLI session routing without opening the app or a provider process."""
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
    loader = importlib.machinery.SourceFileLoader("coincide_session_cli", str(CLIENT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class FakeResponse:
    def __init__(self, payload):
        self.payload = payload

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self, limit):
        return json.dumps(self.payload).encode()


class ProviderSessionCommandTests(unittest.TestCase):
    def test_stop_without_confirmation_never_reads_connection_or_sends_request(self):
        module = client_module()
        with patch.object(module, "connection") as connection, patch.object(module.urllib.request, "build_opener") as opener:
            with patch.object(module.sys, "argv", [str(CLIENT), "session-stop", "claude", "claude:background:session-1"]):
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as exit:
                    module.main()
        self.assertEqual(exit.exception.code, 2)
        connection.assert_not_called()
        opener.assert_not_called()

    def test_exact_provider_owned_id_and_explicit_stop_are_preserved(self):
        for name in ["session-details", "session-stop"]:
            with self.subTest(command=name):
                module = client_module()
                requests = []

                class Opener:
                    def open(self, request, timeout):
                        payload = json.loads(request.data)
                        requests.append(payload)
                        return FakeResponse({"result": {"structuredContent": {"ok": True}}})

                command = [str(CLIENT), name, "claude", "claude:background:exact-session-id"]
                if name == "session-stop":
                    command.append("--confirm")
                with patch.object(module, "connection", return_value={"endpoint": "http://127.0.0.1:1234/mcp", "authorization": "Bearer synthetic-test-only"}):
                    with patch.object(module.urllib.request, "build_opener", return_value=Opener()), patch.object(module.sys, "argv", command):
                        with contextlib.redirect_stdout(io.StringIO()):
                            module.main()
                calls = [request for request in requests if request["method"] == "tools/call"]
                self.assertEqual(len(calls), 1)
                self.assertEqual(calls[0]["params"]["name"], name)
                args = calls[0]["params"]["arguments"]
                self.assertEqual(args["provider"], "claude")
                self.assertEqual(args["session_id"], "claude:background:exact-session-id")
                self.assertEqual(args.get("confirm", False), name == "session-stop")


if __name__ == "__main__":
    unittest.main()
