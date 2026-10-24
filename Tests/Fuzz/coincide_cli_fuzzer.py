#!/usr/bin/env python3
"""Atheris fuzz target for Coincide's local control client, script/coincide.

The client reads a private connection file, checks that it names the app's
authenticated loopback endpoint, and turns the app's JSON-RPC replies into JSON
output or a "coincide: ..." error. This target runs that code on generated
input, without the app, a provider, or a network connection:

- connection() reads a generated connection file from a temporary home folder,
  with varied permissions, links, sizes, endpoints and credentials;
- main() parses generated command lines and handles generated app replies
  through an in-memory opener;
- local_action_error() receives generated tool errors.

Each input is checked against the client's contracts (docs/LOCAL_CONTROL.md):
only a private, regular, single-link connection file is read; an accepted
endpoint is plain HTTP to 127.0.0.1 at /mcp, and urllib would send the request
there unchanged; the credential is a well-formed bearer value; requests go
initialize, initialized, tools/call, each at most once, with that credential;
oversized replies are refused; only well-formed app messages for documented
recovery errors reach the terminal; and every failure raises an exception that
the script's __main__ block reports, never a traceback.

Atheris publishes Linux x86_64 wheels only. To run it there:

    python3 -m pip install atheris
    python3 Tests/Fuzz/coincide_cli_fuzzer.py -max_total_time=60

CI builds it with ClusterFuzzLite (.clusterfuzzlite/) from .github/workflows/fuzz.yml.
"""
import atexit
import base64
import contextlib
import http.client
import importlib.machinery
import importlib.util
import inspect
import io
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
from unittest import mock
import urllib.parse
import urllib.request
import uuid

# The client is loaded from source at run time, so PyInstaller (which
# ClusterFuzzLite uses to package the target) can't see its imports. Import
# them here so they are bundled.
import argparse  # noqa: F401
import stat  # noqa: F401
import urllib.error  # noqa: F401

import atheris

# The script's __main__ block reports these as "coincide: ..." (FileNotFoundError,
# URLError and TimeoutError are OSError subclasses). Any other exception reaches
# the user as a traceback. Keep this in sync with that block.
REPORTED = (ValueError, KeyError, OSError)

# Synthetic connection used when main() is fuzzed; connection() is fuzzed separately.
RECORD = {"endpoint": "http://127.0.0.1:8765/mcp", "authorization": "Bearer " + "0" * 43}
METHODS = ("initialize", "notifications/initialized", "tools/call")
UUID = "8d7c4ba6-3f61-4d1e-9a0b-2c5e7f1d9a34"

# Commands that never return recovery errors; an unknown command can't either.
READ_ONLY_COMMANDS = ["status", "projects", "providers"]
UNKNOWN_COMMAND = "x-unknown-"
ACTION_COMMANDS = READ_ONLY_COMMANDS + [
    "configuration", "configuration-set", "integrations", "integration-import",
    "integration-remove", "integration-use", "send", "compact", "compaction-cancel", "export"]
# The app's recovery codes plus one it never exposes. They only steer generation;
# the checks don't depend on this list.
CODES = ["configuration_review_required", "configuration_changed", "configuration_invalid",
         "integration_refresh_required", "message_not_confirmed",
         "context_compaction_not_confirmed", "provider_error"]
KEYS = ["jsonrpc", "id", "result", "error", "code", "message", "isError",
        "structuredContent", "endpoint", "authorization"]
WORDS = KEYS + CODES + ["2.0", "Bearer ", "http://127.0.0.1:1/mcp"]

# Generated endpoints combine these, then may have URL-significant characters spliced in.
SCHEMES = ["http", "http", "http", "HTTP", "https", "file", "", "\x01http", " http"]
USER_INFO = ["", "", "", "", "@", "user@", "user:pw@", "127.0.0.1@"]
HOSTS = ["127.0.0.1", "127.0.0.1", "127.0.0.1", "localhost", "[::1]", "127.0.0.2",
         "127.1", "0x7f.0.0.1", "127.0.0.1.", "example.com"]
PORTS = [":8765", ":8765", ":1", ":65535", ":08765", "", ":", ":0", ":65536", ":-1", ":x"]
PATHS = ["/mcp", "/mcp", "/mcp", "/MCP", "/mcp/", "/", "", "//mcp", "/%6dcp", "/mcp/.."]
SUFFIXES = ["", "", "", "?", "?a=1", "#", "#top", "?#"]
URL_CHARACTERS = [" ", "\t", "\n", "\r", "\x00", "\x01", "\x7f", "@", "#", "?", "\\", "/", ":", "%"]
CONTROL_CHARACTERS = [0, 9, 10, 13, 27, 31, 127]

