import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).with_name("pi_history_ui.py")
SPEC = importlib.util.spec_from_file_location("pi_history_ui", SOURCE)
PEER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PEER)


class PiHistoryUIPeerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="coincide-ui-testing-pi-unit-")
        self.root = Path(self.temporary.name).resolve(); self.root.chmod(0o700)
        self.checkout = self.root / "Checkout"; self.checkout.mkdir(mode=0o700)
        self.environment = {"COINCIDE_UI_TESTING": "1", "COINCIDE_UI_TEST_ROOT": str(self.root)}
        for key, name in [("HOME", "private-pi-home"), ("PI_CODING_AGENT_DIR", "private-pi-agent"),
                          ("PI_CODING_AGENT_SESSION_DIR", "private-pi-sessions")]:
            path = self.root / name; path.mkdir(mode=0o700); self.environment[key] = str(path)
        self.state, self.wire = self.root / "state.json", self.root / "wire.jsonl"
        self.state.write_text(json.dumps(dict(cwd=str(self.checkout), historyMode="normal", actions={
            "alpha 工作": dict(mode="normal", label="ALPHA"), "beta مرحباً": dict(mode="normal", label="BETA"),
            "lost input": dict(mode="before-write-disconnect", label="LOST"), "new input": dict(mode="normal", label="NEW")})))
        self.state.chmod(0o600)
        self.prior_cwd = Path.cwd(); os.chdir(self.checkout)
        self.patched = patch.dict(os.environ, self.environment, clear=True); self.patched.start()
        self.output = io.StringIO()
        with contextlib.redirect_stdout(self.output):
            self.peer = PEER.Peer(str(self.state), str(self.wire), ["--mode", "rpc"])

    def tearDown(self):
        self.patched.stop(); os.chdir(self.prior_cwd); self.temporary.cleanup()

    def call(self, kind, **fields):
        with contextlib.redirect_stdout(self.output):
            return self.peer.handle(dict(type=kind, id="request-" + kind, **fields))

    def rows(self, path):
        return [json.loads(line) for line in path.read_text().splitlines()]

    def seed(self):
        self.call("prompt", message="alpha 工作"); self.call("prompt", message="beta مرحباً")
        return self.peer.file, self.peer.file.read_bytes(), list(self.peer.entries)

    def test_idle_metadata_is_bounded_and_never_creates_native_history(self):
        self.call("get_state"); self.call("get_entries"); self.call("get_available_models")
        self.assertEqual(list((self.root / "private-pi-sessions").iterdir()), [])
        replies = [json.loads(line) for line in self.output.getvalue().splitlines()]
        self.assertEqual([row["command"] for row in replies], ["get_state", "get_entries", "get_available_models"])
        self.assertEqual(replies[1]["data"], dict(entries=[], leafId=None))
        self.assertNotIn("import subprocess", SOURCE.read_text())
        self.assertNotIn("import socket", SOURCE.read_text())
        self.assertNotIn("import urllib", SOURCE.read_text())

    def test_exclusive_native_branch_keeps_ids_and_source_bytes_then_lost_reply_stays_unconfirmed(self):
        source, before, entries = self.seed()
        self.peer.settings["historyMode"] = "publish-and-disconnect"
        self.output.truncate(0); self.output.seek(0)
        self.assertFalse(self.call("fork", entryId=entries[2]["id"]))
        candidate = self.peer.file
        self.assertNotEqual(candidate, source); self.assertTrue(candidate.is_file())
        copied = self.rows(candidate)
        self.assertEqual(copied[0]["parentSession"], str(source))
        self.assertNotEqual(copied[0]["id"], self.rows(source)[0]["id"])
        self.assertEqual(copied[1:], entries[:2]); self.assertEqual(source.read_bytes(), before)
        self.assertEqual(self.output.getvalue(), "", "Lost result must not claim a successful fork ACK.")
        wire = self.rows(self.wire)
        self.assertEqual(len([row for row in wire if row.get("type") == "fork"]), 1)
        self.assertEqual(len([row for row in wire if row.get("kind") == "fork-result"]), 1)

    def test_offered_control_answer_and_cancel_preserve_exact_original_without_publishing(self):
        source, before, entries = self.seed()
        self.peer.settings["historyMode"] = "controls"
        self.call("fork", entryId=entries[2]["id"])
        with self.assertRaises(ValueError):
            self.call("extension_ui_response", value="Unsolicited option")
        with contextlib.redirect_stdout(self.output):
            self.peer.handle(dict(type="extension_ui_response", id="pi-gui-select", value="Keep inherited context"))
        self.assertEqual(self.peer.pending[1], "confirm")
        with contextlib.redirect_stdout(self.output):
            self.peer.handle(dict(type="extension_ui_response", id="pi-gui-confirm", confirmed=False))
        self.assertIsNone(self.peer.pending)
        self.assertEqual(source.read_bytes(), before)
        self.assertEqual(len(list((self.root / "private-pi-sessions").iterdir())), 1)
        self.assertFalse(any(row.get("kind") == "fork-result" for row in self.rows(self.wire)))

    def test_empty_branch_is_not_a_file_and_reopen_identity_changes_without_replaying_lost_input(self):
        source, before, entries = self.seed()
        self.call("fork", entryId=entries[0]["id"])
        selected = self.peer.file; selected_id = self.peer.header["id"]
        self.assertFalse(selected.exists()); self.assertEqual(self.peer.entries, [])
        self.assertFalse(self.call("prompt", message="lost input")); self.assertFalse(selected.exists())
        self.peer.load(selected)
        self.assertNotEqual(self.peer.header["id"], selected_id)
        self.call("prompt", message="new input")
        persisted = self.rows(selected)
        self.assertEqual(len(persisted), 3)
        self.assertEqual(persisted[1]["message"]["content"][0]["text"], "new input")
        prompts = [row["message"] for row in self.rows(self.wire) if row.get("type") == "prompt"]
        self.assertEqual(prompts, ["alpha 工作", "beta مرحباً", "lost input", "new input"])
        self.assertEqual(source.read_bytes(), before)

    def test_foreign_files_symlinks_unknown_commands_and_unsafe_arguments_are_refused(self):
        with self.assertRaises(ValueError): self.peer.load(self.checkout / "foreign.jsonl")
        target = self.root / "private-pi-sessions" / "linked.jsonl"
        target.symlink_to(self.state)
        with self.assertRaises(ValueError): self.peer.load(target)
        with self.assertRaises(ValueError): self.call("auth")
        with self.assertRaises(ValueError): PEER.Peer(str(self.state), str(self.wire), ["--mode", "rpc", "--unsafe"])
        self.assertEqual(list((self.root / "private-pi-sessions").iterdir()), [target])


if __name__ == "__main__":
    unittest.main()
