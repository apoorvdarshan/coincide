# Coincide Remote on the App Store

Coincide Remote, the iPhone and iPad app (target `CoincideRemote`, bundle ID `com.apoorvdarshan.coincide.remote`,
App Store Connect app 6829516823), is built, signed and released by the shared
[store-release](https://github.com/apoorvdarshan/store-release) pipeline. This repository keeps only its
configuration, [`store-release.toml`](store-release.toml), and two thin callers that store-release renders:

- `.github/workflows/ios-release.yml`: a push of an `ios-v<version>` tag is a release run. **Run workflow** only
  validates: it archives, signs, exports and validates the IPA with App Store Connect and uploads nothing. Its
  `store-plan` job prints, read-only, what a tag run would change.
- `.github/workflows/store-checks.yml`: checks this folder, the callers and the project on pull requests.

The Mac app is separate: it releases from `v<version>` tags through `.github/workflows/release.yml`
([docs/releasing.md](../docs/releasing.md)), and an `ios-v` tag never starts that workflow.

## The project

store-release archives `CoincideRemote.xcodeproj`, which holds Coincide Remote alone. `project-remote.yml` generates
it from the same target template and scheme that `project.yml` uses for `Coincide.xcodeproj`
(`project-shared.yml`), so both projects build the same app. Unlike `Coincide.xcodeproj` it is committed, because
store-release reads `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` from its `project.pbxproj`.

- `xcodegen generate` writes it again after `Coincide.xcodeproj` (`postGenCommand` in `project.yml`). Commit the
  result whenever it changes, for instance after adding a file to `CoincideRemote/`. CI's **Build and test** fails
  when the committed project differs from what XcodeGen (the version `ci.yml` pins) writes.
- The App Store build resolves Swift packages only from the committed
  `CoincideRemote.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. After changing a package pin
  in `project-shared.yml`, run
  `xcodebuild -resolvePackageDependencies -project CoincideRemote.xcodeproj -scheme CoincideRemote` and commit the
  file; CI fails until it matches.
- `MARKETING_VERSION` in `project-remote.yml` is Coincide Remote's version, `0.1.0` for now. The tag must match it:
  `ios-v0.1.0`. The Mac app's version is `MARKETING_VERSION` in `project.yml`.
- The build number is the larger of `CURRENT_PROJECT_VERSION` (1) and App Store Connect's highest build plus one.
- Builds from this project sign with team `23RV7FYH36`; they don't read `Signing.xcconfig`.

## Switches

Switches are repository variables (Settings › Secrets and variables › Actions › Variables). store-release's
[switches.md](https://github.com/apoorvdarshan/store-release/blob/v0.5.0/docs/switches.md) describes each one.

| Variable | Set to | What it controls |
|---|---|---|
| `IOS_RELEASE_AUTOMATION` | `false` | Master switch. While it is off, a tag run builds nothing and touches nothing in App Store Connect; it only creates the tag's GitHub Release (never marked Latest) |
| `IOS_CREATE_VERSION` | `true` | Create the tag's App Store version when App Store Connect doesn't have it yet |
| `IOS_UPLOAD_BUILD` | `false` | Build, sign and upload the binary, then wait until App Store Connect has processed it |
| `IOS_UPLOAD_LISTING` | `false` | Description, keywords, promotional text and URLs; needs an `[ios.listing]` table and `APPSTORE.md`, which don't exist yet |
| `IOS_UPLOAD_WHATS_NEW` | `false` | What's New text; needs an `[ios.whats_new]` table |
| `IOS_UPLOAD_SCREENSHOTS` | `false` | Screenshots; needs `[[ios.screenshots.sets]]` |
| `IOS_UPLOAD_CREATIVE_ASSETS` | `false` | Product page header and search results images; needs `[ios.creative]` |
| `IOS_SUBMIT_REVIEW` | `false` | Select this run's build and submit the version for review |
| `IOS_PUBLIC_RELEASE` | `true` | Release automatically once Apple approves the version |

`IOS_CREATE_VERSION` and `IOS_PUBLIC_RELEASE` are on, but nothing reads them while the master switch is off.

**Turning the master switch on.** `IOS_PUBLIC_RELEASE` only applies with `IOS_SUBMIT_REVIEW`, which only submits the
build its own run uploaded, so set `IOS_UPLOAD_BUILD` and `IOS_SUBMIT_REVIEW` to `true` together with
`IOS_RELEASE_AUTOMATION`. Otherwise the tag run fails before it builds anything. With `IOS_UPLOAD_BUILD` alone the
build reaches TestFlight and App Store Connect, and nothing is submitted.

**What's New stays off for 0.1.0.** App Store Connect shows What's New only from an app's second version on, so the
first version has none to upload. Add `[ios.whats_new]` and its text before turning the switch on for a later version.

## Secrets

The repository's `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID` and `APP_STORE_CONNECT_API_KEY_P8`
belong to the Mac app (its notarization key). Coincide Remote has its own, which `[ios.secrets]` maps to the names
store-release's workflows expect:

| Secret | What it is |
|---|---|
| `IOS_ASC_API_KEY_ID` | Coincide Remote's App Store Connect API key (Admin role): build numbers, cloud-managed distribution signing, upload, listing, review |
| `IOS_ASC_ISSUER_ID` | Its issuer ID |
| `IOS_ASC_API_KEY_P8` | Its private key (the `.p8` file's contents) |
| `IOS_DEV_SIGNING_P12_BASE64` | The shared CI Apple Development identity (base64 `.p12`) that signs the archive |
| `IOS_DEV_SIGNING_P12_PASSWORD` | Its password |

The development identity is the one Fud AI and the owner's other apps share (see Fud AI's `store/README.md`). The App
Store signature comes from Apple's cloud-managed distribution certificate at export, so no distribution certificate
or profile is stored.

## iCloud and push

`CoincideRemote/CoincideRemote.entitlements` doesn't set `com.apple.developer.icloud-container-environment`.
Development-signed builds (Xcode, device installs) then use CloudKit's Development environment, and the App Store
export sets Production, the only value App Store Connect accepts. The export also switches `aps-environment` to
`production`.

The App Store build reads lock-screen alerts from the Production environment, so deploy the schema there before
a build goes public: in the [CloudKit Console](https://icloud.developer.apple.com/), open the container
`iCloud.com.apoorvdarshan.coincide`, check the Development schema, then **Deploy Schema Changes…** to Production. The
record type is `CoincideAlert`, with the String fields `eventID`, `threadID`, `title`, `subtitle`, `body` and
`collapseID` and the Date/Time field `createdAt`. A Mac writes alerts to the environment its own signature names.

## Release notes

`## ios-v<version>` sections of [`RELEASE_NOTES.md`](RELEASE_NOTES.md) become the GitHub Release notes. A tag
without one gets GitHub's generated notes; an empty or duplicated section fails the run.

## Releasing a version

1. Set `MARKETING_VERSION` in `project-remote.yml`, run `xcodegen generate` and commit `CoincideRemote.xcodeproj`
   with it.
2. After that is on `main`, run **iOS Release › Run workflow**. Read the `store-plan` summary: it lists every write a
   tag run would make with the current switches, and anything that would stop it.
3. Push `ios-v<version>` on that commit. The run first needs CI's build and unit tests to pass on it.
