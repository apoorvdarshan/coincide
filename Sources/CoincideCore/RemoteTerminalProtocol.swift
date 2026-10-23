import CryptoKit
import Foundation

public enum RemoteTerminalProtocol {
    public static let maximumOutputBytes = 512 * 1_024
    public static let maximumChunkBytes = 65_536
    public static func inputDigest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func chainedInputDigest(previous: String, sequence: Int64, digest: String) -> String {
        inputDigest(Data("\(previous)|\(sequence)|\(digest)".utf8))
    }
}

/// Driver callbacks must preserve byte order. A driver that exhausts its bounded
/// output queue must emit outputOverflow/finish and close, never silently drop.
public enum RemotePTYEvent: Sendable, Equatable {
    case output(Data)
    case exited(code: Int32?, signal: Int32?)
    case failed
    case outputOverflow
}
public struct RemotePTYLaunch: Sendable {
    public let directory: String
    public let cols: Int
    public let rows: Int
    public init(directory: String, cols: Int, rows: Int) { self.directory = directory; self.cols = cols; self.rows = rows }
}
public protocol RemotePTYDriver: Sendable {
    var events: AsyncStream<RemotePTYEvent> { get }
    func write(_ data: Data) async throws
    func resize(cols: Int, rows: Int) async throws
    func hasForegroundCommand() async -> Bool
    /// Returns only after the exact owned PTY/process and output delivery drain.
    func close() async
}
public typealias RemotePTYDriverFactory = @Sendable (RemotePTYLaunch) async throws -> any RemotePTYDriver

public struct RemoteTerminalOpenRequest: Codable, Sendable, Equatable {
    public let id: UUID
    public let target: RemoteWorkspaceTarget
    public let terminalID: UUID
    public let cols: Int
    public let rows: Int
    public init(id: UUID = UUID(), target: RemoteWorkspaceTarget, terminalID: UUID = UUID(), cols: Int = 80, rows: Int = 24) {
        self.id = id; self.target = target; self.terminalID = terminalID; self.cols = cols; self.rows = rows
    }
}
public struct RemoteTerminalReference: Codable, Sendable, Equatable {
    public let target: RemoteWorkspaceTarget
    public let terminalID: UUID
    public let incarnation: UUID
    public init(target: RemoteWorkspaceTarget, terminalID: UUID, incarnation: UUID) { self.target = target; self.terminalID = terminalID; self.incarnation = incarnation }
}
public struct RemoteTerminalSnapshot: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable { case starting, running, closing, exited, failed, lost }
    public let reference: RemoteTerminalReference
    public var state: State
    public var cols: Int
    public var rows: Int
    public var outputSequence: Int64
    public var retainedStartSequence: Int64
    public var nextInputSequence: Int64
    public var inputDigest: String
    public var inputHalted: Bool
    public var hasForegroundCommand: Bool
    public var exitCode: Int32?
    public var exitSignal: Int32?
    public var id: UUID { reference.terminalID }
    public init(reference: RemoteTerminalReference, state: State, cols: Int, rows: Int,
                outputSequence: Int64 = 0, retainedStartSequence: Int64 = 0, nextInputSequence: Int64 = 1,
                inputDigest: String = "", inputHalted: Bool = false, hasForegroundCommand: Bool = false,
                exitCode: Int32? = nil, exitSignal: Int32? = nil) {
        self.reference = reference; self.state = state; self.cols = cols; self.rows = rows
        self.outputSequence = outputSequence; self.retainedStartSequence = retainedStartSequence
        self.nextInputSequence = nextInputSequence; self.inputDigest = inputDigest; self.inputHalted = inputHalted
        self.hasForegroundCommand = hasForegroundCommand; self.exitCode = exitCode; self.exitSignal = exitSignal
    }
}
public struct RemoteTerminalReadRequest: Codable, Sendable, Equatable {
    public let reference: RemoteTerminalReference
    public let afterSequence: Int64
    public let maxBytes: Int
    public init(reference: RemoteTerminalReference, afterSequence: Int64 = 0, maxBytes: Int = 65_536) { self.reference = reference; self.afterSequence = afterSequence; self.maxBytes = maxBytes }
}
public struct RemoteTerminalReadResult: Codable, Sendable, Equatable {
    public let snapshot: RemoteTerminalSnapshot
    public let data: Data
    public let startSequence: Int64
    public let nextSequence: Int64
    public let gap: Bool
    public init(snapshot: RemoteTerminalSnapshot, data: Data, startSequence: Int64, nextSequence: Int64, gap: Bool) {
        self.snapshot = snapshot; self.data = data; self.startSequence = startSequence; self.nextSequence = nextSequence; self.gap = gap
    }
}
public struct RemoteTerminalInputRequest: Codable, Sendable, Equatable {
    public let reference: RemoteTerminalReference
    public let sequence: Int64
    public let data: Data
    public init(reference: RemoteTerminalReference, sequence: Int64, data: Data) { self.reference = reference; self.sequence = sequence; self.data = data }
}
public struct RemoteTerminalInputReceiptRequest: Codable, Sendable, Equatable {
    public let reference: RemoteTerminalReference
    public let sequence: Int64
    public let digest: String
    public init(reference: RemoteTerminalReference, sequence: Int64, digest: String) { self.reference = reference; self.sequence = sequence; self.digest = digest }
}
public struct RemoteTerminalInputReceipt: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case accepted, delivered, uncertain }
    public let reference: RemoteTerminalReference
    public let sequence: Int64
    public let digest: String
    public let byteCount: Int
    public let inputDigest: String
    public var state: State
    public init(reference: RemoteTerminalReference, sequence: Int64, digest: String, byteCount: Int, inputDigest: String, state: State) {
        self.reference = reference; self.sequence = sequence; self.digest = digest; self.byteCount = byteCount; self.inputDigest = inputDigest; self.state = state
    }
}
public struct RemoteTerminalResizeRequest: Codable, Sendable, Equatable {
    public let reference: RemoteTerminalReference
    public let cols: Int
    public let rows: Int
    public init(reference: RemoteTerminalReference, cols: Int, rows: Int) { self.reference = reference; self.cols = cols; self.rows = rows }
}
public struct RemoteTerminalFailure: Error, Codable, Sendable, Equatable, LocalizedError {
    public enum Kind: String, Codable, Sendable { case unavailable, invalidTarget, staleIncarnation, notFound, invalidRequest, busy, limitExceeded, openCollision, inputCollision, inputExpired, inputUncertain, outputGap }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var errorDescription: String? {
        switch kind {
        case .unavailable: "The remote terminal service is unavailable."
        case .invalidTarget: "The remote terminal workspace changed or is unavailable."
        case .staleIncarnation: "This terminal process changed. Reattach before continuing."
        case .notFound: "This remote terminal is unavailable. Reconnecting will not start a shell."
        case .invalidRequest: "The remote terminal request is invalid."
        case .busy: "This remote workspace or terminal is busy."
        case .limitExceeded: "The remote terminal exceeded a limit."
        case .openCollision: "This terminal identity is already bound to a different open request."
        case .inputCollision: "This input sequence is bound to different bytes."
        case .inputExpired: "This input receipt expired. The input will not be repeated."
        case .inputUncertain: "Input may have reached the remote process. It will not be repeated; close this terminal before sending more input."
        case .outputGap: "Some terminal output is no longer retained."
        }
    }
}
