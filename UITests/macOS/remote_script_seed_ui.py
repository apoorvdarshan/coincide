"""Seed one private native-helper workspace through its production JSON-RPC API.

No SSH, provider, account, model, shell startup or network request is made.
Only the staged signed helper is executable; all mutable data is test-owned.
"""
import json
import os
from pathlib import Path
import select
import stat
import subprocess
import sys
import time
import uuid


class InvalidFixture(Exception):
    pass


def private_directory(path, root=None):
    path = Path(path)
    if not path.is_absolute() or path != path.resolve(strict=True):
        raise InvalidFixture("physical-directory")
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise InvalidFixture("directory")
    if root is not None and not str(path).startswith(str(root) + "/"):
        raise InvalidFixture("scope")
    return path


def seed(root, helper, source, workspace, draft):
    root = private_directory(root)
    if not root.name.startswith("coincide-ui-testing-"):
        raise InvalidFixture("root")
    source = private_directory(source, root)
    workspace = private_directory(workspace, root)
    helper = Path(helper)
    if not helper.is_absolute() or helper != helper.resolve(strict=True) or helper.name != "CoincideEnvironment" or helper.parent.name != "Helpers" or helper.parent.parent.name != "Contents":
        raise InvalidFixture("helper")
    info = helper.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or not os.access(helper, os.X_OK):
        raise InvalidFixture("helper")
    data = root / "coincide-ui-testing-remote-script-host"
    home = root / "remote-script-home"
    codex_home = root / "remote-script-codex-home"
    claude_home = root / "remote-script-claude-home"
    github_home = home / "gh"
    for directory in (data, home, codex_home, claude_home, github_home):
        directory.mkdir(mode=0o700, exist_ok=True)
        private_directory(directory, root)
    git_configuration = root / "gitconfig"
    git_info = git_configuration.lstat()
    if not stat.S_ISREG(git_info.st_mode) or git_info.st_uid != os.getuid() or git_info.st_nlink != 1 or git_info.st_mode & 0o777 != 0o600:
        raise InvalidFixture("git-configuration")
    environment = dict(PATH=os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"), LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8",
                       GIT_CONFIG_GLOBAL=str(git_configuration), GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_SYSTEM="/dev/null",
                       GCM_INTERACTIVE="Never", GH_CONFIG_DIR=str(github_home))
    environment.update(HOME=str(home), SHELL="/bin/sh", CODEX_HOME=str(codex_home),
                       CLAUDE_CONFIG_DIR=str(claude_home), GIT_ALLOW_PROTOCOL="", GIT_TERMINAL_PROMPT="0")
    # A provider launch is a fixture error, never a fallback to installed tools.
    arguments = [str(helper), "--stdio", "--data-directory", str(data), "--label", "Private UI script environment",
                 "--codex-executable", "/usr/bin/false", "--codex-home", str(codex_home),
                 "--claude-executable", "/usr/bin/false", "--claude-configuration-directory", str(claude_home),
                 "--github-executable", "/usr/bin/false", "--github-configuration-directory", str(github_home)]
    process = subprocess.Popen(arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, env=environment, bufsize=0)
    buffer = bytearray()
    environment_id = None
    phase = "describe"

    def rpc(method, params):
        identity = str(uuid.uuid4()).upper()
        request = json.dumps(dict(jsonrpc="2.0", id=identity, method=method, params=params), separators=(",", ":")).encode() + b"\n"
        if len(request) > 1_048_576:
            raise InvalidFixture("request-bound")
        process.stdin.write(request)
        process.stdin.flush()
        deadline = time.monotonic() + 15
        while True:
            while b"\n" in buffer:
                line, _, rest = buffer.partition(b"\n")
                buffer[:] = rest
                value = json.loads(line)
                if value.get("id") != identity:
                    raise InvalidFixture("unexpected-response")
                if "error" in value:
                    raise InvalidFixture("rpc-" + str(value["error"].get("code", "unknown")))
                if "result" not in value:
                    raise InvalidFixture("missing-result")
                return value["result"]
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([process.stdout], [], [], remaining)[0]:
                raise InvalidFixture("response-deadline")
            chunk = os.read(process.stdout.fileno(), 65_536)
            if not chunk:
                raise InvalidFixture("host-exited")
            buffer.extend(chunk)
            if len(buffer) > 16 * 1_024 * 1_024:
                raise InvalidFixture("response-bound")

    def snapshot():
        return rpc("remoteEnvironment.snapshot", dict(environmentID=environment_id))["workspace"]

    def command(value):
        identity = str(uuid.uuid4()).upper()
        receipt = rpc("remoteEnvironment.command", dict(environmentID=environment_id, id=identity, command=value))["receipt"]
        if receipt.get("commandID") != identity or receipt.get("rejection") is not None:
            raise InvalidFixture("command-rejected")

    def configuration(thread):
        keys = ("provider", "workspacePath", "model", "reasoningEffort", "permission", "codexRuntimeConfiguration",
                "claudeRuntimeConfiguration", "acpAgent", "openCodeConfiguration", "piConfiguration", "museConfiguration",
                "antigravityConfiguration", "agentModeID", "agentConfigValues", "agentConfiguration")
        result = {key: thread[key] for key in keys if thread.get(key) is not None}
        if thread.get("providerThreadID") is not None:
            result["nativeThreadID"] = thread["providerThreadID"]
        return result

    try:
        descriptor = rpc("remoteEnvironment.describe", {})
        environment_id = descriptor["environmentID"]
        if not descriptor["capabilities"].get("supportsReviewedSettleScripts"):
            raise InvalidFixture("script-capability")
        project_id, thread_id = [str(uuid.uuid4()).upper() for _ in range(2)]
        phase = "register"
        command(dict(addProject=dict(id=project_id, path=str(source), title="Private Remote Script")))
        command(dict(createThread=dict(id=thread_id, projectID=project_id, provider="codex", title="Reviewed Remote Cleanup",
                                       model="", permission="supervised")))
        thread = next(row for row in snapshot()["threads"] if row["id"] == thread_id)
        target = dict(environmentID=environment_id, projectID=project_id, threadID=thread_id, configuration=configuration(thread))
        phase = "prepare-worktree"
        catalog = rpc("remoteEnvironment.worktree.catalog", dict(target=target))
        command(dict(prepareWorktree=dict(target=target, sourceRootID=catalog["sourceRootID"],
                                         selection=dict(reuse=dict(path=str(workspace))), submodules="none")))
        deadline = time.monotonic() + 20
        while True:
            thread = next(row for row in snapshot()["threads"] if row["id"] == thread_id)
            preparation = thread.get("workspacePreparation") or {}
            if preparation.get("phase") == "completed":
                break
            if preparation.get("phase") in ("failed", "cancelled", "interrupted"):
                raise InvalidFixture("worktree-terminal")
            if time.monotonic() >= deadline:
                raise InvalidFixture("worktree-deadline")
            time.sleep(0.025)
        phase = "draft"
        command(dict(editThread=dict(threadID=thread_id, edit=dict(draft=dict(_0=draft)), expectedConfiguration=configuration(thread))))
        final = next(row for row in snapshot()["threads"] if row["id"] == thread_id)
        if final.get("draft") != draft or final.get("activeRun") is not None or final.get("messages") or final.get("runHistory"):
            raise InvalidFixture("unsent-state")
        phase = "close"
        rpc("remoteEnvironment.close", dict(environmentID=environment_id))
        process.stdin.close()
        if process.wait(timeout=10) != 0:
            raise InvalidFixture("close-status")
        return dict(environmentID=environment_id, threadID=thread_id, projectID=project_id,
                    workspacePath=final["workspacePath"], hostPID=process.pid, hostExit=process.returncode)
    except BaseException:
        print("Private remote-script seed failed at phase=" + phase, file=sys.stderr)
        raise
    finally:
        if process.poll() is None:
            process.stdin.close()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


if __name__ == "__main__":
    try:
        if len(sys.argv) != 6:
            raise InvalidFixture("arguments")
        result = seed(*sys.argv[1:])
        print(json.dumps(result, sort_keys=True))
    except Exception:
        print("Private remote-script seed refused or could not complete its fixed native protocol workflow.", file=sys.stderr)
        sys.exit(1)
