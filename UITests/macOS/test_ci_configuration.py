"""Configuration checks run without launching a native app or touching user state.

The native job has a 45-minute whole-suite budget after the fourteen-workflow
run used 29m59s with five paths still failing early. Individual test/command
deadlines and all fourteen scenarios stay unchanged. Two explicit authentication
settings scenarios and two skills workflows bring the zero-skip result gate to eighteen.
After a failed production suite, diagnostic-only report arrival polling is
capped at thirty seconds; it never reruns tests or changes their result.
"""
import copy
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("macos_ui_ci", Path(__file__).resolve().parents[2] / "script/macos_ui_ci.py")
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


class NativeUIConfigurationTests(unittest.TestCase):
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

    def test_change_filter_keeps_product_and_harness_paths_and_skips_unrelated_unit_docs(self):
        for path in ["Sources/Coincide/Views/ChatView.swift", "Sources/CoincideCore/WorkspaceEngine.swift", "UITests/macOS/Example.swift", "script/test_macos_ui.sh", "script/prepare_macos_signing.py", "Package.resolved"]:
            self.assertTrue(ci.needs_native_ui([path]), path)
        self.assertFalse(ci.needs_native_ui(["README.md", "Tests/CoincideCoreTests/WorkspaceTests.swift", "docs/VALIDATION.md"]))

    def test_results_require_eighteen_real_tests_without_silent_skips(self):
        self.assertEqual(ci.verify_results(dict(totalTestCount=18, passedTests=18, failedTests=0, skippedTests=0)), 18)
        for summary in [dict(totalTestCount=18, passedTests=17, failedTests=0, skippedTests=1),
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
