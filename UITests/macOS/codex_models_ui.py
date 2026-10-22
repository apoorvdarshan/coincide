"""Read-only, closed-world Codex model/default/skill metadata for native UI tests."""
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
        elif method == "skills/list":
            if (state.get("skillsUI") is not True or not isinstance(frame.get("params"), dict)
                    or set(params) != {"cwds", "forceReload"} or params["cwds"] != [str(checkout)]
                    or type(params["forceReload"]) is not bool):
                raise ValueError("Skills require an explicit fixture and the exact bounded workspace read.")
            def skill(name, description, enabled=True):
                return dict(name=name, path=str(checkout / ".codex" / "skills" / name / "SKILL.md"),
                    description=description, scope="repo", enabled=enabled)
            rows = [skill("review-changes", "Review the current workspace"),
                    skill("ship-check", "Inspect packaging"),
                    skill("disabled-skill", "Must never be offered", enabled=False),
                    skill("7k", "A currency-shaped name is not an invocable token")]
            if state.get("generation") == 2:
                rows.append(skill("fresh-check", "A newly discovered workspace skill"))
            result = dict(data=[dict(cwd=str(checkout), skills=rows,
                errors=[dict(path=str(checkout / ".codex" / "skills" / "broken"),
                             message="PRIVATE_SKILL_DIAGNOSTIC_CANARY")])])
        elif method == "account/read":
            if (not isinstance(frame.get("params"), dict) or set(params) != {"refreshToken"}
                    or params["refreshToken"] is not False):
                raise ValueError("The offline account check forbids credential refresh and accepts only refreshToken:false.")
            result = dict(account=dict(type="chatgpt", email="native-ui@example.invalid", planType="Offline Hosted Plus"),
                requiresOpenaiAuth=True, workspaceRouting=dict(chatgptAccountId="offline-native-model-account"))
        elif method == "account/rateLimits/read":
            if not isinstance(frame.get("params"), dict) or params:
                raise ValueError("The offline usage check accepts only an empty read request.")
            result = dict(rateLimits=dict(limitId="codex", limitName="Offline Hosted Allowance",
                primary=dict(usedPercent=25, windowDurationMins=300, resetsAt=4102444800),
                secondary=dict(usedPercent=40, windowDurationMins=10080, resetsAt=4103049600),
                credits=dict(hasCredits=True, unlimited=False, balance="12")),
                ordinaryUsageAllowed=True, accountId="offline-native-model-account")
        else:
            raise ValueError("The offline metadata peer forbids provider input, sign-in, sign-out and configuration mutations.")
    except (KeyError, ValueError, TypeError, OSError) as error:
        reply = dict(id=frame["id"], error=dict(code=-32602, message=str(error)))
    else:
        reply = dict(id=frame["id"], result=result)
    print(json.dumps(reply), flush=True)
