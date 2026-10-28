import CryptoKit
import Foundation
import Testing

@testable import CoincideKit

/// The ACP Registry index: T3 Code's schema checks, its platform filtering and search ranking
/// (`AcpRegistrySupport.test.ts`), with entries from the real index.
struct ACPRegistryIndexTests {
    private func index() throws -> ACPRegistryIndex { try ACPRegistryIndex.parse(ACPRegistryFixtures.registry) }

    @Test func realEntriesParseAndBrokenOnesAreLeftOut() throws {
        let index = try index()
        #expect(index.version == "1.0.0")
        #expect(index.agents.map(\.id).sorted() == ["claude-acp", "cursor", "devin", "fast-agent", "gemini", "goose", "kilo", "kimi"])
        #expect(index.discarded == 7)

        let goose = try #require(index.agent("goose"))
        #expect(goose.name == "goose")
        #expect(goose.authors == ["Block"])
        #expect(goose.license == "Apache-2.0")
        #expect(goose.website?.absoluteString == "https://block.github.io/goose/")
        let target = try #require(goose.binaries["darwin-aarch64"])
        #expect(target.command == "./goose")
        #expect(target.arguments == ["acp"])
        #expect(target.sha256 == "62d806417b19be167474297eaaec7783ff9917f4fa772e781e977f2bdc155163")
        #expect(target.archive.path.hasSuffix(".tar.bz2"))

        // Devin publishes no SHA-256; only HTTPS vouches for its download.
        #expect(index.agent("devin")?.binaries["darwin-x86_64"]?.sha256 == nil)
        let gemini = try #require(index.agent("gemini")?.npx)
        #expect(gemini.package == "@google/gemini-cli@0.66.0")
        #expect(gemini.nameAndVersion.name == "@google/gemini-cli")
        #expect(gemini.nameAndVersion.version == "0.66.0")
        #expect(gemini.arguments == ["--acp"])
        let fast = try #require(index.agent("fast-agent")?.uvx)
        #expect(fast.nameAndVersion.name == "fast-agent-acp")
        #expect(fast.nameAndVersion.version == "0.10.1")
        #expect(fast.environment.keys.contains("FAST_AGENT_MODEL"))
    }

    @Test(arguments: [
        #"{"agents":[]}"#, #"{"version":"1.0.0"}"#, #"{"version":"..","agents":[]}"#, "[1,2]", "not json",
    ])
    func aMalformedIndexFailsAsAWhole(text: String) {
        #expect(throws: ACPRegistryIndex.ParseError.self) { try ACPRegistryIndex.parse(Data(text.utf8)) }
    }

