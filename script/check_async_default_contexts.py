#!/usr/bin/env python3
"""Reject weak async default-argument closures in existing Coincide Mach-O objects.

Read-only guard for the trigger reported in swiftlang/swift#92017. This does not
prove a particular linked body/record mismatch or diagnose an earlier crash.
Accepts build roots from both native SwiftPM and Swift 6.4 swiftbuild layouts.
"""
import argparse
import json
import os
from pathlib import Path
import re
import stat
import struct

MAGIC = b"\xcf\xfa\xed\xfe"
OTHER_MACHO = {b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce",
               b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
DEFAULT_CLOSURE = re.compile(r"fA[0-9]*_.*fU[0-9]*_Tu$")
REQUIRED_MODULES = ("Coincide", "CoincideCore")
MAX_OBJECT_BYTES = 512 * 1024 * 1024


class InvalidObject(ValueError):
    """Only fixed reason codes may be exposed by the command-line guard."""


def _module(symbol):
    match = re.match(r"_?\$s([0-9]{1,6})", symbol)
    if not match:
        return None
    end = match.end() + int(match[1])
    value = symbol[match.end():end]
    return value if end <= len(symbol) and re.fullmatch(r"Coincide[A-Za-z0-9_]*", value) else None


def inspect_macho(data):
    """Return (defined owning modules, default Tu records), or None for non-Mach-O."""
    if data[:4] != MAGIC:
        if data[:4] in OTHER_MACHO:
            raise InvalidObject("unsupportedMachO")
        return None
    if len(data) < 32:
        raise InvalidObject("headerBounds")
    count, command_bytes = struct.unpack_from("<II", data, 16)
    end_commands = 32 + command_bytes
    if end_commands > len(data):
        raise InvalidObject("loadCommandBounds")
    sections, symtab, offset = [], None, 32
    for _ in range(count):
        if offset + 8 > end_commands:
            raise InvalidObject("loadCommandBounds")
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or size % 8 or offset + size > end_commands:
            raise InvalidObject("loadCommandBounds")
        if command == 0x19:  # LC_SEGMENT_64
            if size < 72:
                raise InvalidObject("sectionBounds")
            nsections = struct.unpack_from("<I", data, offset + 64)[0]
            if 72 + nsections * 80 > size:
                raise InvalidObject("sectionBounds")
            for i in range(nsections):
                start = offset + 72 + i * 80
                address, length, fileoffset = struct.unpack_from("<QQI", data, start + 32)
                flags = struct.unpack_from("<I", data, start + 64)[0]
                zero_fill = flags & 0xff in (1, 0x0c, 0x12)
                if not zero_fill and fileoffset + length > len(data):
                    raise InvalidObject("sectionBounds")
                sections.append((address, length, fileoffset, zero_fill))
        elif command == 2:  # LC_SYMTAB
            if size < 24 or symtab is not None:
                raise InvalidObject("symbolTableBounds")
            symtab = struct.unpack_from("<IIII", data, offset + 8)
        offset += size
    if offset != end_commands:
        raise InvalidObject("loadCommandBounds")
    if symtab is None:
        return set(), []
    symbols, nsymbols, strings, string_bytes = symtab
    if symbols + nsymbols * 16 > len(data) or strings + string_bytes > len(data):
        raise InvalidObject("symbolTableBounds")
    modules, records = set(), []
    for i in range(nsymbols):
        index, kind, section, description, value = struct.unpack_from("<IBBHQ", data, symbols + i * 16)
        if index >= string_bytes and index != 0:
            raise InvalidObject("symbolStringBounds")
        if not index:
            continue
        end = data.find(b"\0", strings + index, strings + string_bytes)
        if end < 0:
            raise InvalidObject("symbolStringBounds")
        # Undefined, absolute and stab/debug entries are not section definitions.
        if kind & 0xe0 or kind & 0x0e != 0x0e:
            continue
        if not 1 <= section <= len(sections):
            raise InvalidObject("symbolSectionBounds")
        symbol = data[strings + index:end].decode("utf-8", errors="replace")
        module = _module(symbol)
        if module is None:
            continue
        modules.add(module)
        if not DEFAULT_CLOSURE.search(symbol):
            continue
        if len(symbol) > 4096 or not all(32 <= ord(c) <= 126 for c in symbol):
            raise InvalidObject("invalidDefaultSymbol")
        address, length, fileoffset, zero_fill = sections[section - 1]
        at = fileoffset + value - address
        if zero_fill or value < address or value + 8 > address + length or at < 0 or at + 8 > len(data):
            raise InvalidObject("contextRecordBounds")
        context = struct.unpack_from("<I", data, at + 4)[0]
        # N_PEXT (0x10) is deliberately NOT exempt: the observed bad copies are
        # weak private external definitions. Local/non-weak records are allowed.
        records.append({"symbol": symbol, "contextBytes": context, "weak": bool(description & 0x80)})
    return modules, records


def object_candidates(roots):
    """Discover .o files without following symlink subdirectories or object links."""
    candidates = {}
    for root in roots:
        root = Path(root).resolve()
        if not root.is_dir():
            raise InvalidObject("buildRootUnavailable")
        def failed(_):
            raise InvalidObject("buildRootUnreadable")
        try:
            for directory, _, files in os.walk(root, followlinks=False, onerror=failed):
                for name in files:
                    if not name.endswith(".o"):
                        continue
                    path = Path(directory) / name
                    if path.is_symlink():
                        continue
                    candidates.setdefault(path, path.relative_to(root).as_posix())
        except OSError:
            raise InvalidObject("buildRootUnreadable") from None
    return sorted(candidates.items())


def check_build_roots(roots):
    summary = {"objects": 0, "machObjects": 0, "coverage": dict.fromkeys(REQUIRED_MODULES, 0),
               "localDefaultRecords": 0, "weakDefaultRecords": 0, "failures": [], "violations": []}
    try:
        candidates = object_candidates(roots)
    except (OSError, InvalidObject):
        summary["failures"].append({"reason": "buildRootUnavailable"})
        return summary
    for path, relative in candidates:
        summary["objects"] += 1
        try:
            if not stat.S_ISREG(path.stat().st_mode) or path.stat().st_size > MAX_OBJECT_BYTES:
                raise InvalidObject("objectBounds")
            result = inspect_macho(path.read_bytes())
        except OSError:
            summary["failures"].append({"object": relative, "reason": "objectUnreadable"})
            continue
        except InvalidObject as error:
            summary["failures"].append({"object": relative, "reason": str(error)})
            continue
        if result is None:
            continue
        summary["machObjects"] += 1
        modules, records = result
        for module in REQUIRED_MODULES:
            summary["coverage"][module] += module in modules
        for record in records:
            if record["weak"]:
                summary["weakDefaultRecords"] += 1
                summary["violations"].append({"object": relative, "symbol": record["symbol"], "contextBytes": record["contextBytes"]})
            else:
                summary["localDefaultRecords"] += 1
    if not all(summary["coverage"].values()):
        summary["failures"].append({"reason": "missingCoincideModuleCoverage"})
    return summary


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("roots", nargs="*", type=Path, help="existing build root(s), default .build")
    args = parser.parse_args(argv)
    summary = check_build_roots(args.roots or [Path(".build")])
    counts = {key: summary[key] for key in ("objects", "machObjects", "coverage", "localDefaultRecords", "weakDefaultRecords")}
    print("Async default ABI guard: " + json.dumps(counts, sort_keys=True))
    for issue in summary["failures"][:20]:
        print("error: " + json.dumps(issue, sort_keys=True))
    for record in summary["violations"][:20]:
        print("weak default async closure: " + json.dumps(record, sort_keys=True))
    if len(summary["failures"]) > 20 or len(summary["violations"]) > 20:
        print("Additional diagnostics omitted; counts above retain the failure.")
    return 1 if summary["failures"] or summary["violations"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
