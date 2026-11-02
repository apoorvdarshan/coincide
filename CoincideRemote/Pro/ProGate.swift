import CoincideRemoteKit
import SwiftUI
import UIKit

/// The one gate for Coincide Pro. Without it, everything can be browsed (pairing, the tabs, every thread with its
/// messages, diffs and tool output, settings and usage), and every action that does something on the Mac shows the
/// paywall instead: sending or typing a prompt, approving, answering, stopping, starting threads, git and pull requests,
/// schedules, bots and Mac settings. The paywall can be closed, and comes back on the next action.
///
/// Views call `allows()` where an action starts (before a form opens, say), and `RemoteClient.request` checks every
/// request the Mac would act on (`RemoteRequest.needsPro`), so nothing gets through a view that forgot.
@MainActor
enum ProGate {
    /// Whether an action may run now. If not, the paywall shows over whatever is on screen.
    @discardableResult
    static func allows() -> Bool {
        if ProStore.shared.isPro { return true }
        PaywallPresenter.shared.present()
        return false
    }
}

extension RemoteRequest {
    /// Whether the Mac would act on this request, which needs Coincide Pro (`ProGate`). Reading (the workspace, a thread
    /// and its items, diffs, media, settings, lists) and the phone's own bookkeeping stay free. No `default`: a request
    /// the protocol adds must be put on one side here.
    var needsPro: Bool {
        switch self {
        case .hello, .pair, .ping, .workspace, .openThread, .closeThread, .loadEarlier, .markSeen, .diff, .usageLimits,
            .presence, .showThread, .settings, .settingsDocument, .setProjectExpanded, .media, .completions, .checkout,
            .usageDashboard, .rewindOptions, .composerNotice, .setSidebarOptions, .projectDefaults, .scheduledTasks,
            .gitState, .pullRequests, .pullRequest:
            false
        case .send, .steerQueued, .removeQueued, .stop, .respond, .answer, .dismissQuestion, .updateSettings, .newThread,
            .threadAction, .runScript, .newBotConversation, .saveBot, .deleteBot, .changeSetting, .settingsAction,
            .saveSettingsDocument, .changeCheckout, .forkThread, .rewind, .usageWarningAction, .saveProjectDefaults,
            .removeProject, .saveScheduledTask, .scheduledTaskAction, .gitAction, .pullRequestAction:
            true
        }
    }
}

/// Shows the paywall as a sheet over whatever is on screen, sheets included, so a gated action anywhere can show it.
/// It closes with its button or a swipe, and a later action shows it again.
@MainActor
final class PaywallPresenter {
    static let shared = PaywallPresenter()

    private weak var client: RemoteClient?
    private weak var appearance: AppearanceSettings?
    private weak var navigator: Navigator?
    private weak var shown: UIViewController?

    /// The app's state, for the paywall's environment; set once the window appears.
    func configure(client: RemoteClient, appearance: AppearanceSettings, navigator: Navigator) {
        self.client = client
        self.appearance = appearance
        self.navigator = navigator
    }

    var isShowing: Bool { shown?.presentingViewController != nil }

    func present() {
        guard !isShowing, let client, let appearance, let navigator, let top = Self.topViewController() else { return }
        let store = ProStore.shared
        let root = ThemedRoot(appearance: appearance, server: client.server) {
            NavigationStack {
                PaywallView(mode: .sheet) { [weak self] in self?.dismiss() }
            }
        }
        .environment(client)
        .environment(appearance)
        .environment(navigator)
        .environment(store)
        let host = UIHostingController(rootView: root)
        host.modalPresentationStyle = .pageSheet
        host.sheetPresentationController?.prefersGrabberVisible = true
        shown = host
        top.present(host, animated: true)
    }

    func dismiss() {
        shown?.dismiss(animated: true)
        shown = nil
    }

    /// Once, right after the first Mac is paired, unless Coincide Pro is already on; after the pairing screen has gone.
    func offerAfterFirstPairing() {
        let key = "paywall.shownAfterPairing"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard !ProStore.shared.isPro else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            if !ProStore.shared.isPro { present() }
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var top = scene?.keyWindow?.rootViewController else { return nil }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}
