"""Synthetic crash-report privacy/boundary checks; never inspect local user reports."""
import contextlib
import copy
from datetime import datetime, timezone
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("collect_test_crashes", Path(__file__).resolve().parents[2] / "script/collect_test_crashes.py")
crashes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(crashes)


def fixture(now):
    secret = "DO_NOT_EXPORT_PRIVATE_PAYLOAD"
    return ({"app_name": "CoincidePackageTests", "timestamp": datetime.fromtimestamp(now, timezone.utc).isoformat(), "incident_id": secret}, {
        "procName": "CoincidePackageTests", "procPath": "/Users/private-account/work/CoincidePackageTests",
        "captureTime": datetime.fromtimestamp(now, timezone.utc).isoformat(),
        "exception": {"type": "EXC_BAD_ACCESS", "signal": "SIGBUS", "subtype": "KERN_PROTECTION_FAILURE at 0x1234", "message": secret, "codes": secret},
        "termination": {"namespace": "SIGNAL", "code": 10, "indicator": secret, "details": [secret]},
        "faultingThread": 1, "asi": secret, "environment": {"TOKEN": secret}, "memory": secret,
        "threads": [{"name": secret, "frames": [{"imageIndex": 0, "symbol": "otherThread()", "imageOffset": secret}]},
                    {"triggered": True, "registers": secret, "threadState": secret, "frames": [
                        {"imageIndex": 0, "symbol": "managedProjectRegistration()", "imageOffset": secret, "stackMemory": secret},
                        {"imageIndex": 1, "symbol": "swift_retain", "symbolLocation": secret}]}],
        "usedImages": [{"name": "CoincidePackageTests", "path": "/Users/private-account/work/repo/.build/arm64-apple-macosx/debug/CoincidePackageTests.xctest/Contents/MacOS/CoincidePackageTests", "arch": "arm64", "uuid": secret, "base": secret},
                       {"name": "libswiftCore.dylib", "path": "/usr/lib/swift/libswiftCore.dylib", "arch": "arm64e", "size": secret},
                       {"name": secret, "path": secret}]})


