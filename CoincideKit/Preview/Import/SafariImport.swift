import Foundation

/// Reads WebKit browsers' data: cookies in the `Cookies.binarycookies` format, Safari's `History.db` and
/// `Bookmarks.plist`. Safari's folders are protected; without Full Disk Access reads fail with `EPERM`, which is
/// reported as `SQLiteSnapshot.Failure.permissionDenied` rather than as missing data.
public nonisolated enum SafariDataReader {
    enum Failure: Error { case malformed }

    // MARK: Cookies.binarycookies

    /// The file: "cook", a big-endian page count and page sizes, then pages. Each page starts 00 00 01 00 and lists
    /// little-endian cookie offsets; each cookie record has its flags, string offsets and Mac-epoch dates.
    static func parseBinaryCookies(_ data: Data) throws -> [ImportedCookie] {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0..<4] == [0x63, 0x6F, 0x6F, 0x6B] else { throw Failure.malformed }
        let pageCount = Int(try bigEndian(bytes, 4))
        guard pageCount < 100_000, bytes.count >= 8 + pageCount * 4 else { throw Failure.malformed }
        var sizes: [Int] = []
        for page in 0..<pageCount { sizes.append(Int(try bigEndian(bytes, 8 + page * 4))) }
        var offset = 8 + pageCount * 4
        var cookies: [ImportedCookie] = []
        for size in sizes {
            guard size >= 8, offset + size <= bytes.count else { throw Failure.malformed }
            let page = Array(bytes[offset..<(offset + size)])
            offset += size
            guard page[0..<4] == [0x00, 0x00, 0x01, 0x00] else { throw Failure.malformed }
            let count = Int(try littleEndian(page, 4))
            guard count < 100_000, page.count >= 8 + count * 4 else { throw Failure.malformed }
            for index in 0..<count {
                let start = Int(try littleEndian(page, 8 + index * 4))
                if let cookie = try parseCookie(page, at: start) { cookies.append(cookie) }
            }
        }
        return cookies
    }

    private static func parseCookie(_ page: [UInt8], at start: Int) throws -> ImportedCookie? {
        guard start >= 0, start + 56 <= page.count else { throw Failure.malformed }
        let size = Int(try littleEndian(page, start))
        guard size >= 56, start + size <= page.count else { throw Failure.malformed }
        let record = Array(page[start..<(start + size)])
        let flags = try littleEndian(record, 8)
        func string(at field: Int) throws -> String {
            let position = Int(try littleEndian(record, field))
            guard position >= 56, position < record.count else { throw Failure.malformed }
            let end = record[position...].firstIndex(of: 0) ?? record.count
            return String(decoding: record[position..<end], as: UTF8.self)
        }
        let domain = try string(at: 16), name = try string(at: 20), path = try string(at: 24), value = try string(at: 28)
        guard !domain.isEmpty, !name.isEmpty else { return nil }
        let expiry = record.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt64.self) }
        return ImportedCookie(
            domain: domain, name: name, value: value, path: path,
            expires: BrowserTime.safari(Double(bitPattern: UInt64(littleEndian: expiry))),
            isSecure: flags & 1 != 0, isHTTPOnly: flags & 4 != 0, sameSite: nil)
    }

    private static func bigEndian(_ bytes: [UInt8], _ at: Int) throws -> UInt32 {
        guard at >= 0, at + 4 <= bytes.count else { throw Failure.malformed }
        return bytes[at..<(at + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func littleEndian(_ bytes: [UInt8], _ at: Int) throws -> UInt32 {
        guard at >= 0, at + 4 <= bytes.count else { throw Failure.malformed }
        return bytes[at..<(at + 4)].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func cookies(at file: URL) throws -> [ImportedCookie] {
        let handle = open(file.path, O_RDONLY)
        if handle < 0 {
            if errno == ENOENT { return [] }
            throw errno == EPERM || errno == EACCES ? SQLiteSnapshot.Failure.permissionDenied : SQLiteSnapshot.Failure.unreadable
        }
        close(handle)
        return try parseBinaryCookies(try Data(contentsOf: file))
    }

    // MARK: History and bookmarks

    static func history(at file: URL, limit: Int) throws -> [BrowserHistoryItem] {
        let snapshot = try SQLiteSnapshot(copying: file)
        defer { snapshot.close() }
        return try snapshot.rows(
            """
            SELECT i.url AS url, i.visit_count AS visit_count, MAX(v.visit_time) AS visit_time,
                (SELECT title FROM history_visits WHERE history_item = i.id AND title IS NOT NULL ORDER BY visit_time DESC LIMIT 1) AS title
            FROM history_items i LEFT JOIN history_visits v ON v.history_item = i.id
            GROUP BY i.id ORDER BY visit_time DESC
            """, limit: limit
        ).compactMap { row in
            guard let url = row["url"]?.string, url.hasPrefix("http") else { return nil }
            return BrowserHistoryItem(url: url, title: row["title"]?.string ?? "", visitCount: Int(row["visit_count"]?.int ?? 1),
                lastVisit: BrowserTime.safari(row["visit_time"]?.double ?? 0) ?? .distantPast)
        }
    }

    static func bookmarks(at file: URL, browser: String) throws -> [BrowserBookmark] {
        let handle = open(file.path, O_RDONLY)
        if handle < 0 {
            if errno == ENOENT { return [] }
            throw errno == EPERM || errno == EACCES ? SQLiteSnapshot.Failure.permissionDenied : SQLiteSnapshot.Failure.unreadable
        }
        close(handle)
        return parseBookmarks(try Data(contentsOf: file), browser: browser)
    }

    /// `Bookmarks.plist`: lists (`WebBookmarkTypeList`, with `Children`) and leaves (`WebBookmarkTypeLeaf`, with
    /// `URLString` and a title in `URIDictionary`). The Reading List is left out.
    static func parseBookmarks(_ data: Data, browser: String) -> [BrowserBookmark] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        var result: [BrowserBookmark] = []
        func walk(_ node: [String: Any], folder: String, depth: Int) {
            guard depth < 64 else { return }
            switch node["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                guard let url = node["URLString"] as? String, url.hasPrefix("http") else { return }
                let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String
                result.append(BrowserBookmark(url: url, title: title ?? url, folder: folder))
            case "WebBookmarkTypeList":
                let title = node["Title"] as? String ?? ""
                guard title != "com.apple.ReadingList" else { return }
                let name = title == "BookmarksBar" ? "Favorites" : title == "BookmarksMenu" ? "Bookmarks Menu" : title
                let path = depth == 0 || name.isEmpty ? folder : folder + " › " + name
                for child in node["Children"] as? [[String: Any]] ?? [] { walk(child, folder: path, depth: depth + 1) }
            default: break
            }
        }
        walk(root, folder: browser, depth: 0)
        return result
    }
}
