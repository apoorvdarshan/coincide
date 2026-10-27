import Foundation

/// Decoding helpers that keep as much of a saved file as possible. A thread written by a newer version
/// (an unknown provider, status or item kind) or damaged by hand still loads, minus what this version
/// cannot read, instead of disappearing.
extension KeyedDecodingContainer {
    /// The value, or nil when it is missing or unreadable.
    nonisolated func lenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// The elements that decode, skipping those that do not.
    nonisolated func lenientArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        guard var array = try? nestedUnkeyedContainer(forKey: key) else { return [] }
        var result: [T] = []
        while !array.isAtEnd {
            if let element = try? array.decode(T.self) {
                result.append(element)
            } else if (try? array.decode(JSONValue.self)) == nil {
                break
            }
        }
        return result
    }

    /// A dictionary keyed by provider, as Swift encodes it (alternating keys and values), skipping
    /// providers this version does not know and values it cannot read.
    nonisolated func lenientProviderMap<T: Decodable>(_ type: T.Type, forKey key: Key) -> [ProviderKind: T] {
        if var array = try? nestedUnkeyedContainer(forKey: key) {
            var result: [ProviderKind: T] = [:]
            while !array.isAtEnd {
                guard let raw = try? array.decode(String.self), !array.isAtEnd else { break }
                if let value = try? array.decode(T.self) {
                    if let kind = ProviderKind(rawValue: raw) { result[kind] = value }
                } else if (try? array.decode(JSONValue.self)) == nil {
                    break
                }
            }
            return result
        }
        let keyed = lenient([String: T].self, forKey: key) ?? [:]
        return Dictionary(keyed.compactMap { key, value in ProviderKind(rawValue: key).map { ($0, value) } }) { first, _ in first }
    }
}
