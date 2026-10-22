import CryptoKit
import Darwin
import Foundation
import Testing
import zlib
@testable import CoincideCore

@Suite struct AntigravityArchiveExtractorTests {
    @Test func storedAndRawDeflateMembersMatchPinnedBytesAndExecutableModes() async throws {
        for method in [UInt16(0), 8] {
            let fixture = try AntigravityZIPFixture(); defer { fixture.remove() }
            var members = AntigravityZIPFixture.members
            for index in members.indices { members[index].method = method }
            let bytes = try AntigravityZIPFixture.zip(members)
            let release = try fixture.prepare(bytes)
            try await AntigravityArchiveExtractor.extract(release: release, archive: fixture.archive, to: fixture.output)
            for member in members {
                let file = fixture.output.appendingPathComponent(member.name)
                #expect(try Data(contentsOf: file) == member.body)
                var node = stat(); #expect(lstat(file.path, &node) == 0)
                #expect(node.st_mode & 0o777 == 0o755 && node.st_mode & S_IFMT == S_IFREG)
            }
            #expect(try fixture.outputNames() == Set(members.map(\.name)))
        }
    }

    @Test func ZIP64AndAllOptionalDescriptorSignaturesAreAcceptedPrecisely() async throws {
        for zip64 in [false, true] {
            for signature in [false, true] {
                let fixture = try AntigravityZIPFixture(); defer { fixture.remove() }
                var members = AntigravityZIPFixture.members
                for index in members.indices { members[index].method = 8; members[index].descriptor = true; members[index].signature = signature }
                let bytes = try AntigravityZIPFixture.zip(members, zip64: zip64)
                let release = try fixture.prepare(bytes)
                try await AntigravityArchiveExtractor.extract(release: release, archive: fixture.archive, to: fixture.output)
                #expect(try Data(contentsOf: fixture.output.appendingPathComponent(members[0].name)) == members[0].body)
                #expect(try fixture.outputNames() == Set(members.map(\.name)))
            }
        }
    }

    @Test func rawDeflateChunkBoundaryCanDrainOutputOrRequestMoreInputWithoutLosingBytes() async throws {
        for bufferedOutput in [false, true] {
            let fixture = try AntigravityZIPFixture(); defer { fixture.remove() }
            var members = AntigravityZIPFixture.members
            members[0] = AntigravityZIPFixture.boundaryMember(bufferedOutput: bufferedOutput)
            let release = try fixture.prepare(AntigravityZIPFixture.zip(members), serverBytes: Int64(members[0].body.count))
            try await AntigravityArchiveExtractor.extract(release: release, archive: fixture.archive, to: fixture.output)
            #expect(try Data(contentsOf: fixture.output.appendingPathComponent(members[0].name)) == members[0].body)
            #expect(try Data(contentsOf: fixture.output.appendingPathComponent(members[1].name)) == members[1].body)
        }
    }

