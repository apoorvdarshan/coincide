import Foundation

/// Bounds for text that can grow without limit, such as command output. Sizes are UTF-8 bytes, which
/// Swift strings count in constant time, so checking a long, growing output stays cheap.
public enum TextClip {
    /// Keeps the newest `clipTo` bytes once `text` is longer than `limit`, cutting at a character boundary.
    public nonisolated static func keepingTail(_ text: String, limit: Int, clipTo: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var start = text.utf8.index(text.utf8.endIndex, offsetBy: -max(0, min(clipTo, limit)))
        while start > text.startIndex, start.samePosition(in: text) == nil { start = text.utf8.index(before: start) }
        return String(text[start...])
    }
}
