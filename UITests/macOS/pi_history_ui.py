"""Offline Pi 0.80.5 RPC peer for owned hosted-UI history workflows.

Only private synthetic JSONL is read/written. No model, auth, network, extension
execution or provider fallback exists. Native graph semantics are tested against
the independent original-source oracle separately from these UI fixtures.
"""
import fcntl
import json
import os
from pathlib import Path
import stat
import sys
import uuid

MAX_BYTES = 4_194_304
STAMP = "2026-10-23T00:00:00.000Z"


def require(value):
    if not value:
        raise ValueError("invalid private Pi UI fixture")


def directory(value, root):
    path = Path(value)
    resolved = path.resolve(strict=True)
    require(path.is_absolute() and not path.is_symlink() and os.path.commonpath([root, resolved]) == str(root))
    current = root
    for part in resolved.relative_to(root).parts:
        current /= part
        info = current.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and info.st_mode & 0o077 == 0)
    return resolved


def read(path, optional=False):
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        if optional:
            return None
        raise
    try:
        info = os.fstat(descriptor)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1
                and info.st_mode & 0o077 == 0 and info.st_size <= MAX_BYTES)
        data = bytearray()
        while len(data) <= MAX_BYTES:
            block = os.read(descriptor, min(65_536, MAX_BYTES + 1 - len(data)))
            if not block:
                break
            data.extend(block)
        require(len(data) <= MAX_BYTES)
        return bytes(data)
    finally:
        os.close(descriptor)


