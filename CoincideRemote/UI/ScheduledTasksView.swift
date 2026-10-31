import CoincideRemoteKit
import SwiftUI

/// The Mac's scheduled tasks, as its Scheduled Tasks window lists them: each task's project, state and schedule, its
/// next run, and what its last run said. Tap one to edit it; its menu runs it now, pauses or resumes it, opens its last
/// run or deletes it. Every run starts on the Mac, in a new thread of the task's project.
struct ScheduledTasksView: View {
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme
    @State private var tasks: RemoteScheduledTasks?
    @State private var problem: String?
    @State private var editing: ScheduledTaskEditor.Target?
    @State private var deleting: RemoteScheduledTask?

    var body: some View {
        List {
            if let error = tasks?.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .sidebarRow()
            }
            ForEach(tasks?.tasks ?? []) { task in
                Button { editing = .edit(task) } label: { ScheduledTaskRow(task: task) }
                    .buttonStyle(SidebarRowButtonStyle())
                    .contextMenu { menu(task) }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { deleting = task } label: { Label("Delete", systemImage: "trash") }
                        Button { act(task.isPaused ? .resume : .pause, task) } label: {
                            Label(task.isPaused ? "Resume" : "Pause", systemImage: task.isPaused ? "play" : "pause")
                        }
                        .tint(.gray)
                    }
                    .swipeActions(edge: .leading) {
                        Button { act(.runNow, task) } label: { Label("Run Now", systemImage: "play.fill") }
                            .tint(.indigo)
                            .disabled(!task.canRunNow)
                    }
                    .sidebarRow()
            }
        }
        .sidebarList(theme)
        .overlay { placeholder }
        .refreshable { await load() }
        .navigationTitle("Scheduled Tasks")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = .new } label: { Label("New Task", systemImage: "plus") }
                    .disabled(tasks == nil || !client.isConnected || folderProjects.isEmpty)
            }
        }
        .task(id: client.isConnected) { await load() }
        .sheet(item: $editing) { target in
            ScheduledTaskEditor(target: target, projects: folderProjects) { saved in tasks = saved }
        }
        .confirmationDialog(
            "Delete scheduled task “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible
        ) {
            if let task = deleting {
                Button("Delete", role: .destructive) { act(.delete, task) }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Existing threads are kept. A running thread continues until you stop it.")
        }
    }

    private var folderProjects: [RemoteProject] { client.workspace.projects.filter { !$0.isChats } }

    @ViewBuilder private var placeholder: some View {
        if let problem {
            ContentUnavailableView("Can’t Show Scheduled Tasks", systemImage: "calendar.badge.exclamationmark", description: Text(problem))
                .foregroundStyle(theme.secondaryInk)
        } else if let tasks, tasks.tasks.isEmpty, tasks.error == nil {
            ContentUnavailableView {
                Label("No Scheduled Tasks", systemImage: "calendar.badge.clock")
            } description: {
                Text("No scheduled tasks yet. Create one to start a new thread at a chosen time.")
            } actions: {
                Button("New Task") { editing = .new }
                    .prominentButton()
                    .disabled(folderProjects.isEmpty)
            }
            .foregroundStyle(theme.secondaryInk)
        } else if tasks == nil, client.isConnected {
            ProgressView()
        }
    }

    @ViewBuilder
    private func menu(_ task: RemoteScheduledTask) -> some View {
        Button { act(.runNow, task) } label: { Label("Run Now", systemImage: "play.fill") }
            .disabled(!task.canRunNow)
        Button { act(task.isPaused ? .resume : .pause, task) } label: {
            Label(task.isPaused ? "Resume" : "Pause", systemImage: task.isPaused ? "play" : "pause")
        }
        Button { editing = .edit(task) } label: { Label("Edit…", systemImage: "pencil") }
        if let thread = task.lastThreadID {
            Button { navigator.selection = thread } label: { Label("Open Last Run", systemImage: "bubble.left.and.text.bubble.right") }
        }
        Divider()
        Button(role: .destructive) { deleting = task } label: { Label("Delete…", systemImage: "trash") }
    }

    private func load() async {
        guard client.isConnected else { return }
        do {
            tasks = try await client.scheduledTasks()
            problem = nil
        } catch let error as RemoteError where error.code == .unsupported {
            problem = String(localized: "Update Coincide on your Mac to see its scheduled tasks here.")
        } catch {
            problem = (error as? RemoteError)?.message ?? error.localizedDescription
        }
    }

    private func act(_ action: RemoteScheduledTaskCommand.Action, _ task: RemoteScheduledTask) {
        deleting = nil
        Task { if let updated = await client.scheduledTask(task.id, action) { tasks = updated } }
    }
}

/// A task as the Mac's window lists it: its name; its project, state and schedule; and its next run.
struct ScheduledTaskRow: View {
    let task: RemoteScheduledTask
    @Environment(RemoteClient.self) private var client
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(color)
                .frame(width: 20)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.name).font(.callout.weight(.semibold)).foregroundStyle(theme.ink).lineLimit(1)
                Text(details).font(.footnote).foregroundStyle(theme.secondaryInk).lineLimit(1)
                Text(nextRun).font(.footnote).foregroundStyle(theme.tertiaryInk).lineLimit(1)
                if let message = task.lastMessage, task.state == .failed || task.state == .interrupted {
                    Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        let project = client.project(task.projectID)?.name ?? String(localized: "Project unavailable")
        return [project, task.stateText, task.scheduleText].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var nextRun: String {
        guard let next = task.nextRunAt else { return String(localized: "No future runs") }
        return String(localized: "Next: \(ScheduledTaskEditor.format(next, timeZone: task.recurrence.timeZoneID))")
    }

    private var symbol: String {
        switch task.state {
        case .running: "play.circle.fill"
        case .paused: "pause.circle"
        case .failed, .interrupted, .missed: "exclamationmark.circle"
        case .completed: "checkmark.circle"
        case .scheduled, .unknown: "clock"
        }
    }

    private var color: Color {
        switch task.state {
        case .running: .green
        case .failed, .interrupted, .missed: .orange
        default: theme.secondaryInk
        }
    }
}

