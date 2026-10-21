import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CoincideCore

func attachmentImageData(type: UTType = .png, width: Int = 120, height: Int = 60) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage()), output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil); #expect(CGImageDestinationFinalize(destination))
    return output as Data
}

@Test func attachmentSizedFramesRemainBoundedAndDecodeIncrementally() throws {
    let length = 17 * 1_024 * 1_024
    var frame = Data("{\"payload\":\"".utf8); frame.append(Data(repeating: 97, count: length)); frame.append(Data("\"}\n{}\n".utf8))
    var decoder = NDJSONDecoder(maximumFrameSize: 128 * 1_024 * 1_024), values: [JSONValue] = []
    for start in stride(from: 0, to: frame.count, by: 8_192) {
        values += try decoder.append(frame.subdata(in: start..<min(start + 8_192, frame.count)))
    }
    #expect(values.count == 2 && values[0]["payload"].string?.utf8.count == length && values[1] == .object([:]))
    var standard = NDJSONDecoder()
    #expect(throws: (any Error).self) { try standard.append(frame) }
}

@Test func attachmentCopiesArePrivateImmutableAndSurviveSourceRemoval() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("original 🌍.txt"), directory = root.appendingPathComponent("Attachments")
    try Data("original".utf8).write(to: source)
    let store = try AttachmentStore(root: directory), reference = try await store.importFile(source)
    try Data("changed!".utf8).write(to: source); try FileManager.default.removeItem(at: source)
    let reopened = try AttachmentStore(root: directory), url = try await reopened.url(for: reference)
    #expect(try await reopened.data(for: reference) == Data("original".utf8))
    #expect(reference.name == "original 🌍.txt" && reference.mimeType == "text/plain" && !reference.isImage)
    #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
    #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
    let another = try await reopened.importData(Data("original".utf8), name: reference.name)
    #expect(another.id != reference.id && another.digest == reference.digest)
    let payload = try JSONEncoder().encode(reference)
    #expect(!String(decoding: payload, as: UTF8.self).contains(root.path))
}

@Test func attachmentsDetectFormatsConvertImagesAndKeepNonImageFiles() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try AttachmentStore(root: root)
    let png = try await store.importData(attachmentImageData(), name: "misnamed.txt")
    #expect(png.isImage && png.mimeType == "image/png" && png.fileExtension == "png")
    let converted = try await store.importData(attachmentImageData(type: .tiff), name: "scan.tiff")
    #expect(converted.mimeType == "image/jpeg" && converted.fileExtension == "jpg")
    let wide = try await store.importData(attachmentImageData(width: 6_000, height: 8), name: "wide.png")
    #expect(wide.mimeType == "image/jpeg")
    let data = try await store.data(for: wide), image = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
    #expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 4_096)
    let svg = try await store.importData(Data("<svg/>".utf8), name: "diagram.svg")
    #expect(!svg.isImage && svg.mimeType == "image/svg+xml")
    let longName = String(repeating: "a", count: 247) + ".txt"
    let long = try await store.importData(Data("text".utf8), name: longName)
    #expect(long.name == longName && long.mimeType == "text/plain" && long.fileExtension == "txt")
    await #expect(throws: (any Error).self) { try await store.importData(Data("not an image".utf8), name: "bad.png") }
}