ARGUMENTS = [UUID, UUID.upper(), "{" + UUID + "}", "urn:uuid:" + UUID, "~", "~/notes.md",
             "~coincide-fuzz-no-such-user/notes.md", "./notes.md", "/tmp/notes.md", "", "-x",
             "--confirm", "message text"]
COMMAND_LINES = [  # None is replaced by a generated argument.
    ["status"], ["projects"], ["providers"], ["threads"], ["threads", "--project", None],
    ["integrations", "--provider", "codex", "--kind", "mcp"], ["integration-import", None],
    ["sessions", "claude"], ["session-stop", "codex", None, "--confirm"],
    ["configuration", "claude", "--scope", "project"], ["configuration-set", None, None, None],
    ["send", None, "--confirm"], ["send", None, "--thread", None, "--confirm"],
    ["compaction", "--thread", None], ["compact", "--confirm"],
    ["compaction-cancel", "--operation", None, "--confirm"], ["thread", None], ["select", None],
    ["models", "--all", "--refresh"], ["new", None], ["model", "codex", None],
    ["sort", "--chats", "name"], ["ui", "--settings", "mcp"], ["screenshot", None],
    ["export", None, "--format", "json"]]


def client_path():
    bundle = getattr(sys, "_MEIPASS", None)  # PyInstaller one-file build from ClusterFuzzLite
    if bundle:
        return Path(bundle, "coincide")
    return Path(__file__).resolve().parents[2] / "script" / "coincide"


def load_client():
    loader = importlib.machinery.SourceFileLoader("coincide_cli", str(client_path()))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    for value in list(vars(module).values()):
        if inspect.isfunction(value) and value.__module__ == module.__name__:
            atheris.instrument_func(value)  # includes nested functions such as main()'s rpc
    return module


client = load_client()
GENERIC = client.local_action_error("status", {})
CONTROL = None  # private Control folder under a temporary HOME; set by main()


def fail(problem, **details):
    raise AssertionError(f"{problem}: {details!r}")


def parse(data):
    try:
        return json.loads(data)
    except (ValueError, RecursionError):
        return None


# Input generation


def text(fdp, limit=48):
    return fdp.ConsumeUnicodeNoSurrogates(fdp.ConsumeIntInRange(0, limit))


def json_value(fdp, depth=2):
    kind = fdp.ConsumeIntInRange(0, 7 if depth > 0 else 5)
    if kind == 0:
        return None
    if kind == 1:
        return fdp.ConsumeBool()
    if kind == 2:
        return fdp.ConsumeInt(4)
    if kind == 3:
        return fdp.ConsumeFloat()
    if kind == 4:
        return text(fdp)
    if kind == 5:
        return fdp.PickValueInList(WORDS)
    if kind == 6:
        return [json_value(fdp, depth - 1) for _ in range(fdp.ConsumeIntInRange(0, 3))]
    return {(fdp.PickValueInList(KEYS) if fdp.ConsumeBool() else text(fdp, 8)): json_value(fdp, depth - 1)
            for _ in range(fdp.ConsumeIntInRange(0, 3))}


def message_value(fdp):
    kind = fdp.ConsumeIntInRange(0, 4)
    if kind == 0:
        return json_value(fdp, 0)
    if kind == 1:
        return "m" * fdp.ConsumeIntInRange(4090, 4100)
    message = text(fdp, 80)
    if kind == 2:
        at = fdp.ConsumeIntInRange(0, len(message))
        message = message[:at] + chr(fdp.PickValueInList(CONTROL_CHARACTERS)) + message[at:]
    return message


def tool_result(fdp):
    result = {}
    flag = fdp.ConsumeIntInRange(0, 3)
    if flag == 1:
        result["isError"] = True
    elif flag == 2:
        result["isError"] = False
    elif flag == 3:
        result["isError"] = json_value(fdp, 0)
    shape = fdp.ConsumeIntInRange(0, 3)
    if shape == 0:
        result["structuredContent"] = json_value(fdp)
    elif shape == 1:
        result["structuredContent"] = {"error": json_value(fdp)}
    elif shape == 2:
        code = fdp.PickValueInList(CODES) if fdp.ConsumeIntInRange(0, 3) else json_value(fdp, 0)
        result["structuredContent"] = {"error": {"code": code, "message": message_value(fdp)}}
    return result


