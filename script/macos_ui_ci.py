#!/usr/bin/env python3
"""Read-only change classification and explicit configuration of disposable UI test artifacts."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

TEST_BUNDLE_ID = "com.apoorvdarshan.coincide.uitesting"
TEST_TARGET = "CoincideDesktopUITests"
UI_SHARD_COUNT = 4
MINIMUM_TEST_COUNT = 28
TEST_SOURCE = Path(__file__).resolve().parents[1] / "UITests/macOS/CoincideDesktopUITests.swift"


def native_test_identifiers(source=None):
    """Discover every XCTest method; unsupported declarations must fail closed."""
    source = TEST_SOURCE.read_text(encoding="utf-8") if source is None else source
    declarations = re.findall(r"\bfunc\s+(test\w+)\s*\(", source)
    names = re.findall(r"@MainActor\s+func\s+(test\w+)\s*\(\s*\)\s*throws\s*\{", source)
    if len(names) < MINIMUM_TEST_COUNT or len(names) != len(set(names)) or sorted(names) != sorted(declarations):
        raise ValueError("Native UI discovery requires every test method exactly once in the supported XCTest form.")
    return [TEST_TARGET + "/" + name for name in sorted(names)]


def shard_manifest(index, count, identifiers=None):
    identifiers = native_test_identifiers() if identifiers is None else identifiers
    if type(index) is not int or type(count) is not int or not 0 <= index < count <= len(identifiers):
        raise ValueError("Native UI shard index/count is invalid or would produce an empty shard.")
    if len(identifiers) != len(set(identifiers)):
        raise ValueError("Native UI test identifiers must be unique.")
    return {"shardIndex": index, "shardCount": count, "testIdentifiers": identifiers[index::count]}


def verify_test_identifiers(report, expected):
    """Use xcresult identities as well as counts so a wrong/duplicate selection cannot pass."""
    observed = []

    def visit(nodes):
        if not isinstance(nodes, list):
            raise ValueError("Native UI test report has no valid test-node list.")
        for node in nodes:
            if not isinstance(node, dict):
                raise ValueError("Native UI test report contains an invalid node.")
            if node.get("nodeType") == "Repetition":
                raise ValueError("Native UI tests must run once without repetitions.")
            if node.get("nodeType") == "Test Case":
                identifier = node.get("nodeIdentifier", "")
                if not isinstance(identifier, str) or not identifier.endswith("()") or node.get("result") != "Passed":
                    raise ValueError("Every selected native UI test must have a passing XCTest identity.")
                observed.append(identifier[:-2])
                if sum(child.get("nodeType") == "Test Case Run" for child in node.get("children", [])) > 1:
                    raise ValueError("Native UI tests must not be retried.")
            visit(node.get("children", []))

    visit(report.get("testNodes"))
    if len(observed) != len(set(observed)) or sorted(observed) != sorted(expected):
        raise ValueError("The native UI result identities do not match the assigned tests exactly once.")
    return observed


def verify_shards(directory, count=UI_SHARD_COUNT):
    identifiers = native_test_identifiers()
    manifests = sorted(Path(directory).glob("*/selection.json"))
    if len(manifests) != count:
        raise ValueError(f"Expected {count} native UI shard artifacts, found {len(manifests)}.")
    observed, indexes = [], []
    for path in manifests:
        manifest = json.loads(path.read_text(encoding="utf-8"))
        index = manifest.get("shardIndex")
        if manifest != shard_manifest(index, count, identifiers):
            raise ValueError("A native UI shard manifest differs from the complete source partition.")
        indexes.append(index)
        summary = json.loads(path.with_name("summary.json").read_text(encoding="utf-8"))
        tests = json.loads(path.with_name("tests.json").read_text(encoding="utf-8"))
        verify_results(summary, expected=len(manifest["testIdentifiers"]))
        observed.extend(verify_test_identifiers(tests, manifest["testIdentifiers"]))
    if sorted(indexes) != list(range(count)) or len(observed) != len(set(observed)) or sorted(observed) != identifiers:
        raise ValueError("Native UI shards must cover every source test exactly once.")
    return {"shardCount": count, "passedTests": len(observed), "failedTests": 0, "skippedTests": 0, "testIdentifiers": sorted(observed)}


def needs_native_ui(paths):
    prefixes = ("Sources/", "UITests/macOS/")
    exact = {"Package.swift", "Package.resolved", "script/build_and_run.sh", "script/prepare_macos_signing.py", "script/test_macos_ui.sh", "script/macos_ui_ci.py", ".github/workflows/swift.yml",
             "script/Info.plist.template", "script/generate_app_icon.swift", "VERSION", "docs/third-party-notices.json"}
    return any(path.startswith(prefixes) or path in exact or (path.startswith("docs/") and path.endswith(("-LICENSE.txt", "-NOTICE.txt"))) for path in paths)


def test_targets(configuration):
    if "TestConfigurations" in configuration:
        return [target for group in configuration["TestConfigurations"] for target in group.get("TestTargets", [])]
    # Older Xcode emits one top-level dictionary per target.
    return [value for key, value in configuration.items() if not key.startswith("__") and isinstance(value, dict)]


def prepare_configuration(configuration, app, bootstrap, git, python):
    app, bootstrap, git, python = map(Path, (app, bootstrap, git, python))
    for path in (app, bootstrap):
        if not path.is_absolute() or not path.is_dir() or path.is_symlink():
            raise ValueError("UI artifact locations must be existing absolute directories without a final symlink.")
    if not bootstrap.name.startswith("coincide-ui-testing-"):
        raise ValueError("The bootstrap workspace must use the app's dedicated UI-testing prefix.")
    if not git.is_absolute() or not git.is_file() or not os.access(git, os.X_OK) or git == Path("/usr/bin/git"):
        raise ValueError("UI Git verification requires an absolute executable developer Git path, not the system shim.")
    if not python.is_absolute() or not python.is_file() or not os.access(python, os.X_OK) or python == Path("/usr/bin/python3"):
        raise ValueError("The offline UI provider requires an absolute executable Python path, not the system shim.")
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
        "COINCIDE_UI_PYTHON_PATH": str(python),
    })
    # Keep even an automatic target-app launch away from the normal workspace.
    target.setdefault("UITargetAppEnvironmentVariables", {}).update({
        "COINCIDE_UI_TESTING": "1", "COINCIDE_UI_TEST_ROOT": str(bootstrap),
    })
    return configuration


def verify_results(summary, expected=MINIMUM_TEST_COUNT):
    counts = [summary.get(key) for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests")]
    if not all(type(value) is int for value in counts):
        raise ValueError("The xcresult summary is missing native test counts.")
    total, passed, failed, skipped = counts
    if type(expected) is not int or expected <= 0 or total != expected or passed != total or failed != 0 or skipped != 0:
        raise ValueError(f"Native UI verification failed: total={total}, passed={passed}, failed={failed}, skipped={skipped}; exactly {expected} passing tests are required.")
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
    for name in ("xctestrun", "app", "bootstrap", "git", "python"):
        prepare.add_argument("--" + name, required=True)
    plan = commands.add_parser("plan")
    plan.add_argument("--shard-index", type=int, default=0)
    plan.add_argument("--shard-count", type=int, default=1)
    plan.add_argument("--manifest", required=True)
    results = commands.add_parser("verify-results"); results.add_argument("summary")
    results.add_argument("--tests", required=True)
    results.add_argument("--manifest", required=True)
    shards = commands.add_parser("verify-shards"); shards.add_argument("directory")
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
            configuration = prepare_configuration(plistlib.load(handle), arguments.app, arguments.bootstrap, arguments.git, arguments.python)
        with path.open("wb") as handle:
            plistlib.dump(configuration, handle)
    elif arguments.command == "plan":
        manifest = shard_manifest(arguments.shard_index, arguments.shard_count)
        Path(arguments.manifest).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        for identifier in manifest["testIdentifiers"]:
            print("-only-testing:" + TEST_TARGET + "/" + identifier)
    elif arguments.command == "verify-shards":
        print(json.dumps(verify_shards(arguments.directory), indent=2))
    else:
        manifest = json.loads(Path(arguments.manifest).read_text(encoding="utf-8"))
        if manifest != shard_manifest(manifest.get("shardIndex"), manifest.get("shardCount")):
            raise ValueError("The native UI selection manifest differs from the source tests.")
        with open(arguments.summary, encoding="utf-8") as handle:
            count = verify_results(json.load(handle), expected=len(manifest["testIdentifiers"]))
        verify_test_identifiers(json.loads(Path(arguments.tests).read_text(encoding="utf-8")), manifest["testIdentifiers"])
        print(f"Verified {count} native macOS UI tests, with zero failures or skipped tests.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print("Native UI harness: " + str(error), file=sys.stderr)
        sys.exit(1)
