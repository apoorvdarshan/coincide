import AppKit
import CoincideCore
import Foundation
import Observation

@MainActor @Observable
final class QueuedInputEditor: Identifiable {
    let id = UUID()
    let thread: CodingThread
    let original: QueuedTurn
    let commandID = UUID()
    var text: String
    var attachments: [ChatAttachment]
    var isSaving = false
    var errorMessage: String?
    @ObservationIgnored var imports: [UUID: Task<Void, Never>] = [:]
    init(thread: CodingThread, queued: QueuedTurn) { self.thread = thread; original = queued; text = queued.text; attachments = queued.attachments ?? [] }
    var canSave: Bool { !isSaving && imports.isEmpty && text.utf16.count <= 120_000 && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) }
    func close() { for job in imports.values { job.cancel() } }
    func drain() async { close(); for job in Array(imports.values) { await job.value } }
}
