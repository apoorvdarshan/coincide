import Foundation

/// T3 `when` AST: identifiers combined with `!`, `&&`, `||` and parentheses.
public indirect enum KeybindingWhen: Hashable, Sendable {
    case identifier(String)
    case not(KeybindingWhen)
    case and(KeybindingWhen, KeybindingWhen)
    case or(KeybindingWhen, KeybindingWhen)

    public static let maxLength = 256
    public static let maxDepth = 64

    /// Port of T3 `parseKeybindingWhenExpression`; nil for an empty, malformed or too deeply nested expression.
    public init?(parsing expression: String) {
        guard expression.utf16.count <= Self.maxLength else { return nil }
        guard let tokens = Self.tokenize(expression), !tokens.isEmpty else { return nil }
        var parser = Parser(tokens: tokens)
        guard let node = parser.parseOr(depth: 0), parser.index == tokens.count else { return nil }
        self = node
    }

    /// Unknown identifiers are false; `true` and `false` are literals.
    public func evaluate(_ context: KeybindingContext) -> Bool {
        switch self {
        case .identifier(let name): name == "true" ? true : name == "false" ? false : context[name]
        case .not(let node): !node.evaluate(context)
        case .and(let left, let right): left.evaluate(context) && right.evaluate(context)
        case .or(let left, let right): left.evaluate(context) || right.evaluate(context)
        }
    }

    /// Canonical text that parses back to the same tree, using only the parentheses
    /// that precedence and left association require (`&&` binds tighter than `||`).
    public var expression: String {
        switch self {
        case .identifier(let name): name
        case .not(let node): "!" + node.wrapped
        case .and(let left, let right):
            (left.isOr ? left.wrapped : left.expression) + " && " + (right.isAtom ? right.expression : right.wrapped)
        case .or(let left, let right):
            left.expression + " || " + (right.isOr ? right.wrapped : right.expression)
        }
    }
    private var isAtom: Bool { if case .identifier = self { true } else if case .not = self { true } else { false } }
    private var isOr: Bool { if case .or = self { true } else { false } }
    private var wrapped: String { isAtom ? expression : "(" + expression + ")" }
    public var identifiers: Set<String> {
        switch self {
        case .identifier(let name): [name]
        case .not(let node): node.identifiers
        case .and(let left, let right), .or(let left, let right): left.identifiers.union(right.identifiers)
        }
    }

    enum Token: Equatable { case identifier(String), not, and, or, lparen, rparen }
    static func tokenize(_ expression: String) -> [Token]? {
        var tokens: [Token] = []
        let scalars = Array(expression.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { index += 1; continue }
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil
            if scalar == "&", next == "&" { tokens.append(.and); index += 2; continue }
            if scalar == "|", next == "|" { tokens.append(.or); index += 2; continue }
            if scalar == "!" { tokens.append(.not); index += 1; continue }
            if scalar == "(" { tokens.append(.lparen); index += 1; continue }
            if scalar == ")" { tokens.append(.rparen); index += 1; continue }
            guard isIdentifierStart(scalar) else { return nil }
            var end = index + 1
            while end < scalars.count, isIdentifierPart(scalars[end]) { end += 1 }
            tokens.append(.identifier(String(String.UnicodeScalarView(scalars[index..<end]))))
            index = end
        }
        return tokens
    }
    private static func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (CharacterSet.letters.contains(scalar) || scalar == "_")
    }
    private static func isIdentifierPart(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "_.-".unicodeScalars.contains(scalar))
    }

    private struct Parser {
        let tokens: [Token]
        var index = 0
        mutating func parseOr(depth: Int) -> KeybindingWhen? {
            guard var left = parseAnd(depth: depth) else { return nil }
            while index < tokens.count, tokens[index] == .or {
                index += 1
                guard let right = parseAnd(depth: depth) else { return nil }
                left = .or(left, right)
            }
            return left
        }
        mutating func parseAnd(depth: Int) -> KeybindingWhen? {
            guard var left = parseUnary(depth: depth) else { return nil }
            while index < tokens.count, tokens[index] == .and {
                index += 1
                guard let right = parseUnary(depth: depth) else { return nil }
                left = .and(left, right)
            }
            return left
        }
        mutating func parseUnary(depth: Int) -> KeybindingWhen? {
            var nots = 0
            while index < tokens.count, tokens[index] == .not {
                index += 1; nots += 1
                guard nots <= KeybindingWhen.maxDepth else { return nil }
            }
            guard var node = parsePrimary(depth: depth) else { return nil }
            for _ in 0..<nots { node = .not(node) }
            return node
        }
        mutating func parsePrimary(depth: Int) -> KeybindingWhen? {
            guard depth <= KeybindingWhen.maxDepth, index < tokens.count else { return nil }
            switch tokens[index] {
            case .identifier(let name): index += 1; return .identifier(name)
            case .lparen:
                index += 1
                guard let node = parseOr(depth: depth + 1), index < tokens.count, tokens[index] == .rparen else { return nil }
                index += 1; return node
            default: return nil
            }
        }
    }
}

/// Boolean focus and surface state for `when` evaluation. Missing keys are false.
public struct KeybindingContext: Hashable, Sendable {
    public var values: [String: Bool]
    public init(_ values: [String: Bool] = [:]) { self.values = values }
    public subscript(name: String) -> Bool {
        get { values[name] ?? false }
        set { values[name] = newValue }
    }
    /// The state used for menu and palette labels: the desktop app with chat focus and nothing else open.
    public static let menu = KeybindingContext(["isDesktop": true])

    /// Every context key T3 documents, plus Coincide's own surface keys.
    public static let knownIdentifiers: [String] = [
        "terminalFocus", "terminalOpen", "isWeb", "isDesktop", "true", "false",
        "composerFocus", "composerDraft", "turnRunning", "editableFocus", "modelPickerOpen",
        "previewFocus", "previewOpen", "usagePageOpen", "rightPanelOpen", "draftThreadRoute",
        "inspectorOpen", "fileEditorFocus", "commandPaletteOpen", "threadFindOpen",
    ]
    public static func unknownIdentifiers(in node: KeybindingWhen?) -> [String] {
        guard let node else { return [] }
        let known = Set(knownIdentifiers)
        return node.identifiers.filter { !known.contains($0) }.sorted()
    }
}
