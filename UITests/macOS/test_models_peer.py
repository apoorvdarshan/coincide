"""Model fixture checks never launch the application, GUI, or a real provider."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class NativeModelsPeerTests(unittest.TestCase):
    def exchange(self, state, wire, calls):
        frames = [dict(id=index + 1, method=method, params=params) for index, (method, params) in enumerate(calls)]
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("codex_models_ui.py")), str(state), str(wire)],
            input="".join(json.dumps(frame) + "\n" for frame in frames), text=True, capture_output=True, check=True, timeout=5)
        return [json.loads(line) for line in result.stdout.splitlines()]

    def test_dynamic_catalog_and_cwd_defaults_remain_distinct_across_fresh_processes(self):
        with tempfile.TemporaryDirectory(prefix="coincide-ui-testing-models-") as scratch:
            root = Path(scratch).resolve(); checkout = root / "Checkout"; checkout.mkdir()
            state, wire = root / "models.json", root / "wire.jsonl"
            state.write_text(json.dumps(dict(cwd=str(checkout), generation=1)))
            rows = self.exchange(state, wire, [("initialize", {}), ("model/list", dict(limit=100, includeHidden=False)),
                ("config/read", dict(cwd=str(checkout), includeLayers=False))])
            self.assertEqual(rows[1]["result"]["data"][0]["model"], "gpt-6-astra")
            self.assertTrue(rows[1]["result"]["data"][0]["isDefault"])
            self.assertEqual(rows[2]["result"]["config"]["model"], "future-cwd-model")
            self.assertEqual(rows[2]["result"]["config"]["model_reasoning_effort"], "deep")
            self.assertIn("experimental-effort", [value["reasoningEffort"] for value in rows[1]["result"]["data"][1]["supportedReasoningEfforts"]])
            state.write_text(json.dumps(dict(cwd=str(checkout), generation=2)))
            refreshed = self.exchange(state, wire, [("model/list", dict(limit=100, includeHidden=False))])[0]["result"]["data"][1]
            self.assertEqual(refreshed["model"], "future-native-model")
            self.assertEqual(refreshed["defaultReasoningEffort"], "deep")
            self.assertEqual([value["reasoningEffort"] for value in refreshed["supportedReasoningEfforts"]], ["light", "deep"])

    def test_input_mutations_foreign_checkout_and_unreviewed_catalog_requests_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix="coincide-ui-testing-models-") as scratch:
            root = Path(scratch).resolve(); checkout = root / "Checkout"; checkout.mkdir()
            state, wire = root / "models.json", root / "wire.jsonl"
            state.write_text(json.dumps(dict(cwd=str(checkout), generation=1)))
            rows = self.exchange(state, wire, [("turn/start", {}), ("turn/steer", {}), ("thread/start", {}), ("config/value/write", {}),
                ("config/read", dict(cwd=str(root), includeLayers=False)), ("model/list", dict(limit=100, includeHidden=True))])
            self.assertTrue(all(row["error"]["code"] == -32602 for row in rows))
            self.assertEqual(json.loads(state.read_text()), dict(cwd=str(checkout), generation=1))
            linked = root / "linked.json"; linked.symlink_to(state)
            process = subprocess.run([sys.executable, str(Path(__file__).with_name("codex_models_ui.py")), str(linked), str(wire)],
                input=json.dumps(dict(id=1, method="initialize")) + "\n", text=True, capture_output=True, timeout=5)
            self.assertNotEqual(process.returncode, 0); self.assertEqual(process.stdout, "")


if __name__ == "__main__":
    unittest.main()
