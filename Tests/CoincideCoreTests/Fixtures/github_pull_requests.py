#!/usr/bin/python3
"""Task-private gh stand-in. It has no HTTP client and never invokes real gh."""
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

state_path = Path(os.environ["COINCIDE_GH_FIXTURE"])
args = sys.argv[1:]

if args == ["fixture-child"]:
    def child_stop(_signal, _frame):
        state_path.with_suffix(".child-stopped").write_text("owned child exited\n")
        sys.exit(0)
    signal.signal(signal.SIGTERM, child_stop)
    state_path.with_suffix(".child-started").write_text("owned child started\n")
    while True:
        time.sleep(0.01)

state = json.loads(state_path.read_text())
call = {"args": args, "stdin": None,
        "ambientRedirect": "GH_REPO" in os.environ,
        "debug": "GH_DEBUG" in os.environ,
        "gitRedirect": "GIT_DIR" in os.environ,
        "enterpriseToken": "GH_ENTERPRISE_TOKEN" in os.environ,
        "cloudToken": "GH_TOKEN" in os.environ}
state.setdefault("calls", []).append(call)

def save():
    state_path.write_text(json.dumps(state))

def emit(value):
    save()
    print(json.dumps(value))
    sys.exit(0)

def option(name):
    prefix = "--" + name + "="
    return next((value[len(prefix):] for value in args if value.startswith(prefix)), None)

mode = state.get("mode", "normal")
save()
if mode == "unauthenticated":
    sys.stderr.write("Authentication failed: https://synthetic-user:synthetic-secret@example.invalid/?token=synthetic-token\n")
    sys.exit(4)
if mode in ["http401", "http403", "http429"]:
    code = mode[len("http"):]
    sys.stderr.write("fixture request rejected (HTTP " + code + ") https://synthetic-user:synthetic-secret@example.invalid/?token=synthetic-token\n")
    sys.exit(1)
if mode == "malformed":
    print('{"incomplete":')
    sys.exit(0)
if mode == "overflow":
    sys.stdout.write("x" * (3 * 1024 * 1024))
    sys.stdout.flush()
    sys.exit(0)
if mode == "stalled":
    child = subprocess.Popen([sys.executable, __file__, "fixture-child"])
    def parent_stop(_signal, _frame):
        child.wait(timeout=3)
        state_path.with_suffix(".parent-stopped").write_text("owned parent exited\n")
        sys.exit(0)
    signal.signal(signal.SIGTERM, parent_stop)
    while not state_path.with_suffix(".child-started").exists():
        time.sleep(0.01)
    state_path.with_suffix(".entered").write_text("owned operation entered\n")
    while True:
        time.sleep(0.01)

def row(number=42, head_repository=None, title=None, base=None):
    base_repository = state["baseRepository"]
    head_repository = head_repository or state["headRepository"]
    return {"number": number, "title": title or "Fixture pull request", "url": "https://github.com/" + base_repository + "/pull/" + str(number),
            "state": "OPEN", "isDraft": state.get("isDraft", False), "headRefName": state["branch"],
            "baseRefName": base or state.get("selectedBase", "main"), "headRefOid": state["headCommit"], "baseRefOid": state["baseCommit"],
            "headRepository": None if state.get("deletedFork") else {"nameWithOwner": head_repository},
            "headRepositoryOwner": None if state.get("deletedFork") else {"login": head_repository.split("/")[0]},
            "isCrossRepository": base_repository != head_repository,
            "author": {"login": "dependabot[bot]"}, "updatedAt": "2026-10-21T01:02:03Z", "createdAt": "2026-10-20T01:02:03Z",
            "reviewDecision": "REVIEW_REQUIRED", "body": state.get("createdBody", "Fixture description\n\nSecond paragraph"),
            "additions": 2, "deletions": 1, "changedFiles": 1,
            "reviewRequests": [{"login": "reviewer"}], "labels": [{"name": "enhancement"}],
            "statusCheckRollup": [{"name": "Build", "status": "COMPLETED", "conclusion": "SUCCESS",
                                    "detailsUrl": "https://github.com/" + base_repository + "/actions/runs/1?check_suite_focus=true#step:1"}]}

