import AppKit
import CoincideKit
import Observation
import SwiftUI

/// The archived threads, newest first, grouped by project, kept current as threads are archived and deleted.
@MainActor
@Observable
final class ArchiveSettingsModel {
    struct Group: Identifiable {
        var project: Project
        var threads: [ThreadSummary]
        var id: UUID { project.id }
    }

    private(set) var groups: [Group] = []
    var filter = "" { didSet { reload() } }

    @ObservationIgnored private let store: AppStore
    @ObservationIgnored private var token: ObservationToken?

    init(store: AppStore = .shared) {
        self.store = store
        token = store.observe { [weak self] _ in self?.reload() }
        reload()
    }

    var allThreadIDs: [UUID] { groups.flatMap { $0.threads.map(\.id) } }

    /// Archive Thread's shortcut as the user set it, such as "⌘W".
    var archiveShortcut: String? { store.settings.keyBindings.shortcut(for: .archiveThread)?.displayString }

    func reload() {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        groups = store.projects.compactMap { project in
            let threads = store.threads(in: project.id, includeArchived: true)
                .filter { $0.isArchived && (query.isEmpty || $0.title.localizedStandardContains(query)) }
                .sorted { $0.updatedAt > $1.updatedAt }
            return threads.isEmpty ? nil : Group(project: project, threads: threads)
        }
        .sorted { ($0.threads.first?.updatedAt ?? .distantPast) > ($1.threads.first?.updatedAt ?? .distantPast) }
    }

    func unarchive(_ id: UUID) {
        ThreadInbox.shared.archive([id], archived: false)
    }

    /// Deletes one thread, asking first when the user wants that. Undoable until Coincide quits.
    func delete(_ id: UUID) {
        ThreadActions.delete(id, in: SettingsWindowController.shared.window)
    }

    /// Deletes every archived thread listed, always asking first. Undoable until Coincide quits.
    func deleteAll() {
        ThreadActions.delete(allThreadIDs, in: SettingsWindowController.shared.window, alwaysConfirm: true)
    }
}

/// Settings › Archive: every archived thread, to bring back to the sidebar or delete, one at a time or all at once.
struct ArchiveSettingsView: View {
    @State private var model: ArchiveSettingsModel

    init(model: ArchiveSettingsModel = ArchiveSettingsModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let isFiltering = !model.filter.trimmingCharacters(in: .whitespaces).isEmpty
        Form {
            Section {
                SettingsPaneHeader(title: SettingsSection.archive.title) {
                    SettingsIconTile(symbol: SettingsSection.archive.symbolName, color: SettingsSection.archive.tint, size: 44)
                } subtitle: {
                    if let shortcut = model.archiveShortcut {
                        Text("Threads you archive, with \(shortcut) or a thread's archive button, wait here. Unarchive one to bring it back to the sidebar.")
                    } else {
                        Text("Threads you archive with a thread's archive button wait here. Unarchive one to bring it back to the sidebar.")
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter", text: $model.filter, prompt: Text("Filter archived threads"))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                    Spacer()
                    Button(isFiltering ? "Delete Shown…" : "Delete All…", role: .destructive) { model.deleteAll() }
                        .disabled(model.groups.isEmpty)
                }
            }
            if model.groups.isEmpty {
                Section {
                    Group {
                        if isFiltering {
                            ContentUnavailableView.search(text: model.filter)
                        } else {
                            ContentUnavailableView("No Archived Threads", systemImage: "archivebox")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            ForEach(model.groups) { group in
                Section {
                    ForEach(group.threads) { thread in
                        ArchivedThreadRow(thread: thread, model: model)
                    }
                } header: {
                    Text(group.project.name)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ArchivedThreadRow: View {
    let thread: ThreadSummary
    let model: ArchiveSettingsModel

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: thread.title).lineLimit(1).truncationMode(.tail)
                Text("Last active \(thread.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Unarchive") { model.unarchive(thread.id) }
            Button("Delete", role: .destructive) { model.delete(thread.id) }
        }
    }
}