class CrashCollectionTests(unittest.TestCase):
    def test_two_object_ips_exports_only_allowlisted_stack_and_stable_fingerprint(self):
        now = time.time()
        header, payload = fixture(now)
        decoded = crashes.decode_report((json.dumps(header) + "\n" + json.dumps(payload)).encode())
        report = crashes.sanitize_report(*decoded, since=now - 60, now=now)
        self.assertEqual(report["exception"], {"type": "EXC_BAD_ACCESS", "signal": "SIGBUS", "subtype": "KERN_PROTECTION_FAILURE"})
        self.assertEqual(report["termination"], {"namespace": "SIGNAL", "code": 10})
        self.assertEqual(report["faultingThread"], 1)
        self.assertEqual(report["threads"][0], {"index": 1, "triggered": True, "frames": [
            {"imageIndex": 0, "symbol": "managedProjectRegistration()"}, {"imageIndex": 1, "symbol": "swift_retain"}]})
        self.assertEqual([image["index"] for image in report["usedImages"]], [0, 1])
        self.assertTrue(report["usedImages"][0]["path"].startswith("$BUILD/"))
        self.assertEqual(report["usedImages"][1]["path"], "/usr/lib/swift/libswiftCore.dylib")
        encoded = json.dumps(report)
        for forbidden in ("DO_NOT_EXPORT", "private-account", "0x1234", "imageOffset", "symbolLocation", "registers", "threadState", "memory", "asi", "environment", "uuid"):
            self.assertNotIn(forbidden, encoded)
        payload["asi"] = "A different excluded assertion payload"
        payload["threads"][0]["frames"][0]["symbol"] = "aDifferentIdleThread()"
        self.assertEqual(crashes.sanitize_report(header, payload, now - 60, now)["fingerprint"], report["fingerprint"])

    def test_apple_capture_time_supports_four_fractional_digits_and_compact_timezone(self):
        now = time.time()
        header, payload = fixture(now)
        apple_date = datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%d %H:%M:%S.%f %z")
        date, zone = apple_date.rsplit(" ", 1)
        payload["captureTime"] = date[:-2] + " " + zone
        report = crashes.sanitize_report(header, payload, now - 60, now)
        self.assertEqual(report["exception"]["signal"], "SIGBUS")
        payload["captureTime"] = datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%d %H:%M:%S %z")
        self.assertEqual(crashes.sanitize_report(header, payload, now - 60, now)["exception"]["signal"], "SIGBUS")

    def test_only_bounded_relative_code_offsets_survive_unsymbolicated_frames(self):
        now = time.time()
        header, payload = fixture(now)
        values = [0, 2**48 - 1, -1, 2**48, True, 1.0, "DO_NOT_EXPORT_PRIVATE_PAYLOAD"]
        payload["threads"][1]["frames"] = [{"imageIndex": 0, "imageOffset": value} for value in values]
        frames = crashes.sanitize_report(header, payload, now - 60, now)["threads"][0]["frames"]
        self.assertEqual(frames[:2], [{"imageIndex": 0, "imageOffset": 0}, {"imageIndex": 0, "imageOffset": 2**48 - 1}])
        self.assertEqual(frames[2:], [{"imageIndex": 0}] * 5)

    def test_rejects_unrelated_old_malformed_and_extra_json_objects(self):
        now = time.time()
        header, payload = fixture(now)
        for process in ("Coincide", "other-app", ["CoincidePackageTests"]):
            changed = dict(payload, procName=process)
            with self.assertRaises(ValueError):
                crashes.sanitize_report(header, changed, now - 60, now)
        with self.assertRaises(ValueError):
            crashes.sanitize_report(header, payload, now + 1, now + 2)
        for data in (b"", b"not-json", b"{}\n{}\n{}", b"[]", b'{"captureTime":'):
            with self.assertRaises((ValueError, UnicodeError)):
                crashes.decode_report(data)
        with patch.object(crashes, "MAX_INPUT_BYTES", 8), self.assertRaises(ValueError):
            crashes.decode_report(b" " * 9)

    def test_bounded_frames_images_and_output_prefer_faulting_thread(self):
        now = time.time()
        header, payload = fixture(now)
        frame = {"imageIndex": 0, "symbol": "x" * 500}
        payload["threads"] = [{"frames": [copy.deepcopy(frame) for _ in range(100)]} for _ in range(100)]
        payload["faultingThread"] = 99
        report = crashes.sanitize_report(header, payload, now - 60, now)
        self.assertEqual(report["threads"][0]["index"], 99)
        self.assertTrue(report["truncated"])
        self.assertLessEqual(len(report["threads"]), crashes.MAX_THREADS)
        self.assertLessEqual(sum(len(thread["frames"]) for thread in report["threads"]), crashes.MAX_TOTAL_FRAMES)
        self.assertLessEqual(len((json.dumps(report, sort_keys=True, indent=2) + "\n").encode()), crashes.MAX_REPORT_BYTES)

    def test_collection_caps_reports_and_ignores_old_foreign_symlink_and_large_files(self):
        now = time.time()
        header, payload = fixture(now)
        data = json.dumps(header) + "\n" + json.dumps(payload)
        with tempfile.TemporaryDirectory(prefix="coincide-crash-collector-") as temporary:
            root = Path(temporary)
            source, output = root / "reports", root / "sanitized"
            source.mkdir()
            for index in range(8):
                path = source / ("CoincidePackageTests-%02d.ips" % index)
                path.write_text(data)
                os.utime(path, (now, now))
            (source / "swiftpm-testing-helper-symlink.ips").symlink_to(source / "CoincidePackageTests-00.ips")
            (source / "CoincidePackageTests-malformed.ips").write_text("private malformed canary")
            old = source / "CoincidePackageTests-old.ips"
            old.write_text(data); os.utime(old, (now - 3600, now - 3600))
            (source / "Coincide-other.ips").write_text(data)
            (source / "CoincidePackageTests-large.ips").write_bytes(b" " * (crashes.MAX_INPUT_BYTES + 1))
            self.assertEqual(crashes.collect_reports([source], output, now - 60, now), crashes.MAX_REPORTS)
            files = list(output.iterdir())
            self.assertEqual(len(files), crashes.MAX_REPORTS)
            self.assertLessEqual(sum(path.stat().st_size for path in files), crashes.MAX_TOTAL_BYTES)
            for path in files:
                self.assertEqual(path.suffix, ".json")
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                self.assertNotIn("DO_NOT_EXPORT", path.read_text())
            symlink_output = root / "redirected"; symlink_output.symlink_to(output, target_is_directory=True)
            with self.assertRaises(ValueError):
                crashes.collect_reports([source], symlink_output, now - 60, now)

    def test_malformed_optional_fields_cannot_export_arbitrary_diagnostics(self):
        now = time.time()
        header, payload = fixture(now)
        payload["exception"] = {"type": "private free text", "signal": "SIGBUS\nprivate", "subtype": "private exception message"}
        payload["termination"] = {"namespace": "private free text", "code": True}
        payload["threads"][1]["frames"][0]["symbol"] = "password=DO_NOT_EXPORT"
        payload["usedImages"][0]["path"] = "/Users/private-account/private-project/library"
        payload["usedImages"][0]["arch"] = ["private"]
        report = crashes.sanitize_report(header, payload, now - 60, now)
        self.assertEqual(report["exception"], {})
        self.assertEqual(report["termination"], {})
        self.assertEqual(report["threads"][0]["frames"][0], {"imageIndex": 0})
        self.assertNotIn("private", json.dumps(report))

    def test_diagnostics_cli_failure_is_best_effort_without_exception_payloads(self):
        with patch("sys.argv", ["collect_test_crashes.py", "--since-file", "/missing/PRIVATE_CANARY", "--output", "/missing"]):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(crashes.main(), 0)
            self.assertNotIn("PRIVATE_CANARY", output.getvalue())
            self.assertIn("original test failure is unchanged", output.getvalue())

    def test_workflow_capture_only_follows_failed_tests_and_cannot_replace_failure(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/swift.yml").read_text()
        collector = workflow.split("      - name: Collect sanitized Swift test crash stacks", 1)[1].split("      - name: Package the native app", 1)[0]
        self.assertEqual(collector.count("if: failure() && steps.swift_tests.outcome == 'failure'"), 2)
        self.assertEqual(collector.count("continue-on-error: true"), 2)
        self.assertIn("coincide-test-crashes/*.json", collector)
        self.assertIn("if-no-files-found: ignore", collector)
        self.assertIn("swift test --no-parallel", workflow)
        self.assertIn("timeout-minutes: 35", workflow)
        self.assertIn("timeout-minutes: 45", workflow)
        self.assertIn("cancel-in-progress: ${{ github.event_name == 'pull_request' }}", workflow)


if __name__ == "__main__":
    unittest.main()
