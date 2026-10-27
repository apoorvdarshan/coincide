extension FuzzInput {
    /// Pieces that make paths hard to parse: spaces, the ` b/` that splits `diff --git` headers,
    /// characters git quotes, non-ASCII text and combining marks.
    private static let pathPieces = [
        "a", "b", "src", "Sources", "/", " ", "a/", "b/", " b/", ".", "-", "_", "x.swift", "é", "日本", "🙂",
        "e\u{301}", "\u{301}", "\t", "\n", "\r", "\"", "\\", "#", "?", "1", "\u{7F}", "\u{01}", "~", "@", "\u{85}",
    ]

    private static let refPieces = [
        "main", "feature", "fix", "/", "-", "_", "x", "1", "é", "release-1.0", "coincide/1a2b3c4d", ".",
    ]

    /// A path git could report: not empty, no NUL, not starting with `/`.
    public mutating func gitPath() -> String {
        let path = text(Self.pathPieces, maxPieces: 6)
        return path.isEmpty || path.hasPrefix("/") ? "f" + path : path
    }

    /// A branch or upstream name: not empty and without spaces.
    public mutating func refName() -> String {
        let name = text(Self.refPieces, maxPieces: 4)
        return name.isEmpty ? "main" : name
    }

    /// Free text without newlines, such as a lock reason or a hunk's section heading.
    public mutating func lineText(maxPieces: Int = 6) -> String {
        text(
            [
                "a", "b", " ", "  ", "\t", "x y", "+", "-", "@@", "\\", "\"", "é", "🙂", "\r", "{", "}", "func run() {",
                "diff --git ", "e\u{301}", "\u{301}",
            ], maxPieces: maxPieces)
    }
}
