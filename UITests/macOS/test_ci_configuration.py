"""Configuration checks run without launching a native app or touching user state."""
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
    def test_change_filter_keeps_product_and_harness_paths_and_skips_unrelated_unit_docs(self):
        for path in ["Sources/Coincide/Views/ChatView.swift", "Sources/CoincideCore/WorkspaceEngine.swift", "UITests/macOS/Example.swift", "script/test_macos_ui.sh", "Package.resolved"]:
            self.assertTrue(ci.needs_native_ui([path]), path)
        self.assertFalse(ci.needs_native_ui(["README.md", "Tests/CoincideCoreTests/WorkspaceTests.swift", "docs/VALIDATION.md"]))

    def test_results_require_both_real_tests_without_silent_skips(self):
        self.assertEqual(ci.verify_results(dict(totalTestCount=2, passedTests=2, failedTests=0, skippedTests=0)), 2)
        for summary in [dict(totalTestCount=0, passedTests=0, failedTests=0, skippedTests=0),
                        dict(totalTestCount=2, passedTests=1, failedTests=0, skippedTests=1),
                        dict(totalTestCount=2, passedTests=1, failedTests=1, skippedTests=0),
                        dict(totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0), {}]:
            with self.assertRaises(ValueError):
                ci.verify_results(summary)

    def test_preparation_targets_only_disposable_app_and_preserves_runner_paths(self):
        with tempfile.TemporaryDirectory(prefix="coincide-ui-config-") as directory:
            root = Path(directory).resolve()
            app, parent, bootstrap, artifacts = [root / name for name in ("Copy.app", "workspaces", "coincide-ui-testing-bootstrap", "artifacts")]
            for path in (app / "Contents", parent, bootstrap, artifacts):
                path.mkdir(parents=True)
            info = app / "Contents/Info.plist"
            info.write_bytes(plistlib.dumps({"CFBundleIdentifier": ci.TEST_BUNDLE_ID}))
            original = {"TestConfigurations": [{"TestTargets": [{"BlueprintName": ci.TEST_TARGET, "UITargetAppPath": "__TESTROOT__/Debug/Placeholder.app",
                "TestHostPath": "__TESTROOT__/Debug/Runner.app", "TestBundlePath": "__TESTHOST__/PlugIns/Tests.xctest",
                "DependentProductPaths": ["__TESTROOT__/Debug/Placeholder.app", "__TESTROOT__/Debug/Runner.app"],
                "EnvironmentVariables": {"EXISTING": "kept"}}]}]}
            value = ci.prepare_configuration(copy.deepcopy(original), app, parent, bootstrap, artifacts)
            target = value["TestConfigurations"][0]["TestTargets"][0]
            self.assertEqual(target["UITargetAppPath"], str(app))
            self.assertEqual(target["DependentProductPaths"], [str(app), "__TESTROOT__/Debug/Runner.app"])
            self.assertEqual(target["TestHostPath"], "__TESTROOT__/Debug/Runner.app")
            self.assertEqual(target["EnvironmentVariables"]["EXISTING"], "kept")
            self.assertEqual(target["UITargetAppEnvironmentVariables"]["COINCIDE_UI_TEST_ROOT"], str(bootstrap))
            legacy = {ci.TEST_TARGET: copy.deepcopy(original["TestConfigurations"][0]["TestTargets"][0]), "__xctestrun_metadata__": {"FormatVersion": 1}}
            legacy_value = ci.prepare_configuration(legacy, app, parent, bootstrap, artifacts)
            self.assertEqual(legacy_value[ci.TEST_TARGET]["UITargetAppPath"], str(app))
            info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.apoorvdarshan.coincide"}))
            with self.assertRaises(ValueError):
                ci.prepare_configuration(copy.deepcopy(original), app, parent, bootstrap, artifacts)
            info.write_bytes(plistlib.dumps({"CFBundleIdentifier": ci.TEST_BUNDLE_ID}))
            duplicate = copy.deepcopy(original)
            duplicate["TestConfigurations"][0]["TestTargets"] *= 2
            with self.assertRaises(ValueError):
                ci.prepare_configuration(duplicate, app, parent, bootstrap, artifacts)
            other_target = copy.deepcopy(original)
            other_target["TestConfigurations"][0]["TestTargets"].append({"BlueprintName": "UnexpectedUITests"})
            with self.assertRaises(ValueError):
                ci.prepare_configuration(other_target, app, parent, bootstrap, artifacts)
            with self.assertRaises(ValueError):
                ci.prepare_configuration(copy.deepcopy(original), app, parent, root, artifacts)


if __name__ == "__main__":
    unittest.main()
