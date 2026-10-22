import CryptoKit
import Darwin
import Foundation
import Testing
import zlib
@testable import CoincideCore

@Suite struct CodexArchiveExtractorTests {
    @Test func canonicalPAXPackagePreservesCompleteResourceLicenseAndHelperTrees() async throws {
        let fixture = try CodexTarFixture(); defer { fixture.remove() }
        let members = CodexTarFixture.members
        let release = try fixture.prepare(CodexTarFixture.gzip(CodexTarFixture.tar(members), filename: "codex-package-aarch64-apple-darwin.tar"))
        try await CodexArchiveExtractor.extract(release: release, archive: fixture.archive, to: fixture.output)
        for member in members where member.kind == 48 {
            let file = fixture.output.appendingPathComponent(member.name)
            #expect(try Data(contentsOf: file) == member.body)
            var node = stat(); #expect(lstat(file.path, &node) == 0)
            #expect(node.st_mode & 0o777 == mode_t(member.mode))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.output.appendingPathComponent("@PaxHeader").path))
        let observedFiles = try fixture.files()
        let expectedFiles = Set(members.filter { $0.kind == 48 }.map(\.name))
        #expect(observedFiles == expectedFiles)
        #expect(CodexArchiveExtractor.maximumExpandedBytes == 8 * 1_024 * 1_024 * 1_024)
    }

    @Test func PAXPathAndSizeOverridesAreValidatedAndAppliedBeforeOpeningMembers() async throws {
        let fixture = try CodexTarFixture(); defer { fixture.remove() }
        let path = "codex-resources/" + String(repeating: "long-segment", count: 10) + "/payload"
        let body = Data("long path resource".utf8)
        let member = CodexTarFixtureMember(name: "placeholder", body: body, size: 0, pax: [("mtime", "1790130066.2622466"), ("path", path), ("size", String(body.count))])
        let release = try fixture.prepare(CodexTarFixture.gzip(CodexTarFixture.tar([member])))
        try await CodexArchiveExtractor.extract(release: release, archive: fixture.archive, to: fixture.output)
        #expect(try Data(contentsOf: fixture.output.appendingPathComponent(path)) == body)
        #expect(!FileManager.default.fileExists(atPath: fixture.output.appendingPathComponent("placeholder").path))
    }

    @Test func unsafePathsLinksDuplicatesAndAncestorConflictsFailBeforeAnyOutput() async throws {
        for kind in ["traversal", "absolute", "backslash", "colon", "empty-component", "dot", "symlink", "hardlink", "device", "duplicate", "case-alias", "parent-file", "child-before-file", "special-mode"] {
            let fixture = try CodexTarFixture(); defer { fixture.remove() }
            var members = [CodexTarFixtureMember(name: "bin/codex", body: Data([1]))]
            switch kind {
            case "traversal": members[0].name = "../outside"
            case "absolute": members[0].name = "/outside"
            case "backslash": members[0].name = "bin\\outside"
            case "colon": members[0].name = "C:outside"
            case "empty-component": members[0].name = "bin//outside"
            case "dot": members[0].name = "bin/./outside"
            case "symlink": members[0].kind = 50; members[0].link = "outside"
            case "hardlink": members[0].kind = 49; members[0].link = "outside"
            case "device": members[0].kind = 51
            case "duplicate": members.append(members[0])
            case "case-alias": members.append(.init(name: "BIN/codex", body: Data([2])))
            case "parent-file": members = [.init(name: "bin", body: Data([1])), members[0]]
            case "child-before-file": members.append(.init(name: "bin", body: Data([1])))
            default: members[0].mode = 0o4755
            }
            let release = try fixture.prepare(CodexTarFixture.gzip(CodexTarFixture.tar(members)))
            await #expect(throws: CodexArchiveError.archiveInvalid) {
                try await CodexArchiveExtractor.extract(release: release, archive: fixture.archive, to: fixture.output)
            }
            #expect(try fixture.files().isEmpty, "Rejected TAR case: \(kind)")
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).isEmpty)
            #expect(try Data(contentsOf: fixture.sentinel) == Data("retain".utf8))
        }
    }

    @Test func PAXTraversalSparseUnknownDuplicateMalformedAndDanglingMetadataAreRejected() async throws {
        for kind in ["path", "size", "sparse", "duplicate", "malformed", "dangling", "oversized"] {
            let fixture = try CodexTarFixture(); defer { fixture.remove() }
            var member = CodexTarFixtureMember(name: "bin/codex", body: Data([1]))
            switch kind {
            case "path": member.pax = [("path", "../outside")]
            case "size": member.pax = [("size", String(CodexArchiveExtractor.maximumMemberBytes + 1))]
            case "sparse": member.pax = [("GNU.sparse.map", "0,1")]
            case "duplicate": member.pax = [("mtime", "1.1"), ("mtime", "2.2")]
            case "malformed": member.paxRaw = Data("999 mtime=1.1\n".utf8)
            case "dangling": member = .init(name: "././@PaxHeader", body: CodexTarFixture.pax([("mtime", "1.1")]), kind: 120)
            default: member.paxRaw = Data(repeating: 65, count: 65_537)
            }
            let release = try fixture.prepare(CodexTarFixture.gzip(CodexTarFixture.tar([member])))
            await #expect(throws: CodexArchiveError.archiveInvalid) {
                try await CodexArchiveExtractor.extract(release: release, archive: fixture.archive, to: fixture.output)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).isEmpty)
        }
    }

    @Test func gzipCRCSizeTrailerConcatenationAndTARChecksumOrEndCorruptionAreRejected() async throws {
        for kind in ["crc", "isize", "truncated-gzip", "trailing-gzip", "concatenated-gzip", "tar-checksum", "tar-end", "tar-after-end"] {
            let fixture = try CodexTarFixture(); defer { fixture.remove() }
            var tar = CodexTarFixture.tar([.init(name: "bin/codex", body: Data([1]))], recordPadding: false)
            if kind == "tar-checksum" { tar[0] ^= 1 }
            if kind == "tar-end" { tar.removeLast(512) }
            if kind == "tar-after-end" { tar.append(Data(repeating: 65, count: 512)) }
            var bytes = try CodexTarFixture.gzip(tar)
            switch kind {
            case "crc": bytes[bytes.count - 8] ^= 1
            case "isize": bytes[bytes.count - 4] ^= 1
            case "truncated-gzip": bytes.removeLast(5)
            case "trailing-gzip": bytes.append(0)
            case "concatenated-gzip": bytes.append(try CodexTarFixture.gzip(Data()))
            default: break
            }
            let release = try fixture.prepare(bytes)
            await #expect(throws: CodexArchiveError.archiveInvalid) {
                try await CodexArchiveExtractor.extract(release: release, archive: fixture.archive, to: fixture.output)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).isEmpty, "Invalid framing: \(kind)")
        }
    }

    @Test func declaredHugeMembersAndExcessInventoryAreBoundedBeforeOutput() async throws {
        for countLimit in [false, true] {
            let fixture = try CodexTarFixture(); defer { fixture.remove() }
            let members: [CodexTarFixtureMember]
            if countLimit { members = (0...CodexArchiveExtractor.maximumEntries).map { .init(name: "file-\($0)", body: Data(), pax: []) } }
            else { members = [.init(name: "huge", body: Data(), size: CodexArchiveExtractor.maximumMemberBytes + 1, pax: [])] }
            let release = try fixture.prepare(CodexTarFixture.gzip(CodexTarFixture.tar(members)))
            await #expect(throws: CodexArchiveError.archiveInvalid) {
                try await CodexArchiveExtractor.extract(release: release, archive: fixture.archive, to: fixture.output)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).isEmpty)
        }
    }

    @Test func archiveHashAndOwnedDestinationChecksPreserveExistingFiles() async throws {
        for kind in ["hash", "nonempty", "symlink"] {
            let fixture = try CodexTarFixture(); defer { fixture.remove() }
            let bytes = try CodexTarFixture.gzip(CodexTarFixture.tar(CodexTarFixture.members))
            let release = try fixture.prepare(bytes)
            if kind == "hash" { var changed = bytes; changed[0] ^= 1; try changed.write(to: fixture.archive) }
            else if kind == "nonempty" { try Data("existing".utf8).write(to: fixture.output.appendingPathComponent("existing")) }
            else { try FileManager.default.removeItem(at: fixture.output); try FileManager.default.createSymbolicLink(at: fixture.output, withDestinationURL: fixture.root) }
            await #expect(throws: kind == "hash" ? CodexArchiveError.checksumMismatch : .invalidDestination) {
                try await CodexArchiveExtractor.extract(release: release, archive: fixture.archive, to: fixture.output)
            }
            #expect(try Data(contentsOf: fixture.sentinel) == Data("retain".utf8))
            if kind == "nonempty" { #expect(try Data(contentsOf: fixture.output.appendingPathComponent("existing")) == Data("existing".utf8)) }
        }
    }

    @Test func cancellationDuringOwnedExtractionDrainsWorkerAndRemovesOnlyItsTree() async throws {
        let fixture = try CodexTarFixture(); defer { fixture.remove() }
        let member = CodexTarFixtureMember(name: "bin/codex", body: Data(repeating: 65, count: 32 * 1_024 * 1_024))
        let release = try fixture.prepare(CodexTarFixture.gzip(CodexTarFixture.tar([member])))
        let work = Task { try await CodexArchiveExtractor.extract(release: release, archive: fixture.archive, to: fixture.output) }
        let first = fixture.output.appendingPathComponent(member.name)
        var observed = false
        for _ in 0..<3_000 {
            var node = stat()
            if lstat(first.path, &node) == 0, node.st_size > 0, node.st_size < Int64(member.body.count) { observed = true; break }
            try await Task.sleep(for: .milliseconds(1))
        }
        work.cancel()
        if observed { await #expect(throws: CodexArchiveError.cancelled) { try await work.value } }
        else { _ = try? await work.value; Issue.record("No partial synthetic Codex member was observed.") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).isEmpty)
        #expect(try Data(contentsOf: fixture.sentinel) == Data("retain".utf8))
    }
}

