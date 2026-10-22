import CoincideCore
import Foundation

struct NativePromptSteeringKey: Equatable {
    struct Operation: Equatable {
        let id: UUID
        let phase: String
        let acknowledgedAt: Date?
    }
    let runtimeID: UUID?
    let run: ActiveRun?
    let nativeThreadID: String?
    let capabilityRevision: UInt64?
    let state: ThreadState
    let requests: [RuntimeRequest]
    let workspaceReady: Bool
    let historyLocked: Bool
    let accepting: Bool
    let operations: [Operation]
}
