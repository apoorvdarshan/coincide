import Foundation
import Testing
@testable import CoincideKit

struct AgentOutputMediaTests {
    @Test func generatedImagesAreValidatedCopiedPrivatelyAndReusable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("generated-media-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("image.png")
        try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNQmFDwHwAEFAIglHcfOQAAAABJRU5ErkJggg==")).write(to: source)
        let folder = root.appendingPathComponent("attachments")
        let id = UUID()
        let saved = try #require(await AgentOutputMedia.preserveImage(path: source.path, toolID: id, directory: folder))
        #expect(saved != source.path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: saved)) == Data(contentsOf: source))
        #expect((try FileManager.default.attributesOfItem(atPath: saved)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(await AgentOutputMedia.preserveImage(path: source.path, toolID: id, directory: folder) == saved)
        let fake = root.appendingPathComponent("fake.png")
        try Data("not an image".utf8).write(to: fake)
        #expect(await AgentOutputMedia.preserveImage(path: fake.path, toolID: UUID(), directory: folder) == nil)
        #expect(await AgentOutputMedia.preserveImage(path: "relative.png", toolID: UUID(), directory: folder) == nil)
    }
}
