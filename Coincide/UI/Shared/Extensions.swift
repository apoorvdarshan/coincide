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

extension NSResponder {
    /// Hands a find command (Find…, Find Next, Use Selection for Find) to the next responder that handles
    /// it, such as the chat's find bar. Text views call this instead of searching only their own text,
    /// which as text views without a find bar they would refuse to do.
    func passTextFinderActionOn(_ sender: Any?) {
        nextTextFinder?.performTextFinderAction(sender)
    }

    /// Whether the responder that `passTextFinderActionOn` hands the command to can perform it.
    func validatePassedOnTextFinderAction(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard let finder = nextTextFinder else { return false }
        if let menuItem = item as? NSMenuItem, let validator = finder as? NSMenuItemValidation {
            return validator.validateMenuItem(menuItem)
        }
        return (finder as? NSUserInterfaceValidations)?.validateUserInterfaceItem(item) ?? true
    }

    private var nextTextFinder: NSResponder? {
        var responder = nextResponder
        while let current = responder {
            if current.responds(to: #selector(NSResponder.performTextFinderAction(_:))) { return current }
            responder = current.nextResponder
        }
        return nil
    }
}

extension NSPasteboard {
    /// Replaces the pasteboard's contents with plain text, as Copy does.
    func setText(_ text: String) {
        clearContents()
        setString(text, forType: .string)
    }
}
