#!/usr/bin/env python3
"""Lightweight validator regressions; fixture headers are NOT runnable artifacts."""
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('packaging', Path(__file__).with_name('rust-packaging.py'))
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def fixture(self, platform='linux'):
        base = self.root / 'Coincide Rust.app/Contents' if platform == 'macos' else self.root
        binaries = base / ('MacOS' if platform == 'macos' else 'bin')
        binaries.mkdir(parents=True)
        if platform == 'macos':
            (base / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleExecutable': 'coincide-rust', 'CFBundleName': 'Coincide Rust',
                'CFBundleIdentifier': 'com.apoorvdarshan.coincide.rust'}))
        for name in packaging.BINARIES:
            path = binaries / (name + ('.exe' if platform == 'windows' else ''))
            path.write_bytes({'linux': b'\x7fELF', 'windows': b'MZ00', 'macos': b'\xcf\xfa\xed\xfe'}[platform])
            path.chmod(0o755)
        return packaging.manifest(self.root, platform, '0.1.0-preview', 'a' * 40)

    def test_all_platform_layouts(self):
        for platform in packaging.PLATFORMS:
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as directory:
                self.root = Path(directory).resolve()
                result = packaging.validate(self.root, self.fixture(platform))
                self.assertFalse(result['release_ready'])

    def test_modified_file(self):
        manifest = self.fixture()
        (self.root / 'bin/coincide-store').write_bytes(b'\x7fELFchanged')
        with self.assertRaises(ValueError):
            packaging.validate(self.root, manifest)

    def test_extra_file(self):
        manifest = self.fixture()
        (self.root / 'unexpected').write_text('extra')
        with self.assertRaises(ValueError):
            packaging.validate(self.root, manifest)

    def test_missing_file(self):
        manifest = self.fixture()
        (self.root / 'bin/coincide-rs').unlink()
        with self.assertRaises(OSError):
            packaging.validate(self.root, manifest)

    def test_symlink(self):
        self.fixture()
        try:
            (self.root / 'link').symlink_to(self.root / 'bin/coincide-rs')
        except OSError:
            self.skipTest('host does not permit symlinks')
        with self.assertRaises(ValueError):
            packaging.inventory(self.root)

    def test_wrong_header(self):
        manifest = self.fixture()
        (self.root / 'bin/coincide-rs').write_bytes(b'MZ00')
        with self.assertRaises(ValueError):
            packaging.validate(self.root, manifest)

    def test_production_bundle_refused(self):
        self.fixture('macos')
        path = self.root / 'Coincide Rust.app/Contents/Info.plist'
        info = plistlib.loads(path.read_bytes())
        info['CFBundleIdentifier'] = 'com.apoorvdarshan.coincide'
        path.write_bytes(plistlib.dumps(info))
        with self.assertRaises(ValueError):
            packaging.layout(self.root, 'macos')

    def test_store_tool_cannot_pass_desktop_layout(self):
        self.fixture()
        (self.root / 'bin/coincide-rust').unlink()
        (self.root / 'bin/coincide-rs').unlink()
        manifest = packaging.manifest(self.root, 'linux', 'test', 'a' * 40, 'store-tool')
        self.assertEqual(packaging.validate(self.root, manifest)['kind'], 'store-tool')
        manifest['kind'] = 'desktop-preview'
        with self.assertRaises(OSError):
            packaging.validate(self.root, manifest)

    def test_malformed_manifest(self):
        self.fixture()
        for value in (None, [], 'bad', {}, {'format': 1}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                packaging.validate(self.root, value)

    def test_malformed_labels(self):
        manifest = self.fixture()
        for key, value in (('commit', 13), ('commit', '../'), ('version', []),
                           ('kind', 'release'), ('platform', 'unknown')):
            changed = dict(manifest, **{key: value})
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                packaging.validate(self.root, changed)

    def test_no_metadata_escalation(self):
        manifest = self.fixture()
        manifest['channel'] = 'stable'
        with self.assertRaises(ValueError):
            packaging.validate(self.root, manifest)


def load_tests(loader, tests, pattern):
    # Keep dedicated packaging CI's existing test entry point covering staging.
    staging_spec = importlib.util.spec_from_file_location(
        'staging_tests', Path(__file__).with_name('rust-stage-desktop-tests.py'))
    staging_tests = importlib.util.module_from_spec(staging_spec)
    staging_spec.loader.exec_module(staging_tests)
    tests.addTests(loader.loadTestsFromModule(staging_tests))
    return tests


if __name__ == '__main__':
    unittest.main()
