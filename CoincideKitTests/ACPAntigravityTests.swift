import Compression
import CryptoKit
import Foundation
import Network
import Security
import Testing
import zlib

@testable import CoincideKit

// MARK: - Fixtures

/// Builds ZIP archives byte by byte, including ones no archiver would write, so the installer's
/// checks can be tested against exactly the structure under test.
enum ZipFixture {
    struct Member {
        var name: String
        var data: Data
        var method: UInt16 = 8
        var mode: UInt32 = 0o100755
        var flags: UInt16 = 0
        var dosAttributes: UInt32 = 0
        /// Recorded instead of the real uncompressed size.
        var recordedSize: UInt32?
        /// Recorded instead of the real CRC-32.
        var recordedCRC: UInt32?
    }

    static func build(_ members: [Member], zip64: Bool = false) throws -> Data {
        var archive = Data()
        var directory = Data()
        for member in members {
            let compressed = member.method == 8 ? try deflate(member.data) : member.data
            let crc = member.recordedCRC ?? checksum(member.data)
            let size = member.recordedSize ?? UInt32(member.data.count)
            let name = Data(member.name.utf8)
            let offset = UInt32(archive.count)
            archive.le(UInt32(0x0403_4B50), UInt16(20), member.flags, member.method, UInt16(0), UInt16(0x21))
            archive.le(crc, UInt32(compressed.count), size, UInt16(name.count), UInt16(0))
            archive.append(name)
            archive.append(compressed)
            directory.le(UInt32(0x0201_4B50), UInt16(0x031E), UInt16(20), member.flags, member.method, UInt16(0), UInt16(0x21))
            directory.le(crc, UInt32(compressed.count), size, UInt16(name.count), UInt16(0), UInt16(0), UInt16(0), UInt16(0))
            directory.le(member.mode << 16 | member.dosAttributes, offset)
            directory.append(name)
        }
        let directoryOffset = archive.count
        archive.append(directory)
        let count = UInt16(members.count)
        if zip64 {
            let record = archive.count
            archive.le(UInt32(0x0606_4B50), UInt64(44), UInt16(45), UInt16(45), UInt32(0), UInt32(0))
            archive.le(UInt64(count), UInt64(count), UInt64(directory.count), UInt64(directoryOffset))
            archive.le(UInt32(0x0706_4B50), UInt32(0), UInt64(record), UInt32(1))
            archive.le(UInt32(0x0605_4B50), UInt16(0), UInt16(0), UInt16(0xFFFF), UInt16(0xFFFF))
            archive.le(UInt32(0xFFFF_FFFF), UInt32(0xFFFF_FFFF), UInt16(0))
        } else {
            archive.le(UInt32(0x0605_4B50), UInt16(0), UInt16(0), count, count, UInt32(directory.count), UInt32(directoryOffset), UInt16(0))
        }
        return archive
    }

    static func deflate(_ data: Data) throws -> Data {
        var output = Data()
        let filter = try OutputFilter(.compress, using: .zlib) { if let chunk = $0 { output.append(chunk) } }
        try filter.write(data)
        try filter.finalize()
        return output
    }

    static func checksum(_ data: Data) -> UInt32 {
        UInt32(data.withUnsafeBytes { zlib.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) })
    }
}

extension Data {
    fileprivate mutating func le(_ values: any FixedWidthInteger...) {
        for value in values {
            switch value {
            case let value as UInt16: Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
            case let value as UInt32: Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
            case let value as UInt64: Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
            default: Issue.record("Unsupported integer \(value)")
            }
        }
    }
}

private func sha256(_ data: Data) -> String {
    AntigravityInstaller.hex(SHA256.hash(data: data))
}

/// A release made of two small scripts, pinned the way the real release table pins Google's.
private struct ReleaseFixture {
    var executable = Data("#!/bin/sh\necho agy\n".utf8)
    var harness = Data("#!/bin/sh\necho harness\n".utf8)
    var version = "fixture-new"

    var members: [ZipFixture.Member] {
        [ZipFixture.Member(name: "agy_acp_server.par", data: executable), ZipFixture.Member(name: "localharness_external", data: harness, mode: 0o100555)]
    }

    func archive() throws -> Data { try ZipFixture.build(members) }

    /// Pins `archive` (by default this fixture's own), with the files' real sizes and hashes.
    func asset(archive: Data? = nil) throws -> AntigravityReleaseAsset {
        let archive = try archive ?? self.archive()
        return AntigravityReleaseAsset(
            version: version, url: URL(string: "https://dl.google.com/antigravity-test.zip")!, sha256: sha256(archive),
            archiveBytes: Int64(archive.count),
            executable: .init(
                name: "agy_acp_server.par", bytes: Int64(executable.count), sha256: sha256(executable), signingIdentifier: "agy_acp_server"),
            harness: .init(
                name: "localharness_external", bytes: Int64(harness.count), sha256: sha256(harness),
                signingIdentifier: "localharness_external"))
    }
}

/// Thread-safe call log for the injected installer steps.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func add(_ item: String) { lock.withLock { items.append(item) } }
    var all: [String] { lock.withLock { items } }
}

/// Serves an archive the way `URLSession` would, in small chunks.
private final class FakeDownload: @unchecked Sendable {
    var body: Data
    var headers: [String: String]
    var status = 200
    var delayPerChunk: Duration?
    let calls = Calls()

    init(_ body: Data, headers: [String: String]? = nil) {
        self.body = body
        self.headers = headers ?? ["Content-Length": String(body.count)]
    }

    var downloader: AntigravityDownloader {
        { [self] url, sink in
            calls.add(url.absoluteString)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            try sink.receive(response: response)
            var offset = 0
            while offset < body.count {
                try Task.checkCancellation()
                if let delayPerChunk { try await Task.sleep(for: delayPerChunk) }
                let end = min(offset + 7, body.count)
                try sink.receive(body.subdata(in: offset..<end))
                offset = end
            }
        }
    }
}

@MainActor
private struct InstallHarness {
    let data: URL
    let paths: AntigravityPaths
    let download: FakeDownload
    let signatures: Calls
    let validations: Calls
    let runtime: AntigravityRuntime

    init(
        asset: AntigravityReleaseAsset?, archive: Data, data: URL? = nil, signatureFails: Bool = false,
        validateFails: Bool = false, validateDelay: Duration? = nil, freeSpace: Int64? = nil
    ) throws {
        let data = try data ?? acpTemporaryDirectory()
        self.data = data
        paths = AntigravityPaths(dataDirectory: data, architecture: "arm64")
        download = FakeDownload(archive)
        let signatures = Calls()
        let validations = Calls()
        self.signatures = signatures
        self.validations = validations
        runtime = AntigravityRuntime(
            paths: paths, asset: asset, download: download.downloader,
            verifySignature: { url, requirement in
                signatures.add(url.lastPathComponent + " " + requirement)
                if signatureFails { throw AntigravityInstallError("verify", "unsigned") }
            },
            validate: { executable, version in
                validations.add("\(executable.executable.path) \(version)")
                if let validateDelay { try await Task.sleep(for: validateDelay) }
                if validateFails { throw AntigravityInstallError("verify", "not the expected release") }
            },
            freeSpace: { _ in freeSpace })
    }

