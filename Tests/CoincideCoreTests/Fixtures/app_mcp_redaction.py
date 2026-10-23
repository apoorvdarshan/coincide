"""Private stdio echo peer. No credentials in argv, environment or files."""
import json
import sys

claude = sys.argv[1] == "claude"

def emit(frame):
    print(json.dumps(frame), flush=True)

for line in sys.stdin:
    frame = json.loads(line)
    params = frame.get("request", {}) if claude else frame.get("params", {})
    method = params.get("subtype") if claude else frame.get("method")
    ident = frame.get("request_id") if claude else frame.get("id")
    if method == "echo":
        header = params["header"]
        token = header[7:]
        private = {"header": header, "nested": [token, {token: "literal safe text"}]}
        sys.stderr.write(header + "\n")
        sys.stderr.flush()
        if claude:
            emit({"type": "diagnostic", "private": private})
            emit({"type": "control_request", "request_id": "native-request", "request": {"subtype": "can_use_tool", "private": private}})
            emit({"type": "control_response", "response": {"subtype": "success", "request_id": ident, "response": private}})
        else:
            emit({"method": "diagnostic", "params": private})
            emit({"id": "native-request", "method": "native/request", "params": private})
            emit({"id": ident, "result": private})
    elif method == "error":
        header = params["header"]
        if claude:
            emit({"type": "control_response", "response": {"subtype": "error", "request_id": ident, "error": header + " " + header[7:]}})
        else:
            emit({"id": ident, "error": {"code": -32000, "message": header, "data": {"bare": header[7:]}}})
