import AppKit
import CoincideKit
import QuickLookUI

/// The message composer under the transcript, ported from T3 Code's ChatComposer: an auto-growing editor
/// with `@` file mentions, `/` commands and image attachments; the unified agent and model picker,
/// reasoning effort, access mode and Build/Plan controls; the context meter, send (which queues while a
/// turn runs) and stop; and banners for pending approvals and questions, plan follow-ups, agent switches
/// and queued messages. Drafts persist per thread.
///
/// The view fills the width it is given and centers the composer in the transcript's column; clicks
/// outside the composer's controls pass through to whatever is behind it.
final class ComposerViewController: NSViewController, NSTextViewDelegate {
    var threadID: UUID? {
        didSet {
            guard threadID != oldValue else { return }
            leave(oldValue)
            bindThread()
        }
    }

    private let store: AppStore
    private let registry: ProviderRegistry
    private let runner: ThreadRunner

    private let rootView = ComposerRootView()
    private let column = NSStackView()
    private let queueBanner = ComposerQueueBanner()
    private let handoffBanner = ComposerHandoffBanner()
    private let planBanner = ComposerPlanBanner()
    private let questionBanner = ComposerQuestionBanner()
    private let approvalBanner = ComposerApprovalBanner()
    private let surface = NSGlassEffectView()
    private let surfaceStack = ComposerDropStack()
    private let attachmentStrip = ComposerAttachmentStrip()
    private let scrollView = NSScrollView()
    private let textView = ComposerTextView(usingTextLayoutManager: true)
    private let footer = ComposerFooterView()
    private let branchToolbar = BranchToolbarView(frame: .zero)
    private let suggestions = ComposerSuggestionPanel()
    private var textHeight: NSLayoutConstraint?

    private var storeToken: ObservationToken?
    private let editUndoManager = UndoManager()
    private var attachments: [ComposerAttachment] = []
    /// Attachments of threads the user switched away from, restored when they come back.
    private var parkedAttachments: [UUID: [ComposerAttachment]] = [:]
    private var draftSave: Task<Void, Never>?
    private var trigger: ComposerTrigger?
    /// A trigger dismissed with Escape stays hidden until the caret leaves its word.
    private var dismissedTrigger: ComposerTrigger?
    private var suggestionSearch: Task<Void, Never>?
    /// Approvals and questions the agent is waiting on, refreshed when one of them changes.
    private var pendingRequestIDs: Set<UUID> = []
    private var hasPendingApproval = false
    private var hasPendingQuestion = false
    /// Images still being copied; sending waits for them.
    private var importingImages = 0
    /// The recalled prompt while browsing earlier messages with Up and Down.
    private var history: (index: Int, text: String)?
    /// The plan to implement when the thread is in plan mode and the last turn proposed one.
    private var proposedPlan: String?
    private var previewURLs: [URL] = []
    private var previewIndex = 0
    private var measuredWidth: CGFloat = 0
    private var focusWhenShown = false
    private weak var observedWindow: NSWindow?