    func install() async {
        runtime.install()
        await acpWaitUntil("installation", timeout: .seconds(20)) { !runtime.state.isRunning }
    }

    var currentTarget: String? { try? FileManager.default.destinationOfSymbolicLink(atPath: paths.currentLink.path) }

    var versionFolders: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: paths.versionsDirectory.path)) ?? []).sorted()
    }
}

// MARK: - Release table

struct AntigravityReleaseTests {
    @Test func picksGooglesArchiveForEachMacArchitecture() throws {
        let arm = try #require(AntigravityRelease.asset(architecture: "arm64"))
        #expect(arm.url.absoluteString == "https://dl.google.com/agy-extensions/releases/macos/agy-acp-server-1.3.0-darwin-arm64.zip")
        #expect(arm.sha256 == "7cd97045f7b4fe81175a107cdf16f9c51484e3c78a5162cae415338bb6aa5b88")
        #expect(arm.archiveBytes == 111_456_962)
        #expect(arm.executable.bytes == 278_535_456 && arm.harness.bytes == 118_611_392)
        let intel = try #require(AntigravityRelease.asset(architecture: "x86_64"))
        #expect(intel.url.lastPathComponent == "agy-acp-server-1.3.0-darwin-x86_64.zip")
        #expect(intel.sha256 == "bb23956b89984bf5d354af2c3725e6c57f0cc1b7228e77a0e91c9c2bc1d47646")
        for alias in ["aarch64", "ARM64"] { #expect(AntigravityRelease.asset(architecture: alias) == arm) }
        for alias in ["x64", "amd64"] { #expect(AntigravityRelease.asset(architecture: alias) == intel) }
        for unsupported in ["ppc", "riscv64", "", "darwin-arm64"] { #expect(AntigravityRelease.asset(architecture: unsupported) == nil) }
        #expect(AntigravityRelease.platformKey(architecture: "arm64") == "darwin-arm64")
        #expect(AntigravityRelease.platformKey(architecture: "x86_64") == "darwin-x64")
        #expect(["arm64", "x86_64"].contains(AntigravityRelease.hostArchitecture))
        #expect(AntigravityRelease.asset() != nil)
    }

    @Test func everyPinIsStrict() throws {
        for architecture in ["arm64", "x64"] {
            let asset = try #require(AntigravityRelease.asset(architecture: architecture))
            #expect(asset.version == AntigravityRelease.version)
            #expect(asset.url.scheme == "https" && asset.url.host == "dl.google.com")
            for hash in [asset.sha256] + asset.files.map(\.sha256) { #expect(AntigravityInstaller.isReleaseID(hash)) }
            #expect(asset.files.map(\.name) == ["agy_acp_server.par", "localharness_external"])
            #expect(asset.requiredFreeSpace > asset.archiveBytes + asset.executable.bytes + asset.harness.bytes)
            for file in asset.files {
                var requirement: SecRequirement?
                let text = AntigravityRelease.signingRequirement(for: file)
                #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
                #expect(text.contains("identifier \"\(file.signingIdentifier)\"") && text.contains("EQHXZ8M8AV"))
            }
        }
    }

    @Test func signatureChecksNeedTheRightSigner() throws {
        // An Apple binary meets Apple's requirement, but not Google's.
        try AntigravityInstaller.verifyCodeSignature(URL(fileURLWithPath: "/bin/ls"), requirement: "anchor apple and identifier \"com.apple.ls\"")
        let google = try #require(AntigravityRelease.asset(architecture: "arm64")).executable
        #expect(throws: AntigravityInstallError.self) {
            try AntigravityInstaller.verifyCodeSignature(URL(fileURLWithPath: "/bin/ls"), requirement: AntigravityRelease.signingRequirement(for: google))
        }
        let directory = try acpTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unsigned = directory.appendingPathComponent("agy_acp_server.par")
        try Data("#!/bin/sh\n".utf8).write(to: unsigned)
        #expect(throws: AntigravityInstallError.self) {
            try AntigravityInstaller.verifyCodeSignature(unsigned, requirement: "anchor apple generic")
        }
    }
}

// MARK: - ZIP reading

struct AntigravityZipTests {
    private func write(_ data: Data) throws -> URL {
        let url = try acpTemporaryDirectory().appendingPathComponent("archive.zip")
        try data.write(to: url)
        return url
    }

    private func contents(_ zip: AntigravityZip, _ entry: AntigravityZip.Entry) throws -> Data {
        var data = Data()
        try zip.extract(entry) { data.append($0) }
        return data
    }

    @Test func readsDeflatedAndStoredMembers() throws {
        let big = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 * 7 &+ $0 / 13) })
        let zip = try AntigravityZip(
            url: write(
                ZipFixture.build([
                    .init(name: "a.bin", data: big), .init(name: "b.txt", data: Data("stored".utf8), method: 0, mode: 0o100644),
                ])))
        #expect(zip.entries.map(\.name) == ["a.bin", "b.txt"])
        #expect(zip.entries[0].unixFileType == 0o100000 && zip.entries[0].method == 8)
        #expect(try contents(zip, zip.entries[0]) == big)
        #expect(try contents(zip, zip.entries[1]) == Data("stored".utf8))
    }

    @Test func readsZIP64Directories() throws {
        let zip = try AntigravityZip(url: write(ZipFixture.build([.init(name: "x", data: Data("hello".utf8))], zip64: true)))
        #expect(zip.entries.map(\.name) == ["x"])
        #expect(try contents(zip, zip.entries[0]) == Data("hello".utf8))
    }

    @Test func readsArchivesMadeByZip() async throws {
        let directory = try acpTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data(String(repeating: "antigravity ", count: 5_000).utf8)
        try payload.write(to: directory.appendingPathComponent("member.txt"))
        let archive = directory.appendingPathComponent("made.zip")
        let result = await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/zip"), ["-q", "-X", archive.path, "member.txt"], cwd: directory, timeout: 20)
        try #require(result.succeeded)
        let zip = try AntigravityZip(url: archive)
        #expect(zip.entries.map(\.name) == ["member.txt"])
        #expect(try contents(zip, zip.entries[0]) == payload)
    }

    @Test func refusesDamagedMembers() throws {
        let data = Data(repeating: 0x41, count: 4_096)
        // A wrong CRC-32, a member that inflates past its recorded size, and one that stops short.
        for member in [
            ZipFixture.Member(name: "crc", data: data, recordedCRC: 0x1234_5678),
            ZipFixture.Member(name: "big", data: data, recordedSize: 100),
            ZipFixture.Member(name: "small", data: data, method: 0, recordedSize: 5_000),
        ] {
            let zip = try AntigravityZip(url: write(ZipFixture.build([member])))
            #expect(throws: AntigravityZip.Failure.self) { _ = try contents(zip, zip.entries[0]) }
        }
        // Truncated archives and non-archives are refused before any member is read.
        let whole = try ZipFixture.build([.init(name: "a", data: data)])
        #expect(throws: (any Error).self) { _ = try AntigravityZip(url: write(whole.prefix(whole.count - 30))) }
        #expect(throws: (any Error).self) { _ = try AntigravityZip(url: write(Data("not a zip at all, honestly".utf8))) }
    }

    @Test func stopsWhenCancelled() throws {
        let zip = try AntigravityZip(url: write(ZipFixture.build([.init(name: "a", data: Data(repeating: 1, count: 3 << 20), method: 0)])))
        #expect(throws: CancellationError.self) { try zip.extract(zip.entries[0], isCancelled: { true }) { _ in } }
    }
}

