import Foundation

extension WorkspaceEngine {
    /// The credential grants this run's immutable transfer archive, rather than
    /// granting arbitrary access to the source thread's changing conversation.
    func appMCPContextRead(_ arguments: JSONValue, context: AppMCPContext) async throws -> JSONValue {
        let view = try await appMCPView(context)
        guard context.scope.capabilities.contains(.contextRead), let runID = context.runID,
              let caller = view.snapshot.threads.first(where: { $0.id == context.scope.threadID }),
              caller.activeRun?.id == runID,
              let rawID = arguments["transferId"].string, let id = UUID(uuidString: rawID),
              caller.activeRun?.contextTransferIDs?.contains(id) == true,
              let transfer = view.snapshot.contextTransfers?.first(where: { $0.id == id && $0.targetThreadID == caller.id }),
              transfer.targetRunID == runID,
              transfer.delivery?.runID == runID,
              transfer.delivery?.transferIDs.contains(id) == true else { throw AppMCPError(.staleCaller) }
        let result = try AppMCPContextArchive.read(transfer: transfer, arguments: arguments)
        _ = try await appMCPView(context)
        return result
    }
}

enum AppMCPContextArchive {
    static func read(transfer: ContextTransfer, arguments: JSONValue) throws -> JSONValue {
        func integer(_ key: String, fallback: Int, bounds: ClosedRange<Int>) throws -> Int {
            guard arguments[key] != .null else { return fallback }
            guard case .number(let number) = arguments[key], number.isFinite, number.rounded() == number,
                  number >= Double(bounds.lowerBound), number <= Double(min(bounds.upperBound, 9_007_199_254_740_991)) else { throw AppMCPError(.invalidRequest) }
            return Int(number)
        }
        let after = try integer("afterPosition", fallback: -1, bounds: 0...Int.max)
        let textOffset = try integer("textOffset", fallback: 0, bounds: 0...Int.max)
        let maximum = try integer("maxBytesPerItem", fallback: 4_096, bounds: 1...65_536)
        let limit = try integer("limit", fallback: 20, bounds: 1...100)
        let itemID = arguments["itemId"].string
        guard itemID != nil || textOffset == 0 else { throw AppMCPError(.invalidRequest) }
        let messages = transfer.review.messages
        var items: [JSONValue] = [], next = after, bytes = 0
        for (position, item) in messages.enumerated() where itemID.map({ Data($0.utf8) == Data(item.id.utf8) }) ?? (position > after) {
            guard items.count < limit else { break }
            let data = Data(item.text.utf8)
            guard textOffset <= data.count else { throw AppMCPError(.invalidRequest) }
            if textOffset < data.count, data[textOffset] & 0xc0 == 0x80 { throw AppMCPError(.invalidRequest) }
            var end = textOffset + min(maximum, data.count - textOffset)
            while end > textOffset, end < data.count, data[end] & 0xc0 == 0x80 { end -= 1 }
            func row(_ end: Int) -> JSONValue { .object(["itemId": .string(item.id), "position": .number(Double(position)),
                "runId": item.runID.map { .string($0.uuidString.lowercased()) } ?? .null,
                "role": .string(item.role), "kind": .string(item.kind), "text": .string(String(decoding: data[textOffset..<end], as: UTF8.self)),
                "textOffset": .number(Double(textOffset)), "totalBytes": .number(Double(data.count)),
                "nextTextOffset": end < data.count ? .number(Double(end)) : .null]) }
            let remaining = 98_304 - bytes
            if try ContextTransferProtocol.payload(row(end)).count > remaining {
                var low = textOffset, high = end, fitted: Int?
                while low <= high {
                    let midpoint = low + (high - low) / 2
                    var boundary = midpoint
                    while boundary > textOffset, boundary < data.count, data[boundary] & 0xc0 == 0x80 { boundary -= 1 }
                    if try ContextTransferProtocol.payload(row(boundary)).count <= remaining {
                        fitted = boundary; low = midpoint + 1
                    } else { high = midpoint - 1 }
                }
                guard let fitted else { break }; end = fitted
            }
            guard end > textOffset || textOffset == data.count else {
                if items.isEmpty { throw AppMCPError(.invalidRequest) }; break
            }
            let value = row(end), count = try ContextTransferProtocol.payload(value).count
            bytes += count; items.append(value); next = position
            if itemID != nil { break }
        }
        guard itemID == nil || !items.isEmpty else { throw AppMCPError(.notFound) }
        return .object(["transferId": .string(transfer.id.uuidString.lowercased()),
            "sourceThreadId": .string(transfer.sourceThreadID.uuidString.lowercased()),
            "archiveDigest": .string(transfer.review.digest), "items": .array(items),
            "nextPosition": items.isEmpty ? .null : .number(Double(next)),
            "hasMore": .bool(itemID == nil && next < messages.count - 1),
            "totalCount": .number(Double(messages.count)),
            "scope": .string("immutable captured context for this active input")])
    }
}
