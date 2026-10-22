"""Offline GitHub CLI for the disposable native PR workflow.

Only the exact local fixture checkout/repository/commands are accepted. No
network, Git, browser, credential or subprocess operation exists in this peer.
A create is persisted before an intentionally lost reply; later processes can
only discover that same result. flock and atomic replacement serialize readers.
"""
import fcntl
import json
import os
from pathlib import Path
import sys
import uuid


def main():
    state_path, wire_path = map(Path, sys.argv[1:3])
    arguments = sys.argv[3:]
    root = state_path.parent.resolve(strict=True)
    if (not root.name.startswith("coincide-ui-testing-") or not state_path.is_absolute()
            or not wire_path.is_absolute() or wire_path.parent.resolve(strict=True) != root
            or state_path.is_symlink() or wire_path.is_symlink() or len(arguments) > 24):
        raise ValueError("The offline GitHub peer requires its private UI test root.")
    if any(len(value.encode()) > 1_048_576 or "\0" in value for value in arguments):
        raise ValueError("The fixture command exceeds its bounds.")
    lock_path = root / "github-peer.lock"
    if lock_path.is_symlink():
        raise ValueError("The fixture lock must not be a symlink.")
    with lock_path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = json.loads(state_path.read_text())
        checkout = Path(state["cwd"])
        if (not checkout.is_absolute() or checkout.is_symlink()
                or checkout.resolve(strict=True).parent != root):
            raise ValueError("The command must run in its exact private fixture checkout.")
        current = Path.cwd().resolve(strict=True)
        if current != checkout.resolve(strict=True):
            managed = root / "Worktrees"
            pointer = current / ".git"
            if (state.get("checkoutFixture") is not True or managed.is_symlink()
                    or current.parent != managed or str(uuid.UUID(current.name)).upper() != current.name.upper()
                    or pointer.is_symlink() or not pointer.is_file()):
                raise ValueError("Only this fixture's explicitly enabled managed checkout may read GitHub metadata.")
        if state.get("repository") != "fixture/native-pr":
            raise ValueError("The offline GitHub repository identity is fixed.")
        try:
            output, status, body = execute(arguments, state)
        except (ValueError, KeyError, TypeError, UnicodeError):
            with wire_path.open("a") as wire:
                wire.write(json.dumps(dict(arguments=arguments, body=None, cwd=str(Path.cwd().resolve()), rejected=True)) + "\n")
            raise
        receipt = dict(arguments=arguments, body=body, cwd=str(Path.cwd().resolve()))
        with wire_path.open("a") as wire:
            wire.write(json.dumps(receipt) + "\n")
        replacement = root / "github-peer.next.json"
        if replacement.is_symlink():
            raise ValueError("The fixture state must remain a regular private file.")
        replacement.write_text(json.dumps(state))
        os.replace(replacement, state_path)
        if output is not None:
            print(output if isinstance(output, str) else json.dumps(output), flush=True)
        if status:
            print("Offline fixture deliberately lost the create reply.", file=sys.stderr)
        return status


def options(arguments, allowed):
    result = {}
    for argument in arguments:
        key, separator, value = argument.partition("=")
        if key == "--draft" and not separator:
            value = True
        elif not separator:
            raise ValueError("The fixture only accepts structured flag values.")
        if key not in allowed or key in result:
            raise ValueError("Unknown or repeated offline GitHub option.")
        result[key] = value
    return result