// MARK: - Installation

@MainActor
struct AntigravityInstallTests {
    @Test func installsAVerifiedReleaseAndActivatesIt() async throws {
        let fixture = ReleaseFixture()
        let asset = try fixture.asset()
        let harness = try InstallHarness(asset: asset, archive: fixture.archive())
        #expect(harness.runtime.state.installedVersion == nil && !harness.runtime.state.canRemove)
        await harness.install()

        let state = harness.runtime.state
        #expect(state.phase == .succeeded, "\(state.message ?? "")")
        #expect(state.installedVersion == "fixture-new" && state.canRemove && !state.isUpdateAvailable)
        #expect(state.downloadedBytes == asset.archiveBytes)
        #expect(harness.download.calls.all == ["https://dl.google.com/antigravity-test.zip"])
        #expect(harness.currentTarget == "versions/" + asset.sha256)
        #expect(harness.versionFolders == [asset.sha256])

        // Both files carry Google's requirement, and the release ran once before it became active.
        #expect(harness.signatures.all.count == 2)
        #expect(harness.signatures.all.allSatisfy { $0.contains("EQHXZ8M8AV") })
        #expect(harness.validations.all.count == 1)
        #expect(harness.validations.all[0].contains("/.install-") && harness.validations.all[0].hasSuffix(" fixture-new"))

        let release = harness.paths.versionsDirectory.appendingPathComponent(asset.sha256)
        #expect(try Data(contentsOf: release.appendingPathComponent("agy_acp_server.par")) == fixture.executable)
        let mode = try FileManager.default.attributesOfItem(atPath: release.appendingPathComponent("localharness_external").path)[.posixPermissions]
        #expect(mode as? Int == 0o755)
        let active = try #require(try harness.runtime.activeRelease())
        #expect(active.version == "fixture-new")
        #expect(ACPProfile.managedAntigravityExecutable(paths: harness.paths) == harness.paths.managedExecutable)
        #expect(AntigravityFlavor.harnessURL(for: harness.paths.managedExecutable).lastPathComponent == "localharness_external")
        #expect(
            AntigravityFlavor.harnessURL(for: harness.paths.managedExecutable).resolvingSymlinksInPath().path
                == active.harness.resolvingSymlinksInPath().path)
    }

    @Test func failsClosedWhenTheDownloadDoesNotMatchItsPin() async throws {
        let fixture = ReleaseFixture()
        let archive = try fixture.archive()
        var tampered = archive
        tampered[40] ^= 0xFF
        var extra = archive
        extra.append(0)
        let cases: [(body: Data, headers: [String: String]?, message: String)] = [
            (tampered, nil, "SHA-256"),
            (archive.prefix(archive.count - 1), ["Content-Length": String(archive.count)], "SHA-256"),
            (extra, ["Content-Length": String(extra.count)], "didn’t match"),
            (extra, ["Content-Encoding": "gzip"], "exceeded"),
        ]
        for testCase in cases {
            let harness = try InstallHarness(asset: try fixture.asset(archive: archive), archive: archive)
            harness.download.body = testCase.body
            harness.download.headers = testCase.headers ?? [:]
            await harness.install()
            #expect(harness.runtime.state.phase == .failed)
            #expect(harness.runtime.state.message?.contains(testCase.message) == true, "\(harness.runtime.state.message ?? "")")
            // Nothing ran and nothing was kept.
            #expect(harness.signatures.all.isEmpty && harness.validations.all.isEmpty)
            #expect(harness.currentTarget == nil)
            #expect(harness.versionFolders.isEmpty)
        }
    }

    @Test func acceptsAnEncodedContentLengthAndRefusesServerErrors() async throws {
        let fixture = ReleaseFixture()
        let archive = try fixture.archive()
        let compressed = try InstallHarness(asset: fixture.asset(), archive: archive)
        compressed.download.headers = ["Content-Encoding": "gzip", "Content-Length": "12"]
        await compressed.install()
        #expect(compressed.runtime.state.phase == .succeeded)

        let missing = try InstallHarness(asset: fixture.asset(), archive: archive)
        missing.download.status = 404
        await missing.install()
        #expect(missing.runtime.state.phase == .failed)
        #expect(missing.runtime.state.message?.contains("404") == true)
    }

    @Test func refusesUnexpectedArchiveMembers() async throws {
        let fixture = ReleaseFixture()
        let members = fixture.members
        let cases: [(members: [ZipFixture.Member], message: String)] = [
            (members + [.init(name: "README", data: Data("x".utf8))], "exactly"),
            ([members[0], .init(name: "../localharness_external", data: fixture.harness)], "unexpected, unsafe"),
            ([members[0], .init(name: "localharness_external", data: fixture.harness, mode: 0o120777)], "unexpected, unsafe"),
            ([members[0], .init(name: "localharness_external", data: fixture.harness, dosAttributes: 0x10)], "unexpected, unsafe"),
            ([members[0], .init(name: "localharness_external", data: fixture.harness, flags: 1)], "unexpected, unsafe"),
            ([members[0], .init(name: "localharness_external", data: fixture.harness, method: 12)], "unexpected, unsafe"),
            ([members[0], .init(name: "localharness_external", data: fixture.harness + Data("x".utf8))], "unexpected, unsafe"),
            ([members[0], members[0]], "unexpected, unsafe"),
        ]
        for testCase in cases {
            let archive = try ZipFixture.build(testCase.members)
            let harness = try InstallHarness(asset: try fixture.asset(archive: archive), archive: archive)
            await harness.install()
            #expect(harness.runtime.state.phase == .failed)
            #expect(harness.runtime.state.message?.contains(testCase.message) == true, "\(harness.runtime.state.message ?? "")")
            #expect(harness.validations.all.isEmpty && harness.currentTarget == nil && harness.versionFolders.isEmpty)
        }
    }

    @Test func refusesFilesThatDoNotMatchTheirPinOrSignature() async throws {
        let fixture = ReleaseFixture()
        let archive = try fixture.archive()
        var wrongFile = try fixture.asset()
        wrongFile.harness.sha256 = String(repeating: "0", count: 64)
        let hashes = try InstallHarness(asset: wrongFile, archive: archive)
        await hashes.install()
        #expect(hashes.runtime.state.message?.contains("SHA-256") == true)
        #expect(hashes.signatures.all.isEmpty && hashes.validations.all.isEmpty && hashes.currentTarget == nil)

        let unsigned = try InstallHarness(asset: fixture.asset(), archive: archive, signatureFails: true)
        await unsigned.install()
        #expect(unsigned.runtime.state.phase == .failed)
        #expect(unsigned.validations.all.isEmpty && unsigned.currentTarget == nil && unsigned.versionFolders.isEmpty)
    }

    @Test func aFailedUpdateKeepsThePreviousRelease() async throws {
        let old = ReleaseFixture(version: "1.2.0")
        let data = try acpTemporaryDirectory()
        let first = try InstallHarness(asset: old.asset(), archive: old.archive(), data: data)
        await first.install()
        #expect(first.runtime.state.installedVersion == "1.2.0")
        let oldTarget = first.currentTarget

        // A newer pin offers an update; one that fails its check changes nothing.
        let new = ReleaseFixture(executable: Data("#!/bin/sh\necho new\n".utf8), version: "1.3.0")
        let newID = try new.asset().sha256
        let failing = try InstallHarness(asset: new.asset(), archive: new.archive(), data: data, validateFails: true)
        #expect(failing.runtime.state.installedVersion == "1.2.0" && failing.runtime.state.isUpdateAvailable)
        await failing.install()
        #expect(failing.runtime.state.phase == .failed)
        #expect(failing.runtime.state.installedVersion == "1.2.0")
        #expect(failing.currentTarget == oldTarget)

        // A working update replaces it, and the old release goes once nothing runs from it.
        let updating = try InstallHarness(asset: new.asset(), archive: new.archive(), data: data)
        await updating.install()
        #expect(updating.runtime.state.installedVersion == "1.3.0" && !updating.runtime.state.isUpdateAvailable)
        #expect(updating.currentTarget == "versions/" + newID)
        await acpWaitUntil("old release pruned") { updating.versionFolders == [newID] }
    }

    @Test func reinstallingChecksTheReleaseOnDiskWithoutDownloading() async throws {
        let fixture = ReleaseFixture()
        let asset = try fixture.asset()
        let data = try acpTemporaryDirectory()
        let first = try InstallHarness(asset: asset, archive: fixture.archive(), data: data)
        await first.install()
        try FileManager.default.removeItem(at: first.paths.currentLink)

        let again = try InstallHarness(asset: asset, archive: fixture.archive(), data: data)
        await again.install()
        #expect(again.runtime.state.phase == .succeeded)
        #expect(again.download.calls.all.isEmpty)
        #expect(again.signatures.all.count == 2 && again.validations.all.count == 1)
        #expect(again.currentTarget == "versions/" + asset.sha256)

        // A file changed on disk (same size, so its record still matches) is refused before it runs again.
        let release = again.paths.versionsDirectory.appendingPathComponent(asset.sha256)
        try Data("#!/bin/sh\necho AGY\n".utf8).write(to: release.appendingPathComponent("agy_acp_server.par"))
        try FileManager.default.removeItem(at: again.paths.currentLink)
        let tampered = try InstallHarness(asset: asset, archive: fixture.archive(), data: data)
        #expect(tampered.runtime.state.installedVersion == nil)
        await tampered.install()
        #expect(tampered.runtime.state.phase == .failed)
        #expect(tampered.runtime.state.message?.contains("no longer matches") == true, "\(tampered.runtime.state.message ?? "")")
        #expect(tampered.signatures.all.isEmpty && tampered.validations.all.isEmpty && tampered.currentTarget == nil)
    }

    @Test func cancellingKeepsThePreviousRuntime() async throws {
        let fixture = ReleaseFixture()
        let harness = try InstallHarness(asset: fixture.asset(), archive: fixture.archive(), validateDelay: .seconds(30))
        harness.runtime.install()
        await acpWaitUntil("verifying", timeout: .seconds(10)) { harness.runtime.state.phase == .verifying }
        await acpWaitUntil("validation started") { !harness.validations.all.isEmpty }
        harness.runtime.cancel()
        await acpWaitUntil("cancelled", timeout: .seconds(10)) { !harness.runtime.state.isRunning }
        #expect(harness.runtime.state.phase == .cancelled)
        #expect(harness.currentTarget == nil)
        await acpWaitUntil("staging removed") { harness.versionFolders.isEmpty }

        // Cancelling during the download works the same way.
        let slow = try InstallHarness(asset: fixture.asset(), archive: fixture.archive())
        slow.download.delayPerChunk = .milliseconds(50)
        slow.runtime.install()
        await acpWaitUntil("download progress") { slow.runtime.state.downloadedBytes > 0 }
        slow.runtime.cancel()
        await acpWaitUntil("cancelled", timeout: .seconds(10)) { !slow.runtime.state.isRunning }
        #expect(slow.runtime.state.phase == .cancelled)
        #expect(slow.runtime.state.message?.contains("unchanged") == true)
    }

    @Test func checksSpaceAndSupportBeforeDownloading() async throws {
        let fixture = ReleaseFixture()
        let full = try InstallHarness(asset: fixture.asset(), archive: fixture.archive(), freeSpace: 1_000)
        await full.install()
        #expect(full.runtime.state.message?.contains("free space") == true)
        #expect(full.download.calls.all.isEmpty)

        let unsupported = try InstallHarness(asset: nil, archive: Data())
        unsupported.runtime.install()
        #expect(unsupported.runtime.state.phase == .failed)
        #expect(unsupported.runtime.state.message?.contains("darwin-arm64") == true)
        #expect(unsupported.download.calls.all.isEmpty)
    }

    @Test func removalWaitsForLeasesAndKeepsTheProfile() async throws {
        let fixture = ReleaseFixture()
        let harness = try InstallHarness(asset: fixture.asset(), archive: fixture.archive())
        await harness.install()
        let profile = harness.paths.profileDirectory
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)

        #expect(harness.runtime.lease(for: URL(fileURLWithPath: "/usr/bin/true")) == nil)
        var lease = harness.runtime.lease(for: harness.paths.managedExecutable)
        #expect(lease != nil && harness.runtime.leaseCount == 1)
        #expect(throws: AntigravityInstallError.self) { try harness.runtime.remove() }
        lease = nil
        #expect(harness.runtime.leaseCount == 0)
        // A custom path inside the runtime would break if it went away.
        #expect(throws: AntigravityInstallError.self) { try harness.runtime.remove(protecting: [harness.paths.managedExecutable.path]) }

        try harness.runtime.remove(protecting: ["", "/usr/local/bin/agy_acp_server.par"])
        #expect(!FileManager.default.fileExists(atPath: harness.paths.managedDirectory.path))
        #expect(FileManager.default.fileExists(atPath: profile.path))
        #expect(harness.runtime.state.installedVersion == nil && !harness.runtime.state.canRemove && harness.runtime.state.phase == .idle)
        _ = lease
    }

    @Test func reportsAnIncompleteRelease() async throws {
        let data = try acpTemporaryDirectory()
        let paths = AntigravityPaths(dataDirectory: data, architecture: "arm64")
        try FileManager.default.createDirectory(at: paths.versionsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: paths.currentLink.path, withDestinationPath: "versions/../../elsewhere")
        let runtime = AntigravityRuntime(paths: paths, asset: nil)
        #expect(runtime.state.phase == .failed)
        #expect(runtime.state.canRemove)
        try runtime.remove()
        #expect(runtime.state.phase == .idle)
    }
}

