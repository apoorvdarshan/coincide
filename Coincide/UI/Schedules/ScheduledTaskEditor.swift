import AppKit
import CoincideKit

/// Creates or edits a schedule: a thread schedule, which sends its prompt into its thread, or a project task, which
/// starts a new thread for each run. The preview under the schedule lists its next runs as it changes, or says why it
/// can't run. Saving what an agent asked for allows it too.
final class ScheduledTaskEditor: NSViewController, NSComboBoxDelegate, NSTextViewDelegate {
    var onSave: ((ScheduledTask) throws -> Void)?
    private var task: ScheduledTask
    private let projects: [Project]
    private let isNew: Bool
    private let isProposal: Bool
    private let store: AppStore
    private let name = ThemedTextField(placeholder: String(localized: "Task name"))
    private let prompt = NSTextView()
    private let zone = NSComboBox()
    private let date = NSDatePicker()
    private let intervalField = ThemedTextField(placeholder: "30")
    private let cronField = ThemedTextField(placeholder: "0 9 * * 1-5", monospaced: true)
    private let preview = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let targetLabel = NSTextField(labelWithString: "")
    private let days = NSStackView()
    private var dayButtons: [ThemedButton] = []
    private var intervalUnit = 1
    private lazy var projectButton = ThemedButton(title: "", style: .secondary, target: self, action: #selector(chooseProject))
    private lazy var repeatButton = ThemedButton(title: "", style: .secondary, target: self, action: #selector(chooseRepeat))
    private lazy var weekdayButton = ThemedButton(title: "", style: .secondary, target: self, action: #selector(chooseWeekday))
    private lazy var unitButton = ThemedButton(title: "", style: .secondary, target: self, action: #selector(chooseUnit))
    private lazy var paused = ThemedCheckbox(label: String(localized: "Paused"), target: self, action: #selector(changed))
    private lazy var saveButton = ThemedButton(title: String(localized: "Save"), style: .primary, target: self, action: #selector(save))

    /// The kinds in the Repeat menu's order.
    static let kinds: [TaskRecurrence.Kind] = [.once, .daily, .weekdays, .weekly, .days, .interval, .cron]
    /// Minutes in each interval unit: minutes, hours, days.
    private static let units = [1, 60, 1440]

    init(task: ScheduledTask, isNew: Bool, store: AppStore = .shared) {
        self.store = store
        projects = store.projects.filter { $0.id != AppStore.botsProjectID }
        self.isNew = isNew
        isProposal = task.proposal != nil || task.isAwaitingApproval
        self.task = task
        super.init(nibName: nil, bundle: nil)
        if let minutes = task.recurrence.intervalMinutes {
            intervalUnit = Self.units.lastIndex { minutes % $0 == 0 } ?? 0
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var headingText: String {
        if isProposal { return String(localized: "Review Scheduled Task") }
        return isNew ? String(localized: "New Scheduled Task") : String(localized: "Edit Scheduled Task")
    }

    override func loadView() {
        let heading = NSTextField(labelWithString: headingText)
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        name.stringValue = task.name; name.delegate = self
        name.setAccessibilityLabel(String(localized: "Task name"))
        prompt.string = task.prompt; prompt.delegate = self
        prompt.isRichText = false; prompt.font = .systemFont(ofSize: 13)
        prompt.backgroundColor = Theme.raisedFill; prompt.textColor = Theme.ink
        prompt.insertionPointColor = Theme.ink
        prompt.textContainerInset = NSSize(width: 8, height: 8)
        prompt.isVerticallyResizable = true; prompt.isHorizontallyResizable = false
        prompt.autoresizingMask = [.width]; prompt.textContainer?.widthTracksTextView = true
        prompt.setAccessibilityLabel(String(localized: "Task prompt"))
        let scroll = NSScrollView(); scroll.documentView = prompt; scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 7
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = Theme.surfaceBorder.cgColor
        zone.addItems(withObjectValues: TimeZone.knownTimeZoneIdentifiers.sorted())
        zone.completes = true; zone.stringValue = task.recurrence.timeZoneID; zone.delegate = self
        zone.setAccessibilityLabel(String(localized: "Time Zone"))
        date.datePickerStyle = .textFieldAndStepper
        date.timeZone = TimeZone(identifier: task.recurrence.timeZoneID)
        date.target = self; date.action = #selector(changed)
        date.setAccessibilityLabel(String(localized: "Run at"))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = date.timeZone ?? .current
        date.dateValue = [.once, .interval].contains(task.recurrence.kind) ? task.recurrence.date
            : calendar.date(bySettingHour: task.recurrence.hour, minute: task.recurrence.minute, second: 0, of: Date()) ?? Date()
        intervalField.stringValue = task.recurrence.intervalMinutes.map { String($0 / Self.units[intervalUnit]) } ?? "30"
        intervalField.delegate = self
        intervalField.setAccessibilityLabel(String(localized: "Repeat every"))
        intervalField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        cronField.stringValue = task.recurrence.cron ?? "0 9 * * 1-5"
        cronField.delegate = self
        cronField.setAccessibilityLabel(String(localized: "Cron expression"))
        paused.state = task.isPaused ? .on : .off
        buildDays()
        let timing = NSStackView(views: [repeatButton, weekdayButton, intervalField, unitButton, date])
        timing.spacing = 8
        preview.font = .systemFont(ofSize: 12); preview.textColor = .secondaryLabelColor
        preview.setAccessibilityLabel(String(localized: "Next runs"))
        targetLabel.font = .systemFont(ofSize: 13)
        targetLabel.textColor = Theme.ink
        targetLabel.lineBreakMode = .byTruncatingTail
        let notice = NSTextField(wrappingLabelWithString: noticeText)
        notice.font = .systemFont(ofSize: 11); notice.textColor = .secondaryLabelColor
        errorLabel.textColor = .systemRed; errorLabel.font = .systemFont(ofSize: 12)
        let cancel = ThemedButton(title: String(localized: "Cancel"), style: .secondary, target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        if isProposal { saveButton.title = String(localized: "Save and Allow") }
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = .command
        let buttons = NSStackView(views: [paused, NSView(), cancel, saveButton]); buttons.spacing = 8
        var rows: [NSView] = [heading, label(String(localized: "Name")), name]
        if task.threadID != nil {
            rows += [label(String(localized: "Sends to")), targetLabel]
        } else {
            rows += [label(String(localized: "Project")), projectButton]
        }
        rows += [label(String(localized: "Task prompt")), scroll, label(String(localized: "Schedule")), timing, days, cronField,
            preview, label(String(localized: "Time Zone")), zone, notice, errorLabel, buttons]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        // A thread schedule shows where it sends, a project task its project: only the row it has.
        for child in [name, targetLabel, projectButton, scroll, timing, cronField, preview, zone, notice, errorLabel, buttons]
        where rows.contains(child) {
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

    private var noticeText: String {
        task.threadID != nil
            ? String(localized: "Each run sends the prompt into this thread as your next message, with the thread’s agent, model and access at that time. A busy thread gets it when its turn ends. Runs only while Coincide is open; missed runs are skipped.")
            : String(localized: "Runs only while Coincide is open. Missed runs are skipped after quitting or sleep. Each run starts a new thread using the project's defaults.")
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12, weight: .medium); field.textColor = .secondaryLabelColor
        return field
    }

    private func buildDays() {
        var calendar = Calendar.current
        calendar.locale = .current
        let first = calendar.firstWeekday
        days.spacing = 4
        for offset in 0..<7 {
            let weekday = (first - 1 + offset) % 7 + 1
            let button = ThemedButton(
                title: calendar.veryShortWeekdaySymbols[weekday - 1], style: .secondary, target: self, action: #selector(toggleDay(_:)))
            button.tag = weekday
            button.setAccessibilityLabel(calendar.weekdaySymbols[weekday - 1])
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            dayButtons.append(button)
            days.addArrangedSubview(button)
        }
        days.setAccessibilityElement(true)
        days.setAccessibilityRole(.group)
        days.setAccessibilityLabel(String(localized: "Days"))
    }

    /// The schedule as the controls have it now.
    private var current: TaskRecurrence {
        var recurrence = task.recurrence
        let timeZone = TimeZone(identifier: zone.stringValue) ?? .current
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        recurrence.timeZoneID = zone.stringValue
        recurrence.date = date.dateValue
        recurrence.hour = calendar.component(.hour, from: date.dateValue)
        recurrence.minute = calendar.component(.minute, from: date.dateValue)
        recurrence.weekdays = recurrence.kind == .days ? dayButtons.filter { $0.style == .primary }.map(\.tag).sorted() : nil
        recurrence.intervalMinutes =
            recurrence.kind == .interval ? Int(intervalField.stringValue.trimmingCharacters(in: .whitespaces)).map { $0 * Self.units[intervalUnit] } : nil
        recurrence.cron = recurrence.kind == .cron ? cronField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        return recurrence
    }

    private func updateControls() {
        let kind = task.recurrence.kind
        if let threadID = task.threadID {
            let thread = store.summary(threadID)
            let bot = thread?.botID.flatMap { store.bot($0) }
            let place = bot?.displayName ?? store.project(thread?.projectID ?? UUID())?.name
            targetLabel.stringValue = [thread?.title ?? String(localized: "Thread unavailable"), place].compactMap(\.self).joined(separator: " · ")
        }
        projectButton.title = projects.first(where: { $0.id == task.projectID })?.name ?? String(localized: "Choose a Project")
        repeatButton.title = kind.title
        weekdayButton.title = Calendar.current.weekdaySymbols[task.recurrence.weekday - 1]
        weekdayButton.isHidden = kind != .weekly
        days.isHidden = kind != .days
        intervalField.isHidden = kind != .interval
        unitButton.isHidden = kind != .interval
        unitButton.title = Self.unitTitle(intervalUnit)
        cronField.isHidden = kind != .cron
        date.isHidden = kind == .cron
        date.datePickerElements = kind == .once || kind == .interval ? [.yearMonthDay, .hourMinute] : [.hourMinute]
        date.toolTip = kind == .interval ? String(localized: "The first run; later runs follow at the interval.") : nil
        for button in dayButtons {
            button.style = (task.recurrence.weekdays ?? []).contains(button.tag) ? .primary : .secondary
        }
        let recurrence = current
        let error = recurrence.validationError
        if let error {
            preview.stringValue = error
            preview.textColor = .systemRed
        } else {
            let runs = recurrence.upcoming(after: Date(), count: 3)
            preview.textColor = .secondaryLabelColor
            preview.stringValue =
                runs.isEmpty
                ? String(localized: "No future runs. Choose a later time.")
                : String(localized: "\(recurrence.summary). Next: \(ListFormatter.localizedString(byJoining: runs.map { SchedulePresentation.fullTime($0, zoneID: recurrence.timeZoneID) }))")
        }
        let hasTarget = task.threadID.map { store.summary($0) != nil } ?? projects.contains(where: { $0.id == task.projectID })
        saveButton.isEnabled = !name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && TimeZone(identifier: zone.stringValue) != nil && hasTarget && error == nil
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSComboBox === zone, let timeZone = TimeZone(identifier: zone.stringValue) {
            var old = Calendar(identifier: .gregorian); old.timeZone = date.timeZone ?? .current
            let hour = old.component(.hour, from: date.dateValue), minute = old.component(.minute, from: date.dateValue)
            date.timeZone = timeZone
            if ![.once, .interval].contains(task.recurrence.kind) {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
                date.dateValue = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
            }
        }
        updateControls()
    }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: zone))
        }
    }
    func textDidChange(_ notification: Notification) { updateControls() }
    @objc private func changed() { updateControls() }

    private func menu(_ labels: [String], selected: Int, action: Selector, button: NSButton) {
        let menu = NSMenu()
        for (index, label) in labels.enumerated() {
            let item = NSMenuItem(title: label, action: action, keyEquivalent: "")
            item.target = self; item.tag = index; item.state = index == selected ? .on : .off
            menu.addItem(item)
        }
        ThemedPopup.show(menu: menu, from: button, preferAbove: false)
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
        menu(Self.kinds.map(\.title), selected: Self.kinds.firstIndex(of: task.recurrence.kind) ?? 0,
            action: #selector(pickRepeat(_:)), button: repeatButton)
    }
    @objc private func pickRepeat(_ item: NSMenuItem) {
        guard Self.kinds.indices.contains(item.tag) else { return }
        let kind = Self.kinds[item.tag]
        task.recurrence.kind = kind
        if kind == .days, (task.recurrence.weekdays ?? []).isEmpty { task.recurrence.weekdays = [task.recurrence.weekday] }
        if kind == .interval, task.recurrence.intervalMinutes == nil { task.recurrence.intervalMinutes = 30 }
        if kind == .once || kind == .interval, date.dateValue < Date() {
            date.dateValue = Date().addingTimeInterval(kind == .once ? 3600 : 0)
        }
        updateControls()
    }
    @objc private func chooseWeekday() {
        menu(Calendar.current.weekdaySymbols, selected: task.recurrence.weekday - 1,
            action: #selector(pickWeekday(_:)), button: weekdayButton)
    }
    @objc private func pickWeekday(_ item: NSMenuItem) { task.recurrence.weekday = item.tag + 1; updateControls() }
    @objc private func toggleDay(_ sender: ThemedButton) {
        var selected = Set(task.recurrence.weekdays ?? [])
        if selected.contains(sender.tag) { selected.remove(sender.tag) } else { selected.insert(sender.tag) }
        task.recurrence.weekdays = selected.sorted()
        updateControls()
    }
    @objc private func chooseUnit() {
        menu(Self.units.indices.map(Self.unitTitle), selected: intervalUnit, action: #selector(pickUnit(_:)), button: unitButton)
    }
    @objc private func pickUnit(_ item: NSMenuItem) {
        guard Self.units.indices.contains(item.tag) else { return }
        intervalUnit = item.tag; updateControls()
    }

    private static func unitTitle(_ index: Int) -> String {
        switch index {
        case 0: String(localized: "Minutes")
        case 1: String(localized: "Hours")
        default: String(localized: "Days")
        }
    }

    @objc private func save() {
        task.name = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        task.prompt = prompt.string.trimmingCharacters(in: .whitespacesAndNewlines)
        task.isPaused = paused.state == .on
        task.recurrence = current
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
        case .weekdays: String(localized: "Weekdays")
        case .days: String(localized: "On Selected Days")
        case .interval: String(localized: "Every…")
        case .cron: String(localized: "Custom (cron)")
        }
    }
}
