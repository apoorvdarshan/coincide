import CloudKit
import CoincideRemoteKit
import Foundation
import Observation
import Security

/// A lock-screen alert for one phone, as written to the user's private CloudKit database. Holds no more than the
/// notification shows: the thread's title, what happened and a short line.
struct PushAlert: Codable, Equatable {
    var eventID: String
    var threadID: UUID
    var zone: String
    var title: String
    var subtitle: String
    var body: String
    var createdAt: Date

    /// The longest detail line written to CloudKit.
    static let maxBody = 120

    init(eventID: String, threadID: UUID, zone: String, title: String, subtitle: String, body: String, createdAt: Date) {
        self.eventID = eventID
        self.threadID = threadID
        self.zone = zone
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
    }

    init(_ alert: AlertContent, zone: String, createdAt: Date) {
        let line = alert.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A lock-screen alert without a body line shows nothing below its title, so what happened moves there.
        guard !line.isEmpty else {
            self.init(
                eventID: alert.id, threadID: alert.threadID, zone: zone, title: alert.title, subtitle: "",
                body: alert.subtitle, createdAt: createdAt)
            return
        }
        self.init(
            eventID: alert.id, threadID: alert.threadID, zone: zone, title: alert.title, subtitle: alert.subtitle,
            body: line.count > Self.maxBody ? String(line.prefix(Self.maxBody - 1)) + "…" : line, createdAt: createdAt)
    }
}

/// Writes and removes lock-screen alerts. CloudKit in the app; tests supply their own.
protocol AlertPusher: AnyObject {
    /// Whether alerts can be written at all: CloudKit is set up for this build and an iCloud account is signed in.
    var isAvailable: Bool { get }
    func save(_ alert: PushAlert) async throws
    func delete(_ alerts: [PushAlert]) async throws
}

/// What a failed write means for the alert.
enum PushFailure: Equatable {
    /// The record exists: an earlier attempt got through after all.
    case alreadyDelivered
    /// Worth another try, after the delay CloudKit asks for if it does.
    case transient(retryAfter: TimeInterval?)
    /// No account, no quota, no permission, no zone: the Mac notifies instead.
    case permanent

    static func classify(_ error: Error) -> PushFailure {
        if let error = error as? CKError {
            switch error.code {
            case .serverRecordChanged:
                return .alreadyDelivered
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy,
                .serverResponseLost:
                return .transient(retryAfter: error.retryAfterSeconds)
            case .partialFailure:
                guard let first = error.partialErrorsByItemID?.values.first else { return .permanent }
                return classify(first)
            default:
                return .permanent
            }
        }
        if error is URLError { return .transient(retryAfter: nil) }
        return .permanent
    }
}

/// Writes lock-screen alerts with a few retries for passing failures, and falls back to a Mac notification exactly
/// once when one can't be written. Remembers what it wrote, so seeing the thread anywhere removes it, and removes
/// what's older than `recordLifetime` in any case.
final class PushAlertDelivery {
    static let recordLifetime: TimeInterval = 6 * 60 * 60

    let pusher: AlertPusher
    let maxAttempts: Int
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval
    private let url: URL?
    private let sleep: (TimeInterval) async -> Void
    private let now: () -> Date
    private var tasks: [String: (threadID: UUID, task: Task<Void, Never>)] = [:]
    /// Alerts written and not yet removed.
    private(set) var written: [PushAlert]

    init(
        pusher: AlertPusher, url: URL?, maxAttempts: Int = 3, baseDelay: TimeInterval = 2, maxDelay: TimeInterval = 60,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) {
        self.pusher = pusher
        self.url = url
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.now = now
        self.sleep = sleep
        if let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([PushAlert].self, from: data) {
            written = saved
        } else {
            written = []
        }
    }

    var isAvailable: Bool { pusher.isAvailable }

    /// Writes the alert in the background. `fallback` runs at most once, only if it can't be written and the thread
    /// wasn't seen in the meantime.
    func deliver(_ alert: PushAlert, fallback: @escaping () -> Void) {
        pruneExpired()
        let task = Task { [weak self] in
            await self?.run(alert, fallback: fallback)
            self?.tasks[alert.eventID] = nil
        }
        tasks[alert.eventID] = (alert.threadID, task)
    }

    private func run(_ alert: PushAlert, fallback: () -> Void) async {
        var attempt = 0
        while !Task.isCancelled {
            attempt += 1
            do {
                try await pusher.save(alert)
                if !Task.isCancelled { remember(alert) } else { removeLater([alert]) }
                return
            } catch {
                // Seen while the write was under way: nothing to fall back to.
                guard !Task.isCancelled else { return }
                switch PushFailure.classify(error) {
                case .alreadyDelivered:
                    remember(alert)
                    return
                case .permanent:
                    fallback()
                    return
                case .transient(let retryAfter):
                    guard attempt < maxAttempts else {
                        fallback()
                        return
                    }
                    await sleep(min(maxDelay, retryAfter ?? baseDelay * pow(2, Double(attempt - 1))))
                }
            }
        }
    }

