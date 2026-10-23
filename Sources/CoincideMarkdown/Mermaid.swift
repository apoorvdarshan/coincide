import Foundation

/// A native subset of Mermaid: flowcharts (`graph`/`flowchart`) and sequence diagrams.
/// Anything outside the subset returns `nil`, and the fence stays readable source.
/// Interaction (`click`), styling and subgraph frames are parsed and ignored; nothing
/// is ever loaded or executed.
public struct MermaidDiagram: Sendable, Equatable {
    public enum Direction: String, Sendable { case topDown = "TD", bottomUp = "BT", leftRight = "LR", rightLeft = "RL" }
    public enum Shape: Sendable { case rectangle, rounded, stadium, circle, diamond, hexagon, subroutine, cylinder }
    public enum Stroke: Sendable { case solid, dotted, thick, invisible }
    public struct Node: Sendable, Equatable { public var id: String; public var label: String; public var shape: Shape }
    public struct Edge: Sendable, Equatable {
        public var from: String, to: String
        public var label: String?
        public var stroke: Stroke
        public var arrowEnd: Bool, arrowStart: Bool
    }
    public struct Participant: Sendable, Equatable { public var id: String; public var label: String; public var actor: Bool }
    public enum Arrow: Sendable { case filled, none, cross, open }
    public enum NotePlacement: Sendable { case left, right, over }
    public enum Event: Sendable, Equatable {
        case message(from: String, to: String, text: String, dashed: Bool, arrow: Arrow, number: Int?)
        case note(NotePlacement, [String], String)
        case frameStart(String, String)
        case frameDivider(String)
        case frameEnd
    }
    public enum Kind: Sendable, Equatable { case flowchart(Direction), sequence }

    public var kind: Kind
    public var nodes: [Node] = []
    public var edges: [Edge] = []
    public var participants: [Participant] = []
    public var events: [Event] = []

    static let maximumSource = 20_000, maximumNodes = 150, maximumEdges = 300, maximumEvents = 300

    public static func parse(_ source: String) -> MermaidDiagram? {
        guard source.utf8.count <= maximumSource else { return nil }
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.first(where: { !$0.isEmpty }) == "---" {
            // Front matter configuration is ignored.
            guard let start = lines.firstIndex(of: "---"), let end = lines[(start + 1)...].firstIndex(of: "---") else { return nil }
            lines.removeSubrange(start...end)
        }
        lines = lines.filter { !$0.isEmpty && !$0.hasPrefix("%%") }
        guard let header = lines.first else { return nil }
        let words = header.split(whereSeparator: \.isWhitespace).map(String.init)
        switch words.first {
        case "graph"?, "flowchart"?:
            let direction: Direction = switch words.dropFirst().first?.uppercased() ?? "TD" {
            case "LR": .leftRight
            case "RL": .rightLeft
            case "BT": .bottomUp
            case "TD", "TB": .topDown
            default: .topDown
            }
            // `graph TD; A-->B` keeps statements on the header line.
            var statements: [String] = []
            for (index, line) in lines.enumerated() {
                let parts = splitStatements(line)
                statements += index == 0 ? Array(parts.dropFirst()) : parts
            }
            return flowchart(direction, statements)
        case "sequenceDiagram"?:
            guard words.count == 1 else { return nil }
            return sequence(Array(lines.dropFirst()))
        default: return nil
        }
    }

