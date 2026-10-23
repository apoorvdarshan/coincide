#!/usr/bin/python3
"""Task-private gh stand-in for pull request merge/state actions. No network, no real gh."""
import json
import os
import sys
import time
from pathlib import Path

state_path = Path(os.environ["COINCIDE_GH_FIXTURE"])
args = sys.argv[1:]
state = json.loads(state_path.read_text())
token = os.environ.get("GH_TOKEN")
call = {"args": args, "stdin": None, "hasToken": token is not None,
        "tokenMatches": token is not None and token == state.get("expectedToken"),
        "tokenInArgs": any(state.get("expectedToken", "\0") in value for value in args)}
state.setdefault("calls", []).append(call)


def save():
    temporary = state_path.with_name(state_path.name + "." + str(os.getpid()) + ".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        json.dump(state, handle)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, state_path)


def emit(value):
    save()
    print(json.dumps(value))
    sys.exit(0)


def fail(message, code=1):
    save()
    sys.stderr.write(message + "\n")
    sys.exit(code)


def option(name):
    prefix = "--" + name + "="
    return next((value[len(prefix):] for value in args if value.startswith(prefix)), None)


def field(name):
    for index, value in enumerate(args):
        if value in ["-f", "-F"] and index + 1 < len(args) and args[index + 1].startswith(name + "="):
            return args[index + 1][len(name) + 1:]
    return None


def write(kind):
    state.setdefault("writes", []).append(kind)
    # A single append is independent of the mutable JSON snapshot. If a bug
    # launches two concurrent mutations, their stale snapshots cannot conceal
    # the second native write by replacing each other's counters.
    descriptor = os.open(state_path.with_suffix(".writes"), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(descriptor, (kind + "\n").encode("ascii"))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


base = state["baseRepository"]
head_repository = state.get("headRepository", base)


def row():
    state["views"] = state.get("views", 0) + 1
    if state.get("moveHeadAfterViews") and state["views"] > state["moveHeadAfterViews"]:
        state["headCommit"] = state["movedCommit"]
    owner = head_repository.split("/")[0]
    return {"id": "PR_kwFixture42", "number": state.get("number", 42), "title": "Fixture pull request",
            "url": "https://github.com/" + base + "/pull/" + str(state.get("number", 42)),
            "state": state.get("state", "OPEN"), "isDraft": state.get("isDraft", False),
            "headRefName": state["headBranch"], "baseRefName": state.get("baseBranch", "main"), "headRefOid": state["headCommit"], "baseRefOid": state["baseCommit"],
            "headRepository": {"nameWithOwner": head_repository}, "headRepositoryOwner": {"login": owner},
            "isCrossRepository": head_repository != base, "updatedAt": "2026-10-21T01:02:03Z",
            "mergeable": state.get("mergeable", "MERGEABLE"), "mergeStateStatus": state.get("mergeStateStatus", "CLEAN"),
            "autoMergeRequest": state.get("autoMerge")}


if args[:2] == ["pr", "view"]:
    emit(row())

if args[:2] == ["api", "graphql"]:
    query = field("query") or ""
    if "viewerMergeBodyText" in query:
        emit({"data": {"repository": {"pullRequest": {"headRefOid": state["headCommit"], "viewerMergeBodyText": state.get("mergeBody", "")}}}})
    if query.startswith("query") and "defaultBranchRef" in query:
        ref = {"target": {"oid": state.get("refCommit", state["headCommit"])}} if state.get("refExists", True) else None
        emit({"data": {"repository": {"id": "R_fixture", "defaultBranchRef": {"name": "main"}, "ref": ref}}})
    if "updateRefs" in query:
        state["updateRefs"] = {"id": field("id"), "ref": field("ref"), "before": field("before")}
        write("delete-branch")
        state["refExists"] = False
        emit({"data": {"updateRefs": {"clientMutationId": None}}})
    if "updatePullRequestBranch" in query:
        state["updateBranch"] = {"id": field("id"), "oid": field("oid"), "method": field("method")}
        write("update-branch")
        emit({"data": {"updatePullRequestBranch": {"pullRequest": {"headRefOid": state["headCommit"]}}}})
    if "revertPullRequest" in query:
        write("revert")
        if state.get("holdRevert"):
            save()
            state_path.with_suffix(".revert-entered").write_text(str(os.getpid()))
            release = state_path.with_suffix(".revert-release")
            deadline = time.monotonic() + 30
            while not release.exists():
                if time.monotonic() >= deadline:
                    fail("task-private revert fixture was not released", 2)
                time.sleep(0.01)
        if state.get("revertMode") == "uncertain":
            fail("read tcp: connection reset by peer")
        emit({"data": {"revertPullRequest": {"revertPullRequest": {"number": 43, "url": "https://github.com/" + base + "/pull/43"}}}})
    fail("unsupported fixture GraphQL", 2)

if args and args[0] == "api":
    endpoint = args[-1]
    method = option("method")
    if endpoint == "repos/" + base and method == "GET":
        emit({"full_name": base, "permissions": state.get("permissions", {"push": True}), "allow_merge_commit": True,
              "allow_squash_merge": True, "allow_rebase_merge": state.get("allowRebase", True), "allow_auto_merge": state.get("allowAutoMerge", True)})
    if endpoint.startswith("repos/" + base + "/actions/runs?") and method == "GET":
        emit({"total_count": len(state.get("runs", [])), "workflow_runs": state.get("runs", [])})
    if endpoint.startswith("repos/" + base + "/actions/runs/") and endpoint.endswith("/approve") and method == "POST":
        run = int(endpoint.split("/")[-2])
        state["runs"] = [item for item in state.get("runs", []) if item["id"] != run]
        state.setdefault("approved", []).append(run)
        write("approve")
        emit({})
    fail("unsupported fixture API", 2)

if args[:2] == ["pr", "merge"]:
    call["stdin"] = sys.stdin.read() if "--body-file=-" in args else None
    mode = state.get("mergeMode", "normal")
    if mode == "rejected":
        fail("GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)")
    if mode == "uncertain":
        write("merge")
        fail("read tcp: connection reset by peer")
    if "--disable-auto" in args:
        state["autoMerge"] = None
        write("disable-auto")
        emit({})
    write("auto-merge" if "--auto" in args else "merge")
    if "--auto" in args:
        method = next(name for name in ["merge", "squash", "rebase"] if "--" + name in args)
        state["autoMerge"] = {"mergeMethod": method.upper()}
    else:
        state["state"] = "MERGED"
    save()
    sys.exit(0)

if args[:2] == ["pr", "ready"]:
    state["isDraft"] = "--undo" in args
    write("draft" if "--undo" in args else "ready")
    save()
    sys.exit(0)

if args[:2] in [["pr", "close"], ["pr", "reopen"]]:
    state["state"] = "CLOSED" if args[1] == "close" else "OPEN"
    write(args[1])
    save()
    sys.exit(0)

fail("Unsupported task-private gh command", 2)
