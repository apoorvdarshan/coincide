import AppKit
import CoincideKit

final class ScheduledTaskEditor: NSViewController, NSComboBoxDelegate, NSTextViewDelegate {
    var onSave: ((ScheduledTask) throws -> Void)?
    private var task: ScheduledTask
    private let projects: [Project]
    private let isNew: Bool
    private let name = ThemedTextField(placeholder: String(localized: "Task name"))
    private let prompt = NSTextView()
    private let zone = NSComboBox()
    private let date = NSDatePicker()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var projectButton = ThemedButton(title: "", style: .secondary, target: self, action: #selector(chooseProject))
    private lazy var repeatButton = ThemedButton(title: "", style: .secondary, target: self, action: #selector(chooseRepeat))
    private lazy var weekdayButton = ThemedButton(title: "", style: .secondary, target: self, action: #selector(chooseWeekday))
    private lazy var paused = ThemedCheckbox(label: String(localized: "Paused"), target: self, action: #selector(changed))
    private lazy var saveButton = ThemedButton(title: String(localized: "Save"), style: .primary, target: self, action: #selector(save))

    init(task: ScheduledTask?, projects: [Project], projectID: UUID? = nil) {
        self.projects = projects
        self.isNew = task == nil
        self.task = task ?? ScheduledTask(name: "", projectID: projectID ?? projects.first?.id ?? UUID(), prompt: "", recurrence: TaskRecurrence())
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let heading = NSTextField(labelWithString: isNew ? String(localized: "New Scheduled Task") : String(localized: "Edit Scheduled Task"))
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        name.stringValue = task.name; name.delegate = self
        name.setAccessibilityLabel(String(localized: "Task name"))
        prompt.string = task.prompt; prompt.delegate = self
        prompt.isRichText = false; prompt.font = .systemFont(ofSize: 13)
        prompt.backgroundColor = Theme.raisedFill; prompt.textColor = Theme.ink
        prompt.textContainerInset = NSSize(width: 8, height: 8)
        prompt.isVerticallyResizable = true; prompt.isHorizontallyResizable = false
        prompt.autoresizingMask = [.width]; prompt.textContainer?.widthTracksTextView = true
        prompt.setAccessibilityLabel(String(localized: "Task prompt"))
        let scroll = NSScrollView(); scroll.documentView = prompt; scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        scroll.borderType = .noBorder
        zone.addItems(withObjectValues: TimeZone.knownTimeZoneIdentifiers.sorted())
        zone.completes = true; zone.stringValue = task.recurrence.timeZoneID; zone.delegate = self
        zone.setAccessibilityLabel(String(localized: "Time Zone"))
        date.datePickerStyle = .textFieldAndStepper
        date.timeZone = TimeZone(identifier: task.recurrence.timeZoneID)
        date.target = self; date.action = #selector(changed)
        date.setAccessibilityLabel(String(localized: "Run at"))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = date.timeZone ?? .current
        date.dateValue = task.recurrence.kind == .once ? task.recurrence.date
            : calendar.date(bySettingHour: task.recurrence.hour, minute: task.recurrence.minute, second: 0, of: Date()) ?? Date()
        paused.state = task.isPaused ? .on : .off
        let timing = NSStackView(views: [repeatButton, weekdayButton, date])
        timing.spacing = 8
        let notice = NSTextField(wrappingLabelWithString: String(localized: "Runs only while Coincide is open. Missed runs are skipped after quitting or sleep. Each run starts a new thread using the project's defaults."))
        notice.font = .systemFont(ofSize: 11); notice.textColor = .secondaryLabelColor
        errorLabel.textColor = .systemRed; errorLabel.font = .systemFont(ofSize: 12)
        let cancel = ThemedButton(title: String(localized: "Cancel"), style: .secondary, target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = .command
        let buttons = NSStackView(views: [paused, NSView(), cancel, saveButton]); buttons.spacing = 8
        let stack = NSStackView(views: [heading, label(String(localized: "Name")), name,
            label(String(localized: "Project")), projectButton, label(String(localized: "Task prompt")), scroll,
            label(String(localized: "Schedule")), timing, label(String(localized: "Time Zone")), zone, notice, errorLabel, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for child in [name, projectButton, scroll, timing, zone, notice, errorLabel, buttons] {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        let root = SolidBackgroundView(color: Theme.contentBackground)
        root.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 580),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        updateControls()
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12, weight: .medium); field.textColor = .secondaryLabelColor
        return field
    }
    private func updateControls() {
        projectButton.title = projects.first(where: { $0.id == task.projectID })?.name ?? String(localized: "Choose a Project")
        repeatButton.title = task.recurrence.kind.title
        weekdayButton.title = Calendar.current.weekdaySymbols[task.recurrence.weekday - 1]
        weekdayButton.isHidden = task.recurrence.kind != .weekly
        date.datePickerElements = task.recurrence.kind == .once ? [.yearMonthDay, .hourMinute] : [.hourMinute]
        saveButton.isEnabled = !name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && TimeZone(identifier: zone.stringValue) != nil && projects.contains(where: { $0.id == task.projectID })
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSComboBox === zone, let timeZone = TimeZone(identifier: zone.stringValue) {
            var old = Calendar(identifier: .gregorian); old.timeZone = date.timeZone ?? .current
            let hour = old.component(.hour, from: date.dateValue), minute = old.component(.minute, from: date.dateValue)
            date.timeZone = timeZone
            if task.recurrence.kind != .once {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
                date.dateValue = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
            }
        }
        updateControls()
    }
    func comboBoxSelectionDidChange(_ notification: Notification) { controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: zone)) }
    func textDidChange(_ notification: Notification) { updateControls() }
    @objc private func changed() { updateControls() }

    private func menu(_ labels: [String], selected: Int, action: Selector, button: NSButton) {
        let menu = NSMenu()
        for (index, label) in labels.enumerated() {
            let item = NSMenuItem(title: label, action: action, keyEquivalent: "")
            item.target = self; item.tag = index; item.state = index == selected ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button)
    }
    @objc private func chooseProject() {
        menu(projects.map(\.name), selected: projects.firstIndex(where: { $0.id == task.projectID }) ?? -1,
            action: #selector(pickProject(_:)), button: projectButton)
    }
    @objc private func pickProject(_ item: NSMenuItem) {
        guard projects.indices.contains(item.tag) else { return }
        task.projectID = projects[item.tag].id; updateControls()
    }
    @objc private func chooseRepeat() {
        menu(TaskRecurrence.Kind.allCases.map(\.title), selected: TaskRecurrence.Kind.allCases.firstIndex(of: task.recurrence.kind) ?? 0,
            action: #selector(pickRepeat(_:)), button: repeatButton)
    }
    @objc private func pickRepeat(_ item: NSMenuItem) {
        guard TaskRecurrence.Kind.allCases.indices.contains(item.tag) else { return }
        task.recurrence.kind = TaskRecurrence.Kind.allCases[item.tag]; updateControls()
    }
    @objc private func chooseWeekday() {
        menu(Calendar.current.weekdaySymbols, selected: task.recurrence.weekday - 1,
            action: #selector(pickWeekday(_:)), button: weekdayButton)
    }
    @objc private func pickWeekday(_ item: NSMenuItem) { task.recurrence.weekday = item.tag + 1; updateControls() }

    @objc private func save() {
        guard let timeZone = TimeZone(identifier: zone.stringValue) else { return }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        task.name = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        task.prompt = prompt.string.trimmingCharacters(in: .whitespacesAndNewlines)
        task.isPaused = paused.state == .on
        task.recurrence.timeZoneID = zone.stringValue; task.recurrence.date = date.dateValue
        task.recurrence.hour = calendar.component(.hour, from: date.dateValue)
        task.recurrence.minute = calendar.component(.minute, from: date.dateValue)
        do { try onSave?(task); dismiss(nil) }
        catch { errorLabel.stringValue = error.localizedDescription }
    }
    @objc private func cancel() { dismiss(nil) }
}

extension TaskRecurrence.Kind {
    var title: String {
        switch self {
        case .once: String(localized: "Once")
        case .daily: String(localized: "Daily")
        case .weekly: String(localized: "Weekly")
        }
    }
}
