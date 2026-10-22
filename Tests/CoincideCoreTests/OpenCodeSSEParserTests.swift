import Foundation
import Testing
@testable import CoincideCore

@Test func openCodeSSEFramesSplitUnicodeBOMMultilineAndEveryLineEndingWithoutEarlyDispatch() throws {
    let source = Data("\u{FEFF}: heartbeat\r\nid: opaque-α\r\nevent: session.updated\r\ndata: {\"text\":\"猫\",\r\ndata: \"ok\":true}\r\n\r\nretry: 1250\ndata: next\n\n".utf8)
    var parser = try OpenCodeSSEParser(), received: [OpenCodeSSEEvent] = []
    for byte in source { received += try parser.append(Data([byte])) }
    #expect(received == [
        .init(event: "session.updated", data: "{\"text\":\"猫\",\n\"ok\":true}", id: "opaque-α", retryMilliseconds: nil),
        .init(event: "message", data: "next", id: "opaque-α", retryMilliseconds: 1250)
    ])
    #expect(parser.lastEventID == "opaque-α" && parser.retryMilliseconds == 1250)
}

@Test func openCodeSSEPreservesOneLeadingSpaceEmptyDataAndIDResetButIgnoresNULIDsAndUnknownFields() throws {
    var parser = try OpenCodeSSEParser()
    let result = try parser.append(Data("id: original\n\nid: ignored\0id\nevent: custom\ndata:  spaces\nunknown: ignored\ndata\n\nid:\ndata:\n\n".utf8))
    #expect(result == [
        .init(event: "custom", data: " spaces\n", id: "original", retryMilliseconds: nil),
        .init(event: "message", data: "", id: "", retryMilliseconds: nil)
    ])
    #expect(parser.lastEventID == "")
}

@Test func openCodeSSELoneCRAndSplitCRLFDispatchOnlyAtAnActualBlankLine() throws {
    var parser = try OpenCodeSSEParser()
    #expect(try parser.append(Data("data: first\r".utf8)).isEmpty)
    #expect(try parser.append(Data("\n".utf8)).isEmpty)
    #expect(try parser.append(Data("\r".utf8)) == [.init(event: "message", data: "first", id: nil, retryMilliseconds: nil)])
    #expect(try parser.append(Data("\ndata: second\r\r".utf8)) == [.init(event: "message", data: "second", id: nil, retryMilliseconds: nil)])
}

@Test func openCodeSSEDisconnectDiscardsUnfinishedEventInsteadOfInventingCompletion() throws {
    var parser = try OpenCodeSSEParser()
    #expect(try parser.append(Data("data: {\"type\":\"execution.succeeded\"}\n".utf8)).isEmpty)
    parser.finish()
    #expect(throws: OpenCodeProtocolError.closed) { try parser.append(Data("\n".utf8)) }
}

@Test func openCodeSSEDisconnectCannotAdvanceTheCommittedEventIDPastAnUndispatchedFrame() throws {
    var parser = try OpenCodeSSEParser()
    #expect(try parser.append(Data("id: committed\ndata: before\n\n".utf8)).first?.id == "committed")
    #expect(try parser.append(Data("id: not-delivered\ndata: partial\n".utf8)).isEmpty)
    #expect(parser.lastEventID == "committed")
    parser.finish()
    #expect(parser.lastEventID == "committed")
    var reset = try OpenCodeSSEParser()
    #expect(try reset.append(Data("id: first\n\nid:\n\n".utf8)).isEmpty)
    #expect(reset.lastEventID == "")
}

@Test func openCodeSSEMalformedUTF8AndBothMemoryBoundsFailPermanently() throws {
    var utf8 = try OpenCodeSSEParser()
    #expect(throws: OpenCodeProtocolError.invalidEvent) { try utf8.append(Data([100, 97, 116, 97, 58, 0xFF, 10])) }
    #expect(throws: OpenCodeProtocolError.invalidEvent) { try utf8.append(Data("data: next\n\n".utf8)) }
    var line = try OpenCodeSSEParser(maximumLineBytes: 8)
    #expect(try line.append(Data("data:123".utf8)).isEmpty)
    #expect(throws: OpenCodeProtocolError.eventLimitExceeded) { try line.append(Data("4".utf8)) }
    var event = try OpenCodeSSEParser(maximumEventBytes: 7)
    #expect(try event.append(Data("data:123\n".utf8)).isEmpty)
    #expect(throws: OpenCodeProtocolError.eventLimitExceeded) { try event.append(Data("data:456\n\n".utf8)) }
    #expect(throws: OpenCodeProtocolError.eventLimitExceeded) { try event.append(Data("\n".utf8)) }
}

@Test func openCodeSSERetryRequiresASafeUnsignedDecimalAndCommentsNeedNoEvents() throws {
    var parser = try OpenCodeSSEParser()
    #expect(try parser.append(Data(": heartbeat\nretry: 50\n\nretry: -1\nretry: +3\nretry: 99999999999999999999999999999999\n\n".utf8)).isEmpty)
    #expect(parser.retryMilliseconds == 50)
    #expect(try parser.append(Data("data: ok\n\n".utf8)).first?.retryMilliseconds == 50)
}

@Test func openCodeSSEPreservesALargeSingleLineToolSnapshotAcrossTransportSizedChunks() throws {
    let body = "{\"type\":\"tool.snapshot\",\"text\":\"" + String(repeating: "native tool output 🐱 ", count: 6_000) + "\"}"
    let bytes = Data(("data: " + body + "\n\n").utf8)
    #expect(bytes.count > 65_536)
    var parser = try OpenCodeSSEParser(), result: [OpenCodeSSEEvent] = []
    var offset = bytes.startIndex
    while offset < bytes.endIndex {
        let end = min(offset + 16_384, bytes.endIndex)
        result += try parser.append(bytes.subdata(in: offset..<end)); offset = end
    }
    #expect(result.count == 1 && result.first?.data == body)
}
