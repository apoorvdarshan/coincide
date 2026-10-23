import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ChatAttachment: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var mimeType: String
    public var byteCount: Int
    public var digest: String
    public var fileExtension: String
    public var isImage: Bool { ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mimeType) }
}

public struct ProviderImage: Sendable, Equatable {
    public var mimeType: String
    public var data: Data
}
public struct ProviderInput: Sendable, Equatable {
    public var text: String
    public var images: [ProviderImage]
    public init(text: String, images: [ProviderImage] = []) { self.text = text; self.images = images }
}

public enum AttachmentLimits {
    public static let count = 100
    public static let imageBytes = 10 * 1_024 * 1_024
    public static let totalImageBytes = 80 * 1_024 * 1_024
    public static let fileBytes = 50 * 1_024 * 1_024
    public static func validate(_ values: [ChatAttachment]) throws {
        guard values.count <= count, Set(values.map(\.id)).count == values.count else { throw CoincideError("Attach up to 100 distinct files per message.") }
        var total = 0
        for value in values {
            guard value.byteCount >= 0, value.byteCount <= (value.isImage ? imageBytes : fileBytes),
                  !value.name.isEmpty, value.name.utf8.count <= 1_024, !value.mimeType.isEmpty, value.mimeType.utf8.count <= 128, value.digest.count == 64,
                  value.digest.allSatisfy({ $0.isHexDigit }),
                  value.fileExtension.count <= 16, value.fileExtension.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                throw CoincideError("This attachment has invalid metadata or exceeds the file limit.")
            }
            if value.isImage { total += value.byteCount }
        }
        guard total <= totalImageBytes else { throw CoincideError("Images in one message must total 80 MiB or less.") }
    }
}

