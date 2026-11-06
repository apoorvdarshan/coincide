#!/usr/bin/env python3
"""Offline, unsigned preview artifact inventory and validation. Never installs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import sys

PLATFORMS = ('macos', 'windows', 'linux')
BINARIES = ('coincide-rust', 'coincide-rs', 'coincide-store')
KINDS = ('desktop-preview', 'store-tool')


def require(ok, message):
    if not ok:
        raise ValueError(message)


def inventory(root):
    root = Path(root).absolute()
    require(root.is_dir(), 'artifact root must be a directory')
    for path in (root, *root.parents):
        require(not path.is_symlink(), 'symlink in artifact root path')
    files = {}
    folded = set()
    for path in sorted(root.rglob('*')):
        mode = path.lstat().st_mode
        require(not stat.S_ISLNK(mode), 'symlinks are not supported in preview packages')
        require(stat.S_ISDIR(mode) or stat.S_ISREG(mode), 'special files are forbidden')
        name = path.relative_to(root).as_posix()
        require('\\' not in name and ':' not in name, 'non-portable artifact path')
        require(name.casefold() not in folded, 'case-colliding artifact paths')
        folded.add(name.casefold())
        if path.is_file():
            digest = hashlib.sha256()
            with path.open('rb') as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(block)
            files[name] = {'bytes': path.stat().st_size, 'sha256': digest.hexdigest()}
    require(files, 'empty artifact')
    return files


def layout(root, platform, kind='desktop-preview'):
    bundle = platform == 'macos' and kind == 'desktop-preview'
    base = root / 'Coincide Rust.app/Contents' if bundle else root
    bindir = base / 'MacOS' if bundle else base / 'bin'
    if bundle:
        with (base / 'Info.plist').open('rb') as stream:
            info = plistlib.load(stream)
        require(info.get('CFBundleExecutable') == 'coincide-rust', 'wrong bundle executable')
        require(info.get('CFBundleIdentifier') == 'com.apoorvdarshan.coincide.rust', 'preview bundle identity required')
        require(info.get('CFBundleName') == 'Coincide Rust', 'preview bundle name required')
    for name in (BINARIES if kind == 'desktop-preview' else ('coincide-store',)):
        path = bindir / (name + ('.exe' if platform == 'windows' else ''))
        with path.open('rb') as stream:
            magic = stream.read(4)
        valid = {'linux': magic == b'\x7fELF', 'windows': magic[:2] == b'MZ',
                 'macos': magic in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
                                   b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
                                   b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca')}
        require(valid[platform], 'wrong executable header: ' + name)
        if platform != 'windows' and os.name != 'nt':
            require(path.stat().st_mode & 0o111, 'missing executable permission: ' + name)


def manifest(root, platform, version, commit, kind='desktop-preview'):
    require(platform in PLATFORMS, 'unsupported platform')
    require(kind in KINDS, 'unsupported artifact kind')
    require(isinstance(commit, str) and len(commit) == 40 and all(c in '0123456789abcdef' for c in commit), 'full lowercase commit SHA required')
    require(isinstance(version, str) and version and len(version) < 128 and all(c.isalnum() or c in '.-+' for c in version), 'invalid version label')
    files = inventory(root)
    layout(Path(root), platform, kind)
    return {'format': 2, 'kind': kind, 'channel': 'unsigned-preview', 'platform': platform,
            'version': version, 'commit': commit, 'files': files}


def validate(root, document):
    require(isinstance(document, dict), 'manifest must be an object')
    require(document.get('format') == 2 and document.get('channel') == 'unsigned-preview', 'unsupported manifest')
    require(document.get('platform') in PLATFORMS, 'unsupported platform')
    actual = manifest(root, document['platform'], document['version'], document['commit'], document['kind'])
    require(actual == document, 'artifact inventory or metadata mismatch')
    return {'integrity': 'passed', 'kind': document['kind'], 'release_ready': False,
            'unverified': ['architecture', 'dynamic dependencies', 'OS signature/notarization',
                           'manifest authenticity', 'launch', 'updater', 'rollback compatibility']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    create = commands.add_parser('manifest', help='print inventory; redirect OUTSIDE artifact root')
    create.add_argument('root', type=Path)
    create.add_argument('--platform', choices=PLATFORMS, required=True)
    create.add_argument('--kind', choices=KINDS, default='desktop-preview')
    create.add_argument('--version', required=True)
    create.add_argument('--commit', required=True)
    check = commands.add_parser('validate', help='read files only; never execute candidate')
    check.add_argument('root', type=Path)
    check.add_argument('manifest', type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'manifest':
            result = manifest(args.root, args.platform, args.version, args.commit, args.kind)
        else:
            result = validate(args.root, json.loads(args.manifest.read_text()))
        print(json.dumps(result, indent=2, sort_keys=True))
    except (ValueError, OSError, KeyError, TypeError) as error:
        print('validation failed: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
