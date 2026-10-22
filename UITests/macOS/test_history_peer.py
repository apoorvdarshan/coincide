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

    def test_restore_fixture_edits_only_an_explicit_private_managed_worktree(self):
        peer = Path(__file__).with_name("codex_history_ui.py")
        with tempfile.TemporaryDirectory(prefix="coincide-ui-testing-peer-") as scratch:
            root = Path(scratch).resolve()
            directory = root / "Worktrees" / "Synthetic checkout"
            directory.mkdir(parents=True)
            document = directory / "README.md"
            document.write_text("Before synthetic provider run\n")
            state, wire = root / "history.json", root / "wire.jsonl"
            state.write_text(json.dumps(dict(cwd=str(directory), threads={}, nextTurn=0, restoreFixture=True)))
            frames = [dict(id=1, method="thread/start", params=dict(historyMode="paginated")),
                      dict(id=2, method="turn/start", params=dict(threadId="ui-native-source"))]
            process = subprocess.run([sys.executable, str(peer), str(state), str(wire)],
                input="".join(json.dumps(frame) + "\n" for frame in frames), text=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=5)
            self.assertIn("turn/completed", process.stdout)
            self.assertEqual(document.read_text(), "After synthetic provider run\n")
            saved = json.loads(state.read_text())
            self.assertEqual(saved["threads"]["ui-native-source"]["turns"], ["ui-turn-1"])
            self.assertEqual(saved["nextTurn"], 1)

    def test_restore_fixture_refuses_unmanaged_and_symlink_destinations(self):
        peer = Path(__file__).with_name("codex_history_ui.py")
        with tempfile.TemporaryDirectory(prefix="coincide-ui-testing-peer-") as scratch:
            root = Path(scratch).resolve()
            source = root / "Source"
            source.mkdir(); (source / "README.md").write_text("Keep source\n")
            managed = root / "Worktrees" / "Checkout"
            managed.mkdir(parents=True)
            (managed / "README.md").symlink_to(source / "README.md")
            state, wire = root / "history.json", root / "wire.jsonl"
            for directory in (source, managed):
                with self.subTest(directory=directory.name):
                    state.write_text(json.dumps(dict(cwd=str(directory), threads={"ui-native-source": dict(turns=[])}, nextTurn=0, restoreFixture=True)))
                    process = subprocess.run([sys.executable, str(peer), str(state), str(wire)],
                        input=json.dumps(dict(id=1, method="turn/start", params=dict(threadId="ui-native-source"))) + "\n", text=True,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=5)
                    self.assertIn('"error"', process.stdout)
                    self.assertEqual((source / "README.md").read_text(), "Keep source\n")
                    self.assertEqual(json.loads(state.read_text())["nextTurn"], 0)


if __name__ == "__main__":
    unittest.main()
