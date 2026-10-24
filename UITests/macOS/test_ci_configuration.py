"""Configuration checks run without launching a native app or touching user state.

Four isolated macOS runners partition every discovered native workflow without sharing
a desktop. Counts and xcresult identities must match each shard, and the final
gate requires complete, unique coverage across every shard. Individual test and
command deadlines remain unchanged.
After a failed production suite, diagnostic-only report arrival polling is
capped at thirty seconds; it never reruns tests or changes their result.
"""
import copy
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import subprocess
import sys
import unittest

spec = importlib.util.spec_from_file_location("macos_ui_ci", Path(__file__).resolve().parents[2] / "script/macos_ui_ci.py")
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


class NativeUIConfigurationTests(unittest.TestCase):
    def test_shards_partition_every_source_case_once_and_reject_invalid_or_empty_selections(self):
        identifiers = ci.native_test_identifiers()
        self.assertGreaterEqual(len(identifiers), ci.MINIMUM_TEST_COUNT)
        shards = [ci.shard_manifest(index, ci.UI_SHARD_COUNT, identifiers) for index in range(ci.UI_SHARD_COUNT)]
        flattened = [case for shard in shards for case in shard["testIdentifiers"]]
        self.assertEqual(sorted(flattened), identifiers)
        self.assertEqual(len(set(flattened)), len(flattened))
        sizes = [len(shard["testIdentifiers"]) for shard in shards]
        self.assertTrue(all(sizes))
        self.assertLessEqual(max(sizes) - min(sizes), 1)
        for index, count in ((-1, 4), (4, 4), (0, 0), (0, len(identifiers) + 1), (True, 4), (0, False)):
            with self.assertRaises(ValueError):
                ci.shard_manifest(index, count, identifiers)
        with self.assertRaises(ValueError):
            ci.shard_manifest(0, 4, identifiers + identifiers[:1])
        source = ci.TEST_SOURCE.read_text()
        for invalid in (source.replace("@MainActor func test", "func test", 1), source + "\nfunc testUnsupported() {}",
                        source.replace("func testNativeMainWindowCloseNewWindowAndReopenPreserveUnsentWorkspace() throws", "func testNativeMainWindowCloseNewWindowAndReopenPreserveUnsentWorkspace()", 1)):
            with self.assertRaises(ValueError):
                ci.native_test_identifiers(invalid)

    @staticmethod
    def report(identifiers):
        return {"testNodes": [{"nodeType": "Test Plan", "name": "Plan", "children": [
            {"nodeType": "Test Case", "nodeIdentifier": name + "()", "name": name.rsplit("/", 1)[-1] + "()", "result": "Passed"}
            for name in identifiers]}]}

    def test_result_identity_gate_rejects_wrong_duplicate_missing_skipped_failed_or_retried_cases(self):
        identifiers = ci.shard_manifest(0, 4)["testIdentifiers"]
        report = self.report(identifiers)
        self.assertEqual(ci.verify_test_identifiers(report, identifiers), identifiers)
        bad_reports = [{}, {"testNodes": None}]
        for result in ("Failed", "Skipped", "Expected Failure", "unknown", None):
            value = copy.deepcopy(report)
            value["testNodes"][0]["children"][0]["result"] = result
            bad_reports.append(value)
        for cases in (identifiers[:-1], identifiers + identifiers[:1], ["OtherTests/testUnexpected"] + identifiers[1:]):
            bad_reports.append(self.report(cases))
        repeated = copy.deepcopy(report)
        repeated["testNodes"][0]["children"][0]["children"] = [{"nodeType": "Test Case Run"}] * 2
        bad_reports.append(repeated)
        repetition = copy.deepcopy(report)
        repetition["testNodes"][0]["children"].append({"nodeType": "Repetition"})
        bad_reports.append(repetition)
        for value in bad_reports:
            with self.assertRaises(ValueError):
                ci.verify_test_identifiers(value, identifiers)

    def write_shard(self, root, index):
        directory = root / ("shard-" + str(index))
        directory.mkdir(exist_ok=True)
        manifest = ci.shard_manifest(index, 4)
        (directory / "selection.json").write_text(json.dumps(manifest))
        size = len(manifest["testIdentifiers"])
        (directory / "summary.json").write_text(json.dumps(dict(totalTestCount=size, passedTests=size, failedTests=0, skippedTests=0)))
        (directory / "tests.json").write_text(json.dumps(self.report(manifest["testIdentifiers"])))
        return directory

    def test_aggregate_requires_all_shards_exact_manifests_and_all_real_passing_results(self):
        with tempfile.TemporaryDirectory(prefix="coincide-ui-shards-") as directory:
            root = Path(directory)
            for index in range(3):
                self.write_shard(root, index)
            with self.assertRaises(ValueError):
                ci.verify_shards(root)
            last = self.write_shard(root, 3)
            self.assertEqual(ci.verify_shards(root)["passedTests"], len(ci.native_test_identifiers()))
            self.assertEqual(ci.verify_shards(root)["testIdentifiers"], ci.native_test_identifiers())
            (last / "selection.json").write_text(json.dumps(ci.shard_manifest(2, 4)))
            with self.assertRaises(ValueError):
                ci.verify_shards(root)
            self.write_shard(root, 3)
            (last / "summary.json").write_text(json.dumps(dict(totalTestCount=0, passedTests=0, failedTests=0, skippedTests=0)))
            with self.assertRaises(ValueError):
                ci.verify_shards(root)
            self.write_shard(root, 3)
            (last / "tests.json").write_text(json.dumps(self.report(ci.shard_manifest(2, 4)["testIdentifiers"])))
            with self.assertRaises(ValueError):
                ci.verify_shards(root)

    def test_command_line_plan_generates_only_exact_xcode_selections_and_fails_empty_requests(self):
        with tempfile.TemporaryDirectory(prefix="coincide-ui-plan-") as directory:
            path = Path(directory) / "selection.json"
            command = [sys.executable, str(ci.TEST_SOURCE.parents[2] / "script/macos_ui_ci.py"), "plan",
                       "--shard-index", "1", "--shard-count", "4", "--manifest", str(path)]
            result = subprocess.run(command, check=True, text=True, capture_output=True)
            manifest = json.loads(path.read_text())
            self.assertEqual(manifest, ci.shard_manifest(1, 4))
            self.assertEqual(result.stdout.splitlines(), ["-only-testing:" + ci.TEST_TARGET + "/" + case for case in manifest["testIdentifiers"]])
            result = subprocess.run(command[:command.index("--shard-index")] + ["--shard-count", str(len(ci.native_test_identifiers()) + 1), "--manifest", str(path)], text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_workflow_uses_isolated_serial_runners_keeps_failed_shards_and_enforces_aggregate(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github/workflows/swift.yml").read_text()
        shard = workflow.split("  native-ui-shard:\n", 1)[1].split("  native-ui:\n", 1)[0]
        gate = workflow.split("  native-ui:\n", 1)[1]
        self.assertIn("needs: [build, changes]", shard)
        self.assertIn("fail-fast: false", shard)
        self.assertIn("shard: [0, 1, 2, 3]", shard)
        self.assertIn('--shard-index "${{ matrix.shard }}" --shard-count 4', shard)
        self.assertIn("coincide-native-app-${{ github.sha }}", shard)
        self.assertNotIn("swift test", shard)
        self.assertIn("if-no-files-found: error", shard)
        self.assertIn("needs: [native-ui-shard, changes]", gate)
        self.assertIn("verify-shards", gate)
        self.assertIn("needs.native-ui-shard.result != 'success'", gate)
        runner = (root / "script/test_macos_ui.sh").read_text()
        self.assertIn("-parallel-testing-enabled NO", runner)
        self.assertNotIn("-retry-tests-on-failure", runner)
        self.assertIn('"${TEST_SELECTION[@]}"', runner)
        self.assertIn("get test-results tests", runner)
        self.assertIn('--manifest "$ARTIFACTS/selection.json"', runner)
    def test_swift_compile_and_execution_use_the_same_exact_built_cache_and_toolchain(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/swift.yml").read_text()
        build = workflow.split("  build:\n", 1)[1].split("  test:\n", 1)[0]
        tests = workflow.split("  test:\n", 1)[1].split("  native-ui-shard:\n", 1)[0]
        key = "swift-built-v2-${{ runner.os }}-${{ runner.arch }}-${{ hashFiles('Package.swift', 'Package.resolved') }}-${{ github.sha }}"
        self.assertIn("runs-on: macos-26", build)
        self.assertIn("timeout-minutes: 35", build)
        self.assertIn("swift test list >", build)
        self.assertIn('test -s "$RUNNER_TEMP/coincide-swift-test-list.txt"', build)
        self.assertNotIn("--filter", build)
        self.assertIn("swift --version > .build/coincide-swift-toolchain.txt", build)
        self.assertIn("actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9", build)
        self.assertIn("key: " + key, build)
        self.assertIn("needs: [build]", tests)
        self.assertIn("timeout-minutes: 35", tests)
        self.assertIn("actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9", tests)
        self.assertIn("key: " + key, tests)
        self.assertIn("fail-on-cache-miss: true", tests)
        self.assertNotIn("restore-keys:", tests)
        self.assertIn('cmp .build/coincide-swift-toolchain.txt "$RUNNER_TEMP/coincide-swift-toolchain-current.txt"', tests)
        self.assertLess(tests.index("cmp .build/coincide-swift-toolchain.txt"), tests.index("swift test --skip-build"))
        # One complete, unfiltered run; no probe can replace or duplicate it.
        self.assertEqual(tests.count("swift test --skip-build --no-parallel"), 1)
        self.assertIn("swift test --skip-build --no-parallel\n", tests)
        self.assertNotIn("--filter", tests)
        self.assertNotIn("continue-on-error: true\n        run: |\n          swift test", tests)
        self.assertNotIn("swift test --no-parallel", tests)
        # The app is packaged once with the build so desktop UI shards need not wait for tests.
        self.assertIn("Package the native app", build)
        self.assertNotIn("Package the native app", tests)
        self.assertIn("coincide-native-app-${{ github.sha }}", build)
        self.assertIn("Verify async default closure contexts", tests)

    def test_offline_tools_are_built_signed_and_immutable_inside_the_test_bundle(self):
        directory = Path(__file__).resolve().parent
        project = (directory / "CoincideDesktopUITests.xcodeproj/project.pbxproj").read_text()
        harness = (directory / "CoincideDesktopUITests.swift").read_text()
        launcher = (directory / "OfflineCLILauncher.swift").read_text()
        script = (directory.parents[1] / "script/test_macos_ui.sh").read_text()
        self.assertIn('productType = "com.apple.product-type.tool"', project)
        self.assertEqual(project.count('CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO'), 2)
        self.assertIn('path = CoincideOfflineCLI; sourceTree = BUILT_PRODUCTS_DIR', project)
        self.assertIn('createSymbolicLink(at: executable, withDestinationURL: helper)', harness)
        self.assertNotIn('#!/bin/sh\\nexec ', harness)
        self.assertIn('app.launchEnvironment["COINCIDE_UI_PYTHON_PATH"] = python', harness)
        self.assertIn('cmp "$helper" "$embedded"', script)
        self.assertIn('codesign --verify --strict "$embedded"', script)
        self.assertIn('"-I", "-S", peer.path', launcher)
        self.assertIn('O_NOFOLLOW | O_NONBLOCK', launcher)
        self.assertIn('Set(object.keys) ==', launcher)
        self.assertIn('execv(expectedPython', launcher)
        for forbidden in ('Process(', 'fork(', 'system(', 'posix_spawn('):
            self.assertNotIn(forbidden, launcher)

    def test_claude_approval_flow_and_provider_settings_use_the_isolated_signed_peer(self):
        directory = Path(__file__).resolve().parent
        harness = (directory / "CoincideDesktopUITests.swift").read_text()
        project = (directory / "CoincideDesktopUITests.xcodeproj/project.pbxproj").read_text()
        launcher = (directory / "OfflineCLILauncher.swift").read_text()
        verifier = (directory / "verify_offline_launcher.py").read_text()
        peer = (directory / "claude_history_ui.py").read_text()
        self.assertEqual(harness.count("@MainActor func test"), len(ci.native_test_identifiers()))
        for name in ("testNativeClaudeQuestionSingleMultiCustomNotesAndCancellationPersistExactAnswers",
                     "testNativeClaudeConfigurationPreservesCredentialsAndUnknownHooks",
                     "testNativeSessionsImportExplainsCopiedOwnershipWithoutScanningAutomatically"):
            self.assertIn("func " + name + "() throws", harness)
        self.assertIn('path = claude_history_ui.py;', project)
        self.assertIn('"claude": ["claude_history_ui.py"]', launcher)
        self.assertIn('validClaudeArguments(arguments)', launcher)
        self.assertIn('("CLAUDE_CONFIG_DIR", "private-claude-config")', launcher)
        self.assertIn('("HOME", "private-claude-home")', launcher)
        self.assertIn('Initialize-only metadata cannot invent a native transcript.', verifier)
        self.assertIn('Rejected Claude argv/namespaces must not reach the peer.', verifier)
        self.assertIn('consume-then-disconnect', peer)
        self.assertIn('before-write-disconnect', peer)
        self.assertIn('os.O_NOFOLLOW', peer)
        self.assertNotIn('import urllib', peer)
        self.assertNotIn('import socket', peer)
        self.assertNotIn('subprocess', peer)

    def test_change_filter_keeps_product_and_harness_paths_and_skips_unrelated_unit_docs(self):
        for path in ["Sources/Coincide/Views/ChatView.swift", "Sources/CoincideCore/WorkspaceEngine.swift", "UITests/macOS/Example.swift", "script/test_macos_ui.sh", "script/prepare_macos_signing.py", "Package.resolved", "script/Info.plist.template", "script/generate_app_icon.swift", "VERSION", "docs/third-party-notices.json", "docs/SwiftMathFonts-OFL-LICENSE.txt", "docs/SwiftMarkdown-NOTICE.txt"]:
            self.assertTrue(ci.needs_native_ui([path]), path)
        self.assertFalse(ci.needs_native_ui(["README.md", "Tests/CoincideCoreTests/WorkspaceTests.swift", "docs/VALIDATION.md"]))

    def test_swift_filter_matches_push_paths_and_skips_docs_and_fuzz_only_changes(self):
        for path in ["Sources/CoincideCore/Models.swift", "Tests/CoincideCoreTests/WorkspaceTests.swift", "UITests/macOS/cli_e2e.py",
                     "script/coincide", "Package.swift", "Package.resolved", ".github/workflows/swift.yml", "VERSION",
                     "docs/T3-CODE-LICENSE.txt", "docs/SwiftTerm-LICENSE.txt", "docs/YAMS-NOTICE.txt", "docs/third-party-notices.json"]:
            self.assertTrue(ci.needs_swift([path]), path)
        for path in ["README.md", "docs/VALIDATION.md", "Tests/Fuzz/coincide_cli_fuzzer.py", ".github/workflows/codeql.yml", "LICENSE", "SECURITY.md"]:
            self.assertFalse(ci.needs_swift([path]), path)
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/swift.yml").read_text()
        push_paths = workflow.split("  push:\n", 1)[1].split("\n", 2)[1]
        for pattern in ("'Sources/**'", "'Tests/**'", "'!Tests/Fuzz/**'", "'UITests/**'", "'script/**'", "'VERSION'"):
            self.assertIn(pattern, push_paths)

    def test_single_required_gate_always_reports_and_requires_applicable_jobs(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/swift.yml").read_text()
        pull = workflow.split("  pull_request:\n", 1)[1].split("  workflow_dispatch:", 1)[0]
        self.assertNotIn("paths:", pull, "Pull requests must always run so the required ci check reports.")
        build = workflow.split("  build:\n", 1)[1].split("  test:\n", 1)[0]
        self.assertIn("needs: [changes]", build)
        self.assertIn("if: needs.changes.outputs.swift == 'true'", build)
        gate = workflow.split("  ci:\n", 1)[1]
        self.assertIn("if: always()", gate)
        self.assertIn("needs: [changes, build, test, cli-e2e, native-ui]", gate)
        for value in ('"build", "test", "cli-e2e"', 'required.append("native-ui")', '("failure", "cancelled")'):
            self.assertIn(value, gate)

    def test_results_require_every_discovered_test_without_silent_skips(self):
        count = len(ci.native_test_identifiers())
        self.assertEqual(ci.verify_results(dict(totalTestCount=count, passedTests=count, failedTests=0, skippedTests=0), expected=count), count)
        for total in range(count + 2):
            if total == count:
                continue
            with self.assertRaises(ValueError):
                ci.verify_results(dict(totalTestCount=total, passedTests=total, failedTests=0, skippedTests=0), expected=count)
        for summary in (dict(totalTestCount=count, passedTests=count-1, failedTests=0, skippedTests=1),
                        dict(totalTestCount=count, passedTests=count-1, failedTests=1, skippedTests=0), {},
                        dict(totalTestCount=count, passedTests=count, failedTests=False, skippedTests=0)):
            with self.assertRaises(ValueError):
                ci.verify_results(summary, expected=count)

    def test_preparation_targets_only_disposable_app_and_preserves_runner_paths(self):
        with tempfile.TemporaryDirectory(prefix="coincide-ui-config-") as directory:
            root = Path(directory).resolve()
            app, bootstrap = [root / name for name in ("Copy.app", "coincide-ui-testing-bootstrap")]
            for path in (app / "Contents", bootstrap):
                path.mkdir(parents=True)
            git = root / "developer-git"
            git.write_text("#!/bin/sh\nexit 0\n")
            git.chmod(0o700)
            info = app / "Contents/Info.plist"
            info.write_bytes(plistlib.dumps({"CFBundleIdentifier": ci.TEST_BUNDLE_ID}))
            original = {"TestConfigurations": [{"TestTargets": [{"BlueprintName": ci.TEST_TARGET, "UITargetAppPath": "__TESTROOT__/Debug/Placeholder.app",
                "TestHostPath": "__TESTROOT__/Debug/Runner.app", "TestBundlePath": "__TESTHOST__/PlugIns/Tests.xctest",
                "DependentProductPaths": ["__TESTROOT__/Debug/Placeholder.app", "__TESTROOT__/Debug/Runner.app"],
                "EnvironmentVariables": {"EXISTING": "kept"}}]}]}
            value = ci.prepare_configuration(copy.deepcopy(original), app, bootstrap, git, git)
            target = value["TestConfigurations"][0]["TestTargets"][0]
            self.assertEqual(target["UITargetAppPath"], str(app))
            self.assertEqual(target["DependentProductPaths"], [str(app), "__TESTROOT__/Debug/Runner.app"])
            self.assertEqual(target["TestHostPath"], "__TESTROOT__/Debug/Runner.app")
            self.assertEqual(target["EnvironmentVariables"]["EXISTING"], "kept")
            self.assertEqual(target["EnvironmentVariables"]["COINCIDE_UI_APP_PATH"], str(app))
            self.assertEqual(target["EnvironmentVariables"]["COINCIDE_UI_GIT_PATH"], str(git))
            self.assertEqual(target["EnvironmentVariables"]["COINCIDE_UI_PYTHON_PATH"], str(git))
            self.assertNotIn("COINCIDE_UI_TEST_ROOT_BASE", target["EnvironmentVariables"])
            self.assertNotIn("COINCIDE_UI_ARTIFACTS", target["EnvironmentVariables"])
            self.assertEqual(target["UITargetAppEnvironmentVariables"]["COINCIDE_UI_TEST_ROOT"], str(bootstrap))
            legacy = {ci.TEST_TARGET: copy.deepcopy(original["TestConfigurations"][0]["TestTargets"][0]), "__xctestrun_metadata__": {"FormatVersion": 1}}
            legacy_value = ci.prepare_configuration(legacy, app, bootstrap, git, git)
            self.assertEqual(legacy_value[ci.TEST_TARGET]["UITargetAppPath"], str(app))
            info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.apoorvdarshan.coincide"}))
            with self.assertRaises(ValueError):
                ci.prepare_configuration(copy.deepcopy(original), app, bootstrap, git, git)
            info.write_bytes(plistlib.dumps({"CFBundleIdentifier": ci.TEST_BUNDLE_ID}))
            duplicate = copy.deepcopy(original)
            duplicate["TestConfigurations"][0]["TestTargets"] *= 2
            with self.assertRaises(ValueError):
                ci.prepare_configuration(duplicate, app, bootstrap, git, git)
            other_target = copy.deepcopy(original)
            other_target["TestConfigurations"][0]["TestTargets"].append({"BlueprintName": "UnexpectedUITests"})
            with self.assertRaises(ValueError):
                ci.prepare_configuration(other_target, app, bootstrap, git, git)
            with self.assertRaises(ValueError):
                ci.prepare_configuration(copy.deepcopy(original), app, root, git, git)
            for invalid_git in ("relative/git", root / "missing-git", root, "/usr/bin/git"):
                with self.assertRaises(ValueError):
                    ci.prepare_configuration(copy.deepcopy(original), app, bootstrap, invalid_git, git)
            for invalid_python in ("relative/python", root / "missing-python", root, "/usr/bin/python3"):
                with self.assertRaises(ValueError):
                    ci.prepare_configuration(copy.deepcopy(original), app, bootstrap, git, invalid_python)
            git.chmod(0o600)
            with self.assertRaises(ValueError):
                ci.prepare_configuration(copy.deepcopy(original), app, bootstrap, git, git)


if __name__ == "__main__":
    unittest.main()
