import { code, table } from "../../layout.mjs";

export default {
  path: "/docs/build-from-source",
  title: "Build Coincide from source · Coincide",
  description: "Build the Coincide Mac app with Xcode and XcodeGen: requirements, the SwiftTerm plug-in, Cua Driver, the separate Debug app and signing your builds.",
  name: "Build from source",
  summary: "Build Coincide with Xcode and XcodeGen, and keep Debug builds apart from your installed app.",
  type: "TechArticle",
  eyebrow: "Guide",
  h1: "Build Coincide from source",
  lede: "Coincide is open source under the MIT license. You can build it yourself with Xcode, to try a change or to contribute. The release on the download page is the same code, signed and notarized.",
  related: ["/docs/translations", "/docs/macos-permissions", "/docs/data-storage", "/download"],
  body: (s) => `
<h2 id="requirements">Requirements</h2>
<ul>
  <li>macOS 26 or later</li>
  <li>Xcode 27 or later</li>
  <li><a href="https://github.com/yonaskolb/XcodeGen">XcodeGen</a>, which generates the Xcode project from <code>project.yml</code></li>
  <li>At least one agent CLI, installed and signed in, to try your build (see ${s.link("/agents", "the agents")})</li>
</ul>

<h2 id="build">Building</h2>
${code(`brew install xcodegen
git clone https://github.com/apoorvdarshan/coincide.git
cd coincide
xcodegen generate
open Coincide.xcodeproj`)}
<p>Then build and run the Coincide scheme in Xcode. A few things happen along the way:</p>
<ul>
  <li><strong>The project file isn’t checked in.</strong> <code>Coincide.xcodeproj</code> is generated, so change targets, settings and packages in <code>project.yml</code>, not in Xcode’s project settings. Run <code>xcodegen generate</code> again after editing it, after adding or removing source files, and before building a Release you’ll install: it also sets the build number to the number of commits in your history, so macOS sees each installed build as new.</li>
  <li><strong>Cua Driver is downloaded once.</strong> <code>xcodegen generate</code> first runs <code>scripts/fetch-cua-driver.sh</code>, which downloads the pinned release of Cua Driver that Computer Use bundles, checks its checksum and Cua AI’s Developer ID signature, and puts it in the gitignored <code>Vendor/</code> folder. The download is cached in <code>~/Library/Caches/Coincide</code>, so later runs work offline.</li>
  <li><strong>SwiftTerm runs a build plug-in.</strong> It generates Swift from its own terminfo source. Xcode asks once to trust it; choose Trust &amp; Enable. On the command line, pass <code>-skipPackagePluginValidation</code> to <code>xcodebuild</code>.</li>
</ul>
<p>Coincide has two package dependencies, SwiftTerm (the terminal) and WhisperKit (Whisper dictation, with no bundled models).</p>

<h2 id="debug">The Debug app</h2>
<p>Debug builds, whether from Xcode, the tests or an agent, are a separate app called <strong>Coincide Debug</strong>, so they never touch your installed Coincide:</p>
${table(["", "Installed Coincide", "Coincide Debug"], [
  ["Bundle ID", "<code>com.apoorvdarshan.coincide</code>", "<code>com.apoorvdarshan.coincide.debug</code>"],
  ["Data folder", "<code>~/Library/Application Support/Coincide</code>", "<code>~/Library/Application Support/Coincide Debug</code>"],
  ["Keychain items, background jobs, macOS permissions", "Its own", "Its own"],
  ["Agents", "In the background agent host", "In the app, unless you launch it with <code>COINCIDE_AGENT_HOST=1</code>"],
  ["Terminal’s <code>coincide</code>", "Installed by this app", "Left to the installed app; agents the Debug app starts still get its own tool"],
])}
<p>Set <code>COINCIDE_DATA_DIR</code> to run a build against a scratch folder instead. Xcode registers every app it builds with Launch Services, and macOS can pick any registered copy for a notification’s icon or click. When you’re done with a build you won’t install, unregister it:</p>
${code(`scripts/unregister-builds.sh ~/Library/Developer/Xcode/DerivedData/<folder>`)}

<h2 id="signing">Signing your builds</h2>
<p>Builds are signed ad hoc by default, as in CI. That works, but every build gets a new identity, so macOS asks again for permissions such as access to a protected folder your agent configuration lives in. To keep your answers, sign with your own identity: create a gitignored <code>Local.xcconfig</code> in the repository root, as <code>Signing.xcconfig</code> describes, and run <code>xcodegen generate</code>.</p>
${code(`// Local.xcconfig
CODE_SIGN_IDENTITY = Developer ID Application
DEVELOPMENT_TEAM = ABCDE12345`)}
<p>Some features need more than a signature:</p>
<ul>
  <li><strong>The background agent host</strong> needs a Developer ID signature; ad-hoc builds run agents in the app.</li>
  <li><strong>The in-app updater</strong> installs updates only into a verified Developer ID build.</li>
  <li><strong>Lock-screen alerts</strong> for Coincide Remote and <strong>passkeys</strong> in the browser need entitlements with a matching provisioning profile; <code>Signing.xcconfig</code> explains the steps. Without them the app simply leaves those features out.</li>
</ul>

<h2 id="tests">Tests</h2>
<p>The unit tests use Swift Testing and run in CI on every pull request. To run them yourself, as CI does:</p>
${code(`xcodebuild -project Coincide.xcodeproj -scheme Coincide -skipPackagePluginValidation test`)}
<p>Live provider tests drive the real agent CLIs with your own accounts and spend a little of your quota, so they run only when you set <code>TEST_RUNNER_COINCIDE_LIVE_TESTS=1</code>. The fuzzers for Coincide’s parsers live in <code>Fuzz/</code>.</p>

<h2 id="contribute">Contributing</h2>
<p>Read <a href="https://github.com/apoorvdarshan/coincide/blob/main/CONTRIBUTING.md">CONTRIBUTING.md</a> before opening a pull request: it covers the project layout, code style, tests, user-facing text and the pull request checklist. Changed text needs translating too; see ${s.link("/docs/translations")}. Releases are built, signed and notarized by GitHub Actions from a version tag, as <a href="https://github.com/apoorvdarshan/coincide/blob/main/docs/releasing.md">docs/releasing.md</a> describes.</p>
`,
};