// MARK: - Private profile

@MainActor
struct AntigravityProfileTests {
    private func makeProfile() throws -> (AntigravityProfile, URL) {
        let root = try acpTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        return (AntigravityProfile(geminiHome: root.appendingPathComponent("Coincide/providers/antigravity/default"), userHome: home), home)
    }

    @Test func isolatesTheEnvironmentFromTheUsersOwnProfile() throws {
        let (profile, _) = try makeProfile()
        let base = [
            "HOME": "/Users/me", "PATH": "/usr/bin", "GEMINI_API_KEY": "no-api-billing", "google_api_key": "alias",
            "GOOGLE_CLOUD_PROJECT": "p", "GOOGLE_APPLICATION_CREDENTIALS": "/c.json", "GOOGLE_GENAI_USE_VERTEXAI": "true",
            "AGY_ACP_ENABLE_OAUTH": "1", "GEMINI_HOME": "/Users/me/.gemini", "gemini_home": "/alias", "AGY_ACP_FORCE_FILE_STORAGE": "0",
            "ANTIGRAVITY_HARNESS_PATH": "/wrong/harness", "BROWSER": "open", "browser": "firefox", "PYTHONUNBUFFERED": "0",
            "ELECTRON_RUN_AS_NODE": "1", "CUSTOM_SETTING": "keep",
        ]
        let environment = profile.environment(base, harness: URL(fileURLWithPath: "/release/localharness_external"))
        #expect(
            environment == [
                "HOME": "/Users/me", "PATH": "/usr/bin", "CUSTOM_SETTING": "keep", "GEMINI_HOME": profile.geminiHome.path,
                "AGY_ACP_FORCE_FILE_STORAGE": "1", "BROWSER": profile.browserCommand, "PYTHONUNBUFFERED": "1",
                "ANTIGRAVITY_HARNESS_PATH": "/release/localharness_external",
            ])
        #expect(!profile.browserCommand.contains(":"))
    }

    @Test func preparesPrivateFoldersSettingsAndALinkCatchingBrowser() async throws {
        let (profile, home) = try makeProfile()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini/config/skills"), withIntermediateDirectories: true)
        try await profile.prepare(environment: ["PATH": "/usr/bin:/bin"])
        for directory in [profile.geminiHome, profile.acpDirectory] {
            let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
            #expect(mode == 0o700)
        }
        #expect(try String(contentsOf: profile.settingsFile, encoding: .utf8) == "{\"auth\":{\"type\":\"oauth-personal\"}}\n")
        #expect(!profile.isSignedIn)
        // The user's skills are linked in, whether or not their folders exist yet.
        for relative in ["config/skills", "antigravity-cli/skills"] {
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: profile.geminiHome.appendingPathComponent(relative).path)
            #expect(target == home.appendingPathComponent(".gemini/\(relative)").path)
        }

        // Python's webbrowser would split BROWSER like a shell and run the helper with the link.
        let words = await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"), ["-c", #"eval "set -- $BROWSER"; for a; do printf '[%s]' "$a"; done"#],
            environment: ["BROWSER": profile.browserCommand])
        #expect(words.stdout == "[/bin/sh][\(profile.browserHelper.path)][%s]")
        let link = "https://accounts.google.com/o/oauth2/v2/auth?state=s&response_type=code"
        let helper = await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), [profile.browserHelper.path, link])
        #expect(helper.status == 0 && helper.stdout.isEmpty && helper.stderr == AntigravityProfile.browserMarker + link + "\n")
        // A link with a line break is never split into a look-alike line.
        let split = await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), [profile.browserHelper.path, "https://x\nhttps://y"])
        #expect(split.status == 0 && split.stderr.isEmpty)

        // Running it again changes nothing, and leaves a folder the user put there alone.
        try FileManager.default.removeItem(at: profile.geminiHome.appendingPathComponent("antigravity-cli/skills"))
        try FileManager.default.createDirectory(at: profile.geminiHome.appendingPathComponent("antigravity-cli/skills"), withIntermediateDirectories: true)
        try await profile.prepare(environment: [:])
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: profile.geminiHome.appendingPathComponent("antigravity-cli/skills").path)) == nil)

        try Data("{}".utf8).write(to: profile.tokenFile)
        #expect(profile.isSignedIn)
    }

    @Test func comparesPathsThroughLinksEvenBeforeFilesExist() throws {
        let root = try acpTemporaryDirectory()
        let target = root.appendingPathComponent("versions/abc", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("current").path, withDestinationPath: "versions/abc")
        #expect(AntigravityPaths.canonicalPath(root.appendingPathComponent("current/missing.par")) == target.path + "/missing.par")
        let spelledDifferently = URL(fileURLWithPath: root.path.replacingOccurrences(of: "/private/var/", with: "/var/"))
        #expect(AntigravityPaths.canonicalPath(spelledDifferently.appendingPathComponent("current/x")) == target.path + "/x")
        let paths = AntigravityPaths(dataDirectory: spelledDifferently, architecture: "arm64")
        #expect(paths.isManaged(root.appendingPathComponent("tools/antigravity-acp/darwin-arm64/current/agy_acp_server.par")))
        #expect(!paths.isManaged(root.appendingPathComponent("tools/antigravity-acp/darwin-arm64-evil/agy_acp_server.par")))
        #expect(!paths.isManaged(URL(fileURLWithPath: "/usr/local/bin/agy_acp_server.par")))
    }

    @Test func refusesPathsPythonWouldSplit() async throws {
        let root = try acpTemporaryDirectory()
        let profile = AntigravityProfile(geminiHome: root.appendingPathComponent("odd:folder"))
        await #expect(throws: AntigravityProfileError.self) { try await profile.prepare(environment: [:]) }
        #expect(!FileManager.default.fileExists(atPath: profile.geminiHome.path))
    }

    @Test func removesOnlyTheThrowawaySessionItCreated() throws {
        let (profile, _) = try makeProfile()
        let workspace = try acpTemporaryDirectory()
        let conversations = profile.acpDirectory.appendingPathComponent("conversations", isDirectory: true)
        let brain = profile.acpDirectory.appendingPathComponent("brain", isDirectory: true)
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        let mine = "3f2b8c1e-9d4a-4b6f-8e2d-1c0a9b8f7e6d"
        let theirs = "7a1c2e3f-4b5d-4e6f-9a8b-0c1d2e3f4a5b"
        for (id, cwd) in [(mine, workspace.path), (theirs, "/Users/me/project")] {
            try Data(#"{"cwd":"\#(cwd)"}"#.utf8).write(to: conversations.appendingPathComponent(id + ".meta"))
            try Data().write(to: conversations.appendingPathComponent(id + ".db"))
            try FileManager.default.createDirectory(at: brain.appendingPathComponent(id), withIntermediateDirectories: true)
        }
        profile.removeSessionFiles(sessionID: "../\(theirs)", cwd: workspace)
        profile.removeSessionFiles(sessionID: theirs, cwd: workspace)
        profile.removeSessionFiles(sessionID: mine, cwd: workspace)
        #expect(try FileManager.default.contentsOfDirectory(atPath: conversations.path).sorted() == [theirs + ".db", theirs + ".meta"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: brain.path) == [theirs])
    }
}

