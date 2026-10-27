import Foundation

/// A loosely typed JSON value used for agent wire protocols, where payloads vary
/// between providers and versions.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public nonisolated subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public nonisolated subscript(index: Int) -> JSONValue? {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        return nil
    }

    /// Follows a dotted path such as `"params.item.type"`.
    public nonisolated func at(_ path: String) -> JSONValue? {
        var current: JSONValue? = self
        for key in path.split(separator: ".") {
            current = current?[String(key)]
        }
        return current
    }

    public nonisolated var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public nonisolated var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// The number as an Int, rounded toward zero, or nil when it is not finite or does not fit.
    public nonisolated var int: Int? {
        guard let number, number.isFinite, number >= -9.2e18, number <= 9.2e18 else { return nil }
        return Int(number)
    }

    /// The number as an Int only when it is a whole number in range, for ids that must match exactly
    /// (a JSON-RPC response id of 1.5 answers no request).
    public nonisolated var exactInt: Int? {
        guard let number, number.isFinite, number.rounded(.towardZero) == number else { return nil }
        return Int(exactly: number)
    }

    public nonisolated var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public nonisolated var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public nonisolated var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public nonisolated var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Renders a scalar as text, or the value as compact JSON otherwise.
    public nonisolated var displayText: String {
        switch self {
        case .null: return ""
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            // A whole number past Int64's range (an id of 1e19, say) keeps its floating-point spelling.
            if value.rounded() == value, let integer = Int64(exactly: value) { return String(integer) }
            return String(value)
        case .string(let value): return value
        case .array, .object: return compactJSON
        }
    }

    public nonisolated var compactJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public nonisolated var prettyJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public nonisolated static func parse(_ line: String) -> JSONValue? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    public nonisolated static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public nonisolated init(stringLiteral value: String) { self = .string(value) }
    public nonisolated init(booleanLiteral value: Bool) { self = .bool(value) }
    public nonisolated init(integerLiteral value: Int) { self = .number(Double(value)) }
    public nonisolated init(floatLiteral value: Double) { self = .number(value) }
    public nonisolated init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public nonisolated init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public nonisolated init(nilLiteral: ()) { self = .null }
}
