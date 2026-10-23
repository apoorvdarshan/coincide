#!/usr/bin/env python3
"""Opt-in full Pi 0.80.5 RPC acceptance, without credentials or model calls.

Use an intact, privately installed package and its original npm tarball. This
does not install anything. macOS sandbox-exec denies networking for every Pi
process; all history, configuration and home files are private synthetic data.
It verifies the vendor CLI, rather than the Swift adapter or authentication.
"""

import argparse
import asyncio
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tarfile
import tempfile
import uuid


SHA1 = "fa44899aaa75806b9bcc7be187a90208c057878f"
SHA512 = "GPYFuHw1BN+3m5Gzw1HGH41WdFDzbplLauS0zYSf1ZOkgKFd6wtEAcjchB/vmz9YtTGbQOwECbsVj6GxZxungA=="
STAMP = "2026-01-01T00:00:00.000Z"


def verify_package(package, archive_path):
    raw = archive_path.read_bytes()
    assert len(raw) == 4_867_511 and hashlib.sha1(raw).hexdigest() == SHA1
    assert base64.b64encode(hashlib.sha512(raw).digest()).decode() == SHA512
    with tarfile.open(archive_path, "r:gz") as archive:
        members = archive.getmembers()
        assert len(members) == 821 and sum(row.size for row in members) == 12_490_538
        seen = set()
        for member in members:
            parts = Path(member.name).parts
            assert member.isfile() and parts[0] == "package" and ".." not in parts
            assert not Path(member.name).is_absolute() and member.name not in seen
            seen.add(member.name)
            target = package.joinpath(*parts[1:])
            assert target.read_bytes() == archive.extractfile(member).read(), member.name
    lock = json.loads((package / "npm-shrinkwrap.json").read_text())
    installed = 0
    for relative, metadata in lock["packages"].items():
        if not relative:
            continue
        manifest = package / relative / "package.json"
        if manifest.exists():
            assert json.loads(manifest.read_text())["version"] == metadata["version"], relative
            installed += 1
        else:
            assert metadata.get("optional") is True, relative
    return installed


