import AppKit
import CoincideCore
import Observation

/// Transient, non-blocking feedback (T3's toasts). At most three banners are kept;
/// ordinary banners expire after five seconds, errors stay until dismissed, and
/// hovering the stack pauses expiry. A key replaces an earlier banner with that key.
@MainActor @Observable
final class InAppBannerCenter {
    enum Kind: Sendable, Equatable { case success, info, warning, error }
    struct Banner: Identifiable, Equatable {
        let id: UUID
        var kind: Kind
        var title: String
        var detail: String?
        var actionTitle: String?
        var key: String?
        var threadID: UUID?
        var expiresAt: ContinuousClock.Instant?
    }
    static let shared = InAppBannerCenter()
    static let maximumBanners = 3
    static let lifetime: Duration = .seconds(5)
    static let resumeGrace: Duration = .seconds(2)

    private(set) var banners: [Banner] = []
    private(set) var isHovering = false
    @ObservationIgnored private var hoverOwners: Set<UUID> = []
    private static let defaultHoverOwner = UUID()
    private final class Presentation { weak var window: NSWindow?; init(_ window: NSWindow) { self.window = window } }
    @ObservationIgnored private var presentations: [UUID: Presentation] = [:]
    @ObservationIgnored private var actions: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant
    @ObservationIgnored private let schedulesExpiry: Bool
    @ObservationIgnored private let announces: Bool
    @ObservationIgnored private var stopped = false