    init(store: AppStore = .shared, registry: ProviderRegistry = .shared, runner: ThreadRunner = .shared) {
        self.store = store
        self.registry = registry
        self.runner = runner
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: View

    override func loadView() {
        view = rootView
        rootView.onKeyEquivalent = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }
        buildTextView()
        buildSurface()
        buildColumn()
        wireActions()

        storeToken = store.observe { [weak self] change in self?.handle(change) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(focusRequested), name: .coincideFocusComposer, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationWillTerminate), name: NSApplication.willTerminateNotification, object: nil)
        applySettings()
        bindThread()
    }

    private func buildTextView() {
        textView.configure()
        textView.delegate = self
        textView.font = Theme.bodyFont
        textView.textColor = .labelColor
        textView.onImages = { [weak self] sources in self?.addImages(sources) }
        textView.onFiles = { [weak self] urls in self?.mention(urls) }
        textView.onKeyDown = { [weak self] event in self?.handleKeyDown(event) ?? false }
        textView.onDragHover = { [weak self] hovering in self?.setDropHighlight(hovering) }
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
    }

    private func buildSurface() {
        surfaceStack.orientation = .vertical
        surfaceStack.alignment = .centerX
        surfaceStack.spacing = 8
        surfaceStack.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 8, right: 0)
        surfaceStack.onDrop = { [weak self] pasteboard in self?.textView.takeAttachments(from: pasteboard) ?? false }
        surfaceStack.onDragHover = { [weak self] hovering in self?.setDropHighlight(hovering) }
        attachmentStrip.onRemove = { [weak self] attachment in self?.removeAttachment(attachment) }
        attachmentStrip.onOpen = { [weak self] attachment in self?.preview(attachment) }
        attachmentStrip.isHidden = true
        for view in [attachmentStrip, scrollView, footer] as [NSView] { surfaceStack.addArrangedSubview(view) }
        surfaceStack.setCustomSpacing(4, after: scrollView)
        let height = scrollView.heightAnchor.constraint(equalToConstant: 22)
        textHeight = height
        NSLayoutConstraint.activate([
            height,
            attachmentStrip.widthAnchor.constraint(equalTo: surfaceStack.widthAnchor, constant: -32),
            scrollView.widthAnchor.constraint(equalTo: surfaceStack.widthAnchor, constant: -32),
            footer.widthAnchor.constraint(equalTo: surfaceStack.widthAnchor, constant: -16),
        ])
        surfaceStack.translatesAutoresizingMaskIntoConstraints = false
        surface.cornerRadius = 18
        surface.contentView = surfaceStack
        NSLayoutConstraint.activate([
            surfaceStack.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            surfaceStack.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            surfaceStack.topAnchor.constraint(equalTo: surface.topAnchor),
            surfaceStack.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ])
        surface.setAccessibilityElement(true)
        surface.setAccessibilityRole(.group)
        surface.setAccessibilityLabel(String(localized: "Composer"))
    }

    private func buildColumn() {
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 6
        column.detachesHiddenViews = true
        // What needs an answer sits closest to the input.
        let banners: [NSView] = [handoffBanner, planBanner, queueBanner, questionBanner, approvalBanner]
        for view in banners + [surface, branchToolbar] {
            column.addArrangedSubview(view)
        }
        column.setCustomSpacing(4, after: surface)
        for banner in banners {
            banner.isHidden = true
            banner.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -24).isActive = true
        }
        let toolbarHeight = branchToolbar.heightAnchor.constraint(equalToConstant: 28)
        toolbarHeight.priority = .init(200)
        NSLayoutConstraint.activate([
            surface.widthAnchor.constraint(equalTo: column.widthAnchor),
            branchToolbar.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -28),
            toolbarHeight,
        ])

        // A glass container would only batch these few glass views, and it can keep hidden ones drawing.
        column.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(column)
        let fullWidth = column.widthAnchor.constraint(equalTo: rootView.widthAnchor, constant: -2 * Theme.horizontalPadding)
        fullWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -12),
            column.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: Theme.contentMaxWidth),
            column.widthAnchor.constraint(lessThanOrEqualTo: rootView.widthAnchor, constant: -2 * Theme.horizontalPadding),
            fullWidth,
        ])
        rootView.passThroughViews = [column]
    }

    private func wireActions() {
        footer.modelButton.menuProvider = { [weak self] in self?.modelMenu() }
        footer.effortButton.menuProvider = { [weak self] in self?.effortMenu() }
        footer.accessButton.menuProvider = { [weak self] in self?.accessMenu() }
        footer.modeButton.target = self
        footer.modeButton.action = #selector(toggleInteractionMode)
        footer.attachButton.target = self
        footer.attachButton.action = #selector(chooseImages)
        footer.sendButton.target = self
        footer.sendButton.action = #selector(primaryAction)
        footer.stopButton.target = self
        footer.stopButton.action = #selector(stop)
        footer.stopButton.toolTip = String(localized: "Stop (⌘.)")
        footer.stopButton.setAccessibilityLabel(String(localized: "Stop"))
        footer.implementButton.target = self
        footer.implementButton.action = #selector(implementPlan)
        footer.implementButton.toolTip = String(localized: "Switch to build mode and implement the plan")
        approvalBanner.onRespond = { [weak self] itemID, optionID, text in
            guard let self, let threadID else { return }
            runner.respond(threadID: threadID, itemID: itemID, optionID: optionID, text: text)
            focus()
        }
        questionBanner.onAnswer = { [weak self] itemID, answers in
            guard let self, let threadID else { return }
            runner.answer(threadID: threadID, itemID: itemID, answers: answers)
            focus()
        }
        questionBanner.onDismiss = { [weak self] itemID in
            guard let self, let threadID else { return }
            runner.dismissQuestion(threadID: threadID, itemID: itemID)
            focus()
        }
        queueBanner.onEdit = { [weak self] id in self?.editQueued(id) }
        queueBanner.onRemove = { [weak self] id in
            guard let self, let threadID else { return }
            runner.removeQueued(threadID: threadID, id: id)
        }
        suggestions.onChoose = { [weak self] suggestion in self?.choose(suggestion) }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        observeWindow()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if focusWhenShown {
            focusWhenShown = false
            focus()
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        suggestions.hide()
        if let threadID { saveDraft(to: threadID) }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scrollView.contentSize.width
        if textView.frame.width != width { textView.frame.size.width = width }
        if width != measuredWidth {
            measuredWidth = width
            updateTextHeight()
        }
        suggestions.reposition(above: surface)
    }

    /// Replaces the text and attachments, for example when the user edits a message they already sent.
    func setDraft(_ text: String, imagePaths: [String]) {
        textView.setText(text)
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        attachments = imagePaths.filter { FileManager.default.fileExists(atPath: $0) }
            .map { ComposerAttachment(path: $0, name: ($0 as NSString).lastPathComponent) }
        refreshAttachments()
        textChanged()
        focus()
    }

    /// Puts the caret in the composer.
    func focus() {
        guard let window = view.window else {
            focusWhenShown = true
            return
        }
        window.makeFirstResponder(textView)
    }

    @objc private func focusRequested() {
        focus()
    }

    private func observeWindow() {
        guard let window = view.window, window !== observedWindow else { return }
        let center = NotificationCenter.default
        if let observedWindow {
            center.removeObserver(self, name: NSWindow.didResizeNotification, object: observedWindow)
            center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: observedWindow)
        }
        center.addObserver(self, selector: #selector(windowDidResize), name: NSWindow.didResizeNotification, object: window)
        center.addObserver(self, selector: #selector(windowDidResignKey), name: NSWindow.didResignKeyNotification, object: window)
        observedWindow = window
    }

    @objc private func windowDidResize() {
        updateTextHeight()
    }

    @objc private func windowDidResignKey() {
        suggestions.hide()
    }

    @objc private func applicationWillTerminate() {
        guard let threadID else { return }
        saveDraft(to: threadID)
        store.flush()
    }

    // MARK: Thread

    private var thread: ChatThread? { threadID.flatMap { store.thread($0) } }

    private func leave(_ id: UUID?) {
        guard let id else { return }
        saveDraft(to: id)
        if !attachments.isEmpty { parkedAttachments[id] = attachments }
    }

    private func bindThread() {
        suggestions.hide()
        suggestionSearch?.cancel()
        trigger = nil
        dismissedTrigger = nil
        history = nil
        branchToolbar.threadID = threadID
        textView.setText(thread?.draft ?? "")
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        editUndoManager.removeAllActions()
        attachments = threadID.flatMap { parkedAttachments.removeValue(forKey: $0) } ?? []
        attachmentStrip.show(attachments, warning: nil)
        refreshThread()
        refreshRunState()
        refreshRequests(announcing: false)
        refreshAttachments()
        updateTextHeight()
    }

    private func handle(_ change: StoreChange) {
        switch change {
        case .thread(let id) where id == threadID:
            refreshThread()
        case .items(let id, let changed, let appended) where id == threadID:
            itemsChanged(changed, appended: appended)
        case .runState(let id) where id == threadID:
            refreshRunState()
        case .threadList:
            if threadID != nil, thread == nil { refreshThread() }
        case .settings:
            applySettings()
            refreshThread()
        case .providers:
            refreshThread()
        default:
            break
        }
    }

    /// Streaming updates arrive many times a second; only approvals, questions and full reloads matter here.
    private func itemsChanged(_ changed: [UUID], appended: Bool) {
        if changed.isEmpty, !appended {
            refreshRequests()
            refreshPlan()
            refreshHandoff()
            return
        }
        if !pendingRequestIDs.isDisjoint(with: changed) {
            refreshRequests()
            return
        }
        guard appended, let items = thread?.items else { return }
        for id in changed {
            if let item = items.last(where: { $0.id == id }), item.kind == .approval || item.kind == .question,
                item.status == .waiting
            {
                refreshRequests()
                return
            }
        }
    }

    private func applySettings() {
        textView.font = Theme.bodyFont
        footer.sendButton.toolTip =
            store.settings.sendOnReturn ? String(localized: "Send (↩)") : String(localized: "Send (⌘↩)")
        updateTextHeight()
    }

    // MARK: Refresh

    private func refreshThread() {
        let thread = thread
        let enabled = thread != nil
        textView.isEditable = enabled
        for control in [footer.modelButton, footer.effortButton, footer.accessButton, footer.modeButton, footer.attachButton] {
            control.isEnabled = enabled
        }
        refreshControls(thread)
        refreshHandoff()
        refreshPlan()
        updatePlaceholder()
        updateSendState()
    }

    private func refreshControls(_ thread: ChatThread?) {
        guard let thread else {
            footer.modelButton.configure(title: String(localized: "No thread"), symbolName: "cpu", chevron: true)
            footer.effortButton.isHidden = true
            return
        }
        let selection = thread.selection
        let provider = selection.provider
        let model = registry.model(for: selection)
        let noneReady = noProviderReady
        let modelName = registry.displayName(for: selection)
        let title = selection.modelID == "default" ? provider.displayName : modelName
        if noneReady {
            footer.modelButton.configure(
                title: String(localized: "Set Up a Provider"), symbolName: "exclamationmark.circle", chevron: true)
        } else {
            footer.modelButton.configure(
                title: title, symbolName: provider.symbolName, symbolTint: Theme.color(for: provider), chevron: true)
        }
        footer.modelButton.toolTip = String(localized: "\(provider.displayName) · \(modelName). Choose the agent and model (⇧⌘M)")
        footer.modelButton.setAccessibilityLabel(String(localized: "Agent and model: \(provider.displayName), \(modelName)"))

        if let model, !model.efforts.isEmpty {
            let effort = selection.effort ?? model.defaultEffort
            footer.effortButton.isHidden = false
            footer.effortButton.configure(
                title: effort.map(ComposerMenus.effortTitle) ?? String(localized: "Default"), symbolName: "brain",
                chevron: true)
            footer.effortButton.toolTip = String(localized: "Reasoning effort (⇧⌘E)")
            footer.effortButton.setAccessibilityLabel(
                String(localized: "Reasoning effort: \(effort.map(ComposerMenus.effortTitle) ?? String(localized: "Default"))"))
        } else {
            footer.effortButton.isHidden = true
        }

        footer.accessButton.configure(
            title: thread.accessMode.displayName, symbolName: ComposerMenus.symbolName(for: thread.accessMode),
            chevron: true)
        footer.accessButton.toolTip = ComposerMenus.summary(for: thread.accessMode) + " (⇧⌘A)"
        footer.accessButton.setAccessibilityLabel(String(localized: "Access: \(thread.accessMode.displayName)"))

        let planning = thread.interactionMode == .plan
        footer.modeButton.configure(
            title: thread.interactionMode.displayName, symbolName: planning ? "pencil.and.ruler" : "hammer",
            chevron: false)
        footer.modeButton.isActive = planning
        footer.modeButton.toolTip =
            planning
            ? String(localized: "Plan mode: the agent plans before changing anything. Click to return to build mode (⇧⇥)")
            : String(localized: "Build mode. Click to have the agent plan first (⇧⇥)")
        footer.modeButton.setAccessibilityLabel(String(localized: "Plan mode"))
        footer.modeButton.setAccessibilityValue(planning)
        textView.setAccessibilityLabel(String(localized: "Message \(thread.title)"))
    }

    private func refreshRunState() {
        guard let threadID, let thread else {
            queueBanner.isHidden = true
            footer.contextMeter.isHidden = true
            updateSendState()
            return
        }
        let queued = runner.queuedMessages(threadID)
        if !queued.isEmpty { queueBanner.show(queued) }
        queueBanner.isHidden = queued.isEmpty

        // Usage belongs to whichever agent ran last; after a switch it says nothing about the new one.
        let lastProvider = runner.turn(threadID)?.provider ?? thread.items.last(where: { $0.kind == .user })?.provider
        if let usage = runner.usage[threadID], usage.inputTokens != nil, lastProvider == thread.selection.provider {
            let window = usage.contextWindow ?? registry.model(for: thread.selection)?.contextWindow
            footer.contextMeter.update(usage: usage, contextWindow: window)
            footer.contextMeter.isHidden = false
        } else {
            footer.contextMeter.isHidden = true
        }
        refreshHandoff()
        refreshPlan()
        updatePlaceholder()
        updateSendState()
    }

    /// Shows the latest approval and the latest question the agent is waiting on.
    /// VoiceOver hears about new ones, since they arrive while the user may be typing.
    private func refreshRequests(announcing: Bool = true) {
        let approvals = threadID.map { runner.pendingApprovals($0) } ?? []
        let questions = threadID.map { runner.pendingQuestions($0) } ?? []
        pendingRequestIDs = Set((approvals + questions).map(\.id))
        if let latest = approvals.last { approvalBanner.show(latest, othersWaiting: approvals.count - 1) }
        if let latest = questions.last { questionBanner.show(latest, othersWaiting: questions.count - 1) }
        let announce =
            announcing && ((!approvals.isEmpty && !hasPendingApproval) || (!questions.isEmpty && !hasPendingQuestion))
        hasPendingApproval = !approvals.isEmpty
        hasPendingQuestion = !questions.isEmpty
        approvalBanner.isHidden = approvals.isEmpty
        questionBanner.isHidden = questions.isEmpty
        if announce {
            let message =
                hasPendingQuestion ? String(localized: "The agent asked a question") : String(localized: "The agent needs approval")
            NSAccessibility.post(
                element: textView, notification: .announcementRequested,
                userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        updatePlaceholder()
    }

    /// Shows the agent switch banner when the selected agent will get a recap of turns other agents handled.
    private func refreshHandoff() {
        defer { if handoffBanner.isHidden { handoffBanner.alphaValue = 1 } }
        guard let threadID, let thread, thread.hasUserMessages, runner.turn(threadID)?.provider != thread.selection.provider
        else {
            handoffBanner.isHidden = true
            return
        }
        let provider = thread.selection.provider
        let missed = Handoff.missedItems(in: thread, for: provider)
        let count = missed.filter { $0.kind == .user || $0.kind == .assistant }.count
        guard count > 0, missed.contains(where: { $0.provider != nil && $0.provider != provider }) else {
            handoffBanner.isHidden = true
            return
        }
        let joining = (thread.sessions[provider]?.seenItemCount ?? 0) == 0
        handoffBanner.show(provider: provider, missedMessages: count, joining: joining)
        handoffBanner.isHidden = false
    }

    /// In plan mode, once a turn has settled with a plan, the empty composer offers to implement it.
    private func refreshPlan() {
        proposedPlan = nil
        defer {
            planBanner.isHidden = proposedPlan == nil
            if let proposedPlan { planBanner.show(planTitle: Self.title(ofPlan: proposedPlan)) }
        }
        guard let threadID, let thread, thread.interactionMode == .plan, !runner.isRunning(threadID), attachments.isEmpty
        else { return }
        var plan: String?
        var reply: String?
        for item in thread.items.reversed() {
            if item.kind == .user { break }
            switch item.kind {
            case .error: return
            case .plan where plan == nil: plan = item.text
            case .assistant where reply == nil: reply = item.text
            default: continue
            }
        }
        let text = (plan ?? reply)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        proposedPlan = text.isEmpty ? nil : text
    }

    private static func title(ofPlan plan: String) -> String? {
        let lines = plan.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let heading = lines.first { $0.hasPrefix("#") } ?? lines.first { !$0.isEmpty }
        return heading.map { $0.drop { $0 == "#" || $0 == " " }.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private func refreshAttachments() {
        var warning: String?
        if !attachments.isEmpty, let thread, let model = registry.model(for: thread.selection), !model.supportsImages {
            warning = String(localized: "\(model.displayName) may not be able to read images.")
        }
        attachmentStrip.show(attachments, warning: warning)
        refreshPlan()
        updateSendState()
    }

    private func updatePlaceholder() {
        textView.placeholder = placeholder()
    }

    private func placeholder() -> String {
        guard let thread else { return String(localized: "Select a thread to start") }
        if noProviderReady {
            return String(localized: "Enable a provider in Settings to send a message")
        }
        let provider = thread.selection.provider
        if !isUsable(provider) {
            return String(localized: "\(provider.displayName) isn't available. Choose another agent below.")
        }
        if hasPendingApproval {
            return String(localized: "Send a message to decline and redirect the agent")
        }
        if hasPendingQuestion {
            return String(localized: "Answer above, or send a message to skip the question")
        }
        if proposedPlan != nil {
            return String(localized: "Add feedback to refine the plan, or leave this blank to implement it")
        }
        return String(localized: "Ask anything. @ files, / commands")
    }

    /// A provider counts as usable until a check says otherwise, so nothing is blocked while statuses load.
    private func isUsable(_ provider: ProviderKind) -> Bool {
        switch registry.status(provider).state {
        case .ready: true
        case .unknown: store.settings.settings(for: provider).isEnabled
        case .notInstalled, .notAuthenticated, .error: false
        }
    }

    /// True once every enabled provider has been checked and none of them can run.
    private var noProviderReady: Bool {
        guard !registry.isRefreshing, registry.readyKinds.isEmpty else { return false }
        return registry.orderedKinds.allSatisfy {
            registry.status($0).state != .unknown || !store.settings.settings(for: $0).isEnabled
        }
    }

    private var hasContent: Bool {
        !attachments.isEmpty || textView.string.contains { !$0.isWhitespace }
    }

    /// Send while idle; while a turn runs, send queues the message and Stop sits beside it.
    private func updateSendState() {
        let send = footer.sendButton
        guard let threadID, let thread else {
            send.mode = .send
            send.isEnabled = false
            footer.stopButton.isHidden = true
            footer.implementButton.isHidden = true
            send.isHidden = false
            return
        }
        let running = runner.isRunning(threadID)
        let canSend =
            hasContent && importingImages == 0 && isUsable(thread.selection.provider)
            && !WorktreeService.shared.isPreparing(threadID)
        footer.stopButton.isHidden = !running
        footer.implementButton.isHidden = !(proposedPlan != nil && !hasContent && !running)
        send.isHidden = !footer.implementButton.isHidden
        send.isEnabled = canSend
        if running {
            send.mode = .queue
            send.toolTip = String(localized: "Queue message. It is sent when the current turn finishes.")
            send.setAccessibilityLabel(String(localized: "Queue message"))
        } else {
            send.mode = .send
            send.toolTip =
                store.settings.sendOnReturn ? String(localized: "Send (↩)") : String(localized: "Send (⌘↩)")
            send.setAccessibilityLabel(String(localized: "Send message"))
        }
    }

    // MARK: Text

    func textDidChange(_ notification: Notification) {
        textChanged()
    }

    private func textChanged() {
        if let history, history.text != textView.string { self.history = nil }
        updateTextHeight()
        updateSendState()
        updateTrigger()
        scheduleDraftSave()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateTrigger()
    }

    func textDidEndEditing(_ notification: Notification) {
        suggestions.hide()
    }

    func undoManager(for view: NSTextView) -> UndoManager? { editUndoManager }

    private func updateTextHeight() {
        guard let textHeight else { return }
        let windowHeight = view.window?.contentLayoutRect.height ?? 800
        let maxHeight = max(60, (windowHeight * 0.4).rounded())
        let height = min(textView.contentHeight(upTo: maxHeight + 1, minimumLines: 2), maxHeight)
        if textHeight.constant != height { textHeight.constant = height }
        scrollView.verticalScrollElasticity = height >= maxHeight ? .automatic : .none
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            return handleReturn()
        case #selector(NSResponder.insertLineBreak(_:)):
            // Control-Return would insert U+2028, which agents read as an odd character; use a plain newline.
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        case #selector(NSResponder.insertTab(_:)):
            guard suggestions.isVisible, let item = suggestions.selectedItem else { return false }
            choose(item)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            toggleInteractionMode()
            return true
        case #selector(NSResponder.moveUp(_:)):
            if suggestions.isVisible {
                suggestions.moveSelection(by: -1)
                return true
            }
            return recallHistory(backward: true)
        case #selector(NSResponder.moveDown(_:)):
            if suggestions.isVisible {
                suggestions.moveSelection(by: 1)
                return true
            }
            return recallHistory(backward: false)
        case #selector(NSResponder.cancelOperation(_:)):
            if suggestions.isVisible || trigger != nil {
                dismissedTrigger = trigger
                trigger = nil
                suggestions.hide()
            } else {
                // Skip NSTextView's word completion; let the window handle Escape.
                view.nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil)
            }
            return true
        default:
            return false
        }
    }

    private func handleReturn() -> Bool {
        let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        if suggestions.isVisible, let item = suggestions.selectedItem, flags.isDisjoint(with: [.shift, .option]) {
            choose(item)
            return true
        }
        if flags.contains(.command) || (store.settings.sendOnReturn && flags.isDisjoint(with: [.shift, .option, .control])) {
            primaryAction()
            return true
        }
        return false
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36, 76:  // Return, Enter
            guard flags.contains(.command), !textView.hasMarkedText() else { return false }
            primaryAction()
            return true
        case 47:  // .
            guard flags == .command, let threadID, runner.isRunning(threadID) else { return false }
            runner.stop(threadID: threadID)
            return true
        case 126:  // Up
            guard flags == .option else { return false }
            return editLatestQueued()
        default:
            return false
        }
    }

    /// ⇧⌘M, ⇧⌘E and ⇧⌘A open the model, effort and access menus while focus is not in another editor.
    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard threadID != nil, let window = view.window, window.isKeyWindow,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift]
        else { return false }
        if let editor = window.firstResponder as? NSTextView, editor !== textView, editor.isEditable { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "m": footer.modelButton.showMenu()
        case "e" where !footer.effortButton.isHidden: footer.effortButton.showMenu()
        case "a": footer.accessButton.showMenu()
        default: return false
        }
        return true
    }

    /// Up in an empty composer recalls earlier messages of the thread; Down walks back toward the draft.
    private func recallHistory(backward: Bool) -> Bool {
        guard attachments.isEmpty, history != nil || textView.string.isEmpty,
            textView.caretIsOnEdgeLine(top: backward), let thread
        else { return false }
        var prompts: [String] = []
        for item in thread.items where item.kind == .user && !item.text.isEmpty && prompts.last != item.text {
            prompts.append(item.text)
        }
        guard !prompts.isEmpty else { return false }
        let index: Int
        if let history {
            index = history.index + (backward ? -1 : 1)
        } else if backward {
            index = prompts.count - 1
        } else {
            return false
        }
        guard index >= 0 else { return true }
        let text = index < prompts.count ? prompts[index] : ""
        history = index < prompts.count ? (index, text) : nil
        textView.setText(text)
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        textChanged()
        return true
    }

    // MARK: Drafts

    private func scheduleDraftSave() {
        draftSave?.cancel()
        guard let threadID else { return }
        draftSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveDraft(to: threadID)
        }
    }

    private func saveDraft(to id: UUID) {
        draftSave?.cancel()
        draftSave = nil
        let text = textView.string
        let draft = text.contains { !$0.isWhitespace } ? text : nil
        guard let thread = store.thread(id), thread.draft != draft else { return }
        store.updateThread(id) { $0.draft = draft }
    }

    // MARK: Suggestions

    private func updateTrigger() {
        let selection = textView.selectedRange()
        var detected: ComposerTrigger?
        if threadID != nil, selection.length == 0, !textView.hasMarkedText(), view.window?.firstResponder === textView {
            detected = ComposerTrigger.detect(in: textView.string, cursor: selection.location)
        }
        if let candidate = detected, let dismissed = dismissedTrigger, candidate.kind == dismissed.kind,
            candidate.range.location == dismissed.range.location
        {
            detected = nil
        } else {
            dismissedTrigger = nil
        }
        guard detected != trigger else { return }
        trigger = detected
        loadSuggestions()
    }

    private func loadSuggestions() {
        suggestionSearch?.cancel()
        guard let trigger else {
            suggestions.hide()
            return
        }
        switch trigger.kind {
        case .command:
            let commands = ComposerCommand.matching(trigger.query, in: availableCommands)
            if commands.isEmpty {
                suggestions.hide()
            } else {
                suggestions.show(
                    commands.map { .command($0) }, emptyText: nil, listLabel: String(localized: "Commands"), above: surface)
            }
        case .path:
            guard let root = threadID.flatMap({ store.workingDirectory(for: $0) }) else {
                suggestions.hide()
                return
            }
            let label = String(localized: "Files and folders")
            if !suggestions.isVisible {
                suggestions.show([], emptyText: String(localized: "Searching files…"), listLabel: label, above: surface)
            }
            let query = trigger.query
            suggestionSearch = Task { [weak self] in
                let entries = await ComposerFileIndex.shared.search(query, in: root)
                guard let self, !Task.isCancelled, self.trigger?.kind == .path, self.trigger?.query == query else { return }
                suggestions.show(
                    entries.map { .file($0) }, emptyText: String(localized: "No matching files or folders."),
                    listLabel: label, above: surface)
            }
        }
    }

    private func choose(_ suggestion: ComposerSuggestion) {
        guard let trigger else { return }
        switch suggestion {
        case .file(let entry):
            // Folders keep the list open on their contents, so the user can keep narrowing down.
            if entry.isDirectory, !entry.path.contains(where: \.isWhitespace) {
                replace(trigger.range, with: "@" + entry.path + "/")
            } else {
                replace(trigger.range, with: ComposerTrigger.mention(entry.path) + " ")
            }
        case .command(let command):
            replace(trigger.range, with: "")
            self.trigger = nil
            suggestions.hide()
            perform(command)
        }
    }

    /// Replaces a word in the text as an undoable edit. A replacement ending in a space swallows
    /// one space already after the word, so completing in the middle of a line leaves no double space.
    private func replace(_ range: NSRange, with replacement: String) {
        var range = range
        let text = textView.string as NSString
        if replacement.hasSuffix(" "), NSMaxRange(range) < text.length, text.character(at: NSMaxRange(range)) == 0x20 {
            range.length += 1
        }
        textView.insertText(replacement, replacementRange: range)
    }

    /// The built-in commands plus one for each other agent that is ready, such as `/codex`.
    private var availableCommands: [ComposerCommand] {
        ComposerCommand.available(agents: registry.readyKinds.filter { $0 != thread?.selection.provider })
    }

    private func perform(_ command: ComposerCommand) {
        switch command {
        case .model:
            DispatchQueue.main.async { [weak self] in self?.footer.modelButton.showMenu() }
        case .plan:
            setInteractionMode(.plan)
        case .build:
            setInteractionMode(.build)
        case .agent(let provider):
            switchAgent(to: provider)
        }
    }

    /// Continues the thread with `provider`, on the model it last used here or else its first model.
    private func switchAgent(to provider: ProviderKind) {
        guard let thread else { return }
        let models = registry.models(for: provider)
        let lastUsed = thread.items.last { $0.provider == provider && $0.modelID != nil }?.modelID
        let modelID =
            lastUsed.flatMap { id in models.contains { $0.modelID == id } ? id : nil } ?? models.first?.modelID
            ?? "default"
        select(ModelSelection(provider: provider, modelID: modelID))
    }

    // MARK: Menus and modes

    private func modelMenu() -> NSMenu? {
        guard let thread else { return nil }
        return ComposerMenus.modelMenu(
            current: thread.selection, registry: registry, target: self, choose: #selector(chooseModel(_:)),
            refresh: #selector(refreshProviders), settings: #selector(openProviderSettings))
    }

    private func effortMenu() -> NSMenu? {
        guard let thread, let model = registry.model(for: thread.selection), !model.efforts.isEmpty else { return nil }
        return ComposerMenus.effortMenu(
            model: model, current: thread.selection.effort, target: self, action: #selector(chooseEffort(_:)))
    }

    private func accessMenu() -> NSMenu? {
        guard let thread else { return nil }
        return ComposerMenus.accessMenu(current: thread.accessMode, target: self, action: #selector(chooseAccess(_:)))
    }

    @objc private func chooseModel(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? ModelSelection else { return }
        select(selection)
    }

    /// Picking a model from another provider switches the thread's agent; that agent's native session
    /// continues and it gets a recap of the turns it missed (see `Handoff`). The effort carries over
    /// when the new model supports it.
    private func select(_ selection: ModelSelection) {
        guard let threadID, let thread else { return }
        var selection = selection
        let model = registry.model(for: selection)
        if let effort = thread.selection.effort, model?.efforts.contains(effort) == true {
            selection.effort = effort
        } else {
            selection.effort = model?.defaultEffort
        }
        let switched = selection.provider != thread.selection.provider
        store.updateThread(threadID) { $0.selection = selection }
        if switched {
            footer.modelButton.flash(Theme.color(for: selection.provider))
            NSAccessibility.post(
                element: textView, notification: .announcementRequested,
                userInfo: [
                    .announcement: String(localized: "Switched to \(selection.provider.displayName)"),
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
            if !handoffBanner.isHidden {
                handoffBanner.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    handoffBanner.animator().alphaValue = 1
                }
            }
        }
        focus()
    }

    @objc private func chooseEffort(_ sender: NSMenuItem) {
        guard let threadID, let effort = sender.representedObject as? String else { return }
        store.updateThread(threadID) { $0.selection.effort = effort }
    }

    @objc private func chooseAccess(_ sender: NSMenuItem) {
        guard let threadID, let mode = sender.representedObject as? AccessMode else { return }
        store.updateThread(threadID) { $0.accessMode = mode }
    }

    @objc private func toggleInteractionMode() {
        guard let thread else { return }
        setInteractionMode(thread.interactionMode == .plan ? .build : .plan)
    }

    private func setInteractionMode(_ mode: InteractionMode) {
        guard let threadID, thread?.interactionMode != mode else { return }
        store.updateThread(threadID) { $0.interactionMode = mode }
    }

    @objc private func refreshProviders() {
        Task { await registry.refresh() }
    }

    @objc private func openProviderSettings() {
        AppEvents.post(.coincideShowSettings, ["section": SettingsSection.providers.rawValue])
    }

    // MARK: Sending

    /// Sends (queued while a turn runs), runs a typed command, or implements a proposed plan when empty.
    @objc private func primaryAction() {
        guard let threadID else { return }
        let text = textView.string
        if attachments.isEmpty, let command = ComposerCommand.standalone(text, in: availableCommands) {
            clearComposer()
            perform(command)
            return
        }
        guard hasContent else {
            if proposedPlan != nil, !runner.isRunning(threadID) { implementPlan() }
            return
        }
        // A message sent while the thread's worktree is still being created would run in the project folder.
        guard importingImages == 0, let thread, isUsable(thread.selection.provider),
            !WorktreeService.shared.isPreparing(thread.id)
        else {
            NSSound.beep()
            return
        }
        declinePendingRequests(threadID)
        let imagePaths = attachments.map(\.path)
        clearComposer()
        Task { await runner.send(threadID: threadID, text: text, imagePaths: imagePaths) }
    }

    /// As in T3 Code, a message sent while the agent waits on an approval or a question declines it,
    /// so the agent moves on and the message redirects it.
    private func declinePendingRequests(_ threadID: UUID) {
        for item in runner.pendingApprovals(threadID) {
            let options = item.approval?.options ?? []
            guard let decline = options.first(where: { $0.kind == .deny }) ?? options.first(where: { $0.kind == .cancel })
            else { continue }
            runner.respond(threadID: threadID, itemID: item.id, optionID: decline.id)
        }
        for item in runner.pendingQuestions(threadID) {
            runner.dismissQuestion(threadID: threadID, itemID: item.id)
        }
    }

    @objc private func stop() {
        guard let threadID else { return }
        runner.stop(threadID: threadID)
    }

    @objc private func implementPlan() {
        guard let threadID else { return }
        setInteractionMode(.build)
        Task { await runner.send(threadID: threadID, text: String(localized: "Implement the plan."), imagePaths: []) }
    }

    private func clearComposer() {
        draftSave?.cancel()
        textView.setText("")
        editUndoManager.removeAllActions()
        attachments = []
        history = nil
        trigger = nil
        suggestions.hide()
        if let threadID, thread?.draft != nil { store.updateThread(threadID) { $0.draft = nil } }
        refreshAttachments()
        updateTextHeight()
    }

    /// Takes a queued message back into the composer for editing.
    private func editQueued(_ id: UUID) {
        guard let threadID, let message = runner.removeQueued(threadID: threadID, id: id) else { return }
        let current = textView.string
        let text = current.contains { !$0.isWhitespace } ? current + "\n\n" + message.text : message.text
        textView.setText(text)
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        attachments += message.imagePaths.map { ComposerAttachment(path: $0, name: ($0 as NSString).lastPathComponent) }
        refreshAttachments()
        textChanged()
        focus()
    }

    private func editLatestQueued() -> Bool {
        guard let threadID, let latest = runner.queuedMessages(threadID).last else { return false }
        editQueued(latest.id)
        return true
    }

    // MARK: Attachments

    @objc private func chooseImages() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Attach")
        panel.message = String(localized: "Choose images to send with your message.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.addImages(panel.urls.map { .file($0) })
        }
    }

    private func addImages(_ sources: [ComposerImageSource]) {
        guard let target = threadID, !sources.isEmpty else { return }
        let directory = store.directory.appendingPathComponent("attachments", isDirectory: true)
        importingImages += 1
        updateSendState()
        Task { [weak self] in
            for source in sources {
                let imported = await ComposerAttachmentImporter.importImage(source, into: directory)
                guard let self else { return }
                guard let imported else {
                    NSSound.beep()
                    continue
                }
                let attachment = ComposerAttachment(path: imported.path, name: imported.name)
                if threadID == target {
                    attachments.append(attachment)
                    refreshAttachments()
                } else {
                    parkedAttachments[target, default: []].append(attachment)
                }
            }
            self?.importingImages -= 1
            self?.updateSendState()
        }
    }

    private func removeAttachment(_ attachment: ComposerAttachment) {
        attachments.removeAll { $0.id == attachment.id }
        try? FileManager.default.removeItem(at: attachment.url)
        refreshAttachments()
    }

    /// Mentions dropped or pasted files by path, relative to the working directory when inside it.
    private func mention(_ urls: [URL]) {
        let root = threadID.flatMap { store.workingDirectory(for: $0) }?.standardizedFileURL.path
        let paths = urls.map { url -> String in
            let path = url.standardizedFileURL.path
            if let root, path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
            return path
        }
        textView.insertText(
            paths.map(ComposerTrigger.mention).joined(separator: " ") + " ", replacementRange: textView.selectedRange())
        focus()
    }

    private func setDropHighlight(_ highlighted: Bool) {
        surface.tintColor = highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.12) : nil
    }

    private func preview(_ attachment: ComposerAttachment) {
        previewURLs = attachments.map(\.url)
        previewIndex = attachments.firstIndex(of: attachment) ?? 0
        focus()
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.reloadData()
            panel.currentPreviewItemIndex = previewIndex
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: Quick Look

extension ComposerViewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    // Quick Look calls these on the main thread through the responder chain.
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { !previewURLs.isEmpty }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
            panel.currentPreviewItemIndex = previewIndex
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
            previewURLs = []
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURLs[index] as NSURL
    }
}

/// The composer's root: transparent to clicks outside its controls, so a transcript beneath stays usable,
/// and where the composer's window-wide shortcuts arrive.
private final class ComposerRootView: NSView {
    var passThroughViews: [NSView] = []
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard let hit, hit !== self, !passThroughViews.contains(where: { $0 === hit }) else { return nil }
        return hit
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKeyEquivalent?(event) == true || super.performKeyEquivalent(with: event)
    }
}

/// The composer surface's content. Takes files and images dropped anywhere on it, not only on the text.
private final class ComposerDropStack: NSStackView {
    var onDrop: ((NSPasteboard) -> Bool)?
    var onDragHover: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL] + ComposerAttachmentImporter.pasteboardTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragHover?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragHover?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragHover?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop?(sender.draggingPasteboard) ?? false
    }
}
