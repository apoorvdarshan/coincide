import AppKit
import CoincideKit
import Observation
import SwiftUI

/// Coincide's menu bar item: a gauge with the share used of the window closest to its limit, across every enabled
/// provider and account. Clicking it lists each account's windows, credits and today's tokens. It shows the figures
/// Settings › Usage shows (`UsageInsights`), so opening it reads nothing the page has not, and it lives only while
/// Coincide runs. Settings › Usage turns it off.
@MainActor
final class UsageStatusItem: NSObject, NSPopoverDelegate {
    static let shared = UsageStatusItem()

    private var item: NSStatusItem?
    private var popover: NSPopover?
    private var observers: [NSObjectProtocol] = []
    private var storeObserver: ObservationToken?
    private var insights: UsageInsights { .shared }

    func start() {
        guard observers.isEmpty else { return }
        observers.append(
            NotificationCenter.default.addObserver(forName: UsageInsights.didChange, object: insights, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        storeObserver = AppStore.shared.observe { [weak self] change in
            if change == .settings { self?.update() }
        }
        update()
    }

    private func update() {
        guard AppStore.shared.settings.showsUsageInMenuBar else {
            popover?.close()
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        let item = item ?? makeItem()
        self.item = item
        guard let button = item.button else { return }
        let constrained = UsageInsights.mostConstrained(insights.accountLimits())
        let percent = constrained.map { Int($0.window.usedPercent.rounded()) }
        button.image = Self.gauge(percent: percent)
        button.imagePosition = percent == nil ? .imageOnly : .imageLeading
        button.attributedTitle =
            percent.map {
                NSAttributedString(
                    string: " \($0)%", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)])
            } ?? NSAttributedString()
        let summary = Self.summary(constrained)
        button.toolTip = summary
        button.setAccessibilityLabel(summary)
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle(_:))
        item.button?.setAccessibilityRole(.menuButton)
        return item
    }

    /// A gauge whose needle follows how much is used, drawn as a template so the menu bar tints it.
    static func gauge(percent: Int?) -> NSImage? {
        let name =
            switch percent ?? 0 {
            case ..<25: "gauge.with.dots.needle.0percent"
            case ..<50: "gauge.with.dots.needle.33percent"
            case ..<75: "gauge.with.dots.needle.50percent"
            case ..<95: "gauge.with.dots.needle.67percent"
            default: "gauge.with.dots.needle.100percent"
            }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        image?.isTemplate = true
        return image
    }

    /// "Coincide usage: Claude Code weekly limit 62% used, resets in 2d 3h".
    static func summary(_ constrained: (account: UsageInsights.AccountLimits, window: UsageLimitWindow)?, now: Date = Date()) -> String {
        guard let constrained else { return String(localized: "Coincide usage: no plan limits reported") }
        var text = String(
            localized:
                "Coincide usage: \(UsageFormat.title(constrained.account)) \(constrained.window.label.lowercased()) limit \(Int(constrained.window.usedPercent.rounded()))% used"
        )
        if let reset = constrained.window.resetDescription(at: now) { text += ", " + reset }
        return text
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        let controller = NSHostingController(rootView: UsageMenuView(close: { [weak popover] in popover?.performClose(nil) }))
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
        self.popover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        insights.refreshIfStale()
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }
}

/// The menu bar item's list: what each account's plan allows and today's tokens.
@Observable
private final class UsageMenuModel {
    private(set) var accounts: [UsageInsights.AccountLimits] = []
    private(set) var today = UsageTotals()
    private(set) var isRefreshing = false
    private(set) var lastScan: Date?
    private(set) var now = Date()
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: UsageInsights.didChange, object: UsageInsights.shared, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() {
        let insights = UsageInsights.shared
        now = Date()
        accounts = insights.accountLimits(now: now)
        today = UsageReport.make(insights.events, periodDays: 1, now: now).today
        isRefreshing = insights.isScanning || insights.isCheckingLimits
        lastScan = insights.lastScan
    }
}

private struct UsageMenuView: View {
    let close: () -> Void
    @State private var model = UsageMenuModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Usage").font(.headline)
                Spacer()
                if let lastScan = model.lastScan {
                    Text("Updated \(lastScan.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if model.accounts.isEmpty {
                        Text("No provider is turned on.")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                    }
                    ForEach(model.accounts) { account in
                        UsageMenuAccountRow(account: account, now: model.now) {
                            close()
                            NSApp.activate()
                            UsageNavigation.show(provider: account.provider)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(maxHeight: 460)
            .fixedSize(horizontal: false, vertical: true)
            divider
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Today").font(.caption).foregroundStyle(.secondary)
                    Text(
                        "\(UsageFormat.tokens(model.today.tokens.total)) tokens · \(model.today.hasPricedTokens ? "≈ " + UsageFormat.cost(model.today.cost) : "—")"
                    )
                    .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            divider
            HStack(spacing: 8) {
                Button {
                    Task { await UsageInsights.shared.refreshNow() }
                } label: {
                    HStack(spacing: 5) {
                        if model.isRefreshing { ProgressView().controlSize(.mini) }
                        Text("Refresh")
                    }
                }
                .disabled(model.isRefreshing)
                Spacer()
                Button("Open Coincide") {
                    close()
                    NSApp.activate()
                    (NSApp.delegate as? AppDelegate)?.mainWindow?.showWindow(nil)
                }
            }
            .buttonStyle(ThemedButtonStyle())
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 330)
        .foregroundStyle(Color(nsColor: Theme.ink))
        .background(Color(nsColor: Theme.floatingFill))
        .tint(Color(nsColor: Theme.ink))
    }

    private var divider: some View {
        Rectangle().fill(Color(nsColor: Theme.surfaceBorder)).frame(height: 1)
    }
}

/// One account in the menu: its name and plan, then each window, or why it has none. Clicking opens Settings › Usage.
private struct UsageMenuAccountRow: View {
    let account: UsageInsights.AccountLimits
    let now: Date
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    SettingsProviderIcon(kind: account.provider, size: 16)
                    Text(UsageFormat.title(account)).fontWeight(.medium).lineLimit(1)
                    if let plan = account.limits?.plan {
                        Text(UsageFormat.plan(plan)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let credits = account.limits?.credits {
                        Text(UsageFormat.credits(credits)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                let windows = (account.limits?.windows ?? []) + (account.limits?.modelWindows ?? [])
                if windows.isEmpty {
                    Text(UsageFormat.unavailable(account, settings: AppStore.shared.settings))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(windows) { window in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(window.label).font(.caption)
                                Spacer()
                                Text(UsageFormat.used(window)).font(.caption.monospacedDigit())
                            }
                            UsageWindowBar(window: window, provider: account.provider, now: now, height: 4)
                            if let reset = window.resetDescription(at: now) {
                                Text(reset).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            [window.label, UsageFormat.used(window), window.resetDescription(at: now)].compactMap { $0 }
                                .joined(separator: ", "))
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Color(nsColor: Theme.sidebarHover) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(String(localized: "Show in Settings › Usage"))
    }
}
