import CoincideRemoteKit
import SwiftUI
import UIKit

/// Connects the app's state to alerts: reports presence to the Mac (in front or not, the open thread, the last
/// touch), shows alerts the Mac sends as a banner, clears them when a thread is seen anywhere, and opens the thread
/// when one is tapped. While the app is locked behind Coincide Pro it reports itself as not in use and shows no alerts,
/// so the Mac goes on notifying where the user can act on them.
struct AlertsCoordinator: ViewModifier {
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(ProStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var alerts = PhoneAlerts.shared

    func body(content: Content) -> some View {
        content
            .background { InteractionTracker { client.noteInteraction() } }
            .overlay(alignment: .top) { AlertBanner(alerts: alerts) }
            .onAppear(perform: wire)
            .onChange(of: scenePhase) { _, phase in
                alerts.phase = Self.state(phase)
                if phase == .active {
                    client.noteInteraction()
                    Task { await alerts.refresh() }
                }
                reportLeavingIfNeeded(phase)
            }
            .onChange(of: navigator.selection) { client.sendPresence() }
            .onChange(of: client.isConnected) { _, connected in
                guard connected else { return }
                client.sendPresence()
                guard client.server?.notifies == true, store.isPro else { return }
                // Already paired before alerts existed: ask the first time the Mac is reached.
                Task { await alerts.requestAuthorizationIfNeeded() }
            }
            // Unlocked or locked: the Mac hears it at once, and an unlocked app asks for notifications as pairing would.
            .onChange(of: store.isPro) { _, unlocked in
                client.sendPresence()
                guard unlocked, client.isConnected, client.server?.notifies == true else { return }
                Task { await alerts.requestAuthorizationIfNeeded() }
            }
            // While in front, a heartbeat, so a phone that disappears without a word stops counting as active.
            .task(id: scenePhase == .active && client.isConnected) {
                guard scenePhase == .active, client.isConnected else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(RemotePresence.heartbeat))
                    guard !Task.isCancelled else { return }
                    client.sendPresence()
                }
            }
    }

    private static func state(_ phase: ScenePhase) -> RemotePresence.State {
        switch phase {
        case .active: .active
        case .inactive: .inactive
        case .background: .background
        @unknown default: .unknown
        }
    }

    private func wire() {
        alerts.phase = Self.state(scenePhase)
        alerts.visibleThread = { [navigator, alerts] in alerts.isForeground ? navigator.selection : nil }
        alerts.openThread = { [navigator] id in navigator.selection = id }
        alerts.onChange = { [client] in client.sendPresence() }
        client.onNotify = { [alerts, store] in if store.isPro { alerts.deliver($0) } }
        alerts.macKeepsQuiet = { [client] in
            RemoteMacPresence.keepsPhoneQuiet(client.macPresence, receivedAt: client.macPresenceReceivedAt, now: Date())
        }
        client.onClearNotifications = { [alerts] in alerts.clear($0) }
        client.onPaired = { [alerts, store] server in
            guard server.notifies != false, store.isPro else { return }
            Task { await alerts.requestAuthorizationIfNeeded() }
        }
        client.presenceSource = { [client, navigator, alerts, store] in
            // Locked: as if the app weren't in use, with no lock-screen zone, so alerts stay on the Mac.
            let unlocked = store.isPro
            let state = unlocked ? alerts.phase : .background
            return RemotePresence(
                state: state, openThreadID: state == .active ? navigator.selection : nil,
                idleSeconds: max(0, Date().timeIntervalSince(client.lastInteraction)), alertZone: unlocked ? alerts.alertZone : nil)
        }
        // Connected before this view appeared: report now.
        client.sendPresence()
    }

    /// Leaving the foreground, the Mac must hear it before iOS suspends the app, or it would keep sending alerts here.
    private func reportLeavingIfNeeded(_ phase: ScenePhase) {
        guard phase == .background else {
            client.sendPresence()
            return
        }
        let application = UIApplication.shared
        // The request times out well within the time iOS gives, and ends the task either way.
        let identifier = application.beginBackgroundTask(withName: "Presence", expirationHandler: nil)
        let request = client.sendPresence()
        Task {
            await request?.value
            application.endBackgroundTask(identifier)
        }
    }
}

/// An alert from the Mac at the top of the screen, in the theme. Tap to open the thread; swipe up to dismiss.
struct AlertBanner: View {
    let alerts: PhoneAlerts
    @Environment(\.theme) private var theme

    var body: some View {
        if let alert = alerts.banner {
            Button {
                alerts.open(alert.threadID)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol(alert.kind))
                        .font(.title3)
                        .foregroundStyle(tint(alert.kind))
                        .frame(width: 26)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alert.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(alert.subtitle).font(.footnote).foregroundStyle(theme.secondaryInk).lineLimit(1)
                        if let body = alert.body {
                            Text(body).font(.footnote).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(theme.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(theme.border, lineWidth: max(theme.borderWidth, 0.5)))
                .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.12), radius: 12, y: 4)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 520)
            .padding(.horizontal)
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
            .gesture(DragGesture(minimumDistance: 12).onEnded { value in
                if value.translation.height < 0 { withAnimation(.snappy) { alerts.banner = nil } }
            })
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text("Opens the thread."))
            .accessibilityAction(named: Text("Dismiss")) { alerts.banner = nil }
            .task(id: alert.id) {
                UIAccessibility.post(notification: .announcement, argument: "\(alert.title). \(alert.subtitle)")
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled, alerts.banner?.id == alert.id else { return }
                withAnimation(.snappy) { alerts.banner = nil }
            }
        }
    }

    private func symbol(_ kind: RemoteNotification.Kind) -> String {
        switch kind {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .approval: "hand.raised.fill"
        case .question: "questionmark.bubble.fill"
        case .unknown: "bell.fill"
        }
    }

    private func tint(_ kind: RemoteNotification.Kind) -> Color {
        switch kind {
        case .completed: .green
        case .failed: .orange
        case .approval, .question, .unknown: theme.accent
        }
    }
}

/// Reports every touch in the window without taking part in it, so the Mac knows when the phone was last used.
struct InteractionTracker: UIViewRepresentable {
    let onTouch: () -> Void

    func makeUIView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.onTouch = onTouch
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: TrackerView, context: Context) {
        view.onTouch = onTouch
    }

    final class TrackerView: UIView {
        var onTouch: (() -> Void)?
        private var recognizer: TouchRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            recognizer = nil
            guard let window else { return }
            let recognizer = TouchRecognizer { [weak self] in self?.onTouch?() }
            window.addGestureRecognizer(recognizer)
            self.recognizer = recognizer
        }
    }

    /// Notes a touch and fails at once, so the touch goes on to the views as if it weren't there.
    final class TouchRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
        private let onTouch: () -> Void

        init(onTouch: @escaping () -> Void) {
            self.onTouch = onTouch
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            onTouch()
            state = .failed
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}
