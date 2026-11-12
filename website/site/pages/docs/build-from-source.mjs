import { code } from "../../layout.mjs";

export default {
  path: "/docs/build-from-source",
  title: "Build Coincide from source · Coincide",
  description: "Build the Coincide Rust desktop from source, run its core tests, and find the iPhone and iPad companion project.",
  name: "Build from source",
  summary: "Build the Rust desktop, run its core tests and find the iOS companion project.",
  type: "TechArticle",
  eyebrow: "Guide",
  h1: "Build Coincide from source",
  lede: "Coincide's desktop application is being developed in Rust. The iPhone and iPad companion remains a separate iOS project.",
  related: ["/docs/translations", "/docs/macos-permissions", "/docs/data-storage", "/download"],
  body: () => `
<h2 id="desktop">Rust desktop</h2>
<p>Install a Rust toolchain and the native dependencies for your platform. On macOS, install the Xcode command-line tools. The repository's Rust CI workflow lists Linux and Windows dependencies.</p>
${code(`git clone https://github.com/apoorvdarshan/coincide.git
cd coincide
cargo build -p coincide-desktop --bin coincide-rust --locked
cargo test -p coincide-core --locked`)}
<p>The Rust desktop is in development; platform acceptance and feature parity are still being verified. The repository's <a href="https://github.com/apoorvdarshan/coincide/blob/main/docs/rust/STATUS.md">Rust status</a> and <a href="https://github.com/apoorvdarshan/coincide/blob/main/docs/rust/packaging.md">packaging notes</a> describe the current checks and limits.</p>
<p>The existing public download, Homebrew cask and npm installer contain the retired Swift Mac app. They do not install the Rust desktop. A Rust release pipeline is not configured yet.</p>
<h2 id="ios">Coincide Remote for iPhone and iPad</h2>
<p>The iOS companion remains in the repository. With Xcode and XcodeGen installed, generate its project using <code>xcodegen generate --spec project-remote.yml</code>. See <a href="https://github.com/apoorvdarshan/coincide/blob/main/store/README.md">the companion's setup</a>. Compatibility with the Rust desktop is still being mapped and verified.</p>
<h2 id="contribute">Contributing</h2>
<p>See <a href="https://github.com/apoorvdarshan/coincide/blob/main/CONTRIBUTING.md">CONTRIBUTING.md</a> for the project layout, test guidance and pull requests.</p>
`,
};
