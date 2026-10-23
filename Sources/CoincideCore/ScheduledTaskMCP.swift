import Foundation

public enum ScheduledTaskMCPAction: Codable, Sendable, Equatable {
    case read(id: UUID, revision: UUID, offset: Int, maximumBytes: Int)
    case list(projectID: UUID?, cursor: Int, limit: Int)
    case save(id: UUID?, revision: UUID?, title: String?, prompt: String?, enabled: Bool?, schedule: ScheduledTaskSchedule?, bindToCurrentThread: Bool?, commandID: UUID)
    case delete(id: UUID, revision: UUID, commandID: UUID)
    case run(id: UUID, commandID: UUID)
    case acknowledge(id: UUID, commandID: UUID)
}
extension WorkspaceEngine {
    func performScheduledTaskMCP(_ action: ScheduledTaskMCPAction, context: AppMCPContext) async throws -> JSONValue {
        let view = try await appMCPView(context)
        let ledger = view.snapshot.scheduler ?? .init()
        func task(_ id: UUID) throws -> ScheduledTaskDefinition {
            guard let task = ledger.tasks.first(where: { $0.id == id }), task.source.projectID == context.scope.projectID else { throw AppMCPError(.notFound) }
            return task
        }
        switch action {
        case .read(let id, let revision, let offset, let maximum):
            let value = try task(id)
            guard value.revision == revision else { throw ScheduledTaskError.staleRevision }
            let bytes = Data(value.prompt.utf8)
            guard offset >= 0, offset <= bytes.count, (4...65_536).contains(maximum), String(data: bytes.prefix(offset), encoding: .utf8) != nil else { throw AppMCPError(.invalidRequest) }
            var part = Data(bytes.dropFirst(offset).prefix(maximum))
            while !part.isEmpty, String(data: part, encoding: .utf8) == nil { part.removeLast() }
            let end = offset + part.count
            return .object(["id": .string(id.uuidString), "revision": .string(revision.uuidString), "title": .string(value.title),
                "prompt": .string(String(decoding: part, as: UTF8.self)), "offset": .number(Double(offset)), "byteCount": .number(Double(bytes.count)),
                "digest": .string(ScheduledTaskWebhookSecurity.digest(bytes)), "nextOffset": end < bytes.count ? .number(Double(end)) : .null,
                "complete": .bool(end == bytes.count)])
        case .list(let projectID, let cursor, let limit):
            guard projectID == nil || projectID == context.scope.projectID else { throw AppMCPError(.capabilityDenied) }
            guard cursor >= 0, cursor <= 10_000, (1...100).contains(limit) else { throw AppMCPError(.invalidRequest) }
            let tasks = ledger.tasks.filter { $0.source.projectID == context.scope.projectID }.sorted { $0.createdAt > $1.createdAt }
            let end = min(tasks.count, cursor + limit)
            let rows = cursor < tasks.count ? Array(tasks[cursor..<end]) : []
            return .object(["tasks": .array(rows.map { value in
                .object(["id": .string(value.id.uuidString), "revision": .string(value.revision.uuidString), "title": .string(value.title),
                    "promptPreview": .string(scheduledTaskPreview(value.prompt)), "enabled": .bool(value.enabled), "provider": .string(value.source.configuration.provider.rawValue),
                    "model": .string(value.source.configuration.model), "nextRunAt": value.nextRunAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
                    "sourceThreadId": .string(value.source.threadID.uuidString), "freshThreadPerRun": .bool(value.destination != .existingThread),
                    "unresolvedRuns": .number(Double(ledger.occurrences.filter { $0.taskID == value.id && $0.phase == .uncertain && $0.acknowledgedAt == nil }.count))])
            }), "total": .number(Double(tasks.count)), "nextCursor": end < tasks.count ? .number(Double(end)) : .null])
        default: break
        }
        // A persistent automation can run after this caller exits. Require the
        // pinned full-access ceiling and recheck it in serialized admission.
        guard context.configuration.permission == .fullAccess else { throw AppMCPError(.capabilityDenied) }
        let commandID: UUID
        switch action {
        case .save(let id, _, _, _, _, _, _, let originalID): if let id { _ = try task(id) }; commandID = originalID
        case .delete(let id, _, let originalID), .run(let id, let originalID): _ = try task(id); commandID = originalID
        case .acknowledge(let id, let originalID):
            guard let occurrence = ledger.occurrences.first(where: { $0.id == id }) else { throw AppMCPError(.notFound) }
            _ = try task(occurrence.taskID); commandID = originalID
        case .list, .read: throw AppMCPError(.invalidRequest)
        }
        guard let source = view.snapshot.threads.first(where: { $0.id == context.scope.threadID }),
              let project = view.snapshot.projects.first(where: { $0.id == source.projectID }),
              ScheduledTaskSource.normalized(.init(thread: source)).matchesModelControlCapture(ScheduledTaskSource.normalized(context.configuration)) else { throw AppMCPError(.staleCaller) }
        return try await dispatchScheduledTaskFromAppMCP(action, source: .init(thread: source, project: project), commandID: commandID, context: context)
    }
}

public struct ScheduledTaskMCPCommand: Codable, Sendable, Equatable {
    public let action: ScheduledTaskMCPAction
    public let source: ScheduledTaskSource
    public let managedRoot: String
    public let expectedTaskRevision: UUID?
}

private func scheduledTaskPreview(_ text: String) -> String {
    var bytes = Data(text.utf8.prefix(512))
    while !bytes.isEmpty, String(data: bytes, encoding: .utf8) == nil { bytes.removeLast() }
    return String(decoding: bytes, as: UTF8.self)
}