    private static func splitStatements(_ line: String) -> [String] {
        var result: [String] = [], current = "", quoted = false, depth = 0
        for character in line {
            if character == "\"" { quoted.toggle() }
            if !quoted { if "[({".contains(character) { depth += 1 } else if "])}".contains(character) { depth = max(0, depth - 1) } }
            if character == ";", !quoted, depth == 0 { result.append(current); current = ""; continue }
            current.append(character)
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: Flowchart

    private static let ignoredFlowchart = ["classDef", "class", "style", "linkStyle", "click", "subgraph", "end", "direction", "accTitle", "accDescr"]

    private static func flowchart(_ direction: Direction, _ statements: [String]) -> MermaidDiagram? {
        var diagram = MermaidDiagram(kind: .flowchart(direction))
        var known: [String: Int] = [:]
        func register(_ node: Node, explicit: Bool) {
            if let index = known[node.id] { if explicit { diagram.nodes[index] = node } }
            else { known[node.id] = diagram.nodes.count; diagram.nodes.append(node) }
        }
        for statement in statements {
            let keyword = statement.prefix { !$0.isWhitespace && $0 != ":" }
            if ignoredFlowchart.contains(String(keyword)) { continue }
            let s = Array(statement)
            var index = 0
            guard var previous = nodeGroup(s, &index) else { return nil }
            for (node, explicit) in previous { register(node, explicit: explicit) }
            while true {
                skipSpaces(s, &index)
                guard index < s.count else { break }
                guard let link = link(s, &index) else { return nil }
                skipSpaces(s, &index)
                guard let next = nodeGroup(s, &index) else { return nil }
                for (node, explicit) in next { register(node, explicit: explicit) }
                for (from, _) in previous {
                    for (to, _) in next {
                        diagram.edges.append(.init(from: from.id, to: to.id, label: link.label, stroke: link.stroke, arrowEnd: link.arrowEnd, arrowStart: link.arrowStart))
                    }
                }
                previous = next
            }
            guard diagram.nodes.count <= maximumNodes, diagram.edges.count <= maximumEdges else { return nil }
        }
        return diagram.nodes.isEmpty ? nil : diagram
    }

    private static func skipSpaces(_ s: [Character], _ index: inout Int) { while index < s.count, s[index].isWhitespace { index += 1 } }

    private static func nodeGroup(_ s: [Character], _ index: inout Int) -> [(Node, Bool)]? {
        var result: [(Node, Bool)] = []
        repeat {
            skipSpaces(s, &index)
            guard let node = node(s, &index) else { return nil }
            result.append(node)
            skipSpaces(s, &index)
            guard index < s.count, s[index] == "&" else { break }
            index += 1
        } while true
        return result
    }

    private static func node(_ s: [Character], _ index: inout Int) -> (Node, Bool)? {
        let start = index
        while index < s.count {
            let character = s[index]
            if character.isLetter || character.isNumber || character == "_" { index += 1; continue }
            if character == "-", index + 1 < s.count, s[index + 1].isLetter || s[index + 1].isNumber { index += 1; continue }
            break
        }
        guard index > start else { return nil }
        let id = String(s[start..<index])
        let shapes: [(String, String, Shape)] = [("[[", "]]", .subroutine), ("[(", ")]", .cylinder), ("([", "])", .stadium), ("((", "))", .circle), ("{{", "}}", .hexagon),
                                                 ("[/", "/]", .rectangle), ("[\\", "\\]", .rectangle), ("[/", "\\]", .rectangle), ("[\\", "/]", .rectangle),
                                                 ("[", "]", .rectangle), ("(", ")", .rounded), ("{", "}", .diamond), (">", "]", .rectangle)]
        for (open, close, shape) in shapes {
            let o = Array(open), c = Array(close)
            guard index + o.count <= s.count, Array(s[index..<(index + o.count)]) == o else { continue }
            var cursor = index + o.count, quoted = false
            while cursor + c.count <= s.count {
                if s[cursor] == "\"" { quoted.toggle() }
                if !quoted, Array(s[cursor..<(cursor + c.count)]) == c { break }
                cursor += 1
            }
            guard cursor + c.count <= s.count else { continue }
            let label = cleanLabel(String(s[(index + o.count)..<cursor]))
            index = cursor + c.count
            skipClass(s, &index)
            return (.init(id: id, label: label.isEmpty ? id : label, shape: shape), true)
        }
        skipClass(s, &index)
        return (.init(id: id, label: id, shape: .rectangle), false)
    }

    private static func skipClass(_ s: [Character], _ index: inout Int) {
        guard index + 2 < s.count, s[index] == ":", s[index + 1] == ":", s[index + 2] == ":" else { return }
        index += 3
        while index < s.count, s[index].isLetter || s[index].isNumber || s[index] == "_" || s[index] == "-" { index += 1 }
    }

    static func cleanLabel(_ raw: String) -> String {
        var label = raw.trimmingCharacters(in: .whitespaces)
        if label.count >= 2, let first = label.first, (first == "\"" || first == "`"), label.last == first { label = String(label.dropFirst().dropLast()) }
        if label.count >= 2, label.first == "`", label.last == "`" { label = String(label.dropFirst().dropLast()) }
        label = label.replacingOccurrences(of: #"\s*<br\s*/?>\s*"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        label = label.replacingOccurrences(of: #"</?[A-Za-z][^>]*>"#, with: "", options: .regularExpression)
        return MarkdownHTML.decodeEntities(label.replacingOccurrences(of: #"#quot;"#, with: "\"")).trimmingCharacters(in: .whitespaces)
    }

    struct Link { var label: String?; var stroke: Stroke; var arrowEnd: Bool; var arrowStart: Bool }

    /// `-->`, `---`, `-.->`, `==>`, `~~~`, `<-->`, `--o`, `--x`, `-- text -->` and `-->|text|`.
    private static func link(_ s: [Character], _ index: inout Int) -> Link? {
        var cursor = index, arrowStart = false
        if cursor < s.count, s[cursor] == "<" { arrowStart = true; cursor += 1 }
        let strokeStart = cursor
        while cursor < s.count, "-=.~".contains(s[cursor]) { cursor += 1 }
        var stroke = String(s[strokeStart..<cursor])
        guard stroke.count >= 2 else { return nil }
        var label: String?, arrowEnd = false
        if cursor < s.count, ">ox".contains(s[cursor]), cursor + 1 >= s.count || !(s[cursor + 1].isLetter || s[cursor + 1].isNumber) || s[cursor] == ">" {
            arrowEnd = true; cursor += 1
        } else if ["--", "==", "-."].contains(stroke), cursor < s.count, s[cursor].isWhitespace {
            // Text between an opening stroke and the closing arrow.
            let textStart = cursor
            var search = cursor, found: (Int, Int)?
            while search + 1 < s.count {
                if "-=.".contains(s[search]), "-=.>".contains(s[search + 1]), search > textStart, s[search - 1].isWhitespace {
                    var end = search
                    while end < s.count, "-=.".contains(s[end]) { end += 1 }
                    if end < s.count, s[end] == ">" { end += 1 }
                    if end - search >= 2 { found = (search, end); break }
                }
                search += 1
            }
            guard let (closeStart, closeEnd) = found else { return nil }
            label = cleanLabel(String(s[textStart..<closeStart]))
            stroke += String(s[closeStart..<closeEnd])
            arrowEnd = s[closeEnd - 1] == ">"
            cursor = closeEnd
        }
        skipSpaces(s, &cursor)
        if cursor < s.count, s[cursor] == "|" {
            guard let close = s[(cursor + 1)...].firstIndex(of: "|") else { return nil }
            label = cleanLabel(String(s[(cursor + 1)..<close])); cursor = close + 1
        }
        index = cursor
        let kind: Stroke = stroke.hasPrefix("~") ? .invisible : stroke.contains("=") ? .thick : stroke.contains(".") ? .dotted : .solid
        return Link(label: label?.isEmpty == true ? nil : label, stroke: kind, arrowEnd: arrowEnd, arrowStart: arrowStart)
    }

    // MARK: Sequence

    private static let arrows: [(String, Bool, Arrow)] = [("-->>", true, .filled), ("->>", false, .filled), ("--x", true, .cross), ("-x", false, .cross),
                                                          ("--)", true, .open), ("-)", false, .open), ("-->", true, .none), ("->", false, .none)]

    private static func sequence(_ statements: [String]) -> MermaidDiagram? {
        var diagram = MermaidDiagram(kind: .sequence)
        var number: Int?, frames = 0
        func participant(_ id: String, label: String? = nil, actor: Bool = false) {
            if let index = diagram.participants.firstIndex(where: { $0.id == id }) {
                if let label { diagram.participants[index].label = label }
                if actor { diagram.participants[index].actor = true }
            } else { diagram.participants.append(.init(id: id, label: label ?? id, actor: actor)) }
        }
        for raw in statements.flatMap(splitStatements) {
            let statement = raw.hasPrefix("create ") ? String(raw.dropFirst(7)) : raw
            let lower = statement.lowercased()
            let first = lower.split(separator: " ").first.map(String.init) ?? ""
            switch first {
            case "participant", "actor":
                let rest = statement.dropFirst(first.count).trimmingCharacters(in: .whitespaces)
                guard !rest.isEmpty else { return nil }
                if let alias = rest.range(of: " as ") {
                    participant(cleanLabel(String(rest[..<alias.lowerBound])), label: cleanLabel(String(rest[alias.upperBound...])), actor: first == "actor")
                } else { participant(cleanLabel(rest), actor: first == "actor") }
            case "autonumber": number = 1
            case "title", "activate", "deactivate", "accTitle", "acctitle", "accdescr", "links", "link", "properties", "details": continue
            case "note":
                guard let colon = statement.firstIndex(of: ":") else { return nil }
                let head = statement[..<colon].split(whereSeparator: \.isWhitespace).dropFirst().map(String.init)
                let text = cleanLabel(String(statement[statement.index(after: colon)...]))
                let placement: NotePlacement
                var targets: String
                if head.count >= 3, head[0].lowercased() == "left" || head[0].lowercased() == "right", head[1].lowercased() == "of" {
                    placement = head[0].lowercased() == "left" ? .left : .right; targets = head[2...].joined(separator: " ")
                } else if head.count >= 2, head[0].lowercased() == "over" { placement = .over; targets = head[1...].joined(separator: " ") }
                else { return nil }
                targets = targets.trimmingCharacters(in: .whitespaces)
                let ids = targets.split(separator: ",").map { cleanLabel(String($0)) }.filter { !$0.isEmpty }
                guard !ids.isEmpty, ids.count <= 2 else { return nil }
                ids.forEach { participant($0) }
                diagram.events.append(.note(placement, ids, text))
            case "loop", "alt", "opt", "par", "critical", "break", "rect", "box":
                frames += 1
                let label = statement.dropFirst(first.count).trimmingCharacters(in: .whitespaces)
                diagram.events.append(.frameStart(first, first == "rect" || first == "box" ? "" : cleanLabel(label)))
            case "else", "and", "option":
                guard frames > 0 else { return nil }
                diagram.events.append(.frameDivider(cleanLabel(statement.dropFirst(first.count).trimmingCharacters(in: .whitespaces))))
            case "end":
                guard frames > 0 else { return nil }
                frames -= 1; diagram.events.append(.frameEnd)
            default:
                guard let message = message(statement) else { return nil }
                participant(message.from); participant(message.to)
                diagram.events.append(.message(from: message.from, to: message.to, text: message.text, dashed: message.dashed, arrow: message.arrow, number: number))
                if let current = number { number = current + 1 }
            }
            guard diagram.events.count <= maximumEvents, diagram.participants.count <= 40 else { return nil }
        }
        while frames > 0 { diagram.events.append(.frameEnd); frames -= 1 }
        return diagram.participants.isEmpty ? nil : diagram
    }

    private static func message(_ statement: String) -> (from: String, to: String, text: String, dashed: Bool, arrow: Arrow)? {
        let head: Substring, text: String
        if let colon = statement.firstIndex(of: ":") { head = statement[..<colon]; text = cleanLabel(String(statement[statement.index(after: colon)...])) }
        else { head = statement[...]; text = "" }
        // Bidirectional `<<->>` arrows draw with their forward head.
        let normalized = String(head).replacingOccurrences(of: "<<", with: "")
        for (token, dashed, arrow) in arrows {
            guard let range = normalized.range(of: token) else { continue }
            let from = normalized[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let to = normalized[range.upperBound...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "+-")).trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty, !to.isEmpty, !from.contains(" ") || from.hasPrefix("\""), !to.contains(" ") || to.hasPrefix("\"") else { return nil }
            return (cleanLabel(from), cleanLabel(to), text, dashed, arrow)
        }
        return nil
    }
}
