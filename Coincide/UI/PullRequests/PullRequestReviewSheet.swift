import AppKit
import CoincideKit

/// A review stays editable if GitHub rejects it, so a failed submission never loses the user's message.
final class PullRequestReviewSheet: NSViewController, NSTextViewDelegate {
    var onSubmit: ((PullRequestReviewEvent, String) async throws -> Void)?
    private let number: Int
    private let eventPicker = ThemedPopUpButton(frame: .zero, pullsDown: false)
    private let message = PlaceholderTextView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var submitButton = ThemedButton(
        title: String(localized: "Submit Review"), style: .primary, target: self, action: #selector(submit))
    private lazy var cancelButton = ThemedButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel))
    private var isSubmitting = false

    init(number: Int) {
        self.number = number
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let title = NSTextField(labelWithString: String(localized: "Review pull request #\(number)"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        eventPicker.addItems(withTitles: [String(localized: "Comment"), String(localized: "Approve"), String(localized: "Request Changes")])
        eventPicker.target = self
        eventPicker.action = #selector(selectionChanged)
        eventPicker.setAccessibilityLabel(String(localized: "Review outcome"))
        message.placeholder = String(localized: "Write your review…")
        message.setAccessibilityLabel(String(localized: "Review message"))
        message.isRichText = false
        message.allowsUndo = true
        message.font = .systemFont(ofSize: Theme.fontSize)
        message.textContainerInset = NSSize(width: 6, height: 6)
        message.isVerticallyResizable = true
        message.autoresizingMask = [.width]
        message.textContainer?.widthTracksTextView = true
        message.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = message
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.heightAnchor.constraint(equalToConstant: 160).isActive = true
        errorLabel.textColor = Theme.failure
        errorLabel.isHidden = true
        cancelButton.keyEquivalent = "\u{1b}"
        submitButton.keyEquivalent = "\r"
        submitButton.keyEquivalentModifierMask = .command
        let buttons = NSStackView(views: [NSView(), cancelButton, submitButton])
        buttons.spacing = 8
        let stack = NSStackView(views: [title, eventPicker, scroll, errorLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.widthAnchor.constraint(equalToConstant: 500).isActive = true
        for child in [scroll, errorLabel, buttons] {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        view = stack
        updateEnabled()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(message)
    }

    private var event: PullRequestReviewEvent { PullRequestReviewEvent.allCases[max(0, eventPicker.indexOfSelectedItem)] }

    func textDidChange(_ notification: Notification) { updateEnabled() }
    @objc private func selectionChanged() { updateEnabled() }

    private func updateEnabled() {
        submitButton.isEnabled = !isSubmitting && event.accepts(body: message.string)
        cancelButton.isEnabled = !isSubmitting
        eventPicker.isEnabled = !isSubmitting
        message.isEditable = !isSubmitting
    }

    @objc private func submit() {
        guard !isSubmitting, event.accepts(body: message.string), let onSubmit else { return }
        let event = event
        let body = message.string
        isSubmitting = true
        errorLabel.isHidden = true
        updateEnabled()
        Task {
            do {
                try await onSubmit(event, body)
                dismiss(nil)
            } catch {
                let failure = error as? GitError
                errorLabel.stringValue = [failure?.message ?? error.localizedDescription, failure?.detail].compactMap { $0 }.joined(separator: "\n")
                errorLabel.isHidden = false
            }
            isSubmitting = false
            updateEnabled()
        }
    }

    @objc private func cancel() {
        guard !isSubmitting else { return }
        dismiss(nil)
    }
}