if args and args[0] == "api":
    endpoint = args[-1]
    base = "repos/" + state["baseRepository"]
    if endpoint == base:
        emit({"full_name": state["baseRepository"], "default_branch": "main"})
    if endpoint == base + "/branches?per_page=100":
        emit([{"name": "main"}, {"name": "develop"}])
    marker = "/git/ref/heads/"
    if marker in endpoint:
        repository, branch = endpoint.split(marker, 1)
        repository = repository.removeprefix("repos/") if hasattr(repository, "removeprefix") else repository[len("repos/"):]
        if repository == state["headRepository"] and branch == state["branch"]:
            if state.get("published", True):
                emit({"ref": "refs/heads/" + branch, "object": {"type": "commit", "sha": state["headCommit"]}})
        elif repository == state["baseRepository"] and branch in ["main", "develop"]:
            emit({"ref": "refs/heads/" + branch, "object": {"type": "commit", "sha": state["baseCommit"]}})
        save()
        print(json.dumps({"message": "Not Found", "status": "404"}))
        sys.stderr.write("gh: Not Found (HTTP 404)\n")
        sys.exit(1)

if args[:2] == ["pr", "list"]:
    rows = []
    if state.get("foreignSameBranch", False):
        rows.append(row(number=7, head_repository="unrelated/project"))
    if state.get("existing", False):
        rows.append(row(title=state.get("createdTitle")))
    emit(rows)
if args[:2] == ["pr", "view"]:
    if args[2] not in ["42", state["branch"]]:
        sys.stderr.write("fixture pull request is missing\n")
        sys.exit(1)
    emit(row(title=state.get("createdTitle")))
if args[:2] == ["pr", "create"]:
    if state.get("requireDurableDispatch", False):
        import sqlite3
        with sqlite3.connect(Path(state["databasePath"]).as_uri() + "?mode=ro", uri=True) as connection:
            snapshot = json.loads(connection.execute("SELECT payload FROM workspace WHERE id=1").fetchone()[0])
            operation = next((item for item in snapshot.get("pullRequestCreations", [])
                              if item["review"]["id"] == state["operationID"]), None)
            effect = None if operation is None else connection.execute(
                "SELECT id,command_id,status FROM workspace_effects WHERE id=?", (operation["effectID"],)).fetchone()
        state["durableDispatchObserved"] = bool(operation and operation["phase"] == "dispatching" and
            effect and effect[0] == operation["effectID"] and effect[1] == state["operationID"] and effect[2] == "running")
        save()
        if not state["durableDispatchObserved"]:
            sys.stderr.write("The owned intent was not durably dispatched before creation.\n")
            sys.exit(2)
    if state.get("createGate"):
        state_path.with_suffix(".create-entered").write_text("owned create reached\n")
        deadline = time.monotonic() + 8
        while not Path(state["createGate"]).exists():
            if time.monotonic() >= deadline:
                sys.stderr.write("The owned create fixture gate was not released.\n")
                sys.exit(2)
            time.sleep(0.01)
    state["creates"] = state.get("creates", 0) + 1
    call["stdin"] = sys.stdin.read()
    state["createdBody"] = call["stdin"]
    state["createdTitle"] = option("title")
    state["selectedBase"] = option("base")
    state["isDraft"] = "--draft" in args
    if state.get("createMode") != "lostBefore":
        state["existing"] = True
    save()
    if state.get("createMode") in ["lostBefore", "lostAfter"]:
        sys.stderr.write("fixture connection lost; https://synthetic-user:synthetic-secret@example.invalid/?token=synthetic-token\n")
        sys.exit(1)
    print("https://github.com/" + state["baseRepository"] + "/pull/42")
    sys.exit(0)

sys.stderr.write("Unsupported task-private gh command\n")
sys.exit(2)
