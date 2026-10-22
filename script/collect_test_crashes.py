#!/usr/bin/env python3
"""Best-effort, allowlisted macOS Swift test crash stacks; never copy raw reports."""
import argparse
from datetime import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import time

TEST_PROCESSES = {"CoincidePackageTests", "swiftpm-testing-helper"}
MAX_INPUT_BYTES = 2 * 1024 * 1024
MAX_REPORT_BYTES = 64 * 1024
MAX_TOTAL_BYTES = 192 * 1024
MAX_REPORTS = 3
MAX_CANDIDATES = 32
MAX_DIRECTORY_ENTRIES = 1024
MAX_THREADS = 16
MAX_FRAMES_PER_THREAD = 64
MAX_TOTAL_FRAMES = 256
MAX_IMAGES = 128
MAX_WAIT_SECONDS = 30
MAX_POLL_INTERVAL = 5
MAX_DIRECTORIES = 4
MAX_SUMMARY_BYTES = 4096

REJECTION_REASONS = ("directoryUnavailable", "nonRegular", "stale", "future", "oversized", "inputRead",
                     "malformedJSON", "unrelatedProcess", "invalidCaptureTime", "captureWindow", "invalidStack",
                     "outputLimit", "outputWrite", "candidateLimit", "directoryEntryLimit", "directoryLimit")


class CollectionState:
    def __init__(self):
        self.rejections = dict.fromkeys(REJECTION_REASONS, 0)
        self.seen = set()
        self.unavailable_directories = set()
        self.limited_directories = set()
        self.written = 0
        self.total_bytes = 0
        self.inspected = 0
        self.scans = 0

    def summary(self, waited_seconds):
        return {"schemaVersion": 1, "reportsWritten": self.written, "scanAttempts": self.scans,
                "inspectedCandidates": self.inspected, "waitedSeconds": round(waited_seconds, 3),
                "rejectionCounts": dict(self.rejections)}


def _integer(value, maximum=1_000_000):
    return type(value) is int and 0 <= value <= maximum


def _text(value, maximum=256):
    if not isinstance(value, str) or not value or len(value) > maximum:
        return None
    if not all(32 <= ord(character) <= 126 for character in value):
        return None
    if re.search(r"https?://|bearer |(?:token|password|secret|cookie)\s*[=:]|/Users/", value, re.I):
        return None
    return value


def _image_path(value):
    if not isinstance(value, str) or len(value) > 1024:
        return None
    # Preserve system/build identity, never the account/repository/private fixture prefix.
    if "/.build/" in value:
        return _text("$BUILD/" + value.split("/.build/", 1)[1], 1024)
    if ".xctoolchain/" in value:
        return _text("$TOOLCHAIN/" + value.split(".xctoolchain/", 1)[1], 1024)
    if value.startswith(("/System/Library/", "/usr/lib/", "/usr/bin/")):
        return _text(value, 1024)
    return None


def _address(value):
    return value if type(value) is int and 0 <= value < 2**64 else None


