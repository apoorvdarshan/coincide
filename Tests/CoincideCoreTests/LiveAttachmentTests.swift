import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CoincideCore

private func markerImage(_ marker: String) throws -> Data {
    let context = try #require(CGContext(data: nil, width: 560, height: 160, bitsPerComponent: 8, bytesPerRow: 560 * 4,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 560, height: 160))
    let text = NSAttributedString(string: marker, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo-Bold" as CFString, 36, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
    context.textPosition = CGPoint(x: 20, y: 60); CTLineDraw(CTLineCreateWithAttributedString(text), context)
    let output = NSMutableData(), image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil); #expect(CGImageDestinationFinalize(destination))
    return output as Data
}

/// Explicit opt-in: incurs real provider usage and sends only generated test data.
@Test(.enabled(if: ProcessInfo.processInfo.environment["COINCIDE_LIVE_ATTACHMENTS"] == "1"), .timeLimit(.minutes(3)), arguments: ProviderKind.builtIn)
func installedProvidersReadAnImageAndFileThroughTheNativeEngine(_ kind: ProviderKind) async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"))
    do {
        _ = try await engine.load()
        // Avoid visually ambiguous punctuation in an OCR fixture; retain an exact
        // comparison of independent random image and file markers.
        let project = WorkspaceProject(path: root.path), imageMarker = "IMG\(Int.random(in: 100_000...999_999))", fileMarker = "NOTE\(Int.random(in: 100_000...999_999))"
        var thread = CodingThread(project: project); thread.provider = kind
        try await engine.dispatch(.addProject(project)); try await engine.dispatch(.createThread(thread))
        let image = try await engine.attachments.importData(markerImage(imageMarker), name: "picture.png")
        let note = try await engine.attachments.importData(Data(fileMarker.utf8), name: "note.txt")
        let noteURL = try await engine.attachments.url(for: note)
        try await engine.dispatch(.addAttachments(threadID: thread.id, attachments: [image, note]))
        try await engine.dispatch(.submit(threadID: thread.id, text: "Read the text in the attached image and the attached text file. Reply with only the image text, one space, then the file text. You may use a read-only tool to read the attached file. Do not change files or use the network."))
        let deadline = ContinuousClock.now + .seconds(140)
        while true {
            let state = await engine.current(), current = try #require(state.snapshot.threads.first)
            if let error = state.error { throw CoincideError(error) }
            if current.state == .idle {
                let answer = current.messages.last(where: { $0.role == .assistant })?.text.trimmingCharacters(in: .whitespacesAndNewlines)
                #expect(answer == "\(imageMarker) \(fileMarker)")
                #expect(current.messages.first?.attachments == [image, note] && current.draftAttachments.isEmpty)
                break
            }
            if current.state == .failed || current.state == .interrupted { throw CoincideError("The live \(kind.name) attachment turn did not complete.") }
            for request in current.runtimeRequests where !request.responding {
                let permitted = request.request.method == "can_use_tool" && request.request.params["tool_name"].string == "Read" && request.request.params["input"]["file_path"].string == noteURL.path
                try await engine.dispatch(.respond(threadID: thread.id, requestID: request.id, response: .decision(permitted)))
            }
            guard ContinuousClock.now < deadline else { throw CoincideError("The live attachment smoke check timed out.") }
            try await Task.sleep(for: .milliseconds(200))
        }
        await engine.shutdown()
    } catch { await engine.shutdown(); throw error }
}
