"""Synthetic Claude SDK control peer; no provider/model/network calls."""
import copy
import json
import os
import sys
import time

scenario, root = sys.argv[1:3]
question_one = " Choose one / 工作? "
question_many = "Which features, exactly?"
native_input = {
    "questions": [
        {"question": question_one, "header": "Single", "multiSelect": False,
         "options": [{"label": "a/b", "description": "Slash", "preview": "native preview"},
                     {"label": "a b", "description": "Space"}]},
        {"question": question_many, "header": "Multiple", "multiSelect": True,
         "options": [{"label": "First, literal", "description": "Comma"},
                     {"label": "Second 🌍", "description": "Unicode"}]}
    ],
    "metadata": {"source": "synthetic", "unicode": "Caf\u00e9"},
    "futureInput": {"keep": [1, True, "exact"]},
    "annotations": {question_one: {"preview": "native preview", "future": "preserve"}}
}
request = {"subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": native_input,
           "tool_use_id": "tool-question"}
turn = 0


def emit(value):
    sys.stdout.write(json.dumps(value, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def ask(value=request):
    emit({"type": "control_request", "request_id": "question-1", "request": value})


def finish():
    emit({"type": "result", "session_id": "claude-questions", "is_error": False, "result": "QUESTION_DONE"})


def wait_for_release():
    with open(os.path.join(root, "ready"), "w", encoding="utf-8") as marker:
        marker.write("ready")
    deadline = time.monotonic() + 10
    while not os.path.exists(os.path.join(root, "release")):
        if time.monotonic() >= deadline:
            raise AssertionError("Fixture release timed out")
        time.sleep(.005)


for line in sys.stdin:
    frame = json.loads(line)
    with open(os.path.join(root, "wire.jsonl"), "a", encoding="utf-8") as wire:
        wire.write(json.dumps(frame, ensure_ascii=False) + "\n")
    if frame["type"] == "control_request":
        subtype = frame["request"]["subtype"]
        if subtype == "initialize" and scenario == "inactive":
            ask()
        assert subtype in ("initialize", "set_permission_mode", "set_model", "interrupt")
        emit({"type": "control_response", "response": {
            "subtype": "success", "request_id": frame["request_id"], "response": {}}})
    elif frame["type"] == "user":
        turn += 1
        emit({"type": "system", "subtype": "init", "session_id": "claude-questions"})
        if scenario == "malformed":
            invalid = copy.deepcopy(request)
            invalid["input"]["questions"][1]["question"] = question_one
            ask(invalid)
        else:
            ask()
            if scenario in ("cancel", "changed"):
                ask()  # Exact retransmission must not emit another UI request.
                wait_for_release()
                if scenario == "cancel":
                    emit({"type": "control_cancel_request", "request_id": "question-1"})
                    finish()
                else:
                    changed = copy.deepcopy(request)
                    changed["input"]["questions"][0]["options"][0]["label"] = "CHANGED"
                    ask(changed)
    elif frame["type"] == "control_response":
        response = frame["response"]
        assert response["request_id"] == "question-1"
        if scenario in ("malformed", "changed", "inactive") or scenario == "reused" and turn == 2:
            assert response["subtype"] == "error"
            if scenario != "inactive":
                finish()
            continue
        assert response["subtype"] == "success"
        result = response["response"]
        if scenario == "decline":
            assert result["behavior"] == "deny" and "updatedInput" not in result
        else:
            assert result["behavior"] == "allow"
            updated = result["updatedInput"]
            assert updated["questions"] == native_input["questions"]
            assert updated["metadata"] == native_input["metadata"]
            assert updated["futureInput"] == native_input["futureInput"]
            assert set(updated["answers"]) == {question_one, question_many}
            if scenario in ("generic", "reused"):
                assert updated["answers"] == {question_one: " custom, 工作 🌍 ", question_many: "First, literal, Second 🌍"}
                assert updated["annotations"] == native_input["annotations"]
            else:
                assert updated["answers"] == {question_one: "a/b", question_many: "First, literal, Second 🌍, custom answer"}
                assert updated["annotations"][question_one] == {"preview": "native preview", "future": "preserve", "notes": " exact notes 🌍 "}
        finish()
    else:
        raise AssertionError(frame["type"])