// MARK: - Sign-in links and callbacks

struct AntigravityAuthorizationTests {
    static let link =
        "https://accounts.google.com/o/oauth2/v2/auth?response_type=code&client_id=test-client"
        + "&redirect_uri=http%3A%2F%2F127.0.0.1%3A46353%2F&state=test-opaque-state&code_challenge=c&code_challenge_method=S256"

    @Test func acceptsOnlyGooglesLoopbackSignIn() throws {
        let request = try #require(AntigravityAuthorization.parse(Self.link))
        #expect(request.redirectURI == "http://127.0.0.1:46353/")
        #expect(request.state == "test-opaque-state")
        #expect(request.url.absoluteString == Self.link)
        let rejected = [
            Self.link.replacingOccurrences(of: "accounts.google.com", with: "accounts.google.com.evil.example"),
            Self.link.replacingOccurrences(of: "https://", with: "http://"),
            Self.link.replacingOccurrences(of: "https://", with: "https://user:pass@"),
            Self.link.replacingOccurrences(of: "accounts.google.com", with: "accounts.google.com:8443"),
            Self.link.replacingOccurrences(of: "/o/oauth2/v2/auth", with: "/o/oauth2/auth"),
            Self.link + "#fragment",
            Self.link + "&state=second",
            Self.link + "&redirect_uri=http%3A%2F%2F127.0.0.1%3A5000%2F",
            Self.link.replacingOccurrences(of: "response_type=code", with: "response_type=token"),
            Self.link.replacingOccurrences(of: "127.0.0.1%3A46353", with: "localhost%3A46353"),
            Self.link.replacingOccurrences(of: "127.0.0.1%3A46353%2F", with: "127.0.0.1%3A46353%2Fpath"),
            Self.link.replacingOccurrences(of: "%3A46353", with: "%3A80"),
            Self.link.replacingOccurrences(of: "%3A46353", with: "%3A70000"),
            Self.link.replacingOccurrences(of: "test-opaque-state", with: "a+b"),
            Self.link.replacingOccurrences(of: "test-opaque-state", with: String(repeating: "s", count: 513)),
            Self.link.replacingOccurrences(of: "&state=test-opaque-state", with: ""),
            Self.link + " ",
            Self.link + String(repeating: "x", count: 16_384),
        ]
        for text in rejected { #expect(AntigravityAuthorization.parse(text) == nil, "\(text.prefix(160))") }
    }

    @Test func findsLinksFromTheAgentAndTheBrowserHelper() {
        #expect(AntigravityFlavor.authorizationText(in: AntigravityFlavor.signInPrefix + Self.link + "\r") == Self.link)
        #expect(AntigravityFlavor.authorizationText(in: AntigravityProfile.browserMarker + Self.link) == Self.link)
        #expect(AntigravityFlavor.authorizationText(in: "Open the link: " + Self.link) == nil)
        #expect(AntigravityFlavor.authorizationText(in: "x" + AntigravityProfile.browserMarker + Self.link) == nil)
    }

    @Test func acceptsTheExactCallbackAndAnExplicitDenial() throws {
        let pending = try #require(AntigravityAuthorization.parse(Self.link))
        let code = try AntigravityCallback.validate(
            "http://127.0.0.1:46353/?state=test-opaque-state&code=4%2F0Ab&scope=email&iss=https%3A%2F%2Faccounts.google.com", for: pending)
        #expect(code.absoluteString.hasPrefix("http://127.0.0.1:46353/?state=test-opaque-state&code=4%2F0Ab"))
        _ = try AntigravityCallback.validate("http://127.0.0.1:46353?state=test-opaque-state&error=access_denied", for: pending)
    }

    @Test func rejectsCallbacksForAnythingElse() throws {
        let pending = try #require(AntigravityAuthorization.parse(Self.link))
        let base = "http://127.0.0.1:46353/?state=test-opaque-state&code=abc"
        let rejected = [
            "not a url", "127.0.0.1:46353/?state=test-opaque-state&code=abc",
            base.replacingOccurrences(of: "46353", with: "46354"),
            base.replacingOccurrences(of: "127.0.0.1", with: "localhost"),
            base.replacingOccurrences(of: "http://", with: "https://"),
            base.replacingOccurrences(of: "http://", with: "http://user:pw@"),
            base.replacingOccurrences(of: "/?", with: "/other?"),
            base + "#x",
            base.replacingOccurrences(of: "test-opaque-state", with: "another-state"),
            base + "&state=test-opaque-state",
            base + "&code=second",
            base + "&error=access_denied",
            base.replacingOccurrences(of: "code=abc", with: "code="),
            base + "&iss=https%3A%2F%2Fevil.example",
            base + "&iss=https%3A%2F%2Faccounts.google.com&iss=https%3A%2F%2Faccounts.google.com",
            base + "&x=" + String(repeating: "y", count: 16_384),
        ]
        for text in rejected {
            #expect(throws: AntigravitySignInError.self, "\(text.prefix(120))") { try AntigravityCallback.validate(text, for: pending) }
        }
    }
}

/// A loopback-only HTTP server that answers one request with `status`.
private final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "coincide.tests.loopback")
    private let lock = NSLock()
    private var requests: [String] = []
    let status: Int

    init(status: Int) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.status = status
    }

    var received: [String] { lock.withLock { requests } }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, _, _ in
                let text = String(decoding: data ?? Data(), as: UTF8.self)
                lock.withLock { requests.append(text) }
                let body = "done"
                let response = "HTTP/1.1 \(status) X\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let ready = Calls()
        listener.stateUpdateHandler = { state in if case .ready = state { ready.add("ready") } }
        listener.start(queue: queue)
        for _ in 0..<200 where ready.all.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        return try #require(listener.port?.rawValue)
    }

    func stop() { listener.cancel() }
}

