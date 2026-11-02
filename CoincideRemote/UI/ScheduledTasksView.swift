import CoincideRemoteKit
import SwiftUI

/// The Mac's scheduled tasks, grouped as its Scheduled panel groups them: by the bot (with its character), thread or
/// project their runs go to. Each shows its state and schedule, its next run, and what its last run said. Tap one to
/// edit it; its menu runs it now, pauses or resumes it, opens its thread or last run, or deletes it. With `threadID`, only
/// that thread's schedules, from the clock in its header; a new one sends into that thread.
struct ScheduledTasksView: View {
    var threadID: UUID? = nil
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
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
            ForEach(groups, id: \.owner) { group in
                Section {
                    ForEach(group.tasks) { task in row(task) }
                } header: {
                    if threadID == nil { ScheduleGroupHeader(owner: group.owner) }
                }
            }
        }
        .sidebarList(theme)
        .overlay { placeholder }
        .refreshable { await load() }
        .navigationTitle(threadID == nil ? "Scheduled Tasks" : "Scheduled in This Thread")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if threadID != nil {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { if ProGate.allows() { editing = .new } } label: { Label("New Task", systemImage: "plus") }
                    .disabled(tasks == nil || !client.isConnected || (threadID == nil && folderProjects.isEmpty))
            }
        }
        .task(id: client.isConnected) { await load() }
        .sheet(item: $editing) { target in
            ScheduledTaskEditor(target: target, projects: folderProjects, threadID: threadID) { saved in tasks = saved }
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

    /// The schedules shown, grouped by where their runs go, the soonest group first.
    private var groups: [(owner: RemoteScheduleOwner, tasks: [RemoteScheduledTask])] {
        RemoteScheduleOwner.groups((tasks?.tasks ?? []).filter { threadID == nil || $0.threadID == threadID })
    }

    @ViewBuilder
    private func row(_ task: RemoteScheduledTask) -> some View {
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

    private var folderProjects: [RemoteProject] { client.workspace.projects.filter { !$0.isChats } }

    @ViewBuilder private var placeholder: some View {
        if let problem {
            ContentUnavailableView("Can’t Show Scheduled Tasks", systemImage: "calendar.badge.exclamationmark", description: Text(problem))
                .foregroundStyle(theme.secondaryInk)
        } else if let tasks, threadID != nil, groups.isEmpty, tasks.error == nil {
            ContentUnavailableView {
                Label("Nothing Scheduled Here", systemImage: "clock")
            } description: {
                Text("Add a schedule, or ask the agent to do something later or on a schedule.")
            } actions: {
                Button("New Task") { if ProGate.allows() { editing = .new } }.prominentButton()
            }
            .foregroundStyle(theme.secondaryInk)
        } else if let tasks, tasks.tasks.isEmpty, tasks.error == nil {
            ContentUnavailableView {
                Label("No Scheduled Tasks", systemImage: "calendar.badge.clock")
            } description: {
                Text("No scheduled tasks yet. Create one to start a new thread at a chosen time.")
            } actions: {
                Button("New Task") { if ProGate.allows() { editing = .new } }
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
        if let thread = task.threadID, client.summary(thread) != nil, threadID == nil {
            Button { navigator.selection = thread } label: { Label("Open Thread", systemImage: "bubble.left.and.text.bubble.right") }
        } else if task.threadID == nil, let thread = task.lastThreadID {
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

/// A group's heading in the list, as the Mac's Scheduled panel heads it: a bot's character and name, a thread's agent
/// logo and title over its project, or a project's folder. Tapping a bot's or thread's opens that conversation.
struct ScheduleGroupHeader: View {
    let owner: RemoteScheduleOwner
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                leading.frame(width: 22, height: 22)
                Text(title).font(.footnote.weight(.semibold)).foregroundStyle(theme.ink).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(theme.tertiaryInk).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(thread == nil)
        .textCase(nil)
        .accessibilityLabel([title, subtitle].compactMap(\.self).joined(separator: ", "))
    }

    private var bot: RemoteBot? {
        guard case .bot(let id) = owner else { return nil }
        return client.workspace.bots?.first { $0.id == id }
    }

    /// The conversation the heading opens: the thread's, or the bot's latest.
    private var thread: UUID? {
        switch owner {
        case .thread(let id): client.summary(id) == nil ? nil : id
        case .bot: bot?.threadIDs.first
        case .project: nil
        }
    }

    @ViewBuilder private var leading: some View {
        switch owner {
        case .bot:
            BotAvatarImage(avatar: bot?.avatar, size: 22, name: bot?.name)
        case .thread(let id):
            if let provider = client.summary(id)?.selection.provider {
                AgentLogo(provider: provider, size: 15)
            } else {
                Image(systemName: "bubble.left").font(.caption).foregroundStyle(theme.secondaryInk)
            }
        case .project:
            Image(systemName: "folder").font(.caption.weight(.medium)).foregroundStyle(theme.secondaryInk)
        }
    }

    private var title: String {
        switch owner {
        case .bot: bot?.name ?? String(localized: "Bot")
        case .thread(let id): client.summary(id)?.title ?? String(localized: "Deleted thread")
        case .project(let id): client.project(id)?.name ?? String(localized: "Project unavailable")
        }
    }

    private var subtitle: String? {
        switch owner {
        case .bot: String(localized: "Bot")
        case .thread(let id):
            client.summary(id).flatMap { client.project($0.projectID) }.map { $0.isChats ? String(localized: "Chat") : $0.name }
        case .project: String(localized: "A new thread each run")
        }
    }

    private func open() {
        if let thread { navigator.selection = thread }
    }
}

/// A task as the Mac's window lists it: its name; its state and schedule; and its next run.
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
                HStack(spacing: 5) {
                    Text(task.name).font(.callout.weight(.semibold)).foregroundStyle(theme.ink).lineLimit(1)
                    if task.createdByAgent == true {
                        Image(systemName: "sparkles").font(.caption2).foregroundStyle(theme.tertiaryInk)
                            .accessibilityLabel("Created by the agent")
                    }
                    Spacer(minLength: 4)
                    if task.needsApproval == true {
                        StatusBadge(text: String(localized: "Needs approval"), color: .orange)
                    }
                }
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
        // A thread schedule's group names its thread; a project task's names its project.
        // A task waiting for approval says so in its badge.
        [task.needsApproval == true ? "" : task.stateText, task.scheduleText].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var nextRun: String {
        guard let next = task.nextRunAt else { return String(localized: "No future runs") }
        return String(localized: "Next: \(ScheduledTaskEditor.format(next, timeZone: task.recurrence.timeZoneID))")
    }

    private var symbol: String {
        if task.needsApproval == true { return "clock.badge.questionmark" }
        return switch task.state {
        case .running: "play.circle.fill"
        case .paused: "pause.circle"
        case .failed, .interrupted, .missed: "exclamationmark.circle"
        case .completed: "checkmark.circle"
        case .scheduled, .unknown: "clock"
        }
    }

    private var color: Color {
        if task.needsApproval == true { return .orange }
        return switch task.state {
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
    /// A new task's thread, from the thread's clock: it sends into that thread rather than starting new ones.
    var threadID: UUID? = nil
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

    /// The thread it sends into, if it's a thread schedule.
    private var thread: UUID? { existing?.threadID ?? (existing == nil ? threadID : nil) }

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
            if let thread {
                LabeledContent("Sends to", value: client.summary(thread)?.title ?? String(localized: "Thread unavailable"))
            } else {
                Picker("Project", selection: $projectID) {
                    ForEach(projects) { project in Text(project.name).tag(Optional(project.id)) }
                }
            }
        }
        Section {
            TextField("What the agent should do", text: $prompt, axis: .vertical)
                .lineLimit(4...12)
        } header: {
            Text("Task")
        } footer: {
            Text(
                thread == nil
                    ? String(localized: "Each run starts a new thread in the project, with its defaults.")
                    : String(localized: "Each run sends this into the thread as your next message, with its agent, model and access. A busy thread gets it when its turn ends."))
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
            && (projectID != nil || thread != nil)
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
            projectID = threadID.flatMap { client.summary($0)?.projectID } ?? projects.first?.id
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
            isPaused: isPaused, threadID: existing == nil ? threadID : nil)
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
