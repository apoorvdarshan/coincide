"""Read-only, closed-world Codex model/default metadata for hosted native UI tests."""
import fcntl
import json
from pathlib import Path
import sys

state_path, wire_path = map(Path, sys.argv[1:3])
root = state_path.parent.resolve(strict=True)
if (not root.name.startswith("coincide-ui-testing-") or not state_path.is_absolute()
        or not wire_path.is_absolute() or wire_path.parent.resolve(strict=True) != root
        or state_path.is_symlink() or wire_path.is_symlink()):
    raise SystemExit("The model peer requires its private native UI fixture root.")


def catalog(state):
    def row(identifier, name, efforts, default, is_default=False):
        return dict(id="catalog-" + identifier, model=identifier, displayName=name,
            supportedReasoningEfforts=[dict(reasoningEffort=value, description="Offline advertised " + value) for value in efforts],
            defaultReasoningEffort=default, isDefault=is_default, hidden=False)
    updated = state.get("generation") == 2
    return [row("gpt-6-astra", "Offline Astra", ["low", "medium", "high"], "high", True),
        row("future-native-model", "Offline Future Refreshed" if updated else "Offline Future", ["light", "deep"] if updated else ["light", "deep", "experimental-effort"], "deep" if updated else "light"),
        row("future-cwd-model", "Offline CWD Default", ["light", "deep"], "light")]


for line in sys.stdin:
    if len(line) > 4_194_304:
        raise SystemExit("The offline metadata frame exceeds its fixture limit.")
    frame = json.loads(line)
    if "id" not in frame:
        continue
    if state_path.stat().st_size > 4_194_304:
        raise SystemExit("The offline metadata state exceeds its fixture limit.")
    state = json.loads(state_path.read_text(encoding="utf-8"))
    checkout = Path(state["cwd"])
    if not checkout.is_absolute() or checkout.is_symlink() or checkout.resolve(strict=True).parent != root or not checkout.is_dir():
        raise SystemExit("The metadata checkout must be a real private fixture directory.")
    with wire_path.open("a", encoding="utf-8") as wire:
        fcntl.flock(wire, fcntl.LOCK_EX)
        wire.write(json.dumps(frame) + "\n"); wire.flush()
    method, params = frame["method"], frame.get("params") or {}
    try:
        if method == "initialize":
            result = dict(userAgent="coincide/0.163.0 (macos; fixture)", codexHome=str(root), platformFamily="unix", platformOs="macos")
        elif method == "model/list":
            if params != dict(limit=100, includeHidden=False):
                raise ValueError("The native catalog must use its exact read-only visible-model request.")
            result = dict(data=catalog(state), nextCursor=None)
        elif method == "config/read":
            if (set(params) != {"cwd", "includeLayers"} or params["includeLayers"] is not False
                    or Path(params["cwd"]).resolve(strict=True) != checkout.resolve(strict=True)):
                raise ValueError("CLI defaults must be read only for this exact private checkout.")
            result = dict(config=dict(model="future-cwd-model", model_reasoning_effort="deep", model_provider="openai"))
        else:
            raise ValueError("The offline metadata peer forbids provider input and configuration mutations.")
    except (KeyError, ValueError, TypeError, OSError) as error:
        reply = dict(id=frame["id"], error=dict(code=-32602, message=str(error)))
    else:
        reply = dict(id=frame["id"], result=result)
    print(json.dumps(reply), flush=True)