def endpoint_text(fdp):
    kind = fdp.ConsumeIntInRange(0, 7)
    if kind == 0:
        return text(fdp, 64)
    if kind <= 4:  # the form the app writes
        endpoint = f"http://127.0.0.1:{fdp.ConsumeIntInRange(0, 70000)}/mcp"
    else:
        endpoint = "".join(fdp.PickValueInList(part) for part in (SCHEMES, ["://"], USER_INFO, HOSTS, PORTS, PATHS, SUFFIXES))
    for _ in range(fdp.ConsumeIntInRange(-1, 2)):
        at = fdp.ConsumeIntInRange(0, len(endpoint))
        insert = fdp.PickValueInList(URL_CHARACTERS) if fdp.ConsumeBool() else text(fdp, 4)
        endpoint = endpoint[:at] + insert + endpoint[at:]
    return endpoint


def credential(fdp):
    if fdp.ConsumeBool():  # the app's form: "Bearer " and 32 random bytes in base64url
        return "Bearer " + base64.urlsafe_b64encode(fdp.ConsumeBytes(32).ljust(32, b"0")).rstrip(b"=").decode()
    token = text(fdp, 50)
    if fdp.ConsumeBool():
        token = (token + "0" * 43)[:43]  # the length the client expects
    return fdp.PickValueInList(["Bearer ", "Bearer ", "bearer ", "Basic ", ""]) + token


def connection_bytes(fdp):
    shape = fdp.ConsumeIntInRange(0, 9)
    if shape == 0:
        return fdp.ConsumeBytes(fdp.ConsumeIntInRange(0, 5000))
    if shape == 1:
        return b"[" * fdp.ConsumeIntInRange(1, 4096)
    if shape == 2:
        value = json_value(fdp)
    else:
        value = {}
        if fdp.ConsumeIntInRange(0, 9):
            value["endpoint"] = endpoint_text(fdp) if fdp.ConsumeIntInRange(0, 9) else json_value(fdp, 0)
        if fdp.ConsumeIntInRange(0, 9):
            value["authorization"] = credential(fdp) if fdp.ConsumeIntInRange(0, 9) else json_value(fdp, 0)
        if fdp.ConsumeIntInRange(0, 3) == 0:
            value[text(fdp, 8)] = json_value(fdp, 1)
    data = json.dumps(value, ensure_ascii=fdp.ConsumeBool()).encode()
    if fdp.ConsumeIntInRange(0, 15) == 0:
        data += b" " * (4097 - len(data))  # valid JSON just over the file size limit
    return data


def reply_body(fdp):
    shape = fdp.ConsumeIntInRange(0, 9)
    if shape == 0:
        return fdp.ConsumeBytes(fdp.ConsumeIntInRange(0, 300))
    if shape == 1:
        return b"[" * fdp.ConsumeIntInRange(1, 100_000)
    if shape == 2:
        value = json_value(fdp)
    elif shape == 3:
        error = json_value(fdp) if fdp.ConsumeBool() else {"code": fdp.ConsumeInt(4), "message": message_value(fdp)}
        value = {"jsonrpc": "2.0", "id": text(fdp, 8), "error": error}
    else:
        value = {"jsonrpc": "2.0", "id": text(fdp, 8),
                 "result": tool_result(fdp) if fdp.ConsumeIntInRange(0, 7) else json_value(fdp)}
    return json.dumps(value, ensure_ascii=fdp.ConsumeBool()).encode()


def command_line(fdp):
    argv = []
    for part in fdp.PickValueInList(COMMAND_LINES):
        if part is None:
            part = fdp.PickValueInList(ARGUMENTS) if fdp.ConsumeBool() else text(fdp, 40)
            part = part.replace("\x00", "")  # a real argv can't contain NUL
        argv.append(part)
    return argv


# Contract checks


