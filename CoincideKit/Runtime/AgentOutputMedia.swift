import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Runtime-only output guidance, independent of browser agent control and never saved as the user's message.
public enum AgentOutputMedia {
    public static let context = """
        <coincide_output>
        Coincide can display your actual output inline: Markdown images (![description](/absolute/path/image.png)) and links to audio or video files ([description](/absolute/path/clip.mp4)). HTTP(S) media URLs also work. Use absolute local paths so projectless threads can resolve them.
        For self-contained interactive charts or tools, use a fenced code block with language coincide-html (HTML/CSS/inline JavaScript) or coincide-svg (SVG), or link a local .html/.svg file. Previews have no network, saved logins, app access, external scripts, popups or downloads. Use inline code and data only. Ordinary html fences remain code samples.
        Only show files or results that were actually created. If a generation tool failed or is unavailable, explain that; never claim an image or video was generated without a real result.
        </coincide_output>
        """

    /// Preserves a native generation result before an agent's scratch directory disappears. Bounded decoding
    /// checks the actual image type; arbitrary tool text and non-image files never become attachments.
    @concurrent
    static func preserveImage(path: String, toolID: UUID, directory: URL) async -> String? {
        guard path.hasPrefix("/"), path.utf8.count < 4096 else { return nil }
        let sourceURL = URL(fileURLWithPath: path)
        guard let info = try? sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), info.isRegularFile == true,
            let size = info.fileSize, size > 0, size <= 32 * 1024 * 1024,
            let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil), CGImageSourceGetCount(source) > 0,
            let identifier = CGImageSourceGetType(source) as String?, let type = UTType(identifier), type.conforms(to: .image),
            let ext = type.preferredFilenameExtension else { return nil }
        let destination = directory.appendingPathComponent("generated-" + toolID.uuidString).appendingPathExtension(ext)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: sourceURL, to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
            return destination.path
        } catch { return nil }
    }
}
