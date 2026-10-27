import AppKit

extension String {
    /// Nil when the string is empty.
    var nonEmpty: String? { isEmpty ? nil : self }

    /// Nil when the string is empty or only whitespace.
    var nonBlank: String? { allSatisfy(\.isWhitespace) ? nil : self }
}

extension Collection {
    /// The element at `index`, or nil when it is out of range.
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension NSPasteboard {
    /// Replaces the pasteboard's contents with plain text, as Copy does.
    func setText(_ text: String) {
        clearContents()
        setString(text, forType: .string)
    }
}