/// Creates or edits a scheduled task, as the Mac's editor: name, project, prompt, schedule (once, daily or weekly at a
/// time, in a time zone) and paused. A schedule a newer Mac set that the phone doesn't know is kept as it is.
struct ScheduledTaskEditor: View {
    enum Target: Identifiable {
        case new
        case edit(RemoteScheduledTask)

        var id: String {
            switch self {
            case .new: "new"
            case .edit(let task): task.id.uuidString
            }
        }
    }

    let target: Target
    let projects: [RemoteProject]
    let onSave: (RemoteScheduledTasks) -> Void
    @Environment(RemoteClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var name = ""
    @State private var projectID: UUID?
    @State private var prompt = ""
    @State private var recurrence = RemoteTaskRecurrence()
    @State private var time = Date()
    @State private var isPaused = false
    @State private var saving = false
    @State private var loaded = false

    private var existing: RemoteScheduledTask? {
        if case .edit(let task) = target { return task }
        return nil
    }

    /// The schedule is one the phone can't edit (a newer Mac's kind): it's kept as the Mac has it.
    private var keepsSchedule: Bool { existing?.recurrence.kind == .unknown }

    var body: some View {
        NavigationStack {
            Form {
                Group { fields }.themedCards(theme)
            }
            .scrollContentBackground(.hidden)
            .background(theme.isDark ? theme.content : theme.sidebar)
            .navigationTitle(existing == nil ? "New Scheduled Task" : "Edit Scheduled Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Create" : "Save") { Task { await save() } }
                        .disabled(!canSave || saving || !client.isConnected)
                }
            }
            .onAppear(perform: load)
        }
    }

    @ViewBuilder private var fields: some View {
        Section {
            TextField("Name", text: $name)
            Picker("Project", selection: $projectID) {
                ForEach(projects) { project in Text(project.name).tag(Optional(project.id)) }
            }
        }
        Section {
            TextField("What the agent should do", text: $prompt, axis: .vertical)
                .lineLimit(4...12)
        } header: {
            Text("Task")
        } footer: {
            Text("Each run starts a new thread in the project, with its defaults.")
        }
        Section("Schedule") {
            if keepsSchedule, let existing {
                LabeledContent("Schedule", value: existing.scheduleText)
                Text("Change this schedule on your Mac.").font(.footnote).foregroundStyle(theme.secondaryInk)
            } else {
                Picker("Repeat", selection: $recurrence.kind) {
                    ForEach(RemoteTaskRecurrence.Kind.editable, id: \.self) { kind in Text(Self.title(of: kind)).tag(kind) }
                }
                .pickerStyle(.segmented)
                switch recurrence.kind {
                case .once:
                    DatePicker("Date", selection: $recurrence.date, displayedComponents: .date)
                case .weekly:
                    Picker("Day", selection: $recurrence.weekday) {
                        ForEach(1...7, id: \.self) { day in Text(Calendar.current.weekdaySymbols[day - 1]).tag(day) }
                    }
                default:
                    EmptyView()
                }
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                Picker("Time Zone", selection: $recurrence.timeZoneID) {
                    ForEach(Self.timeZones(including: recurrence.timeZoneID), id: \.self) { zone in Text(zone).tag(zone) }
                }
            }
        }
        Section {
            Toggle("Paused", isOn: $isPaused).toggleStyle(ThemedSwitchStyle())
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && projectID != nil
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let task = existing {
            name = task.name
            projectID = task.projectID
            prompt = task.prompt
            recurrence = task.recurrence
            isPaused = task.isPaused
        } else {
            projectID = projects.first?.id
            recurrence = RemoteTaskRecurrence(kind: .daily, date: Date().addingTimeInterval(3600))
        }
        time = Calendar.current.date(bySettingHour: recurrence.hour, minute: recurrence.minute, second: 0, of: Date()) ?? Date()
    }

    private func save() async {
        guard let projectID else { return }
        saving = true
        defer { saving = false }
        var schedule = recurrence
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        schedule.hour = parts.hour ?? schedule.hour
        schedule.minute = parts.minute ?? schedule.minute
        let draft = RemoteScheduledTaskDraft(
            id: existing?.id, name: name, projectID: projectID, prompt: prompt, recurrence: keepsSchedule ? nil : schedule,
            isPaused: isPaused)
        if let saved = await client.saveScheduledTask(draft) {
            onSave(saved)
            dismiss()
        }
    }

    static func title(of kind: RemoteTaskRecurrence.Kind) -> String {
        switch kind {
        case .once: String(localized: "Once")
        case .daily: String(localized: "Daily")
        case .weekly: String(localized: "Weekly")
        case .unknown: String(localized: "Other")
        }
    }

    /// The phone's zone first, then the task's own when it differs, then every other.
    static func timeZones(including current: String) -> [String] {
        var zones = [TimeZone.current.identifier]
        if current != zones[0] { zones.append(current) }
        return zones + TimeZone.knownTimeZoneIdentifiers.filter { !zones.contains($0) }
    }

    /// A run's date and time in the task's zone, with the zone named, as the Mac shows it.
    static func format(_ date: Date, timeZone: String) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        if let zone = TimeZone(identifier: timeZone) { style.timeZone = zone }
        return "\(date.formatted(style)) (\(timeZone))"
    }
}
