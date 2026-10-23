import Foundation
import Yams

struct ClaudeSkillMetadata {
    var name: String?
    var description = ""
    var userInvocable = true
    var userInvocationOnly = false
    static func read(path: String) throws -> Self? {
        guard let bytes = try ClaudeSkillFiles.read(path, maximum: 65_536, prefix: true) else { return nil }
        guard bytes.starts(with: Data("---\n".utf8)) || bytes.starts(with: Data("---\r\n".utf8)) else { return .init() }
        // Decode only the header. An arbitrary/incomplete UTF-8 body suffix is
        // never parsed or copied into the catalog.
        let lines = bytes.split(separator: 10, omittingEmptySubsequences: false)
        var header = Data(), found = false
        for line in lines.dropFirst() {
            let clean = line.last == 13 ? line.dropLast() : line[...]
            if clean == Data("---".utf8) { found = true; break }
            header.append(contentsOf: line); header.append(10)
        }
        if !found, bytes.count <= 65_536 { return .init() }
        guard found, header.count <= 65_536, let source = String(data: header, encoding: .utf8) else { throw ProviderSkillError(.invalidResponse) }
        let node: Node
        let resolver = try Resolver.default.removing(.bool).removing(.timestamp).appending(.bool, "^(?:true|True|TRUE|false|False|FALSE)$")
        do { try ClaudeSkillYAMLBounds.validate(source); guard let value = try compose(yaml: source, resolver, .default, .utf8) else { throw ProviderSkillError(.invalidResponse) }; node = value }
        catch is CancellationError { throw CancellationError() }
        catch {
            let repaired = try repairColonScalars(source); try ClaudeSkillYAMLBounds.validate(repaired)
            guard let value = try compose(yaml: repaired, resolver, .default, .utf8) else { throw ProviderSkillError(.invalidResponse) }; node = value
        }
        var budget = 4_096
        try validate(node, depth: 0, budget: &budget)
        guard case .mapping(let mapping) = node else { throw ProviderSkillError(.invalidResponse) }
        var result = Self(), seen = Set<String>()
        for pair in mapping {
            guard case .scalar(let key) = pair.key else { continue }
            guard seen.insert(key.string).inserted else { throw ProviderSkillError(.invalidResponse) }
            guard case .scalar(let scalar) = pair.value else { continue }
            let text = scalar.string.trimmingCharacters(in: .whitespacesAndNewlines)
            switch key.string {
            case "name": if pair.value.tag.rawValue == Tag.Name.str.rawValue, !text.isEmpty { result.name = text }
            case "description": if pair.value.tag.rawValue == Tag.Name.str.rawValue { result.description = text }
            case "user-invocable": if boolean(pair.value) == false { result.userInvocable = false }
            case "disable-model-invocation": result.userInvocationOnly = boolean(pair.value) == true
            default: break
            }
        }
        try SkillValidation.text(result.description, maximum: 16_384, multiline: true)
        return result
    }
    private static func validate(_ node: Node, depth: Int, budget: inout Int) throws {
        guard depth <= 32, budget > 0 else { throw ProviderSkillError(.invalidResponse) }; budget -= 1
        switch node {
        case .scalar(let value): guard value.string.utf8.count <= 65_536 else { throw ProviderSkillError(.invalidResponse) }
        case .sequence(let values): for value in values { try validate(value, depth: depth + 1, budget: &budget) }
        case .mapping(let values): for pair in values { try validate(pair.key, depth: depth + 1, budget: &budget); try validate(pair.value, depth: depth + 1, budget: &budget) }
        case .alias: throw ProviderSkillError(.invalidResponse)
        }
    }
    private static func boolean(_ node: Node) -> Bool? {
        if node.tag.rawValue == Tag.Name.int.rawValue, let value = node.int { return value == 1 ? true : value == 0 ? false : nil }
        if node.tag.rawValue == Tag.Name.float.rawValue, let value = node.float { return value == 1 ? true : value == 0 ? false : nil }
        return switch node.string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() { case "true", "yes", "on", "y": true; case "false", "no", "off", "n": false; default: nil }
    }
    private static func repairColonScalars(_ text: String) throws -> String {
        let pattern = try NSRegularExpression(pattern: #"(?m)^([\w-]+:[ \t]*)([^\r\n]*)"#), source = text as NSString
        let result = NSMutableString(string: text)
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let raw = source.substring(with: match.range(at: 2))
            let comment = try NSRegularExpression(pattern: #"[ \t]+#"#).firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length))
            let scalar = (raw as NSString).substring(to: comment?.range.location ?? (raw as NSString).length)
            guard scalar.range(of: #":[ \t]"#, options: .regularExpression) != nil,
                  scalar.range(of: #"^(?:[\"'\[\]{}|>&*!#%@`]|[-?:](?:[ \t]|$))"#, options: .regularExpression) == nil else { continue }
            let encoded = try JSONSerialization.data(withJSONObject: scalar, options: [.fragmentsAllowed])
            guard let quoted = String(data: encoded, encoding: .utf8) else { throw ProviderSkillError(.invalidResponse) }
            result.replaceCharacters(in: match.range(at: 2), with: quoted + String(raw.dropFirst(scalar.count)))
        }
        return result as String
    }
}
