import Foundation

/// One owned HTTP event response's bounded byte backlog. Callback boundaries
/// are not a memory budget: small fragments coalesce into FIFO chunks while a
/// slow consumer retains at most 512KiB, in chunks no larger than 16KiB.
final class OpenCodeHTTPEventBuffer: @unchecked Sendable {
    static let maximumBufferedBytes = 512 * 1_024
    static let maximumChunkBytes = 16 * 1_024
    private static let maximumBufferedChunks = maximumBufferedBytes / maximumChunkBytes

    enum AppendResult: Sendable, Equatable { case enqueued, overflow, terminated }
    private enum Terminal {
        case finished
        case failed(any Error)
    }
    private enum Delivery {
        case value(Data?)
        case failure(any Error)
    }
    /// Retained only by a stream's producer closure, never by this buffer or
    /// the request owner. Dropping the final unread stream cancels that request.
    private final class ConsumerLifetime: @unchecked Sendable {
        private weak var buffer: OpenCodeHTTPEventBuffer?
        init(buffer: OpenCodeHTTPEventBuffer) { self.buffer = buffer }
        deinit { buffer?.cancelConsumer() }
    }
    private typealias Waiter = CheckedContinuation<Data?, any Error>

    private let lock = NSLock()
    private let onCancel: @Sendable () -> Void
    private var chunks: [Data] = []
    private var head = 0
    private var bufferedBytes = 0
    private var terminal: Terminal?
    private var waiter: Waiter?
    private var consumerCancelled = false

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
        chunks.reserveCapacity(Self.maximumBufferedChunks)
    }

    /// The stream retains this buffer; the callback supplied by its request
    /// owner must capture that owner weakly. This buffer never stores a stream.
    func makeStream() -> AsyncThrowingStream<Data, any Error> {
        let lifetime = ConsumerLifetime(buffer: self)
        return AsyncThrowingStream(unfolding: { [self, lifetime] in
            defer { withExtendedLifetime(lifetime) {} }
            return try await next()
        })
    }

    /// Preserve every accepted byte, including the remaining available prefix
    /// of an oversized callback. Overflow is terminal; the prefix drains before
    /// that fixed error. The caller owns cancellation of the exact HTTP task.
    func append(_ data: Data) -> AppendResult {
        var immediate: (Waiter, Data)?
        lock.lock()
        guard !consumerCancelled, terminal == nil else { lock.unlock(); return .terminated }
        guard !data.isEmpty else { lock.unlock(); return .enqueued }
        var offset = data.startIndex
        if let waiting = waiter {
            let end = data.index(offset, offsetBy: min(data.distance(from: offset, to: data.endIndex), Self.maximumChunkBytes))
            immediate = (waiting, data.subdata(in: offset..<end))
            waiter = nil; offset = end
        }
        compactIfNeeded()
        let remaining = data.distance(from: offset, to: data.endIndex)
        var accepted = min(remaining, Self.maximumBufferedBytes - bufferedBytes)
        let overflow = accepted < remaining
        while accepted > 0 {
            if let tail = chunks.indices.last, chunks[tail].count < Self.maximumChunkBytes {
                let count = min(accepted, Self.maximumChunkBytes - chunks[tail].count)
                let end = data.index(offset, offsetBy: count)
                chunks[tail].append(contentsOf: data[offset..<end])
                offset = end; accepted -= count; bufferedBytes += count
            } else {
                let count = min(accepted, Self.maximumChunkBytes)
                let end = data.index(offset, offsetBy: count)
                chunks.append(data.subdata(in: offset..<end))
                offset = end; accepted -= count; bufferedBytes += count
            }
        }
        if overflow { terminal = .failed(OpenCodeHTTPError.eventBufferOverflow) }
        lock.unlock()
        if let (waiting, bytes) = immediate { waiting.resume(returning: bytes) }
        return overflow ? .overflow : .enqueued
    }

    /// Natural/error EOF never discards accepted bytes or replaces the first
    /// terminal cause. A pending consumer has no queued bytes, so it can finish.
    func finish(throwing error: (any Error)? = nil) {
        var waiting: Waiter?
        var delivery: Delivery?
        lock.lock()
        if terminal == nil {
            terminal = error.map(Terminal.failed) ?? .finished
            if let pending = waiter {
                waiting = pending; waiter = nil
                delivery = terminalDelivery()
            }
        }
        lock.unlock()
        if let waiting, let delivery { Self.resume(waiting, with: delivery) }
    }

    private func next() async throws -> Data? {
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: Waiter) in
                var delivery: Delivery?
                lock.lock()
                if consumerCancelled {
                    delivery = .failure(CancellationError())
                } else if bufferedBytes > 0 {
                    let value = chunks[head]
                    chunks[head] = Data(); head += 1; bufferedBytes -= value.count
                    compactIfNeeded()
                    delivery = .value(value)
                } else if terminal != nil {
                    delivery = terminalDelivery()
                } else if waiter != nil {
                    // Concurrent iterator consumers are unsupported. Reject the
                    // second waiter without replacing/leaking the first one.
                    delivery = .failure(OpenCodeHTTPError.invalidResponse)
                } else {
                    waiter = continuation
                }
                lock.unlock()
                if let delivery { Self.resume(continuation, with: delivery) }
            }
        } onCancel: {
            cancelConsumer()
        }
        // A queued/delivered value may race cancellation after its continuation
        // was detached under the lock. Cancelled consumers never receive it.
        try Task.checkCancellation()
        return result
    }

    private func cancelConsumer() {
        var waiting: Waiter?
        lock.lock()
        guard !consumerCancelled else { lock.unlock(); return }
        consumerCancelled = true
        waiting = waiter; waiter = nil
        chunks.removeAll(keepingCapacity: true); head = 0; bufferedBytes = 0
        lock.unlock()
        // Request cancellation may synchronously reenter finish(). Neither it
        // nor a resumed task runs while the buffer's lock is held.
        onCancel()
        waiting?.resume(throwing: CancellationError())
    }

    /// Caller holds lock. At most32 retained chunks exist; consumed slots are
    /// removed before appending, so callback count cannot grow the container.
    private func compactIfNeeded() {
        if head == chunks.count {
            chunks.removeAll(keepingCapacity: true); head = 0
        } else if head > 0 {
            chunks.removeFirst(head); head = 0
        }
    }

    /// Caller holds lock. Queued bytes are inspected before this method.
    private func terminalDelivery() -> Delivery {
        switch terminal {
        case .finished: .value(nil)
        case .failed(let error): .failure(error)
        case nil: .failure(OpenCodeHTTPError.invalidResponse)
        }
    }

    private static func resume(_ continuation: Waiter, with delivery: Delivery) {
        switch delivery {
        case .value(let bytes): continuation.resume(returning: bytes)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}