def _fault_classification(payload, fault):
    """Reduce private address/register/VM data to fixed diagnostic enums only.

    A neighbouring guard or a stack mentioned elsewhere is not fault evidence.
    Keep this independent of the stack fingerprint and never return raw input.
    """
    unknown = {"faultRegion": "unknown", "faultToStackPointer": "unknown"}
    exception = payload.get("exception")
    if not isinstance(exception, dict) or exception.get("type") != "EXC_BAD_ACCESS":
        return unknown
    addresses = []
    if "rawCodes" in exception:
        codes = exception["rawCodes"]
        if not isinstance(codes, list) or len(codes) != 2 or any(_address(value) is None for value in codes):
            return unknown
        addresses.append(codes[1])
    subtype = exception.get("subtype")
    if isinstance(subtype, str) and len(subtype) <= 128:
        match = re.fullmatch(r"KERN_[A-Z0-9_]{1,48} at 0x([0-9a-fA-F]{1,16})", subtype)
        if match:
            addresses.append(int(match.group(1), 16))
    if not addresses or len(set(addresses)) != 1:
        return unknown
    address = addresses[0]
    result = dict(unknown)
    threads = payload.get("threads")
    if isinstance(threads, list) and _integer(fault) and fault < len(threads) and isinstance(threads[fault], dict):
        state = threads[fault].get("threadState")
        if isinstance(state, dict):
            register = {"ARM_THREAD_STATE64": "sp", "x86_THREAD_STATE64": "rsp"}.get(state.get("flavor")) if isinstance(state.get("flavor"), str) else None
            saved = state.get(register) if register else None
            pointer = _address(saved.get("value")) if isinstance(saved, dict) else None
            if pointer is not None and pointer != 0:
                distance = abs(address - pointer)
                result["faultToStackPointer"] = ("lessThan4KiB" if distance < 4096 else
                                                  "4KiBTo64KiB" if distance < 65536 else
                                                  "64KiBTo1MiB" if distance < 1048576 else "atLeast1MiB")
    regions = payload.get("vmRegionInfo")
    if not isinstance(regions, str) or len(regions) > 65536:
        return result
    lines = regions.splitlines()
    if len(lines) > 128:
        return result
    # Apple marks the fault's row with an arrow. Parse only a single exact row,
    # cross-check its range, and discard all labels/details after classification.
    marked = [line for line in lines if line.lstrip().startswith("--->")]
    unmapped = [line for line in lines if re.fullmatch(r"0x[0-9a-fA-F]{1,16} is not in any region\.(?: [^\r\n]{0,256})?", line)]
    if len(unmapped) == 1 and not marked:
        native_address = int(unmapped[0].split(" ", 1)[0], 16)
        if native_address == address:
            result["faultRegion"] = "unmapped"
    elif len(marked) == 1 and not unmapped:
        match = re.fullmatch(r"\s*--->\s+(.{1,80}?)\s+(?:0x)?([0-9a-fA-F]{1,16})-(?:0x)?([0-9a-fA-F]{1,16})\s+\[[^\]\r\n]{1,32}\]\s+([rwx-]{3})/[rwx-]{3}(?:\s+[^\r\n]{0,512})?", marked[0])
        if match:
            label, start, end, protection = match.groups()
            if int(start, 16) <= address < int(end, 16):
                result["faultRegion"] = ("guard" if label.strip() == "STACK GUARD" and protection == "---" else
                                         "stack" if label.strip() == "Stack" else
                                         "readOnly" if "r" in protection and "w" not in protection else
                                         "writable" if "w" in protection else "other")
    return result


def _timestamp(header, payload):
    value = payload.get("captureTime", header.get("timestamp"))
    if not isinstance(value, str) or len(value) > 64:
        raise ValueError("Missing capture time")
    normalized = value.replace("Z", "+00:00").replace(" ", "T", 1)
    normalized = re.sub(r"\s*([+-]\d{2}):?(\d{2})$", r"\1:\2", normalized)
    # Python 3.9 accepts 3/6 fractional digits; Apple commonly emits four.
    normalized = re.sub(r"\.(\d+)(?=[+-]\d{2}:\d{2}$)",
                        lambda match: "." + match.group(1)[:6].ljust(6, "0"), normalized)
    parsed = datetime.fromisoformat(normalized)
    if parsed.tzinfo is None:
        raise ValueError("Capture time has no timezone")
    return parsed.timestamp()


def decode_report(data):
    """Apple .ips files may have a metadata object followed by the crash object."""
    if len(data) > MAX_INPUT_BYTES:
        raise ValueError("Oversized report")
    text = data.decode("utf-8")
    decoder = json.JSONDecoder()
    values = []
    while text.strip():
        if len(values) == 2:
            raise ValueError("Unexpected trailing report data")
        value, end = decoder.raw_decode(text.lstrip())
        if not isinstance(value, dict):
            raise ValueError("Invalid report object")
        values.append(value)
        text = text.lstrip()[end:]
    if not values:
        raise ValueError("Empty report")
    return ({}, values[0]) if len(values) == 1 else (values[0], values[1])


