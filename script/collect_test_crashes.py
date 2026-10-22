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


def collect_reports(directories, output, since, now=None):
    now = time.time() if now is None else now
    if not math.isfinite(since) or not now - 3 * 3600 <= since <= now + 60:
        raise ValueError("Invalid diagnostic window")
    candidates = []
    for directory in directories:
        directory = Path(directory)
        if directory.is_symlink():
            continue
        try:
            with os.scandir(directory) as entries:
                for count, entry in enumerate(entries):
                    if count >= MAX_DIRECTORY_ENTRIES:
                        break
                    if not entry.name.endswith(".ips") or not any(entry.name.startswith(name + "-") or entry.name.startswith(name + "_") for name in TEST_PROCESSES):
                        continue
                    info = entry.stat(follow_symlinks=False)
                    if stat.S_ISREG(info.st_mode) and since <= info.st_mtime <= now + 60 and info.st_size <= MAX_INPUT_BYTES:
                        candidates.append((info.st_mtime, Path(entry.path)))
        except OSError:
            continue
    candidates.sort(key=lambda item: item[0], reverse=True)
    output = Path(output)
    if output.is_symlink():
        raise ValueError("Invalid output directory")
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    written, total = 0, 0
    for _, path in candidates[:MAX_CANDIDATES]:
        if written >= MAX_REPORTS:
            break
        try:
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(descriptor, "rb") as handle:
                info = os.fstat(handle.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_INPUT_BYTES or info.st_mtime < since:
                    continue
                data = handle.read(MAX_INPUT_BYTES + 1)
            report = sanitize_report(*decode_report(data), since=since, now=now)
            encoded = (json.dumps(report, sort_keys=True, indent=2) + "\n").encode()
            if len(encoded) > MAX_REPORT_BYTES or total + len(encoded) > MAX_TOTAL_BYTES:
                continue
            destination = output / ("test-crash-%02d.json" % (written + 1))
            descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(encoded)
            total += len(encoded)
            written += 1
        except (OSError, ValueError, UnicodeError, RecursionError, OverflowError):
            # Never print raw input, report paths, exception payloads, or parser errors.
            continue
    return written


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--since-file", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--directory", action="append")
    arguments = parser.parse_args()
    try:
        marker = Path(arguments.since_file)
        if marker.is_symlink() or marker.stat().st_size > 64:
            raise ValueError("Invalid diagnostic marker")
        since = float(marker.read_text(encoding="ascii"))
        directories = arguments.directory or [Path.home() / "Library/Logs/DiagnosticReports", Path("/Library/Logs/DiagnosticReports")]
        count = collect_reports(directories, arguments.output, since)
        print("Sanitized test crash reports written: %d." % count)
    except Exception:
        # Diagnostics must not replace or obscure the original test result.
        print("Sanitized test crash collection was unavailable; original test failure is unchanged.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
