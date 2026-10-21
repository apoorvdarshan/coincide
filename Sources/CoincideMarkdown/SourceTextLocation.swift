import Foundation

public enum SourceTextLocation {
    /// Clamp out-of-range references to EOF; NSTextView ranges use UTF-16 units.
    public static func range(in text: String, line: Int) -> NSRange {
        let source = text as NSString
        guard line > 1 else { return source.lineRange(for: NSRange(location: 0, length: 0)) }
        var offset = 0, current = 1
        while current < line, offset < source.length {
            offset = NSMaxRange(source.lineRange(for: NSRange(location: offset, length: 0))); current += 1
        }
        guard offset < source.length else { return NSRange(location: source.length, length: 0) }
        return source.lineRange(for: NSRange(location: offset, length: 0))
    }
}