def seed(path, cwd):
    header = {"type": "session", "version": 3, "id": str(uuid.uuid4()), "timestamp": STAMP, "cwd": str(cwd)}
    rows = [
        {"type": "model_change", "id": "model001", "parentId": None, "timestamp": STAMP, "provider": "openai", "modelId": "gpt-4"},
        {"type": "thinking_level_change", "id": "think001", "parentId": "model001", "timestamp": STAMP, "thinkingLevel": "off"},
    ]
    parent = "think001"
    for number in (1, 2):
        user, assistant = f"user000{number}", f"assist0{number}"
        rows.append({"type": "message", "id": user, "parentId": parent, "timestamp": STAMP, "message": {
            "role": "user", "content": [{"type": "text", "text": f"Synthetic native input {number} 工作"}], "timestamp": 1767225600000}})
        rows.append({"type": "message", "id": assistant, "parentId": user, "timestamp": STAMP, "message": {
            "role": "assistant", "content": [{"type": "text", "text": f"Synthetic native answer {number} λ"}],
            "api": "openai-responses", "provider": "openai", "model": "gpt-4", "stopReason": "stop", "timestamp": 1767225600001,
            "usage": {"input": 1, "output": 1, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 2,
                      "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0}}}})
        parent = assistant
    path.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in [header, *rows]))
    path.chmod(0o600)
    return header, rows


async def request(process, command, **fields):
    assert command in {"get_state", "get_entries", "fork"}
    identity = str(uuid.uuid4())
    process.stdin.write((json.dumps({"id": identity, "type": command, **fields}) + "\n").encode())
    await process.stdin.drain()
    deadline = asyncio.get_running_loop().time() + 15
    total = 0
    for _ in range(256):
        remaining = deadline - asyncio.get_running_loop().time()
        assert remaining > 0, "Native RPC response timed out."
        line = await asyncio.wait_for(process.stdout.readline(), remaining)
        assert line, "Native RPC closed before its correlated response."
        total += len(line)
        assert len(line) <= 4 * 1024 * 1024 and total <= 32 * 1024 * 1024
        message = json.loads(line)
        if message.get("type") == "response" and message.get("id") == identity:
            assert message.get("command") == command and message.get("success") is True
            return message.get("data")
        assert message.get("type") != "extension_ui_request", "Unexpected lifecycle dialog."
    raise AssertionError("Native RPC response event limit exceeded.")


async def drain(process):
    process.stdin.close()
    try:
        status = await asyncio.wait_for(process.wait(), 8)
    except asyncio.TimeoutError:
        assert os.getpgid(process.pid) == process.pid
        os.killpg(process.pid, signal.SIGTERM)
        await asyncio.wait_for(process.wait(), 5)
        raise AssertionError("Native RPC did not drain on EOF.")
    stderr = await process.stderr.read(8192)
    assert status == 0, "Native RPC exited unsuccessfully."
    return {"exit": status, "stderrBytes": len(stderr)}


async def check(args):
    assert shutil.which("sandbox-exec"), "macOS sandbox-exec is required to deny all network access."
    package, node = args.package_root.resolve(), args.node.resolve()
    installed = verify_package(package, args.archive.resolve())
    root = Path(tempfile.mkdtemp(prefix="coincide-pi-native-history-", dir="/tmp"))
    root.chmod(0o700)
    for name in ("Home", "Tmp", "Agent", "Cwd", "Sessions"):
        (root / name).mkdir(mode=0o700)
    env = {"PATH": "/usr/bin:/bin", "HOME": str(root / "Home"), "TMPDIR": str(root / "Tmp"), "LANG": "en_US.UTF-8",
           "PI_CODING_AGENT_DIR": str(root / "Agent"), "PI_OFFLINE": "1", "PI_SKIP_VERSION_CHECK": "1", "NO_COLOR": "1"}
    base = [shutil.which("sandbox-exec"), "-p", "(version 1) (allow default) (deny network*)", str(node), str(package / "dist/cli.js"),
            "--offline", "--no-tools", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes", "--no-context-files",
            "--provider", "openai", "--model", "gpt-4", "--thinking", "off", "--mode", "rpc", "--session-dir", str(root / "Sessions")]
    node_version = subprocess.check_output([str(node), "--version"], env=env, timeout=5, text=True).strip()
    results = {"package": "@earendil-works/pi-coding-agent", "version": "0.80.5", "node": node_version,
               "originalPackageFilesVerified": 821, "lockedInstalledVersionsVerified": installed,
               "network": "OS denied", "modelRequests": 0, "authCredentials": 0, "scenarios": []}
    try:
        for label, cut in (("historical", "user0002"), ("first-user", "user0001"), ("cli-head-fork", None)):
            source = root / "Sessions" / f"{label}-source.jsonl"
            header, rows = seed(source, (root / "Cwd").resolve())
            original = source.read_bytes()
            extra = ["--fork" if cut is None else "--session", str(source)]
            process = await asyncio.create_subprocess_exec(*base, *extra, cwd=root / "Cwd", env=env,
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
                limit=4 * 1024 * 1024, start_new_session=True)
            try:
                state, entries = await request(process, "get_state"), await request(process, "get_entries")
                assert not state["isStreaming"] and not state["isCompacting"] and state["pendingMessageCount"] == 0
                assert len(entries["entries"]) == 6 and entries["leafId"] is not None
                if cut is not None:
                    assert state["sessionId"] == header["id"] and state["sessionFile"] == str(source)
                    assert entries["entries"] == rows and entries["leafId"] == "assist02"
                    response = await request(process, "fork", entryId=cut)
                    state, entries = await request(process, "get_state"), await request(process, "get_entries")
                    assert response["cancelled"] is False and len(entries["entries"]) == 4
                    assert response["text"] == f"Synthetic native input {2 if label == 'historical' else 1} 工作"
                    if label == "historical":
                        assert entries["entries"] == rows[:4]
                    else:
                        assert state["messageCount"] == 0 and entries["entries"][:2] == rows[:2]
                        assert [row["type"] for row in entries["entries"][2:]] == ["model_change", "thinking_level_change"]
                        assert entries["entries"][2]["provider"] == "openai" and entries["entries"][2]["modelId"] == "gpt-4"
                        assert entries["entries"][3]["thinkingLevel"] == "off"
                assert state["sessionFile"] != str(source) and state["sessionId"] != header["id"]
                candidate = Path(state["sessionFile"])
                assert candidate.exists() == (label != "first-user")
                if candidate.exists():
                    disk = [json.loads(line) for line in candidate.read_text().splitlines()]
                    assert disk[0]["parentSession"] == str(source) and disk[0]["cwd"] == str((root / "Cwd").resolve())
                    assert disk[1:] == entries["entries"]
                assert source.read_bytes() == original
                result = {"name": label, "entries": len(entries["entries"]), "candidatePersisted": candidate.exists(), "unchangedSource": True}
            finally:
                closed = await drain(process)
            result["drain"] = closed
            results["scenarios"].append(result)
        args.output.write_text(json.dumps(results, indent=2) + "\n")
        args.output.chmod(0o600)
        shutil.rmtree(root)
        return results
    except BaseException:
        print(f"Private failed native history evidence preserved at {root}")
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-root", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--node", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    print(json.dumps(asyncio.run(check(parser.parse_args()))))
