import AppKit
import CoincideKit
import Observation
import SwiftUI

/// Settings › Browser › Import: pick a browser and profile, choose what to bring, scan (macOS may ask for Keychain
/// access or Full Disk Access first), pick sites for cookies, then import into the shared profile and library.
@Observable
final class BrowserImportModel {
    enum Phase {
        case choose
        case scanning
        case review(BrowserImportData)
        case importing
        case done(BrowserImportSummary, [BrowserImportProblem])
    }

    let sources: [BrowserCatalog.Detected]
    var sourceID: String? { didSet { if sourceID != oldValue { profileID = source?.profiles.first?.id } } }
    var profileID: String?
    var kinds: Set<BrowserImportKind> = [.cookies, .history, .bookmarks]
    var phase = Phase.choose
    var selectedSites: Set<String> = []
    var siteFilter = ""
    @ObservationIgnored private let profile: BrowserProfile
    @ObservationIgnored private let home: URL

    init(profile: BrowserProfile, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        appURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
    {
        self.profile = profile
        self.home = home
        sources = BrowserCatalog.detect(home: home, appURL: appURL)
        sourceID = sources.first { $0.status == .available }?.id
        profileID = source?.profiles.first?.id
    }

    var source: BrowserCatalog.Detected? { sources.first { $0.id == sourceID } }
    var selectedProfile: BrowserCatalog.Profile? { source?.profiles.first { $0.id == profileID } }
    var importable: [BrowserCatalog.Detected] { sources.filter { if case .unsupported = $0.status { false } else { true } } }
    var unsupported: [BrowserCatalog.Detected] { sources.filter { if case .unsupported = $0.status { true } else { false } } }

    var canScan: Bool {
        guard let source, source.status == .available, selectedProfile != nil else { return false }
        return !kinds.intersection(source.kinds).isEmpty
    }

    func scan() {
        guard let source, let selected = selectedProfile else { return }
        phase = .scanning
        let kinds = kinds, home = home
        Task {
            let data = await Task.detached {
                BrowserImporter.scan(source, profile: selected, kinds: kinds, home: home) { SafeStorageKeychain.password(services: $0) }
            }.value
            selectedSites = Set(data.sites.map(\.site))
            if data.cookies.isEmpty, data.history.isEmpty, data.bookmarks.isEmpty {
                phase = .done(BrowserImportSummary(), data.problems)
            } else {
                phase = .review(data)
            }
        }
    }

    func importReviewed() {
        guard case .review(let data) = phase else { return }
        phase = .importing
        let cookies = data.cookies(forSites: selectedSites)
        Task {
            var summary = BrowserImportSummary()
            summary.cookies = await profile.importCookies(cookies)
            summary.sites = Set(cookies.map(\.site)).count
            summary.history = profile.library.mergeHistory(data.history)
            summary.bookmarks = profile.library.mergeBookmarks(data.bookmarks)
            profile.library.flush()
            if summary.cookies > 0 { PreviewSessions.shared.resetSessions() }
            phase = .done(summary, data.problems)
        }
    }
}

struct BrowserImportSheet: View {
    @State private var model: BrowserImportModel
    let close: () -> Void

