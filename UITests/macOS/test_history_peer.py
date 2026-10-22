"""Offline protocol-fixture checks; these never launch Coincide or native GUI."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class NativeHistoryPeerTests(unittest.TestCase):
    def test_fresh_processes_retain_exact_fork_and_rewind_boundaries_without_replay(self):
        peer = Path(__file__).with_name("codex_history_ui.py")
        with tempfile.TemporaryDirectory(prefix="coincide-ui-testing-peer-") as scratch:
            root = Path(scratch).resolve()
            checkout = root / "Synthetic checkout"
            checkout.mkdir()
            state, wire = root / "history.json", root / "wire.jsonl"
            state.write_text(json.dumps(dict(cwd=str(checkout), threads={}, nextTurn=0)))

            def exchange(requests):
                frames = [dict(id=index + 1, method=method, params=params) for index, (method, params) in enumerate(requests)]
                process = subprocess.run([sys.executable, str(peer), str(state), str(wire)],
                    input="".join(json.dumps(frame) + "\n" for frame in frames), text=True,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=5)
                return [json.loads(line) for line in process.stdout.splitlines()]

            first = exchange([("initialize", {}), ("thread/start", {"historyMode": "paginated"})] +
                [("turn/start", {"threadId": "ui-native-source", "input": [{"type": "text", "text": "Prompt"}]})] * 3)
            self.assertEqual(len([frame for frame in first if frame.get("method") == "turn/completed"]), 3)
            fork = exchange([("thread/fork", {"threadId": "ui-native-source", "lastTurnId": "ui-turn-2"})])[0]
            self.assertEqual([item["id"] for item in fork["result"]["thread"]["turns"]], ["ui-turn-1", "ui-turn-2"])
            observed = exchange([("thread/turns/list", {"threadId": "ui-native-source"}),
                ("thread/turns/list", {"threadId": "ui-native-fork"}),
                ("thread/revert", {"threadId": "ui-native-source", "beforeTurnId": "ui-turn-2"})])
            self.assertEqual([item["id"] for item in observed[0]["result"]["data"]], ["ui-turn-3", "ui-turn-2", "ui-turn-1"])
            self.assertEqual([item["id"] for item in observed[1]["result"]["data"]], ["ui-turn-2", "ui-turn-1"])
            self.assertEqual([item["id"] for item in observed[2]["result"]["thread"]["turns"]], ["ui-turn-1"])
            again = exchange([("thread/fork", {"threadId": "ui-native-source", "lastTurnId": "ui-turn-1"}),
                ("thread/read", {"threadId": "ui-native-source"})])
            self.assertEqual(again[0]["error"]["code"], -32602)
            self.assertEqual([item["id"] for item in again[1]["result"]["thread"]["turns"]], ["ui-turn-1"])
            self.assertEqual(json.loads(state.read_text())["nextTurn"], 3)

    def test_peer_rejects_a_workspace_outside_its_private_test_root(self):
        peer = Path(__file__).with_name("codex_history_ui.py")
        with tempfile.TemporaryDirectory(prefix="coincide-ui-testing-peer-") as scratch:
            root = Path(scratch).resolve()
            state = root / "history.json"
            state.write_text(json.dumps(dict(cwd=str(root.parent), threads={}, nextTurn=0)))
            process = subprocess.run([sys.executable, str(peer), str(state), str(root / "wire.jsonl")],
                input=json.dumps(dict(id=1, method="initialize")) + "\n", text=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            self.assertNotEqual(process.returncode, 0)
            self.assertEqual(process.stdout, "")


if __name__ == "__main__":
    unittest.main()
