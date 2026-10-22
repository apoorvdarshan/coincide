"""Immutable hosted-UI Claude stream-json peer; private synthetic transcripts only.

No authentication, network, installed provider or user home is consulted. Native
forking/selection is performed by the app; this peer reads that real file graph.
"""
import fcntl
import json
import os
from pathlib import Path
import select
import stat
import sys
import unicodedata
import uuid

BASE_ARGUMENTS = ["--print", "--input-format", "stream-json", "--output-format", "stream-json",
                  "--verbose", "--include-partial-messages", "--permission-prompt-tool", "stdio",
                  "--allow-dangerously-skip-permissions"]
MAX_FILE = 4_194_304
MAX_FRAME = 65_536
MODES = {"normal", "hold-result", "consume-then-disconnect", "before-write-disconnect"}


def require(value):
    if not value:
        raise ValueError("invalid isolated Claude fixture")


def native_uuid(value):
    require(isinstance(value, str) and len(value) == 36 and str(uuid.UUID(value)) == value.lower())
    return value


def private_directory(path, root):
    path = Path(path)
    require(path.is_absolute() and os.path.commonpath([str(root), str(path.resolve(strict=True))]) == str(root))
    current = root
    for part in path.resolve(strict=True).relative_to(root).parts:
        current /= part
        info = current.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and info.st_mode & 0o077 == 0)
    require(not path.is_symlink())
    return path.resolve(strict=True)


def regular_bytes(path, maximum=MAX_FILE, optional=False):
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        if optional:
            return b""
        raise
    try:
        info = os.fstat(descriptor)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1
                and info.st_mode & 0o077 == 0 and info.st_size <= maximum)
        data = bytearray()
        while len(data) <= maximum:
            block = os.read(descriptor, min(65_536, maximum + 1 - len(data)))
            if not block:
                break
            data.extend(block)
        require(len(data) <= maximum)
        return bytes(data)
    finally:
        os.close(descriptor)


