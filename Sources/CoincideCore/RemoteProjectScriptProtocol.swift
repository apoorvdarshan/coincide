import Foundation

public enum RemoteProjectScriptProtocol {
    public static let readMethod = "remoteEnvironment.projectScript.read"
    public static let contentMethod = "remoteEnvironment.projectScript.content"
    public static let outputMethod = "remoteEnvironment.projectScript.output"
    public static let maximumResultBytes = 262_144
    public static let maximumContentBytes = 131_072
    public static func payload<T: Encodable>(_ value: T) throws -> Data { try RemoteLifecycleProtocol.payload(value) }
}

public enum RemoteProjectScriptAction: Codable, Sendable, Equatable {
    case approve(RemoteProjectScriptClaim)
    case stop(generationID: UUID, runID: UUID)
    case skip(generationID: UUID, runID: UUID)
    case retry(generationID: UUID, runID: UUID)
    public var requiresBoundRoot: Bool { switch self { case .approve, .retry: true; default: false } }
    public var generationID: UUID { switch self { case .approve(let claim): claim.generationID; case .stop(let id, _), .skip(let id, _), .retry(let id, _): id } }
    public var runID: UUID { switch self { case .approve(let claim): claim.runID; case .stop(_, let id), .skip(_, let id), .retry(_, let id): id } }
}

public struct RemoteProjectScriptClaim: Codable, Sendable, Equatable, Identifiable {
    private struct Payload: Codable, Sendable, Equatable { let id: UUID; let digest: String; let target: RemoteWorkspaceTarget; let generationID, runID, hostID: UUID }
    private let storage: [Payload]
    public var id: UUID { storage[0].id }; public var digest: String { storage[0].digest }
    public var target: RemoteWorkspaceTarget { storage[0].target }; public var generationID: UUID { storage[0].generationID }
    public var runID: UUID { storage[0].runID }; public var hostID: UUID { storage[0].hostID }
    public init(id: UUID, digest: String, target: RemoteWorkspaceTarget, generationID: UUID, runID: UUID, hostID: UUID) {
        storage = [.init(id: id, digest: digest, target: target, generationID: generationID, runID: runID, hostID: hostID)]
    }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}

public struct RemoteProjectScriptContentReference: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case name, command }
    public let id: UUID; public let kind: Kind; public let totalBytes: Int; public let digest: String
    public init(id: UUID, kind: Kind, totalBytes: Int, digest: String) { self.id = id; self.kind = kind; self.totalBytes = totalBytes; self.digest = digest }
}
public struct RemoteProjectScriptText: Codable, Sendable, Equatable {
    public let preview: String; public let content: RemoteProjectScriptContentReference?
    public init(preview: String, content: RemoteProjectScriptContentReference? = nil) { self.preview = preview; self.content = content }
}
public struct RemoteProjectScriptReview: Codable, Sendable, Equatable {
    private struct Payload: Codable, Sendable, Equatable {
        let claim: RemoteProjectScriptClaim; let name, command: RemoteProjectScriptText
        let projectRoot, workspacePath, shellPath: String; let runsAsynchronously: Bool
    }
    private let storage: [Payload]
    public var claim: RemoteProjectScriptClaim { storage[0].claim }; public var name: RemoteProjectScriptText { storage[0].name }
    public var command: RemoteProjectScriptText { storage[0].command }; public var projectRoot: String { storage[0].projectRoot }
    public var workspacePath: String { storage[0].workspacePath }; public var shellPath: String { storage[0].shellPath }
    public var runsAsynchronously: Bool { storage[0].runsAsynchronously }
    public init(claim: RemoteProjectScriptClaim, name: RemoteProjectScriptText, command: RemoteProjectScriptText,
                projectRoot: String, workspacePath: String, shellPath: String, runsAsynchronously: Bool) {
        storage = [.init(claim: claim, name: name, command: command, projectRoot: projectRoot, workspacePath: workspacePath, shellPath: shellPath, runsAsynchronously: runsAsynchronously)]
    }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}

public struct RemoteProjectScriptOutputReference: Codable, Sendable, Equatable, Identifiable {
    private struct Payload: Codable, Sendable, Equatable { let id: UUID; let target: RemoteWorkspaceTarget; let generationID, runID, hostID: UUID }
    private let storage: [Payload]
    public var id: UUID { storage[0].id }; public var target: RemoteWorkspaceTarget { storage[0].target }
    public var generationID: UUID { storage[0].generationID }; public var runID: UUID { storage[0].runID }; public var hostID: UUID { storage[0].hostID }
    public init(id: UUID, target: RemoteWorkspaceTarget, generationID: UUID, runID: UUID, hostID: UUID) { storage = [.init(id: id, target: target, generationID: generationID, runID: runID, hostID: hostID)] }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}
