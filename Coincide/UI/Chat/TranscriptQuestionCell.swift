import AppKit
import CoincideKit

/// Questions an agent asks the user (Claude's AskUserQuestion, Codex's request_user_input…).
///
/// While waiting it is a small form: each question's options as radio buttons (checkboxes when
/// several may be chosen) and a field for a typed answer, secure for secrets, with Dismiss and
/// Submit. Once answered, dismissed or resolved by the agent it shrinks to a summary.
final class TranscriptQuestionCell: TranscriptCell, NSTextFieldDelegate {
    private static let padding: CGFloat = 12
    private static let kindRowHeight: CGFloat = 18
    private static let optionHeight: CGFloat = 20
    private static let optionIndent: CGFloat = 20
    private static let fieldHeight: CGFloat = 24
    private static let answerLineHeight: CGFloat = 20

    private let card = TranscriptCardView()
    private let icon = NSImageView()
    private let kindLabel = NSTextField(labelWithString: "")
    private let titleView = ChatTextView()
    private var sections: [QuestionSectionView] = []
    private lazy var dismissButton = NSButton(title: String(localized: "Dismiss"), target: self, action: #selector(dismiss))
    private lazy var submitButton = NSButton(title: String(localized: "Submit"), target: self, action: #selector(submit))
    private let summary = TranscriptDisclosureHeader()
    private var answerLabels: [NSTextField] = []
    private var item: TranscriptItem?
    /// Identifies the form on screen, so updates that leave the question alone keep focus and typing.
    private var formSignature: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(card)
        addSubview(summary)
        kindLabel.font = .systemFont(ofSize: Theme.fontSize - 2, weight: .semibold)
        for button in [dismissButton, submitButton] {
            button.bezelStyle = .push
            button.controlSize = .regular
        }
        submitButton.tintProminence = .primary
        for view in [icon, kindLabel, titleView, dismissButton, submitButton] as [NSView] { card.addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func configure(_ row: TranscriptRow, host: TranscriptHost) {
        super.configure(row, host: host)
        guard let id = row.itemID, let item = host.item(id), let request = item.questions else { return }
        self.item = item
        let isWaiting = item.status == .waiting
        card.isHidden = !isWaiting
        summary.isHidden = isWaiting
        if isWaiting {
            configureForm(request, item: item, host: host)
        } else {
            configureSummary(request, item: item)
        }
    }

    // MARK: Form

    private func configureForm(_ request: UserInputRequest, item: TranscriptItem, host: TranscriptHost) {
        var hasher = Hasher()
        hasher.combine(item.id)
        hasher.combine(request)
        let signature = hasher.finalize()
        defer { updateSubmitButton() }
        guard signature != formSignature else { return }
        formSignature = signature
        for label in answerLabels { label.isHidden = true }

        card.strokeColor = Theme.warning.withAlphaComponent(0.45)
        icon.image = Theme.symbol("questionmark.bubble", size: 12, weight: .semibold)
        icon.contentTintColor = Theme.warning
        kindLabel.textColor = Theme.warning
        kindLabel.stringValue = Self.kindText(request, provider: item.provider)
        let title = request.title?.nonBlank
        titleView.isHidden = title == nil
        if let title { titleView.setText(Self.titleText(title)) }

        for section in sections { section.removeFromSuperview() }
        let draft = host.inputDraft(for: item.id)
        sections = request.questions.enumerated().map { index, question in
            let section = QuestionSectionView(question: question, index: index, draft: draft, owner: self)
            card.addSubview(section)
            return section
        }
        setAccessibilityLabel(kindLabel.stringValue + (title.map { ": \($0)" } ?? ""))
        needsLayout = true
    }

    private func updateSubmitButton() {
        guard let item, let request = item.questions, let host, item.status == .waiting else { return }
        submitButton.isEnabled = host.inputDraft(for: item.id).isComplete(for: request)
    }

    fileprivate func optionClicked(_ sender: NSButton, in section: QuestionSectionView) {
        guard let item, let host else { return }
        let question = section.question
        guard question.options.indices.contains(sender.tag) else { return }
        let label = question.options[sender.tag].label
        let draft = host.inputDraft(for: item.id)
        var chosen = draft.selections[question.id] ?? []
        if question.allowsMultipleSelection {
            if sender.state == .on { chosen.insert(label) } else { chosen.remove(label) }
        } else {
            chosen = [label]
        }
        draft.selections[question.id] = chosen
        updateSubmitButton()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let item, let host,
            let section = sections.first(where: { $0.field === field })
        else { return }
        host.inputDraft(for: item.id).texts[section.question.id] = field.stringValue
        updateSubmitButton()
    }

    /// Return in an answer field submits once every question is answered.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if submitButton.isEnabled { submit() } else { NSSound.beep() }
        return true
    }

    @objc private func submit() {
        guard let item, let request = item.questions, let host else { return }
        let draft = host.inputDraft(for: item.id)
        guard draft.isComplete(for: request) else { return }
        host.answer(item.id, answers: draft.answers(for: request))
    }

    @objc private func dismiss() {
        guard let item else { return }
        host?.dismissQuestion(item.id)
    }

    // MARK: Summary

    private func configureSummary(_ request: UserInputRequest, item: TranscriptItem) {
        formSignature = nil
        for section in sections { section.removeFromSuperview() }
        sections = []
        let font = NSFont.systemFont(ofSize: Theme.fontSize - 1)
        let title = request.title?.nonBlank ?? request.questions.first?.prompt ?? String(localized: "Question")
        let (detail, status): (String?, TranscriptDisclosureHeader.Status) =
            switch (item.status, item.answers) {
            case (.declined, _): (String(localized: "Not answered"), .declined)
            case (_, nil): (String(localized: "Resolved by the agent"), .completed)
            default: (nil, .completed)
            }
        summary.configure(
            symbol: "questionmark.bubble", title: TranscriptText.inlineLabel(title, font: font, color: .secondaryLabelColor),
            detail: detail, status: status, isExpandable: false, isExpanded: false)

        let lines = Self.answerLines(request, answers: item.answers)
        while answerLabels.count < lines.count {
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            addSubview(label)
            answerLabels.append(label)
        }
        for (index, label) in answerLabels.enumerated() {
            label.isHidden = index >= lines.count
            guard index < lines.count else { continue }
            let (question, answer) = lines[index]
            let text = NSMutableAttributedString(
                string: question + "  ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            text.append(NSAttributedString(string: answer, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            label.attributedStringValue = text
            label.toolTip = "\(question)\n\(answer)"
        }
        setAccessibilityLabel(([title, detail].compactMap { $0 } + lines.map { "\($0.0): \($0.1)" }).joined(separator: ", "))
        needsLayout = true
    }

    private static func answerLines(_ request: UserInputRequest, answers: [String: [String]]?) -> [(String, String)] {
        guard let answers else { return [] }
        return request.questions.compactMap { question in
            guard let values = answers[question.id], !values.isEmpty else { return nil }
            return (question.header?.nonBlank ?? question.prompt, values.joined(separator: ", "))
        }
    }

    // MARK: Text

    private static func kindText(_ request: UserInputRequest, provider: ProviderKind?) -> String {
        let count = request.questions.count
        guard let provider else { return count == 1 ? String(localized: "Question") : String(localized: "\(count) questions") }
        return count == 1
            ? String(localized: "Question from \(provider.displayName)")
            : String(localized: "\(count) questions from \(provider.displayName)")
    }

    static func titleText(_ title: String) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: ChatFonts.body(Theme.fontSize, weight: .semibold), .foregroundColor: NSColor.labelColor])
    }

