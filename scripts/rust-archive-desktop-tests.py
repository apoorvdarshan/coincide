#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import stat
import sys
import tempfile
import unittest
import warnings
import zipfile

spec = importlib.util.spec_from_file_location('archiver', Path(__file__).with_name('rust-archive-desktop.py'))
archive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archive)


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def fixture(self, platform):
        paths = [self.root / name for name in ('desktop', 'cli', 'store')]
        for path in paths:
            path.write_bytes({'macos': b'\xcf\xfa\xed\xfe', 'windows': b'MZ00', 'linux': b'\x7fELF'}[platform])
        icon = self.root / 'fixture.icns'
        icon.write_bytes(b'icns\x00\x00\x00\x08')
        assets = self.root / 'assets'
        assets.mkdir(exist_ok=True)
        (assets / 'Unicode-日本語.txt').write_text('fixture')
        return archive.staging.stage(self.root, platform, *paths, '0.1.0', 'a' * 40, assets, icon, '11.0')

    def test_portable_roundtrips_all_platforms(self):
        for platform in archive.packaging.PLATFORMS:
            with self.subTest(platform=platform):
                stage = self.fixture(platform)
                report = archive.create(stage['artifact'], stage['manifest'], self.root, ['zip', 'tar.gz'])
                self.assertEqual(len(report['archives']), 2)
                self.assertFalse(report['release_ready'])
                self.assertEqual(report['signing_status']['container'], 'unsigned')
                for item in report['archives']:
                    self.assertEqual(item['sha256'], archive.digest(Path(item['path'])))
                self.assertTrue(Path(stage['artifact']).is_dir())

    def test_traversal_duplicate_and_link_refusal(self):
        for name, mode, twice in (('../outside', stat.S_IFREG | 0o644, False),
                                  ('known', stat.S_IFLNK | 0o777, False),
                                  ('known', stat.S_IFREG | 0o644, True)):
            with self.subTest(name=name, mode=mode, twice=twice), tempfile.TemporaryDirectory(dir=self.root) as tmp:
                root = Path(tmp)
                path = root / 'bad.zip'
                with zipfile.ZipFile(path, 'w') as target:
                    info = zipfile.ZipInfo(name)
                    info.external_attr = mode << 16
                    target.writestr(info, b'x')
                    if twice:
                        with warnings.catch_warnings():
                            warnings.simplefilter('ignore', UserWarning)
                            duplicate = zipfile.ZipInfo(name)
                            duplicate.external_attr = mode << 16
                            target.writestr(duplicate, b'x')
                with self.assertRaises(ValueError):
                    archive.extract_portable(path, root / 'out', {'known': {'bytes': 1}}, 'zip')
                self.assertFalse((root / 'outside').exists())

    def test_changed_input_and_nested_output_refused(self):
        stage = self.fixture('linux')
        with self.assertRaises(ValueError):
            archive.create(stage['artifact'], stage['manifest'], stage['artifact'], ['zip'])
        (Path(stage['artifact']) / 'bin/coincide-store').write_bytes(b'changed')
        with self.assertRaises(ValueError):
            archive.create(stage['artifact'], stage['manifest'], self.root, ['zip'])

    @unittest.skipUnless(sys.platform == 'darwin', 'DMG tools require macOS')
    def test_synthetic_dmg_without_mount(self):
        stage = self.fixture('macos')
        report = archive.create(stage['artifact'], stage['manifest'], self.root, ['dmg'])
        self.assertFalse(report['task_images_attached'])
        self.assertEqual(report['archives'][0]['extracted_validation']['integrity'], 'passed')


if __name__ == '__main__':
    unittest.main()