    @Test func rawDeflateTruncatedAtAnEmptyInputBoundaryStillFailsAndCleansItsOutput() async throws {
        for bufferedOutput in [false, true] {
            let fixture = try AntigravityZIPFixture(); defer { fixture.remove() }
            var members = AntigravityZIPFixture.members
            members[0] = AntigravityZIPFixture.boundaryMember(bufferedOutput: bufferedOutput)
            let compressed = try #require(members[0].compressed)
            members[0].compressed = Data(compressed.prefix(65_536))
            let release = try fixture.prepare(AntigravityZIPFixture.zip(members), serverBytes: Int64(members[0].body.count))
            await #expect(throws: AntigravityArchiveError.archiveInvalid) {
                try await AntigravityArchiveExtractor.extract(release: release, archive: fixture.archive, to: fixture.output)
            }
            #expect(try fixture.outputNames().isEmpty)
        }
    }

    @Test func extraDuplicateTraversalAndNonregularMembersAreRejectedBeforeWrites() async throws {
        for kind in ["extra", "duplicate", "traversal", "absolute", "backslash", "symlink", "directory", "encrypted", "method"] {
            let fixture = try AntigravityZIPFixture(); defer { fixture.remove() }
            var members = AntigravityZIPFixture.members
            switch kind {
            case "extra": members.append(.init(name: "unexpected", body: Data([1])))
            case "duplicate": members[1].name = members[0].name
            case "traversal": members[0].name = "../" + members[0].name
            case "absolute": members[0].name = "/" + members[0].name
            case "backslash": members[0].name = "..\\" + members[0].name
            case "symlink": members[0].attributes = UInt32(0o120777) << 16
            case "directory": members[0].attributes = UInt32(0o040755) << 16 | 0x10
            case "encrypted": members[0].flags |= 1
            default: members[0].method = 12
            }
            let release = try fixture.prepare(AntigravityZIPFixture.zip(members))
            await #expect(throws: AntigravityArchiveError.archiveInvalid) {
                try await AntigravityArchiveExtractor.extract(release: release, archive: fixture.archive, to: fixture.output)
            }
            #expect(try fixture.outputNames().isEmpty, "Unsafe member kind: \(kind)")
            #expect(try Data(contentsOf: fixture.sentinel) == Data("retain".utf8))
        }
    }

    @Test func localCentralAndDescriptorDisagreementCannotBeIgnored() async throws {
        for kind in ["local-name", "local-crc", "local-size", "descriptor", "overlap", "gap", "truncated", "extra-central"] {
            let fixture = try AntigravityZIPFixture(); defer { fixture.remove() }
            var members = AntigravityZIPFixture.members
            switch kind {
            case "local-name": members[0].localName = String(repeating: "x", count: members[0].name.utf8.count)
            case "local-crc": members[0].localCRC = 42
            case "local-size": members[0].localSize = 42
            case "descriptor": members[0].descriptor = true; members[0].descriptorCRC = 42
            case "overlap": members[1].offsetOverride = 0
            case "gap": members[0].padding = Data([0])
            default: break
            }
            var bytes = try AntigravityZIPFixture.zip(members)
            if kind == "truncated" { bytes.removeLast() }
            if kind == "extra-central" { bytes.insert(0, at: bytes.count - 22) }
            let release = try fixture.prepare(bytes)
            await #expect(throws: AntigravityArchiveError.archiveInvalid) {
                try await AntigravityArchiveExtractor.extract(release: release, archive: fixture.archive, to: fixture.output)
            }
            #expect(try fixture.outputNames().isEmpty, "Conflicting metadata: \(kind)")
        }
    }

    @Test func truncatedOversizedAndTrailingDeflatePayloadsFailAndRemoveEarlierMember() async throws {
        for kind in ["crc", "truncated-deflate", "trailing-deflate", "decoded-overflow", "wrong-pinned-size"] {
            let fixture = try AntigravityZIPFixture(); defer { fixture.remove() }
            var members = AntigravityZIPFixture.members
            members[1].method = 8
            switch kind {
            case "crc": members[1].crc = 42
            case "truncated-deflate": members[1].compressed = Data([0x03])
            case "trailing-deflate": members[1].compressed = try AntigravityZIPFixture.deflate(members[1].body) + Data([0])
            case "decoded-overflow": members[1].compressed = try AntigravityZIPFixture.deflate(Data(repeating: 65, count: 512 * 1_024))
            default: break
            }
            let bytes = try AntigravityZIPFixture.zip(members)
            let release = try fixture.prepare(bytes, harnessBytes: kind == "wrong-pinned-size" ? 1 : nil)
            await #expect(throws: AntigravityArchiveError.archiveInvalid) {
                try await AntigravityArchiveExtractor.extract(release: release, archive: fixture.archive, to: fixture.output)
            }
            #expect(try fixture.outputNames().isEmpty, "Invalid payload: \(kind)")
            #expect(try Data(contentsOf: fixture.sentinel) == Data("retain".utf8))
        }
    }

    @Test func malformedZIP64MetadataIsBoundedAndRejected() async throws {
        for kind in ["missing-extra", "extra-garbage", "huge-record", "disk", "descriptor-width"] {
            let fixture = try AntigravityZIPFixture(); defer { fixture.remove() }
            var members = AntigravityZIPFixture.members
            for index in members.indices { members[index].descriptor = true }
            var bytes = try AntigravityZIPFixture.zip(members, zip64: true)
            // EOCD22 + locator20 + ZIP64EOCD56 follow the central directory.
            let record = bytes.count - 22 - 20 - 56
            switch kind {
            case "huge-record": bytes.zipSet64(4_097, at: record + 4)
            case "disk": bytes.zipSet32(1, at: record + 16)
            case "missing-extra": bytes.zipSet16(0x0002, at: 30 + members[0].name.utf8.count)
            case "extra-garbage": bytes.zipSet16(17, at: 30 + members[0].name.utf8.count + 2)
            default:
                // A ZIP64 descriptor cannot silently fall back to 32-bit sizes.
                let descriptor = 30 + members[0].name.utf8.count + 20 + members[0].body.count
                bytes.zipSet64(0, at: descriptor + 8)
            }
            let release = try fixture.prepare(bytes)
            await #expect(throws: AntigravityArchiveError.archiveInvalid) {
                try await AntigravityArchiveExtractor.extract(release: release, archive: fixture.archive, to: fixture.output)
            }
            #expect(try fixture.outputNames().isEmpty, "Invalid ZIP64: \(kind)")
        }
    }

    @Test func checksumLengthAndArchiveSymlinkAreVerifiedBeforeExtraction() async throws {
        for kind in ["checksum", "length", "symlink"] {
            let fixture = try AntigravityZIPFixture(); defer { fixture.remove() }
            let bytes = try AntigravityZIPFixture.zip(AntigravityZIPFixture.members)
            let release = try fixture.prepare(bytes)
            if kind == "checksum" { var changed = bytes; changed[0] ^= 1; try changed.write(to: fixture.archive) }
            else if kind == "length" { try (bytes + Data([0])).write(to: fixture.archive) }
            else {
                let target = fixture.root.appendingPathComponent("archive-original")
                try FileManager.default.moveItem(at: fixture.archive, to: target)
                try FileManager.default.createSymbolicLink(at: fixture.archive, withDestinationURL: target)
            }
            await #expect(throws: kind == "checksum" ? AntigravityArchiveError.checksumMismatch : .archiveInvalid) {
                try await AntigravityArchiveExtractor.extract(release: release, archive: fixture.archive, to: fixture.output)
            }
            #expect(try fixture.outputNames().isEmpty)
        }
    }

    @Test func nonemptyAndSymlinkStagingCannotOverwriteExistingFiles() async throws {
        for symlink in [false, true] {
            let fixture = try AntigravityZIPFixture(); defer { fixture.remove() }
            let release = try fixture.prepare(AntigravityZIPFixture.zip(AntigravityZIPFixture.members))
            if symlink {
                try FileManager.default.removeItem(at: fixture.output)
                try FileManager.default.createSymbolicLink(at: fixture.output, withDestinationURL: fixture.root)
            } else { try Data("existing".utf8).write(to: fixture.output.appendingPathComponent("existing")) }
            await #expect(throws: AntigravityArchiveError.invalidDestination) {
                try await AntigravityArchiveExtractor.extract(release: release, archive: fixture.archive, to: fixture.output)
            }
            #expect(try Data(contentsOf: fixture.sentinel) == Data("retain".utf8))
            if !symlink { #expect(try Data(contentsOf: fixture.output.appendingPathComponent("existing")) == Data("existing".utf8)) }
        }
    }

    @Test func cancellationBeforeDispatchCreatesNoMembers() async throws {
        let fixture = try AntigravityZIPFixture(); defer { fixture.remove() }
        let release = try fixture.prepare(AntigravityZIPFixture.zip(AntigravityZIPFixture.members))
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await AntigravityArchiveExtractor.extract(release: release, archive: fixture.archive, to: fixture.output)
        }
        await #expect(throws: AntigravityArchiveError.cancelled) { try await work.value }
        #expect(try fixture.outputNames().isEmpty)
    }

    @Test func cancellationDuringInflationJoinsWorkerAndRemovesItsPartialMembers() async throws {
        let fixture = try AntigravityZIPFixture(); defer { fixture.remove() }
        var members = AntigravityZIPFixture.members
        members[0].body = Data(repeating: 65, count: 32 * 1_024 * 1_024); members[0].method = 8
        let release = try fixture.prepare(AntigravityZIPFixture.zip(members), serverBytes: Int64(members[0].body.count))
        let work = Task { try await AntigravityArchiveExtractor.extract(release: release, archive: fixture.archive, to: fixture.output) }
        let first = fixture.output.appendingPathComponent(members[0].name)
        var observedPartial = false
        for _ in 0..<3_000 {
            var node = stat()
            if lstat(first.path, &node) == 0, node.st_size > 0, node.st_size < Int64(members[0].body.count) { observedPartial = true; break }
            try await Task.sleep(for: .milliseconds(1))
        }
        work.cancel()
        if observedPartial { await #expect(throws: AntigravityArchiveError.cancelled) { try await work.value } }
        else { _ = try? await work.value; Issue.record("The test did not observe the synthetic archive's partial inflated member.") }
        #expect(try fixture.outputNames().isEmpty)
        #expect(try Data(contentsOf: fixture.sentinel) == Data("retain".utf8))
    }
}

