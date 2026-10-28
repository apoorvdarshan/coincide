import CryptoKit
import Foundation
import Testing
import zlib
@testable import CoincideKit

struct AppUpdateTests {
    @Test func versionsRejectAmbiguityAndCompareNumerically() {
        #expect(UpdateVersion("1.10.0")! > UpdateVersion("1.9.99")!)
        for text in ["1.0", "v1.0.0", "01.0.0", "1.-1.0", "1.0.0-beta", "1.0.0/evil", "١.0.0", "999999999999999999999.0.0"] {
            #expect(UpdateVersion(text) == nil)
        }
    }

    @Test func releaseRequiresTrustedURLDigestArchitectureAndNewerStableVersion() throws {
        let valid = metadata()
        let release = try #require(try AppUpdateRelease.parse(valid, newerThan: "0.1.0", architecture: "arm64"))
        #expect(release.version == "0.2.0" && release.sha256.count == 64)
        #expect(try AppUpdateRelease.parse(valid, newerThan: "0.2.0") == nil)
        #expect(try AppUpdateRelease.parse(valid, newerThan: "1.0.0") == nil)
        for changes: [String: Any] in [["draft": true], ["prerelease": true], ["tag_name": "v0.2.0-rc1"]] {
            #expect(throws: AppUpdateError.self) { try AppUpdateRelease.parse(metadata(changes), newerThan: "0.1.0") }
        }
        for asset: [String: Any] in [["digest": ""], ["size": -1], ["size": Int64.max], ["name": "Coincide-macos-x86_64.zip"],
                                   ["browser_download_url": "https://evil.example/Coincide.zip"],
                                   ["browser_download_url": "https://github.com/other/repo/releases/download/v0.2.0/Coincide-macos-universal.zip"]] {
            #expect(throws: AppUpdateError.self) { try AppUpdateRelease.parse(metadata(asset: asset), newerThan: "0.1.0", architecture: "arm64") }
        }
    }