    /// Tests inject a clock and drive `expire(at:)` themselves.
    init(now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }, schedulesExpiry: Bool = true, announces: Bool = true) {
        self.now = now; self.schedulesExpiry = schedulesExpiry; self.announces = announces
    }

    @discardableResult
    func post(_ kind: Kind, title: String, detail: String? = nil, key: String? = nil, threadID: UUID? = nil,
              actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil) -> UUID {
        guard !stopped else { return UUID() }
        if let key { for banner in banners where banner.key == key { remove(banner.id) } }
        let id = UUID()
        let banner = Banner(id: id, kind: kind, title: title, detail: detail, actionTitle: action == nil ? nil : actionTitle, key: key,
                            threadID: threadID, expiresAt: kind == .error ? nil : now() + Self.lifetime)
        banners.insert(banner, at: 0)
        if let action { actions[id] = action }
        while banners.count > Self.maximumBanners {
            // Drop the oldest transient banner first; errors yield only to newer errors.
            let victim = banners.lastIndex(where: { $0.kind != .error }) ?? banners.indices.last!
            remove(banners[victim].id)
        }
        if announces, let window = presentations.values.compactMap(\.window).first(where: { $0.isKeyWindow && $0.attachedSheet == nil }), NSApp?.modalWindow == nil {
            let text = [title, detail].compactMap { $0 }.joined(separator: ". ")
            NSAccessibility.post(element: window, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        scheduleExpiry()
        return id
    }

    func dismiss(_ id: UUID) { remove(id); scheduleExpiry() }
    func registerPresentation(_ id: UUID, window: NSWindow?) {
        presentations = presentations.filter { $0.value.window != nil }
        presentations[id] = window.map(Presentation.init)
    }
    func dismiss(key: String) { for banner in banners where banner.key == key { remove(banner.id) }; scheduleExpiry() }
    func dismissAll(where predicate: (Banner) -> Bool) { for banner in banners where predicate(banner) { remove(banner.id) }; scheduleExpiry() }

    func performAction(_ id: UUID) {
        let action = actions[id]
        dismiss(id)
        action?()
    }

    func setHovering(_ hovering: Bool, owner: UUID? = nil) {
        let owner = owner ?? Self.defaultHoverOwner
        if hovering { hoverOwners.insert(owner) } else { hoverOwners.remove(owner) }
        let next = !hoverOwners.isEmpty
        guard next != isHovering else { return }
        isHovering = next
        if !next {
            let floor = now() + Self.resumeGrace
            for index in banners.indices { if let deadline = banners[index].expiresAt, deadline < floor { banners[index].expiresAt = floor } }
        }
        scheduleExpiry()
    }

    /// Removes expired banners unless the stack is hovered.
    func expire(at instant: ContinuousClock.Instant) {
        guard !isHovering else { return }
        for banner in banners where banner.expiresAt.map({ $0 <= instant }) == true { remove(banner.id) }
    }

    private func remove(_ id: UUID) {
        banners.removeAll { $0.id == id }
        actions.removeValue(forKey: id)
    }

    private func scheduleExpiry() {
        expiry?.cancel(); expiry = nil
        guard schedulesExpiry, !isHovering, let next = banners.compactMap(\.expiresAt).min() else { return }
        expiry = Task { [weak self] in
            try? await Task.sleep(until: next, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.expire(at: self.now()); self.scheduleExpiry()
        }
    }
    func shutdown() async {
        stopped = true
        let task = expiry; expiry = nil; task?.cancel(); await task?.value
        banners.removeAll(); actions.removeAll(); hoverOwners.removeAll(); presentations.removeAll(); isHovering = false
    }
}

/// Shows a banner when another conversation finishes, fails or needs input while
/// Coincide is active (T3 ThreadNotificationCoordinator). System notifications still
/// cover the background case; this path needs no notification permission.
@MainActor
final class ThreadBannerCoordinator {
    static let preference = "inAppThreadBanners"
    private let center: InAppBannerCenter
    private let defaults: UserDefaults
    private let selectedThreadID: @MainActor () -> UUID?
    private let open: @MainActor (UUID) -> Void
    private let currentThread: (@MainActor (UUID) -> CodingThread?)?
    private var shown: [String: ThreadAttentionNotification] = [:]
    private struct Identity: Equatable {
        let projectID: UUID
        let createdAt: Date
        let path: Data
        let preparationID: UUID?
        init(_ thread: CodingThread) {
            projectID = thread.projectID; createdAt = thread.createdAt; path = Data(thread.workspacePath.utf8)
            preparationID = thread.workspacePreparation?.id
        }
    }
    private var identities: [UUID: Identity] = [:]
    private var currentEvent: ((ThreadAttentionNotification) -> Bool)?

    init(center: InAppBannerCenter, defaults: UserDefaults = .standard, selectedThreadID: @escaping @MainActor () -> UUID?,
         currentThread: (@MainActor (UUID) -> CodingThread?)? = nil,
         open: @escaping @MainActor (UUID) -> Void) {
        self.center = center; self.defaults = defaults; self.selectedThreadID = selectedThreadID; self.currentThread = currentThread; self.open = open
    }

    var isEnabled: Bool { defaults.object(forKey: Self.preference) as? Bool ?? true }

    func observe(_ events: [ThreadAttentionNotification], appIsActive: Bool, snapshot: WorkspaceSnapshot? = nil,
                 isCurrent: @escaping (ThreadAttentionNotification) -> Bool) {
        currentEvent = isCurrent
        if let snapshot { identities = Dictionary(uniqueKeysWithValues: snapshot.threads.map { ($0.id, Identity($0)) }) }
        let selected = selectedThreadID()
        for (key, event) in shown where !isCurrent(event) || event.threadID == selected {
            center.dismiss(key: key); shown.removeValue(forKey: key)
        }
        guard isEnabled, appIsActive else {
            for key in shown.keys { center.dismiss(key: key) }; shown.removeAll(); return
        }
        for event in events where event.threadID != selected && isCurrent(event) {
            let kind: InAppBannerCenter.Kind = switch event.kind {
            case .completed: .success
            case .approval, .input: .warning
            case .failed: .error
            }
            let threadID = event.threadID
            guard let identity = identities[threadID] else { continue }
            center.post(kind, title: event.title, detail: event.threadTitle, key: event.id, threadID: threadID,
                        actionTitle: String(localized: "Open")) { [weak self] in
                guard let self, self.isEnabled, self.currentEvent?(event) == true,
                      self.identities[threadID] == identity else { return }
                if let currentThread = self.currentThread {
                    guard let thread = currentThread(threadID), Identity(thread) == identity else { return }
                }
                self.open(threadID)
            }
            shown[event.id] = event
        }
    }
}