def execute(arguments, state):
    if arguments == ["--version"]:
        return "gh version 2.0.0 (offline Coincide UI fixture)", 0, None
    if arguments and arguments[0] == "api":
        if len(arguments) != 4 or arguments[1:3] != ["--hostname=github.com", "--method=GET"]:
            raise ValueError("Only the exact read-only fixture API is supported.")
        endpoint = arguments[3]
        if endpoint == "repos/fixture/native-pr":
            return dict(full_name="fixture/native-pr", default_branch="main"), 0, None
        if endpoint == "repos/fixture/native-pr/branches?per_page=100":
            return [dict(name="main"), dict(name="topic")], 0, None
        prefix = "repos/fixture/native-pr/git/ref/heads/"
        if endpoint.startswith(prefix) and endpoint[len(prefix):] in state["published"]:
            branch = endpoint[len(prefix):]
            return dict(ref="refs/heads/" + branch, object=dict(type="commit", sha=state["published"][branch])), 0, None
        raise ValueError("The fixture refuses every unrecognized API endpoint.")
    if arguments[:2] == ["pr", "list"]:
        flags = options(arguments[2:], {"--repo", "--state", "--head", "--limit", "--json", "--search", "--author", "--base"})
        require_repository(flags)
        if flags.get("--state") not in ("open", "closed", "merged", "all") or not 1 <= int(flags.get("--limit", "0")) <= 100 or not flags.get("--json"):
            raise ValueError("The fixture list request is invalid.")
        pr = state.get("pullRequest")
        rows = []
        if pr and flags["--state"] in ("open", "all") and flags.get("--head", "topic") == "topic":
            query = flags.get("--search", "").lower()
            if query in (pr["title"] + " " + pr["body"]).lower():
                rows = [pr]
        return rows, 0, None
    if arguments[:2] == ["pr", "view"]:
        if len(arguments) < 3 or arguments[2] != "42":
            raise ValueError("Only the exact fixture PR can be viewed.")
        flags = options(arguments[3:], {"--repo", "--json"}); require_repository(flags)
        if not flags.get("--json") or state.get("pullRequest") is None:
            raise ValueError("The fixture PR has not been created.")
        return state["pullRequest"], 0, None
    if arguments[:2] == ["pr", "create"]:
        flags = options(arguments[2:], {"--repo", "--head", "--base", "--title", "--body-file", "--draft"}); require_repository(flags)
        if (flags.get("--head") != "topic" or flags.get("--base") != "main" or flags.get("--body-file") != "-"
                or not isinstance(flags.get("--title"), str) or not flags["--title"].strip()):
            raise ValueError("The fixture refuses an unreviewed create request.")
        if state.get("pullRequest") is not None or state.get("creates", 0) != 0:
            raise ValueError("The offline fixture refuses duplicate creation.")
        body = sys.stdin.buffer.read(1_048_577)
        if len(body) > 1_048_576:
            raise ValueError("The create body exceeds the fixture bound.")
        body = body.decode("utf-8")
        state["creates"] = 1
        state["pullRequest"] = dict(number=42, title=flags["--title"], body=body,
            url="https://github.com/fixture/native-pr/pull/42", state="OPEN", isDraft=flags.get("--draft", False),
            headRefName="topic", baseRefName="main", headRefOid=state["published"]["topic"], baseRefOid=state["published"]["main"],
            headRepository=dict(name="native-pr", nameWithOwner="fixture/native-pr"), headRepositoryOwner=dict(login="fixture"),
            isCrossRepository=False, author=dict(login="fixture"), updatedAt="2026-10-22T00:00:00Z", createdAt="2026-10-22T00:00:00Z",
            reviewDecision="REVIEW_REQUIRED", statusCheckRollup=[dict(name="Offline native fixture check", status="COMPLETED", conclusion="SUCCESS")],
            additions=1, deletions=1, changedFiles=1, reviewRequests=[], labels=[dict(name="native-ui-fixture")])
        return (None, 1, body) if state.get("loseCreateReply", True) else (state["pullRequest"]["url"], 0, body)
    raise ValueError("This offline peer never delegates to the real GitHub CLI.")


def require_repository(flags):
    if flags.get("--repo") != "github.com/fixture/native-pr":
        raise ValueError("The fixture refuses another host or repository.")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, KeyError, TypeError, UnicodeError, json.JSONDecodeError):
        print("The offline GitHub fixture rejected this command.", file=sys.stderr)
        raise SystemExit(2)