    @Test func extractsFilesAndSafeFrameworkLinksAndRejectsArchiveAttacks() throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("release.zip")
        try zip([("Coincide.app/Contents/Frameworks/A.framework/Versions/A/A", Data("binary".utf8), 0o100755),
                 ("Coincide.app/Contents/Frameworks/A.framework/Versions/Current", Data("A".utf8), 0o120777),
                 ("Coincide.app/Contents/Frameworks/A.framework/A", Data("Versions/Current/A".utf8), 0o120777)]).write(to: archive)
        let expanded = directory.appendingPathComponent("good")
        try UpdateArchive.extract(archive, to: expanded)
        #expect(try String(contentsOf: expanded.appendingPathComponent("Coincide.app/Contents/Frameworks/A.framework/A"), encoding: .utf8) == "binary")
        let attacks: [[(String, Data, UInt32)]] = [
            [("../escaped", Data(), 0o100644)], [("/escaped", Data(), 0o100644)], [("Coincide.app/../escaped", Data(), 0o100644)],
            [("Coincide.app/a\\b", Data(), 0o100644)], [("Coincide.app/a:b", Data(), 0o100644)],
            [("Coincide.app/a", Data(), 0o100644), ("Coincide.app/A", Data(), 0o100644)],
            [("Coincide.app/link", Data("/tmp".utf8), 0o120777)], [("Coincide.app/link", Data("..".utf8), 0o120777)],
            [("Coincide.app/link", Data(".".utf8), 0o120777), ("Coincide.app/link/file", Data(), 0o100644)],
            [("Coincide.app/a", Data("b".utf8), 0o120777), ("Coincide.app/b", Data("a".utf8), 0o120777)],
            [("Coincide.app/b", Data(".".utf8), 0o120777), ("Coincide.app/a", Data("b/..".utf8), 0o120777)],
            [("Coincide.app/B", Data(".".utf8), 0o120777), ("Coincide.app/a", Data("b/..".utf8), 0o120777)],
            [("Coincide.app/pipe", Data(), 0o010644)], [("Other.app/file", Data(), 0o100644)]
        ]
        for (index, entries) in attacks.enumerated() {
            try zip(entries).write(to: archive)
            #expect(throws: AppUpdateError.self) { try UpdateArchive.extract(archive, to: directory.appendingPathComponent("bad\(index)")) }
        }
        // Mutate each byte of the metadata fixture; malformed headers must throw, never index outside the input.
        let seed = zip([("Coincide.app/file", Data("payload".utf8), 0o100644)])
        for index in seed.indices {
            var bytes = seed; bytes[index] ^= 0xff
            try bytes.write(to: archive)
            let output = directory.appendingPathComponent("mutation\(index)")
            try? UpdateArchive.extract(archive, to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("escaped").path))
    }

    @Test func integrityChecksRejectChangedArchivesAndAdHocBuilds() throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("release.zip")
        let bytes = Data("archive".utf8); try bytes.write(to: archive)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let release = try #require(try AppUpdateRelease.parse(metadata(asset: ["digest": "sha256:" + digest, "size": bytes.count]), newerThan: "0.1.0"))
        try AppUpdateStaging.checkArchive(archive, release: release)
        try Data("changed".utf8).write(to: archive)
        #expect(throws: AppUpdateError.self) { try AppUpdateStaging.checkArchive(archive, release: release) }
        let adhoc = directory.appendingPathComponent("adhoc")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: adhoc)
        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", adhoc.path]
        signer.standardError = FileHandle.nullDevice
        try signer.run(); signer.waitUntilExit()
        #expect(signer.terminationStatus == 0)
        #expect(throws: AppUpdateError.self) { try AppUpdateSecurity.signingTeam(at: adhoc) }
        #expect(throws: AppUpdateError.self) { try AppUpdateSecurity.validateSignature(at: directory, team: "bad\"team", identifier: nil) }
    }

    @Test func atomicInstallKeepsBackupAndRollsBackFailedPostSwapVerification() throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("Coincide.app"), candidate = directory.appendingPathComponent("New.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: target.appendingPathComponent("version"))
        try Data("new".utf8).write(to: candidate.appendingPathComponent("version"))
        #expect(throws: AppUpdateError.self) { try AppUpdateInstallation.exchange(candidate: candidate, target: target, isRunning: { true }, verify: { _ in }) }
        #expect(throws: AppUpdateError.self) {
            try AppUpdateInstallation.exchange(candidate: candidate, target: target, isRunning: { false }) { url in
                if url == target { throw AppUpdateError.verification }
            }
        }
        #expect(try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8) == "old")
        let backup = try AppUpdateInstallation.exchange(candidate: candidate, target: target, isRunning: { false }, verify: { _ in })
        #expect(try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: backup.appendingPathComponent("version"), encoding: .utf8) == "old")
    }

    @Test func processObserverAcceptsOnlyCleanExit() throws {
        for command in ["read line; exit 0", "read line; exit 7", "read line; kill -TERM $$"] {
            let process = Process(), input = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.standardInput = input
            try process.run()
            let observe = {
                try AppUpdateInstallation.observeCleanExit(processID: process.processIdentifier, timeoutSeconds: 5) {
                    input.fileHandleForWriting.write(Data("quit\n".utf8))
                }
            }
            if command.hasSuffix("exit 0") { try observe() }
            else { #expect(throws: AppUpdateError.self) { try observe() } }
            process.waitUntilExit()
        }
        #expect(throws: AppUpdateError.self) { try AppUpdateInstallation.waitForCleanExit(processID: 0, ready: {}) }
    }

    @Test func readsDeflatedArchivesProducedByMacOSTools() throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Coincide.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        let body = String(repeating: "app resources ", count: 500)
        try Data(body.utf8).write(to: app.appendingPathComponent("resource.txt"))
        let archive = directory.appendingPathComponent("deflated.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", app.path, archive.path]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let output = directory.appendingPathComponent("expanded")
        try UpdateArchive.extract(archive, to: output)
        #expect(try String(contentsOf: output.appendingPathComponent("Coincide.app/resource.txt"), encoding: .utf8) == body)
    }

    private func temporary() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-update-tests-\(UUID())")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func metadata(_ changes: [String: Any] = [:], asset changesToAsset: [String: Any] = [:]) -> Data {
        var asset: [String: Any] = ["name": "Coincide-macos-universal.zip", "size": 10, "digest": "sha256:" + String(repeating: "a", count: 64),
                                  "browser_download_url": "https://github.com/apoorvdarshan/coincide/releases/download/v0.2.0/Coincide-macos-universal.zip"]
        asset.merge(changesToAsset) { _, new in new }
        var release: [String: Any] = ["tag_name": "v0.2.0", "draft": false, "prerelease": false, "assets": [asset]]
        release.merge(changes) { _, new in new }
        return try! JSONSerialization.data(withJSONObject: release)
    }
    private func zip(_ entries: [(String, Data, UInt32)]) -> Data {
        var data = Data(), central = Data()
        func integer(_ value: UInt32, bytes: Int, into data: inout Data) { for shift in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (8 * shift))) } }
        for (name, payload, mode) in entries {
            let filename = Data(name.utf8), offset = UInt32(data.count), size = UInt32(payload.count)
            let crc = payload.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(payload.count))) }
            for (v, n): (UInt32, Int) in [(0x04034b50,4),(20,2),(0,2),(0,2),(0,2),(0,2),(crc,4),(size,4),(size,4),(UInt32(filename.count),2),(0,2)] { integer(v, bytes: n, into: &data) }
            data.append(filename); data.append(payload)
            for (v, n): (UInt32, Int) in [(0x02014b50,4),(0x0314,2),(20,2),(0,2),(0,2),(0,2),(0,2),(crc,4),(size,4),(size,4),(UInt32(filename.count),2),(0,2),(0,2),(0,2),(0,2),(mode << 16,4),(offset,4)] { integer(v, bytes: n, into: &central) }
            central.append(filename)
        }
        let start = UInt32(data.count); data.append(central)
        for (v, n): (UInt32, Int) in [(0x06054b50,4),(0,2),(0,2),(UInt32(entries.count),2),(UInt32(entries.count),2),(UInt32(central.count),4),(start,4),(0,2)] { integer(v, bytes: n, into: &data) }
        return data
    }
}
