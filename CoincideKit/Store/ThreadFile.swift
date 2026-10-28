import Foundation

extension CodingUserInfoKey {
    /// Set to true to have `ThreadFile` look for everything this version could not read
    /// (`hasUnreadContent`), not only for items it left out.
    static let checksUnreadContent = CodingUserInfoKey(rawValue: "coincide.checksUnreadContent")!
}

/// A thread file as read: the thread, and whether the file holds anything this version could not read.
///
/// Decoding is lenient (see `ChatThread.init(from:)`), so a file written by a newer version loads without
/// items of a kind added later, sessions of a provider this version does not know, and fields it does not
/// know or cannot read. Saving the thread would drop all of that, so before the store first replaces a
/// file it reads it again with `checksUnreadContent` and copies it aside if needed. That check visits every
/// item, so loading skips it. Items left out shift positions, so each session's `seenItemCount` is always
/// adjusted to count only the items that were kept.
struct ThreadFile: Decodable {
    var thread: ChatThread
    /// The file holds something that saving `thread` would not write back. Only looked for when the
    /// decoder's `checksUnreadContent` is true; items left out are always noticed.
    var hasUnreadContent = false

    nonisolated init(from decoder: Decoder) throws {
        thread = try ChatThread(from: decoder)
        let container = try decoder.container(keyedBy: FileKey.self)
        let checksFields = decoder.userInfo[.checksUnreadContent] as? Bool == true
        var unread = false
        var skippedItems: [Int] = []
        // Counting the items is cheap; pairing them up only happens when some were left out.
        if var items = try? container.nestedUnkeyedContainer(forKey: FileKey("items")),
            checksFields || items.count != thread.items.count
        {
            skippedItems = Self.skippedItems(in: &items, decoded: thread.items, checksFields: checksFields, unread: &unread)
        }
        if checksFields {
            for key in container.allKeys where !container.isNull(key) {
                switch key.stringValue {
                case "items":
                    if (try? container.nestedUnkeyedContainer(forKey: key)) == nil { unread = true }
                case "sessions":
                    if !Self.readsSessions(in: container, key, decoded: thread.sessions) { unread = true }
                default:
                    if !Self.readsThreadField(container, key) { unread = true }
                }
            }
        }
        if !skippedItems.isEmpty {
            unread = true
            for (kind, var ref) in thread.sessions {
                ref.seenItemCount -= skippedItems.prefix { $0 < ref.seenItemCount }.count
                thread.sessions[kind] = ref
            }
        }
        hasUnreadContent = unread
    }

    private typealias Container = KeyedDecodingContainer<FileKey>

    nonisolated static let selectionKeys: Set<String> = ["provider", "modelID", "effort"]
    nonisolated static let sessionKeys: Set<String> = ["sessionID", "seenItemCount"]

    /// Whether this version reads a top-level field other than the items and sessions. False for a field
    /// it does not know.
    private nonisolated static func readsThreadField(_ container: Container, _ key: FileKey) -> Bool {
        switch key.stringValue {
        case "id", "projectID": container.reads(UUID.self, key)
        case "title", "worktreePath", "branch", "draft": container.reads(String.self, key)
        case "createdAt", "updatedAt", "snoozedUntil": container.reads(Date.self, key)
        case "accessMode": container.reads(AccessMode.self, key)
        case "interactionMode": container.reads(InteractionMode.self, key)
        case "isPinned", "isArchived": container.reads(Bool.self, key)
        case "selection":
            container.reads(ModelSelection.self, key)
                && (try? container.nestedContainer(keyedBy: FileKey.self, forKey: key))?.hasOnly(selectionKeys) == true
        default: false
        }
    }

