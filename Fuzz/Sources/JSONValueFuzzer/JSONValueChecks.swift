import Foundation
import FuzzSupport

enum JSONValueChecks {
    /// The input as one JSON document and, as agents send them, as JSON lines.
    static func run(_ bytes: [UInt8]) {
        if let value = JSONValue.parse(Data(bytes)) { check(value) }
        let text = String(decoding: bytes, as: UTF8.self)
        for line in text.split(separator: "\n").prefix(32) {
            if let value = JSONValue.parse(String(line)) { check(value) }
        }
    }

    static func check(_ value: JSONValue) {
        // Whatever decodes must encode, and read back as the same value.
        let compact = value.compactJSON
        expect(!compact.isEmpty, "compactJSON is empty for \(String(reflecting: value))")
        guard let reparsed = JSONValue.parse(compact) else { fail("compactJSON does not parse: \(compact)") }
        expectEqual(reparsed, value, "compactJSON round trip of \(compact)")
        expectEqual(reparsed.hashValue, value.hashValue, "equal values hash alike: \(compact)")
        expectEqual(reparsed.compactJSON, compact, "compactJSON is stable")
        expectEqual(JSONValue.parse(value.prettyJSON), value, "prettyJSON round trip of \(compact)")

        if case .array = value { expectEqual(value.displayText, compact, "a container displays as compact JSON") }
        if case .object = value { expectEqual(value.displayText, compact, "a container displays as compact JSON") }
        walk(value)
    }

    /// Checks the accessors on every nested value.
    private static func walk(_ value: JSONValue) {
        switch value {
        case .null:
            expect(value.isNull && value.displayText.isEmpty, "null accessors")
        case .bool(let bool):
            expect(value.bool == bool && value.displayText == (bool ? "true" : "false"), "bool accessors")
        case .number(let number):
            checkNumber(value, number)
        case .string(let string):
            expect(value.string == string && value.displayText == string, "string accessors")
        case .array(let array):
            expectEqual(value.array, array, "array accessor")
            expectEqual(value[-1], nil, "index -1")
            expectEqual(value[array.count], nil, "index past the end")
            for (index, element) in array.enumerated() {
                expectEqual(value[index], element, "element \(index)")
                walk(element)
            }
        case .object(let object):
            expectEqual(value.object, object, "object accessor")
            for (key, element) in object {
                expectEqual(value[key], element, "member \(key)")
                // `at` splits on dots and skips empty parts, so only plain keys address one member.
                if !key.isEmpty, !key.contains(".") {
                    expectEqual(value.at(key), element, "at(\(key))")
                    // Code passes literal paths of protocol field names; a key starting with a combining
                    // mark would join the dot before it into one Character.
                    for (inner, innerElement) in element.object ?? [:]
                    where !inner.isEmpty && !inner.contains(".") && inner.unicodeScalars.allSatisfy(\.isASCII) {
                        expectEqual(value.at("\(key).\(inner)"), innerElement, "at(\(key).\(inner))")
                    }
                }
                walk(element)
            }
        }
    }

    private static func checkNumber(_ value: JSONValue, _ number: Double) {
        expectEqual(value.number, number, "number accessor")
        expect(number.isFinite, "a parsed number is finite: \(number)")
        // displayText is how ids and option values are shown and matched, so it must read back exactly.
        let text = value.displayText
        expectEqual(Double(text), number, "displayText \(text) reads back")
        if let exact = value.exactInt {
            expectEqual(Double(exact), number, "exactInt is exact")
        }
        let whole = number == number.rounded(.towardZero)
        if whole, number >= -9_223_372_036_854_775_808, number < 9_223_372_036_854_775_808 {
            expect(value.exactInt != nil, "a whole number in Int's range has an exactInt: \(number)")
        }
        if !whole { expectEqual(value.exactInt, nil, "a fraction has no exactInt") }
        if let int = value.int {
            expectEqual(Double(int), number.rounded(.towardZero), "int rounds toward zero")
        }
    }
}
