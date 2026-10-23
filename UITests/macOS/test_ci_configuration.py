"""Configuration checks run without launching a native app or touching user state.

Four isolated macOS runners partition all twenty-five workflows without sharing
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
        self.assertEqual(len(identifiers), 25)
        shards = [ci.shard_manifest(index, ci.UI_SHARD_COUNT, identifiers) for index in range(ci.UI_SHARD_COUNT)]
        flattened = [case for shard in shards for case in shard["testIdentifiers"]]
        self.assertEqual(sorted(flattened), identifiers)
        self.assertEqual(len(set(flattened)), len(flattened))
        self.assertEqual([len(shard["testIdentifiers"]) for shard in shards], [7, 6, 6, 6])
        for index, count in ((-1, 4), (4, 4), (0, 0), (0, 26), (True, 4), (0, False)):
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
            self.assertEqual(ci.verify_shards(root)["passedTests"], 25)
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
            result = subprocess.run(command[:command.index("--shard-index")] + ["--shard-count", "26", "--manifest", str(path)], text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_workflow_uses_isolated_serial_runners_keeps_failed_shards_and_enforces_aggregate(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github/workflows/swift.yml").read_text()
        shard = workflow.split("  native-ui-shard:\n", 1)[1].split("  native-ui:\n", 1)[0]
        gate = workflow.split("  native-ui:\n", 1)[1]
        self.assertIn("needs: [test, changes]", shard)
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
    def test_isolated_crash_probe_cannot_replace_full_coverage_or_hide_its_failure(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/swift.yml").read_text()
        isolation = workflow.split("      - name: Isolate the Codex executable inspection crash", 1)[1].split("      - name: Build and test", 1)[0]
        complete = workflow.split("      - name: Build and test", 1)[1].split("      - name: Collect sanitized", 1)[0]
        direct = workflow.split("      - name: Inspect the Codex executable directly", 1)[1].split("      - name: Isolate", 1)[0]
        self.assertIn("continue-on-error: true", direct)
        self.assertIn("shell: bash", direct)
        self.assertIn("--filter codexDirectExecutableInspectionChecksPrivateHomeVersionAndHelpWithoutInstallationClosure", direct)
        self.assertIn("Test run with 1 tests? in ", direct)
        self.assertIn("continue-on-error: true", isolation)
        self.assertIn("shell: bash", isolation)
        self.assertIn("--filter codexManagedInstallKeepsWholeResourceTreeAndChecksOnlyPrivateHomeVersionAndHelp", isolation)
        self.assertIn("Test run with 1 tests? in ", isolation)
        self.assertIn("swift test --no-parallel\n", complete)
        self.assertNotIn("--filter", complete)
        self.assertNotIn("continue-on-error", complete)
        enforced = workflow.split("      - name: Enforce the isolated Codex inspection result", 1)[1].split("      - name: Package", 1)[0]
        self.assertIn("if: always() && (steps.codex_inspection.outcome == 'failure' || steps.codex_direct_inspection.outcome == 'failure')", enforced)
        self.assertIn("exit 1", enforced)

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

    def test_claude_native_history_cases_are_additive_and_use_the_isolated_signed_peer(self):
        directory = Path(__file__).resolve().parent
        harness = (directory / "CoincideDesktopUITests.swift").read_text()
        project = (directory / "CoincideDesktopUITests.xcodeproj/project.pbxproj").read_text()
        launcher = (directory / "OfflineCLILauncher.swift").read_text()
        verifier = (directory / "verify_offline_launcher.py").read_text()
        peer = (directory / "claude_history_ui.py").read_text()
        self.assertEqual(harness.count("@MainActor func test"), 25)
        for name in ("testNativeClaudeForkAndDeferredRewindPreserveSourceWithoutSendingAcrossRestart",
                     "testNativeClaudeSelectedContextIsConsumedOnceBeforeQueuedSuccessor",
                     "testNativeClaudeContextInspectionIsReadOnlyAndNeverReplaysConsumedOrUnwrittenInput"):
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

    def test_pi_history_adds_three_offline_native_scenarios_and_keeps_strict_closed_world_launcher(self):
        directory = Path(__file__).parent
        harness = (directory / "CoincideDesktopUITests.swift").read_text()
        launcher = (directory / "OfflineCLILauncher.swift").read_text()
        project = (directory / "CoincideDesktopUITests.xcodeproj/project.pbxproj").read_text()
        verifier = (directory / "verify_offline_launcher.py").read_text()
        peer = (directory / "pi_history_ui.py").read_text()
        for name in ("testNativePiHistoryQuestionsUseExactWorkerAndCancellationNeverSendsDraft",
                     "testNativePiUnknownHistoryKeepsOriginalAcrossRestartWithoutRepeatingNativeFork",
                     "testNativePiEmptyContextRecoveryRequiresExplicitAcknowledgementAndNeverReplaysUnknownInput"):
            self.assertIn("func " + name + "() throws", harness)
        self.assertIn('path = pi_history_ui.py;', project)
        self.assertIn('"pi": ["pi_history_ui.py"]', launcher)
        self.assertIn('validPiArguments(arguments)', launcher)
        self.assertIn('privatePiDirectory(value, expected:', launcher)
        self.assertIn('Exact immutable Pi helper preflight.', harness)
        self.assertIn('Version/metadata inspection cannot create a persisted native session.', verifier)
        for value in ('publish-and-disconnect', 'before-write-disconnect', 'extension_ui_response', 'os.O_NOFOLLOW', 'os.O_EXCL'):
            self.assertIn(value, peer)
        for value in ('import socket', 'import urllib', 'import subprocess'):
            self.assertNotIn(value, peer)

    def test_change_filter_keeps_product_and_harness_paths_and_skips_unrelated_unit_docs(self):
        for path in ["Sources/Coincide/Views/ChatView.swift", "Sources/CoincideCore/WorkspaceEngine.swift", "UITests/macOS/Example.swift", "script/test_macos_ui.sh", "script/prepare_macos_signing.py", "Package.resolved"]:
            self.assertTrue(ci.needs_native_ui([path]), path)
        self.assertFalse(ci.needs_native_ui(["README.md", "Tests/CoincideCoreTests/WorkspaceTests.swift", "docs/VALIDATION.md"]))

    def test_results_require_twenty_five_real_tests_without_silent_skips(self):
        self.assertEqual(ci.verify_results(dict(totalTestCount=25, passedTests=25, failedTests=0, skippedTests=0)), 25)
        for summary in [dict(totalTestCount=26, passedTests=26, failedTests=0, skippedTests=0),
                        dict(totalTestCount=25, passedTests=24, failedTests=0, skippedTests=1),
                        dict(totalTestCount=25, passedTests=24, failedTests=1, skippedTests=0),
                        dict(totalTestCount=24, passedTests=24, failedTests=0, skippedTests=0),
                        dict(totalTestCount=23, passedTests=23, failedTests=0, skippedTests=0),
                        dict(totalTestCount=21, passedTests=21, failedTests=0, skippedTests=0),
                        dict(totalTestCount=21, passedTests=20, failedTests=0, skippedTests=1),
                        dict(totalTestCount=21, passedTests=20, failedTests=1, skippedTests=0),
                        dict(totalTestCount=20, passedTests=20, failedTests=0, skippedTests=0),
                        dict(totalTestCount=18, passedTests=18, failedTests=0, skippedTests=0),
                        dict(totalTestCount=18, passedTests=17, failedTests=0, skippedTests=1),
                        dict(totalTestCount=18, passedTests=17, failedTests=1, skippedTests=0),
                        dict(totalTestCount=17, passedTests=17, failedTests=0, skippedTests=0),
                        dict(totalTestCount=16, passedTests=16, failedTests=0, skippedTests=0),
                        dict(totalTestCount=16, passedTests=15, failedTests=0, skippedTests=1),
                        dict(totalTestCount=16, passedTests=15, failedTests=1, skippedTests=0),
                        dict(totalTestCount=15, passedTests=15, failedTests=0, skippedTests=0),
                        dict(totalTestCount=14, passedTests=14, failedTests=0, skippedTests=0),
                        dict(totalTestCount=14, passedTests=13, failedTests=0, skippedTests=1),
                        dict(totalTestCount=14, passedTests=13, failedTests=1, skippedTests=0),
                        dict(totalTestCount=13, passedTests=13, failedTests=0, skippedTests=0),
                        dict(totalTestCount=13, passedTests=12, failedTests=0, skippedTests=1),
                        dict(totalTestCount=13, passedTests=12, failedTests=1, skippedTests=0),
                        dict(totalTestCount=12, passedTests=12, failedTests=0, skippedTests=0),
                        dict(totalTestCount=12, passedTests=11, failedTests=0, skippedTests=1),
                        dict(totalTestCount=12, passedTests=11, failedTests=1, skippedTests=0),
                        dict(totalTestCount=11, passedTests=11, failedTests=0, skippedTests=0),
                        dict(totalTestCount=10, passedTests=10, failedTests=0, skippedTests=0),
                        dict(totalTestCount=0, passedTests=0, failedTests=0, skippedTests=0),
                        dict(totalTestCount=10, passedTests=9, failedTests=0, skippedTests=1),
                        dict(totalTestCount=10, passedTests=9, failedTests=1, skippedTests=0),
                        dict(totalTestCount=9, passedTests=9, failedTests=0, skippedTests=0),
                        dict(totalTestCount=8, passedTests=8, failedTests=0, skippedTests=0),
                        dict(totalTestCount=7, passedTests=7, failedTests=0, skippedTests=0),
                        dict(totalTestCount=6, passedTests=6, failedTests=0, skippedTests=0),
                        dict(totalTestCount=5, passedTests=5, failedTests=0, skippedTests=0),
                        dict(totalTestCount=4, passedTests=4, failedTests=0, skippedTests=0),
                        dict(totalTestCount=3, passedTests=3, failedTests=0, skippedTests=0),
                        dict(totalTestCount=2, passedTests=2, failedTests=0, skippedTests=0),
                        dict(totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0), {}]:
            with self.assertRaises(ValueError):
                ci.verify_results(summary)

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