def sanitize_report(header, payload, since, now):
    process = payload.get("procName", header.get("app_name"))
    if not isinstance(process, str) or process not in TEST_PROCESSES:
        raise ValueError("Unrelated process")
    captured = _timestamp(header, payload)
    if not since <= captured <= now + 60:
        raise ValueError("Outside diagnostic window")
    exception = payload.get("exception", {})
    termination = payload.get("termination", {})
    report = {"schemaVersion": 1, "processName": process, "exception": {}, "termination": {}}
    if isinstance(exception, dict):
        for key, pattern in (("type", r"EXC_[A-Z0-9_]+"), ("signal", r"SIG[A-Z0-9]+")):
            value = exception.get(key)
            if isinstance(value, str) and re.fullmatch(pattern, value[:64]) and len(value) <= 64:
                report["exception"][key] = value
        # Subtypes may append an address or free text; retain only a known enum token.
        subtype = exception.get("subtype")
        if isinstance(subtype, str):
            token = subtype.split(" ", 1)[0]
            if re.fullmatch(r"KERN_[A-Z0-9_]{1,48}", token):
                report["exception"]["subtype"] = token
    if isinstance(termination, dict):
        namespace = termination.get("namespace")
        if isinstance(namespace, str) and re.fullmatch(r"[A-Z_]{1,32}", namespace):
            report["termination"]["namespace"] = namespace
        if _integer(termination.get("code"), 2**32 - 1):
            report["termination"]["code"] = termination["code"]

    threads, images = payload.get("threads", []), payload.get("usedImages", [])
    if not isinstance(threads, list) or not isinstance(images, list):
        raise ValueError("Invalid stack structure")
    fault = payload.get("faultingThread")
    if not _integer(fault) or fault >= len(threads):
        fault = next((index for index, thread in enumerate(threads)
                      if isinstance(thread, dict) and thread.get("triggered") is True), None)
    if fault is not None:
        report["faultingThread"] = fault
    classification = _fault_classification(payload, fault)
    if any(value != "unknown" for value in classification.values()):
        report["faultClassification"] = classification
    order = ([fault] if fault is not None else []) + [index for index in range(len(threads)) if index != fault]
    report["threads"] = []
    frame_count = 0
    for index in order[:MAX_THREADS]:
        thread = threads[index]
        if not isinstance(thread, dict) or not isinstance(thread.get("frames"), list):
            continue
        safe_thread = {"index": index, "frames": []}
        if thread.get("triggered") is True:
            safe_thread["triggered"] = True
        for frame in thread["frames"][:MAX_FRAMES_PER_THREAD]:
            if frame_count >= MAX_TOTAL_FRAMES:
                break
            if not isinstance(frame, dict) or not _integer(frame.get("imageIndex")) or frame["imageIndex"] >= len(images):
                continue
            safe_frame = {"imageIndex": frame["imageIndex"]}
            if _integer(frame.get("imageOffset"), 2**48 - 1):
                safe_frame["imageOffset"] = frame["imageOffset"]
            symbol = _text(frame.get("symbol"), 512)
            if symbol:
                safe_frame["symbol"] = symbol
            safe_thread["frames"].append(safe_frame)
            frame_count += 1
        report["threads"].append(safe_thread)

    referenced = sorted({frame["imageIndex"] for thread in report["threads"] for frame in thread["frames"]})
    report["usedImages"] = []
    for index in referenced[:MAX_IMAGES]:
        image = images[index]
        if not isinstance(image, dict):
            continue
        safe_image = {"index": index}
        name = _text(image.get("name"), 128)
        if name and "/" not in name:
            safe_image["name"] = name
        path = _image_path(image.get("path"))
        if path:
            safe_image["path"] = path
        if isinstance(image.get("arch"), str) and image["arch"] in {"arm64", "arm64e", "x86_64", "x86_64h"}:
            safe_image["arch"] = image["arch"]
        report["usedImages"].append(safe_image)
    report["truncated"] = (len(order) > MAX_THREADS or len(referenced) > MAX_IMAGES
                           or frame_count >= MAX_TOTAL_FRAMES
                           or any(isinstance(thread, dict) and isinstance(thread.get("frames"), list)
                                  and len(thread["frames"]) > MAX_FRAMES_PER_THREAD for thread in threads))
    # No report IDs, machine/user identifiers, private paths, registers, addresses, memory,
    # environment, ASI/assertion messages, or other arbitrary payload fields survive.
    # faultClassification contains only fixed enums derived before this boundary.
    while len(json.dumps(report, ensure_ascii=True, sort_keys=True, indent=2).encode()) > MAX_REPORT_BYTES - 100:
        report["truncated"] = True
        if len(report["threads"]) > 1:
            report["threads"].pop()
        elif report["threads"] and report["threads"][0]["frames"]:
            report["threads"][0]["frames"].pop()
        else:
            report["usedImages"].pop()
    fault_threads = [thread for thread in report["threads"] if thread["index"] == fault]
    fault_images = {frame["imageIndex"] for thread in fault_threads for frame in thread["frames"]}
    fingerprint = {key: report.get(key) for key in ("processName", "exception", "termination")}
    fingerprint["threads"] = fault_threads
    fingerprint["usedImages"] = [image for image in report["usedImages"] if image["index"] in fault_images]
    report["fingerprint"] = hashlib.sha256(json.dumps(fingerprint, sort_keys=True).encode()).hexdigest()
    return report


