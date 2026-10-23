import Foundation

public enum RemoteThreadActionsProtocol {
    public static let readMethod = "remoteEnvironment.threadActions.read"
    public static let releaseMethod = "remoteEnvironment.threadActions.release"
    public static let maximumBytes = RemoteProjectionProtocol.maximumResultBytes
}
public struct RemoteThreadActionBinding: Codable, Sendable, Equatable {
    private struct Payload: Codable, Sendable { let environmentID: UUID, hostID: UUID, leaseID: UUID; let digest: String }
    private let storage: [Payload]
    public var environmentID: UUID { storage[0].environmentID }
    public var hostID: UUID { storage[0].hostID }
    public var leaseID: UUID { storage[0].leaseID }
    public var digest: String { storage[0].digest }
    init(environmentID: UUID, hostID: UUID, leaseID: UUID, digest: String) { storage = [.init(environmentID: environmentID, hostID: hostID, leaseID: leaseID, digest: digest)] }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.environmentID == rhs.environmentID && lhs.hostID == rhs.hostID && lhs.leaseID == rhs.leaseID && lhs.digest == rhs.digest }
}
public struct RemoteThreadActionCapture: Codable, Sendable, Equatable {
    public let id: UUID
    public let binding: RemoteThreadActionBinding
    public let target: RemoteWorkspaceTarget
    public let threadCreatedAt: Date, projectCreatedAt: Date?
    public let runID: UUID?, runtimeID: UUID?
    public let expectedPinned: Bool, expectedArchived: Bool
    public let digest: String
}
public struct RemoteThreadUndoGroup: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let digest: String
    public let kind: ThreadActionUndoKind
    public let claimIDs: [UUID], threadIDs: [UUID], forwardCommandIDs: [UUID]
    public let expiresAt: Date
    public let remainingMilliseconds: Int
    public var count: Int { claimIDs.count }
}
public struct RemoteThreadActionsReadRequest: Codable, Sendable {
    public let environmentID: UUID
    public let binding: RemoteThreadActionBinding?
    public let target: RemoteWorkspaceTarget?
    public init(environmentID: UUID, binding: RemoteThreadActionBinding? = nil, target: RemoteWorkspaceTarget? = nil) { self.environmentID = environmentID; self.binding = binding; self.target = target }
}
public struct RemoteThreadActionsReadResult: Codable, Sendable {
    public let binding: RemoteThreadActionBinding
    public let sequence: Int64
    public let capture: RemoteThreadActionCapture?
    public let undo: RemoteThreadUndoGroup?
}
public struct RemoteThreadActionsReleaseRequest: Codable, Sendable {
    public let binding: RemoteThreadActionBinding
    public init(binding: RemoteThreadActionBinding) { self.binding = binding }
}
public struct RemoteThreadActionsReleaseResult: Codable, Sendable { public let binding: RemoteThreadActionBinding; public let released: Bool }
public indirect enum RemoteThreadAction: Codable, Sendable, Equatable {
    case setPinned(capture: RemoteThreadActionCapture, value: Bool)
    case setArchived(capture: RemoteThreadActionCapture, value: Bool)
    case undo(binding: RemoteThreadActionBinding, groupID: UUID, digest: String, claimIDs: [UUID])
    public var binding: RemoteThreadActionBinding { switch self { case .setPinned(let capture, _), .setArchived(let capture, _): capture.binding; case .undo(let binding, _, _, _): binding } }
}

struct RemoteThreadActionsPreparation: Codable, Sendable {
    private struct Payload: Codable, Sendable {
        let binding: RemoteThreadActionBinding
        let capture: RemoteThreadActionCapture?
        let incarnation: UUID?
        let expected: ThreadActionUndoClaim.State?
        let claims: [ThreadActionUndoClaim]
        let deadline: Date?
        let targets: [RemoteWorkspaceTarget]
    }
    private let storage: [Payload]
    var binding: RemoteThreadActionBinding { storage[0].binding }
    var capture: RemoteThreadActionCapture? { storage[0].capture }
    var incarnation: UUID? { storage[0].incarnation }
    var expected: ThreadActionUndoClaim.State? { storage[0].expected }
    var claims: [ThreadActionUndoClaim] { storage[0].claims }
    var deadline: Date? { storage[0].deadline }
    var targets: [RemoteWorkspaceTarget] { storage[0].targets }
    init(binding: RemoteThreadActionBinding, capture: RemoteThreadActionCapture? = nil, incarnation: UUID? = nil, expected: ThreadActionUndoClaim.State? = nil,
         claims: [ThreadActionUndoClaim] = [], deadline: Date? = nil, targets: [RemoteWorkspaceTarget] = []) {
        storage = [.init(binding: binding, capture: capture, incarnation: incarnation, expected: expected, claims: claims, deadline: deadline, targets: targets)]
    }
    init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}
