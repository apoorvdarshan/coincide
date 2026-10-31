import CoincideRemoteKit
import SwiftUI

/// The thread menu, as the Mac's sidebar context menu offers it.
struct ThreadActionsMenu: View {
    let thread: RemoteThreadSummary
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator

    var body: some View {
        Button { act(.pin(!thread.isPinned)) } label: {
            Label(thread.isPinned ? "Unpin" : "Pin", systemImage: thread.isPinned ? "pin.slash" : "pin")
        }
        Button { navigator.renaming = thread } label: { Label("Rename…", systemImage: "pencil") }
        Button { act(.markUnread) } label: { Label("Mark as Unread", systemImage: "circlebadge") }
        Menu {
            if let until = thread.snoozedUntil, until > Date() {
                Button("Wake Now") { act(.snooze(nil)) }
                Divider()
            }
            ForEach(SnoozePreset.presets()) { preset in
                Button("\(preset.title) (\(preset.detail))") { act(.snooze(preset.date)) }
            }
        } label: {
            Label("Snooze", systemImage: "moon.zzz")
        }
        Button { act(.settle(!thread.isSettled)) } label: {
            Label(thread.isSettled ? "Unsettle" : "Settle", systemImage: "tray.and.arrow.down")
        }
        Button { act(.archive(!thread.isArchived)) } label: {
            Label(thread.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox")
        }
        .disabled(thread.isRunning && !thread.isArchived)
        let projects = client.workspace.projects.filter { $0.id != thread.projectID }
        if !projects.isEmpty, !thread.hasWorktree {
            Menu {
                ForEach(projects) { project in
                    Button(project.name) { act(.move(projectID: project.id)) }
                }
            } label: {
                Label("Move to", systemImage: "folder")
            }
            .disabled(thread.isRunning)
        }
        if let scripts = client.project(thread.projectID)?.scripts, !scripts.isEmpty {
            Menu {
                ForEach(scripts) { script in
                    Button {
                        Task { await client.perform(.runScript(threadID: thread.id, scriptID: script.id)) }
                    } label: {
                        Label(script.name, systemImage: ScriptIcon.symbol(script.icon))
                    }
                }
            } label: {
                Label("Run Script", systemImage: "play")
            }
        }
        Button { navigator.diff = .init(threadID: thread.id, turnID: nil) } label: {
            Label("Uncommitted Changes", systemImage: "plus.forwardslash.minus")
        }
        // As the Mac's menu: the id the `coincide` command line takes.
        Button { UIPasteboard.general.string = thread.id.uuidString } label: {
            Label("Copy Thread ID", systemImage: "doc.on.doc")
        }
        Divider()
        Button(role: .destructive) { navigator.deleting = thread } label: {
            Label("Delete…", systemImage: "trash")
        }
    }

    private func act(_ action: RemoteThreadAction) {
        Task { await client.act(action, on: thread.id) }
    }
}

enum ScriptIcon {
    static func symbol(_ icon: String) -> String {
        switch icon {
        case "test": "checkmark.seal"
        case "lint": "wand.and.stars"
        case "configure": "gearshape"
        case "build": "hammer"
        case "debug": "ant"
        default: "play"
        }
    }
}

/// T3 Code's snooze choices, as the Mac offers them.
struct SnoozePreset: Identifiable {
    var title: String
    var detail: String
    var date: Date
    var id: String { title }

    static func presets(now: Date = Date(), calendar: Calendar = .current) -> [SnoozePreset] {
        let hour: TimeInterval = 3_600
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        func at(_ hourOfDay: Int, daysAhead: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: daysAhead, to: now) ?? now
            return calendar.date(bySettingHour: hourOfDay, minute: 0, second: 0, of: day) ?? day
        }
        var presets = [
            SnoozePreset(title: String(localized: "In 1 Hour"), detail: now.addingTimeInterval(hour).formatted(time), date: now.addingTimeInterval(hour)),
            SnoozePreset(title: String(localized: "In 3 Hours"), detail: now.addingTimeInterval(3 * hour).formatted(time), date: now.addingTimeInterval(3 * hour)),
        ]
        let evening = at(18, daysAhead: 0)
        if evening.timeIntervalSince(now) > hour {
            presets.append(SnoozePreset(title: String(localized: "This Evening"), detail: evening.formatted(time), date: evening))
        }
        let tomorrow = at(9, daysAhead: 1)
        presets.append(SnoozePreset(title: String(localized: "Tomorrow"), detail: tomorrow.formatted(time), date: tomorrow))
        let weekday = calendar.component(.weekday, from: now)
        let ahead = (2 - weekday + 7) % 7
        let monday = at(9, daysAhead: ahead == 0 ? 7 : ahead)
        if monday != tomorrow {
            presets.append(
                SnoozePreset(
                    title: String(localized: "Next Week"),
                    detail: monday.formatted(.dateTime.weekday(.abbreviated)) + " " + monday.formatted(time), date: monday))
        }
        return presets
    }
}

/// Renaming and deleting, which ask first.
struct ThreadActionDialogs: ViewModifier {
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @State private var title = ""

    func body(content: Content) -> some View {
        @Bindable var navigator = navigator
        content
            .alert(
                "Rename Thread", isPresented: Binding(get: { navigator.renaming != nil }, set: { if !$0 { navigator.renaming = nil } })
            ) {
                TextField("Title", text: $title)
                Button("Rename") {
                    if let thread = navigator.renaming { Task { await client.act(.rename(title), on: thread.id) } }
                    navigator.renaming = nil
                }
                Button("Cancel", role: .cancel) { navigator.renaming = nil }
            }
            .onChange(of: navigator.renaming) { _, thread in title = thread?.title ?? "" }
            .confirmationDialog(
                "Delete “\(navigator.deleting?.title ?? "")”?",
                isPresented: Binding(get: { navigator.deleting != nil }, set: { if !$0 { navigator.deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Thread", role: .destructive) {
                    if let thread = navigator.deleting {
                        if navigator.selection == thread.id { navigator.selection = nil }
                        Task { await client.act(.delete, on: thread.id) }
                    }
                    navigator.deleting = nil
                }
            } message: {
                Text(
                    navigator.deleting?.isRunning == true
                        ? "The agent working in it stops. You can undo the deletion on the Mac until Coincide quits."
                        : "You can undo the deletion on the Mac until Coincide quits. Files in the project aren’t changed.")
            }
    }
}