    init(profile: BrowserProfile, close: @escaping () -> Void) {
        _model = State(initialValue: BrowserImportModel(profile: profile))
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import from Another Browser").font(.title3.weight(.semibold))
            switch model.phase {
            case .choose: chooser
            case .scanning: progress(String(localized: "Reading the browser’s data…"))
            case .review(let data): review(data)
            case .importing: progress(String(localized: "Importing…"))
            case .done(let summary, let problems): done(summary, problems)
            }
        }
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 420)
        .background(Color(nsColor: Theme.contentBackground))
        .toggleStyle(ThemedSwitchToggleStyle())
        .buttonStyle(ThemedButtonStyle())
        .tint(Color(nsColor: Theme.ink))
    }

    // MARK: Choose

    @ViewBuilder private var chooser: some View {
        if model.sources.isEmpty {
            Text("No supported browsers were found on this Mac.").foregroundStyle(.secondary)
            Spacer()
            HStack { Spacer(); Button("Close", action: close).keyboardShortcut(.cancelAction) }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.importable) { source in sourceRow(source) }
                    if !model.unsupported.isEmpty {
                        Text("Not supported").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                        ForEach(model.unsupported) { source in unsupportedRow(source) }
                    }
                }
            }
            .frame(maxHeight: 220)
            if let source = model.source {
                if source.profiles.count > 1 {
                    ThemedPicker(
                        selection: Binding(get: { model.profileID ?? "" }, set: { model.profileID = $0 }),
                        options: source.profiles.map { .init($0.id, $0.name) }
                    ) { Text("Profile") }
                }
                HStack(spacing: 16) {
                    kindToggle(.cookies, String(localized: "Cookies and sign-ins"), source)
                    kindToggle(.history, String(localized: "History"), source)
                    kindToggle(.bookmarks, String(localized: "Bookmarks"), source)
                }
                explanation(for: source)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Continue") { model.scan() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canScan)
            }
        }
    }

    private func sourceRow(_ source: BrowserCatalog.Detected) -> some View {
        let selected = model.sourceID == source.id
        return Button {
            model.sourceID = source.id
        } label: {
            HStack(spacing: 10) {
                BrowserIcon(appURL: source.appURL)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.definition.name)
                    if source.status == .needsFullDiskAccess {
                        Text("Needs Full Disk Access").font(.caption).foregroundStyle(.secondary)
                    } else if source.profiles.isEmpty {
                        Text("No profile data found").font(.caption).foregroundStyle(.secondary)
                    } else if source.profiles.count > 1 {
                        Text("Profiles: \(source.profiles.count)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color(nsColor: Theme.ink)) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: selected ? Theme.sidebarSelection : .clear)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func unsupportedRow(_ source: BrowserCatalog.Detected) -> some View {
        HStack(spacing: 10) {
            BrowserIcon(appURL: source.appURL).opacity(0.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.definition.name).foregroundStyle(.secondary)
                if case .unsupported(let reason) = source.status {
                    Text(Self.reason(reason)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    static func reason(_ reason: BrowserCatalog.Unsupported) -> String {
        switch reason {
        case .encryptedStore: String(localized: "Encrypts its data with a key only the app can use.")
        case .unreadableFormat: String(localized: "Keeps its data in a format Coincide can’t read.")
        }
    }

    private func kindToggle(_ kind: BrowserImportKind, _ title: String, _ source: BrowserCatalog.Detected) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { model.kinds.contains(kind) && source.kinds.contains(kind) },
                set: { if $0 { model.kinds.insert(kind) } else { model.kinds.remove(kind) } })
        )
        .toggleStyle(ThemedCheckboxToggleStyle())
        .disabled(!source.kinds.contains(kind))
    }

    @ViewBuilder private func explanation(for source: BrowserCatalog.Detected) -> some View {
        Group {
            if source.status == .needsFullDiskAccess {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "macOS protects \(source.definition.name)’s data. To import it, turn on Coincide in System Settings › Privacy & Security › Full Disk Access, then open this again."
                    )
                    Button("Open Privacy Settings") { Self.openFullDiskAccess() }
                }
            } else if case .chromium(let services) = source.definition.engine, model.kinds.contains(.cookies) {
                Text(
                    "\(source.definition.name) encrypts cookies with a key in your Keychain. macOS will ask whether Coincide may use “\(services.first ?? "")”; choose Allow to import cookies. The key is used once, on this Mac, and isn’t kept."
                )
            } else {
                Text("Coincide reads a copy of the data. Nothing is sent anywhere.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    static func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Review

    @ViewBuilder private func review(_ data: BrowserImportData) -> some View {
        let sites = data.sites
        VStack(alignment: .leading, spacing: 8) {
            Text("History items: \(data.history.count) · Bookmarks: \(data.bookmarks.count)")
                .foregroundStyle(.secondary)
            if !sites.isEmpty {
                HStack {
                    Text("Cookies from these sites").font(.headline)
                    Spacer()
                    Button("All") { model.selectedSites = Set(sites.map(\.site)) }.buttonStyle(.borderless)
                    Button("None") { model.selectedSites = [] }.buttonStyle(.borderless)
                }
                TextField("Filter sites", text: $model.siteFilter)
                    .textFieldStyle(ThemedTextFieldStyle())
                List {
                    ForEach(sites.filter { model.siteFilter.isEmpty || $0.site.localizedStandardContains(model.siteFilter) }, id: \.site) { entry in
                        Toggle(
                            isOn: Binding(
                                get: { model.selectedSites.contains(entry.site) },
                                set: { if $0 { model.selectedSites.insert(entry.site) } else { model.selectedSites.remove(entry.site) } })
                        ) {
                            HStack {
                                Text(entry.site)
                                Spacer()
                                Text(entry.cookies, format: .number).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .toggleStyle(ThemedCheckboxToggleStyle())
                    }
                }
                .scrollContentBackground(.hidden)
                .frame(minHeight: 180)
            }
            problemList(data.problems)
        }
        Spacer(minLength: 0)
        HStack {
            Spacer()
            Button("Cancel", action: close).keyboardShortcut(.cancelAction)
            Button("Import") { model.importReviewed() }.keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Done

    @ViewBuilder private func done(_ summary: BrowserImportSummary, _ problems: [BrowserImportProblem]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            summaryRow(String(localized: "Cookies"), summary.cookies)
            summaryRow(String(localized: "Sites"), summary.sites)
            summaryRow(String(localized: "History items"), summary.history)
            summaryRow(String(localized: "Bookmarks"), summary.bookmarks)
        }
        problemList(problems)
        Spacer(minLength: 0)
        HStack { Spacer(); Button("Done", action: close).keyboardShortcut(.defaultAction) }
    }

    private func summaryRow(_ title: String, _ count: Int) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(count, format: .number).monospacedDigit()
        }
    }

    @ViewBuilder private func problemList(_ problems: [BrowserImportProblem]) -> some View {
        ForEach(Array(Set(problems)), id: \.self) { problem in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Color(nsColor: Theme.warning))
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.message(problem))
                    if problem.reason == .needsFullDiskAccess {
                        Button("Open Privacy Settings") { Self.openFullDiskAccess() }
                    }
                }
            }
            .font(.callout)
        }
    }

    static func message(_ problem: BrowserImportProblem) -> String {
        let kind =
            switch problem.kind {
            case .cookies: String(localized: "Cookies")
            case .history: String(localized: "History")
            case .bookmarks: String(localized: "Bookmarks")
            }
        return switch problem.reason {
        case .needsFullDiskAccess: String(localized: "\(kind): Coincide needs Full Disk Access to read them.")
        case .keyUnavailable: String(localized: "\(kind): the browser’s Keychain key wasn’t available, so none were imported. Try again and choose Allow.")
        case .undecryptable: String(localized: "\(kind): they couldn’t be decrypted with the browser’s key.")
        case .unreadable: String(localized: "\(kind): the browser’s file couldn’t be read.")
        }
    }

    private func progress(_ title: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView().controlSize(.small)
            Text(title).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// An installed browser's own icon, or a neutral globe when only its data is on this Mac.
struct BrowserIcon: View {
    let appURL: URL?
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let appURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "globe").resizable().scaledToFit().padding(size * 0.12).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
