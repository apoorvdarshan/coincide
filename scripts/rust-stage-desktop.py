#!/usr/bin/env python3
"""Stage explicit built binaries into a new scratch-only unsigned preview artifact."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import sys
import tempfile

spec = importlib.util.spec_from_file_location('rust_packaging', Path(__file__).with_name('rust-packaging.py'))
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


def regular(path):
    path = Path(path).absolute()
    packaging.require(stat.S_ISREG(path.lstat().st_mode), 'input must be a regular non-symlink file: ' + str(path))
    return path


def scratch_parent(path):
    path = Path(path).resolve(strict=True)
    permitted = [Path(tempfile.gettempdir()).resolve()]
    if os.name != 'nt':
        permitted.append(Path('/tmp').resolve())
    packaging.require(path.is_dir() and any(path == p or p in path.parents for p in permitted),
                      'scratch root must be inside the system temporary directory or /tmp')
    return path


def stage(scratch_root, platform, desktop, cli, store, version, commit,
          assets_dir=None, icon=None, minimum_macos=None, build_number='1', helper=None):
    parent = scratch_parent(scratch_root)
    packaging.require(platform in packaging.PLATFORMS, 'unsupported platform')
    packaging.require(re.fullmatch(r'\d+\.\d+\.\d+', version) is not None, 'version must be major.minor.patch')
    packaging.require(re.fullmatch(r'[1-9]\d*', build_number) is not None, 'build number must be a positive integer')
    binaries = [regular(p) for p in (desktop, cli, store)]
    if helper is not None:
        packaging.require(platform == 'macos', 'helper binary is macOS-only')
        helper = regular(helper)
    if assets_dir is not None:
        # inventory checks every nested entry before copytree can follow a symlink.
        assets_dir = Path(assets_dir).absolute()
        packaging.inventory(assets_dir)
        physical_assets = assets_dir.resolve()
        packaging.require(parent != physical_assets and physical_assets not in parent.parents,
                          'scratch root cannot be inside the assets source')
    if icon is not None:
        icon = regular(icon)
    if platform == 'macos':
        packaging.require(minimum_macos is not None and re.fullmatch(r'\d+\.\d+(?:\.\d+)?', minimum_macos),
                          'explicit numeric minimum macOS version required')
        packaging.require(icon is not None, 'explicit .icns icon required for macOS')
        packaging.require(icon.read_bytes()[:4] == b'icns', 'macOS icon must have ICNS header')
    result = Path(tempfile.mkdtemp(prefix='coincide-desktop-stage-', dir=parent)).resolve()
    try:
        artifact = result / 'artifact'
        if platform == 'macos':
            contents = artifact / 'Coincide Rust.app/Contents'
            bindir, resources = contents / 'MacOS', contents / 'Resources'
        else:
            bindir, resources = artifact / 'bin', artifact / 'resources'
        bindir.mkdir(parents=True)
        resources.mkdir(parents=True)
        for name, source in zip(packaging.BINARIES, binaries):
            target = bindir / (name + ('.exe' if platform == 'windows' else ''))
            shutil.copyfile(source, target)
            target.chmod(0o755)
        if helper is not None:
            target = bindir / 'CoincideRustUpdater'
            shutil.copyfile(helper, target)
            target.chmod(0o755)
        if assets_dir is not None:
            # Keep caller assets in a namespace that cannot replace generated files.
            shutil.copytree(assets_dir, resources / 'assets')
        if icon is not None:
            shutil.copyfile(icon, resources / ('CoincideRust.icns' if platform == 'macos' else 'AppIcon' + icon.suffix))
        if platform == 'macos':
            info = {'CFBundleIdentifier': 'com.apoorvdarshan.coincide.rust',
                    'CFBundleExecutable': 'coincide-rust', 'CFBundleName': 'Coincide Rust',
                    'CFBundleDisplayName': 'Coincide Rust', 'CFBundlePackageType': 'APPL',
                    'CFBundleShortVersionString': version, 'CFBundleVersion': build_number,
                    'CFBundleIconFile': 'CoincideRust.icns', 'LSMinimumSystemVersion': minimum_macos,
                    'NSHighResolutionCapable': True, 'NSPrincipalClass': 'NSApplication',
                    'NSMicrophoneUsageDescription': 'Record audio for Voice dictation only when you start recording.',
                    'NSSpeechRecognitionUsageDescription': 'Transcribe your Voice dictation on this device when you choose Apple Speech.'}
            (contents / 'Info.plist').write_bytes(plistlib.dumps(info, sort_keys=True))
        manifest = packaging.manifest(artifact, platform, version, commit)
        validation = packaging.validate(artifact, manifest)
        (result / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
        inputs = [str(p) for p in binaries] + ([str(helper)] if helper is not None else [])
        report = {'artifact': str(artifact), 'manifest': str(result / 'manifest.json'),
                  'validation': validation, 'build_number': build_number,
                  'source_inputs': inputs}
        (result / 'validation.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        return report
    except BaseException:
        # This unique directory was created here; never remove supplied inputs.
        shutil.rmtree(result)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scratch-root', type=Path, required=True)
    parser.add_argument('--platform', choices=packaging.PLATFORMS, required=True)
    parser.add_argument('--desktop-bin', type=Path, required=True)
    parser.add_argument('--cli-bin', type=Path, required=True)
    parser.add_argument('--store-bin', type=Path, required=True)
    parser.add_argument('--helper-bin', type=Path)
    parser.add_argument('--version', required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--assets-dir', type=Path)
    parser.add_argument('--icon', type=Path)
    parser.add_argument('--minimum-macos-version')
    parser.add_argument('--build-number', default='1')
    args = parser.parse_args()
    try:
        print(json.dumps(stage(args.scratch_root, args.platform, args.desktop_bin, args.cli_bin,
                               args.store_bin, args.version, args.commit, args.assets_dir, args.icon,
                               args.minimum_macos_version, args.build_number, args.helper_bin), indent=2))
    except (ValueError, OSError, KeyError, TypeError) as error:
        print('staging failed: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
