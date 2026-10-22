"""Closed-world skill metadata peer. No vendor, credential or skill-file access."""
import json
import os
from pathlib import Path
import sys
import threading

options_path, wire_path = map(Path, sys.argv[1:3])
options = json.loads(options_path.read_text())
closed = threading.Event()
output_lock = threading.Lock()
workers = []
skill_reads = 0


def emit(frame):
    with output_lock:
        print(json.dumps(frame, ensure_ascii=False), flush=True)


def answer_skills(identifier, held):
    while held and not closed.is_set() and not (options_path.parent / "release-skills").exists():
        closed.wait(0.005)
    if closed.is_set():
        return
    if "error" in options:
        emit({"id": identifier, "error": {"code": options["error"], "message": "synthetic-private-skill-error"}})
        return
    response = options.get("response", {"data": [{"cwd": os.getcwd(), "skills": [
        {"name": "review-follow-up", "description": "Offline advertised description 日本語", "path": "relative/SKILL.md",
         "scope": "repo", "enabled": True, "interface": {"displayName": "Offline Review", "shortDescription": "Native interface summary"}}
    ], "errors": []}]})
    emit({"id": identifier, "result": response})


try:
    for line in sys.stdin:
        if len(line) > 4_194_304:
            raise SystemExit("Oversized offline skill request.")
        frame = json.loads(line)
        with wire_path.open("a", encoding="utf-8") as log:
            log.write(json.dumps(frame) + "\n"); log.flush()
        method, identifier = frame.get("method"), frame.get("id")
        if identifier is None:
            continue
        if method == "initialize":
            emit({"id": identifier, "result": {"userAgent": options.get("userAgent", "coincide/0.163.0")}})
        elif method == "skills/list":
            skill_reads += 1
            worker = threading.Thread(target=answer_skills, args=(identifier, options.get("holdFirst", False) and skill_reads == 1))
            workers.append(worker); worker.start()
        elif method == "model/list":
            emit({"id": identifier, "result": {"data": [{"id": "synthetic-model"}], "nextCursor": None}})
        else:
            emit({"id": identifier, "error": {"code": -32601, "message": "The offline skill peer rejects mutations."}})
finally:
    closed.set()
    for worker in workers:
        worker.join(timeout=1)
