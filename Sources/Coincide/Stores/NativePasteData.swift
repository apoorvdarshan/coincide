import Foundation

enum NativePasteData {
    @MainActor static func load(_ provider: NSItemProvider, type: String) async throws -> Data {
        let operation = PasteDataOperation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard operation.install(continuation) else { return }
                let progress = provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                    if let data { operation.finish(.success(data)) }
                    else { operation.finish(.failure(error ?? NSError(domain: "Coincide", code: 1, userInfo: [NSLocalizedDescriptionKey: "The pasted attachment could not be read."]))) }
                }
                operation.install(progress)
            }
        } onCancel: { operation.cancel() }
    }
}

private final class PasteDataOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var progress: Progress?
    private var finished = false
    func install(_ continuation: CheckedContinuation<Data, any Error>) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); continuation.resume(throwing: CancellationError()); return false }
        self.continuation = continuation; lock.unlock(); return true
    }
    func install(_ progress: Progress) {
        lock.lock()
        if finished { lock.unlock(); progress.cancel() }
        else { self.progress = progress; lock.unlock() }
    }
    func finish(_ result: Result<Data, any Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; let saved = continuation; continuation = nil; progress = nil; lock.unlock()
        saved?.resume(with: result)
    }
    func cancel() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; let saved = continuation, pending = progress; continuation = nil; progress = nil; lock.unlock()
        saved?.resume(throwing: CancellationError()); pending?.cancel()
    }
}
