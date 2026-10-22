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
import uuid


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

        def call(expected, arguments=("app-server", "--stdio"), env=None, payload_override=None):
            result = subprocess.run([str(command), *arguments], input=payload if payload_override is None else payload_override, text=True, cwd=checkout,
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

        # Pi keeps the same immutable image and private descriptor, with only
        # version/idle-entry inspection here. No model input is generated.
        pi_home, pi_agent, pi_sessions = (root / value for value in ("private-pi-home", "private-pi-agent", "private-pi-sessions"))
        for path in (pi_home, pi_agent, pi_sessions):
            path.mkdir(mode=0o700)
        state.write_text(json.dumps(dict(cwd=str(checkout), historyMode="normal", actions={}))); state.chmod(0o600)
        pi_wire = root / "pi-wire.jsonl"
        pi = dict(original, tool="pi", peer="pi_history_ui.py", wire=str(pi_wire))
        pi_descriptor = root / "pi.offline.json"
        pi_descriptor.write_text(json.dumps(pi)); pi_descriptor.chmod(0o600)
        command = private_bin / "pi"; command.symlink_to(executable)
        pi_env = dict(environment, HOME=str(pi_home), PI_CODING_AGENT_DIR=str(pi_agent), PI_CODING_AGENT_SESSION_DIR=str(pi_sessions))
        assert call(0, arguments=("--version",), env=pi_env, payload_override="").stdout.strip() == "0.80.5"
        frames = [dict(type="get_state", id="pi-preflight-state"), dict(type="get_entries", id="pi-preflight-entries")]
        idle = call(0, arguments=("--mode", "rpc"), env=pi_env,
                    payload_override="".join(json.dumps(frame) + "\n" for frame in frames))
        replies = [json.loads(line) for line in idle.stdout.splitlines()]
        assert [frame["id"] for frame in replies] == [frame["id"] for frame in frames]
        assert all(frame["success"] for frame in replies) and replies[1]["data"] == dict(entries=[], leafId=None)
        assert not list(pi_sessions.iterdir()), "Version/metadata inspection cannot create a persisted native session."
        if str(root).startswith("/private/var/"):
            alias = str(root)[len("/private"):]
            pi_descriptor.write_text(json.dumps(dict(pi, root=alias, state=alias + "/state.json", wire=alias + "/pi-wire.jsonl"))); pi_descriptor.chmod(0o600)
            alias_env = dict(pi_env, COINCIDE_UI_TEST_ROOT=alias, PI_CODING_AGENT_DIR=alias + "/private-pi-agent",
                             PI_CODING_AGENT_SESSION_DIR=alias + "/private-pi-sessions")
            assert call(0, arguments=("--version",), env=alias_env, payload_override="").stdout.strip() == "0.80.5"
            pi_descriptor.write_text(json.dumps(pi)); pi_descriptor.chmod(0o600)
        pi_before = pi_wire.read_bytes()
        call(78, arguments=("--mode", "rpc", "--unsafe"), env=pi_env)
        call(78, arguments=("--mode", "rpc"), env=dict(pi_env, PI_CODING_AGENT_DIR=str(checkout)))
        pi_descriptor.write_text(json.dumps(dict(pi, peer="codex_models_ui.py"))); pi_descriptor.chmod(0o600)
        call(78, arguments=("--mode", "rpc"), env=pi_env)
        assert pi_wire.read_bytes() == pi_before

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

        # The same signed image recognizes only the literal native Claude
        # stream-json argv. It never invokes auth, a vendor CLI, or a user home.
        base = ["--print", "--input-format", "stream-json", "--output-format", "stream-json",
                "--verbose", "--include-partial-messages", "--permission-prompt-tool", "stdio",
                "--allow-dangerously-skip-permissions"]
        config, home = root / "private-claude-config", root / "private-claude-home"
        config.mkdir(mode=0o700); home.mkdir(mode=0o700)
        alpha, beta, probe = "Remember the native marker ALPHA.", "Remember the native marker BETA.", "Probe selected native context."
        state.write_text(json.dumps(dict(cwd=str(checkout), configurationDirectory=str(config), actions={
            alpha: dict(mode="normal", label="alpha"), beta: dict(mode="normal", label="beta"),
            probe: dict(mode="normal", label="probe")})))
        state.chmod(0o600)
        claude_wire = root / "claude-wire.jsonl"
        claude = dict(original, tool="claude", peer="claude_history_ui.py", wire=str(claude_wire))
        claude_descriptor = root / "claude.offline.json"
        claude_descriptor.write_text(json.dumps(claude)); claude_descriptor.chmod(0o600)
        command = private_bin / "claude"; command.symlink_to(executable)
        claude_env = dict(environment, HOME=str(home), CLAUDE_CONFIG_DIR=str(config),
                          CLAUDE_CODE_PROJECT_DIR_NAME="coincide-claude-ui")
        def control(method, **params):
            return dict(type="control_request", request_id="launcher-claude-" + method,
                        request=dict(subtype=method, **params))
        def encoded(frames):
            return "".join(json.dumps(frame) + "\n" for frame in frames)
        initialized = control("initialize", hooks=None)
        initialization = call(0, arguments=base, env=claude_env, payload_override=encoded([initialized]))
        first = json.loads(initialization.stdout.splitlines()[0])["response"]
        assert first["subtype"] == "success" and first["request_id"] == initialized["request_id"]
        assert first["response"]["models"][0]["value"] == "claude-ui-model"
        assert not list(config.rglob("*.jsonl")), "Initialize-only metadata cannot invent a native transcript."
        prefix = [initialized, control("set_permission_mode", mode="default"), control("set_model", model=None)]
        opening_alpha, opening_beta = str(uuid.uuid4()), str(uuid.uuid4())
        def user(ident, text):
            return dict(type="user", uuid=ident, parent_tool_use_id=None, message=dict(role="user", content=text))
        accepted = call(0, arguments=base, env=claude_env,
                        payload_override=encoded(prefix + [user(opening_alpha, alpha), user(opening_beta, beta)]))
        responses = [json.loads(line) for line in accepted.stdout.splitlines()]
        assistants = [frame for frame in responses if frame.get("type") == "assistant"]
        assert len(assistants) == 2 and all(frame["uuid"] != frame["message"]["id"] for frame in assistants)
        session = assistants[0]["session_id"]; cursor = assistants[0]["uuid"]
        transcript = config / "projects/coincide-claude-ui" / (session + ".jsonl")
        original_rows = [json.loads(line) for line in transcript.read_text().splitlines()]
        assert [row["uuid"] for row in original_rows if row["type"] == "user"] == [opening_alpha, opening_beta]
        assert original_rows[0]["parentUuid"] is None and original_rows[1]["parentUuid"] == opening_alpha
        opening_probe = str(uuid.uuid4())
        selected = call(0, arguments=base + ["--resume", session, "--resume-session-at=" + cursor], env=claude_env,
                        payload_override=encoded(prefix + [user(opening_probe, probe)]))
        selected_assistant = next(frame for frame in map(json.loads, selected.stdout.splitlines()) if frame.get("type") == "assistant")
        assert selected_assistant["message"]["content"][0]["text"] == "Claude GUI probe context ALPHA"
        selected_rows = [json.loads(line) for line in transcript.read_text().splitlines()]
        assert selected_rows[:4] == original_rows and selected_rows[4]["parentUuid"] == cursor
        assert selected_rows[4]["uuid"] == opening_probe and selected_rows[5]["parentUuid"] == opening_probe
        continued = call(0, arguments=base + ["--resume", session], env=claude_env,
                         payload_override=encoded(prefix + [user(str(uuid.uuid4()), probe)]))
        assert "Claude GUI probe context ALPHA BETA" not in continued.stdout
        assert "Claude GUI probe context ALPHA" in continued.stdout
        fresh_id = str(uuid.uuid4())
        call(0, arguments=base + ["--session-id", fresh_id], env=claude_env, payload_override=encoded([initialized]))
        assert not (transcript.parent / (fresh_id + ".jsonl")).exists()
        before_claude = claude_wire.read_bytes()
        for suffix in (["--resume", "not-a-native-uuid"], ["--session-id", fresh_id, "--resume", session],
                       ["--resume", session, "--resume-session-at=invalid"], ["--resume-session-at=" + cursor],
                       ["--resume", session, "--resume", session], ["--session-id", "../foreign"],
                       ["--resume", session, "--dangerously-skip-permissions"]):
            call(78, arguments=base + suffix, env=claude_env, payload_override=encoded([initialized]))
        call(78, arguments=base + ["--resume", session], env=dict(claude_env, CLAUDE_CONFIG_DIR=str(checkout)), payload_override=encoded([initialized]))
        call(78, arguments=base, env=dict(claude_env, HOME=str(checkout)), payload_override=encoded([initialized]))
        config.rename(root / "configuration-target")
        config.symlink_to(root / "configuration-target", target_is_directory=True)
        call(78, arguments=base, env=claude_env, payload_override=encoded([initialized]))
        config.unlink(); (root / "configuration-target").rename(config)
        assert claude_wire.read_bytes() == before_claude, "Rejected Claude argv/namespaces must not reach the peer."
        assert sorted(path.name for path in config.iterdir()) == ["projects"]
        assert not list(home.iterdir())
    print("Offline CLI launcher: Codex/GitHub/Claude envelopes, native selected chains and isolated descriptor/argv rejection checks passed without GUI.")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: verify_offline_launcher.py <embedded-helper> <absolute-python>")
    verify(*sys.argv[1:])
