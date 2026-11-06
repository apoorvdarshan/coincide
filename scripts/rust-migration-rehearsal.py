#!/usr/bin/env python3
"""Run an explicitly supplied trusted coincide-store on disposable synthetic data."""
import argparse
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile

ID = '12345678-1234-4234-8234-123456789abc'


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def files(root):
    return {p.relative_to(root).as_posix(): p.read_bytes()
            for p in root.rglob('*') if p.is_file()}


def inspect(db):
    # The subprocess has exited; immutable avoids creating SQLite sidecar files.
    require(not Path(str(db) + '-wal').exists(), 'unexpected WAL after process exit')
    with closing(sqlite3.connect(db.as_uri() + '?mode=ro&immutable=1', uri=True)) as conn:
        require(conn.execute('PRAGMA integrity_check').fetchall() == [('ok',)], 'SQLite integrity failure')
        return {table: conn.execute('SELECT * FROM ' + table + ' ORDER BY 1').fetchall()
                for table in ('original_files', 'threads', 'imported_threads', 'metadata')}


def rehearse(binary):
    binary = binary.resolve(strict=True)
    require(binary.is_file(), 'store binary required')
    initial_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
    checks = []
    skipped = []
    with tempfile.TemporaryDirectory(prefix='coincide-synthetic-rehearsal-') as temporary:
        root = Path(temporary).resolve()
        source = root / 'synthetic-swift'
        (source / 'threads').mkdir(parents=True)
        (source / 'attachments').mkdir()
        document = {'id': ID, 'title': 'Synthetic 日本語', 'items': [], 'draft': 'unsent',
                    'unknown': {'future': [1, True]}, 'sessions': [{'sessionID': 'fake-only'}]}
        (source / 'threads/one.json').write_text(json.dumps(document), encoding='utf-8')
        (source / 'attachments/sample.bin').write_bytes(bytes(range(256)))
        (source / 'projects.json').write_text('[]')
        before = files(source)
        # Deliberately do not inherit provider secrets or Coincide control bindings.
        env = {k: v for k, v in os.environ.items() if k in ('PATH', 'SystemRoot', 'WINDIR')}
        for key in ('HOME', 'USERPROFILE', 'TMPDIR', 'TMP', 'TEMP', 'COINCIDE_RUST_DATA_DIR'):
            env[key] = str(root)
        def run(db, success):
            result = subprocess.run([str(binary), 'import', str(source), str(db)],
                                    cwd=root, env=env, capture_output=True, timeout=60)
            require((result.returncode == 0) == success,
                    'unexpected import exit status: ' + result.stderr.decode('utf-8', errors='replace')[:2000])
            require(files(source) == before, 'synthetic source changed')
        db = root / 'candidate/store.sqlite'
        run(db, True)
        state = inspect(db)
        require(dict(state['original_files']) == before, 'original bytes not preserved')
        require(json.loads(state['threads'][0][1]) == document, 'thread fields changed')
        require(state['imported_threads'] == [(ID,)], 'import execution boundary missing')
        checks.append('lossless synthetic import and source preservation')
        run(db, False)
        require(inspect(db) == state, 'repeat import changed data')
        checks.append('repeat import refused without logical mutation')
        # Restore only a closed, synthetic database, never a live WAL database.
        backup = root / 'rollback.sqlite'
        shutil.copyfile(db, backup)
        with closing(sqlite3.connect(db)) as conn:
            with conn:
                conn.execute('DELETE FROM threads')
        shutil.copyfile(backup, db)
        require(inspect(db) == state, 'synthetic restore differs')
        checks.append('closed synthetic database backup/restore equivalence')
        (source / 'threads/broken.json').write_text('{broken')
        before = files(source)
        bad = root / 'invalid/store.sqlite'
        run(bad, False)
        def require_empty(db):
            rejected = inspect(db)
            require(not rejected['threads'] and not rejected['original_files'] and
                    not rejected['imported_threads'] and
                    'legacy_source' not in dict(rejected['metadata']), 'failed import committed data')
        require_empty(bad)
        checks.append('invalid input transaction rollback')
        (source / 'threads/broken.json').unlink()
        (source / 'threads/duplicate.json').write_text(json.dumps(document), encoding='utf-8')
        before = files(source)
        duplicate_db = root / 'duplicate/store.sqlite'
        run(duplicate_db, False)
        require_empty(duplicate_db)
        checks.append('duplicate thread identity transaction rollback')
        (source / 'threads/duplicate.json').unlink()
        target = root / 'synthetic-outside-source.bin'
        target.write_bytes(b'synthetic outside capture')
        link = source / 'attachments/link.bin'
        try:
            link.symlink_to(target)
        except OSError as error:
            if os.name != 'nt' or error.winerror != 1314:
                raise
            skipped.append('symlink rejection: Windows lacks symlink privilege')
        else:
            before = files(source)
            linked_db = root / 'symlink/store.sqlite'
            run(linked_db, False)
            require_empty(linked_db)
            require(target.read_bytes() == b'synthetic outside capture', 'symlink target changed')
            checks.append('symlink import refused without source or target mutation')
    require(hashlib.sha256(binary.read_bytes()).hexdigest() == initial_hash, 'store binary changed during rehearsal')
    return {'checks': checks, 'store_sha256': initial_hash,
            'skipped': skipped, 'scope': 'synthetic only', 'cutover_ready': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--store-bin', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(rehearse(args.store_bin), indent=2))
