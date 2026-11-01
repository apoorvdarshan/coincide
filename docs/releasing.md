# Releasing Coincide for Mac

`.github/workflows/release.yml` builds and publishes Coincide when a version tag is pushed. Everything it runs lives in `scripts/release/`, so a release can also be built and checked on a Mac.

## What a release contains

| Asset | Used by |
|---|---|
| `Coincide-<version>.dmg` | Homebrew (`brew install --cask apoorvdarshan/tap/coincide`) |
| `Coincide.dmg` | coincide.dev's Download button, through `releases/latest/download/Coincide.dmg` (a copy of the versioned DMG) |
| `Coincide-macos-universal.zip` | The in-app updater ([app-updates.md](app-updates.md)) and `npx coincide-dev` |
| `SHA256SUMS.txt` | SHA-256 of the three files above; `npx coincide-dev` checks the ZIP against it |

The app is universal (Apple silicon and Intel), signed with the Developer ID Application certificate of team 23RV7FYH36, with the hardened runtime and secure timestamps, notarized and stapled. The DMG holds the app and an Applications link and is itself signed, notarized and stapled. `scripts/release/verify.sh` checks all of this before anything is published, and also runs the in-app updater's own checks (`scripts/release/check-update-archive.swift`) on the ZIP.

The hardened runtime needs the app to claim the microphone (dictation) and Apple Events (Computer Use's helper): `Coincide/Coincide.entitlements`. Release builds have no provisioning profile, so they leave out the iCloud (lock-screen alerts for Coincide Remote) and passkey entitlements, as default builds do (see `Signing.xcconfig`).

Releases are published as regular releases, not pre-releases, even at 0.x: GitHub's `releases/latest`, which the in-app updater, coincide.dev's download link and Homebrew's livecheck all read, skips pre-releases.

## Cutting a release

1. In a pull request, set the new version in `project.yml` (`MARKETING_VERSION`) and `npm/package.json` (`version`), and add its `## <version>` section to `CHANGELOG.md`. `scripts/release/test.sh` fails if the two versions differ.
2. After it merges, tag main and push the tag:

   ```sh
   git switch main && git pull
   git tag v0.2.0
   git push origin v0.2.0
   ```

3. The workflow then runs:
   - **Preflight**: the tag must be `v` + `MARKETING_VERSION` and on main, CHANGELOG.md must have the version's notes, the secrets below must exist, and the release scripts' tests (`scripts/release/test.sh`) must pass.
   - **Unit tests**: the same build and tests as CI.
   - **Build, sign and notarize**: `scripts/release/build.sh`, in a temporary keychain that is deleted afterwards. The files are kept on the run as the `Coincide-<version>` artifact.
   - **Publish the GitHub Release** with the four files and the CHANGELOG section as notes. The Discord bot announces it in #announcements within the hour.
   - **Update the Homebrew cask**: sets `version` and `sha256` in `Casks/coincide.rb` of [apoorvdarshan/homebrew-tap](https://github.com/apoorvdarshan/homebrew-tap) (`scripts/release/update-cask.sh`).
   - **Publish coincide-dev to npm** at the same version, with provenance.

Releases run one at a time; a newer tag waits for the running release. Each publishing job can be re-run on its own: the GitHub Release is updated rather than created twice, the cask commit is skipped when it is already current, and npm publishing is skipped when the version is already there.

**Run workflow** on the Release workflow runs everything up to publishing (tests, build, signing, notarization, stapling and verification) and keeps the files as the run's artifact. It never publishes anything. Use it to check a change to the pipeline or the build.

## Building on a Mac

With the Developer ID identity in the login keychain and an App Store Connect API key:

```sh
NOTARY_KEY_PATH=~/path/AuthKey_XXXXXXXXXX.p8 NOTARY_KEY_ID=XXXXXXXXXX NOTARY_ISSUER_ID=<issuer> \
  scripts/release/build.sh            # files in build/release
NOTARIZE=0 scripts/release/build.sh   # build and signing checks only; never publish these
```

## Secrets

| Secret | What it is |
|---|---|
| `MACOS_CERTIFICATE_P12` | Base64 of a password-protected `.p12` with only the "Developer ID Application: Apoorv Darshan (23RV7FYH36)" certificate and its private key. **The certificate expires on 1 February 2027**; replace both certificate secrets with a new Developer ID Application identity before then. |
| `MACOS_CERTIFICATE_PASSWORD` | The `.p12`'s password |
| `APP_STORE_CONNECT_API_KEY_ID` | ID of the App Store Connect API key notarytool signs in with (team key `5ZAR575U5J`, which can't manage certificates) |
| `APP_STORE_CONNECT_ISSUER_ID` | Its issuer ID |
| `APP_STORE_CONNECT_API_KEY_P8` | Its private key (the `.p8` file's contents) |
| `TAP_GITHUB_TOKEN` | Fine-grained personal access token "coincide release: homebrew-tap": Contents read and write on apoorvdarshan/homebrew-tap only, no expiration. It can't push workflow files or touch any other repository. |
| `NPM_TOKEN` | npm token of the `apoorvdarshan` account, for `npm publish` |

The tap and npm secrets are needed only by tag runs; Run workflow checks the signing and notarization ones.
