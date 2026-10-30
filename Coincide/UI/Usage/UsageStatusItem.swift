import AppKit
import CoincideKit
import Observation
import SwiftUI

/// Coincide's menu bar item. By default it shows the logo of the agent used last with the share used of that account's
/// most used limit; its list and Settings › Usage can pin an account's figure instead, show the closest limit across
/// all (with a gauge), or add a second figure beside the first (`AppSettings.menuBarUsage`). Clicking it shows the
/// overall usage and each account's windows, credits and figures. It shows the figures Settings › Usage shows
/// (`UsageInsights`), so opening it reads nothing the page has not, and it lives only while Coincide runs. Settings ›
/// Usage turns it off.
@MainActor
final class UsageStatusItem: NSObject {
    static let shared = UsageStatusItem()

    private var item: NSStatusItem?
    /// The list clicking the item drops down, in a panel that opens under the clicked item on whatever display and
    /// Space the user is on, over full-screen apps too, without activating Coincide.
    private let dropdown = StatusItemDropdown()
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
        let settings = AppStore.shared.settings
        guard settings.showsUsageInMenuBar else {
            dropdown.close()
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        let item = item ?? makeItem()
        self.item = item
        guard let button = item.button else { return }
        let readings = Self.readings(settings: settings, accounts: insights.accountLimits(), lastActive: insights.lastActive)
        button.image = Self.image(for: readings, mode: settings.usageDisplayMode)
        button.imagePosition = .imageOnly
        button.title = ""
        let summary = Self.summary(readings, mode: settings.usageDisplayMode)
        button.toolTip = summary
        button.setAccessibilityLabel(summary)
    }

