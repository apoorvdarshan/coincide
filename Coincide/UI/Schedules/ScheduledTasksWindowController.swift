import AppKit
import CoincideKit

final class ScheduledTasksWindowController: NSWindowController {
    static let shared = ScheduledTasksWindowController(window: nil)
    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: ScheduledTasksViewController())
            window.title = String(localized: "Scheduled Tasks")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.contentMinSize = NSSize(width: 760, height: 400)
            window.setContentSize(NSSize(width: 860, height: 520))
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.backgroundColor = Theme.contentBackground
            if !window.setFrameUsingName("CoincideScheduledTasks") { window.center() }
            window.setFrameAutosaveName("CoincideScheduledTasks")
            self.window = window
        }
        showWindow(nil)
    }
}

final class ScheduledTasksViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let service: ScheduledTasks
    private let appStore: AppStore
    private let table = NSTableView()
    private let details = NSTextField(wrappingLabelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: String(localized: "No scheduled tasks yet. Create one to start a new thread at a chosen time."))
    private var observation: NSObjectProtocol?
    private var tasks: [ScheduledTask] { service.schedules.tasks }
    private var selected: ScheduledTask? { tasks.indices.contains(table.selectedRow) ? tasks[table.selectedRow] : nil }
    private lazy var add = ThemedButton(title: String(localized: "New Task…"), style: .primary, target: self, action: #selector(newTask))
    private lazy var edit = ThemedButton(title: String(localized: "Edit…"), style: .secondary, target: self, action: #selector(editTask))
    private lazy var run = ThemedButton(title: String(localized: "Run Now"), style: .secondary, target: self, action: #selector(runTask))
    private lazy var pause = ThemedButton(title: String(localized: "Pause"), style: .secondary, target: self, action: #selector(pauseTask))
    private lazy var delete = ThemedButton(title: String(localized: "Delete"), style: .plain, target: self, action: #selector(deleteTask))
    private lazy var open = ThemedButton(title: String(localized: "Open Last Run"), style: .secondary, target: self, action: #selector(openRun))

    init(service: ScheduledTasks = .shared, store: AppStore = .shared) {
        self.service = service; appStore = store
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    isolated deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }

    override func loadView() {
        let root = SolidBackgroundView(color: Theme.contentBackground)
        let notice = NSTextField(wrappingLabelWithString: String(localized: "Runs only while Coincide is open. Missed runs after quitting or sleep are skipped. Running tasks never overlap their next occurrence."))
        notice.font = .systemFont(ofSize: 12); notice.textColor = .secondaryLabelColor
        let header = NSStackView(views: [notice, add]); header.spacing = 16
        notice.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        table.addTableColumn(NSTableColumn(identifier: .init("task")))
        table.headerView = nil; table.rowHeight = 78
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(editTask)
        table.style = .plain; table.backgroundColor = .clear
        table.setAccessibilityLabel(String(localized: "Scheduled Tasks"))
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        empty.textColor = .secondaryLabelColor; empty.alignment = .center
        let buttons = NSStackView(views: [edit, run, pause, delete, NSView(), open]); buttons.spacing = 8
        details.font = .systemFont(ofSize: 12); details.textColor = .secondaryLabelColor
        for child in [header, scroll, empty, details, buttons] {
            child.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: details.topAnchor, constant: -12),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 50),
            empty.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -50),
            details.leadingAnchor.constraint(equalTo: header.leadingAnchor), details.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            details.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.leadingAnchor.constraint(equalTo: header.leadingAnchor), buttons.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        view = root
        observation = NotificationCenter.default.addObserver(forName: ScheduledTasks.didChange, object: service, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }
    private func refresh() {
        let id = selected?.id
        table.reloadData()
        if let id, let row = tasks.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        empty.isHidden = !tasks.isEmpty
        add.isEnabled = !appStore.projects.isEmpty && service.schedules.loadError == nil
        selectionChanged()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tasks.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tasks.indices.contains(row) else { return nil }
        let task = tasks[row]
        let title = NSTextField(labelWithString: task.name)
        title.font = .systemFont(ofSize: 14, weight: .semibold); title.lineBreakMode = .byTruncatingTail
        let project = appStore.project(task.projectID)?.name ?? String(localized: "Project unavailable")
        let status = service.hasActiveWork(task) ? String(localized: "Running") : Self.state(task)
        let state = NSTextField(labelWithString: "\(project) · \(status) · \(task.recurrence.kind.title)")
        state.font = .systemFont(ofSize: 12); state.textColor = .secondaryLabelColor
        let next = NSTextField(labelWithString: task.nextRunAt.map { String(localized: "Next: \(Self.date($0, task: task))") } ?? String(localized: "No future runs"))
        next.font = .systemFont(ofSize: 12); next.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, state, next]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        return stack
    }
    func tableViewSelectionDidChange(_ notification: Notification) { selectionChanged() }
    private func selectionChanged() {
        let task = selected
        edit.isEnabled = task != nil
        run.isEnabled = task.map { $0.activeThreadID == nil && !service.hasActiveWork($0) } ?? false
        pause.isEnabled = task != nil
        delete.isEnabled = task != nil
        open.isEnabled = task?.lastThreadID.flatMap { appStore.summary($0) } != nil
        pause.title = task?.isPaused == true ? String(localized: "Resume") : String(localized: "Pause")
        var text: [String] = []
        if let error = service.schedules.loadError ?? service.lastError { text.append(error) }
        if let task {
            if let date = task.lastRunAt { text.append(String(localized: "Last run: \(Self.date(date, task: task))")) }
            if let message = task.lastMessage { text.append(message) }
        }
        details.stringValue = text.joined(separator: "\n")
    }
    static func state(_ task: ScheduledTask) -> String {
        if task.activeThreadID != nil { return String(localized: "Running") }
        if task.isPaused { return task.lastOutcome == .failed ? String(localized: "Failed · Paused") : String(localized: "Paused") }
        switch task.lastOutcome {
        case .failed: return String(localized: "Failed")
        case .interrupted: return String(localized: "Interrupted")
        case .missed: return String(localized: "Missed")
        case .completed where task.nextRunAt == nil: return String(localized: "Completed")
        default: return String(localized: "Scheduled")
        }
    }
    static func date(_ value: Date, task: ScheduledTask) -> String {
        let format = DateFormatter(); format.dateStyle = .medium; format.timeStyle = .short
        format.timeZone = TimeZone(identifier: task.recurrence.timeZoneID)
        return format.string(from: value) + " (" + task.recurrence.timeZoneID + ")"
    }
    @objc private func newTask() { showEditor(nil) }
    @objc private func editTask() { if let selected { showEditor(selected) } }
    private func showEditor(_ task: ScheduledTask?) {
        let editor = ScheduledTaskEditor(task: task, projects: appStore.projects)
        editor.onSave = { [weak self] task in try self?.service.scheduler.save(task) }
        presentAsSheet(editor)
    }
    @objc private func runTask() {
        guard let task = selected else { return }
        do { try service.scheduler.runNow(task.id) } catch { details.stringValue = error.localizedDescription }
    }
    @objc private func pauseTask() {
        guard let task = selected else { return }
        do { try service.scheduler.setPaused(task.id, !task.isPaused) } catch { details.stringValue = error.localizedDescription }
    }
    @objc private func deleteTask() {
        guard let task = selected, let window = view.window else { return }
        let alert = ThemedAlert()
        alert.messageText = String(localized: "Delete scheduled task “\(task.name)”?" )
        alert.informativeText = String(localized: "Existing threads are kept. A running thread continues until you stop it.")
        alert.addButton(withTitle: String(localized: "Delete")); alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do { try self?.service.schedules.delete(task.id) } catch { self?.details.stringValue = error.localizedDescription }
        }
    }
    @objc private func openRun() { if let id = selected?.lastThreadID { AppEvents.openThread(id) } }
}