def append(path, rows):
    payload = b"".join((json.dumps(row, separators=(",", ":"), ensure_ascii=False) + "\n").encode() for row in rows)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        info = os.fstat(descriptor)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1
                and info.st_mode & 0o077 == 0 and info.st_size + len(payload) <= MAX_FILE)
        offset = 0
        while offset < len(payload):
            offset += os.write(descriptor, payload[offset:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def project_key(path):
    units = unicodedata.normalize("NFC", path).encode("utf-16-le")
    values = [int.from_bytes(units[index:index + 2], "little") for index in range(0, len(units), 2)]
    result = "".join(chr(value) if value < 128 and chr(value).isascii() and chr(value).isalnum() else "-" for value in values)
    if len(result) <= 200:
        return result
    hashed = 0
    for value in values:
        hashed = (hashed * 31 + value) & 0xffffffff
    number = abs(hashed if hashed < 0x80000000 else hashed - 0x100000000)
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    suffix = "0" if number == 0 else ""
    while number:
        suffix = digits[number % 36] + suffix
        number //= 36
    return result[:200] + "-" + suffix


def parse_arguments(arguments):
    require(arguments[:len(BASE_ARGUMENTS)] == BASE_ARGUMENTS)
    suffix = arguments[len(BASE_ARGUMENTS):]
    if not suffix:
        return "new", str(uuid.uuid4()), None
    if len(suffix) == 2 and suffix[0] == "--session-id":
        return "fresh", native_uuid(suffix[1]), None
    require(len(suffix) in (2, 3) and suffix[0] == "--resume")
    native = native_uuid(suffix[1])
    if len(suffix) == 2:
        return "resume", native, None
    require(suffix[2].startswith("--resume-session-at="))
    return "resumeAt", native, native_uuid(suffix[2].split("=", 1)[1])


def run():
    require(len(sys.argv) >= 4 and os.environ.get("COINCIDE_UI_TESTING") == "1")
    root = Path(os.environ["COINCIDE_UI_TEST_ROOT"]).resolve(strict=True)
    info = root.lstat()
    require(root.name.startswith("coincide-ui-testing-") and stat.S_ISDIR(info.st_mode)
            and info.st_uid == os.getuid() and info.st_mode & 0o077 == 0)
    state_path, wire = Path(sys.argv[1]), Path(sys.argv[2])
    require(state_path.parent.resolve(strict=True) == root and wire.parent.resolve(strict=True) == root)
    state = json.loads(regular_bytes(state_path))
    require(set(state) == {"cwd", "configurationDirectory", "actions"} and isinstance(state["actions"], dict)
            and len(state["actions"]) <= 16)
    cwd = private_directory(state["cwd"], root)
    configuration = private_directory(state["configurationDirectory"], root)
    require(os.path.samefile(cwd, os.getcwd()) and os.path.samefile(configuration, os.environ["CLAUDE_CONFIG_DIR"]))
    private_directory(os.environ["HOME"], root)
    require(os.environ.get("CLAUDE_CODE_PROJECT_DIR_NAME") in (None, "coincide-claude-ui")
            and not os.environ.get("CLAUDE_CODE_DISABLE_PRECOMPACT_SKIP"))
    for prompt, action in state["actions"].items():
        require(isinstance(prompt, str) and 0 < len(prompt) <= 4096 and isinstance(action, dict)
                and set(action) <= {"mode", "label", "gate"} and action.get("mode") in MODES
                and isinstance(action.get("label"), str) and 0 < len(action["label"]) <= 64)
        if action["mode"] == "hold-result":
            gate = action.get("gate")
            require(isinstance(gate, str) and gate.startswith("release-") and len(gate) <= 80
                    and "/" not in gate and "\\" not in gate and ".." not in gate)
    selection, session, cursor = parse_arguments(sys.argv[3:])
    projects = configuration / "projects"
    projects.mkdir(mode=0o700, exist_ok=True)
    private_directory(projects, root)
    directory = projects / (os.environ.get("CLAUDE_CODE_PROJECT_DIR_NAME") or project_key(str(cwd)))
    directory.mkdir(mode=0o700, exist_ok=True)
    private_directory(directory, root)
    transcript = directory / (session + ".jsonl")
    rows = [json.loads(line) for line in regular_bytes(transcript, optional=True).splitlines()]
    require(len(rows) <= 128)
    if selection in ("resume", "resumeAt"):
        require(rows)
    if selection in ("fresh", "new"):
        require(not rows and not transcript.exists())
    records = {row["uuid"]: row for row in rows if row.get("uuid") and row.get("type") in ("user", "assistant")}
    require(len(records) == sum(1 for row in rows if row.get("uuid") and row.get("type") in ("user", "assistant")))
    parent = cursor if cursor is not None else next((row.get("uuid") for row in reversed(rows)
        if row.get("type") in ("user", "assistant") and row.get("isSidechain") is not True), None)
    if cursor:
        require(cursor in records and records[cursor].get("type") == "assistant")
    launch = str(uuid.uuid4())
    def log(method, **values):
        append(wire, [dict(method=method, launchID=launch, **values)])
    def emit(value):
        data = (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
        require(len(data) <= MAX_FRAME)
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
    def result(input_id, text, error=False):
        log("result", inputID=input_id, sessionID=session, isError=error)
        emit(dict(type="result", session_id=session, parent_tool_use_id=None, user_message_uuid=input_id,
                  is_error=error, result=text))
    log("launch", selection=selection, sessionID=session, cursor=cursor,
        privateConfiguration=True, privateHome=True)
    permission = None
    pending = None
    buffer = bytearray()
    turns = 0
    try:
        while True:
            # The held terminal is an explicit test-controlled gate, not timing
            # used to decide whether the queued successor arrived too early.
            if pending and (root / pending[0]).exists():
                require(regular_bytes(root / pending[0], maximum=32) == b"release\n")
                result(pending[1], pending[2]); pending = None
            ready, _, _ = select.select([sys.stdin.buffer], [], [], 0.05 if pending else None)
            if not ready:
                continue
            block = os.read(sys.stdin.fileno(), 4096)
            if not block:
                require(not buffer)
                return
            buffer.extend(block)
            require(len(buffer) <= MAX_FRAME)
            while b"\n" in buffer:
                line, _, remainder = buffer.partition(b"\n")
                buffer = bytearray(remainder)
                require(line and len(line) <= MAX_FRAME)
                frame = json.loads(line)
                if frame.get("type") == "control_request":
                    request, ident = frame["request"], frame["request_id"]
                    method = request["subtype"]
                    require(isinstance(ident, str) and len(ident) <= 256)
                    if method == "set_model":
                        log(method, model=request.get("model"))
                    elif method == "set_permission_mode":
                        log(method, mode=request.get("mode"))
                    else:
                        log(method)
                    response = {}
                    if method == "initialize":
                        response = {"models": [{"value": "claude-ui-model", "displayName": "Claude UI Model"}]}
                    elif method == "set_permission_mode":
                        permission = request["mode"]
                        require(permission == "default")
                    elif method == "set_model":
                        require(request.get("model") in (None, "claude-ui-model"))
                    elif method == "interrupt":
                        pass
                    else:
                        raise ValueError("unsupported isolated control")
                    emit(dict(type="control_response", response=dict(subtype="success", request_id=ident, response=response)))
                    if method == "interrupt" and pending:
                        result(pending[1], "Synthetic turn interrupted", True); pending = None
                    continue
                require(frame.get("type") == "user" and pending is None and permission == "default")
                turns += 1
                require(turns <= 16 and frame.get("parent_tool_use_id") is None)
                opening = native_uuid(frame["uuid"])
                prompt = frame["message"]["content"]
                require(frame["message"]["role"] == "user" and isinstance(prompt, str) and prompt in state["actions"])
                action = state["actions"][prompt]
                chain, visited, next_id = [], set(), parent
                while next_id is not None:
                    require(next_id not in visited and next_id in records and len(visited) < 128)
                    visited.add(next_id)
                    row = records[next_id]
                    require(row.get("sessionId") == session and row.get("isSidechain") is False)
                    chain.append(row)
                    next_id = row.get("parentUuid")
                native_text = "\n".join(row["message"]["content"] for row in reversed(chain)
                    if isinstance(row["message"].get("content"), str))
                alpha, beta = "Remember the native marker ALPHA." in native_text, "Remember the native marker BETA." in native_text
                log("user", inputID=opening, sessionID=session, parentID=parent, action=action["label"],
                    mode=action["mode"], contextAlpha=alpha, contextBeta=beta, cursor=cursor)
                emit(dict(type="system", subtype="init", session_id=session, parent_tool_use_id=None))
                if action["mode"] == "before-write-disconnect":
                    return
                user = dict(type="user", uuid=opening, parentUuid=parent, sessionId=session, cwd=str(cwd),
                            isSidechain=False, message=dict(role="user", content=prompt))
                require(opening not in records)
                append(transcript, [user]); records[opening] = user
                emit(dict(type="user", uuid=opening, session_id=session, parent_tool_use_id=None,
                          message=user["message"]))
                if action["mode"] == "consume-then-disconnect":
                    return
                if action["label"] == "alpha":
                    answer = "Claude GUI saved ALPHA"
                elif action["label"] == "beta":
                    answer = "Claude GUI saved BETA"
                else:
                    answer = "Claude GUI " + action["label"] + " context " + ("ALPHA" if alpha else "EMPTY") + (" BETA" if beta else "")
                assistant = str(uuid.uuid4())
                row = dict(type="assistant", uuid=assistant, parentUuid=opening, sessionId=session, cwd=str(cwd),
                           isSidechain=False, message=dict(role="assistant", content=answer))
                append(transcript, [row]); records[assistant] = row; parent = assistant
                emit(dict(type="assistant", uuid=assistant, session_id=session, parent_tool_use_id=None,
                          user_message_uuid=opening, message=dict(id="api-" + str(uuid.uuid4()), role="assistant",
                          content=[dict(type="text", text=answer)])))
                if action["mode"] == "hold-result":
                    pending = (action["gate"], opening, answer)
                    log("held", inputID=opening, sessionID=session)
                else:
                    result(opening, answer)
    finally:
        log("closed", sessionID=session)


if __name__ == "__main__":
    try:
        run()
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
        sys.stderr.write("The isolated Claude history peer rejected its synthetic contract.\n")
        raise SystemExit(78)
