#!/usr/bin/python3
"""Task-owned offline Codex app-server peer. Never logs credential values."""
import json
import os
import signal
import stat
import sys
import uuid

ROOT = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(ROOT, "options.json"), encoding="utf-8") as source:
    OPTIONS = json.load(source)


def record(kind, **values):
    # Values are restricted to synthetic markers, method names, booleans and PID.
    data = (json.dumps({"kind": kind, "pid": os.getpid(), **values}, ensure_ascii=False) + "\n").encode("utf-8")
    fd = os.open(os.path.join(ROOT, "wire.jsonl"), os.O_APPEND | os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)


OVERRIDES = [
    'model_provider="openai_token_sharing"',
    'model_providers.openai_token_sharing.name="OpenAI Token Sharing"',
    'model_providers.openai_token_sharing.base_url="https://api.openai.com/v1"',
    'model_providers.openai_token_sharing.model_catalog_url="https://api.openai.com/v1/models"',
    'features.api_key_model_discovery=true',
    'features.multi_agent=false',
    'features.multi_agent_v2=false',
    'model_providers.openai_token_sharing.env_key="ACCESS_TOKEN"',
    'model_providers.openai_token_sharing.wire_api="responses"',
    'model_providers.openai_token_sharing.requires_openai_auth=false',
    'model_providers.openai_token_sharing.supports_websockets=false',
]
EXPECTED = ["app-server", "--stdio"] + [part for override in OVERRIDES for part in ["-c", override]]
home = os.environ.get("CODEX_HOME", "")
token = os.environ.get("ACCESS_TOKEN", "")
try:
    uuid.UUID(token)
    token_is_synthetic_uuid = True
except ValueError:
    token_is_synthetic_uuid = False
owned = OPTIONS.get("owned", False)
home_matches = bool(home) and os.path.realpath(home) == OPTIONS.get("overlay")
shared_history = bool(home) and os.path.realpath(os.path.join(home, "sessions")) == os.path.join(OPTIONS["shared"], "sessions")
private_home = home_matches and stat.S_IMODE(os.stat(home).st_mode) == 0o700
record("launch", exactArguments=sys.argv[1:] == EXPECTED, argumentCount=len(sys.argv) - 1,
       basicArguments=sys.argv[1:] == ["app-server", "--stdio"], tokenPresent=bool(token),
       syntheticToken=token_is_synthetic_uuid, aliasesScrubbed=all(key not in os.environ for key in
           ["T3CODE_CODEX_LAUNCH_ARGS", "OPENAI_API_KEY", "OPENAI_BASE_URL"]),
       privateHome=private_home, exactHome=home_matches, sharedHistory=shared_history,
       authRedirect=bool(home) and os.path.islink(os.path.join(home, "auth.json")))
del token

terminated = False


def on_term(_signal, _frame):
    global terminated
    # ProcessChannel closes owned stdin before signalling. Keep draining it.
    terminated = True


signal.signal(signal.SIGTERM, on_term)


def emit(value):
    print(json.dumps({"jsonrpc": "2.0", **value}, ensure_ascii=False), flush=True)


def reply(identifier, value):
    emit({"id": identifier, "result": value})


def notify(method, params):
    emit({"method": method, "params": {"threadId": native_thread, **params}})


native_thread = "owned-native-thread"
state_path = os.path.join(home, "sessions", "owned-fixture-history.json") if owned else None
state = {"threadID": native_thread, "count": 0}
if owned and os.path.isfile(state_path):
    with open(state_path, encoding="utf-8") as source:
        state = json.load(source)
if owned:
    cache = os.path.join(home, "models_cache.json")
    if not os.path.exists(cache):
        fd = os.open(cache, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.write(fd, b'{"syntheticPrivateCache":true}')
        os.close(fd)

try:
    for line in sys.stdin:
        frame = json.loads(line)
        method, identifier = frame.get("method"), frame.get("id")
        params = frame.get("params") or {}
        record("request", method=method)
        if identifier is None:
            continue
        if method == "initialize":
            reply(identifier, {"userAgent": "coincide/0.156.1"})
        elif method == "model/list":
            reply(identifier, {"data": [{"id": "owned-catalog-row", "model": "owned-wire-model", "displayName": "Synthetic owned model",
                "supportedReasoningEfforts": [{"reasoningEffort": "medium", "description": "Synthetic medium"}],
                "defaultReasoningEffort": "medium", "isDefault": True, "hidden": False}], "nextCursor": None})
        elif method == "thread/start":
            record("thread", resumed=False, persisted=False)
            reply(identifier, {"thread": {"id": native_thread}})
        elif method == "thread/resume":
            persisted = bool(owned and os.path.isfile(state_path) and state["count"] > 0 and params.get("threadId") == state["threadID"])
            record("thread", resumed=True, persisted=persisted)
            if persisted:
                reply(identifier, {"thread": {"id": native_thread}})
            else:
                emit({"id": identifier, "error": {"code": -32602, "message": "Synthetic conversation was not persisted"}})
        elif method == "turn/start":
            state["count"] += 1
            turn_id = "owned-turn-" + str(state["count"])
            text = " ".join(item.get("text", "") for item in params.get("input", []) if item.get("type") == "text")
            record("turn", marker=text, nativeThreadMatches=params.get("threadId") == native_thread,
                   modelMatches=params.get("model") == "owned-wire-model", effortMatches=params.get("effort") == "medium")
            if owned:
                fd = os.open(state_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                os.write(fd, json.dumps(state).encode("utf-8")); os.fsync(fd); os.close(fd)
            reply(identifier, {"turn": {"id": turn_id}})
            notify("turn/started", {"turn": {"id": turn_id}})
            notify("item/completed", {"turnId": turn_id, "item": {"id": "message-" + turn_id, "type": "agentMessage", "text": "OWNED_REPLY " + text}})
            notify("turn/completed", {"turn": {"id": turn_id, "status": "completed"}})
        elif method == "turn/interrupt":
            reply(identifier, {})
            notify("turn/completed", {"turn": {"id": params.get("turnId"), "status": "interrupted"}})
        else:
            emit({"id": identifier, "error": {"code": -32601, "message": "Unsupported synthetic method"}})
    record("closed", stdinEOF=True, signalObserved=terminated)
except Exception:
    # Never persist parser input, requests, environment or exception bodies.
    record("peer-failed", failed=True)
    raise SystemExit(2)