public struct RemoteProjectScriptState: Codable, Sendable, Equatable {
    private struct Payload: Codable, Sendable, Equatable {
        let runID: UUID; let phase: ThreadProjectScriptRunPhase; let commandExit: ProjectScriptCommandExit?; let error: String?
        let startedAt, endedAt: Date?; let review: RemoteProjectScriptReview?; let canApprove, canStop, canSkip, canRetry: Bool
        let output: RemoteProjectScriptOutputReference
    }
    private let storage: [Payload]
    public var runID: UUID { storage[0].runID }; public var phase: ThreadProjectScriptRunPhase { storage[0].phase }
    public var commandExit: ProjectScriptCommandExit? { storage[0].commandExit }; public var error: String? { storage[0].error }
    public var startedAt: Date? { storage[0].startedAt }; public var endedAt: Date? { storage[0].endedAt }
    public var review: RemoteProjectScriptReview? { storage[0].review }; public var canApprove: Bool { storage[0].canApprove }
    public var canStop: Bool { storage[0].canStop }; public var canSkip: Bool { storage[0].canSkip }; public var canRetry: Bool { storage[0].canRetry }
    public var output: RemoteProjectScriptOutputReference { storage[0].output }
    public init(runID: UUID, phase: ThreadProjectScriptRunPhase, commandExit: ProjectScriptCommandExit?, error: String?, startedAt: Date?, endedAt: Date?,
                review: RemoteProjectScriptReview?, canApprove: Bool, canStop: Bool, canSkip: Bool, canRetry: Bool, output: RemoteProjectScriptOutputReference) {
        storage = [.init(runID: runID, phase: phase, commandExit: commandExit, error: error, startedAt: startedAt, endedAt: endedAt,
            review: review, canApprove: canApprove, canStop: canStop, canSkip: canSkip, canRetry: canRetry, output: output)]
    }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}
public struct RemoteProjectScriptReadRequest: Codable, Sendable, Equatable {
    public let target: RemoteWorkspaceTarget; public let generationID: UUID
    public init(target: RemoteWorkspaceTarget, generationID: UUID) { self.target = target; self.generationID = generationID }
}
public struct RemoteProjectScriptReadResult: Codable, Sendable, Equatable {
    public let target: RemoteWorkspaceTarget; public let hostID: UUID; public let generationID: UUID; public let script: RemoteProjectScriptState?
    public init(target: RemoteWorkspaceTarget, hostID: UUID, generationID: UUID, script: RemoteProjectScriptState?) { self.target = target; self.hostID = hostID; self.generationID = generationID; self.script = script }
}
public struct RemoteProjectScriptContentRequest: Codable, Sendable, Equatable {
    public let claim: RemoteProjectScriptClaim; public let reference: RemoteProjectScriptContentReference; public let offset, maximumBytes: Int
    public init(claim: RemoteProjectScriptClaim, reference: RemoteProjectScriptContentReference, offset: Int = 0, maximumBytes: Int = RemoteProjectScriptProtocol.maximumContentBytes) {
        self.claim = claim; self.reference = reference; self.offset = offset; self.maximumBytes = maximumBytes
    }
}
public struct RemoteProjectScriptContentResult: Codable, Sendable, Equatable {
    public let claim: RemoteProjectScriptClaim; public let reference: RemoteProjectScriptContentReference; public let offset: Int
    public let data: Data; public let nextOffset: Int?; public let complete: Bool
    public init(claim: RemoteProjectScriptClaim, reference: RemoteProjectScriptContentReference, offset: Int, data: Data, nextOffset: Int?, complete: Bool) {
        self.claim = claim; self.reference = reference; self.offset = offset; self.data = data; self.nextOffset = nextOffset; self.complete = complete
    }
}
public enum RemoteProjectScriptOutputRetention: String, Codable, Sendable { case notStarted, retained, notRetained }
public struct RemoteProjectScriptOutputRequest: Codable, Sendable, Equatable {
    public let reference: RemoteProjectScriptOutputReference; public let afterSequence: UInt64?
    public init(reference: RemoteProjectScriptOutputReference, afterSequence: UInt64? = nil) { self.reference = reference; self.afterSequence = afterSequence }
}
/// Full bounded replacement, including when unchanged. Sequence is scoped to
/// this exact helper/attempt; notRetained never pretends to restore old output.
public struct RemoteProjectScriptOutputResult: Codable, Sendable, Equatable {
    public let reference: RemoteProjectScriptOutputReference; public let sequence: UInt64; public let text: String
    public let truncated, isClosed: Bool; public let retention: RemoteProjectScriptOutputRetention
    public init(reference: RemoteProjectScriptOutputReference, sequence: UInt64, text: String, truncated: Bool, isClosed: Bool, retention: RemoteProjectScriptOutputRetention) {
        self.reference = reference; self.sequence = sequence; self.text = text; self.truncated = truncated; self.isClosed = isClosed; self.retention = retention
    }
}
public struct RemoteProjectScriptFailure: Error, Codable, Sendable, Equatable, LocalizedError {
    public enum Kind: String, Codable, Sendable { case invalidTarget, staleReview, staleHost, invalidRequest, unavailable, busy, limitExceeded }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var errorDescription: String? { "This remote settle-script request could not be verified. Refresh the exact attempt before continuing." }
}
