#!/usr/bin/env python3
"""Read-only change classification and explicit configuration of disposable UI test artifacts."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

TEST_BUNDLE_ID = "com.apoorvdarshan.coincide.uitesting"
TEST_TARGET = "CoincideDesktopUITests"


def needs_native_ui(paths):
    prefixes = ("Sources/", "UITests/macOS/")
    exact = {"Package.swift", "Package.resolved", "script/build_and_run.sh", "script/test_macos_ui.sh", "script/macos_ui_ci.py", ".github/workflows/swift.yml"}
    return any(path.startswith(prefixes) or path in exact for path in paths)


def test_targets(configuration):
    if "TestConfigurations" in configuration:
        return [target for group in configuration["TestConfigurations"] for target in group.get("TestTargets", [])]
    # Older Xcode emits one top-level dictionary per target.
    return [value for key, value in configuration.items() if not key.startswith("__") and isinstance(value, dict)]


def prepare_configuration(configuration, app, bootstrap, git):
    app, bootstrap, git = map(Path, (app, bootstrap, git))
    for path in (app, bootstrap):
        if not path.is_absolute() or not path.is_dir() or path.is_symlink():
            raise ValueError("UI artifact locations must be existing absolute directories without a final symlink.")
    if not bootstrap.name.startswith("coincide-ui-testing-"):
        raise ValueError("The bootstrap workspace must use the app's dedicated UI-testing prefix.")
    if not git.is_absolute() or not git.is_file() or not os.access(git, os.X_OK) or git == Path("/usr/bin/git"):
        raise ValueError("UI Git verification requires an absolute executable developer Git path, not the system shim.")
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleIdentifier") != TEST_BUNDLE_ID:
        raise ValueError("Refusing to launch an app without the disposable UI-testing bundle identifier.")
    all_targets = test_targets(configuration)
    targets = [target for target in all_targets if target.get("BlueprintName") == TEST_TARGET]
    if len(targets) != 1 or len(all_targets) != 1:
        raise ValueError("Expected exactly one native UI test target in the generated xctestrun file.")
    target = targets[0]
    previous_app = target.get("UITargetAppPath")
    if not previous_app:
        raise ValueError("The generated UI test target has no application path.")
    target["UITargetAppPath"] = str(app)
    target["UITargetAppBundleIdentifier"] = TEST_BUNDLE_ID
    target["DependentProductPaths"] = [str(app) if path == previous_app else path for path in target.get("DependentProductPaths", [])]
    target.setdefault("EnvironmentVariables", {}).update({
        "COINCIDE_UI_APP_PATH": str(app),
        "COINCIDE_UI_GIT_PATH": str(git),
    })
    # Keep even an automatic target-app launch away from the normal workspace.
    target.setdefault("UITargetAppEnvironmentVariables", {}).update({
        "COINCIDE_UI_TESTING": "1", "COINCIDE_UI_TEST_ROOT": str(bootstrap),
    })
    return configuration


def verify_results(summary, expected=4):
    counts = [summary.get(key) for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests")]
    if not all(type(value) is int for value in counts):
        raise ValueError("The xcresult summary is missing native test counts.")
    total, passed, failed, skipped = counts
    if total < expected or passed != total or failed != 0 or skipped != 0:
        raise ValueError(f"Native UI verification failed: total={total}, passed={passed}, failed={failed}, skipped={skipped}; at least {expected} passing tests are required.")
    return total


def classify_event(event, event_name):
    if event_name == "workflow_dispatch":
        return True
    if event_name == "pull_request":
        base, head = event["pull_request"]["base"]["sha"], event["pull_request"]["head"]["sha"]
        arguments = ["git", "diff", "--name-only", "-z", base + "..." + head]
    elif event_name == "push":
        base, head = event["before"], event["after"]
        arguments = (["git", "diff-tree", "--root", "--no-commit-id", "--name-only", "-r", "-z", head]
                     if set(base) == {"0"} else ["git", "diff", "--name-only", "-z", base, head])
    else:
        raise ValueError("Unsupported workflow event; native UI checks cannot be classified safely.")
    output = subprocess.run(arguments, check=True, stdout=subprocess.PIPE).stdout
    return needs_native_ui([path.decode("utf-8", "surrogateescape") for path in output.split(b"\0") if path])


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("changes")
    prepare = commands.add_parser("prepare")
    for name in ("xctestrun", "app", "bootstrap", "git"):
        prepare.add_argument("--" + name, required=True)
    results = commands.add_parser("verify-results"); results.add_argument("summary")
    arguments = parser.parse_args()
    if arguments.command == "changes":
        with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as handle:
            needed = classify_event(json.load(handle), os.environ["GITHUB_EVENT_NAME"])
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write("macos_ui=" + str(needed).lower() + "\n")
        print("Native UI checks required: " + str(needed).lower())
    elif arguments.command == "prepare":
        path = Path(arguments.xctestrun)
        with path.open("rb") as handle:
            configuration = prepare_configuration(plistlib.load(handle), arguments.app, arguments.bootstrap, arguments.git)
        with path.open("wb") as handle:
            plistlib.dump(configuration, handle)
    else:
        with open(arguments.summary, encoding="utf-8") as handle:
            count = verify_results(json.load(handle))
        print(f"Verified {count} native macOS UI tests, with zero failures or skipped tests.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print("Native UI harness: " + str(error), file=sys.stderr)
        sys.exit(1)