struct AntigravityCallbackForwardingTests {
    @Test func forwardsTheCallbackOnceToTheLoopbackListener() async throws {
        let server = try LoopbackServer(status: 200)
        defer { server.stop() }
        let port = try await server.start()
        let callback = try #require(URL(string: "http://127.0.0.1:\(port)/?state=s&code=4%2F0A"))
        try await AntigravityCallback.forward(callback)
        let request = try #require(server.received.first)
        #expect(request.hasPrefix("GET /?state=s&code=4%2F0A HTTP/1.1\r\n"))
        #expect(request.contains("Host: 127.0.0.1:\(port)\r\n"))
        #expect(server.received.count == 1)
    }

    @Test func failsWithoutA2xxAnswer() async throws {
        let server = try LoopbackServer(status: 500)
        defer { server.stop() }
        let port = try await server.start()
        await #expect(throws: AntigravitySignInError.self) {
            try await AntigravityCallback.forward(URL(string: "http://127.0.0.1:\(port)/?state=s&code=c")!)
        }
        // Nothing is listening once the agent is gone; that fails too.
        server.stop()
        await #expect(throws: AntigravitySignInError.self) {
            try await AntigravityCallback.forward(URL(string: "http://127.0.0.1:\(port)/?state=s&code=c")!, timeout: 3)
        }
        await #expect(throws: AntigravitySignInError.self) {
            try await AntigravityCallback.forward(URL(string: "http://example.com:\(port)/?state=s&code=c")!)
        }
    }
}

