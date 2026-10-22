"""Synthetic Mach-O guard checks; never build or inspect developer build outputs."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("check_async_default_contexts", Path(__file__).resolve().parents[2] / "script/check_async_default_contexts.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def symbol(module="CoincideCore", suffix="7FixtureV6actionACyyYaYbc_tcfcfA_yyYaYbcfU_Tu"):
    return "_$s%d%s%s" % (len(module), module, suffix)


def object_bytes(entries, duplicate_symtab=False):
    """A real thin arm64 MH_OBJECT with __const data and LC_SYMTAB/nlist_64."""
    command_bytes = 152 + 24 * (2 if duplicate_symtab else 1)
    data_offset = 32 + command_bytes
    records = b"".join(struct.pack("<iI", 0, entry.get("context", 32)) for entry in entries)
    symbol_offset = data_offset + len(records)
    strings = bytearray(b"\0")
    symbols = bytearray()
    for i, entry in enumerate(entries):
        name = entry.get("symbol", symbol()).encode()
        index = len(strings)
        strings += name + b"\0"
        symbols += struct.pack("<IBBHQ", index, entry.get("kind", 0x1f), entry.get("section", 1),
                               entry.get("description", 0x80), entry.get("value", 0x1000 + i * 8))
    strings_offset = symbol_offset + len(symbols)
    header = struct.pack("<IIIIIIII", 0xfeedfacf, 0x100000c, 0, 1, 3 if duplicate_symtab else 2, command_bytes, 0, 0)
    segment = struct.pack("<II16sQQQQiiII", 0x19, 152, b"__TEXT", 0x1000, len(records), data_offset, len(records), 7, 7, 1, 0)
    section = struct.pack("<16s16sQQIIIIIIII", b"__const", b"__TEXT", 0x1000, len(records), data_offset, 3, 0, 0, 0, 0, 0, 0)
    table = struct.pack("<IIIIII", 2, 24, symbol_offset, len(entries), strings_offset, len(strings))
    return header + segment + section + table * (2 if duplicate_symtab else 1) + records + symbols + strings


def changed(data, offset, value, form="<I"):
    result = bytearray(data)
    struct.pack_into(form, result, offset, value)
    return bytes(result)


def write_object(root, relative, entries):
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(object_bytes(entries))
    return path


def write_coverage(root):
    core = write_object(root, "arm64-apple-macosx/debug/CoincideCore.build/Library.swift.o", [
        {"symbol": symbol(suffix="7FixtureV4workyyF"), "description": 0}])
    app = write_object(root, "out/Intermediates.noindex/Coincide.build/Debug/Coincide-t.build/Objects-normal/arm64/App.o", [
        {"symbol": symbol("Coincide", "7FixtureV4workyyF"), "description": 0}])
    return core, app


class AsyncDefaultContextsTests(unittest.TestCase):
    def test_library_client_48_32_records_are_measured_and_weak_private_external_is_rejected(self):
        for size in (48, 32):
            modules, records = guard.inspect_macho(object_bytes([{"context": size}]))
            self.assertEqual(modules, {"CoincideCore"})
            self.assertEqual(records, [{"symbol": symbol(), "contextBytes": size, "weak": True}])
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            write_coverage(root)
            write_object(root, "Library.o", [{"context": 48}])
            write_object(root, "Client.o", [{"context": 32}])
            result = guard.check_build_roots([root])
            self.assertFalse(result["failures"])
            self.assertEqual(result["weakDefaultRecords"], 2)
            self.assertEqual(sorted(row["contextBytes"] for row in result["violations"]), [32, 48])

    def test_even_equal_weak_contexts_fail_instead_of_only_rejecting_a_known_mismatch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            write_coverage(root)
            write_object(root, "First.o", [{"context": 32}])
            write_object(root, "Second.o", [{"context": 32}])
            self.assertEqual(guard.check_build_roots([root])["weakDefaultRecords"], 2)
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(guard.main([str(root)]), 1)

    def test_local_and_nonweak_private_or_external_records_are_allowed(self):
        entries = [{"kind": 0x0e, "description": 0}, {"kind": 0x1f, "description": 0},
                   {"kind": 0x0f, "description": 0}]
        modules, records = guard.inspect_macho(object_bytes(entries))
        self.assertEqual(modules, {"CoincideCore"})
        self.assertEqual(len(records), 3)
        self.assertTrue(all(not row["weak"] for row in records))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            write_coverage(root)
            write_object(root, "Local.o", entries)
            result = guard.check_build_roots([root])
            self.assertEqual(result["localDefaultRecords"], 3)
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(guard.main([str(root)]), 0)

    def test_stab_undefined_absolute_and_foreign_symbols_neither_match_nor_supply_coverage(self):
        entries = [{"kind": 0xef, "section": 255}, {"kind": 1, "section": 0, "description": 0x40},
                   {"kind": 3, "section": 0}, {"symbol": symbol("Foreign", "12CoincideCore6fA_fU_Tu")},
                   {"symbol": "_$s7CoincideCore7FixtureV6actionfA_fU_Tu"}]
        modules, records = guard.inspect_macho(object_bytes(entries))
        self.assertFalse(modules)
        self.assertFalse(records)

    def test_actual_candidate_extraction_requires_owned_default_async_closure_Tu(self):
        wanted = symbol(suffix="7FixtureV6actionACyyYaYbc_tcfcfA12_yyYaYbcfU3_Tu")
        entries = [{"symbol": wanted}, {"symbol": symbol(suffix="7FixtureV6actionyyYaFTu")},
                   {"symbol": symbol(suffix="7FixtureV6actionACyyc_tcfcfA_yycfU_")},
                   {"symbol": symbol(suffix="7FixtureV6actionACyyYaYbc_tcfcfA_yyYaYbcfU_")},
                   {"symbol": symbol("CoincideUITests")}]
        modules, records = guard.inspect_macho(object_bytes(entries))
        self.assertEqual(modules, {"CoincideCore", "CoincideUITests"})
        self.assertEqual([row["symbol"] for row in records], [wanted, symbol("CoincideUITests")])

    def test_malformed_recognized_headers_commands_sections_and_symbol_tables_fail_closed(self):
        valid = object_bytes([{}])
        symtab = 32 + 152
        symbol_offset, _, strings_offset, strings_size = struct.unpack_from("<IIII", valid, symtab + 8)
        cases = [valid[:20], changed(valid, 20, len(valid)), changed(valid, 36, 0),
                 changed(valid, 36, 7), changed(valid, 36, 24), changed(valid, 32 + 64, 2),
                 changed(valid, symtab + 4, 16), changed(valid, symtab + 8, len(valid) + 1),
                 changed(valid, symtab + 16, len(valid) + 1),
                 changed(valid, symbol_offset, strings_size + 1), valid[:-1] + b"X",
                 changed(valid, symbol_offset + 5, 255, "<B"),
                 changed(valid, symbol_offset + 8, 0xfff, "<Q"),
                 changed(valid, symbol_offset + 8, 0x1004, "<Q"),
                 changed(valid, 32 + 72 + 48, len(valid) + 1), object_bytes([{}], duplicate_symtab=True)]
        for data in cases:
            with self.subTest(size=len(data)):
                with self.assertRaises(guard.InvalidObject):
                    guard.inspect_macho(data)
        self.assertLess(strings_offset, len(valid))

    def test_unreadable_object_and_malformed_foreign_object_are_failures_despite_good_coverage(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            write_coverage(root)
            bad = root / "Broken.o"
            bad.write_bytes(guard.MAGIC)
            result = guard.check_build_roots([root])
            self.assertIn({"object": "Broken.o", "reason": "headerBounds"}, result["failures"])
            original = Path.read_bytes
            def read(path):
                if path == bad:
                    raise PermissionError("PRIVATE_ERROR_PAYLOAD")
                return original(path)
            with patch.object(Path, "read_bytes", read):
                result = guard.check_build_roots([root])
            self.assertIn({"object": "Broken.o", "reason": "objectUnreadable"}, result["failures"])
            self.assertNotIn("PRIVATE_ERROR_PAYLOAD", json.dumps(result))

    def test_both_native_and_swiftbuild_object_layouts_are_discovered_once(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            core, app = write_coverage(root)
            (root / "NotAnObject.txt").write_bytes(object_bytes([{}]))
            (root / "Foreign.o").write_bytes(object_bytes([{"symbol": symbol("Foreign")}]))
            (root / "Bitcode.o").write_bytes(b"BC\xc0\xde")
            nested = root / "outside-link"
            nested.symlink_to(root / "out", target_is_directory=True)
            (root / "Object-link.o").symlink_to(core)
            candidates = guard.object_candidates([root, root / "out"])
            self.assertEqual({path for path, _ in candidates}, {core, app, root / "Foreign.o", root / "Bitcode.o"})
            result = guard.check_build_roots([root])
            self.assertFalse(result["failures"])
            self.assertEqual(result["coverage"], {"Coincide": 1, "CoincideCore": 1})
            self.assertEqual(result["objects"], 4)
            self.assertEqual(result["machObjects"], 3)

    def test_missing_empty_foreign_and_single_module_roots_cannot_report_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            for inputs in ([root / "missing"], [root]):
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(guard.main([str(value) for value in inputs]), 1)
            for module in ("Coincide", "CoincideCore", "Foreign"):
                directory = root / module
                write_object(directory, "Only.o", [{"symbol": symbol(module), "description": 0}])
                result = guard.check_build_roots([directory])
                self.assertIn({"reason": "missingCoincideModuleCoverage"}, result["failures"])
            # A named test module is not evidence that the app itself was scanned.
            write_object(root / "tests-only", "Tests.o", [{"symbol": symbol("CoincideCoreTests"), "description": 0}])
            self.assertIn({"reason": "missingCoincideModuleCoverage"}, guard.check_build_roots([root / "tests-only"])["failures"])

    def test_cli_reports_only_compact_counts_relative_object_and_affected_symbol_context(self):
        with tempfile.TemporaryDirectory(prefix="coincide-PRIVATE_ACCOUNT-") as temporary:
            root = Path(temporary).resolve()
            write_coverage(root)
            path = write_object(root, "target/Owned.o", [{"context": 48}])
            # Unreferenced arbitrary bytes never enter diagnostic output.
            path.write_bytes(path.read_bytes() + b"PRIVATE_BINARY_PAYLOAD")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                code = guard.main([str(root)])
            text = output.getvalue()
            self.assertEqual(code, 1)
            self.assertNotIn(str(root), text)
            self.assertNotIn("PRIVATE_", text)
            self.assertIn('"object": "target/Owned.o"', text)
            self.assertIn('"contextBytes": 48', text)
            self.assertIn(symbol(), text)
            self.assertEqual(len(text.splitlines()), 2)

    def test_other_macho_formats_are_rejected_and_nonmacho_data_cannot_supply_coverage(self):
        for magic in guard.OTHER_MACHO:
            with self.subTest(magic=magic):
                with self.assertRaises(guard.InvalidObject):
                    guard.inspect_macho(magic + bytes(64))
        self.assertIsNone(guard.inspect_macho(b"not a Mach-O object"))
        self.assertIsNone(guard.inspect_macho(b""))


if __name__ == "__main__":
    unittest.main()
