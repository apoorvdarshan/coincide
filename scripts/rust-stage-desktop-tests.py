#!/usr/bin/env python3
"""Staging regression fixtures contain headers only; they never execute."""
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('stage', Path(__file__).with_name('rust-stage-desktop.py'))
staging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staging)


class StagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.assets = self.root / 'selected-assets'
        self.assets.mkdir()
        (self.assets / 'fixture.txt').write_bytes(b'asset bytes')
        self.icon = self.root / 'icon.icns'
        self.icon.write_bytes(b'icns\x00\x00\x00\x08')
        self.binaries = [self.root / name for name in ('desktop', 'cli', 'store')]

    def run_stage(self, platform='macos'):
        magic = {'macos': b'\xcf\xfa\xed\xfe', 'windows': b'MZ00', 'linux': b'\x7fELF'}[platform]
        for p in self.binaries:
            p.write_bytes(magic + p.name.encode())
        return staging.stage(self.root, platform, *self.binaries, '0.1.0', 'a' * 40,
                             self.assets, self.icon, '13.0')

    def test_all_layouts_and_source_preservation(self):
        for host in staging.packaging.PLATFORMS:
            with self.subTest(platform=host):
                report = self.run_stage(host)
                artifact = Path(report['artifact'])
                resources = artifact / ('Coincide Rust.app/Contents/Resources' if host == 'macos' else 'resources')
                self.assertEqual((resources / 'assets/fixture.txt').read_bytes(), b'asset bytes')
                self.assertFalse(report['validation']['release_ready'])
                self.assertEqual(len(list(artifact.rglob('manifest.json'))), 0)
                for p in self.binaries:
                    self.assertTrue(p.read_bytes().endswith(p.name.encode()))
                if host == 'macos':
                    info = plistlib.loads((artifact / 'Coincide Rust.app/Contents/Info.plist').read_bytes())
                    self.assertEqual(info['CFBundleIdentifier'], 'com.apoorvdarshan.coincide.rust')
                    self.assertEqual(info['CFBundleIconFile'], 'CoincideRust.icns')
                    self.assertEqual(info['LSMinimumSystemVersion'], '13.0')

    def test_never_replaces_existing_stage(self):
        first = self.run_stage()
        second = self.run_stage()
        self.assertNotEqual(first['artifact'], second['artifact'])
        self.assertTrue(Path(first['artifact']).is_dir())

    def test_symlink_asset_refused(self):
        try:
            (self.assets / 'link').symlink_to(self.icon)
        except OSError:
            self.skipTest('host lacks symlink privilege')
        with self.assertRaises(ValueError):
            self.run_stage()
        self.assertFalse(list(self.root.glob('coincide-desktop-stage-*')))

    def test_bad_binary_cleans_only_own_stage(self):
        self.run_stage()
        existing = set(self.root.glob('coincide-desktop-stage-*'))
        self.binaries[0].write_bytes(b'bad')
        with self.assertRaises(ValueError):
            staging.stage(self.root, 'macos', *self.binaries, '0.1.0', 'a' * 40,
                          icon=self.icon, minimum_macos='13.0')
        self.assertEqual(existing, set(self.root.glob('coincide-desktop-stage-*')))
        self.assertEqual(self.binaries[0].read_bytes(), b'bad')

    def test_recursive_asset_destination_refused(self):
        self.run_stage()
        with self.assertRaises(ValueError):
            staging.stage(self.assets, 'linux', *self.binaries, '0.1.0', 'a' * 40,
                          assets_dir=self.assets)

    def test_missing_macos_icon_refused_before_output(self):
        self.run_stage()
        existing = set(self.root.glob('coincide-desktop-stage-*'))
        with self.assertRaises(ValueError):
            staging.stage(self.root, 'macos', *self.binaries, '0.1.0', 'a' * 40,
                          minimum_macos='13.0')
        self.assertEqual(existing, set(self.root.glob('coincide-desktop-stage-*')))

    def test_non_scratch_destination_refused(self):
        # Filesystem root is outside system temp on all supported hosts.
        with self.assertRaises(ValueError):
            staging.scratch_parent(Path(self.root.anchor))


if __name__ == '__main__':
    unittest.main()