    /// What the item shows for the user's choices: the first, then the second unless it reads the same.
    static func readings(
        settings: AppSettings, accounts: [UsageInsights.AccountLimits], lastActive: LastActiveAgent?
    ) -> [MenuBarUsageReading] {
        let choices = [settings.menuBarUsage] + [settings.menuBarSecondaryUsage].compactMap { $0 }
        var readings: [MenuBarUsageReading] = []
        for choice in choices {
            guard let reading = MenuBarUsage.reading(for: choice, accounts: accounts, lastActive: lastActive, mode: settings.usageDisplayMode),
                !readings.contains(where: { $0.provider == reading.provider && $0.account?.id == reading.account?.id && $0.text == reading.text })
            else { continue }
            readings.append(reading)
        }
        return readings
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle(_:))
        item.button?.setAccessibilityRole(.menuButton)
        return item
    }

    /// The item's whole image, drawn as one template so the menu bar tints it for light and dark bars and its highlight:
    /// each reading's logo (or the gauge) followed by its text. With no reading, the gauge alone. The gauge's needle
    /// follows what is used, or what is left (like a fuel gauge) when `mode` shows that.
    static func image(for readings: [MenuBarUsageReading], mode: UsageDisplayMode = .used) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let iconSize: CGFloat = 15
        let height: CGFloat = 18
        let segments: [(icon: NSImage?, text: NSAttributedString?)] =
            readings.isEmpty
            ? [(gauge(percent: nil), nil)]
            : readings.map { reading in
                let icon = reading.provider.map { Theme.logo(for: $0) } ?? gauge(percent: reading.window.map { $0.shownPercent(mode) })
                return (icon, reading.text.map { NSAttributedString(string: $0, attributes: attributes) })
            }
        let gap: CGFloat = 3
        let spacing: CGFloat = 7
        let widths = segments.map { segment in iconSize + (segment.text.map { gap + ceil($0.size().width) } ?? 0) }
        let width = widths.reduce(0, +) + spacing * CGFloat(max(0, segments.count - 1))
        let image = NSImage(size: NSSize(width: max(width, iconSize), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (index, segment) in segments.enumerated() {
                let iconRect = NSRect(x: x, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
                if let icon = segment.icon {
                    icon.draw(in: Self.fitted(icon.size, in: iconRect))
                    // A silhouette, so a colored logo (Claude's) tints like the rest.
                    NSColor.black.setFill()
                    iconRect.fill(using: .sourceAtop)
                }
                if let text = segment.text {
                    let size = text.size()
                    text.draw(at: NSPoint(x: iconRect.maxX + gap, y: (height - size.height) / 2))
                }
                x += widths[index] + spacing
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// `size` scaled to fit `rect`, centered.
    private static func fitted(_ size: NSSize, in rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    /// A gauge whose needle follows `percent`, drawn as a template so the menu bar tints it.
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

    /// "Coincide usage: Claude Code weekly limit 62% used, resets in 2d 3h. Codex: $12.40 left" ("38% left" when
    /// `mode` shows what is left).
    static func summary(_ readings: [MenuBarUsageReading], mode: UsageDisplayMode = .used, now: Date = Date()) -> String {
        let parts = readings.compactMap { reading -> String? in
            guard let account = reading.account else { return nil }
            if let window = reading.window {
                var text =
                    mode == .used
                    ? String(localized: "\(UsageFormat.title(account)) \(window.label.lowercased()) limit \(window.shownPercent(.used))% used")
                    : String(localized: "\(UsageFormat.title(account)) \(window.label.lowercased()) limit \(window.shownPercent(.remaining))% left")
                if let reset = window.resetDescription(at: now) { text += ", " + reset }
                return text
            }
            if let figure = reading.figure {
                return "\(UsageFormat.title(account)): \(UsageRow.figure(figure, mode: mode, now: now).value)"
            }
            if let credits = reading.credits { return "\(UsageFormat.title(account)): \(UsageFormat.credits(credits))" }
            return String(localized: "\(UsageFormat.title(account)): no limits reported")
        }
        guard !parts.isEmpty else { return String(localized: "Coincide usage: no plan limits reported") }
        return String(localized: "Coincide usage: \(parts.joined(separator: ". "))")
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if dropdown.isShown {
            dropdown.close()
            return
        }
        let controller = NSHostingController(rootView: UsageMenuView(close: { [weak dropdown = self.dropdown] in dropdown?.close() }))
        controller.sizingOptions = .preferredContentSize
        controller.preferredContentSize = controller.sizeThatFits(
            in: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        controller.title = String(localized: "Usage")
        // Where the click was, so the list opens under it even if the item's frame is from another display's menu bar.
        let mouse = NSApp.currentEvent.flatMap { Self.isMouseClick($0.type) ? NSEvent.mouseLocation : nil }
        dropdown.show(controller, under: sender, mouse: mouse)
        insights.refreshIfStale()
    }

    private static func isMouseClick(_ type: NSEvent.EventType) -> Bool {
        [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp].contains(type)
    }
}

/// The menu bar item's list: usage across all agents, then what each account's plan allows.
@Observable
private final class UsageMenuModel {
    private(set) var accounts: [UsageInsights.AccountLimits] = []
    private(set) var report = UsageReport()
    private(set) var closest: (account: UsageInsights.AccountLimits, window: UsageLimitWindow)?
    /// Coincide's turns with each Anthropic API-key account, by `UsageReport.accountKey`.
    private(set) var tracked: [String: UsageReport] = [:]
    private(set) var isRefreshing = false
    private(set) var lastScan: Date?
    private(set) var now = Date()
    /// Used or what is left, kept in step with the setting (which Settings › Usage may change while the list shows).
    var displayMode: UsageDisplayMode = AppStore.shared.settings.usageDisplayMode {
        didSet {
            guard AppStore.shared.settings.usageDisplayMode != displayMode else { return }
            AppStore.shared.updateSettings { $0.usageDisplayMode = displayMode }
        }
    }
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var storeObserver: ObservationToken?

    init() {
        observer = NotificationCenter.default.addObserver(forName: UsageInsights.didChange, object: UsageInsights.shared, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.reload() }
        }
        storeObserver = AppStore.shared.observe { [weak self] change in
            guard change == .settings, let self, self.displayMode != AppStore.shared.settings.usageDisplayMode else { return }
            self.displayMode = AppStore.shared.settings.usageDisplayMode
        }
        reload()
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var menuBarUsage: MenuBarUsageChoice? {
        get { AppStore.shared.settings.menuBarUsage }
        set { AppStore.shared.updateSettings { $0.menuBarUsage = newValue ?? .lastActive } }
    }

    var menuBarSecondaryUsage: MenuBarUsageChoice? {
        get { AppStore.shared.settings.menuBarSecondaryUsage }
        set { AppStore.shared.updateSettings { $0.menuBarSecondaryUsage = newValue } }
    }

    func reload() {
        let insights = UsageInsights.shared
        now = Date()
        accounts = insights.accountLimits(now: now)
        closest = UsageInsights.mostConstrained(accounts)
        tracked = UsageRow.trackedReports(accounts, events: insights.events, now: now)
        report = UsageReport.make(insights.events, periodDays: 30, now: now)
        isRefreshing = insights.isScanning || insights.isCheckingLimits
        lastScan = insights.lastScan
    }
}

private struct UsageMenuView: View {
    let close: () -> Void
    @State private var model = UsageMenuModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Usage").font(.headline)
                    if let lastScan = model.lastScan {
                        Text("Updated \(lastScan.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                UsageDisplayModeToggle(mode: $model.displayMode)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            overall
            divider
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if model.accounts.isEmpty {
                        Text("No provider is turned on.")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                    }
                    ForEach(model.accounts) { account in
                        UsageMenuAccountRow(
                            account: account, mode: model.displayMode, now: model.now,
                            tracked: model.tracked[UsageReport.accountKey(account.provider, account.account.id)]
                        ) {
                            close()
                            NSApp.activate()
                            UsageNavigation.show(provider: account.provider)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
            divider
            VStack(spacing: 6) {
                MenuBarUsagePicker(title: String(localized: "Menu bar shows"), choice: $model.menuBarUsage, accounts: model.accounts)
                MenuBarUsagePicker(
                    title: String(localized: "Also show"), choice: $model.menuBarSecondaryUsage, accounts: model.accounts, allowsNone: true)
                UsageRefreshPicker(showsDescription: false)
            }
            .font(.caption)
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
        .frame(width: 340)
        .foregroundStyle(Color(nsColor: Theme.ink))
        .background(Color(nsColor: Theme.floatingFill))
        .tint(Color(nsColor: Theme.ink))
    }

    /// Tokens and estimated cost across every agent today and over the last 7 and 30 days, and the closest limit.
    private var overall: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Overall").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 0) {
                period(String(localized: "Today"), model.report.today)
                period(String(localized: "7 days"), model.report.lastWeek)
                period(String(localized: "30 days"), model.report.lastMonth)
            }
            if let closest = model.closest {
                let row = UsageRow.closest(closest.account, closest.window, mode: model.displayMode, now: model.now)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        SettingsProviderIcon(kind: closest.account.provider, size: 14)
                        Text("Closest limit").font(.caption).foregroundStyle(.secondary)
                    }
                    UsageRowView(row: row, provider: closest.account.provider, compact: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Closest limit") + ", " + row.accessibilityLabel)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func period(_ title: String, _ totals: UsageTotals) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(UsageFormat.tokens(totals.tokens.total)).font(.body.monospacedDigit())
                .help(UsageFormat.exactTokens(totals.tokens.total))
            Text(totals.hasPricedTokens ? "≈ " + UsageFormat.cost(totals.cost) : "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help(UsageFormat.exactCost(totals))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var divider: some View {
        Rectangle().fill(Color(nsColor: Theme.surfaceBorder)).frame(height: 1)
    }
}

/// One account in the menu: its name and plan, then a row for each window, credits and figure, or why it has none.
/// Clicking opens Settings › Usage.
private struct UsageMenuAccountRow: View {
    let account: UsageInsights.AccountLimits
    let mode: UsageDisplayMode
    let now: Date
    /// Coincide's own turns with the account, for an API key with no balance to show.
    var tracked: UsageReport?
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    SettingsProviderIcon(kind: account.provider, size: 16)
                    Text(UsageFormat.title(account)).fontWeight(.medium).lineLimit(1)
                    if let plan = account.limits?.plan {
                        Text(UsageFormat.plan(plan)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                let rows = account.limits.map { UsageRow.rows($0, marks: account.balanceMarks, mode: mode, now: now) } ?? []
                if rows.isEmpty && (account.limits?.notes ?? []).isEmpty && tracked == nil {
                    Text(UsageFormat.unavailable(account, settings: AppStore.shared.settings))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    UsageRowView(row: row, provider: account.provider, compact: true)
                }
                if let tracked {
                    UsageTrackedRows(report: tracked, compact: true)
                }
                ForEach(account.limits?.notes ?? [], id: \.self) { note in
                    Text(note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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

/// Switches between showing what is used and what is left: a small two-part control for the list's header.
struct UsageDisplayModeToggle: View {
    @Binding var mode: UsageDisplayMode

    var body: some View {
        HStack(spacing: 0) {
            ForEach(UsageDisplayMode.allCases, id: \.self) { option in
                let isSelected = option == mode
                Button {
                    mode = option
                } label: {
                    Text(UsageFormat.displayModeName(option))
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isSelected ? Color(nsColor: Theme.sidebarSelection) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? Color(nsColor: Theme.ink) : .secondary)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: Theme.raisedFill)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(nsColor: Theme.surfaceBorder), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Show usage as"))
        .help(String(localized: "Show what is used of each limit, or what is left"))
    }
}

/// Picks what the menu bar item shows: the last active agent, the closest limit across all, or one account's most used
/// limit, one of its windows or its balance. With `allowsNone`, also nothing (for the second figure).
struct MenuBarUsagePicker: View {
    let title: String
    @Binding var choice: MenuBarUsageChoice?
    let accounts: [UsageInsights.AccountLimits]
    var allowsNone = false

    var body: some View {
        ThemedPicker(selection: $choice, options: Self.options(accounts: accounts, allowsNone: allowsNone, current: choice)) {
            Text(title)
        }
    }

    static func options(
        accounts: [UsageInsights.AccountLimits], allowsNone: Bool, current: MenuBarUsageChoice?
    ) -> [ThemedPicker<MenuBarUsageChoice?, Text>.Option] {
        typealias Option = ThemedPicker<MenuBarUsageChoice?, Text>.Option
        var options: [Option] = []
        if allowsNone { options.append(Option(nil, String(localized: "None"))) }
        options.append(Option(.lastActive, String(localized: "Auto (last active agent)")))
        options.append(Option(.closest, String(localized: "Closest limit across all")))
        for account in accounts {
            let group = UsageFormat.title(account)
            let image = Theme.logo(for: account.provider, size: 14)
            func option(_ metric: MenuBarUsageMetric, _ name: String) -> Option {
                Option(
                    .account(provider: account.provider, accountID: account.account.id, metric: metric), "\(group) · \(name)",
                    image: image, group: group)
            }
            options.append(option(.mostUsed, String(localized: "Most used limit")))
            for window in MenuBarUsage.allWindows(account) {
                options.append(option(.window(window.id), window.label))
            }
            if MenuBarUsage.hasBalance(account) {
                options.append(option(.balance, String(localized: "Balance")))
            }
        }
        // A pinned window that is not reported now (not checked yet, say) stays listed, so the field names it.
        if let current, !options.contains(where: { $0.value == current }) {
            options.append(Option(current, String(localized: "Not reported now")))
        }
        return options
    }
}