    @Test func anOversizedIndexIsRefused() {
        let padding = String(repeating: " ", count: ACPRegistryIndex.maxBytes)
        #expect(throws: ACPRegistryIndex.ParseError.self) {
            try ACPRegistryIndex.parse(Data(#"{"version":"1.0.0","agents":[]}\#(padding)"#.utf8))
        }
    }

    @Test func distributionsPreferAnArchiveThenNpmThenPython() throws {
        let index = try index()
        // Kilo has both an archive and an npm package: macOS gets the archive, a platform without one the package.
        #expect(index.agent("kilo")?.distribution(for: "darwin-aarch64")?.kind == .binary)
        #expect(index.agent("kilo")?.distribution(for: "windows-aarch64")?.kind == .npx)
        #expect(index.agent("fast-agent")?.distribution(for: "darwin-aarch64")?.kind == .uvx)
        let devin = try #require(index.agent("devin")?.distribution(for: "darwin-aarch64"))
        #expect(devin.arguments == ["acp"])
        #expect(!devin.hasChecksum)
        #expect(index.agent("goose")?.distribution(for: "darwin-x86_64")?.hasChecksum == true)
        // Kimi publishes no Intel Mac build and no package.
        #expect(index.agent("kimi")?.distribution(for: "darwin-x86_64") == nil)
        #expect(index.agent("kimi")?.distribution(for: nil) == nil)
    }

    @Test func searchShowsOnlyAgentsThatCanRunHere() throws {
        let index = try index()
        let all: Set<ACPRegistryDistribution> = [.npx, .uvx]
        let appleSilicon = index.search("", platform: "darwin-aarch64", runners: all).map(\.agent.id)
        // Built-in agents (claude-acp, cursor) are left out, as T3 Code leaves out its first-class providers.
        #expect(appleSilicon == ["devin", "fast-agent", "gemini", "goose", "kilo", "kimi"])
        #expect(!index.search("", platform: "darwin-x86_64", runners: all).map(\.agent.id).contains("kimi"))
        // Without npm or uv, their packages can't install.
        let binariesOnly = index.search("", platform: "darwin-aarch64", runners: []).map(\.agent.id)
        #expect(binariesOnly == ["devin", "goose", "kilo", "kimi"])
        #expect(index.search("claude", platform: "darwin-aarch64", runners: all).isEmpty)
    }

    @Test func searchRanksExactMatchesThenPrefixesThenWordsThenDescriptions() throws {
        let index = try index()
        let search = { (query: String) in index.search(query, platform: "darwin-aarch64", runners: [.npx, .uvx]).map(\.agent.id) }
        #expect(search("goose").first == "goose")
        #expect(search("GEM") == ["gemini"])
        // "cli" starts a word of two names, which rank above Devin's description ("Devin CLI coding agent").
        #expect(search("cli") == ["gemini", "kimi", "devin"])
        #expect(search("cognition") == ["devin"])
        #expect(search("moonshot") == ["kimi"])
        #expect(search("nothing-like-this").isEmpty)
        let goose = try #require(index.agent("goose"))
        #expect(ACPRegistryIndex.rank(goose, "goose") == 0)
        #expect(ACPRegistryIndex.rank(goose, "goo") == 10)
        #expect(ACPRegistryIndex.rank(goose, "block") == 40)
        #expect(ACPRegistryIndex.rank(goose, "automates engineering") == 50)
        #expect(ACPRegistryIndex.rank(goose, "") == 100)
    }

    @Test func thisMacsPlatformIsTheRegistrysName() {
        #expect(ACPRegistryPlatform.key(architecture: "arm64") == "darwin-aarch64")
        #expect(ACPRegistryPlatform.key(architecture: "x86_64") == "darwin-x86_64")
        #expect(ACPRegistryPlatform.key(architecture: "ppc") == nil)
    }

    @Test func commandPathsMustStayInsideTheirFolder() {
        #expect(ACPRegistryPaths.relativeComponents("./bin/devin") == ["bin", "devin"])
        #expect(ACPRegistryPaths.relativeComponents("./goose-package\\goose.exe") == ["goose-package", "goose.exe"])
        for unsafe in ["/usr/bin/env", "../outside", "bin/../../x", "C:/agent.exe", "", "./", "a/./b"] {
            #expect(ACPRegistryPaths.relativeComponents(unsafe) == nil, "\(unsafe)")
        }
        #expect(ACPRegistryInstaller.entriesAreSafe("./\n./goose\nbin/\nbin/devin\n"))
        #expect(!ACPRegistryInstaller.entriesAreSafe("./goose\n../../.zshrc\n"))
        #expect(!ACPRegistryInstaller.entriesAreSafe("/etc/passwd\n"))
    }
}

/// The catalog fetches the index, keeps it for offline searches and falls back to it when the network fails.
@MainActor
struct ACPRegistryCatalogTests {
    @Test func aFailedFetchFallsBackToTheCachedIndex() async throws {
        let data = try acpTemporaryDirectory()
        let paths = ACPRegistryPaths(dataDirectory: data)
        let fresh = ACPRegistryCatalog(paths: paths, fetch: { _ in ACPRegistryFixtures.registry }, which: { _ in nil })
        #expect(await fresh.refresh()?.agents.count == 8)
        // The cache is written off the main thread.
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: paths.registryCache.path) {
            try await Task.sleep(for: .milliseconds(10))
        }