def collect_reports(directories, output, since, now=None, state=None):
    now = time.time() if now is None else now
    if not math.isfinite(since) or not now - 3 * 3600 <= since <= now + 60:
        raise ValueError("Invalid diagnostic window")
    state = CollectionState() if state is None else state
    state.scans += 1
    output = Path(output)
    if output.is_symlink():
        raise ValueError("Invalid output directory")
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    candidates = []
    directories = list(directories)
    if state.scans == 1:
        state.rejections["directoryLimit"] = max(0, len(directories) - MAX_DIRECTORIES)
    for directory in directories[:MAX_DIRECTORIES]:
        directory = Path(directory)
        if directory.is_symlink():
            if directory not in state.unavailable_directories:
                state.rejections["directoryUnavailable"] += 1
                state.unavailable_directories.add(directory)
            continue
        try:
            with os.scandir(directory) as entries:
                for count, entry in enumerate(entries):
                    if count >= MAX_DIRECTORY_ENTRIES:
                        if directory not in state.limited_directories:
                            state.rejections["directoryEntryLimit"] += 1
                            state.limited_directories.add(directory)
                        break
                    # Report filenames are not a reliable executable identity.
                    # Inspect bounded recent reports, then enforce the payload allowlist.
                    if not entry.name.endswith(".ips"):
                        continue
                    try:
                        info = entry.stat(follow_symlinks=False)
                    except OSError:
                        state.rejections["inputRead"] += 1
                        continue
                    revision = (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
                    if revision in state.seen:
                        continue
                    reason = ("nonRegular" if not stat.S_ISREG(info.st_mode) else
                              "stale" if info.st_mtime < since else
                              "future" if info.st_mtime > now + 60 else
                              "oversized" if info.st_size > MAX_INPUT_BYTES else None)
                    if reason:
                        state.seen.add(revision)
                        state.rejections[reason] += 1
                    else:
                        candidates.append((info.st_mtime, Path(entry.path), revision))
        except OSError:
            if directory not in state.unavailable_directories:
                state.rejections["directoryUnavailable"] += 1
                state.unavailable_directories.add(directory)
            continue
    candidates.sort(key=lambda item: item[0], reverse=True)
    remaining = max(0, MAX_CANDIDATES - state.inspected)
    for _, _, revision in candidates[remaining:]:
        state.seen.add(revision)
        state.rejections["candidateLimit"] += 1
    for _, path, revision in candidates[:remaining]:
        if state.written >= MAX_REPORTS:
            break
        state.seen.add(revision)
        state.inspected += 1
        try:
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(descriptor, "rb") as handle:
                info = os.fstat(handle.fileno())
                if not stat.S_ISREG(info.st_mode) or not since <= info.st_mtime <= now + 60:
                    state.rejections["inputRead"] += 1
                    continue
                if info.st_size > MAX_INPUT_BYTES:
                    state.rejections["oversized"] += 1
                    continue
                data = handle.read(MAX_INPUT_BYTES + 1)
        except OSError:
            state.rejections["inputRead"] += 1
            continue
        if len(data) > MAX_INPUT_BYTES:
            state.rejections["oversized"] += 1
            continue
        try:
            header, payload = decode_report(data)
        except (ValueError, UnicodeError, RecursionError, OverflowError):
            state.rejections["malformedJSON"] += 1
            continue
        process = payload.get("procName", header.get("app_name"))
        if not isinstance(process, str) or process not in TEST_PROCESSES:
            state.rejections["unrelatedProcess"] += 1
            continue
        try:
            captured = _timestamp(header, payload)
        except (ValueError, TypeError, OverflowError):
            state.rejections["invalidCaptureTime"] += 1
            continue
        if not since <= captured <= now + 60:
            state.rejections["captureWindow"] += 1
            continue
        try:
            report = sanitize_report(header, payload, since=since, now=now)
            encoded = (json.dumps(report, sort_keys=True, indent=2) + "\n").encode()
        except (ValueError, TypeError, RecursionError, OverflowError):
            state.rejections["invalidStack"] += 1
            continue
        if len(encoded) > MAX_REPORT_BYTES or state.total_bytes + len(encoded) > MAX_TOTAL_BYTES - MAX_SUMMARY_BYTES:
            state.rejections["outputLimit"] += 1
            continue
        try:
            destination = output / ("test-crash-%02d.json" % (state.written + 1))
            descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(encoded)
            state.total_bytes += len(encoded)
            state.written += 1
        except OSError:
            state.rejections["outputWrite"] += 1
            continue
    return state.written


def poll_reports(directories, output, since, wait_seconds=MAX_WAIT_SECONDS, wall_clock=None, monotonic=None, sleeper=None):
    if not isinstance(wait_seconds, (int, float)) or not math.isfinite(wait_seconds) or not 0 <= wait_seconds <= MAX_WAIT_SECONDS:
        raise ValueError("Invalid arrival wait")
    wall_clock = time.time if wall_clock is None else wall_clock
    monotonic = time.monotonic if monotonic is None else monotonic
    sleeper = time.sleep if sleeper is None else sleeper
    state = CollectionState()
    deadline = monotonic() + wait_seconds
    waited = 0
    while True:
        collect_reports(directories, output, since, now=wall_clock(), state=state)
        remaining = deadline - monotonic()
        if state.written or state.inspected >= MAX_CANDIDATES or remaining <= 0:
            break
        interval = min(MAX_POLL_INTERVAL, remaining)
        sleeper(interval)
        waited += interval
    summary = state.summary(waited)
    encoded = (json.dumps(summary, sort_keys=True, indent=2) + "\n").encode()
    if len(encoded) > MAX_SUMMARY_BYTES or state.total_bytes + len(encoded) > MAX_TOTAL_BYTES:
        raise ValueError("Summary exceeds output budget")
    destination = Path(output) / "collection-summary.json"
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(encoded)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--since-file", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--directory", action="append")
    parser.add_argument("--wait-seconds", type=float, default=MAX_WAIT_SECONDS)
    arguments = parser.parse_args()
    try:
        marker = Path(arguments.since_file)
        if marker.is_symlink() or marker.stat().st_size > 64:
            raise ValueError("Invalid diagnostic marker")
        since = float(marker.read_text(encoding="ascii"))
        roots = [Path.home() / "Library/Logs/DiagnosticReports", Path("/Library/Logs/DiagnosticReports")]
        directories = arguments.directory or [path for root in roots for path in (root, root / "Retired")]
        summary = poll_reports(directories, arguments.output, since, wait_seconds=arguments.wait_seconds)
        print("Sanitized test crash collection: " + json.dumps(summary, sort_keys=True))
    except Exception:
        # Diagnostics must not replace or obscure the original test result.
        print("Sanitized test crash collection was unavailable; original test failure is unchanged.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