@Test func attachmentIntegrityTraversalAndLimitsFailExplicitly() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try AttachmentStore(root: root.appendingPathComponent("saved"))
    let reference = try await store.importData(Data("safe".utf8), name: "../../safe.txt")
    let url = try await store.url(for: reference)
    #expect(reference.name == "safe.txt")
    try Data("evil".utf8).write(to: url)
    await #expect(throws: (any Error).self) { try await store.data(for: reference) }
    try FileManager.default.removeItem(at: url)
    let outside = root.appendingPathComponent("outside"); try Data("safe".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
    await #expect(throws: (any Error).self) { try await store.data(for: reference) }
    var traversal = reference; traversal.fileExtension = "../../outside"
    await #expect(throws: (any Error).self) { try await store.url(for: traversal) }
    #expect(throws: (any Error).self) { try AttachmentLimits.validate([reference, reference]) }
    var image = reference; image.mimeType = "image/png"; image.byteCount = AttachmentLimits.imageBytes + 1
    #expect(throws: (any Error).self) { try AttachmentLimits.validate([image]) }
    image.byteCount = AttachmentLimits.imageBytes
    let many = (0..<9).map { _ in var value = image; value.id = UUID(); return value }
    #expect(throws: (any Error).self) { try AttachmentLimits.validate(many) }
    let tooMany = (0..<101).map { _ in var value = reference; value.id = UUID(); return value }
    #expect(throws: (any Error).self) { try AttachmentLimits.validate(tooMany) }
    let large = root.appendingPathComponent("large.bin")
    #expect(FileManager.default.createFile(atPath: large.path, contents: nil))
    let handle = try FileHandle(forWritingTo: large); try handle.truncate(atOffset: UInt64(AttachmentLimits.fileBytes + 1)); try handle.close()
    await #expect(throws: (any Error).self) { try await store.importFile(large) }
}

@Test func attachmentReferencesReplayWhenOnlyMessageAttachmentsChange() throws {
    var old = WorkspaceSnapshot(); let project = WorkspaceProject(path: "/tmp")
    var thread = CodingThread(project: project); thread.messages = [.init(role: .user, text: "same text")]
    old.projects = [project]; old.threads = [thread]
    var next = old
    let reference = ChatAttachment(id: UUID(), name: "test.txt", mimeType: "text/plain", byteCount: 0,
                                   digest: String(repeating: "0", count: 64), fileExtension: "txt")
    next.threads[0].messages[0].attachments = [reference]
    var replay = old
    for event in try WorkspaceJournal.changes(from: old, to: next) { try event.apply(to: &replay) }
    #expect(replay == next)
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(thread)) as? [String: Any])
    object.removeValue(forKey: "draftAttachments")
    #expect(try JSONDecoder().decode(CodingThread.self, from: JSONSerialization.data(withJSONObject: object)).draftAttachments.isEmpty)
    let queued = QueuedTurn(id: UUID(), text: "old", configuration: .init(thread: thread), createdAt: Date())
    #expect(try JSONDecoder().decode(QueuedTurn.self, from: JSONEncoder().encode(queued)).attachments == nil)
    let effect = WorkspaceEffectRequest.providerStart(threadID: thread.id, runID: UUID(), configuration: .init(thread: thread), prompt: "old")
    #expect(try JSONDecoder().decode(WorkspaceEffectRequest.self, from: JSONEncoder().encode(effect)) == effect)
}

@Test(.timeLimit(.minutes(1))) func providersDeliverNativeImagesAndFileContextThroughTheirRealTransports() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try AttachmentStore(root: root.appendingPathComponent("Attachments"))
    let image = try await store.importData(attachmentImageData(), name: "blue.png")
    let note = try await store.importData(Data("A synthetic attachment.".utf8), name: "note.txt")
    let input = try await store.prepare(text: "Read this note", attachments: [image, note])
    #expect(input.images.count == 1 && input.text.contains("Attached file"))
    let peer = try #require(Bundle.module.url(forResource: "attachment_server", withExtension: "py", subdirectory: "Fixtures"))
    for kind in ProviderKind.builtIn {
        var thread = CodingThread(project: WorkspaceProject(path: root.path)); thread.provider = kind
        let session: any ProviderSession = kind == .codex
            ? try CodexSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), cwd: root, arguments: [peer.path, kind.rawValue])
            : try ClaudeSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), cwd: root, arguments: [peer.path, kind.rawValue])
        do {
            let observer = Task {
                var text = ""
                for await event in session.events {
                    switch event {
                    case .message(let message): text = message.text
                    case .completed: return text
                    case .failure(let message), .connectionClosed(let message): throw CoincideError(message)
                    default: break
                    }
                }
                throw CoincideError("Attachment peer ended early")
            }
            try await session.send(input: input, thread: thread)
            #expect(try await observer.value == "ATTACHMENT_FIXTURE_OK")
            await session.close()
        } catch { await session.close(); throw error }
    }
}
