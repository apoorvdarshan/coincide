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
    def test_delayed_report_with_unrelated_filename_is_collected_without_repeating_tests(self):
        now = time.time()
        header, payload = fixture(now)
        data = json.dumps(header) + "\n" + json.dumps(payload)
        with tempfile.TemporaryDirectory(prefix="coincide-crash-delay-") as temporary:
            root = Path(temporary)
            source, output = root / "reports", root / "sanitized"
            source.mkdir()
            elapsed, waits = [0], []

            def arrival(interval):
                waits.append(interval); elapsed[0] += interval
                report = source / "Unexpected-system-report-name.ips"
                report.write_text(data); os.utime(report, (now + elapsed[0], now + elapsed[0]))

            summary = crashes.poll_reports([source], output, now - 60, wall_clock=lambda: now + elapsed[0],
                                          monotonic=lambda: elapsed[0], sleeper=arrival)
            self.assertEqual(summary["reportsWritten"], 1)
            self.assertEqual(summary["scanAttempts"], 2)
            self.assertEqual(summary["inspectedCandidates"], 1)
            self.assertEqual(waits, [5])
            report = json.loads((output / "test-crash-01.json").read_text())
            self.assertEqual(report["exception"]["signal"], "SIGBUS")
            self.assertNotIn("Unexpected-system-report-name", json.dumps(summary))

    def test_arrival_poll_deadline_and_individual_waits_are_bounded_and_zero_report_summary_survives(self):
        now = time.time()
        with tempfile.TemporaryDirectory(prefix="coincide-crash-no-report-") as temporary:
            root = Path(temporary)
            source, output = root / "reports", root / "sanitized"
            source.mkdir()
            elapsed, waits = [0], []

            def advance(interval):
                waits.append(interval); elapsed[0] += interval

            summary = crashes.poll_reports([source], output, now - 60, wait_seconds=30,
                                          wall_clock=lambda: now + elapsed[0], monotonic=lambda: elapsed[0], sleeper=advance)
            self.assertEqual(summary["reportsWritten"], 0)
            self.assertEqual(summary["scanAttempts"], 7)
            self.assertEqual(sum(waits), 30)
            self.assertTrue(all(0 < wait <= 5 for wait in waits))
            self.assertEqual(summary["waitedSeconds"], 30)
            self.assertEqual(json.loads((output / "collection-summary.json").read_text()), summary)
            self.assertLessEqual(sum(path.stat().st_size for path in output.iterdir()), crashes.MAX_TOTAL_BYTES)
            for invalid in (-1, 30.01, float("inf"), float("nan"), "30"):
                with self.assertRaises(ValueError):
                    crashes.poll_reports([source], root / "unused", now - 60, wait_seconds=invalid)

    def test_revised_partial_report_is_reconsidered_after_arrival_without_recounting_unchanged_rejections(self):
        now = time.time()
        header, payload = fixture(now)
        with tempfile.TemporaryDirectory(prefix="coincide-crash-partial-") as temporary:
            root = Path(temporary)
            source, output = root / "reports", root / "sanitized"
            source.mkdir()
            partial = source / "Crash-report.ips"
            partial.write_text("PRIVATE_PARTIAL_PAYLOAD"); os.utime(partial, (now, now))
            foreign = source / "Foreign.ips"
            foreign.write_text(json.dumps(dict(payload, procName="PRIVATE_FOREIGN_PROCESS")))
            elapsed = [0]

            def complete(interval):
                elapsed[0] += interval
                if elapsed[0] >= 10:
                    partial.write_text(json.dumps(header) + "\n" + json.dumps(payload))
                    os.utime(partial, (now + elapsed[0], now + elapsed[0]))

            summary = crashes.poll_reports([source], output, now - 60, wall_clock=lambda: now + elapsed[0],
                                          monotonic=lambda: elapsed[0], sleeper=complete)
            self.assertEqual(summary["scanAttempts"], 3)
            self.assertEqual(summary["inspectedCandidates"], 3)
            self.assertEqual(summary["rejectionCounts"]["malformedJSON"], 1)
            self.assertEqual(summary["rejectionCounts"]["unrelatedProcess"], 1)
            self.assertEqual(summary["reportsWritten"], 1)
            self.assertNotIn("PRIVATE_", json.dumps(summary))

    def test_rejection_counts_distinguish_filters_without_exporting_names_or_payloads(self):
        now = time.time()
        header, payload = fixture(now)
        with tempfile.TemporaryDirectory(prefix="coincide-crash-rejections-") as temporary:
            root = Path(temporary)
            source, output = root / "reports", root / "sanitized"
            source.mkdir()

            def report(name, body, modified=now):
                path = source / (name + "_PRIVATE_FILENAME.ips")
                path.write_text(json.dumps(body) if isinstance(body, dict) else body)
                os.utime(path, (modified, modified))
                return path

            report("foreign", dict(payload, procName="PRIVATE_PROCESS_NAME"))
            report("malformed", "PRIVATE_MALFORMED_PAYLOAD")
            report("timestamp", dict(payload, captureTime="PRIVATE_INVALID_TIMESTAMP"))
            report("capture", dict(payload, captureTime=datetime.fromtimestamp(now - 1000, timezone.utc).isoformat()))
            report("stack", dict(payload, threads="PRIVATE_INVALID_STACK"))
            report("stale", payload, now - 1000)
            report("future", payload, now + 1000)
            report("oversized", "x" * 8193)
            (source / "PRIVATE_SYMLINK.ips").symlink_to(source / "foreign_PRIVATE_FILENAME.ips")
            with patch.object(crashes, "MAX_INPUT_BYTES", 8192):
                summary = crashes.poll_reports([source], output, now - 60, wait_seconds=0, wall_clock=lambda: now)
            for reason in ("unrelatedProcess", "malformedJSON", "invalidCaptureTime", "captureWindow", "invalidStack", "stale", "future", "oversized", "nonRegular"):
                self.assertEqual(summary["rejectionCounts"][reason], 1, reason)
            self.assertEqual(summary["reportsWritten"], 0)
            self.assertNotIn("PRIVATE_", (output / "collection-summary.json").read_text())

    def test_candidate_budget_is_shared_across_all_poll_scans_and_summary_has_only_fixed_keys(self):
        now = time.time()
        _, payload = fixture(now)
        with tempfile.TemporaryDirectory(prefix="coincide-crash-candidates-") as temporary:
            root = Path(temporary)
            source, output = root / "reports", root / "sanitized"
            source.mkdir()
            for index in range(5):
                (source / ("Unrelated-%d.ips" % index)).write_text(json.dumps(dict(payload, procName="PRIVATE_PROCESS")))
            with patch.object(crashes, "MAX_CANDIDATES", 2):
                summary = crashes.poll_reports([source], output, now - 60, wall_clock=lambda: now,
                                              sleeper=lambda _: self.fail("An exhausted candidate budget cannot poll again."))
            self.assertEqual(summary["scanAttempts"], 1)
            self.assertEqual(summary["inspectedCandidates"], 2)
            self.assertEqual(summary["rejectionCounts"]["candidateLimit"], 3)
            self.assertEqual(set(summary["rejectionCounts"]), set(crashes.REJECTION_REASONS))
            self.assertEqual(set(summary), {"schemaVersion", "reportsWritten", "scanAttempts", "inspectedCandidates", "waitedSeconds", "rejectionCounts"})

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

    def test_fault_classification_derives_only_fixed_enums_from_the_exact_fault_region(self):
        now = time.time()
        cases = [("STACK GUARD", "---", "guard"), ("Stack", "rw-", "stack"),
                 ("__TEXT", "r-x", "readOnly"), ("MALLOC_SMALL", "rw-", "writable"),
                 ("VM_ALLOCATE", "---", "other")]
        for label, protection, expected in cases:
            with self.subTest(region=expected):
                header, payload = fixture(now)
                payload["exception"]["subtype"] = "KERN_PROTECTION_FAILURE at 0x70001234"
                payload["exception"]["rawCodes"] = [2, 0x70001234]
                payload["threads"][1]["threadState"] = {"flavor": "ARM_THREAD_STATE64", "sp": {"value": 0x70002000, "symbol": "PRIVATE_REGISTER_CANARY"}}
                payload["vmRegionInfo"] = ("PRIVATE_VM_CANARY /Users/private-account/secret\n"
                    "--->  %s 70000000-70004000 [16K] %s/rwx SM=PRV PRIVATE_REGION_CANARY" % (label, protection))
                report = crashes.sanitize_report(header, payload, now - 60, now)
                self.assertEqual(report["faultClassification"], {"faultRegion": expected, "faultToStackPointer": "lessThan4KiB"})
                encoded = json.dumps(report)
                for forbidden in ("0x70001234", "70000000", str(0x70001234), str(0x70002000), "PRIVATE_", "private-account", "rawCodes", "threadState", "vmRegionInfo", "SM=PRV"):
                    self.assertNotIn(forbidden, encoded)
                _, without = fixture(now)
                self.assertEqual(report["fingerprint"], crashes.sanitize_report(header, without, now - 60, now)["fingerprint"])

    def test_fault_distance_is_coarse_bounded_and_uses_only_the_faulting_thread(self):
        now = time.time()
        for distance, expected in [(0, "lessThan4KiB"), (4095, "lessThan4KiB"),
                                   (4096, "4KiBTo64KiB"), (65535, "4KiBTo64KiB"),
                                   (65536, "64KiBTo1MiB"), (1048575, "64KiBTo1MiB"),
                                   (1048576, "atLeast1MiB")]:
            for flavor, register in [("ARM_THREAD_STATE64", "sp"), ("x86_THREAD_STATE64", "rsp")]:
                with self.subTest(distance=expected, flavor=flavor):
                    header, payload = fixture(now)
                    payload["exception"]["subtype"] = "KERN_PROTECTION_FAILURE at 0x70000000"
                    payload["threads"][0]["threadState"] = {"flavor": flavor, register: {"value": 0x70000000}}
                    payload["threads"][1]["threadState"] = {"flavor": flavor, register: {"value": 0x70000000 + distance}}
                    report = crashes.sanitize_report(header, payload, now - 60, now)
                    self.assertEqual(report["faultClassification"], {"faultRegion": "unknown", "faultToStackPointer": expected})

    def test_fault_region_requires_exact_range_and_never_infers_from_adjacent_guard_text(self):
        now = time.time()
        header, payload = fixture(now)
        payload["exception"]["subtype"] = "KERN_PROTECTION_FAILURE at 0x70001234"
        cases = [
            ("0x70001234 is not in any region. Bytes before following region: 500\n"
             "      STACK GUARD 70002000-70004000 [8K] ---/rwx SM=NUL", "unmapped"),
            ("---> Stack 70000000-70004000 [16K] rw-/rwx SM=PRV\n"
             "      STACK GUARD 70004000-70008000 [16K] ---/rwx SM=NUL", "stack"),
            ("---> STACK GUARD 70002000-70004000 [8K] ---/rwx SM=NUL", None),
            ("---> STACK GUARD 70000000-70001234 [4K] ---/rwx SM=NUL", None),
            ("---> Stack 70000000-70004000 [16K] rw-/rwx SM=PRV\n"
             "---> STACK GUARD 70000000-70004000 [16K] ---/rwx SM=NUL", None),
            ("0x70001111 is not in any region.", None),
            ("0x70001234 is not in any region.\n---> Stack 70000000-70004000 [16K] rw-/rwx", None),
        ]
        for text, expected in cases:
            with self.subTest(expected=expected):
                payload["vmRegionInfo"] = text
                report = crashes.sanitize_report(header, payload, now - 60, now)
                if expected:
                    self.assertEqual(report["faultClassification"], {"faultRegion": expected, "faultToStackPointer": "unknown"})
                else:
                    self.assertNotIn("faultClassification", report)

    def test_malformed_or_conflicting_fault_data_is_omitted_without_exporting_private_inputs(self):
        now = time.time()
        header, valid = fixture(now)
        valid["exception"]["subtype"] = "KERN_PROTECTION_FAILURE at 0x70001234"
        valid["threads"][1]["threadState"] = {"flavor": "ARM_THREAD_STATE64", "sp": {"value": 0x70002000}}
        cases = []
        for codes in ([2, 0x70001235], [2, True], [2, -1], [2, 2**64], [2], "PRIVATE_RAW_CODES"):
            changed = copy.deepcopy(valid); changed["exception"]["rawCodes"] = codes; cases.append(changed)
        for state in (None, "PRIVATE_STATE", {"flavor": []}, {"flavor": "PRIVATE_FLAVOR", "sp": {"value": 0x70002000}},
                      {"flavor": "ARM_THREAD_STATE64", "sp": {"value": True}},
                      {"flavor": "ARM_THREAD_STATE64", "sp": {"value": 0}},
                      {"flavor": "ARM_THREAD_STATE64", "sp": {"value": 2**64}}):
            changed = copy.deepcopy(valid); changed["threads"][1]["threadState"] = state; cases.append(changed)
        changed = copy.deepcopy(valid); changed["exception"]["type"] = "EXC_CRASH"; cases.append(changed)
        changed = copy.deepcopy(valid); changed["exception"]["subtype"] = "PRIVATE_FAULT"; cases.append(changed)
        for payload in cases:
            report = crashes.sanitize_report(header, payload, now - 60, now)
            self.assertNotIn("faultClassification", report)
            for forbidden in ("PRIVATE_", "0x7000", str(0x70001234), "threadState", "rawCodes"):
                self.assertNotIn(forbidden, json.dumps(report))
        for text in (None, ["PRIVATE_REGION"], "x" * 65537, "\n" * 129):
            payload = copy.deepcopy(valid); payload["vmRegionInfo"] = text
            self.assertEqual(crashes.sanitize_report(header, payload, now - 60, now)["faultClassification"],
                             {"faultRegion": "unknown", "faultToStackPointer": "lessThan4KiB"})

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
        self.assertIn("--wait-seconds 30", collector)
        self.assertIn("swift test --no-parallel", workflow)
        self.assertIn("timeout-minutes: 35", workflow)
        self.assertIn("timeout-minutes: 45", workflow)
        self.assertIn("cancel-in-progress: ${{ github.event_name == 'pull_request' }}", workflow)


if __name__ == "__main__":
    unittest.main()
