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
        result = subprocess.run([sys.executable, "-I", "-S", str(Path(__file__).with_name("codex_models_ui.py")), str(state), str(wire)],
            input="".join(json.dumps(frame) + "\n" for frame in frames), text=True, capture_output=True, check=True, timeout=5)
        return [json.loads(line) for line in result.stdout.splitlines()]

    def test_explicit_skills_fixture_preserves_native_rows_and_fresh_reload_without_mutations(self):
        with tempfile.TemporaryDirectory(prefix="coincide-ui-testing-skills-") as scratch:
            root = Path(scratch).resolve(); checkout = root / "Checkout"; checkout.mkdir()
            state, wire = root / "models.json", root / "wire.jsonl"
            initial = dict(cwd=str(checkout), generation=1, skillsUI=True)
            state.write_text(json.dumps(initial))
            response = self.exchange(state, wire, [("skills/list", dict(cwds=[str(checkout)], forceReload=False))])[0]["result"]
            entry = response["data"][0]
            self.assertEqual(entry["cwd"], str(checkout))
            self.assertEqual([row["name"] for row in entry["skills"]], ["review-changes", "ship-check", "disabled-skill", "7k"])
            self.assertFalse(entry["skills"][2]["enabled"])
            self.assertEqual(len(entry["errors"]), 1)
            self.assertEqual(json.loads(state.read_text()), initial)
            state.write_text(json.dumps(dict(initial, generation=2)))
            updated = self.exchange(state, wire, [("skills/list", dict(cwds=[str(checkout)], forceReload=True))])[0]["result"]
            self.assertIn("fresh-check", [row["name"] for row in updated["data"][0]["skills"]])
            self.assertEqual([row["params"]["forceReload"] for row in map(json.loads, wire.read_text().splitlines())], [False, True])

    def test_skills_require_opt_in_exact_cwd_and_boolean_reload_and_never_accept_input(self):
        with tempfile.TemporaryDirectory(prefix="coincide-ui-testing-skills-") as scratch:
            root = Path(scratch).resolve(); checkout = root / "Checkout"; checkout.mkdir()
            state, wire = root / "models.json", root / "wire.jsonl"
            state.write_text(json.dumps(dict(cwd=str(checkout), generation=1)))
            params = dict(cwds=[str(checkout)], forceReload=False)
            self.assertIn("error", self.exchange(state, wire, [("skills/list", params)])[0])
            initial = dict(cwd=str(checkout), generation=1, skillsUI=True)
            state.write_text(json.dumps(initial))
            calls = [("skills/list", dict(cwds=[str(root)], forceReload=False)),
                ("skills/list", dict(cwds=[str(checkout)], forceReload=0)),
                ("skills/list", dict(cwds=[str(checkout)], forceReload=False, extra=True)),
                ("skills/list", dict(cwds=[str(checkout)])), ("turn/start", {}),
                ("turn/steer", {}), ("thread/start", {}), ("config/value/write", {})]
            self.assertTrue(all("error" in row for row in self.exchange(state, wire, calls)))
            self.assertEqual(json.loads(state.read_text()), initial)

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
            process = subprocess.run([sys.executable, "-I", "-S", str(Path(__file__).with_name("codex_models_ui.py")), str(linked), str(wire)],
                input=json.dumps(dict(id=1, method="initialize")) + "\n", text=True, capture_output=True, timeout=5)
            self.assertNotEqual(process.returncode, 0); self.assertEqual(process.stdout, "")

    def test_account_and_usage_reads_are_synthetic_read_only_and_independent_of_process_cwd(self):
        with tempfile.TemporaryDirectory(prefix="coincide-ui-testing-models-") as scratch:
            root = Path(scratch).resolve(); checkout = root / "Checkout"; checkout.mkdir()
            state, wire = root / "models.json", root / "wire.jsonl"
            original = dict(cwd=str(checkout), generation=2)
            state.write_text(json.dumps(original))
            rows = self.exchange(state, wire, [("account/read", dict(refreshToken=False)),
                ("account/rateLimits/read", {}), ("account/read", dict(refreshToken=False))])
            account, usage = rows[0]["result"], rows[1]["result"]
            self.assertEqual(rows[2]["result"], account)
            self.assertEqual(account["account"], dict(type="chatgpt", email="native-ui@example.invalid", planType="Offline Hosted Plus"))
            self.assertTrue(account["requiresOpenaiAuth"])
            self.assertEqual(account["workspaceRouting"]["chatgptAccountId"], usage["accountId"])
            self.assertEqual(usage["rateLimits"]["primary"]["usedPercent"], 25)
            self.assertEqual(usage["rateLimits"]["secondary"]["usedPercent"], 40)
            self.assertEqual(usage["rateLimits"]["primary"]["windowDurationMins"], 300)
            self.assertEqual(usage["rateLimits"]["credits"]["balance"], "12")
            self.assertTrue(usage["ordinaryUsageAllowed"])
            self.assertEqual(json.loads(state.read_text()), original)
            self.assertEqual([json.loads(line)["method"] for line in wire.read_text().splitlines()],
                ["account/read", "account/rateLimits/read", "account/read"])

    def test_account_credentials_mutations_and_non_readonly_probe_shapes_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix="coincide-ui-testing-models-") as scratch:
            root = Path(scratch).resolve(); checkout = root / "Checkout"; checkout.mkdir()
            state, wire = root / "models.json", root / "wire.jsonl"
            original = dict(cwd=str(checkout), generation=1)
            state.write_text(json.dumps(original))
            calls = [(method, {}) for method in ["account/login/start", "account/login/cancel", "account/logout",
                "account/credits/reset", "config/value/write", "turn/start", "turn/steer", "thread/start"]]
            calls += [("account/read", dict(refreshToken=True)), ("account/read", {}),
                ("account/read", dict(refreshToken=0)), ("account/read", dict(refreshToken=False, extra=True)),
                ("account/rateLimits/read", dict(refresh=True)), ("account/rateLimits/read", [])]
            rows = self.exchange(state, wire, calls)
            self.assertEqual(len(rows), len(calls))
            self.assertTrue(all(row["error"]["code"] == -32602 for row in rows))
            self.assertEqual(json.loads(state.read_text()), original)


if __name__ == "__main__":
    unittest.main()
