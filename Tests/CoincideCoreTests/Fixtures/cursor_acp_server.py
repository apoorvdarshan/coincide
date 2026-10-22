import json
import sys

mode = sys.argv[1]
session = "cursor-fixture-session"
prompt_id = None
round_number = 0


def send(frame):
    print(json.dumps({"jsonrpc": "2.0", **frame}, ensure_ascii=False), flush=True)


def result(request, value):
    send({"id": request["id"], "result": value})


def ask(plan=False):
    if plan:
        payload = {"toolCallId": "plan-tool", "name": "Fixture plan", "plan": "# Review\nKeep files unchanged.",
                   "todos": [{"id": "one", "content": "Inspect", "status": "pending"}]}
        method = "_cursor/create_plan"
    else:
        payload = {"toolCallId": "question-tool", "title": "Exact choices", "futureSecret": "synthetic-private-token",
                   "questions": [{"id": "multi", "prompt": "Choose options", "allowMultiple": True,
                                  "options": [{"id": "opaque-B", "label": "Same label"}, {"id": "opaque-A", "label": "Same label"}]},
                                 {"id": "single", "prompt": "Choose one", "options": [{"id": "日本語", "label": "Yes"}]}]}
        if mode == "malformed":
            payload["questions"][0]["options"][1]["id"] = "opaque-B"
        method = "_cursor/ask_question"
    if mode == "alias":
        method = method[1:]
    send({"id": "reused-wire", "method": method, "params": payload})


for line in sys.stdin:
    frame = json.loads(line)
    method = frame.get("method")
    params = frame.get("params", {})
    if len(sys.argv) > 2:
        with open(sys.argv[2], "a") as audit:
            audit.write((method or "response") + "\n")
    if method == "initialize":
        assert params["clientCapabilities"] == {}
        result(frame, {"protocolVersion": 1, "agentInfo": {"name": "fixture-cursor", "version": "1"},
                       "agentCapabilities": {"loadSession": True, "promptCapabilities": {"image": True}},
                       "authMethods": [{"id": "cursor_login", "name": "Cursor login"}]})
    elif method == "session/new":
        assert mode != "initialize", "Connection check created a session"
        result(frame, {"sessionId": session})
    elif method == "session/prompt":
        prompt_id = frame["id"]
        ask(plan=mode in ["accept", "decline"])
        if mode == "remote_cancel":
            send({"method": "$/cancel_request", "params": {"requestId": "reused-wire"}})
            ask(plan=True)
    elif method == "session/cancel":
        assert mode == "cancel"
    elif frame.get("id") == "reused-wire":
        if mode in ["malformed", "unprofiled"]:
            assert "error" in frame
        else:
            outcome = frame["result"]["outcome"]
            if mode in ["accept", "remote_cancel"]:
                assert outcome == {"outcome": "accepted"}
            elif mode == "decline":
                assert outcome == {"outcome": "rejected"}
            elif mode == "skip":
                assert outcome == {"outcome": "skipped"}
            elif mode == "cancel":
                assert outcome == {"outcome": "cancelled"}
            else:
                assert outcome == {"outcome": "answered", "answers": [
                    {"questionId": "multi", "selectedOptionIds": ["opaque-B", "opaque-A"]},
                    {"questionId": "single", "selectedOptionIds": ["日本語"]}]}
        round_number += 1
        if mode == "reuse" and round_number == 1:
            ask()
        else:
            send({"id": prompt_id, "result": {"stopReason": "cancelled" if mode == "cancel" else "end_turn"}})
    else:
        raise AssertionError("Unexpected fixture client method")
