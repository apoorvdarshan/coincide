import AppKit
import CoincideKit

/// A glass card stacked above the composer for approvals, plan follow-ups, agent switches and queued messages.
class ComposerBanner: NSView {
    let content = NSStackView()
    private let glass = NSGlassEffectView()

    /// Hides the glass itself too, in case an enclosing glass container lifts it out from under this view.
    override var isHidden: Bool {
        didSet { glass.isHidden = isHidden }
    }

    init(tint: NSColor? = nil) {
        super.init(frame: .zero)
        glass.cornerRadius = 14
        glass.tintColor = tint
        content.orientation = .horizontal
        content.alignment = .top
        content.distribution = .fill
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 10)
        content.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView = content
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            content.topAnchor.constraint(equalTo: glass.topAnchor),
            content.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func icon(_ symbolName: String, color: NSColor) -> NSImageView {
        let view = NSImageView(image: Theme.symbol(symbolName, size: 13, weight: .semibold) ?? NSImage())
        view.contentTintColor = color
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        return view
    }

    static func label(_ text: String = "", size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = .labelColor)
        -> NSTextField
    {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

/// The latest approval the agent is waiting on, with the provider's choices as buttons and,
/// when the agent asks for it, a field for text to send along with the choice.
final class ComposerApprovalBanner: ComposerBanner {
    var onRespond: ((_ itemID: UUID, _ optionID: String, _ text: String?) -> Void)?

    private let heading = ComposerBanner.label(size: 11, weight: .semibold, color: .systemOrange)
    private let agent = ComposerBanner.label(size: 11, color: .secondaryLabelColor)
    private let counter = ComposerBanner.label(size: 11, color: .secondaryLabelColor)
    private let summary = ComposerBanner.label(weight: .medium)
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let input = NSTextField()
    private let buttons = NSStackView()
    private var inputHeight: NSLayoutConstraint?
    private var itemID: UUID?
    private var textInput: TextInputSpec?

    init() {
        super.init(tint: Theme.approvalTint)
        counter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        counter.setContentCompressionResistancePriority(.required, for: .horizontal)
        summary.maximumNumberOfLines = 2
        summary.lineBreakMode = .byTruncatingTail
        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 6
        detail.lineBreakMode = .byTruncatingTail
        detail.isSelectable = true
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        input.font = .systemFont(ofSize: 12)
        input.bezelStyle = .roundedBezel
        input.isHidden = true
        input.target = self
        input.action = #selector(submitText)
        (input.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false
        input.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons.orientation = .horizontal
        buttons.spacing = 6

        let titleRow = NSStackView(views: [heading, agent, NSView(), counter])
        titleRow.orientation = .horizontal
        titleRow.spacing = 6
        let actionRow = NSStackView(views: [NSView(), buttons])
        actionRow.orientation = .horizontal
        let column = NSStackView(views: [titleRow, summary, detail, input, actionRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.detachesHiddenViews = true
        column.setCustomSpacing(8, after: detail)
        column.setCustomSpacing(8, after: input)
        for row in [titleRow, summary, detail, input, actionRow] {
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        let height = input.heightAnchor.constraint(equalToConstant: 22)
        height.isActive = true
        inputHeight = height
        content.addArrangedSubview(ComposerBanner.icon("exclamationmark.shield.fill", color: .systemOrange))
        content.addArrangedSubview(column)
    }

    func show(_ item: TranscriptItem, othersWaiting: Int) {
        let isNew = item.id != itemID
        itemID = item.id
        let kind = Self.heading(for: item.category)
        heading.stringValue = kind
        agent.stringValue = item.provider?.displayName ?? ""
        counter.stringValue = othersWaiting > 0 ? String(localized: "\(othersWaiting) more waiting") : ""
        // Titles use Markdown code spans for commands, as in the transcript.
        let title = NSMutableAttributedString(
            attributedString: TranscriptText.inlineLabel(
                item.title ?? kind, font: .systemFont(ofSize: 12, weight: .medium), color: .labelColor))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        title.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: title.length))
        summary.attributedStringValue = title
        let detailText = item.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        detail.stringValue = detailText
        detail.isHidden = detailText.isEmpty || detailText == item.title
        setAccessibilityLabel([kind, item.provider?.displayName, title.string].compactMap { $0 }.joined(separator: ", "))

        textInput = item.approval?.textInput
        input.isHidden = textInput == nil
        if let textInput, isNew {
            input.stringValue = textInput.initialText ?? ""
            input.placeholderString = textInput.placeholder ?? String(localized: "Reply to the agent")
            input.setAccessibilityLabel(textInput.placeholder ?? String(localized: "Reply to the agent"))
            input.usesSingleLineMode = !textInput.isMultiline
            input.cell?.wraps = textInput.isMultiline
            input.cell?.isScrollable = !textInput.isMultiline
            inputHeight?.constant = textInput.isMultiline ? 58 : 22
        }

        guard isNew else { return }
        for view in buttons.arrangedSubviews { view.removeFromSuperview() }
        let options = (item.approval?.options ?? []).sorted { Self.order($0.kind) < Self.order($1.kind) }
        for option in options {
            let button = NSButton(title: option.label, target: self, action: #selector(respond(_:)))
            button.controlSize = .small
            button.bezelStyle = .push
            button.identifier = NSUserInterfaceItemIdentifier(option.id)
            if option.kind == .allowOnce { button.tintProminence = .primary }
            buttons.addArrangedSubview(button)
        }
    }

    @objc private func respond(_ sender: NSButton) {
        guard let itemID, let optionID = sender.identifier?.rawValue else { return }
        onRespond?(itemID, optionID, textInput == nil ? nil : input.stringValue)
    }

    /// Return in the text field picks the primary choice.
    @objc private func submitText() {
        guard let primary = buttons.arrangedSubviews.last as? NSButton else { return }
        respond(primary)
    }

    /// Denials first and the plain "allow" last, so the primary choice sits at the trailing edge.
    private static func order(_ kind: ApprovalOption.Kind) -> Int {
        switch kind {
        case .cancel: 0
        case .deny: 1
        case .allowAlways: 2
        case .allowOnce: 3
        }
    }

    private static func heading(for category: ToolCategory?) -> String {
        switch category {
        case .command: String(localized: "Command approval")
        case .fileChange: String(localized: "File change approval")
        case .read, .search: String(localized: "File read approval")
        case .web: String(localized: "Web access approval")
        case .mcp: String(localized: "Tool approval")
        default: String(localized: "Approval needed")
        }
    }
}

/// Shown in plan mode once the agent has proposed a plan; the send button then offers to implement it.
final class ComposerPlanBanner: ComposerBanner {
    private let title = ComposerBanner.label()

    init() {
        super.init()
        let heading = ComposerBanner.label(String(localized: "Plan ready"), weight: .semibold, color: .secondaryLabelColor)
        heading.setContentCompressionResistancePriority(.required, for: .horizontal)
        content.alignment = .centerY
        content.addArrangedSubview(ComposerBanner.icon("checklist", color: .controlAccentColor))
        content.addArrangedSubview(heading)
        content.addArrangedSubview(title)
    }

    func show(planTitle: String?) {
        title.stringValue = planTitle ?? ""
        title.isHidden = planTitle == nil
        setAccessibilityLabel([String(localized: "Plan ready"), planTitle].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Questions the agent is waiting on, one at a time, as in T3 Code's pending user input panel:
/// pick options or type an answer, then go on to the next question. Picking a single option with the
/// mouse moves on by itself.
final class ComposerQuestionBanner: ComposerBanner, NSTextFieldDelegate {
    var onAnswer: ((_ itemID: UUID, _ answers: [String: [String]]) -> Void)?
    var onDismiss: ((UUID) -> Void)?

    private let heading = ComposerBanner.label(size: 11, weight: .semibold, color: .controlAccentColor)
    private let agent = ComposerBanner.label(size: 11, color: .secondaryLabelColor)
    private let counter = ComposerBanner.label(size: 11, color: .secondaryLabelColor)
    private let prompt = NSTextField(wrappingLabelWithString: "")
    private let options = NSStackView()
    private let answerField = NSTextField()
    private let secretField = NSSecureTextField()
    private let backButton = NSButton(title: String(localized: "Back"), target: nil, action: nil)
    private let nextButton = NSButton(title: String(localized: "Next"), target: nil, action: nil)
    private var itemID: UUID?
    private var requestTitle: String?
    private var questions: [UserQuestion] = []
    private var index = 0
    private var selections: [String: [String]] = [:]
    private var typed: [String: String] = [:]
    /// The question whose option buttons are on screen, so picking an option keeps keyboard focus in place.
    private var renderedQuestion: (itemID: UUID, questionID: String)?
    private var pendingAdvance: DispatchWorkItem?

    init() {
        super.init(tint: Theme.questionTint)
        counter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        counter.setContentCompressionResistancePriority(.required, for: .horizontal)
        let dismiss = NSButton(
            image: NSImage(
                systemSymbolName: "xmark", accessibilityDescription: String(localized: "Dismiss without answering"))
                ?? NSImage(), target: self, action: #selector(dismiss))
        dismiss.isBordered = false
        dismiss.contentTintColor = .secondaryLabelColor
        dismiss.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        dismiss.toolTip = String(localized: "Dismiss without answering")
        prompt.font = .systemFont(ofSize: 13)
        prompt.maximumNumberOfLines = 8
        prompt.isSelectable = true
        prompt.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 4
        for field in [answerField, secretField] {
            field.font = .systemFont(ofSize: 12)
            field.bezelStyle = .roundedBezel
            field.delegate = self
            field.target = self
            field.action = #selector(next)
            (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        answerField.placeholderString = String(localized: "Type your own answer")
        secretField.placeholderString = String(localized: "Type your answer")
        for button in [backButton, nextButton] {
            button.controlSize = .small
            button.bezelStyle = .push
            button.target = self
        }
        backButton.action = #selector(back)
        nextButton.action = #selector(next)
        nextButton.tintProminence = .primary

        let titleRow = NSStackView(views: [heading, agent, NSView(), counter, dismiss])
        titleRow.orientation = .horizontal
        titleRow.spacing = 6
        let actionRow = NSStackView(views: [NSView(), backButton, nextButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 6
        let column = NSStackView(views: [titleRow, prompt, options, answerField, secretField, actionRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.detachesHiddenViews = true
        for row in [titleRow, prompt, options, answerField, secretField, actionRow] {
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        content.addArrangedSubview(ComposerBanner.icon("questionmark.bubble.fill", color: .controlAccentColor))
        content.addArrangedSubview(column)
    }

    /// Shows `item`'s questions, keeping the answers given so far while it stays the same item.
    func show(_ item: TranscriptItem, othersWaiting: Int) {
        if item.id != itemID {
            itemID = item.id
            requestTitle = item.questions?.title
            questions = item.questions?.questions ?? []
            index = 0
            selections = [:]
            typed = [:]
            pendingAdvance?.cancel()
        }
        agent.stringValue = [item.provider?.displayName, othersWaiting > 0 ? String(localized: "\(othersWaiting) more waiting") : nil]
            .compactMap { $0 }.joined(separator: " · ")
        render()
    }

    private var question: UserQuestion? { questions.indices.contains(index) ? questions[index] : nil }

    private func render() {
        guard let itemID, let question else { return }
        heading.stringValue = question.header ?? requestTitle ?? String(localized: "Question")
        counter.stringValue = questions.count > 1 ? String(localized: "\(index + 1) of \(questions.count)") : ""
        prompt.stringValue = question.prompt
        setAccessibilityLabel([heading.stringValue, agent.stringValue, question.prompt].joined(separator: ", "))

        if renderedQuestion?.itemID != itemID || renderedQuestion?.questionID != question.id {
            renderedQuestion = (itemID, question.id)
            buildOptions(for: question)
            let field = question.isSecret ? secretField : answerField
            field.stringValue = typed[question.id] ?? ""
            field.setAccessibilityLabel(question.prompt)
        }
        let typedAnswer = typed[question.id] ?? ""
        let picked = selections[question.id] ?? []
        for case let row as NSStackView in options.arrangedSubviews {
            guard let button = row.arrangedSubviews.first as? NSButton, question.options.indices.contains(button.tag)
            else { continue }
            button.state = typedAnswer.isEmpty && picked.contains(question.options[button.tag].label) ? .on : .off
        }
        options.isHidden = question.options.isEmpty
        answerField.isHidden = !question.allowsFreeText || question.isSecret
        secretField.isHidden = !question.allowsFreeText || !question.isSecret
        backButton.isHidden = index == 0
        updateNextButton()
    }

    private func buildOptions(for question: UserQuestion) {
        for view in options.arrangedSubviews { view.removeFromSuperview() }
        for (position, option) in question.options.enumerated() {
            let button =
                question.allowsMultipleSelection
                ? NSButton(checkboxWithTitle: option.label, target: self, action: #selector(toggleOption(_:)))
                : NSButton(radioButtonWithTitle: option.label, target: self, action: #selector(toggleOption(_:)))
            button.tag = position
            let row = NSStackView(views: [button])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 1
            if let detail = option.detail, !detail.isEmpty, detail != option.label {
                let detailLabel = NSTextField(wrappingLabelWithString: detail)
                detailLabel.font = .systemFont(ofSize: 11)
                detailLabel.textColor = .secondaryLabelColor
                detailLabel.maximumNumberOfLines = 2
                row.addArrangedSubview(detailLabel)
                detailLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20).isActive = true
                detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor).isActive = true
                button.setAccessibilityHelp(detail)
            }
            options.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: options.widthAnchor).isActive = true
        }
    }

    private func updateNextButton() {
        let isLast = index >= questions.count - 1
        nextButton.title =
            isLast ? (questions.count > 1 ? String(localized: "Submit Answers") : String(localized: "Submit"))
            : String(localized: "Next")
        nextButton.isEnabled = question.map { answer(for: $0) != nil } ?? false
    }

    /// The answer to `question` so far: typed text wins over picked options. Nil when it still needs one.
    private func answer(for question: UserQuestion) -> [String]? {
        let text = (typed[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return [text] }
        let picked = selections[question.id] ?? []
        if !picked.isEmpty { return picked }
        return question.options.isEmpty && !question.allowsFreeText ? [] : nil
    }

    @objc private func toggleOption(_ sender: NSButton) {
        guard let question, question.options.indices.contains(sender.tag) else { return }
        let label = question.options[sender.tag].label
        typed[question.id] = nil
        if question.allowsMultipleSelection {
            var picked = selections[question.id] ?? []
            if let existing = picked.firstIndex(of: label) { picked.remove(at: existing) } else { picked.append(label) }
            selections[question.id] = picked
            render()
            return
        }
        selections[question.id] = [label]
        render()
        // Arrow keys move through radio buttons too; only a click moves on to the next question.
        guard NSApp.currentEvent?.type == .leftMouseUp || NSApp.currentEvent?.type == .leftMouseDown else { return }
        pendingAdvance?.cancel()
        let advance = DispatchWorkItem { [weak self] in self?.next() }
        pendingAdvance = advance
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: advance)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let question, let field = notification.object as? NSTextField else { return }
        typed[question.id] = field.stringValue
        render()
    }

    @objc private func next() {
        pendingAdvance?.cancel()
        guard let itemID, let question, answer(for: question) != nil else { return }
        if index < questions.count - 1 {
            index += 1
            render()
            return
        }
        var answers: [String: [String]] = [:]
        for question in questions {
            guard let answer = answer(for: question) else {
                index = questions.firstIndex(of: question) ?? index
                render()
                return
            }
            answers[question.id] = answer
        }
        onAnswer?(itemID, answers)
    }

    @objc private func back() {
        pendingAdvance?.cancel()
        guard index > 0 else { return }
        index -= 1
        render()
    }

    @objc private func dismiss() {
        pendingAdvance?.cancel()
        if let itemID { onDismiss?(itemID) }
    }
}

/// Explains what happens when the thread continues on a different agent: it gets a recap of what it missed.
final class ComposerHandoffBanner: ComposerBanner {
    private let message = NSTextField(wrappingLabelWithString: "")
    private let iconView = ComposerBanner.icon("arrow.triangle.swap", color: .secondaryLabelColor)

    init() {
        super.init()
        message.font = .systemFont(ofSize: 12)
        message.maximumNumberOfLines = 2
        message.textColor = .secondaryLabelColor
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        content.alignment = .centerY
        content.addArrangedSubview(iconView)
        content.addArrangedSubview(message)
    }

    func show(provider: ProviderKind, missedMessages: Int, joining: Bool) {
        let name = provider.displayName
        iconView.contentTintColor = Theme.color(for: provider)
        message.stringValue =
            if joining {
                String(localized: "\(name) joins this thread and gets a recap of the conversation so far.")
            } else if missedMessages == 1 {
                String(localized: "\(name) picks up where the other agents left off, with a recap of the message it missed.")
            } else {
                String(localized: "\(name) picks up where the other agents left off, with a recap of the \(missedMessages) messages it missed.")
            }
        setAccessibilityLabel(message.stringValue)
    }
}

/// Messages sent while a turn runs. Each can be sent into the running turn when its agent takes messages while it
/// works (T3 Code's "Send now"), edited (taken back into the composer) or removed.
final class ComposerQueueBanner: ComposerBanner {
    var onEdit: ((UUID) -> Void)?
    var onRemove: ((UUID) -> Void)?
    var onSteer: ((UUID) -> Void)?
    /// Whether the running turn takes messages now, which offers "Send now" on each row.
    private var canSteer = false
    /// The key that sends the oldest queued message now (`ComposerSendKeys.steerQueued`), named on its row's "Send now"
    /// as in T3 Code's queue.
    private var steerKey: KeyShortcut?

    private let rows = NSStackView()
    private static let visibleRows = 3

    init() {
        super.init()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 2
        content.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 6)
        content.addArrangedSubview(rows)
        rows.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -18).isActive = true
    }

    func show(_ messages: [ThreadRunner.QueuedMessage], canSteer: Bool, steerKey: KeyShortcut?) {
        self.canSteer = canSteer
        self.steerKey = steerKey
        for view in rows.arrangedSubviews { view.removeFromSuperview() }
        for (index, message) in messages.prefix(Self.visibleRows).enumerated() {
            let row = makeRow(message, isFirst: index == 0)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        if messages.count > Self.visibleRows {
            let more = ComposerBanner.label(
                String(localized: "\(messages.count - Self.visibleRows) more queued"), size: 11, color: .tertiaryLabelColor)
            rows.addArrangedSubview(more)
        }
        setAccessibilityLabel(
            messages.count == 1
                ? String(localized: "1 queued message")
                : String(localized: "\(messages.count) queued messages"))
    }

    private func makeRow(_ message: ThreadRunner.QueuedMessage, isFirst: Bool) -> NSView {
        let icon = ComposerBanner.icon("clock", color: .tertiaryLabelColor)
        let firstLine = message.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let images = message.imagePaths.count
        let text =
            if firstLine.isEmpty {
                images == 1 ? String(localized: "1 image") : String(localized: "\(images) images")
            } else {
                firstLine
            }
        let label = ComposerBanner.label(text, color: .secondaryLabelColor)
        label.toolTip = message.text
        let edit = rowButton("pencil", label: String(localized: "Edit queued message"), id: message.id, action: #selector(edit(_:)))
        let remove = rowButton("xmark", label: String(localized: "Remove from queue"), id: message.id, action: #selector(remove(_:)))
        var views: [NSView] = [icon, label, NSView()]
        if canSteer {
            let title = String(localized: "Send now, into the current turn")
            let button = rowButton("arrow.turn.up.right", label: title, id: message.id, action: #selector(steer(_:)))
            if isFirst, let keys = steerKey?.displayString { button.toolTip = String(localized: "\(title) (\(keys))") }
            views.append(button)
        }
        let row = NSStackView(views: views + [edit, remove])
        row.orientation = .horizontal
        row.spacing = 6
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        row.setAccessibilityLabel(String(localized: "Queued: \(text)"))
        row.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return row
    }

    private func rowButton(_ symbolName: String, label: String, id: UUID, action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbolName, accessibilityDescription: label) ?? NSImage(), target: self,
            action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        button.toolTip = label
        button.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        return button
    }

    @objc private func edit(_ sender: NSButton) {
        if let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) { onEdit?(id) }
    }

    @objc private func steer(_ sender: NSButton) {
        if let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) { onSteer?(id) }
    }

    @objc private func remove(_ sender: NSButton) {
        if let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) { onRemove?(id) }
    }
}
