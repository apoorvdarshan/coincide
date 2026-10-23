import AppKit
import CoincideCore
import Observation
@preconcurrency import UserNotifications

@MainActor @Observable
final class NativeThreadNotifications {
    private static let preference = "threadNotificationMode"
    private(set) var mode: ThreadNotificationMode
    private(set) var permission = String(localized: "Not requested")
    private(set) var isRequesting = false
    private(set) var error: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let center: UNUserNotificationCenter?
    @ObservationIgnored private let delegate: ThreadNotificationDelegate
    @ObservationIgnored private var tracker = ThreadAttentionNotificationTracker()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var deliveryGeneration = 0
    @ObservationIgnored private var authorized = false
    @ObservationIgnored private var delivery: Task<Void, Never>?
    @ObservationIgnored private var pending: [UUID: ThreadAttentionNotification] = [:]
    @ObservationIgnored private var lastSound: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var focusObservation: ThreadNotificationFocusObservation?
    /// In-app banners for other conversations while Coincide is active.
    @ObservationIgnored var banners: ThreadBannerCoordinator?

    init(defaults: UserDefaults = .standard, onOpen: @escaping @MainActor (UUID) -> Void) {
        self.defaults = defaults
        mode = ThreadNotificationMode(rawValue: defaults.string(forKey: Self.preference) ?? "") ?? .off
        delegate = ThreadNotificationDelegate(onOpen: onOpen)
        // SwiftPM test helpers and the synthetic GUI bundle never request OS
        // permission, emit sounds or change the real application's Dock badge.
        if Bundle.main.bundleIdentifier == "com.apoorvdarshan.coincide" {
            center = .current()
            center?.delegate = delegate
        } else { center = nil }
        if center != nil {
            let token = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.clear() }
                }
            focusObservation = .init(token)
        }
    }

    func setMode(_ mode: ThreadNotificationMode) async {
        generation += 1
        isRequesting = false
        self.mode = mode; defaults.set(mode.rawValue, forKey: Self.preference)
        error = nil; clear()
        guard mode.showsNotifications, let center else { return }
        let owner = generation
        isRequesting = true
        defer { if owner == generation { isRequesting = false } }
        do {
            let settings = await center.notificationSettings()
            guard owner == generation else { return }
            if settings.authorizationStatus == .notDetermined {
                _ = try await center.requestAuthorization(options: [.alert, .badge])
            }
            guard owner == generation else { return }
            await refreshPermission()
        } catch {
            guard owner == generation else { return }
            self.error = String(localized: "Notification permission could not be requested. Try again in System Settings.")
        }
    }

    func refreshPermission() async {
        guard let center else { permission = String(localized: "Available in the packaged app"); return }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            authorized = true; permission = String(localized: "Allowed")
        case .denied:
            authorized = false; permission = String(localized: "Denied — enable Coincide in System Settings → Notifications")
        case .notDetermined:
            authorized = false; permission = String(localized: "Not requested")
        default:
            authorized = false; permission = String(localized: "Unavailable")
        }
    }

    func observe(_ snapshot: WorkspaceSnapshot, baseline: Bool, appIsActive: Bool) {
        let events = tracker.observe(snapshot, baseline: baseline)
        prunePending()
        let current = tracker
        banners?.observe(events, appIsActive: appIsActive) { current.eventIsCurrent($0) }
        guard mode != .off, center != nil, !events.isEmpty else { return }
        let previous = delivery, owner = generation, deliveryOwner = deliveryGeneration
        delivery = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == owner, self.deliveryGeneration == deliveryOwner, !Task.isCancelled else { return }
            for event in events {
                guard self.generation == owner, self.deliveryGeneration == deliveryOwner, !Task.isCancelled else { return }
                guard self.tracker.eventIsCurrent(event) else { continue }
                if self.mode.playsSound {
                    let clock = ContinuousClock.now
                    let sound = event.kind == .completed ? "Glass" : "Submarine"
                    if self.lastSound[sound].map({ $0.duration(to: clock) > .seconds(1) }) ?? true {
                        NSSound(named: NSSound.Name(sound))?.play()
                        self.lastSound[sound] = clock
                    }
                }
                guard self.mode.showsNotifications, !appIsActive, !(NSApp?.isActive ?? false), let center = self.center else { continue }
                await self.refreshPermission()
                guard self.generation == owner, self.deliveryGeneration == deliveryOwner, self.authorized,
                      self.tracker.eventIsCurrent(event), !(NSApp?.isActive ?? false), !Task.isCancelled else { continue }
                let content = UNMutableNotificationContent()
                content.title = event.title; content.body = event.threadTitle
                content.threadIdentifier = event.threadID.uuidString.lowercased()
                // Sound is played once above, keeping simultaneous thread alerts
                // from stacking duplicate system sounds.
                do {
                    try await center.add(.init(identifier: event.id, content: content, trigger: nil))
                    guard self.generation == owner, self.deliveryGeneration == deliveryOwner,
                          self.tracker.eventIsCurrent(event), !(NSApp?.isActive ?? false), !Task.isCancelled else {
                        center.removePendingNotificationRequests(withIdentifiers: [event.id])
                        center.removeDeliveredNotifications(withIdentifiers: [event.id]); continue
                    }
                    self.pending[event.threadID] = event
                    NSApp?.dockTile.badgeLabel = String(self.pending.count)
                } catch {
                    if self.generation == owner, self.deliveryGeneration == deliveryOwner, self.tracker.eventIsCurrent(event) {
                        self.error = String(localized: "A thread notification could not be delivered.")
                    }
                }
            }
        }
    }

    private func prunePending() {
        let stale = pending.values.filter { !tracker.eventIsCurrent($0) }
        guard !stale.isEmpty else { return }
        for event in stale { pending.removeValue(forKey: event.threadID) }
        if let center {
            let identifiers = stale.map(\.id)
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
            NSApp?.dockTile.badgeLabel = pending.isEmpty ? nil : String(pending.count)
        }
    }

    func clear() {
        deliveryGeneration += 1
        pending.removeAll()
        if let center {
            center.removeAllPendingNotificationRequests(); center.removeAllDeliveredNotifications()
            NSApp?.dockTile.badgeLabel = nil
        }
    }

    func shutdown() async {
        generation += 1
        isRequesting = false
        delivery?.cancel(); await delivery?.value; delivery = nil
        clear()
    }
}

@MainActor private final class ThreadNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    let onOpen: @MainActor (UUID) -> Void
    init(onOpen: @escaping @MainActor (UUID) -> Void) { self.onOpen = onOpen }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let prefix = "coincide.thread."
        let identifier = response.notification.request.identifier
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              identifier.hasPrefix(prefix), let id = UUID(uuidString: String(identifier.dropFirst(prefix.count))) else { return }
        await MainActor.run { self.onOpen(id) }
    }
}

private final class ThreadNotificationFocusObservation: @unchecked Sendable {
    let token: any NSObjectProtocol
    init(_ token: any NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}