    /// Waits for writes under way, for tests.
    func waitUntilIdle() async {
        while let next = tasks.values.first?.task { await next.value }
    }

    /// The user saw the thread: cancel writes under way and remove written alerts.
    func threadSeen(_ threadID: UUID) {
        for (eventID, entry) in tasks where entry.threadID == threadID {
            entry.task.cancel()
            tasks[eventID] = nil
        }
        let seen = written.filter { $0.threadID == threadID }
        guard !seen.isEmpty else { return }
        written.removeAll { $0.threadID == threadID }
        save()
        removeLater(seen)
    }

    /// Removes alerts older than `recordLifetime`.
    func pruneExpired() {
        let cutoff = now().addingTimeInterval(-Self.recordLifetime)
        let expired = written.filter { $0.createdAt < cutoff }
        guard !expired.isEmpty else { return }
        written.removeAll { $0.createdAt < cutoff }
        save()
        removeLater(expired)
    }

    private func remember(_ alert: PushAlert) {
        written.removeAll { $0.eventID == alert.eventID }
        written.append(alert)
        save()
    }

    /// Removing is best effort: what fails here is removed by the next prune of the phone's zone or expires unseen.
    private func removeLater(_ alerts: [PushAlert]) {
        let pusher = pusher
        Task { try? await pusher.delete(alerts) }
    }

    private func save() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(written).write(to: url, options: .atomic)
        } catch {
            NSLog("Coincide: couldn’t save lock-screen alerts: \(error.localizedDescription)")
        }
    }
}

/// Lock-screen alerts in the user's private CloudKit database. Only builds signed with the iCloud container (see
/// `Coincide/CoincideCloudKit.entitlements`) can use CloudKit; others report it unavailable and never touch it,
/// since CloudKit stops an app that uses it without the entitlement.
@Observable
final class CloudKitAlertPusher: AlertPusher {
    static let shared = CloudKitAlertPusher()

    enum Status: Equatable {
        /// This build isn't signed for the iCloud container.
        case notConfigured
        case checking
        case available
        /// No iCloud account, or it is restricted.
        case noAccount
    }

    private(set) var status: Status

    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private lazy var container = CKContainer(identifier: RemoteAlerts.containerIdentifier)

    init() {
        guard Self.hasContainerEntitlement() else {
            status = .notConfigured
            return
        }
        status = .checking
        observer = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    var isAvailable: Bool { status == .available }

    func refresh() {
        guard status != .notConfigured else { return }
        let container = container
        Task { [weak self] in
            let accountStatus = try? await container.accountStatus()
            self?.status = accountStatus == .available ? .available : .noAccount
        }
    }

    private var database: CKDatabase { container.privateCloudDatabase }

    func save(_ alert: PushAlert) async throws {
        guard status != .notConfigured else { throw CKError(.missingEntitlement) }
        let zoneID = CKRecordZone.ID(zoneName: alert.zone, ownerName: CKCurrentUserDefaultName)
        let record = CKRecord(recordType: RemoteAlerts.recordType, recordID: CKRecord.ID(recordName: alert.eventID, zoneID: zoneID))
        record[RemoteAlerts.Field.eventID] = alert.eventID as CKRecordValue
        record[RemoteAlerts.Field.threadID] = alert.threadID.uuidString as CKRecordValue
        record[RemoteAlerts.Field.title] = alert.title as CKRecordValue
        record[RemoteAlerts.Field.subtitle] = alert.subtitle as CKRecordValue
        record[RemoteAlerts.Field.body] = alert.body as CKRecordValue
        record[RemoteAlerts.Field.collapseID] = RemoteAlerts.collapseID(eventID: alert.eventID) as CKRecordValue
        record[RemoteAlerts.Field.createdAt] = alert.createdAt as CKRecordValue
        // Unchanged-only: writing an event twice fails with serverRecordChanged instead of ringing the phone again.
        let (saved, _) = try await database.modifyRecords(
            saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        if case .failure(let error)? = saved[record.recordID] { throw error }
    }

    func delete(_ alerts: [PushAlert]) async throws {
        guard status != .notConfigured, !alerts.isEmpty else { return }
        let ids = alerts.map {
            CKRecord.ID(recordName: $0.eventID, zoneID: CKRecordZone.ID(zoneName: $0.zone, ownerName: CKCurrentUserDefaultName))
        }
        _ = try await database.modifyRecords(saving: [], deleting: ids, savePolicy: .changedKeys, atomically: false)
    }

    /// Whether this process is signed for the iCloud container.
    static func hasContainerEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
            let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains(RemoteAlerts.containerIdentifier) == true
    }
}
