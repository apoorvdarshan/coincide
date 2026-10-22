"""No GUI, GitHub access, credentials or external writes are used by these tests."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid


class NativeGitHubPeerTests(unittest.TestCase):
    def fixture(self, root):
        checkout = root / "Checkout"
        checkout.mkdir()
        state, wire = root / "github.json", root / "github-wire.jsonl"
        state.write_text(json.dumps(dict(cwd=str(checkout), repository="fixture/native-pr",
            published=dict(main="a" * 40, topic="b" * 40), creates=0, loseCreateReply=True)))
        return checkout, state, wire

    def call(self, checkout, state, wire, arguments, body=""):
        return subprocess.run([sys.executable, "-I", "-S", str(Path(__file__).with_name("github_pr_ui.py")), str(state), str(wire)] + arguments,
            cwd=checkout, input=body, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)

    def test_create_is_persisted_before_lost_reply_and_reconciliation_never_repeats_it(self):
        with tempfile.TemporaryDirectory(prefix="coincide-ui-testing-github-") as scratch:
            checkout, state, wire = self.fixture(Path(scratch).resolve())
            arguments = ["pr", "create", "--repo=github.com/fixture/native-pr", "--head=topic", "--base=main",
                "--title=Literal $(never executed) title", "--body-file=-", "--draft"]
            body = "Keep Markdown\n\n- Spaces and `literal` characters\n"
            result = self.call(checkout, state, wire, arguments, body)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, "")
            saved = json.loads(state.read_text())
            self.assertEqual(state.stat().st_mode & 0o777, 0o600)
            self.assertEqual(saved["creates"], 1)
            self.assertEqual(saved["pullRequest"]["body"], body)
            self.assertTrue(saved["pullRequest"]["isDraft"])
            rows = self.call(checkout, state, wire, ["pr", "list", "--repo=github.com/fixture/native-pr", "--head=topic", "--state=open", "--limit=100", "--json=number"])
            self.assertEqual(rows.returncode, 0)
            self.assertEqual(json.loads(rows.stdout)[0]["number"], 42)
            detail = self.call(checkout, state, wire, ["pr", "view", "42", "--repo=github.com/fixture/native-pr", "--json=body"])
            self.assertEqual(json.loads(detail.stdout)["body"], body)
            receipts = [json.loads(line) for line in wire.read_text().splitlines()]
            self.assertEqual(len([row for row in receipts if row["arguments"][:2] == ["pr", "create"]]), 1)
            duplicate = self.call(checkout, state, wire, arguments, body)
            self.assertEqual(duplicate.returncode, 2)
            self.assertEqual(json.loads(state.read_text())["creates"], 1)
            receipts = [json.loads(line) for line in wire.read_text().splitlines()]
            self.assertEqual(len([row for row in receipts if row["arguments"][:2] == ["pr", "create"]]), 2)
            self.assertTrue(receipts[-1]["rejected"])
            self.assertEqual(receipts[0]["body"], body)

    def test_api_requires_the_exact_repository_host_and_published_commit(self):
        with tempfile.TemporaryDirectory(prefix="coincide-ui-testing-github-") as scratch:
            checkout, state, wire = self.fixture(Path(scratch).resolve())
            result = self.call(checkout, state, wire, ["api", "--hostname=github.com", "--method=GET", "repos/fixture/native-pr/git/ref/heads/topic"])
            self.assertEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stdout)["object"]["sha"], "b" * 40)
            for arguments in [["auth", "token"], ["api", "--hostname=elsewhere.invalid", "--method=GET", "repos/fixture/native-pr"],
                    ["pr", "list", "--repo=github.com/other/repo", "--state=open", "--limit=30", "--json=number"],
                    ["pr", "list", "--repo=github.com/fixture/native-pr", "--state=open", "--limit=30", "--json=number", "--web=true"]]:
                with self.subTest(arguments=arguments):
                    self.assertEqual(self.call(checkout, state, wire, arguments).returncode, 2)
            self.assertEqual(json.loads(state.read_text())["creates"], 0)

    def test_peer_refuses_a_foreign_cwd_or_symlink_state(self):
        with tempfile.TemporaryDirectory(prefix="coincide-ui-testing-github-") as scratch:
            root = Path(scratch).resolve()
            checkout, state, wire = self.fixture(root)
            self.assertEqual(self.call(root, state, wire, ["--version"]).returncode, 2)
            linked = root / "linked.json"
            linked.symlink_to(state)
            self.assertEqual(self.call(checkout, linked, wire, ["--version"]).returncode, 2)
            self.assertEqual(json.loads(state.read_text())["creates"], 0)

    def test_seeded_checkout_metadata_is_read_only_and_confined_to_owned_managed_worktrees(self):
        with tempfile.TemporaryDirectory(prefix="coincide-ui-testing-github-") as scratch:
            root = Path(scratch).resolve()
            checkout, state, wire = self.fixture(root)
            value = json.loads(state.read_text())
            value["pullRequest"] = dict(number=42, title="Seeded native checkout", body="Preserve this published review")
            value["checkoutFixture"] = True
            state.write_text(json.dumps(value))
            managed = root / "Worktrees" / str(uuid.uuid4()).upper()
            managed.mkdir(parents=True)
            (managed / ".git").write_text("gitdir: owned fixture proof\n")
            listed = self.call(managed, state, wire, ["pr", "list", "--repo=github.com/fixture/native-pr", "--state=open", "--limit=50", "--json=number"])
            self.assertEqual(listed.returncode, 0)
            self.assertEqual(json.loads(listed.stdout)[0]["number"], 42)
            detail = self.call(managed, state, wire, ["pr", "view", "42", "--repo=github.com/fixture/native-pr", "--json=body"])
            self.assertEqual(json.loads(detail.stdout)["body"], value["pullRequest"]["body"])
            self.assertEqual(json.loads(state.read_text())["creates"], 0)
            self.assertTrue(all(row["arguments"][:2] != ["pr", "create"] for row in map(json.loads, wire.read_text().splitlines())))
            value["checkoutFixture"] = False
            state.write_text(json.dumps(value))
            self.assertEqual(self.call(managed, state, wire, ["--version"]).returncode, 2)
            value["checkoutFixture"] = True
            state.write_text(json.dumps(value))
            (managed / ".git").unlink()
            (managed / ".git").symlink_to(state)
            self.assertEqual(self.call(managed, state, wire, ["--version"]).returncode, 2)


if __name__ == "__main__":
    unittest.main()
