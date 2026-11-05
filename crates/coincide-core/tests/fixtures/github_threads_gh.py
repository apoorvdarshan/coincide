#!/usr/bin/env python3
"""Native acceptance fixture. Fixed synthetic PR only; NO networking or vaults.

Use only as the configured executable of a dedicated synthetic threads service.
No real gh fallback. Marker files in the synthetic stored root enable scenarios:
  threads-slow: pause before response so Cancel/scope switching can be exercised
  threads-changed-head: return a different full SHA (must fail closed)
  threads-partial-errors: return data AND GraphQL errors (must fail closed)
Log contains only fixed synthetic query names/variables, never environment values.
"""
import json
import pathlib
import sys
import time


def main():
    args = sys.argv[1:]
    assert args[:2] == ["api", "graphql"]
    assert args[args.index("--hostname") + 1] == "github.com"
    assert args[args.index("--method") + 1] == "POST"
    fields = {}
    for index, arg in enumerate(args):
        if arg in ("--raw-field", "--field"):
            name, value = args[index + 1].split("=", 1)
            fields[name] = value
    query = fields["query"]
    assert "mutation " not in query and "fullDatabaseId" in query
    comments = query.startswith("query CoincideReviewComments")
    assert comments or query.startswith("query CoincideReviewThreads")
    cursor = fields.get("cursor")
    if comments:
        assert fields["id"] == "fixture-thread-1"
        assert cursor == "fixture-replies-2"
    else:
        assert fields["owner"] == "owner" and fields["name"] == "project"
        assert fields["number"] == "7"
        assert cursor in (None, "fixture-threads-2")
    with pathlib.Path("threads-fixture-calls.jsonl").open("a") as log:
        log.write(json.dumps({"kind": "comments" if comments else "threads", "cursor": cursor}) + "\n")
    if pathlib.Path("threads-slow").exists():
        time.sleep(3)
    pr = {
        "number": 7,
        "url": "https://github.com/owner/project/pull/7",
        "headRefOid": ("b" if pathlib.Path("threads-changed-head").exists() else "a") * 40,
        "repository": {"nameWithOwner": "owner/project"},
    }

    def connection(nodes, next_cursor=None):
        return {"nodes": nodes, "pageInfo": {"hasNextPage": next_cursor is not None, "endCursor": next_cursor}}

    def comment(number, body, reply=False):
        return {
            "id": "fixture-comment-" + str(number),
            "databaseId": str(number),  # fullDatabaseId BigInt alias, intentionally string-valued
            "body": body,
            "diffHunk": "@@ -3,2 +3,2 @@\n-old value\n+new value",
            "author": {"login": "fixture-reviewer"},
            "url": "https://github.com/owner/project/pull/7#discussion_r" + str(number),
            "createdAt": "2026-11-05T12:00:00Z",
            "updatedAt": "2026-11-05T12:01:00Z",
            "commit": None if reply else {"oid": "a" * 40},
            "replyTo": {"id": "fixture-comment-101", "databaseId": "101"} if reply else None,
        }

    if comments:
        data = {"node": {"id": "fixture-thread-1", "pullRequest": pr,
                         "comments": connection([comment(102, "Reply mentions @org/team. `@code` is code text.", True)])}}
    else:
        second = cursor is not None
        thread = {
            "id": "fixture-thread-2" if second else "fixture-thread-1",
            "path": "src/second.rs" if second else "src/first.rs",
            "line": None if second else 4, "originalLine": 3, "startLine": None,
            "diffSide": "RIGHT", "isResolved": second, "isOutdated": second,
            "resolvedBy": {"login": "fixture-maintainer"} if second else None,
            "comments": connection([comment(201 if second else 101,
                                            "Resolved older discussion." if second else "Please check @octocat. Contact user@example.com is not a mention.")],
                                   None if second else "fixture-replies-2"),
        }
        pr["reviewThreads"] = connection([thread], None if second else "fixture-threads-2")
        data = {"repository": {"pullRequest": pr}}
    value = {"data": data}
    if pathlib.Path("threads-partial-errors").exists():
        value["errors"] = [{"message": "SYNTHETIC-UNTRUSTED-DIAGNOSTIC"}]
    print(json.dumps(value), flush=True)


if __name__ == "__main__":
    main()
