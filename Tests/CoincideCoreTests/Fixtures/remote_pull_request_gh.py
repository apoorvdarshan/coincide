"""Private gh executable: bounded metadata and one synthetic create, no network."""
import json
import os
from pathlib import Path
import signal
import sqlite3
import sys
import time

root = Path(sys.argv[1]).resolve(strict=True)
assert root.name.startswith("coincide-remote-pr-") and os.stat(root).st_mode & 0o077 == 0
assert Path(os.environ["HOME"]).resolve(strict=True) == root / "home"
assert Path(os.environ["GH_CONFIG_DIR"]).resolve(strict=True) == root / "gh-home"
assert all(name not in os.environ for name in ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_REPO", "GH_DEBUG"))
assert os.environ["GH_HOST"] == "github.com" and os.environ["GH_PROMPT_DISABLED"] == "1"
assert os.environ["GH_BROWSER"] == "/usr/bin/false" and os.environ["GH_EDITOR"] == "/usr/bin/false"
state_path = root / "gh-state.json"
state = json.loads(state_path.read_text())
args = sys.argv[2:]


def record(kind, **fields):
    data = (json.dumps({"kind": kind, "pid": os.getpid(), **fields}) + "\n").encode()
    fd = os.open(root / "gh-wire.jsonl", os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        assert os.write(fd, data) == len(data)
    finally:
        os.close(fd)


def option(name):
    prefix = "--" + name + "="
    return next((item[len(prefix):] for item in args if item.startswith(prefix)), None)


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)
    raise SystemExit(0)


def save():
    temporary = root / (".gh-state-" + str(os.getpid()))
    fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        data = json.dumps(state).encode()
        assert os.write(fd, data) == len(data)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(temporary, state_path)


def row():
    return {"number": 42, "title": state.get("title", "Private remote pull request"),
            "url": "https://github.com/upstream/project/pull/42", "state": "OPEN", "isDraft": state.get("draft", False),
            "headRefName": "feature/topic", "baseRefName": state.get("baseBranch", "main"),
            "headRefOid": state["head"], "baseRefOid": state["base"],
            "headRepository": {"nameWithOwner": "fork/project"}, "headRepositoryOwner": {"login": "fork"},
            "isCrossRepository": True, "author": {"login": "private-fixture"},
            "updatedAt": "2026-10-23T01:02:03Z", "createdAt": "2026-10-22T01:02:03Z",
            "reviewDecision": "REVIEW_REQUIRED", "body": state.get("body", "Private remote PR description"),
            "additions": 1, "deletions": 0, "changedFiles": 1, "reviewRequests": [{"login": "fixture-reviewer"}],
            "labels": [{"name": "fixture"}], "statusCheckRollup": [{"name": "Private Build", "status": "COMPLETED",
            "conclusion": "SUCCESS", "detailsUrl": "https://github.com/upstream/project/actions/runs/1"}]}


record("call", method=" ".join(args[:2]))
if args and args[0] == "api":
    endpoint = args[-1]
    assert "--hostname=github.com" in args and "--method=GET" in args
    if endpoint == "repos/upstream/project":
        emit({"full_name": "upstream/project", "default_branch": "main"})
    if endpoint == "repos/upstream/project/branches?per_page=100":
        emit([{"name": "main"}, {"name": "develop"}])
    if endpoint == "repos/fork/project/git/ref/heads/feature/topic":
        emit({"ref": "refs/heads/feature/topic", "object": {"type": "commit", "sha": state["head"]}})
    if endpoint in ("repos/upstream/project/git/ref/heads/main", "repos/upstream/project/git/ref/heads/develop"):
        emit({"ref": "refs/heads/" + endpoint.rsplit("/", 1)[1], "object": {"type": "commit", "sha": state["base"]}})
    raise AssertionError("Unknown private GitHub metadata endpoint")
assert option("repo") == "github.com/upstream/project"
if args[:2] == ["pr", "list"]:
    assert option("state") in ("open", "closed", "merged", "all")
    emit([row()] if state.get("existing", False) else [])
if args[:2] == ["pr", "view"]:
    assert args[2] in ("42", "feature/topic")
    emit(row())
if args[:2] == ["pr", "create"]:
    # The outer remote UUID and native outbox must already be durable before the
    # sole external write. No test-only shortcut can fabricate that evidence.
    with sqlite3.connect((root / "data/workspace.sqlite").as_uri() + "?mode=ro", uri=True) as db:
        snapshot = json.loads(db.execute("SELECT payload FROM workspace WHERE id=1").fetchone()[0])
        operation = next(item for item in snapshot.get("pullRequestCreations", []) if item["review"]["id"].lower() == state["reviewID"].lower())
        effect = db.execute("SELECT command_id,status FROM workspace_effects WHERE id=?", (operation["effectID"],)).fetchone()
        receipt = db.execute("SELECT payload FROM workspace_receipts WHERE lower(id)=lower(?)", (state["commandID"],)).fetchone()
        assert operation["phase"] == "dispatching" and effect is not None and effect[1] == "running"
        assert effect[0].lower() == state["commandID"].lower() and receipt is not None
        assert json.loads(receipt[0])["commandID"].lower() == state["commandID"].lower()
    body = sys.stdin.read(1_048_577)
    assert len(body.encode()) <= 1_048_576
    state["title"] = option("title");state["body"] = body;state["draft"] = "--draft" in args;state["baseBranch"] = option("base")
    state["creates"] = state.get("creates", 0) + 1
    if state.get("createOutcome") != "lost-before":
        state["existing"] = True
    save()
    record("create", durableOriginalReceipt=True, commandID=state["commandID"], reviewID=state["reviewID"])
    if state.get("holdCreate", False):
        deadline = time.monotonic() + 20
        while not (root / "release-create").exists() and time.monotonic() < deadline:
            time.sleep(.005)
        assert (root / "release-create").exists()
    if state.get("createOutcome") in ("lost-before", "lost-after"):
        sys.stderr.write("PRIVATE_UNTRUSTED_GH_DIAGNOSTIC\n")
        raise SystemExit(1)
    print("https://github.com/upstream/project/pull/42", flush=True)
    raise SystemExit(0)
raise AssertionError("Unsupported private gh command")