// MARK: - Sign-in flow

@MainActor
struct AntigravitySignInTests {
    private static let initialize = JSONValue.parse(
        #"{"protocolVersion":1,"agentInfo":{"name":"antigravity-acp","version":"1.3.0"},"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"resume":{}},"auth":{"logout":{}}},"authMethods":[{"id":"oauth-personal","name":"Log in with Google"}]}"#
    )!
    private static let session = JSONValue.parse(
        #"{"sessionId":"3f2b8c1e-9d4a-4b6f-8e2d-1c0a9b8f7e6d","configOptions":[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"gemini-pro","options":[{"value":"gemini-pro","name":"Gemini Pro"},{"value":"gemini-flash","name":"Gemini Flash"}]}]}"#
    )!
    private static let executable = URL(fileURLWithPath: "/usr/bin/true")
    private static let callback = "http://127.0.0.1:46353/?state=test-opaque-state&code=abc"

    private func make(
        _ agent: ACPFakeAgent, forward: @escaping @Sendable (URL) async throws -> Void = { _ in }, timeout: TimeInterval = 30,
        hint: TimeInterval = 30
    ) throws -> (AntigravitySignIn, AntigravityProfile) {
        let root = try acpTemporaryDirectory()
        let profile = AntigravityProfile(geminiHome: root.appendingPathComponent("profile"), userHome: root.appendingPathComponent("home"))
        agent.initializeResult = Self.initialize
        agent.sessionResult = Self.session
        let signIn = AntigravitySignIn(
            profile: profile, runtime: nil, transport: agent.factory, forward: forward, timeout: timeout, noResponseHint: hint)
        return (signIn, profile)
    }

    /// Plays the agent asking for Google sign-in; returns the pending `authenticate` request's id.
    private func pendingAuthentication(_ agent: ACPFakeAgent, stderr: Bool = true) -> () -> JSONValue? {
        var pending: JSONValue?
        agent.handlers["authenticate"] = { id, _ in
            pending = id
            if stderr {
                agent.transport.onStderr?("Starting...\n\(AntigravityProfile.browserMarker)\(AntigravityAuthorizationTests.link)\n")
            } else {
                agent.transport.deliver(AntigravityFlavor.signInPrefix + AntigravityAuthorizationTests.link)
            }
        }
        return { pending }
    }

    @Test func showsTheLinkAndSucceedsOnlyWhenTheAgentSignsIn() async throws {
        let agent = ACPFakeAgent()
        let forwarded = Calls()
        let (signIn, profile) = try make(agent, forward: { forwarded.add($0.absoluteString) })
        let pending = pendingAuthentication(agent)
        signIn.start(executable: Self.executable, environment: ["PATH": "/usr/bin", "GEMINI_API_KEY": "billing"])
        #expect(signIn.phase == .starting && signIn.isActive)
        await acpWaitUntil("the link") { signIn.phase == .waiting }
        #expect(signIn.authorization?.url.absoluteString == AntigravityAuthorizationTests.link)
        #expect(signIn.acceptsCallback)
        // The agent repeating the same link on stdout changes nothing.
        agent.transport.deliver(AntigravityFlavor.signInPrefix + AntigravityAuthorizationTests.link)
        await acpSettle()
        #expect(signIn.phase == .waiting)

        // An address for another sign-in is refused without being sent anywhere.
        await #expect(throws: AntigravitySignInError.self) {
            try await signIn.complete(callback: Self.callback.replacingOccurrences(of: "test-opaque-state", with: "other"))
        }
        #expect(forwarded.all.isEmpty)
        try await signIn.complete(callback: "  \(Self.callback)\n")
        #expect(forwarded.all == [Self.callback])
        #expect(signIn.phase == .verifying && !signIn.acceptsCallback)
        await #expect(throws: AntigravitySignInError.self) { try await signIn.complete(callback: Self.callback) }

        // Delivering the address is not success; the agent's answer is.
        agent.reply(try #require(pending()), [:])
        await acpWaitUntil("success") { signIn.phase == .succeeded }
        #expect(signIn.message == "Signed in with Google.")
        #expect(signIn.models.map(\.modelID) == ["antigravity-default", "gemini-pro", "gemini-flash"])
        #expect(AntigravityFlavor(profile: profile).offlineModels(environment: [:]).map(\.modelID) == signIn.models.map(\.modelID))
        #expect(agent.requests.map(\.method) == ["initialize", "authenticate", "session/new"])
        #expect(agent.requests("authenticate").first?["methodId"] == "oauth-personal")
        let environment = agent.transport.environment
        #expect(environment["GEMINI_HOME"] == profile.geminiHome.path && environment["GEMINI_API_KEY"] == nil)
        #expect(environment["BROWSER"] == profile.browserCommand)
        #expect(agent.transport.isTerminated)
        AntigravityFlavor.knownModels[profile.geminiHome.path] = nil
    }