        let offline = ACPRegistryCatalog(paths: paths, fetch: { _ in throw URLError(.notConnectedToInternet) }, which: { _ in nil })
        let results = await offline.search("", platform: "darwin-aarch64")
        #expect(results.map(\.agent.id) == ["devin", "goose", "kilo", "kimi"])
        #expect(offline.failure == nil)

        let empty = ACPRegistryCatalog(
            paths: ACPRegistryPaths(dataDirectory: try acpTemporaryDirectory()), fetch: { _ in throw URLError(.timedOut) },
            which: { _ in nil })
        #expect(await empty.search("goose").isEmpty)
        #expect(empty.failure != nil)
    }

    @Test func packageAgentsAppearWhenTheirManagerIsInstalled() async throws {
        let catalog = ACPRegistryCatalog(
            paths: ACPRegistryPaths(dataDirectory: try acpTemporaryDirectory()), fetch: { _ in ACPRegistryFixtures.registry },
            which: { $0 == "npm" ? URL(fileURLWithPath: "/usr/local/bin/npm") : nil })
        let ids = await catalog.search("", platform: "darwin-aarch64").map(\.agent.id)
        #expect(ids.contains("gemini"))
        #expect(!ids.contains("fast-agent"))
    }
}

// MARK: - Installing

/// A downloader that serves `body`, the way `URLSession` would, and counts its calls.
private final class RegistryDownload: @unchecked Sendable {
    private let lock = NSLock()
    var body: Data
    var status = 200
    var headers: [String: String]?
    private var urls: [URL] = []

    init(_ body: Data) { self.body = body }

    var calls: [URL] { lock.withLock { urls } }

    var downloader: AntigravityDownloader {
        { [self] url, sink in
            lock.withLock { urls.append(url) }
            let headers = self.headers ?? ["Content-Length": String(body.count)]
            try sink.receive(response: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
            var offset = 0
            while offset < body.count {
                let end = min(offset + 5, body.count)
                try sink.receive(body.subdata(in: offset..<end))
                offset = end
            }
        }
    }
}

/// Records the commands an install would run, and plays them: nothing is ever executed.
private final class FakeRunner: @unchecked Sendable {
    struct Call {
        var executable: URL
        var arguments: [String]
        var environment: [String: String]
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    var handle: @Sendable (Call) -> ProcessRunner.Result = { _ in ProcessRunner.Result(status: 0, stdout: "", stderr: "") }

    var calls: [Call] { lock.withLock { recorded } }

    var runner: ACPRegistryInstaller.Runner {
        { [self] executable, arguments, environment, _ in
            let call = Call(executable: executable, arguments: arguments, environment: environment)
            lock.withLock { recorded.append(call) }
            return handle(call)
        }
    }
}

private func sha256(_ data: Data) -> String {
    AntigravityInstaller.hex(SHA256.hash(data: data))
}

private func sampleAgent(
    id: String = "sample", version: String = "1.2.3", archive: String = "https://example.com/sample-agent", command: String = "./sample-agent",
    sha256: String? = nil, npx: String? = nil, uvx: String? = nil
) -> ACPRegistryAgent {
    var binaries: [String: ACPRegistryBinary] = [:]
    if npx == nil && uvx == nil {
        binaries["darwin-aarch64"] = ACPRegistryBinary(
            archive: URL(string: archive)!, command: command, sha256: sha256, arguments: ["acp"], environment: ["SAMPLE_MODE": "acp"])
    }
    return ACPRegistryAgent(
        id: id, name: "Sample Agent", version: version, description: "", authors: [], license: "MIT",
        website: URL(string: "https://example.com"), repository: nil, icon: nil, binaries: binaries,
        npx: npx.map { ACPRegistryPackage(package: $0, arguments: ["--acp"], environment: [:]) },
        uvx: uvx.map { ACPRegistryPackage(package: $0, arguments: ["acp"], environment: [:]) })
}

/// Installing registry agents (T3 Code's `installBinary` and `ensureGlobalPackage` tests) with a fake download and
/// a fake `tar`, `npm` and `uv`.
struct ACPRegistryInstallerTests {
    private let script = Data("#!/bin/sh\necho never run\n".utf8)

