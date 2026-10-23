"""Delegate actual Git; map only exact fixture fetch URLs to private bare repos."""
import json
import os
from pathlib import Path
import sys
import time

root = Path(sys.argv[1]).resolve(strict=True)
assert root.name.startswith("coincide-remote-pr-") and os.stat(root).st_mode & 0o077 == 0
args = sys.argv[2:]
assert not any(item in ("push", "clone", "ls-remote") for item in args)
state = json.loads((root / "gh-state.json").read_text())
if "commit" in args and state.get("holdCommit", False):
    fd = os.open(root / "git-wire.jsonl", os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        data = (json.dumps({"kind": "held-commit", "pid": os.getpid()}) + "\n").encode()
        assert os.write(fd, data) == len(data)
    finally:
        os.close(fd)
    deadline = time.monotonic() + 20
    while not (root / "release-commit").exists() and time.monotonic() < deadline:
        time.sleep(.005)
    assert (root / "release-commit").exists()
if "fetch" in args:
    mapping = {"https://github.com/upstream/project.git": root / "base.git", "https://github.com/fork/project.git": root / "head.git"}
    remote = next((item for item in args if "://" in item), None)
    assert remote in mapping
    bare = mapping[remote].resolve(strict=True)
    assert bare.parent == root and bare.is_dir()
    args = [str(bare) if item == remote else item for item in args]
    fd = os.open(root / "git-wire.jsonl", os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        data = (json.dumps({"kind": "fetch", "pid": os.getpid(), "localOnly": True}) + "\n").encode()
        assert os.write(fd, data) == len(data)
    finally:
        os.close(fd)
    if state.get("holdFetch", False):
        deadline = time.monotonic() + 20
        while not (root / "release-fetch").exists() and time.monotonic() < deadline:
            time.sleep(.005)
        assert (root / "release-fetch").exists()
    os.environ["GIT_ALLOW_PROTOCOL"] = "file"
else:
    # Metadata may contain HTTPS remote configuration, but only the exact mapped
    # fetch path above can contact a transport. No credential helper can run.
    os.environ["GIT_ALLOW_PROTOCOL"] = ""
os.execve("/usr/bin/git", ["/usr/bin/git", *args], os.environ)