    static func promptText(_ prompt: String) -> NSAttributedString {
        ChatMarkdownRenderer.render(prompt, style: ChatMarkdownStyle(fontSize: Theme.fontSize)).string
    }

    static func detailText(_ detail: String) -> NSAttributedString {
        NSAttributedString(string: detail, attributes: [.font: ChatFonts.body(Theme.fontSize - 2), .foregroundColor: NSColor.secondaryLabelColor])
    }

    // MARK: Layout

    fileprivate struct SectionLayout {
        var frame: NSRect
        var header: NSRect?
        var prompt: NSRect
        var options: [NSRect]
        var details: [NSRect?]
        var field: NSRect?
    }

    private struct FormLayout {
        var title: NSRect?
        var sections: [SectionLayout]
        var buttonsY: CGFloat
        var cardHeight: CGFloat
    }

    /// Frames inside the card. Section children are relative to their section.
    private static func formLayout(_ request: UserInputRequest, width: CGFloat) -> FormLayout {
        let measurer = ChatTextMeasurer.shared
        let inner = TranscriptMetrics.column(width: width).width - padding * 2
        var y = padding + kindRowHeight + 6
        var title: NSRect?
        if let text = request.title?.nonBlank {
            let height = measurer.height(of: titleText(text), width: inner)
            title = NSRect(x: padding, y: y, width: inner, height: height)
            y += height + 10
        }
        var sections: [SectionLayout] = []
        for (index, question) in request.questions.enumerated() {
            if index > 0 { y += 14 }
            let top = y
            var local: CGFloat = 0
            var header: NSRect?
            if question.header?.nonBlank != nil {
                header = NSRect(x: padding, y: local, width: inner, height: 16)
                local += 18
            }
            let promptHeight = measurer.height(of: promptText(question.prompt), width: inner)
            let prompt = NSRect(x: padding, y: local, width: inner, height: promptHeight)
            local += promptHeight + 6
            var options: [NSRect] = []
            var details: [NSRect?] = []
            for option in question.options {
                options.append(NSRect(x: padding - 1, y: local, width: inner + 1, height: optionHeight))
                local += optionHeight
                if let detail = option.detail?.nonBlank {
                    let height = measurer.height(of: detailText(detail), width: inner - optionIndent)
                    details.append(NSRect(x: padding + optionIndent, y: local, width: inner - optionIndent, height: height))
                    local += height + 2
                } else {
                    details.append(nil)
                }
                local += 4
            }
            var field: NSRect?
            if question.allowsFreeText {
                field = NSRect(x: padding, y: local + 2, width: inner, height: fieldHeight)
                local += fieldHeight + 4
            }
            sections.append(
                SectionLayout(
                    frame: NSRect(x: 0, y: top, width: inner + padding * 2, height: local), header: header, prompt: prompt,
                    options: options, details: details, field: field))
            y = top + local
        }
        let buttonsY = y + 10
        return FormLayout(title: title, sections: sections, buttonsY: buttonsY, cardHeight: buttonsY + 28 + padding)
    }

