import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image attachments as Messages API image blocks.
enum ClaudeAttachments {
    /// The API accepts up to 5 MB of base64 per image, which is 3.75 MB of raw bytes.
    static let maxImageBytes = 3_750_000
    /// Once a conversation holds many images, the API rejects any image with a side over 2000 pixels,
    /// and it scales larger ones down anyway.
    static let maxPixelSize = 2_000

    /// Image blocks for the given files, plus the files that could not be attached.
    static func imageBlocks(for paths: [String]) -> (blocks: [JSONValue], skipped: [String]) {
        var blocks: [JSONValue] = []
        var skipped: [String] = []
        for path in paths {
            guard let data = FileManager.default.contents(atPath: path), let (mediaType, bytes) = encodable(data) else {
                skipped.append(path)
                continue
            }
            blocks.append([
                "type": "image",
                "source": ["type": "base64", "media_type": .string(mediaType), "data": .string(bytes.base64EncodedString())],
            ])
        }
        return (blocks, skipped)
    }

    /// The image as-is when Claude accepts it, otherwise re-encoded (and downscaled) as PNG or JPEG.
    static func encodable(_ data: Data) -> (mediaType: String, data: Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetType(source) != nil,
            CGImageSourceGetCount(source) > 0
        else { return nil }
        if let mediaType = mediaType(of: data), data.count <= maxImageBytes,
            pixelSize(source).map({ max($0.width, $0.height) <= maxPixelSize }) ?? true
        {
            return (mediaType, data)
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
        let encodeOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        for (type, mediaType) in [(UTType.png, "image/png"), (UTType.jpeg, "image/jpeg")] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, encodeOptions as CFDictionary)
            if CGImageDestinationFinalize(destination), output.length <= maxImageBytes { return (mediaType, output as Data) }
        }
        return nil
    }

    /// Pixel dimensions of the first image, read from its header.
    private static func pixelSize(_ source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        return (width, height)
    }

    /// PNG, JPEG, GIF or WebP, the formats Claude reads directly.
    static func mediaType(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if bytes.count >= 12, bytes.starts(with: [0x52, 0x49, 0x46, 0x46]), Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        return nil
    }
}
