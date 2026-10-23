import CYaml
import Foundation

/// The native event parser is iterative. Reject excessive structure before
/// Yams' recursive composer sees it; the second AST budget bounds alias copies.
enum ClaudeSkillYAMLBounds {
    static func validate(_ text: String) throws {
        guard !text.isEmpty, text.utf8.count <= 65_536 else { throw ProviderSkillError(.invalidResponse) }
        var parser = yaml_parser_t()
        guard yaml_parser_initialize(&parser) == 1 else { throw ProviderSkillError(.unavailable) }
        defer { yaml_parser_delete(&parser) }
        let bytes = Array(text.utf8)
        try bytes.withUnsafeBufferPointer { buffer in
            yaml_parser_set_input_string(&parser, buffer.baseAddress, buffer.count)
            struct Frame { var size = 1; let anchor: String? }
            var frames: [Frame] = [], anchors: [String: Int] = [:]
            var depth = 0, nodes = 0, aliases = 0, documents = 0, rootSize = 0
            func add(_ count: Int) throws {
                if frames.isEmpty { rootSize += count; guard rootSize <= 4_096 else { throw ProviderSkillError(.invalidResponse) } }
                else { frames[frames.count - 1].size += count; guard frames.last!.size <= 4_096 else { throw ProviderSkillError(.invalidResponse) } }
            }
            while true {
                try Task.checkCancellation()
                var event = yaml_event_t()
                guard yaml_parser_parse(&parser, &event) == 1 else { throw ProviderSkillError(.invalidResponse) }
                defer { yaml_event_delete(&event) }
                switch event.type {
                case YAML_STREAM_END_EVENT: return
                case YAML_DOCUMENT_START_EVENT: documents += 1
                case YAML_SEQUENCE_START_EVENT, YAML_MAPPING_START_EVENT:
                    depth += 1; nodes += 1
                    let pointer = event.type == YAML_SEQUENCE_START_EVENT ? event.data.sequence_start.anchor : event.data.mapping_start.anchor
                    frames.append(.init(anchor: pointer.map { String(cString: $0) }))
                case YAML_SEQUENCE_END_EVENT, YAML_MAPPING_END_EVENT:
                    depth -= 1; guard let frame = frames.popLast() else { throw ProviderSkillError(.invalidResponse) }
                    if let anchor = frame.anchor { anchors[anchor] = frame.size }; try add(frame.size)
                case YAML_SCALAR_EVENT:
                    nodes += 1; if let anchor = event.data.scalar.anchor { anchors[String(cString: anchor)] = 1 }; try add(1)
                case YAML_ALIAS_EVENT:
                    aliases += 1; nodes += 1
                    guard let anchor = event.data.alias.anchor, let size = anchors[String(cString: anchor)] else { throw ProviderSkillError(.invalidResponse) }
                    try add(size)
                default: break
                }
                guard depth >= 0, depth <= 32, nodes <= 4_096, aliases <= 64, documents <= 1 else { throw ProviderSkillError(.invalidResponse) }
            }
        }
    }
}
