# Rust preview packaging and migration rehearsal

These tools implement an offline integrity gate and a disposable migration rehearsal.
They do not create an installer, sign, publish, update, launch the desktop, or authorize
cutover. Feature parity remains incomplete; see [STATUS.md](STATUS.md).
Python 3.9+ is required; no third-party Python packages or network calls are used.

## Artifact contract

Prepare an isolated, **quiescent** unpacked artifact using coordinator-built binaries.
Never use the running Swift app or Rust preview as the staging directory. On macOS,
resolve `/tmp` to its physical path first (`/private/tmp`); symlink ancestors are refused.

| Platform | Required relative files |
| --- | --- |
| macOS | `Coincide Rust.app/Contents/MacOS/{coincide-rust,coincide-rs,coincide-store}` and `Contents/Info.plist` within that app |
| Windows | `bin/{coincide-rust,coincide-rs,coincide-store}.exe` |
| Linux | `bin/{coincide-rust,coincide-rs,coincide-store}` |

The macOS plist must use executable `coincide-rust`, name `Coincide Rust`, and
identifier `com.apoorvdarshan.coincide.rust`. This is a new preview identity, not
permission to change an existing installed bundle. Native executables need executable
permission on Unix. Windows validates `MZ`, Linux ELF, and macOS Mach-O/fat magic.
Headers are only a format sanity check, not architecture or executable validation.
Additional regular resources are allowed but included in the exact manifest inventory.
Symlinks (including framework symlinks), special files, case collisions and nonportable
colon/backslash paths are refused. Framework packaging needs a reviewed extension to
this contract; do not flatten frameworks silently.

```sh
python3 scripts/rust-packaging.py manifest /absolute/physical/stage \
  --platform macos --version 0.1.0-preview --commit FULL_40_CHARACTER_COMMIT > /outside/stage-manifest.json
python3 scripts/rust-packaging.py validate /absolute/physical/stage /outside/stage-manifest.json
python3 -B scripts/rust-packaging-tests.py
```

Manifest format 2 requires an explicit artifact kind. `desktop-preview` is the default;
`--kind store-tool` validates only `bin/coincide-store[.exe]` on every OS and needs
no app plist. It does not validate a desktop bundle. Format 1 manifests must be regenerated.

The manifest records version, source commit label, byte counts and SHA-256 for every
file. The commit/version are caller assertions, not build provenance. Keep the manifest
outside the artifact. Validation reads only and executes no artifacts. Manifest creation
is not a secret scanner: inspect staging contents before distributing either inventory
or artifact. Hash equality proves integrity relative to the supplied manifest, not its
authenticity. A modified artifact plus modified manifest can pass. Concurrent mutation
is unsupported. Output always says `release_ready: false`.

## Synthetic migration rehearsal

Coordinator allocates builds; do not start competing Cargo builds. Once a trusted
`coincide-store` has been built from the intended commit:

```sh
python3 -B scripts/rust-migration-rehearsal.py --store-bin /absolute/path/coincide-store
```

The only input is an executable path, never a user source/database path. The program
runs that executable (it must be trusted), with private generated temporary fixtures,
isolated home/data/temp directories, and no inherited provider credentials or Coincide
control variables. It imports Unicode text, unknown fields, a draft, fake session
references and binary attachment bytes. It checks exact captured bytes, thread JSON,
imported identity, source immutability, repeat-import refusal, failed-import atomicity,
closed synthetic database backup/restore equivalence, duplicate-ID rollback, and
symlink refusal with source/target preservation. Windows without symlink privilege
reports that case as skipped in evidence; it never counts a skipped case as passed. Child commands have a
60-second timeout. SQLite inspection is read-only and refuses leftover WAL files.
Temporary fixtures are removed on normal completion or error; only JSON evidence is
printed. The store executable hash ties evidence to an artifact; record source SHA too.

This does not execute providers, test account access, migrate browser/keychain data,
verify old-binary/new-schema compatibility, or prove rollback of a running application.
The current store `check` command opens/migrates a database and is **not** a read-only
inspection tool. Never run it on live data as a validation shortcut.

## Updater and rollback gates still required

No updater is implemented by these scripts. Before a replacement release, independently
verify each of the following and record host, architecture, artifact hash and commit:

- macOS signing identity/entitlements, nested signatures, hardened runtime, notarization,
  Gatekeeper assessment and resource loading; Windows Authenticode, installer identity,
  locked-file handling and WebView runtime; Linux target ABI, GTK/WebKit dependencies,
  desktop integration and the selected package format. Native launch acceptance is separate.
- An authenticated update manifest with pinned trust, target/architecture/version/channel
  binding, downgrade/replay protection, bounded download, verified artifact digest/signature,
  safe archive extraction and atomic same-volume replacement. Never execute a download
  before verification or replace the active bundle during a conversation.
- Durable pending/committed update state and crash/power-loss injection at every transition;
  failed health checks must retain a verified previous executable. App health requires more
  than process start. Updating must not discard the prior install before acceptance.
- Schema compatibility declared per binary. App rollback does not imply database rollback.
  A new schema must never be opened by an incompatible old app. Restore a verified closed
  snapshot into a fresh isolated location, accounting for post-snapshot edits explicitly;
  never overwrite the only current database or copy a live SQLite main file without WAL.

## Final migration rehearsal gate (not authorized here)

After complete feature/account/platform acceptance, obtain explicit cutover authorization.
Quiesce all writers, capture a consistent inventory and backup of legacy data, import
into a fresh isolated destination, compare counts and exact bytes, and verify representative
UI/provider workflows without attaching both apps to shared mutable state. Document the
excluded browser credentials, account state, processes and companion state and their
separate migration paths. Rehearse recovery against copies with the exact previous and
candidate binaries. Record any edits made after cutover and how they are retained if
rolling back. Keep the original application/data intact until acceptance and retention
requirements are met. These synthetic checks alone cannot satisfy this gate.

## Dedicated validation CI

`.github/workflows/rust-packaging.yml` adds Mac/Linux/Windows jobs without changing
existing workflows. It runs Python regressions, builds only `coincide-store --locked`,
and uses `scripts/rust-packaging-ci.py` to copy that executable into disposable staging,
inventory and validate it as `store-tool`, then rehearse against that exact staged file.
The JSON evidence records its SHA-256, byte count, OS, architecture and CI source commit.
Only evidence JSON is retained for seven days; no executable or user data is uploaded.
Caches never replace executing the validations. PR supersession cancels only PR runs.
The temporary worker branch push trigger allows validation before integration; the
coordinator may remove that trigger after integration. macOS jobs are path-filtered.

For a coordinator-provided local binary, the commit argument is a label only and cannot
prove its build origin. The hash identifies the tested bytes. Local equivalent:

```sh
python3 -B scripts/rust-packaging-ci.py --store-bin /absolute/path/coincide-store --commit FULL_40_CHARACTER_COMMIT
```