    override class var measuresText: Bool { true }

    override class func height(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        guard let id = row.itemID, let item = host.item(id), let request = item.questions else { return 0 }
        if item.status == .waiting { return formLayout(request, width: width).cardHeight + bottomSpacing(for: row) }
        let lines = CGFloat(answerLines(request, answers: item.answers).count)
        return TranscriptMetrics.workRowHeight + lines * answerLineHeight + bottomSpacing(for: row)
    }

    override var copyText: String? {
        guard let item, let request = item.questions else { return nil }
        return request.questions.map { question in
            let answer = item.answers?[question.id]?.joined(separator: ", ")
            return [question.prompt, answer].compactMap { $0 }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    override func layout() {
        super.layout()
        guard let item, let request = item.questions else { return }
        let column = TranscriptMetrics.column(width: bounds.width)
        guard item.status == .waiting else {
            summary.frame = NSRect(x: column.x, y: 0, width: column.width, height: TranscriptMetrics.workRowHeight)
            var y = TranscriptMetrics.workRowHeight
            for label in answerLabels where !label.isHidden {
                label.frame = NSRect(x: column.x + TranscriptMetrics.detailIndent, y: y + 1, width: column.width - TranscriptMetrics.detailIndent, height: 18)
                y += Self.answerLineHeight
            }
            return
        }
        let layout = Self.formLayout(request, width: bounds.width)
        card.frame = NSRect(x: column.x, y: 0, width: column.width, height: layout.cardHeight)
        icon.frame = NSRect(x: Self.padding, y: Self.padding + 1, width: 16, height: 16)
        kindLabel.frame = NSRect(x: Self.padding + 22, y: Self.padding, width: column.width - Self.padding * 2 - 22, height: Self.kindRowHeight)
        if let title = layout.title { titleView.frame = title }
        for (section, frames) in zip(sections, layout.sections) { section.apply(frames) }
        var x = column.width - Self.padding
        for button in [submitButton, dismissButton] {
            let width = max(84, ceil(button.intrinsicContentSize.width))
            x -= width
            button.frame = NSRect(x: x, y: layout.buttonsY, width: width, height: 28)
            x -= 8
        }
    }
}

/// One question in the form: header, prompt, options and the answer field. Each question has its
/// own view so its radio buttons form their own group.
private final class QuestionSectionView: NSView {
    let question: UserQuestion
    private let header = NSTextField(labelWithString: "")
    private let prompt = ChatTextView()
    private var buttons: [NSButton] = []
    private var details: [ChatTextView] = []
    private(set) var field: NSTextField?
    private weak var owner: TranscriptQuestionCell?

    override var isFlipped: Bool { true }

    init(question: UserQuestion, index: Int, draft: TranscriptInputDraft, owner: TranscriptQuestionCell) {
        self.question = question
        self.owner = owner
        super.init(frame: .zero)
        header.font = .systemFont(ofSize: Theme.fontSize - 2, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.stringValue = question.header ?? ""
        header.isHidden = question.header?.nonBlank == nil
        addSubview(header)
        prompt.setText(TranscriptQuestionCell.promptText(question.prompt))
        addSubview(prompt)

        let chosen = draft.selections[question.id] ?? []
        for (optionIndex, option) in question.options.enumerated() {
            let button =
                question.allowsMultipleSelection
                ? NSButton(checkboxWithTitle: option.label, target: self, action: #selector(optionClicked(_:)))
                : NSButton(radioButtonWithTitle: option.label, target: self, action: #selector(optionClicked(_:)))
            button.font = .systemFont(ofSize: Theme.fontSize)
            button.lineBreakMode = .byTruncatingTail
            button.tag = optionIndex
            button.state = chosen.contains(option.label) ? .on : .off
            button.toolTip = option.detail
            addSubview(button)
            buttons.append(button)
            let detail = ChatTextView()
            detail.isHidden = option.detail?.nonBlank == nil
            if let text = option.detail?.nonBlank { detail.setText(TranscriptQuestionCell.detailText(text)) }
            addSubview(detail)
            details.append(detail)
        }
        if question.allowsFreeText {
            let field = question.isSecret ? NSSecureTextField() : NSTextField()
            field.font = .systemFont(ofSize: Theme.fontSize)
            field.placeholderString = question.options.isEmpty ? String(localized: "Your answer") : String(localized: "Other answer")
            field.stringValue = draft.texts[question.id] ?? ""
            field.delegate = owner
            field.setAccessibilityLabel(question.prompt)
            addSubview(field)
            self.field = field
        }
        setAccessibilityElement(true)
        setAccessibilityRole(question.allowsMultipleSelection ? .group : .radioGroup)
        setAccessibilityLabel(question.header?.nonBlank ?? question.prompt)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ layout: TranscriptQuestionCell.SectionLayout) {
        frame = layout.frame
        if let rect = layout.header { header.frame = rect }
        prompt.frame = layout.prompt
        for (button, rect) in zip(buttons, layout.options) { button.frame = rect }
        for (detail, rect) in zip(details, layout.details) {
            if let rect { detail.frame = rect }
        }
        if let rect = layout.field { field?.frame = rect }
    }

    @objc private func optionClicked(_ sender: NSButton) {
        owner?.optionClicked(sender, in: self)
    }
}

private extension String {
    var nonBlank: String? { allSatisfy(\.isWhitespace) ? nil : self }
}
