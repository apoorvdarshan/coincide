import AppKit
import CoincideKit
import Observation
import SwiftUI

/// Settings › Browser's state, over `BrowserProfile`.
@Observable
final class BrowserSettingsModel {
    private(set) var settings: BrowserSettings
    private(set) var bookmarks: [BrowserBookmark] = []
    private(set) var historyCount = 0
    @ObservationIgnored let profile: BrowserProfile
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(profile: BrowserProfile = .shared) {
        self.profile = profile
        settings = profile.settings.settings
        reload()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: BrowserSettingsStore.didChange, object: profile.settings, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settings = profile.settings.settings }
        })
        observers.append(center.addObserver(forName: BrowserLibrary.didChange, object: profile.library, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func reload() {
        bookmarks = profile.library.bookmarks
        historyCount = profile.library.history.count
    }

    var usesPrivateSessions: Bool {
        get { settings.usesPrivateSessions }
        set { profile.settings.update { $0.usesPrivateSessions = newValue } }
    }

    var agentControlByDefault: Bool {
        get { settings.agentControlByDefault }
        set { profile.settings.update { $0.agentControlByDefault = newValue } }
    }

    func clear(siteData: Bool, history: Bool) async {
        await profile.clear(siteData: siteData, history: history)
        if siteData { PreviewSessions.shared.resetSessions() }
    }

    func remove(_ bookmark: BrowserBookmark) {
        profile.library.removeBookmarks { $0.id == bookmark.id }
    }
}

struct BrowserSettingsView: View {
    @State private var model = BrowserSettingsModel()
    @State private var confirmingClear = false
    @State private var clearing = false
    @State private var importing = false
    /// Set at launch when macOS reopened Coincide for Full Disk Access, so the import picks up where it was.
    static var opensImportOnAppear = false
    @State private var showsAllBookmarks = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $model.usesPrivateSessions) {
                    Text("Use private sessions")
                    Text(
                        model.usesPrivateSessions
                            ? "Each thread’s browser has its own temporary storage, cleared when Coincide quits. Imported cookies and saved sign-ins aren’t used."
                            : "All threads share one browser profile, so sign-ins and site data last across threads and relaunches. Each thread still has its own page and back/forward history."
                    )
                }
                LabeledContent {
                    Button(clearing ? "Clearing…" : "Clear Browsing Data…") { confirmingClear = true }
                        .disabled(clearing)
                } label: {
                    Text("Browsing data")
                    Text("History items: \(model.historyCount). Bookmarks are kept.")
                }
            } header: {
                Text("Profile")
            }

            Section {
                Toggle(isOn: $model.agentControlByDefault) {
                    Text("Agent Control in new threads")
                    Text(
                        "Agents can use their thread’s browser in the background and open it when they need you, for example to sign in. You can turn it off for any thread in its browser panel."
                    )
                }
                VStack(alignment: .leading, spacing: 4) {
                    Label("The connection is private to this Mac and to each thread, and ends when Coincide quits.", systemImage: "lock")
                    Label("Agents can’t read cookies, site storage or what’s typed in password fields.", systemImage: "eye.slash")
                    Label("Agents ask you to take over for sign-ins, CAPTCHAs and two-factor codes.", systemImage: "hand.raised")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .labelStyle(BrowserNoteLabelStyle())
            } header: {
                Text("Agents")
            }

            PasswordsSettingsSection()

            Section {
                LabeledContent {
                    Button("Import…") { importing = true }
                } label: {
                    Text("Import from another browser")
                    Text("Bring cookies and sign-ins, history and bookmarks from Safari, Chrome, Firefox and others. Nothing leaves this Mac.")
                }
            } header: {
                Text("Import")
            }

            Section {
                if model.bookmarks.isEmpty {
                    Text("Bookmark a page with the star in the browser’s address bar.")
                        .foregroundStyle(.secondary)
                } else {
                    let shown = showsAllBookmarks ? model.bookmarks : Array(model.bookmarks.prefix(12))
                    ForEach(shown) { bookmark in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(bookmark.title).lineLimit(1)
                                Text(bookmark.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button {
                                model.remove(bookmark)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help(Text("Remove Bookmark"))
                            .accessibilityLabel(Text("Remove Bookmark"))
                        }
                    }
                    if model.bookmarks.count > 12, !showsAllBookmarks {
                        Button("Show All \(model.bookmarks.count)") { showsAllBookmarks = true }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Bookmarks")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if Self.opensImportOnAppear {
                Self.opensImportOnAppear = false
                importing = true
            }
        }
        .sheet(isPresented: $importing) {
            BrowserImportSheet(profile: model.profile) { importing = false }
        }
        .confirmationDialog("Clear browsing data?", isPresented: $confirmingClear) {
            Button("Clear Everything", role: .destructive) { clear(siteData: true, history: true) }
            Button("Clear Cookies and Site Data", role: .destructive) { clear(siteData: true, history: false) }
            Button("Clear History", role: .destructive) { clear(siteData: false, history: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cookies and site data include sign-ins in the shared browser profile; pages open in threads reload. Bookmarks are kept.")
        }
    }

    private func clear(siteData: Bool, history: Bool) {
        clearing = true
        Task {
            await model.clear(siteData: siteData, history: history)
            clearing = false
        }
    }
}

/// A note with its symbol aligned to the first line of text.
private struct BrowserNoteLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.frame(width: 16)
            configuration.title
        }
    }
}