    private func installer(_ data: URL, download: RegistryDownload, runner: FakeRunner = FakeRunner()) -> ACPRegistryInstaller {
        ACPRegistryInstaller(
            paths: ACPRegistryPaths(dataDirectory: data), download: download.downloader, run: runner.runner, freeSpace: { _ in nil })
    }

    @Test func aDownloadThatMatchesItsSHA256IsInstalledUnderItsVersion() async throws {
        let data = try acpTemporaryDirectory()
        let download = RegistryDownload(script)
        let agent = sampleAgent(sha256: sha256(script))
        let distribution = try #require(agent.distribution(for: "darwin-aarch64"))
        let install = try await installer(data, download: download).install(agent, distribution, environment: [:])

        #expect(install.agentID == "sample")
        #expect(install.version == "1.2.3")
        #expect(install.distribution == .binary)
        #expect(install.executable == "darwin-aarch64/sample-agent")
        #expect(install.arguments == ["acp"])
        #expect(install.environment == ["SAMPLE_MODE": "acp"])
        #expect(install.sha256 == sha256(script))
        let paths = ACPRegistryPaths(dataDirectory: data)
        let executable = try #require(paths.validatedExecutable(for: install))
        #expect(executable.path.hasSuffix("tools/acp/sample/1.2.3/darwin-aarch64/sample-agent"))
        #expect(try Data(contentsOf: executable) == script)
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))
        // No staging folder is left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.agentDirectory("sample").path) == ["1.2.3"])

        // Installing the same version again finds it complete and downloads nothing.
        _ = try await installer(data, download: download).install(agent, distribution, environment: [:])
        #expect(download.calls.count == 1)
    }