def check_action_error(command, result, message):
    """The client shows its generic text, or the app's own message for a recovery error."""
    if message == GENERIC:
        return
    structured = result.get("structuredContent")
    error = structured.get("error") if isinstance(structured, dict) else None
    if not isinstance(error, dict) or message != error.get("message"):
        fail("showed text other than the app's error message", command=command, result=result, shown=message)
    if command in READ_ONLY_COMMANDS or command.startswith(UNKNOWN_COMMAND):
        fail("showed an app message for a command without recovery errors", command=command, result=result)
    if not isinstance(error.get("code"), str):
        fail("showed an app message for an error without a code", command=command, result=result)
    if (not isinstance(message, str) or not 0 < len(message) <= 4096
            or any(ord(c) < 32 or ord(c) == 127 for c in message)):
        fail("showed an empty, oversized, or terminal-control app message", command=command, shown=message)


def check_record(record):
    endpoint, credential_value = record.get("endpoint"), record.get("authorization")
    url = urllib.parse.urlsplit(endpoint)
    if ((url.scheme, url.hostname, url.path) != ("http", "127.0.0.1", "/mcp") or not url.port
            or url.username or url.password or url.query or url.fragment):
        fail("accepted an endpoint other than the app's loopback MCP endpoint", endpoint=endpoint)
    # The client validates with urlsplit, but urllib.request and http.client parse
    # the raw string again when they send it. Both must agree on the destination.
    try:
        request = urllib.request.Request(endpoint)
        connection = http.client.HTTPConnection(request.host)
        connection.putrequest("POST", request.selector)  # validates the request line; doesn't connect
    except (http.client.InvalidURL, ValueError) as error:
        fail("accepted an endpoint that urllib can't send", endpoint=endpoint, error=error)
    if (request.type != "http" or (connection.host, connection.port) != ("127.0.0.1", url.port)
            or urllib.parse.urlsplit(request.selector).path != "/mcp"):
        fail("accepted an endpoint that urllib sends somewhere else", endpoint=endpoint,
             sent=(request.type, connection.host, connection.port, request.selector))
    if (not isinstance(credential_value, str) or not credential_value.startswith("Bearer ")
            or len(credential_value) != 50 or "\r" in credential_value or "\n" in credential_value):
        fail("accepted a malformed credential", credential=credential_value)


def check_exchange(argv, replay, output, outcome):
    bodies = []
    for request in replay.requests:
        if request.full_url != RECORD["endpoint"] or request.get_method() != "POST":
            fail("sent a request somewhere other than the connection endpoint", url=request.full_url)
        if request.get_header("Authorization") != RECORD["authorization"]:
            fail("sent a request without the connection credential", argv=argv)
        bodies.append(json.loads(request.data))
    methods = tuple(body.get("method") for body in bodies)
    if methods != METHODS[:len(methods)]:
        fail("sent requests out of order or repeated one", argv=argv, methods=methods)
    ids = [body["id"] for body in bodies if "id" in body]
    if len(ids) != len(set(ids)) or any(("id" in body) == (body["method"] == METHODS[1]) for body in bodies):
        fail("sent a notification with an ID, or a request without a unique ID", bodies=bodies)
    for index, reply in enumerate(replay.replies):
        if reply.oversized and (not isinstance(outcome, ValueError) or len(replay.replies) != index + 1):
            fail("used a reply that reached the read limit", argv=argv, reply=index)
    if len(bodies) == 3:
        call = bodies[2].get("params", {})
        arguments = call.get("arguments", {})
        if call.get("name") != argv[0] or any(value is None for value in arguments.values()):
            fail("called the wrong tool or sent unset arguments", argv=argv, call=call)
        if "id" in arguments and arguments["id"] != str(uuid.UUID(arguments["id"])):
            fail("sent a non-canonical conversation ID", argv=argv, call=call)
        if "path" in arguments and not os.path.isabs(arguments["path"]):
            fail("sent a relative path", argv=argv, call=call)
    if outcome is None:
        reply = parse(replay.replies[-1].body) if len(bodies) == 3 else None
        result = reply.get("result") if isinstance(reply, dict) else None
        if not isinstance(result, dict) or result.get("isError"):
            fail("succeeded without a successful tool result", argv=argv, reply=reply)
        if output != json.dumps(result.get("structuredContent"), indent=2, ensure_ascii=False) + "\n":
            fail("printed something other than the tool's structured content", argv=argv, output=output)
    elif len(bodies) == 3 and isinstance(outcome, ValueError):
        reply = parse(replay.replies[-1].body)
        result = reply.get("result") if isinstance(reply, dict) and "error" not in reply else None
        if isinstance(result, dict) and result.get("isError"):
            check_action_error(argv[0], result, str(outcome))


# Targets