def append(path, value):
    payload = (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        info = os.fstat(descriptor)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1
                and info.st_mode & 0o077 == 0 and info.st_size + len(payload) <= MAX_BYTES)
        offset = 0
        while offset < len(payload):
            offset += os.write(descriptor, payload[offset:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


class Peer:
    def __init__(self, state_path, wire, arguments):
        require(os.environ.get("COINCIDE_UI_TESTING") == "1")
        self.root = Path(os.environ["COINCIDE_UI_TEST_ROOT"]).resolve(strict=True)
        info = self.root.lstat()
        require(self.root.name.startswith("coincide-ui-testing-") and info.st_uid == os.getuid()
                and stat.S_ISDIR(info.st_mode) and info.st_mode & 0o077 == 0)
        self.state_path, self.wire = Path(state_path), Path(wire)
        require(self.state_path.parent.resolve(strict=True) == self.root and self.wire.parent.resolve(strict=True) == self.root)
        self.settings = json.loads(read(self.state_path))
        require(set(self.settings) == {"cwd", "historyMode", "actions"} and self.settings["historyMode"] in {"normal", "controls", "publish-and-disconnect"})
        self.cwd = directory(self.settings["cwd"], self.root)
        require(os.path.samefile(self.cwd, os.getcwd()))
        for key, name in [("HOME", "private-pi-home"), ("PI_CODING_AGENT_DIR", "private-pi-agent"),
                          ("PI_CODING_AGENT_SESSION_DIR", "private-pi-sessions")]:
            require(directory(os.environ[key], self.root) == self.root / name)
        self.sessions = self.root / "private-pi-sessions"
        require(isinstance(self.settings["actions"], dict) and len(self.settings["actions"]) <= 16)
        for prompt, action in self.settings["actions"].items():
            require(isinstance(prompt, str) and 0 < len(prompt) <= 4096 and set(action) == {"mode", "label"}
                    and action["mode"] in {"normal", "before-write-disconnect"} and isinstance(action["label"], str) and len(action["label"]) <= 100)
        self.version = arguments == ["--version"]
        if not self.version:
            require(arguments[:2] == ["--mode", "rpc"])
            suffix = arguments[2:]
            require(not suffix or len(suffix) == 2 and suffix[0] == "--extension")
            if suffix:
                extension = Path(suffix[1])
                info = extension.lstat()
                require(extension.is_absolute() and extension.name == "permission.ts" and extension.parent.name.startswith("coincide-pi-")
                        and stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1
                        and info.st_mode & 0o077 == 0 and info.st_size <= 65_536)
        self.header, self.entries, self.file, self.pending = None, [], None, None
        self.model = {"provider": "offline", "id": "pi-history-model"}
        self.thinking = "off"
        self.new_session()
        self.record("launch", versionOnly=self.version)

    def record(self, kind, **values):
        append(self.wire, {"kind": kind, **values})

    def native_path(self, path):
        value = Path(path)
        require(value.is_absolute() and value.parent.resolve(strict=True) == self.sessions and not value.is_symlink()
                and value.name.endswith(".jsonl") and len(value.name) <= 240)
        return value

    def new_session(self, path=None, parent=None):
        native = str(uuid.uuid4())
        self.file = self.native_path(path or self.sessions / (native + ".jsonl"))
        self.header = {"type": "session", "version": 3, "id": native, "timestamp": STAMP, "cwd": str(self.cwd)}
        if parent is not None:
            self.header["parentSession"] = str(parent)
        self.entries = []

    def load(self, path):
        path = self.native_path(path)
        data = read(path, optional=True)
        if data is None:
            self.new_session(path=path)
            return
        rows = [json.loads(line) for line in data.splitlines() if line.strip()]
        require(rows and rows[0].get("type") == "session" and rows[0].get("version") == 3
                and os.path.samefile(rows[0]["cwd"], self.cwd) and len(rows) <= 20_000)
        seen = set()
        for row in rows[1:]:
            require(row.get("type") == "message" and row.get("id") not in seen
                    and (row.get("parentId") is None or row["parentId"] in seen))
            seen.add(row["id"])
        self.header, self.entries, self.file = rows[0], rows[1:], path

    def persist(self):
        require(read(self.file, optional=True) is None)
        payload = b"".join((json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n").encode() for row in [self.header, *self.entries])
        require(len(payload) <= MAX_BYTES)
        descriptor = os.open(self.file, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            offset = 0
            while offset < len(payload):
                offset += os.write(descriptor, payload[offset:])
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    def state(self):
        return dict(sessionFile=str(self.file), sessionId=self.header["id"], isStreaming=False, isCompacting=False,
                    pendingMessageCount=0, model=self.model, thinkingLevel=self.thinking)

    def reply(self, frame, data=None):
        emit(dict(type="response", id=frame["id"], command=frame["type"], success=True, data=data))

    def branch(self, frame):
        index = next(index for index, entry in enumerate(self.entries) if entry["id"] == frame["entryId"])
        require(self.entries[index]["message"]["role"] == "user")
        retained, current = [], self.entries[index]["parentId"]
        by_id = {entry["id"]: entry for entry in self.entries}
        while current is not None:
            require(current in by_id and len(retained) < 20_000)
            retained.append(by_id[current]); current = by_id[current]["parentId"]
        source = self.file
        self.new_session(parent=source)
        parent = None
        for entry in reversed(retained):
            copied = dict(entry, parentId=parent); self.entries.append(copied); parent = copied["id"]
        if any(entry["message"]["role"] == "assistant" for entry in self.entries):
            self.persist()
        self.record("fork-result", sourceFile=str(source), candidateFile=str(self.file), retainedIDs=[entry["id"] for entry in self.entries])
        if self.settings["historyMode"] == "publish-and-disconnect":
            return False
        self.reply(frame, {"cancelled": False, "text": "Native returned text must never replace the latest draft"})
        return True

    def handle(self, frame):
        require(isinstance(frame, dict) and isinstance(frame.get("type"), str))
        kind = frame["type"]
        self.record("request", **frame)
        if kind == "extension_ui_response":
            require(self.pending is not None)
            pending, stage = self.pending
            if stage == "select":
                require(frame.get("id") == "pi-gui-select" and frame.get("value") == "Keep inherited context")
                self.pending = (pending, "confirm")
                emit(dict(type="extension_ui_request", id="pi-gui-confirm", method="confirm", title="Pi GUI final branch confirmation", timeout=0))
            else:
                require(frame.get("id") == "pi-gui-confirm" and isinstance(frame.get("confirmed"), bool))
                self.pending = None
                if frame["confirmed"]:
                    return self.branch(pending)
                self.reply(pending, {"cancelled": True})
            return True
        require(isinstance(frame.get("id"), str) and self.pending is None)
        if kind == "get_state": self.reply(frame, self.state())
        elif kind == "get_entries": self.reply(frame, {"entries": self.entries, "leafId": self.entries[-1]["id"] if self.entries else None})
        elif kind == "get_available_models": self.reply(frame, {"models": [{"provider": "offline", "id": "pi-history-model", "name": "Pi Offline History", "reasoning": False}]})
        elif kind == "switch_session": self.load(frame["sessionPath"]); self.reply(frame, {"cancelled": False})
        elif kind == "set_model": self.model = {"provider": frame["provider"], "id": frame["modelId"]}; self.reply(frame, self.model)
        elif kind == "set_thinking_level": self.thinking = frame["level"]; self.reply(frame)
        elif kind == "clear_queue": self.reply(frame, {"steering": [], "followUp": []})
        elif kind == "abort": self.reply(frame); emit({"type": "agent_settled", "aborted": True})
        elif kind == "fork":
            require(set(frame) == {"type", "id", "entryId"})
            if self.settings["historyMode"] == "controls":
                self.pending = (frame, "select")
                emit(dict(type="extension_ui_request", id="pi-gui-select", method="select", title="Pi GUI choose retained context",
                          options=["Keep inherited context", "Cancel branch"], timeout=0))
            else: return self.branch(frame)
        elif kind == "prompt":
            require(set(frame) <= {"type", "id", "message", "images", "streamingBehavior"} and not frame.get("images"))
            action = self.settings["actions"][frame["message"]]
            if action["mode"] == "before-write-disconnect":
                self.record("input-with-lost-result", message=frame["message"], sessionFile=str(self.file)); return False
            label = "Pi GUI saved " + action["label"]
            parent = self.entries[-1]["id"] if self.entries else None
            user = dict(type="message", id=uuid.uuid4().hex[:8], parentId=parent, timestamp=STAMP,
                        message=dict(role="user", content=[dict(type="text", text=frame["message"])], timestamp=1))
            answer = dict(type="message", id=uuid.uuid4().hex[:8], parentId=user["id"], timestamp=STAMP,
                          message=dict(role="assistant", content=[dict(type="text", text=label)], stopReason="stop", timestamp=1))
            existed = read(self.file, optional=True) is not None
            self.entries += [user, answer]
            if existed:
                append(self.file, user); append(self.file, answer)
            else: self.persist()
            emit({"type": "agent_start"}); self.reply(frame)
            emit({"type": "message_start", "message": {"role": "assistant"}})
            emit({"type": "message_update", "message": {"role": "assistant"}, "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": label}})
            emit({"type": "message_end", "message": answer["message"]}); emit({"type": "agent_end", "messages": []})
            emit({"type": "agent_settled", "aborted": False})
        else: require(False)
        return True


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def run():
    require(len(sys.argv) >= 4)
    peer = Peer(sys.argv[1], sys.argv[2], sys.argv[3:])
    try:
        if peer.version:
            print("0.80.5", flush=True); return
        while True:
            line = sys.stdin.buffer.readline(65_537)
            if not line:
                break
            require(len(line) <= 65_536 and line.endswith(b"\n"))
            if not peer.handle(json.loads(line)):
                break
    finally:
        peer.record("closed")


if __name__ == "__main__":
    try: run()
    except (ValueError, KeyError, TypeError, OSError, StopIteration, json.JSONDecodeError):
        print("The isolated Pi history peer rejected its input.", file=sys.stderr)
        sys.exit(78)
