"""Offline app-server peer for account/allowance lifecycle tests."""
import json
import os
import sys
import time

with open(sys.argv[1], encoding="utf-8") as handle:
    options = json.load(handle)
wire = sys.argv[2]
account_reads = 0
default_account = {"account": {"type": "chatgpt", "email": "offline@example.invalid", "planType": "pro"}, "requiresOpenaiAuth": True}
default_usage = {"rateLimits": {"limitId": "codex", "primary": {"usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1800000000},
                               "secondary": {"usedPercent": 40, "windowDurationMins": 10080, "resetsAt": 1801000000}}}


def emit(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)


for line in sys.stdin:
    frame = json.loads(line)
    fd = os.open(wire, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(frame, separators=(",", ":")) + "\n")
    if "id" not in frame:
        continue
    method = frame.get("method")
    result = None
    error = None
    if method == "initialize":
        result = {"userAgent": "coincide/0.163.0"}
    elif method == "account/read":
        account_reads += 1
        if options.get("accountErrorCode") is not None:
            error = options["accountErrorCode"]
        else:
            accounts = options.get("accounts", [default_account])
            result = accounts[min(account_reads - 1, len(accounts) - 1)]
            if account_reads > 1:
                for notice in options.get("updatesBeforeFinalAccount", []):
                    emit(notice)
    elif method == "account/rateLimits/read":
        time.sleep(options.get("usageDelay", 0))
        if options.get("exitDuringUsage"):
            sys.exit(0)
        for notice in options.get("updatesBeforeUsage", []):
            emit(notice)
        if options.get("usageErrorCode") is not None:
            error = options["usageErrorCode"]
        else:
            result = options.get("usage", default_usage)
    else:
        error = -32601
    if error is not None:
        emit({"id": frame["id"], "error": {"code": error, "message": "synthetic-private-token must never be displayed"}})
    else:
        emit({"id": frame["id"], "result": result})
    if method == "account/read" and account_reads == 1:
        for notice in options.get("updatesAfterFirstAccount", []):
            emit(notice)
    if method == "account/rateLimits/read":
        for notice in options.get("updatesAfterUsage", []):
            emit(notice)
