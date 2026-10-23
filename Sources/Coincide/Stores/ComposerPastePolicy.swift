import Foundation

enum ComposerPastePolicy {
    static let attachmentThreshold = 32 * 1_024
    static let maximumInputLength = 120_000
    static func exceedsInputLimit(_ pasted: String, text: String, selection: NSRange) -> Bool {
        guard ComposerUTF16Selection.isValid(selection, in: text) else { return true }
        return text.utf16.count - selection.length + pasted.utf16.count > maximumInputLength
    }
    static func folds(_ text: String, bypass: Bool, wouldExceedLimit: Bool = false) -> Bool {
        !bypass && !text.isEmpty && (wouldExceedLimit || text.utf8.count >= attachmentThreshold)
    }
    static func nextName(_ names: [String]) -> String {
        let reserved = Set(names.map { $0.lowercased() })
        if !reserved.contains("pasted-text.txt") { return "pasted-text.txt" }
        var index = 2
        while reserved.contains("pasted-text-\(index).txt") { index += 1 }
        return "pasted-text-\(index).txt"
    }
    static func replacing(_ range: NSRange, in text: String, with replacement: String) -> (String, NSRange)? {
        guard ComposerUTF16Selection.isValid(range, in: text), let swiftRange = Range(range, in: text) else { return nil }
        var result = text; result.replaceSubrange(swiftRange, with: replacement)
        return (result, .init(location: range.location + replacement.utf16.count, length: 0))
    }
}