    @Test func aDownloadThatDoesNotMatchItsSHA256InstallsNothing() async throws {
        let data = try acpTemporaryDirectory()
        let agent = sampleAgent(sha256: String(repeating: "0", count: 64))
        let distribution = try #require(agent.distribution(for: "darwin-aarch64"))
        await #expect(throws: ACPRegistryInstallError.self) {
            try await installer(data, download: RegistryDownload(script)).install(agent, distribution, environment: [:])
        }
        let version = ACPRegistryPaths(dataDirectory: data).versionDirectory("sample", "1.2.3")
        #expect(!FileManager.default.fileExists(atPath: version.appendingPathComponent("darwin-aarch64").path))
        #expect((try FileManager.default.contentsOfDirectory(atPath: version.deletingLastPathComponent().path)) == ["1.2.3"])
    }

    @Test func aDownloadWithoutAChecksumKeepsTheRegistrysHTTPSGuarantee() async throws {
        let data = try acpTemporaryDirectory()
        let agent = sampleAgent()
        let distribution = try #require(agent.distribution(for: "darwin-aarch64"))
        let install = try await installer(data, download: RegistryDownload(script)).install(agent, distribution, environment: [:])
        #expect(install.sha256 == nil)
        #expect(ACPRegistryPaths(dataDirectory: data).validatedExecutable(for: install) != nil)
    }

    @Test func refusedDownloadsInstallNothing() async throws {
        let agent = sampleAgent()
        let distribution = try #require(agent.distribution(for: "darwin-aarch64"))
        let missing = RegistryDownload(script)
        missing.status = 404
        await #expect(throws: ACPRegistryInstallError.self) {
            try await installer(try acpTemporaryDirectory(), download: missing).install(agent, distribution, environment: [:])
        }
        let huge = RegistryDownload(script)
        huge.headers = ["Content-Length": String(ACPRegistryInstaller.maxArchiveBytes + 1)]
        await #expect(throws: ACPRegistryInstallError.self) {
            try await installer(try acpTemporaryDirectory(), download: huge).install(agent, distribution, environment: [:])
        }
        let short = RegistryDownload(script)
        short.headers = ["Content-Length": String(script.count + 10)]
        await #expect(throws: ACPRegistryInstallError.self) {
            try await installer(try acpTemporaryDirectory(), download: short).install(agent, distribution, environment: [:])
        }
        let unsafe = sampleAgent(command: "../escape")
        await #expect(throws: ACPRegistryInstallError.self) {
            try await installer(try acpTemporaryDirectory(), download: RegistryDownload(script))
                .install(unsafe, try #require(unsafe.distribution(for: "darwin-aarch64")), environment: [:])
        }
    }

    @Test func anArchiveIsListedAndCheckedBeforeItIsUnpacked() async throws {
        let data = try acpTemporaryDirectory()
        let archive = Data("pretend tar.gz".utf8)
        let agent = sampleAgent(archive: "https://example.com/sample.tar.gz", command: "./bin/sample", sha256: sha256(archive))
        let runner = FakeRunner()
        let script = self.script
        runner.handle = { call in
            if call.arguments.first == "-tf" { return ProcessRunner.Result(status: 0, stdout: "./\n./bin/\n./bin/sample\n", stderr: "") }
            // `tar -xf <archive> -C <folder>`: play the extraction.
            let folder = URL(fileURLWithPath: call.arguments[3])
            try? FileManager.default.createDirectory(at: folder.appendingPathComponent("bin"), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: folder.appendingPathComponent("bin/sample").path, contents: script)
            return ProcessRunner.Result(status: 0, stdout: "", stderr: "")
        }
        let install = try await installer(data, download: RegistryDownload(archive), runner: runner)
            .install(agent, try #require(agent.distribution(for: "darwin-aarch64")), environment: [:])
        #expect(runner.calls.map(\.executable.path) == ["/usr/bin/tar", "/usr/bin/tar"])
        #expect(runner.calls.first?.arguments.first == "-tf")
        #expect(runner.calls.last?.arguments.first == "-xf")
        #expect(install.executable == "darwin-aarch64/bin/sample")
        // tar marks nothing executable here; the installer does.
        #expect(ACPRegistryPaths(dataDirectory: data).validatedExecutable(for: install) != nil)
    }

    @Test func anArchiveWithAnUnsafePathIsNeverUnpacked() async throws {
        let archive = Data("pretend zip".utf8)
        let agent = sampleAgent(archive: "https://example.com/sample.zip", command: "./sample")
        let runner = FakeRunner()
        runner.handle = { call in
            ProcessRunner.Result(status: 0, stdout: call.arguments.first == "-tf" ? "sample\n../../.ssh/authorized_keys\n" : "", stderr: "")
        }
        await #expect(throws: ACPRegistryInstallError.self) {
            try await installer(try acpTemporaryDirectory(), download: RegistryDownload(archive), runner: runner)
                .install(agent, try #require(agent.distribution(for: "darwin-aarch64")), environment: [:])
        }
        #expect(runner.calls.map { $0.arguments.first } == ["-tf"])
    }

    @Test func anExecutableThatLinksOutsideItsFolderIsRefused() async throws {
        let archive = Data("pretend tar.bz2".utf8)
        let agent = sampleAgent(archive: "https://example.com/sample.tar.bz2", command: "./sample")
        let runner = FakeRunner()
        runner.handle = { call in
            if call.arguments.first == "-xf" {
                let folder = URL(fileURLWithPath: call.arguments[3])
                try? FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("sample").path, withDestinationPath: "/bin/sh")
            }
            return ProcessRunner.Result(status: 0, stdout: call.arguments.first == "-tf" ? "sample\n" : "", stderr: "")
        }
        await #expect(throws: ACPRegistryInstallError.self) {
            try await installer(try acpTemporaryDirectory(), download: RegistryDownload(archive), runner: runner)
                .install(agent, try #require(agent.distribution(for: "darwin-aarch64")), environment: [:])
        }
    }

    /// A folder with a fake `npm` or `uv` the fake runner stands in for.
    private func toolFolder(_ name: String) throws -> URL {
        let folder = try acpTemporaryDirectory().appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data(), attributes: [.posixPermissions: 0o755])
        return folder
    }

    @Test func anNpmPackageInstallsAtItsExactVersionIntoCoincidesPrefix() async throws {
        let data = try acpTemporaryDirectory()
        let tools = try toolFolder("npm")
        let agent = sampleAgent(id: "gemini", version: "0.66.0", npx: "@google/gemini-cli@0.66.0")
        let runner = FakeRunner()
        runner.handle = { call in
            // npm's global install into the prefix it was given.
            let prefix = URL(fileURLWithPath: call.environment["npm_config_prefix"] ?? "/nonexistent")
            let package = prefix.appendingPathComponent("lib/node_modules/@google/gemini-cli")
            try? FileManager.default.createDirectory(at: package.appendingPathComponent("dist"), withIntermediateDirectories: true)
            try? Data(#"{"name":"@google/gemini-cli","version":"0.66.0","bin":{"gemini":"dist/index.js"}}"#.utf8)
                .write(to: package.appendingPathComponent("package.json"))
            FileManager.default.createFile(
                atPath: package.appendingPathComponent("dist/index.js").path, contents: Data(), attributes: [.posixPermissions: 0o755])
            try? FileManager.default.createDirectory(at: prefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try? FileManager.default.createSymbolicLink(
                atPath: prefix.appendingPathComponent("bin/gemini").path, withDestinationPath: "../lib/node_modules/@google/gemini-cli/dist/index.js")
            return ProcessRunner.Result(status: 0, stdout: "", stderr: "")
        }
        let distribution = try #require(agent.distribution(for: "darwin-aarch64"))
        let install = try await installer(data, download: RegistryDownload(Data()), runner: runner)
            .install(agent, distribution, environment: ["PATH": tools.path + ":/usr/bin", "HOME": "/Users/test"])

        let call = try #require(runner.calls.first)
        #expect(call.executable == tools.appendingPathComponent("npm"))
        #expect(call.arguments == ["install", "--global", "@google/gemini-cli@0.66.0"])
        #expect(call.environment["npm_config_prefix"]?.hasSuffix("tools/acp/gemini/0.66.0/npm") == true)
        #expect(call.environment["PATH"]?.hasPrefix(tools.path + ":") == true)
        #expect(install.executable == "npm/bin/gemini")
        #expect(install.binDirectory == "npm/bin")
        #expect(install.arguments == ["--acp"])
        #expect(ACPRegistryPaths(dataDirectory: data).validatedExecutable(for: install) != nil)

        // Already installed: npm doesn't run again.
        _ = try await installer(data, download: RegistryDownload(Data()), runner: runner)
            .install(agent, distribution, environment: ["PATH": tools.path])
        #expect(runner.calls.count == 1)
    }

    @Test func aPythonPackageInstallsIntoItsOwnToolFolder() async throws {
        let data = try acpTemporaryDirectory()
        let tools = try toolFolder("uv")
        let agent = sampleAgent(id: "fast-agent", version: "0.10.1", uvx: "fast-agent-acp==0.10.1")
        let runner = FakeRunner()
        runner.handle = { call in
            let bin = URL(fileURLWithPath: call.environment["UV_TOOL_BIN_DIR"] ?? "/nonexistent")
            FileManager.default.createFile(atPath: bin.appendingPathComponent("fast-agent").path, contents: Data(), attributes: [.posixPermissions: 0o755])
            return ProcessRunner.Result(status: 0, stdout: "", stderr: "")
        }
        let install = try await installer(data, download: RegistryDownload(Data()), runner: runner)
            .install(agent, try #require(agent.distribution(for: "darwin-aarch64")), environment: ["PATH": tools.path])
        let call = try #require(runner.calls.first)
        #expect(call.arguments == ["tool", "install", "--force", "fast-agent-acp==0.10.1"])
        #expect(call.environment["UV_TOOL_DIR"]?.hasSuffix("tools/acp/fast-agent/0.10.1/python") == true)
        #expect(install.executable == "python/bin/fast-agent")
        #expect(install.distribution == .uvx)
    }

    @Test func aPackageInstallNeedsItsManagerAndReportsItsFailure() async throws {
        let agent = sampleAgent(id: "gemini", version: "0.66.0", npx: "@google/gemini-cli@0.66.0")
        let distribution = try #require(agent.distribution(for: "darwin-aarch64"))
        let runner = FakeRunner()
        await #expect(throws: ACPRegistryInstallError.self) {
            try await installer(try acpTemporaryDirectory(), download: RegistryDownload(Data()), runner: runner)
                .install(agent, distribution, environment: ["PATH": "/nonexistent"])
        }
        #expect(runner.calls.isEmpty)

        runner.handle = { _ in ProcessRunner.Result(status: 1, stdout: "", stderr: "npm ERR! 404 Not Found\n") }
        do {
            _ = try await installer(try acpTemporaryDirectory(), download: RegistryDownload(Data()), runner: runner)
                .install(agent, distribution, environment: ["PATH": try toolFolder("npm").path])
            Issue.record("The install should fail")
        } catch let error as ACPRegistryInstallError {
            #expect(error.message.contains("npm ERR! 404 Not Found"))
        }
    }

    @Test func npmCommandNamesFollowT3Code() {
        #expect(ACPRegistryInstaller.npmCommandName(agentID: "x", packageName: "@scope/tool", bin: "cli.js") == "tool")
        #expect(ACPRegistryInstaller.npmCommandName(agentID: "x", packageName: "@scope/tool", bin: ["only": "a.js"]) == "only")
        #expect(ACPRegistryInstaller.npmCommandName(agentID: "x", packageName: "tool", bin: ["a": "a.js", "tool": "t.js"]) == "tool")
        #expect(ACPRegistryInstaller.npmCommandName(agentID: "agent", packageName: "pkg", bin: ["agent": "a.js", "b": "b.js"]) == "agent")
        #expect(ACPRegistryInstaller.npmCommandName(agentID: "x", packageName: "pkg", bin: ["a": "same.js", "b": "same.js"]) == "a")
        #expect(ACPRegistryInstaller.npmCommandName(agentID: "x", packageName: "pkg", bin: ["a": "a.js", "b": "b.js"]) == nil)
        #expect(ACPRegistryInstaller.packageCommandCandidates(agentID: "minion-code", packageName: "minion-code") == ["minion-code"])
        #expect(ACPRegistryInstaller.packageCommandCandidates(agentID: "fast-agent", packageName: "fast-agent-acp") == ["fast-agent", "fast-agent-acp"])
    }

    @Test func unusedVersionsAreRemovedUnlessSomethingRunsFromThem() throws {
        let data = try acpTemporaryDirectory()
        let paths = ACPRegistryPaths(dataDirectory: data)
        for folder in ["goose/1.0.0", "goose/1.1.0", "devin/3.0.0", "kimi/1.0.0"] {
            try FileManager.default.createDirectory(
                at: paths.toolsDirectory.appendingPathComponent(folder).appendingPathComponent("darwin-aarch64"), withIntermediateDirectories: true)
        }
        let installer = ACPRegistryInstaller(paths: paths)
        installer.removeUnused(referenced: ["goose/1.1.0"], inUse: [paths.versionDirectory("devin", "3.0.0").path])
        let remaining = try FileManager.default.contentsOfDirectory(atPath: paths.toolsDirectory.path).sorted()
        #expect(remaining == ["devin", "goose"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.agentDirectory("goose").path) == ["1.1.0"])
    }
}
