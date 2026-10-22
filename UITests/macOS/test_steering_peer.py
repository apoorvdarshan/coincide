"""Pure protocol checks for the hosted peer; no Coincide app or GUI is launched."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid


class NativeSteeringPeerTests(unittest.TestCase):
    def fixture(self, root):
        checkout = root / "Steering checkout"
        checkout.mkdir()
        state, wire = root / "steering.json", root / "wire.jsonl"
        state.write_text(json.dumps(dict(cwd=str(checkout), firstPrompt="Hold this first turn",
            steeringPrompt="Literal café λ 👩🏽‍💻 '$(not executed)' \\n stays text")), encoding="utf-8")
        return checkout, state, wire

    def exchange(self, state, wire, calls):
        process = subprocess.run([sys.executable, str(Path(__file__).with_name("codex_steering_ui.py")), str(state), str(wire)],
            input="".join(json.dumps(dict(id=index + 1, method=method, params=params), ensure_ascii=False) + "\n"
                for index, (method, params) in enumerate(calls)), text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=5)
        return [json.loads(line) for line in process.stdout.splitlines()]

    def start(self, checkout, state, wire):
        return self.exchange(state, wire, [("initialize", {}), ("thread/start", dict(cwd=str(checkout), historyMode="paginated")),
            ("turn/start", dict(cwd=str(checkout), threadId="ui-native-steering-thread",
                input=[dict(type="text", text="Hold this first turn")]))])

    def test_original_turn_is_held_until_exact_unicode_steer_and_never_replayed(self):
        with tempfile.TemporaryDirectory(prefix="coincide-ui-testing-steering-") as scratch:
            checkout, state, wire = self.fixture(Path(scratch).resolve())
            first = self.start(checkout, state, wire)
            self.assertEqual(len([row for row in first if row.get("method") == "turn/started"]), 1)
            self.assertFalse(any(row.get("method") == "turn/completed" for row in first))
            literal = json.loads(state.read_text())["steeringPrompt"]
            message = "user-" + str(uuid.uuid4()).upper()
            params = dict(threadId="ui-native-steering-thread", expectedTurnId="ui-native-steering-turn",
                clientUserMessageId=message, input=[dict(type="text", text=literal, text_elements=[])])
            sent = self.exchange(state, wire, [("turn/steer", params)])
            self.assertEqual(sent[0]["result"], dict(turnId="ui-native-steering-turn"))
            self.assertEqual(len([row for row in sent if row.get("method") == "turn/completed"]), 1)
            self.assertEqual(json.loads(state.read_text())["clientMessageID"], message)
            restart = self.exchange(state, wire, [("initialize", {}),
                ("thread/read", dict(threadId="ui-native-steering-thread")), ("turn/steer", params)])
            self.assertEqual([turn["id"] for turn in restart[1]["result"]["thread"]["turns"]], ["ui-native-steering-turn"])
            self.assertEqual(restart[1]["result"]["thread"]["turns"][0]["status"], "completed")
            self.assertEqual(restart[2]["error"]["code"], -32602)
            receipts = [json.loads(line) for line in wire.read_text().splitlines()]
            self.assertEqual([row["params"]["input"][0]["text"] for row in receipts if row["method"] == "turn/steer"], [literal, literal])

    def test_stale_turn_configuration_override_and_extra_starts_fail_without_completion(self):
        with tempfile.TemporaryDirectory(prefix="coincide-ui-testing-steering-") as scratch:
            checkout, state, wire = self.fixture(Path(scratch).resolve())
            self.start(checkout, state, wire)
            params = dict(threadId="ui-native-steering-thread", expectedTurnId="ui-native-steering-turn",
                clientUserMessageId="user-" + str(uuid.uuid4()), input=[dict(type="text", text=json.loads(state.read_text())["steeringPrompt"], text_elements=[])])
            invalid = [dict(params, expectedTurnId="a-different-turn"), dict(params, model="must-not-override"),
                dict(params, clientUserMessageId=""), dict(params, clientUserMessageId="control\nidentity"),
                dict(params, clientUserMessageId="x" * 4097),
                dict(params, input=[dict(type="text", text="changed literal input", text_elements=[])])]
            calls = [("turn/steer", value) for value in invalid] + [
                ("thread/start", dict(cwd=str(checkout), historyMode="paginated")),
                ("turn/start", dict(cwd=str(checkout), threadId="ui-native-steering-thread", input=[dict(type="text", text="Hold this first turn")]))]
            rejected = self.exchange(state, wire, calls)
            self.assertTrue(all(row["error"]["code"] == -32602 for row in rejected))
            self.assertFalse(json.loads(state.read_text()).get("steered", False))
            self.assertNotIn("clientMessageID", json.loads(state.read_text()))

    def test_private_root_and_real_checkout_are_required(self):
        with tempfile.TemporaryDirectory(prefix="coincide-ui-testing-steering-") as scratch:
            root = Path(scratch).resolve()
            checkout, state, wire = self.fixture(root)
            value = json.loads(state.read_text()); value["cwd"] = str(root.parent)
            state.write_text(json.dumps(value))
            for path in [state, root / "linked-state.json"]:
                if path != state:
                    path.symlink_to(state)
                process = subprocess.run([sys.executable, str(Path(__file__).with_name("codex_steering_ui.py")), str(path), str(wire)],
                    input=json.dumps(dict(id=1, method="initialize")) + "\n", text=True,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
                self.assertNotEqual(process.returncode, 0)
                self.assertEqual(process.stdout, "")
            self.assertFalse(wire.exists())


if __name__ == "__main__":
    unittest.main()
