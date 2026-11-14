#!/usr/bin/env python3
"""Exercise the real SMAppService bridge with an isolated, inert launch agent."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import uuid

if sys.platform != 'darwin':
    raise SystemExit('This fixture requires macOS')

source = Path(__file__).resolve().parent.parent / 'crates/coincide-desktop/src/awake_service_macos.m'
HARNESS = r'''
#include <stdio.h>
#include <string.h>
extern int coincide_awake_service_status(int);
extern int coincide_awake_service_present(int);
extern int coincide_awake_service_register(int, char *, unsigned long);
extern int coincide_awake_service_unregister(int, char *, unsigned long);
int main(int argc, char **argv) {
    char error[1024] = {0};
    if (argc > 1 && strcmp(argv[1], "--cleanup") == 0)
        return coincide_awake_service_unregister(0, error, sizeof(error)) == 0 ? 0 : 1;
    if (argc > 1 && strcmp(argv[1], "--missing") == 0) {
        if (coincide_awake_service_present(0) != 0) return 2;
        if (coincide_awake_service_register(0, error, sizeof(error)) >= 0) return 3;
        return 0;
    }
    int initial = coincide_awake_service_status(0);
    if (initial != 0 && initial != 3) return 4;
    if (coincide_awake_service_present(0) != 1) return 5;
    int registered = coincide_awake_service_register(0, error, sizeof(error));
    if (registered != 1 && registered != 2) {
        fprintf(stderr, "registration failed: %s (status %d)\n", error, registered);
        return 6;
    }
    if (coincide_awake_service_unregister(0, error, sizeof(error)) != 0) {
        fprintf(stderr, "unregistration failed: %s\n", error);
        return 7;
    }
    printf("initial=%d registered=%d unregistered\n", initial, registered);
    return 0;
}
'''


def run_case(root, missing):
    suffix = uuid.uuid4().hex
    bundle_id = 'com.apoorvdarshan.coincide.awake-fixture-' + suffix
    label = bundle_id + '.agent'
    name = label + '.plist'
    app = root / ('Missing.app' if missing else 'Present.app')
    contents = app / 'Contents'
    binary_dir = contents / 'MacOS'
    agent_dir = contents / 'Library/LaunchAgents'
    binary_dir.mkdir(parents=True)
    agent_dir.mkdir(parents=True)
    info = {'CFBundleIdentifier': bundle_id, 'CFBundleExecutable': 'probe',
            'CFBundleName': 'Coincide Awake Fixture', 'CFBundlePackageType': 'APPL',
            'CFBundleVersion': '1', 'LSUIElement': True}
    agent = {'Label': label, 'BundleProgram': 'Contents/MacOS/coincide-awake-helper',
             'ProgramArguments': ['coincide-awake-helper', '--agent'],
             'AssociatedBundleIdentifiers': [bundle_id], 'RunAtLoad': False}
    with (contents / 'Info.plist').open('wb') as f:
        plistlib.dump(info, f)
    with (agent_dir / name).open('wb') as f:
        plistlib.dump(agent, f)
    harness = root / ('missing.c' if missing else 'present.c')
    harness.write_text(HARNESS)
    if not missing:
        helper_source = root / 'helper.c'
        helper_source.write_text('int main(void) { return 0; }\n')
        subprocess.run(['clang', str(helper_source), '-o', str(binary_dir / 'coincide-awake-helper')], check=True)
    args = ['clang', '-fobjc-arc', '-fblocks', '-framework', 'Foundation', '-framework', 'ServiceManagement',
            '-DCOINCIDE_AWAKE_BUNDLE_ID=@"' + bundle_id + '"',
            '-DCOINCIDE_AWAKE_AGENT_PLIST=@"' + name + '"',
            str(source), str(harness), '-o', str(binary_dir / 'probe')]
    subprocess.run(args, check=True)
    if not missing:
        subprocess.run(['codesign', '--force', '--sign', '-', str(binary_dir / 'coincide-awake-helper')], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    try:
        result = subprocess.run([str(binary_dir / 'probe')] + (['--missing'] if missing else []),
                                check=True, capture_output=True, text=True, timeout=40)
        print(('missing assets: ' if missing else 'first registration: ') + (result.stdout.strip() or 'refused safely'))
    finally:
        # A test assertion or timeout must not leave its unique background item registered.
        subprocess.run([str(binary_dir / 'probe'), '--cleanup'], check=True, capture_output=True, timeout=20)


with tempfile.TemporaryDirectory(prefix='coincide-awake-service-') as tmp:
    os.chmod(tmp, 0o700)
    run_case(Path(tmp), False)
    run_case(Path(tmp), True)
