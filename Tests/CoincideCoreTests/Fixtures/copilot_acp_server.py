"""Closed-world ACP1 Copilot integration peer; no providers, Git or network."""
import json
import os
import sys

mode, wire = sys.argv[1:3]
session = "copilot-integration-root"
prompts = 0
new_sessions = 0
events = ["subagent.started", "subagent.completed", "subagent.failed",
          "assistant.message_delta", "assistant.reasoning_delta"]


def emit(frame):
    print(json.dumps(dict(jsonrpc="2.0", **frame), ensure_ascii=False), flush=True)


def reply(request, value):
    emit(dict(id=request["id"], result=value))


def update(kind, **fields):
    emit(dict(method="session/update", params=dict(sessionId=session,
        update=dict(sessionUpdate=kind, **fields))))


def raw(kind, data, agent=None):
    params = dict(sessionId=session, type=kind, data=data)
    if agent is not None:
        params["agentId"] = agent
    emit(dict(method="_github.com/copilot/sessionEvent", params=params))


def chunk(text, message="child-message", *, task="child-launch", thought=False):
    data = dict(deltaContent=text)
    if task is not None:
        data["parentToolCallId"] = task
    raw("assistant.reasoning_delta" if thought else "assistant.message_delta", data)
    fields = dict(content=dict(type="text", text=text))
    if message != "__absent__":
        fields["messageId"] = message
    update("agent_thought_chunk" if thought else "agent_message_chunk", **fields)


for line in sys.stdin:
    request = json.loads(line)
    assert request.get("jsonrpc") == "2.0"
    descriptor = os.open(wire, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    with os.fdopen(descriptor, "a", encoding="utf-8") as output:
        output.write(json.dumps(request, ensure_ascii=False) + "\n")
    method, params = request.get("method"), request.get("params", {})
    if method == "initialize":
        assert params["protocolVersion"] == 1
        assert params["clientCapabilities"] == {"_meta": {"github.com/copilot": {"events": events}}}
        reply(request, dict(protocolVersion=1, agentInfo=dict(name="Offline Copilot", version="fixture"),
            agentCapabilities=dict(loadSession=True, promptCapabilities=dict(image=False)), authMethods=[]))
    elif method == "session/new":
        new_sessions += 1
        assert new_sessions == 1 and set(params) == {"cwd", "mcpServers"}
        assert os.path.isabs(params["cwd"]) and params["mcpServers"] == []
        reply(request, dict(sessionId=session))
    elif method == "session/prompt":
        prompts += 1
        assert params["sessionId"] == session and len(params["prompt"]) == 1
        assert params["prompt"][0] == dict(type="text", text="first" if prompts == 1 else "second")
        if prompts == 1:
            update("tool_call", toolCallId="child-launch", title="Launch background child", status="completed",
                rawInput=dict(agent_type="explore", prompt="Inspect the synthetic checkout", mode="background",
                              description="Offline child", model="fixture-model"))
            raw("subagent.started", dict(toolCallId="child-launch"), agent="child-agent")
            if mode == "null":
                message = None
            elif mode == "missing":
                message = "__absent__"
            elif mode == "number":
                message = 19
            elif mode == "object":
                message = {"unexpected": "synthetic-private-token"}
            elif mode == "oversized":
                message = "x" * 4097
            else:
                message = "child-message"
            chunk("child first café λ", message)
            if mode in ("number", "object", "oversized"):
                continue  # The client must close without a trap or raw-value error.
            chunk("child thought first", "child-thought", thought=True)
            update("tool_call", toolCallId="nested-read", title="Nested child read", status="completed",
                _meta={"github.com/copilot": {"agentId": "child-agent"}},
                content=[dict(type="content", content=dict(type="text", text="Nested child result"))])
            chunk("DROP unknown child", "unknown-child-message", task="unowned-child")
            chunk("root first", "root-first", task=None)
            reply(request, dict(stopReason="end_turn"))
        else:
            assert mode == "ownership" and prompts == 2
            chunk("child late during second run", "child-late")
            raw("subagent.completed", dict(toolCallId="child-launch"), agent="child-agent")
            chunk("DROP finished child", "after-completion")
            chunk("root second", "root-second", task=None)
            reply(request, dict(stopReason="end_turn"))
    else:
        raise AssertionError("The offline Copilot fixture refuses unsupported methods.")
