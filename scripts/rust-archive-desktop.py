#!/usr/bin/env python3
"""Create unsigned scratch archives and verify extracted content; never mount or run."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile

spec = importlib.util.spec_from_file_location('staging', Path(__file__).with_name('rust-stage-desktop.py'))
staging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staging)
packaging = staging.packaging


def safe_name(name):
    path = PurePosixPath(name)
    packaging.require(name and not path.is_absolute() and '..' not in path.parts and
                      '\\' not in name and ':' not in name and
                      all(ord(c) >= 32 for c in name), 'unsafe archive path')
    return path


def extract_portable(archive, output, files, kind):
    """Exact allowlist extraction; never use extractall or honor links/owners."""
    output.mkdir()
    seen = set()
    def copy(name, size, mode, stream):
        path = safe_name(name)
        packaging.require(name in files and name not in seen, 'unexpected or duplicate archive member')
        packaging.require(size == files[name]['bytes'], 'archive member size differs')
        seen.add(name)
        dest = output.joinpath(*path.parts)
        dest.parent.mkdir(parents=True, exist_ok=True)
        with dest.open('xb') as target:
            remaining = size
            while remaining:
                block = stream.read(min(1024 * 1024, remaining))
                packaging.require(block, 'truncated archive member')
                target.write(block)
                remaining -= len(block)
            packaging.require(not stream.read(1), 'oversized archive member')
        dest.chmod(mode & 0o777)
    if kind == 'zip':
        with zipfile.ZipFile(archive) as source:
            for member in source.infolist():
                packaging.require(member.filename not in seen, 'duplicate archive member')
                mode = member.external_attr >> 16
                packaging.require(stat.S_ISREG(mode), 'zip member must be a regular file')
                with source.open(member) as stream:
                    copy(member.filename, member.file_size, mode, stream)
    else:
        with tarfile.open(archive, 'r:gz') as source:
            for member in source:
                packaging.require(member.isfile(), 'tar member must be a regular file')
                with source.extractfile(member) as stream:
                    copy(member.name, member.size, member.mode, stream)
    packaging.require(seen == set(files), 'missing archive member')


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def create(artifact, manifest_path, scratch_root, kinds):
    artifact = Path(artifact).absolute()
    manifest = json.loads(Path(manifest_path).read_text())
    packaging.validate(artifact, manifest)
    packaging.require(manifest['kind'] == 'desktop-preview', 'desktop manifest required')
    packaging.require(kinds and len(set(kinds)) == len(kinds) and set(kinds) <= {'zip', 'tar.gz', 'dmg'}, 'invalid archive formats')
    if 'dmg' in kinds:
        packaging.require(sys.platform == 'darwin' and manifest['platform'] == 'macos', 'DMG requires a Mac and macOS artifact')
    parent = staging.scratch_parent(scratch_root)
    packaging.require(parent != artifact.resolve() and artifact.resolve() not in parent.parents,
                      'scratch output cannot be inside artifact input')
    for name in manifest['files']:
        safe_name(name)
    result = Path(tempfile.mkdtemp(prefix='coincide-desktop-archives-', dir=parent)).resolve()
    # A private snapshot decouples archive production from caller files.
    payload = result / 'payload'
    shutil.copytree(artifact, payload)
    packaging.validate(payload, manifest)
    modes = {name: (payload / name).stat().st_mode & 0o777 for name in manifest['files']}
    report = {'platform': manifest['platform'], 'source_manifest': manifest,
              'signing_status': {'container': 'unsigned', 'signing_performed': False,
                                 'payload_signatures': 'unverified; input bytes preserved',
                                 'notarization': 'not performed'},
              'release_ready': False, 'archives': []}
    for kind in kinds:
        archive = result / ('Coincide-Rust-preview.' + kind)
        output = result / ('extracted-' + kind.replace('.', '-'))
        if kind == 'zip':
            with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as target:
                for name in sorted(manifest['files']):
                    target.write(payload / name, arcname=name)
            extract_portable(archive, output, manifest['files'], kind)
        elif kind == 'tar.gz':
            with tarfile.open(archive, 'w:gz') as target:
                for name in sorted(manifest['files']):
                    info = target.gettarinfo(str(payload / name), arcname=name)
                    info.uid = info.gid = 0
                    info.uname = info.gname = ''
                    with (payload / name).open('rb') as stream:
                        target.addfile(info, stream)
            extract_portable(archive, output, manifest['files'], kind)
        else:
            def run(*args):
                subprocess.run(args, check=True, capture_output=True, timeout=300)
            hybrid, raw = result / 'hybrid.iso', result / 'readback.cdr'
            run('/usr/bin/hdiutil', 'makehybrid', '-hfs', '-iso', '-joliet',
                '-hfs-volume-name', 'Coincide Rust Preview', '-o', str(hybrid), str(payload))
            run('/usr/bin/hdiutil', 'convert', str(hybrid), '-format', 'UDZO', '-o', str(archive))
            run('/usr/bin/hdiutil', 'verify', str(archive))
            run('/usr/bin/hdiutil', 'convert', str(archive), '-format', 'UDTO', '-o', str(raw))
            # bsdtar reads ISO/Joliet directly. No disk device or mount is created.
            listing = subprocess.check_output(['/usr/bin/bsdtar', '-tf', str(raw)], text=True).splitlines()
            allowed_dirs = {str(p) for name in manifest['files']
                            for p in PurePosixPath(name).parents}
            for name in listing:
                if name != '.':
                    normalized = name.rstrip('/')
                    safe_name(normalized)
                    packaging.require(normalized in manifest['files'] or normalized in allowed_dirs,
                                      'unexpected DMG readback member')
            output.mkdir()
            run('/usr/bin/bsdtar', '-xf', str(raw), '-C', str(output), '--no-same-owner', '--no-same-permissions')
            packaging.require(packaging.inventory(output) == manifest['files'], 'DMG readback contents differ')
            # ISO does not preserve Unix executable modes; restore only known payload modes
            # for the extracted validator. This does NOT validate HFS mode metadata.
            for name, mode in modes.items():
                (output / name).chmod(mode)
            hybrid.unlink()
            raw.unlink()
        validation = packaging.validate(output, manifest)
        report['archives'].append({'path': str(archive), 'bytes': archive.stat().st_size,
                                   'sha256': digest(archive), 'extracted_validation': validation,
                                   'content_view': 'ISO/Joliet; HFS metadata unverified' if kind == 'dmg' else kind})
    packaging.validate(artifact, manifest)
    if 'dmg' in kinds:
        images = plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist']))
        packaging.require(not any(str(image.get('image-path', '')).startswith(str(result) + '/')
                                  for image in images.get('images', [])), 'unexpected task image attachment')
        report['task_images_attached'] = False
    (result / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (result / 'archive-report.json').write_text(json.dumps(report, indent=2) + '\n')
    # Delete only private disposable copies made here, retaining final evidence/artifacts.
    shutil.rmtree(payload)
    for kind in kinds:
        shutil.rmtree(result / ('extracted-' + kind.replace('.', '-')))
    return {'directory': str(result), **report}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact-root', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--scratch-root', type=Path, required=True)
    parser.add_argument('--format', choices=('zip', 'tar.gz', 'dmg'), action='append', required=True)
    args = parser.parse_args()
    print(json.dumps(create(args.artifact_root, args.manifest, args.scratch_root, args.format), indent=2))
