import Foundation

public struct OpenCodeSSEEvent: Sendable, Equatable {
    public let event: String
    public let data: String
    public let id: String?
    public let retryMilliseconds: Int?
}

/// Incremental UTF-8 framing. Connection loss never dispatches an unfinished
/// event, and overflow permanently fails this parser rather than truncating JSON.
public struct OpenCodeSSEParser: Sendable {
    private let maximumLineBytes: Int
    private let maximumEventBytes: Int
    private var line = Data()
    private var skipLF = false
    private var firstLine = true
    private var dataLines: [String] = []
    private var dataBytes = 0
    private var eventName = ""
    private var pendingEventID: String?
    private var ended = false
    private var failure: OpenCodeProtocolError?
    public private(set) var lastEventID: String?
    public private(set) var retryMilliseconds: Int?

    public init(maximumLineBytes: Int = 1_048_576, maximumEventBytes: Int = 1_048_576) throws {
        guard (1...1_048_576).contains(maximumLineBytes),
              (1...16_777_216).contains(maximumEventBytes) else { throw OpenCodeProtocolError.eventLimitExceeded }
        self.maximumLineBytes = maximumLineBytes; self.maximumEventBytes = maximumEventBytes
    }

    public mutating func append(_ bytes: Data) throws -> [OpenCodeSSEEvent] {
        if let failure { throw failure }
        guard !ended else { throw OpenCodeProtocolError.closed }
        var result: [OpenCodeSSEEvent] = []
        do {
            guard bytes.count <= 1_048_576 else { throw OpenCodeProtocolError.eventLimitExceeded }
            for byte in bytes {
                if skipLF {
                    skipLF = false
                    if byte == 10 { continue }
                }
                if byte == 10 || byte == 13 {
                    if let event = try consumeLine() { result.append(event) }
                    skipLF = byte == 13
                } else {
                    guard line.count < maximumLineBytes else { throw OpenCodeProtocolError.eventLimitExceeded }
                    line.append(byte)
                }
            }
            return result
        } catch let error as OpenCodeProtocolError {
            failure = error; discard(); throw error
        } catch {
            failure = .invalidEvent; discard(); throw OpenCodeProtocolError.invalidEvent
        }
    }

    public mutating func finish() {
        ended = true; pendingEventID = lastEventID; discard()
    }

    private mutating func discard() {
        line.removeAll(keepingCapacity: false); dataLines.removeAll(keepingCapacity: false)
        dataBytes = 0; eventName = ""
    }

    private mutating func consumeLine() throws -> OpenCodeSSEEvent? {
        if firstLine {
            firstLine = false
            if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
        }
        guard let text = String(data: line, encoding: .utf8) else { throw OpenCodeProtocolError.invalidEvent }
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            // An incomplete block must not advance a future reconnect cursor.
            lastEventID = pendingEventID
            defer { dataLines.removeAll(keepingCapacity: true); dataBytes = 0; eventName = "" }
            guard !dataLines.isEmpty else { return nil }
            return OpenCodeSSEEvent(event: eventName.isEmpty ? "message" : eventName,
                                   data: dataLines.joined(separator: "\n"), id: lastEventID,
                                   retryMilliseconds: retryMilliseconds)
        }
        guard text.first != ":" else { return nil }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = parts[0]
        var value = parts.count > 1 ? parts[1] : Substring()
        if value.first == " " { value.removeFirst() }
        switch field {
        case "data":
            let length = value.utf8.count
            guard dataLines.count < 4_096, length < maximumEventBytes,
                  dataBytes <= maximumEventBytes - length - 1 else { throw OpenCodeProtocolError.eventLimitExceeded }
            dataBytes += length + 1; dataLines.append(String(value))
        case "event":
            guard value.utf8.count <= 1_024 else { throw OpenCodeProtocolError.eventLimitExceeded }
            eventName = String(value)
        case "id":
            if !value.contains("\0") {
                guard value.utf8.count <= 4_096 else { throw OpenCodeProtocolError.eventLimitExceeded }
                pendingEventID = String(value)
            }
        case "retry":
            if !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let retry = Int(value) {
                retryMilliseconds = retry
            }
        default: break
        }
        return nil
    }
}
