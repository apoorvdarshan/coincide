import Foundation

public struct ClaudeSkillDispatchPlan: Sendable, Equatable {
    public let leadingText: String?
    public let commandText: String
    public let skillName: String
}

public enum ClaudeSkillDispatch {
    /// Match pinned T3's currency-prefixed token grammar exactly. Only known,
    /// enabled, explicitly user-invocable skills are lowered; no body is copied.
    public static func plan(text: String, skills: [ProviderSkill]) throws -> ClaudeSkillDispatchPlan? {
        guard text.utf8.count <= 16 * 1_024 * 1_024 else { throw ProviderSkillError(.invalidResponse) }
        var names: [String: ProviderSkill] = [:]
        for skill in skills where skill.canInvokeFromComposer { if names[skill.name] == nil { names[skill.name] = skill } }
        let expression = try NSRegularExpression(pattern: #"(^|\s)\p{Sc}(?![0-9][0-9_]*(?:[kKmMbBtT]|[eE][0-9]+)?(?:\s|$))(?=[a-zA-Z0-9:_-]*[a-zA-Z])([a-zA-Z0-9][a-zA-Z0-9:_-]*)(?=\s|$)"#)
        let source = text as NSString
        struct Mention { let start: Int, end: Int; let name: String; let skill: ProviderSkill }
        let mentions = expression.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match -> Mention? in
            let name = source.substring(with: match.range(at: 2)); guard let skill = names[name] else { return nil }
            return .init(start: match.range.location + match.range(at: 1).length, end: NSMaxRange(match.range), name: name, skill: skill)
        }
        guard let last = mentions.last else { return nil }
        var annotated = Set([last.name]), rewritten = "", cursor = 0
        for mention in mentions {
            rewritten += source.substring(with: NSRange(location: cursor, length: mention.start - cursor)) + "/" + mention.name
            if mention.skill.userInvocationOnly, annotated.insert(mention.name).inserted {
                rewritten += " [The user invoked this skill. Follow the instructions at: \(mention.skill.path)]"
            }
            cursor = mention.end
        }
        rewritten += source.substring(from: cursor)
        let leading = source.substring(to: last.start).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : trimEnd(rewritten)
        return .init(leadingText: leading, commandText: trimEnd("/" + last.name + source.substring(from: last.end)), skillName: last.name)
    }
    private static func trimEnd(_ value: String) -> String {
        var end = value.endIndex
        while end > value.startIndex { let previous = value.index(before: end); guard value[previous].isWhitespace else { break }; end = previous }
        return String(value[..<end])
    }
}

extension ClaudeSkillDispatch {
    static func content(input: ProviderInput, plan: ClaudeSkillDispatchPlan?) throws -> JSONValue {
        let images: [JSONValue] = input.images.map { image in
            .object(["type": .string("image"), "source": .object(["type": .string("base64"),
                "media_type": .string(image.mimeType), "data": .string(image.data.base64EncodedString())])])
        }
        guard let plan else {
            if input.images.isEmpty && input.historicalContext == nil { return .string(input.text) }
            return .array(images + (try input.providerTextBlocks()).map { .object(["type": .string("text"), "text": .string($0)]) })
        }
        var blocks: [JSONValue] = []
        if let historical = input.historicalContext { try historical.validate(); blocks.append(.object(["type": .string("text"), "text": .string(historical.selection.renderedText)])) }
        if let leading = plan.leadingText { blocks.append(.object(["type": .string("text"), "text": .string(leading)])) }
        blocks += images
        blocks.append(.object(["type": .string("text"), "text": .string(plan.commandText)]))
        return .array(blocks)
    }
}