private struct AntigravityZIPMember {
    var name: String
    var body: Data
    var method: UInt16 = 0
    var flags: UInt16 = 0x0800
    var attributes: UInt32 = UInt32(0o100755) << 16
    var descriptor = false
    var signature = true
    var crc: UInt32?
    var localCRC: UInt32?
    var localName: String?
    var localSize: UInt32?
    var compressed: Data?
    var descriptorCRC: UInt32?
    var offsetOverride: UInt64?
    var padding = Data()
}
private struct AntigravityZIPFixture {
    let root: URL
    var archive: URL { root.appendingPathComponent("release.zip") }
    var output: URL { root.appendingPathComponent("staging", isDirectory: true) }
    var sentinel: URL { root.appendingPathComponent("sentinel") }
    static var members: [AntigravityZIPMember] {
        [.init(name: "agy_acp_server.par", body: Data("synthetic server 🌍\n".utf8)),
         .init(name: "localharness_external", body: Data("synthetic harness\n".utf8))]
    }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-archive-extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("retain".utf8).write(to: sentinel)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func outputNames() throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: output.path)) }
    func prepare(_ bytes: Data, serverBytes: Int64? = nil, harnessBytes: Int64? = nil) throws -> AntigravityManagedRelease {
        try bytes.write(to: archive)
        return try .init(version: "synthetic", platform: "darwin", architecture: "arm64", url: URL(string: "https://archive-fixture.invalid/pinned.zip")!,
                         archiveBytes: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                         serverName: Self.members[0].name, serverBytes: serverBytes ?? Int64(Self.members[0].body.count),
                         harnessName: Self.members[1].name, harnessBytes: harnessBytes ?? Int64(Self.members[1].body.count))
    }

    static func boundaryMember(bufferedOutput: Bool) -> AntigravityZIPMember {
        // A nonfinal stored block emits65,528 A bytes, followed by a fixed
        // Huffman block emitting8 or10 more A bytes, then a final stored Z.
        // At exactly65,536 compressed bytes the output buffer is full and
        // input is empty. The next inflate call must either report empty-input
        // Z_BUF_ERROR or emit two buffered bytes with Z_OK, respectively.
        // These APPNOTE/RFC1951 bytes reproduce both boundaries observed in the
        // SHA-verified1.3.0 server member without embedding vendor executable data.
        var compressed = Data([0x00, 0xf8, 0xff, 0x07, 0x00])
        compressed.append(Data(repeating: 65, count: 65_528))
        compressed.append(Data([0x72, 0x84, bufferedOutput ? 0x03 : 0x02, 0x40, 0x00, 0x01, 0x00, 0xfe, 0xff, 0x5a]))
        var body = Data(repeating: 65, count: 65_528 + (bufferedOutput ? 10 : 8)); body.append(0x5a)
        var member = Self.members[0]; member.body = body; member.method = 8; member.compressed = compressed
        return member
    }

    // Hand-built APPNOTE records deliberately exercise real header offsets and
    // raw deflate, rather than mocking the production extractor's parsed rows.
    static func zip(_ members: [AntigravityZIPMember], zip64: Bool = false) throws -> Data {
        var file = Data(), central = Data()
        for member in members {
            let offset = UInt64(file.count), name = Data(member.name.utf8), localName = Data((member.localName ?? member.name).utf8)
            let compressed = try member.compressed ?? (member.method == 8 ? deflate(member.body) : member.body)
            let checksum = member.crc ?? crc(member.body), flags = member.flags | (member.descriptor ? 8 : 0)
            var localExtra = Data(), centralExtra = Data()
            if zip64 {
                localExtra.zip16(1); localExtra.zip16(16); localExtra.zip64(UInt64(member.body.count)); localExtra.zip64(UInt64(compressed.count))
                centralExtra.zip16(1); centralExtra.zip16(24); centralExtra.zip64(UInt64(member.body.count)); centralExtra.zip64(UInt64(compressed.count)); centralExtra.zip64(member.offsetOverride ?? offset)
            }
            file.zip32(0x04034b50); file.zip16(zip64 ? 45 : 20); file.zip16(flags); file.zip16(member.method); file.zip32(0)
            file.zip32(member.localCRC ?? (member.descriptor ? 0 : checksum))
            file.zip32(zip64 ? .max : (member.descriptor ? 0 : UInt32(compressed.count)))
            file.zip32(member.localSize ?? (zip64 ? .max : (member.descriptor ? 0 : UInt32(member.body.count))))
            file.zip16(UInt16(localName.count)); file.zip16(UInt16(localExtra.count)); file.append(localName); file.append(localExtra); file.append(compressed)
            if member.descriptor {
                if member.signature { file.zip32(0x08074b50) }
                file.zip32(member.descriptorCRC ?? checksum)
                if zip64 { file.zip64(UInt64(compressed.count)); file.zip64(UInt64(member.body.count)) }
                else { file.zip32(UInt32(compressed.count)); file.zip32(UInt32(member.body.count)) }
            }
            file.append(member.padding)
            central.zip32(0x02014b50); central.zip16(0x032d); central.zip16(zip64 ? 45 : 20); central.zip16(flags); central.zip16(member.method)
            central.zip32(0); central.zip32(checksum); central.zip32(zip64 ? .max : UInt32(compressed.count)); central.zip32(zip64 ? .max : UInt32(member.body.count))
            central.zip16(UInt16(name.count)); central.zip16(UInt16(centralExtra.count)); central.zip16(0); central.zip16(0); central.zip16(0)
            central.zip32(member.attributes); central.zip32(zip64 ? .max : UInt32(member.offsetOverride ?? offset)); central.append(name); central.append(centralExtra)
        }
        let centralOffset = UInt64(file.count); file.append(central)
        if zip64 {
            let recordOffset = UInt64(file.count)
            file.zip32(0x06064b50); file.zip64(44); file.zip16(45); file.zip16(45); file.zip32(0); file.zip32(0)
            file.zip64(UInt64(members.count)); file.zip64(UInt64(members.count)); file.zip64(UInt64(central.count)); file.zip64(centralOffset)
            file.zip32(0x07064b50); file.zip32(0); file.zip64(recordOffset); file.zip32(1)
        }
        file.zip32(0x06054b50); file.zip16(0); file.zip16(0)
        file.zip16(zip64 ? .max : UInt16(members.count)); file.zip16(zip64 ? .max : UInt16(members.count))
        file.zip32(zip64 ? .max : UInt32(central.count)); file.zip32(zip64 ? .max : UInt32(centralOffset)); file.zip16(0)
        return file
    }
    static func crc(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { UInt32(truncatingIfNeeded: crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
    }
    static func deflate(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw AntigravityZIPFixtureError.compression }
        defer { deflateEnd(&stream) }
        var output = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        try data.withUnsafeBytes { bytes in
            stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: Bytef.self).baseAddress); stream.avail_in = uInt(bytes.count)
            var status: Int32 = Z_OK
            repeat {
                status = buffer.withUnsafeMutableBytes { target in
                    stream.next_out = target.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(target.count)
                    return zlib.deflate(&stream, Z_FINISH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw AntigravityZIPFixtureError.compression }
                output.append(contentsOf: buffer.prefix(buffer.count - Int(stream.avail_out)))
            } while status != Z_STREAM_END
        }; return output
    }
}
private enum AntigravityZIPFixtureError: Error { case compression }
private extension Data {
    mutating func zip16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func zip32(_ value: UInt32) { zip16(UInt16(truncatingIfNeeded: value)); zip16(UInt16(truncatingIfNeeded: value >> 16)) }
    mutating func zip64(_ value: UInt64) { zip32(UInt32(truncatingIfNeeded: value)); zip32(UInt32(truncatingIfNeeded: value >> 32)) }
    mutating func zipSet16(_ value: UInt16, at offset: Int) { self[offset] = UInt8(truncatingIfNeeded: value); self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8) }
    mutating func zipSet32(_ value: UInt32, at offset: Int) { zipSet16(UInt16(truncatingIfNeeded: value), at: offset); zipSet16(UInt16(truncatingIfNeeded: value >> 16), at: offset + 2) }
    mutating func zipSet64(_ value: UInt64, at offset: Int) { zipSet32(UInt32(truncatingIfNeeded: value), at: offset); zipSet32(UInt32(truncatingIfNeeded: value >> 32), at: offset + 4) }
}
