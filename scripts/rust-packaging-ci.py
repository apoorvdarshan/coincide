#!/usr/bin/env python3
"""Validate a built store tool and emit bounded synthetic CI evidence."""
import argparse
import importlib.util
import json
from pathlib import Path
import platform
import shutil
import tempfile


def module(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def check(binary, commit):
    artifact = module('rust-packaging')
    migration = module('rust-migration-rehearsal')
    host = {'Darwin': 'macos', 'Linux': 'linux', 'Windows': 'windows'}[platform.system()]
    binary = binary.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix='coincide-artifact-validation-') as directory:
        root = Path(directory).resolve()
        (root / 'bin').mkdir()
        staged = root / 'bin' / ('coincide-store.exe' if host == 'windows' else 'coincide-store')
        shutil.copy2(binary, staged)
        inventory = artifact.manifest(root, host, 'ci-validation', commit, 'store-tool')
        integrity = artifact.validate(root, inventory)
        rehearsal = migration.rehearse(staged)
        expected = inventory['files'][staged.relative_to(root).as_posix()]['sha256']
        if rehearsal['store_sha256'] != expected:
            raise RuntimeError('rehearsed binary differs from inventoried binary')
        return {'source_commit_label': commit, 'host': host, 'machine': platform.machine(),
                'manifest': inventory, 'validation': integrity, 'rehearsal': rehearsal}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--store-bin', type=Path, required=True)
    parser.add_argument('--commit', required=True)
    args = parser.parse_args()
    print(json.dumps(check(args.store_bin, args.commit), indent=2))