    /// Positions (in the file) of the items that were left out. With `checksFields`, also sets `unread` when
    /// a kept item has a field this version does not know or could not read. Sets it as well when the items
    /// cannot be walked to the end.
    private nonisolated static func skippedItems(
        in array: inout UnkeyedDecodingContainer, decoded: [TranscriptItem], checksFields: Bool, unread: inout Bool
    ) -> [Int] {
        var skipped: [Int] = []
        var next = 0
        // When every item was kept, they pair up by position; otherwise by id.
        let keptAll = array.count == decoded.count
        while !array.isAtEnd {
            let position = array.currentIndex
            if let item = try? array.nestedContainer(keyedBy: FileKey.self) {
                if next < decoded.count,
                    keptAll || (try? item.decode(UUID.self, forKey: FileKey("id"))) == decoded[next].id
                {
                    if checksFields, !reads(item, as: decoded[next]) { unread = true }
                    next += 1
                } else {
                    skipped.append(position)
                }
                continue
            }
            skipped.append(position)
            // Not an object: step over it, unless the failed read already did.
            if array.currentIndex == position, (try? array.decode(AnyValue.self)) == nil {
                unread = true
                break
            }
        }
        return skipped
    }

    /// Whether every field of an item in the file made it into the decoded item. A null counts as read.
    private nonisolated static func reads(_ item: Container, as decoded: TranscriptItem) -> Bool {
        for key in item.allKeys {
            let read =
                switch key.stringValue {
                case "id", "kind": true
                // Fields that fall back to a value rather than nil are read again only when they did.
                case "text": !decoded.text.isEmpty || item.reads(String.self, key)
                case "createdAt": decoded.createdAt != .distantPast || item.reads(Date.self, key)
                case "title": decoded.title != nil
                case "detail": decoded.detail != nil
                case "category": decoded.category != nil
                case "status": decoded.status != nil
                case "provider": decoded.provider != nil
                case "modelID": decoded.modelID != nil
                case "externalID": decoded.externalID != nil
                case "approval": decoded.approval != nil
                case "questions": decoded.questions != nil
                case "answers": decoded.answers != nil
                case "attachments": decoded.attachments != nil
                case "steered": decoded.steered != nil
                case "completedAt": decoded.completedAt != nil
                default: false
                }
            if !read, !item.isNull(key) { return false }
        }
        return true
    }

    /// Whether every session in the file made it into the decoded sessions. Swift writes a dictionary keyed
    /// by an enum as alternating keys and values; a keyed object is read too.
    private nonisolated static func readsSessions(
        in container: Container, _ key: FileKey, decoded: [ProviderKind: ProviderSessionRef]
    ) -> Bool {
        if var array = try? container.nestedUnkeyedContainer(forKey: key) {
            var count = 0
            while !array.isAtEnd {
                guard (try? array.decode(String.self)) != nil, !array.isAtEnd,
                    let value = try? array.nestedContainer(keyedBy: FileKey.self), value.hasOnly(sessionKeys)
                else { return false }
                count += 1
            }
            return count == decoded.count
        }
        guard let keyed = try? container.nestedContainer(keyedBy: FileKey.self, forKey: key) else { return false }
        for provider in keyed.allKeys {
            guard let value = try? keyed.nestedContainer(keyedBy: FileKey.self, forKey: provider), value.hasOnly(sessionKeys)
            else { return false }
        }
        return keyed.allKeys.count == decoded.count
    }
}

/// Any key of a JSON object.
struct FileKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    nonisolated init(_ stringValue: String) { self.stringValue = stringValue }
    nonisolated init?(stringValue: String) { self.stringValue = stringValue }
    nonisolated init?(intValue: Int) { nil }
}

/// Any JSON value, read without looking at it.
private struct AnyValue: Decodable {
    nonisolated init(from decoder: Decoder) throws {}
}

extension KeyedDecodingContainer where Key == FileKey {
    fileprivate nonisolated func isNull(_ key: Key) -> Bool {
        (try? decodeNil(forKey: key)) ?? false
    }

    fileprivate nonisolated func reads<T: Decodable>(_ type: T.Type, _ key: Key) -> Bool {
        (try? decode(type, forKey: key)) != nil
    }

    /// Whether every key with a value is one of `known`.
    fileprivate nonisolated func hasOnly(_ known: Set<String>) -> Bool {
        allKeys.allSatisfy { known.contains($0.stringValue) || isNull($0) }
    }
}