/// Immutable private copies. SQLite and provider-effect journals contain references,
/// never base64 payloads or paths to the user's original files.
public actor AttachmentStore {
    public nonisolated let root: URL
    public init(root: URL) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
    }
    public func importFile(_ url: URL) throws -> ChatAttachment {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw CoincideError("Attach a regular file, not a folder.") }
        let data = try readBounded(url, limit: AttachmentLimits.fileBytes)
        return try importData(data, name: url.lastPathComponent)
    }
    public func importData(_ data: Data, name: String) throws -> ChatAttachment {
        try importData(data, name: name, reserving: nil)
    }
    /// A host reserves this identity durably before publication. An exact
    /// repeated finalize verifies the existing immutable copy instead of
    /// allocating another blob after a lost response or process interruption.
    func importFile(_ url: URL, name: String, reservedID: UUID) throws -> ChatAttachment {
        try importData(readBounded(url, limit: AttachmentLimits.fileBytes), name: name, reserving: reservedID)
    }
    private func importData(_ data: Data, name: String, reserving reservedID: UUID?) throws -> ChatAttachment {
        try Task.checkCancellation()
        guard data.count <= AttachmentLimits.fileBytes else { throw CoincideError("Files must be 50 MiB or smaller.") }
        var bytes = data
        let basename = String(name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last ?? "Attachment")
        let cleaned = basename.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? "_" : String($0) }.joined()
        let safeName = cleaned.utf8.count <= 1_024 ? cleaned : String(String.UnicodeScalarView(cleaned.unicodeScalars.prefix(200)))
        var ext = URL(fileURLWithPath: basename).pathExtension.lowercased()
        if ext.count > 16 || !ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) { ext = "" }
        var mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        if let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true {
            let actual = UTType(type as String)
            mime = actual?.preferredMIMEType ?? mime
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            guard width > 0, height > 0 else { throw CoincideError("This image could not be read.") }
            if !["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime) || data.count > AttachmentLimits.imageBytes || max(width, height) > 4_096 {
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4_096] as CFDictionary) else { throw CoincideError("This image could not be converted.") }
                let converted = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(converted, UTType.jpeg.identifier as CFString, 1, nil) else { throw CoincideError("This image could not be converted.") }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw CoincideError("This image could not be converted.") }
                bytes = converted as Data; mime = "image/jpeg"; ext = "jpg"
            } else { ext = actual?.preferredFilenameExtension ?? ext }
        } else if ["image/png", "image/jpeg", "image/gif", "image/webp", "image/heic", "image/heif"].contains(mime) {
            throw CoincideError("This file does not contain a supported readable image.")
        }
        let reference = ChatAttachment(id: reservedID ?? UUID(), name: safeName.isEmpty ? "Attachment" : safeName, mimeType: mime,
            byteCount: bytes.count, digest: Self.digest(bytes), fileExtension: ext)
        try AttachmentLimits.validate([reference])
        try Task.checkCancellation()
        let target = path(reference)
        if reservedID != nil, FileManager.default.fileExists(atPath: target.path) {
            guard try self.data(for: reference) == bytes else { throw CoincideError("The reserved attachment content changed.") }
            return reference
        }
        try writePrivate(bytes, to: target)
        return reference
    }
    /// Range reads never resolve a caller path and never reread a complete
    /// 50 MiB attachment per page. Receivers verify its final native digest.
    func read(_ reference: ChatAttachment, offset: Int, maximumBytes: Int) throws -> Data {
        try AttachmentLimits.validate([reference])
        guard offset >= 0, offset <= reference.byteCount, (1...RemoteAttachmentProtocol.maximumChunkBytes).contains(maximumBytes) else { throw RemoteAttachmentFailure(.invalidRequest) }
        let directory = try GitWorktreeDirectory(path: root.path)
        let fd = openat(directory.fd, path(reference).lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw RemoteAttachmentFailure(.integrity) }
        defer { Darwin.close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(), before.st_nlink == 1,
              before.st_size == reference.byteCount else { throw RemoteAttachmentFailure(.integrity) }
        var bytes = Data(count: min(maximumBytes, reference.byteCount - offset)), position = 0
        while position < bytes.count {
            try Task.checkCancellation()
            let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress!.advanced(by: position), $0.count - position, off_t(offset + position)) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw RemoteAttachmentFailure(.integrity) }; position += count
        }
        guard fstat(fd, &after) == 0, worktreeIdentity(before) == worktreeIdentity(after), before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw RemoteAttachmentFailure(.integrity) }
        try directory.validate()
        return bytes
    }
    func removeUnclaimed(_ reference: ChatAttachment) throws {
        var info = stat()
        if lstat(path(reference).path, &info) != 0, errno == ENOENT { return }
        _ = try data(for: reference)
        let directory = try GitWorktreeDirectory(path: root.path)
        guard unlinkat(directory.fd, path(reference).lastPathComponent, 0) == 0, fsync(directory.fd) == 0 else { throw RemoteAttachmentFailure(.unavailable) }
    }
    public func url(for reference: ChatAttachment) throws -> URL {
        try AttachmentLimits.validate([reference])
        let url = path(reference)
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true, values.fileSize == reference.byteCount else { throw CoincideError("This attachment is missing or changed. Attach it again.") }
        return url
    }
    public func data(for reference: ChatAttachment) throws -> Data {
        let bytes = try readBounded(url(for: reference), limit: reference.isImage ? AttachmentLimits.imageBytes : AttachmentLimits.fileBytes)
        guard bytes.count == reference.byteCount, Self.digest(bytes) == reference.digest else { throw CoincideError("This attachment changed. Attach it again.") }
        return bytes
    }
    public func prepare(text: String, attachments: [ChatAttachment]) throws -> ProviderInput {
        try AttachmentLimits.validate(attachments)
        var input = ProviderInput(text: text)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        for attachment in attachments {
            try Task.checkCancellation()
            let bytes = try data(for: attachment), url = try url(for: attachment)
            // JSON quoting keeps filenames and paths separate from authored instructions.
            let name = String(decoding: try encoder.encode(attachment.name), as: UTF8.self)
            let path = String(decoding: try encoder.encode(url.path), as: UTF8.self)
            input.text += "\n\n[Attached \(attachment.isImage ? "image" : "file") \(name) is saved at: \(path)]"
            if attachment.isImage { input.images.append(.init(mimeType: attachment.mimeType, data: bytes)) }
        }
        return input
    }
    private func path(_ reference: ChatAttachment) -> URL {
        root.appendingPathComponent(reference.id.uuidString + (reference.fileExtension.isEmpty ? "" : "." + reference.fileExtension))
    }
    private func readBounded(_ url: URL, limit: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var result = Data()
        while let chunk = try file.read(upToCount: min(1_048_576, limit + 1 - result.count)), !chunk.isEmpty {
            try Task.checkCancellation()
            result.append(chunk)
            guard result.count <= limit else { throw CoincideError("This attachment exceeds the file limit.") }
        }
        return result
    }
    private func writePrivate(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw CoincideError("Could not save this attachment.") }
        var complete = false
        defer { Darwin.close(descriptor); if !complete { try? FileManager.default.removeItem(at: url) } }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw CoincideError("Could not save this attachment.") }; offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw CoincideError("Could not finish saving this attachment.") }
        let directory = Darwin.open(root.path, O_RDONLY | O_CLOEXEC)
        guard directory >= 0 else { throw CoincideError("Could not finish saving this attachment.") }
        defer { Darwin.close(directory) }
        guard fsync(directory) == 0 else { throw CoincideError("Could not finish saving this attachment.") }
        complete = true
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
