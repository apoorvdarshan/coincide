import Foundation
import Testing
@testable import CoincideCore

@Test func mcpProtocolBoundsJSONBeforeDecodingAndAcceptsNativeIDs() throws {
    let ordinary: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("ping")])
    #expect(try MCPProtocol.decode(MCPProtocol.encode(ordinary)) == ordinary)
    let nested = String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33)
    #expect(throws: MCPError(.limitExceeded)) { _ = try MCPProtocol.decode(Data(nested.utf8)) }
    #expect(throws: MCPError(.limitExceeded)) { _ = try MCPProtocol.decode(Data(repeating: 32, count: MCPProtocol.maximumBodyBytes + 1)) }
    #expect(throws: MCPError.self) { _ = try MCPProtocol.decode(Data("{not-json}".utf8)) }
    #expect(try MCPRequestID(.string("native-request")) == .text("native-request"))
    #expect(try MCPRequestID(.number(0)) == .integer(0))
    let invalidValues: [JSONValue] = [.null, .bool(true), .number(1.5), .number(9_007_199_254_740_992)]
    for invalid in invalidValues {
        #expect(throws: MCPError.self) { _ = try MCPRequestID(invalid) }
    }
}

@Test func mcpProtocolToolDefinitionsPublishNativeTextAndStructuredResultsWithoutAuthorityFields() throws {
    let tool = MCPToolDefinition(name: "coincide_thread_read", title: "Read thread", description: "Read the owned thread.",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])]), capability: .orchestration, readOnly: true)
    try tool.validate()
    #expect(tool.json["annotations"]["readOnlyHint"] == .bool(true))
    #expect(tool.json["capability"] == .null)
    let result = MCPToolResult(content: ["A bounded result"], structuredContent: .object(["ready": .bool(true)]))
    #expect(result.json["content"].array?.first?["type"] == .string("text"))
    #expect(result.json["structuredContent"]["ready"] == .bool(true))
    #expect(String(reflecting: result) == "MCPToolResult(redacted)")
    #expect(Mirror(reflecting: result).children.isEmpty)
    let bad = MCPToolDefinition(name: "untrusted/name", description: "bad", inputSchema: .object(["type": .string("object")]), capability: .preview, readOnly: false)
    #expect(throws: MCPError.self) { try bad.validate() }
}
