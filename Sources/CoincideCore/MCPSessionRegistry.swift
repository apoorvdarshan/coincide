import CryptoKit
import Foundation
import Security

/// Runtime-only authority. The header is never Codable, logged, mirrored, or
/// included in a URL; only a private provider handoff should read it.
public final class MCPSessionCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let sessionID: UUID
    public let authorizationHeader: String
    fileprivate init(sessionID: UUID, authorizationHeader: String) { self.sessionID = sessionID; self.authorizationHeader = authorizationHeader }
    public var description: String { "MCPSessionCredential(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }
}

/// Stores only hashed credentials. MCP traffic never extends liveness; only an
/// explicit trusted owner touch can renew an idle provider session.
public actor MCPSessionRegistry {
    private struct Record {
        let scope: MCPInvocationScope
        var touchedAt: Date
        var version: String?
        var initialized = false
        var requestIDs: Set<MCPRequestID> = []
    }
    private struct Call {
        let scope: MCPInvocationScope
        let requestID: MCPRequestID
        let task: Task<MCPToolResult, any Error>
    }
    private var records: [String: Record] = [:]
    private var calls: [UUID: Call] = [:]
    private let now: @Sendable () -> Date
    private let liveness: TimeInterval
    private var closed = false
    public init(livenessWindow: TimeInterval = 86_400, now: @escaping @Sendable () -> Date = { Date() }) {
        self.liveness = livenessWindow; self.now = now
    }
    public func issue(scope: MCPInvocationScope) throws -> MCPSessionCredential {
        try scope.validate()
        guard !closed, liveness.isFinite, liveness > 0, liveness <= 86_400,
              records.count < 128, !records.values.contains(where: { $0.scope.sessionID == scope.sessionID }) else { throw MCPError(.invalidConfiguration) }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw MCPError(.unavailable) }
        let token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        records[Self.digest(token)] = Record(scope: scope, touchedAt: now())
        return MCPSessionCredential(sessionID: scope.sessionID, authorizationHeader: "Bearer " + token)
    }
    public func touch(sessionID: UUID) {
        guard !closed, let key = records.first(where: { $0.value.scope.sessionID == sessionID })?.key else { return }
        records[key]?.touchedAt = now()
    }
    public func revoke(sessionID: UUID) async { await revokeWhere { $0.sessionID == sessionID } }
    public func revoke(threadID: UUID) async { await revokeWhere { $0.threadID == threadID } }
    public func revokeAll() async { await revokeWhere { _ in true } }
    public func shutdown() async { closed = true; await revokeAll() }
    private func revokeWhere(_ matches: (MCPInvocationScope) -> Bool) async {
        // Removed credentials must not hide a still-draining invocation from a
        // concurrent revoke/shutdown caller. Calls retain their immutable scope
        // until the actual callback has returned.
        let ids = Set(records.values.filter { matches($0.scope) }.map { $0.scope.sessionID })
            .union(calls.values.filter { matches($0.scope) }.map { $0.scope.sessionID })
        records = records.filter { !ids.contains($0.value.scope.sessionID) }
        let pending = calls.values.filter { ids.contains($0.scope.sessionID) }.map(\.task)
        for task in pending { task.cancel() }
        for task in pending { _ = await task.result }
    }
    private static func digest(_ token: String) -> String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }
    func authenticate(_ header: String?) throws -> MCPInvocationScope {
        guard !closed, let header, header.hasPrefix("Bearer "), header.utf8.count == 50 else { throw MCPError(.unauthorized) }
        let token = String(header.dropFirst(7))
        guard token.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let record = records[Self.digest(token)], now().timeIntervalSince(record.touchedAt) >= 0,
              now().timeIntervalSince(record.touchedAt) <= liveness else { throw MCPError(.unauthorized) }
        return record.scope
    }
    private func key(sessionID: UUID) throws -> String {
        guard !closed, let item = records.first(where: { $0.value.scope.sessionID == sessionID }),
              now().timeIntervalSince(item.value.touchedAt) >= 0,
              now().timeIntervalSince(item.value.touchedAt) <= liveness else { throw MCPError(.unauthorized) }
        return item.key
    }
    func initialize(sessionID: UUID, requestedVersion: String) throws -> String {
        let key = try key(sessionID: sessionID)
        let version = MCPProtocol.supportedVersions.contains(requestedVersion) ? requestedVersion : MCPProtocol.supportedVersions.last!
        if let prior = records[key]?.version, prior != version { throw MCPError(.invalidRequest) }
        records[key]?.version = version
        return version
    }
    func initialized(sessionID: UUID, version: String?) throws {
        let key = try key(sessionID: sessionID)
        guard let negotiated = records[key]?.version, version == negotiated else { throw MCPError(.notReady) }
        records[key]?.initialized = true
    }
    func ready(sessionID: UUID, version: String?) throws {
        let key = try key(sessionID: sessionID)
        guard records[key]?.initialized == true, let negotiated = records[key]?.version, version == negotiated else { throw MCPError(.notReady) }
    }
    func claim(sessionID: UUID, requestID: MCPRequestID) throws {
        let key = try key(sessionID: sessionID)
        guard records[key]!.requestIDs.count < 4_096, records[key]!.requestIDs.insert(requestID).inserted else { throw MCPError(.invalidRequest) }
    }
    func cancel(sessionID: UUID, requestID: MCPRequestID) {
        for call in calls.values where call.scope.sessionID == sessionID && call.requestID == requestID { call.task.cancel() }
    }
    private func cancel(callID: UUID) { calls[callID]?.task.cancel() }
    func invoke(sessionID: UUID, requestID: MCPRequestID, capability: MCPCapability,
                operation: @escaping @Sendable (MCPInvocationScope) async throws -> MCPToolResult) async throws -> MCPToolResult {
        let key = try key(sessionID: sessionID), scope = records[key]!.scope
        guard scope.capabilities.contains(capability) else { throw MCPError(.unavailable) }
        guard calls.count < 64, calls.values.filter({ $0.scope.sessionID == sessionID }).count < 8 else { throw MCPError(.limitExceeded) }
        try Task.checkCancellation()
        let callID = UUID(), task = Task { try Task.checkCancellation(); return try await operation(scope) }
        calls[callID] = Call(scope: scope, requestID: requestID, task: task)
        defer { calls.removeValue(forKey: callID) }
        return try await withTaskCancellationHandler {
            do {
                let result = try await task.value
                try Task.checkCancellation()
                _ = try self.key(sessionID: sessionID)
                return result
            } catch is CancellationError { throw MCPError(.cancelled) }
        } onCancel: { Task { await self.cancel(callID: callID) } }
    }
}