def write_connection(data, folder_bits, file_bits, link):
    os.chmod(CONTROL, 0o700)
    for name in ("connection.json", "target.json"):
        with contextlib.suppress(FileNotFoundError):
            os.unlink(CONTROL / name)
    target = CONTROL / ("connection.json" if link == "file" else "target.json")
    target.write_bytes(data)
    os.chmod(target, 0o600 | file_bits)
    if link == "symlink":
        os.symlink(target, CONTROL / "connection.json")
    elif link == "hardlink":
        os.link(target, CONTROL / "connection.json")
    os.chmod(CONTROL, 0o700 | folder_bits)


def loose_bits(fdp):
    return fdp.ConsumeIntInRange(1, 0o77) if fdp.ConsumeIntInRange(0, 7) == 0 else 0


def fuzz_connection(fdp):
    folder_bits, file_bits = loose_bits(fdp), loose_bits(fdp)
    link = fdp.PickValueInList(["file", "file", "file", "symlink", "hardlink"])
    override = fdp.PickValueInList([None, None, None, "absolute", "relative"])
    data = connection_bytes(fdp)
    write_connection(data, folder_bits, file_bits, link)
    if override:  # the test-only COINCIDE_CONTROL_DIR must get the same checks
        os.environ["COINCIDE_CONTROL_DIR"] = str(CONTROL) if override == "absolute" else "Control"
    try:
        record = client.connection()
    except REPORTED:
        return
    finally:
        os.environ.pop("COINCIDE_CONTROL_DIR", None)
    if folder_bits or file_bits or link != "file" or len(data) > 4096 or override == "relative":
        fail("read a connection file it must refuse", folder_bits=oct(folder_bits), file_bits=oct(file_bits),
             link=link, size=len(data), override=override)
    check_record(record)


class Reply:
    """A generated app reply; an oversized one fills the client's read limit with valid JSON."""

    def __init__(self, fdp):
        self.oversized = fdp.ConsumeIntInRange(0, 63) == 0
        self.body = b"" if self.oversized else reply_body(fdp)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self, limit):  # the client must bound every read
        if self.oversized:
            self.body = b" " * (limit - 2) + b"{}"
        return self.body[:limit]


class Replay:
    """Stands in for the client's urllib opener: records requests, returns generated replies."""

    def __init__(self, fdp):
        self.fdp, self.requests, self.replies = fdp, [], []

    def open(self, request, timeout):
        self.requests.append(request)
        self.replies.append(Reply(self.fdp))
        return self.replies[-1]


def fuzz_main(fdp):
    argv = command_line(fdp)
    replay = Replay(fdp)
    output = io.StringIO()
    outcome = None
    with mock.patch.object(client, "connection", return_value=dict(RECORD)), \
            mock.patch.object(urllib.request, "build_opener", return_value=replay), \
            mock.patch.object(sys, "argv", ["coincide", *argv]), \
            contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
        try:
            client.main()
        except SystemExit:
            # argparse rejected the command line, or printed help, before contacting the app.
            if replay.requests:
                fail("exited after contacting the app", argv=argv)
            return
        except REPORTED as error:
            outcome = error
    check_exchange(argv, replay, output.getvalue(), outcome)


def fuzz_action_error(fdp):
    if fdp.ConsumeIntInRange(0, 3):
        command = fdp.PickValueInList(ACTION_COMMANDS)
    else:
        command = UNKNOWN_COMMAND + text(fdp, 12)
    result = tool_result(fdp)
    check_action_error(command, result, client.local_action_error(command, result))


TARGETS = [fuzz_connection, fuzz_main, fuzz_action_error]


def TestOneInput(data):
    fdp = atheris.FuzzedDataProvider(data)
    TARGETS[fdp.ConsumeIntInRange(0, len(TARGETS) - 1)](fdp)


def main():
    global CONTROL
    home = Path(tempfile.mkdtemp(prefix="coincide-fuzz-"))
    atexit.register(shutil.rmtree, home, ignore_errors=True)
    os.environ["HOME"] = str(home)  # the client's default Control folder is under HOME
    os.environ.pop("COINCIDE_CONTROL_DIR", None)
    CONTROL = home / "Library" / "Application Support" / "Coincide" / "Control"
    CONTROL.mkdir(parents=True)
    if not isinstance(GENERIC, str) or not GENERIC:
        raise RuntimeError("local_action_error() did not return its generic message")
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