    @Test func aSignInFinishedInTheLocalBrowserNeedsNoAddress() async throws {
        let agent = ACPFakeAgent()
        let (signIn, _) = try make(agent)
        let pending = pendingAuthentication(agent, stderr: false)
        signIn.start(executable: Self.executable, environment: [:])
        await acpWaitUntil("the link") { signIn.phase == .waiting }
        agent.reply(try #require(pending()), [:])
        await acpWaitUntil("success") { signIn.phase == .succeeded }
    }

    @Test func cancelStopsTheAgent() async throws {
        let agent = ACPFakeAgent()
        let (signIn, _) = try make(agent)
        _ = pendingAuthentication(agent)
        signIn.start(executable: Self.executable, environment: [:])
        await acpWaitUntil("the link") { signIn.phase == .waiting }
        signIn.cancel()
        #expect(signIn.phase == .cancelled && signIn.authorization == nil)
        #expect(agent.transport.isTerminated)
        await #expect(throws: AntigravitySignInError.self) { try await signIn.complete(callback: Self.callback) }
    }

    @Test func refusesASecondDifferentLink() async throws {
        let agent = ACPFakeAgent()
        let (signIn, _) = try make(agent)
        agent.handlers["authenticate"] = { _, _ in
            agent.transport.deliver(AntigravityFlavor.signInPrefix + AntigravityAuthorizationTests.link)
            agent.transport.deliver(
                AntigravityFlavor.signInPrefix + AntigravityAuthorizationTests.link.replacingOccurrences(of: "test-opaque-state", with: "second"))
        }
        signIn.start(executable: Self.executable, environment: [:])
        await acpWaitUntil("failure") { signIn.phase == .failed }
        #expect(signIn.message?.contains("more than one") == true)
    }

    @Test func failedDeliveryFailsTheSignIn() async throws {
        let agent = ACPFakeAgent()
        let (signIn, _) = try make(agent, forward: { _ in throw URLError(.cannotConnectToHost) })
        _ = pendingAuthentication(agent)
        signIn.start(executable: Self.executable, environment: [:])
        await acpWaitUntil("the link") { signIn.phase == .waiting }
        await #expect(throws: AntigravitySignInError.self) { try await signIn.complete(callback: Self.callback) }
        #expect(signIn.phase == .failed && signIn.message?.contains("deliver") == true)
        #expect(agent.transport.isTerminated)
    }

    @Test func explainsAnAgentThatCannotReachGoogleThenTimesOut() async throws {
        let agent = ACPFakeAgent()
        let (signIn, _) = try make(agent, timeout: 0.6, hint: 0.2)
        agent.handlers["authenticate"] = { _, _ in }
        signIn.start(executable: Self.executable, environment: [:])
        await acpWaitUntil("the network hint") { signIn.message?.contains("30 seconds") == true }
        #expect(signIn.phase == .starting)
        await acpWaitUntil("timeout") { signIn.phase == .failed }
        #expect(signIn.message?.contains("couldn’t reach Google") == true)

        // Once the link was shown, running out of time means the link expired.
        let shown = ACPFakeAgent()
        let (expiring, _) = try make(shown, timeout: 0.4, hint: 0.1)
        _ = pendingAuthentication(shown)
        expiring.start(executable: Self.executable, environment: [:])
        await acpWaitUntil("timeout") { expiring.phase == .failed }
        #expect(expiring.message?.contains("expired") == true)
    }

    @Test func reportsWhyGoogleSignInFailed() async throws {
        let cases: [(method: String, code: Int, message: String, expected: String)] = [
            ("authenticate", -32603, "SUBSCRIPTION_REQUIRED: no plan", "subscription"),
            ("authenticate", -32603, "access_denied by user", "wasn’t approved"),
            ("session/new", -32603, "boom", "couldn’t start a session"),
            ("authenticate", -32603, "secret internal detail", "Google sign-in failed"),
        ]
        for testCase in cases {
            let agent = ACPFakeAgent()
            let (signIn, _) = try make(agent)
            agent.handlers[testCase.method] = { id, _ in agent.fail(id, code: testCase.code, message: testCase.message) }
            signIn.start(executable: Self.executable, environment: [:])
            await acpWaitUntil("failure") { signIn.phase == .failed }
            #expect(signIn.message?.contains(testCase.expected) == true, "\(signIn.message ?? "")")
            #expect(signIn.message?.contains("secret") == false)
        }
    }

    @Test func signsOutWithTheAgentsOwnLogout() async throws {
        let agent = ACPFakeAgent()
        let (signIn, profile) = try make(agent)
        AntigravityFlavor.knownModels[profile.geminiHome.path] = [ModelOption(provider: .antigravity, modelID: "gemini-pro", displayName: "Pro")]
        try await signIn.signOut(executable: Self.executable, environment: [:])
        #expect(agent.requests.map(\.method) == ["initialize", "logout"])
        #expect(signIn.phase == .idle && signIn.message == "Signed out of Google.")
        #expect(AntigravityFlavor.knownModels[profile.geminiHome.path] == nil)

        // An agent that cannot sign out is never asked to.
        let old = ACPFakeAgent()
        let (outdated, _) = try make(old)
        old.initializeResult = ["protocolVersion": 1, "agentCapabilities": ["loadSession": true]]
        await #expect(throws: AntigravitySignInError.self) { try await outdated.signOut(executable: Self.executable, environment: [:]) }
        #expect(old.requests("logout").isEmpty)
        #expect(outdated.phase == .failed)
    }

    @Test func signingOutCancelsASignInInProgress() async throws {
        let agent = ACPFakeAgent()
        let (signIn, _) = try make(agent)
        _ = pendingAuthentication(agent)
        signIn.start(executable: Self.executable, environment: [:])
        await acpWaitUntil("the link") { signIn.phase == .waiting }
        let signInProcess = agent.transport
        try await signIn.signOut(executable: Self.executable, environment: [:])
        #expect(signInProcess.isTerminated)
        #expect(agent.requests("logout").count == 1)
    }

    @Test func checksTheReleaseIdentityLikeT3Code() throws {
        #expect(AntigravityValidation.isExpected(ACPInitializeResult(json: Self.initialize), version: "1.3.0"))
        #expect(!AntigravityValidation.isExpected(ACPInitializeResult(json: Self.initialize), version: "1.2.0"))
        for (key, replacement) in [
            (#""name":"antigravity-acp""#, #""name":"other""#), (#""auth":{"logout":{}}"#, #""auth":{}"#),
            (#""loadSession":true"#, #""loadSession":false"#), (#""resume":{}"#, #""resume":null"#),
            (#""id":"oauth-personal""#, #""id":"gemini-api-key""#), (#""protocolVersion":1"#, #""protocolVersion":3"#),
        ] {
            let text = Self.initialize.compactJSON.replacingOccurrences(of: key, with: replacement)
            #expect(!AntigravityValidation.isExpected(ACPInitializeResult(json: JSONValue.parse(text)!), version: "1.3.0"), "\(replacement)")
        }
    }
}
