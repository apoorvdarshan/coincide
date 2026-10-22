"""Exercise the built immutable helper without GUI, providers, network or user data.

Invoked after build/sign verification, using the embedded binary and selected
absolute Python. Invalid descriptors must exit before any peer runs.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def verify(executable, python):
    executable, python = Path(executable).resolve(strict=True), Path(python).resolve(strict=True)
    if (executable.name != "CoincideOfflineCLI" or not os.access(executable, os.X_OK)
            or not python.is_absolute() or not os.access(python, os.X_OK)):
        raise ValueError("The verifier requires the built embedded helper and selected Python.")
    with tempfile.TemporaryDirectory(prefix="coincide-ui-testing-launcher-") as scratch:
        root = Path(scratch).resolve(strict=True)
        root.chmod(0o700)
        checkout = root / "Checkout"
        checkout.mkdir(mode=0o700)
        state, wire = root / "state.json", root / "wire.jsonl"
        state.write_text(json.dumps(dict(cwd=str(checkout), generation=1)))
        state.chmod(0o600)
        descriptor = root / "codex.offline.json"
        original = dict(version=1, tool="codex", root=str(root), python=str(python),
                        peer="codex_models_ui.py", state=str(state), wire=str(wire))
        environment = {"COINCIDE_UI_TESTING": "1", "COINCIDE_UI_TEST_ROOT": str(root),
                       "COINCIDE_UI_PYTHON_PATH": str(python)}
        private_bin = root / "private-bin"
        private_bin.mkdir(mode=0o700)
        command = private_bin / "codex"
        command.symlink_to(executable)
        payload = json.dumps(dict(id="launcher-contract", method="initialize", params={})) + "\n"

        def write(value):
            descriptor.write_text(json.dumps(value))
            descriptor.chmod(0o600)

        def call(expected, arguments=("app-server", "--stdio"), env=None):
            result = subprocess.run([str(command), *arguments], input=payload, text=True, cwd=checkout,
                env=environment if env is None else env, capture_output=True, timeout=5)
            if result.returncode != expected:
                raise AssertionError(f"Offline helper exit {result.returncode}, expected {expected}: {result.stderr[:512]}")
            return result

        write(original)
        output = call(0)
        reply = json.loads(output.stdout.splitlines()[0])
        assert reply["id"] == "launcher-contract"
        assert reply["result"]["userAgent"] == "coincide/0.163.0 (macos; fixture)"
        assert command.is_symlink() and command.resolve() == executable
        # Python realpath and Foundation deliberately use different spellings
        # for this same macOS temporary directory. Both exact bindings work;
        # mixing their descriptor/environment spellings must still fail.
        if str(root).startswith("/private/var/"):
            alias = str(root)[len("/private"):]
            assert os.path.samefile(alias, root)
            alias_value = dict(original, root=alias, state=alias + "/state.json", wire=alias + "/wire.jsonl")
            alias_environment = dict(environment, COINCIDE_UI_TEST_ROOT=alias)
            write(alias_value)
            alias_reply = call(0, env=alias_environment)
            assert json.loads(alias_reply.stdout.splitlines()[0])["id"] == "launcher-contract"
            call(78)  # Same directory identity does not waive exact binding.
            write(original)
            call(78, env=alias_environment)
        write(original)
        before = wire.read_bytes()
        invalid = [dict(original, version=2), dict(original, tool="gh"), dict(original, peer="../codex_models_ui.py"),
            dict(original, peer="arbitrary.py"), dict(original, python="/usr/bin/false"),
            dict(original, state=str(checkout / "nested.json")), dict(original, wire=str(root / "../foreign.json")),
            dict(original, unknown=True)]
        for value in invalid:
            write(value)
            call(78)
        write(original)
        descriptor.chmod(0o644)
        call(78)
        descriptor.chmod(0o600)
        state.chmod(0o644)
        call(78)
        state.chmod(0o600)
        original_state = state.read_bytes()
        state.unlink()
        state_target = root / "state-target.json"
        state_target.write_bytes(original_state)
        state_target.chmod(0o600)
        state.symlink_to(state_target)
        call(78)
        state.unlink()
        state.write_bytes(original_state)
        state.chmod(0o600)
        root.chmod(0o755)
        call(78)
        root.chmod(0o700)
        descriptor.unlink()
        linked = root / "descriptor-target.json"
        linked.write_text(json.dumps(original))
        linked.chmod(0o600)
        descriptor.symlink_to(linked)
        call(78)
        descriptor.unlink()
        write(original)
        call(78, arguments=("auth", "token"))
        call(78, env={key: value for key, value in environment.items() if key != "COINCIDE_UI_TESTING"})
        call(78, env=dict(environment, COINCIDE_UI_TEST_ROOT=str(root) + "/../" + root.name))
        with tempfile.TemporaryDirectory(prefix="coincide-ui-testing-foreign-") as other:
            call(78, env=dict(environment, COINCIDE_UI_TEST_ROOT=str(Path(other).resolve())))
        linked_root = root.parent / ("coincide-ui-testing-linked-" + root.name)
        linked_root.symlink_to(root, target_is_directory=True)
        try:
            call(78, env=dict(environment, COINCIDE_UI_TEST_ROOT=str(linked_root)))
        finally:
            linked_root.unlink()
        assert wire.read_bytes() == before, "Rejected input must never reach the peer."

        # Same immutable image serves gh. No provider/system fallback is used.
        github_state = dict(cwd=str(checkout), repository="fixture/native-pr", published=dict(main="a" * 40), creates=0)
        state.write_text(json.dumps(github_state))
        state.chmod(0o600)
        github = dict(original, tool="gh", peer="github_pr_ui.py")
        (root / "gh.offline.json").write_text(json.dumps(github))
        (root / "gh.offline.json").chmod(0o600)
        command = private_bin / "gh"
        command.symlink_to(executable)
        output = call(0, arguments=("--version",))
        assert output.stdout.strip() == "gh version 2.0.0 (offline Coincide UI fixture)"
        assert json.loads(state.read_text())["creates"] == 0
        assert state.stat().st_mode & 0o777 == 0o600
    print("Offline CLI launcher: initialize, GitHub metadata and descriptor rejection checks passed without GUI.")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: verify_offline_launcher.py <embedded-helper> <absolute-python>")
    verify(*sys.argv[1:])