private struct CodexTarFixtureMember {
    var name: String
    var body: Data
    var kind: UInt8 = 48
    var mode: Int64 = 0o644
    var size: Int64?
    var pax: [(String, String)] = [("mtime", "1790130066.2622466")]
    var paxRaw: Data?
    var link = ""
}
private struct CodexTarFixture {
    let root: URL
    var archive: URL { root.appendingPathComponent("release.tar.gz") }
    var output: URL { root.appendingPathComponent("runtime", isDirectory: true) }
    var sentinel: URL { root.appendingPathComponent("sentinel") }
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("coincide-codex-tar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("retain".utf8).write(to: sentinel)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func files() throws -> Set<String> {
        let enumerator = try #require(FileManager.default.enumerator(at: output, includingPropertiesForKeys: [.isRegularFileKey]))
        let parent = output.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var result = Set<String>()
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let child = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                guard child.count > parent.count, child.starts(with: parent) else { throw CodexTarFixtureError.inventoryLocation }
                result.insert(child.dropFirst(parent.count).joined(separator: "/"))
            }
        }
        return result
    }
    func prepare(_ bytes: Data) throws -> CodexManagedRelease {
        try bytes.write(to: archive)
        return try .init(version: "0.156.1", target: "aarch64-apple-darwin",
                         url: URL(string: "https://github.com/openai/codex/releases/download/rust-v0.156.1/codex-package-aarch64-apple-darwin.tar.gz")!,
                         archiveBytes: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
    static var members: [CodexTarFixtureMember] {
        [.init(name: "bin/", body: Data(), kind: 53, mode: 0o755),
         .init(name: "bin/codex", body: Data("synthetic codex".utf8), mode: 0o755),
         .init(name: "bin/codex-code-mode-host", body: Data("synthetic host".utf8), mode: 0o755),
         .init(name: "codex-package.json", body: Data("{\"layoutVersion\":1,\"version\":\"0.156.1\",\"target\":\"aarch64-apple-darwin\",\"variant\":\"codex\",\"entrypoint\":\"bin/codex\",\"resourcesDir\":\"codex-resources\",\"pathDir\":\"codex-path\"}".utf8)),
         .init(name: "codex-path/rg", body: Data("synthetic rg".utf8), mode: 0o755),
         .init(name: "codex-resources/voice/bin/codex-voice-host", body: Data("synthetic voice".utf8), mode: 0o755),
         .init(name: "codex-resources/voice/lib/libfixture.dylib", body: Data("synthetic dylib".utf8), mode: 0o755),
         .init(name: "codex-resources/voice/licenses/LGPL-2.1.txt", body: Data("synthetic license".utf8)),
         .init(name: "codex-resources/zsh/bin/zsh", body: Data("synthetic zsh".utf8), mode: 0o755)]
    }
    static func pax(_ values: [(String, String)]) -> Data {
        var result = Data()
        for (key, value) in values {
            let body = " \(key)=\(value)\n"; var length = body.utf8.count + 1
            while String(length).utf8.count + body.utf8.count != length { length = String(length).utf8.count + body.utf8.count }
            result.append(Data((String(length) + body).utf8))
        }; return result
    }
    static func tar(_ members: [CodexTarFixtureMember], recordPadding: Bool = true) -> Data {
        var result = Data()
        func append(_ member: CodexTarFixtureMember) {
            result.append(header(member)); result.append(member.body)
            result.append(Data(repeating: 0, count: (512 - member.body.count % 512) % 512))
        }
        for member in members {
            if let metadata = member.paxRaw ?? (member.pax.isEmpty ? nil : pax(member.pax)), member.kind != 120 {
                append(.init(name: "././@PaxHeader", body: metadata, kind: 120, mode: 0, pax: []))
            }
            append(member)
        }
        result.append(Data(repeating: 0, count: 1_024))
        if recordPadding { result.append(Data(repeating: 0, count: (10_240 - result.count % 10_240) % 10_240)) }
        return result
    }
    static func header(_ member: CodexTarFixtureMember) -> Data {
        var bytes = Data(repeating: 0, count: 512)
        func text(_ string: String, _ start: Int, _ length: Int) { let value = Data(string.utf8.prefix(length)); bytes.replaceSubrange(start..<start + value.count, with: value) }
        func number(_ value: Int64, _ start: Int, _ length: Int) { let raw = String(value, radix: 8); text(String(repeating: "0", count: max(0, length - raw.count - 1)) + raw, start, length - 1) }
        text(member.name, 0, 100); number(member.mode, 100, 8); number(0, 108, 8); number(0, 116, 8)
        number(member.size ?? Int64(member.body.count), 124, 12); number(1_790_130_066, 136, 12)
        bytes.replaceSubrange(148..<156, with: Data(repeating: 32, count: 8)); bytes[156] = member.kind
        text(member.link, 157, 100); text("ustar", 257, 6); text("00", 263, 2)
        let checksum = bytes.reduce(0) { $0 + Int64($1) }; number(checksum, 148, 7); bytes[155] = 32
        return bytes
    }
    static func gzip(_ data: Data, filename: String? = nil) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw CodexTarFixtureError.compression }
        defer { deflateEnd(&stream) }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress); stream.avail_in = uInt(input.count)
            var status: Int32
            repeat {
                status = buffer.withUnsafeMutableBytes { target in
                    stream.next_out = target.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(target.count)
                    return zlib.deflate(&stream, Z_FINISH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw CodexTarFixtureError.compression }
                result.append(contentsOf: buffer.prefix(buffer.count - Int(stream.avail_out)))
            } while status != Z_STREAM_END
        }
        if let filename { result[3] |= 8; result.insert(contentsOf: Data((filename + "\0").utf8), at: 10) }
        return result
    }
}
private enum CodexTarFixtureError: Error { case compression, inventoryLocation }
