# Native app updates

Coincide → Check for Updates and Settings → About use the public GitHub Releases API. Daily checks are opt-in and persisted; checking does not download, stop agents, or quit the app. Download Update stages a verified release. Install on Quit starts a separate signed Swift helper and can be cancelled until the user quits.

The helper waits for a normal exit of the exact parent process and a one-use consent marker written after provider shutdown and store/UI flushing. It does not terminate or relaunch Coincide. After installation it shows a native confirmation; the user reopens the app manually. A crash, forced termination, missing consent, another running Coincide, failed verification, or unwritable destination leaves installation unperformed. Closing a window alone does not install anything.

## Required release artifact

The feed is `https://api.github.com/repos/apoorvdarshan/coincide/releases/latest`. It must be a published, non-prerelease version with a three-component numeric tag, such as `v0.2.0`. The version must be strictly newer than the running app's `CFBundleShortVersionString`; same-version build-number updates and downgrades are not supported.

Provide one of these assets:

- `Coincide-macos-arm64.zip`
- `Coincide-macos-x86_64.zip`
- `Coincide-macos-universal.zip`

The architecture-specific asset is preferred over universal. GitHub must return the asset size and its `sha256:` digest. The initial HTTPS asset URL must belong to this repository's release/tag. Redirects are restricted to GitHub's HTTPS API/download hosts.

The ZIP must contain a top-level `Coincide.app`. Stored and Deflate entries and safe relative framework symlinks are supported. ZIP64, encrypted entries, unsupported file types, duplicate or Unicode-fold-equivalent paths, path traversal, external/cyclic symlinks, and children nested under a symlink are rejected. Finder's `__MACOSX` metadata is ignored. Limits are 512 MiB compressed, 1 GiB expanded, 256 MiB per entry, and fewer than 50,000 entries.

The app must:

- Have bundle ID `com.apoorvdarshan.coincide` and a version exactly matching the release tag.
- Be Developer ID signed by the same team as the installed build, with valid nested code and all architecture signatures.
- Include a compatible main executable and a supported `LSMinimumSystemVersion`.
- Pass Gatekeeper assessment. Official distribution should use a hardened-runtime, notarized and stapled app.
- Include the signed `CoincideUpdater` tool in `Contents/MacOS`; it is built and embedded by the XcodeGen project. Its signing identifier is `CoincideUpdater`.

Ad-hoc and unsigned builds cannot stage or arm installation. The team is derived from the installed code signature, never from GitHub metadata or a mutable job file. The repository defaults to ad-hoc signing; a local `Local.xcconfig` may already configure the maintainer's Developer ID. No signing identities or release credentials are changed by this feature.

## Staging and installation

Each download uses its own private directory under `~/Library/Caches/com.apoorvdarshan.coincide/Updates`. The archive's byte count and SHA-256 digest are verified before extraction. Regular files are extracted before validated relative symlinks, so extraction never traverses an archive-created symlink. The bundle is verified before showing Ready.

Install on Quit copies the signed helper into the job directory and waits for it to register its process-exit observer. Normal application termination writes consent only after the existing shutdown/flush sequence. The helper derives the trusted signing team from its own signature, rechecks the installed app, rehashes and re-extracts the archive, and verifies the candidate again. Mutable previously extracted content is never trusted for installation.

The verified candidate is copied beside the destination app and verified again. A same-filesystem atomic exchange replaces the app; failed final verification exchanges it back. The old app remains at `.Coincide-backup-<UUID>.app` beside the installed app. The job's `result.json` records that backup path when writable; failure to write this diagnostic receipt does not change a successful installation into a failure. Backups are retained for manual recovery, not silently deleted. The installer never reads or changes chat data, projects, provider credentials, or preferences, and never requests elevated permissions.

If a filesystem error also prevents rollback, both bundles are retained for recovery. The previous app's backup is not removed. A user who manually relaunches before the installation completes can cause the helper to refuse installation; wait for its confirmation first.

## Current availability and validation

Releases are built and published by `.github/workflows/release.yml` ([releasing.md](releasing.md)), which attaches `Coincide-macos-universal.zip` to every release and, before publishing, runs this updater's own archive and bundle checks on it (`scripts/release/check-update-archive.swift`). At implementation time (28 October 2026) no release had been published, and none was created for testing. Release checks, invalid metadata, archive attacks, digest validation, ad-hoc rejection, clean/nonzero/signalled process exits, and atomic exchange/rollback are tested using isolated fixtures. A native signed/notarized public release update has **not** been tested end to end. The active Coincide bundle and user chat data were not replaced or restarted during development.
