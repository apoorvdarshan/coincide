import AppKit
import CoincideKit
import QuickLookUI

/// The message composer under the transcript, ported from T3 Code's ChatComposer: an auto-growing editor
/// with `@` file mentions, `/` commands, `$` skills, `#` pull requests and image attachments; the unified
/// agent and model picker, reasoning effort, access mode and Build/Plan controls; the usage and context
/// meters, send and stop; and banners for pending approvals and questions, plan follow-ups, agent switches,
/// usage limits and queued messages. Drafts persist per thread.
///
/// While a turn runs, send steers it (the agent takes the message in as it works) or queues the message for
/// after the turn, as the follow-up behavior setting says; the alternate send (⌘↩, or ⇧⌘↩ when ⌘↩ sends, or
/// ⌘-click) does the other, as in T3 Code. A message the agent can't take now is queued either way.
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
    private let usageBanner = ComposerUsageBanner()
    private let handoffBanner = ComposerHandoffBanner()
    private let planBanner = ComposerPlanBanner()
    private let questionBanner = ComposerQuestionBanner()
    private let approvalBanner = ComposerApprovalBanner()
    private let surface = FlatSurfaceView(style: .composer)
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
    /// Usage warnings the user dismissed; one comes back when its window resets or reaches its limit.
    private var dismissedUsageWarnings: Set<String> = []
    /// Keeps reset countdowns current while the usage meter shows.
    private var usageClock: Timer?
    /// Watches the modifier keys while the composer shows, so send can show what the alternate send does.
    private var flagsMonitor: Any?
    /// The alternate send's modifiers are held: send does the other of the follow-up behavior.
    private var alternateHeld = false

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
        buildTextView()
        buildSurface()
        buildColumn()
        wireActions()

        storeToken = store.observe { [weak self] change in self?.handle(change) }
        // Switching a thread to Ask for approval must reach its live sessions too, from wherever it is switched.
        AccessDowngrades.shared.start()
        NotificationCenter.default.addObserver(
            self, selector: #selector(focusRequested), name: .coincideFocusComposer, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(mentionPullRequest(_:)), name: .coincideMentionPullRequest, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationWillTerminate), name: NSApplication.willTerminateNotification, object: nil)
        // Folders are moved and deleted in other apps.
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(usageLimitsChanged), name: ThreadRunner.usageLimitsChangedNotification, object: runner)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyBindingsChanged), name: KeyBindingsController.didChangeNotification, object: nil)
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
        surface.cornerRadius = 22
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
        let banners: [NSView] = [handoffBanner, planBanner, usageBanner, queueBanner, questionBanner, approvalBanner]
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
        // The column prefers its full 820 points and gives way to the chat's width. Tying the preference to the chat's
        // width instead pulled the chat toward 868 points: the split view widened the thread list to its maximum to
        // get there, and zoom and resizing stopped at the thread list plus 868 points.
        let fullWidth = column.widthAnchor.constraint(equalToConstant: Theme.contentMaxWidth)
        fullWidth.priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 1)
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
        footer.modelButton.popupProvider = { [weak self] in self?.modelPicker() }
        for button in [footer.modelButton, footer.effortButton, footer.accessButton] { button.popupClearance = surface }
        footer.effortButton.menuProvider = { [weak self] in self?.effortMenu() }
        footer.accessButton.menuProvider = { [weak self] in self?.accessMenu() }
        footer.modeButton.target = self
        footer.modeButton.action = #selector(toggleInteractionMode)
        footer.attachButton.target = self
        footer.attachButton.action = #selector(chooseImages)
        footer.sendButton.target = self
        footer.sendButton.action = #selector(sendClicked)
        footer.stopButton.target = self
        footer.stopButton.action = #selector(stop)
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
        queueBanner.onSteer = { [weak self] id in self?.steerQueued(id) }
        usageBanner.onShowDetails = { [weak self] in self?.footer.usageMeter.showDetails() }
        usageBanner.onToggleResume = { [weak self] in self?.toggleResumeAtReset() }
        usageBanner.onDismiss = { [weak self] in
            guard let self, let thread, let warning = runner.usageLimits(for: thread.selection.provider)?.current(at: Date()).warning
            else { return }
            dismissedUsageWarnings.insert(UsageLimits.warningKey(for: warning, provider: thread.selection.provider))
            refreshUsageLimits()
            focus()
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
        if flagsMonitor == nil {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.modifiersChanged(event.modifierFlags)
                return event
            }
        }
        refreshUsageLimits()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        suggestions.hide()
        if let threadID { saveDraft(to: threadID) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        usageClock?.invalidate()
        usageClock = nil
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

    /// Inserts a PR link into the draft itself so its repository survives saving, queueing and agent handoff.
    @objc private func mentionPullRequest(_ notification: Notification) {
        guard threadID != nil, let pullRequest = notification.userInfo?["pullRequest"] as? PullRequestSummary else { return }
        guard let mention = PullRequestMention.markdown(pullRequest) else { return }
        let text = textView.string as NSString
        var range = textView.selectedRange()
        if range.location > text.length { range = NSRange(location: text.length, length: 0) }
        let before = range.location > 0 && !ComposerTrigger.isWhitespace(text.character(at: range.location - 1))
        textView.insertText((before ? " " : "") + mention + " ", replacementRange: range)
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

    @objc private func applicationDidBecomeActive() {
        refreshThread()
    }

    @objc private func usageLimitsChanged() {
        refreshUsageLimits()
    }

    /// Send shows what it will do: holding the alternate send's modifiers while a turn runs turns steer into queue,
    /// or queue into steer.
    private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let held = isAlternate(flags)
        guard held != alternateHeld else { return }
        alternateHeld = held
        if let threadID, runner.isRunning(threadID) { updateSendState() }
    }

    /// The modifiers of the alternate send: ⌘ when Return sends, else ⇧⌘.
    private func isAlternate(_ flags: NSEvent.ModifierFlags) -> Bool {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        return store.settings.sendOnReturn ? flags.contains(.command) : flags.isSuperset(of: [.command, .shift])
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
        case .projects:
            if threadID != nil { refreshThread() }
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
        refreshStopToolTip()
        updateTextHeight()
    }

    /// The footer's tooltips name the menu commands' shortcuts, which the user can change. Send's and the queue's
    /// leave out a send key a command was given.
    @objc private func keyBindingsChanged() {
        refreshStopToolTip()
        refreshControls(thread)
        refreshRunState()
    }

    /// The send keys that reach the composer, for tooltips.
    private var sendKeys: ComposerSendKeys {
        let keyBindings = KeyBindingsController.shared
        return ComposerSendKeys(sendOnReturn: store.settings.sendOnReturn, menuHas: { keyBindings.menuBarHas($0) })
    }

    /// What send does while a turn runs: the follow-up behavior setting, or steer while an approval is shown.
    private var followUpBehavior: FollowUpBehavior {
        ComposerDispatch.followUpBehavior(store.settings.followUpBehavior, approvalShown: hasPendingApproval)
    }

    private func refreshStopToolTip() {
        footer.stopButton.toolTip = KeyBindingsController.shared.toolTip(String(localized: "Stop"), for: .stopTurn)
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
        refreshUsageLimits()
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
        // A faster speed shows as a bolt on the control and is named with the model.
        let speedName = selection.speed.map { model?.speed($0)?.name ?? $0 }
        let modelDescription = speedName.map { String(localized: "\(modelName), \($0)") } ?? modelName
        if noneReady {
            footer.modelButton.configure(
                title: String(localized: "Set Up a Provider"), symbolName: "exclamationmark.circle", chevron: true)
        } else {
            footer.modelButton.configure(title: title, agent: provider, chevron: true)
        }
        footer.modelButton.accentSymbol = noneReady || speedName == nil ? nil : "bolt.fill"
        let keyBindings = KeyBindingsController.shared
        footer.modelButton.toolTip = keyBindings.toolTip(
            String(localized: "\(provider.displayName) · \(modelDescription). Choose the agent and model"), for: .chooseModel)
        footer.modelButton.setAccessibilityLabel(
            String(localized: "Agent and model: \(provider.displayName), \(modelDescription)"))

        if let model, !model.efforts.isEmpty {
            let effort = selection.effort ?? model.defaultEffort
            footer.effortButton.isHidden = false
            footer.effortButton.configure(
                title: effort.map(ComposerMenus.effortTitle) ?? String(localized: "Default"), symbolName: "brain",
                chevron: true)
            footer.effortButton.toolTip = keyBindings.toolTip(String(localized: "Reasoning effort"), for: .reasoningEffort)
            footer.effortButton.setAccessibilityLabel(
                String(localized: "Reasoning effort: \(effort.map(ComposerMenus.effortTitle) ?? String(localized: "Default"))"))
        } else {
            footer.effortButton.isHidden = true
        }

        footer.accessButton.configure(
            title: thread.accessMode.displayName, symbolName: ComposerMenus.symbolName(for: thread.accessMode),
            chevron: true)
        footer.accessButton.toolTip = keyBindings.toolTip(ComposerMenus.summary(for: thread.accessMode), for: .accessMode)
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
        if !queued.isEmpty { queueBanner.show(queued, canSteer: runner.canSteer(threadID), steerKey: sendKeys.steerQueued) }
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
        // A shown approval makes send steer.
        updateSendState()
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
        // The latest turn's plan or reply, past any message steered into it.
        for item in thread.items.reversed() {
            if item.opensUserTurn { break }
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

    /// "Resume at Reset" for a thread with a conversation that isn't running while the agent's limit stops work.
    private func resumeOffer(provider: ProviderKind, now: Date) -> ComposerUsageBanner.ResumeOffer? {
        guard let threadID, store.summary(threadID)?.hasUserMessages == true, !runner.isRunning(threadID) else { return nil }
        if let date = runner.scheduledResumes[threadID] { return .scheduled(date) }
        return runner.blockingLimitReset(for: provider, now: now) == nil ? nil : .available
    }

    private func toggleResumeAtReset() {
        guard let threadID, let provider = thread?.selection.provider else { return }
        if runner.scheduledResumes[threadID] != nil {
            runner.cancelResume(threadID)
        } else if let reset = runner.blockingLimitReset(for: provider) {
            runner.resumeAtReset(threadID, at: reset)
        }
        refreshUsageLimits()
    }

    /// The selected agent's subscription limits: the footer meter, and a banner once a window is nearly used up.
    private func refreshUsageLimits() {
        let now = Date()
        guard let thread, let reported = runner.usageLimits(for: thread.selection.provider), !reported.windows.isEmpty
        else {
            footer.usageMeter.isHidden = true
            usageBanner.isHidden = true
            usageClock?.invalidate()
            usageClock = nil
            return
        }
        let provider = thread.selection.provider
        let limits = reported.current(at: now)
        footer.usageMeter.update(provider: provider, limits: limits)
        footer.usageMeter.isHidden = false
        if let warning = limits.warning,
            !dismissedUsageWarnings.contains(UsageLimits.warningKey(for: warning, provider: provider))
        {
            usageBanner.show(warning, provider: provider, now: now, resume: resumeOffer(provider: provider, now: now))
            usageBanner.isHidden = false
        } else {
            usageBanner.isHidden = true
        }
        if usageClock == nil, view.window != nil {
            let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshUsageLimits() }
            }
            timer.tolerance = 10
            RunLoop.main.add(timer, forMode: .common)
            usageClock = timer
        }
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
        if let missing = missingFolder {
            return missing.isWorktree
                ? String(localized: "This thread’s worktree no longer exists.")
                : String(localized: "The project folder was moved or deleted. Locate it from the sidebar.")
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

    /// The folder the thread works in, when it was moved or deleted.
    private var missingFolder: (url: URL, isWorktree: Bool)? {
        guard let thread, let folder = store.workingDirectory(for: thread.id),
            !FileManager.default.fileExists(atPath: folder.path)
        else { return nil }
        return (folder, thread.worktreePath != nil)
    }

    private var hasContent: Bool {
        !attachments.isEmpty || textView.string.contains { !$0.isWhitespace }
    }

    /// Send while idle; while a turn runs, send steers or queues as the follow-up behavior says (the other while the
    /// alternate send's modifiers are held, and queue when the agent can't take the message now) and Stop sits
    /// beside it.
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
            && !WorktreeService.shared.isPreparing(threadID) && missingFolder == nil
        footer.stopButton.isHidden = !running
        footer.implementButton.isHidden = !(proposedPlan != nil && !hasContent && !running)
        send.isHidden = !footer.implementButton.isHidden
        send.isEnabled = canSend
        let canSteer = runner.canSteer(threadID)
        let behavior = followUpBehavior
        send.toolTip = sendKeys.sendToolTip(running: running, canSteer: canSteer, behavior: behavior)
        switch ComposerDispatch.resolve(running: running, canSteer: canSteer, alternate: alternateHeld, behavior: behavior) {
        case .steer:
            send.mode = .steer
            send.setAccessibilityLabel(String(localized: "Steer message"))
        case .queue:
            send.mode = .queue
            send.setAccessibilityLabel(String(localized: "Queue message"))
        case .send:
            send.mode = .send
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
            commandReturn(flags)
            return true
        }
        return false
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36, 76:  // Return, Enter
            guard flags.contains(.command), !textView.hasMarkedText() else { return false }
            commandReturn(flags)
            return true
        case 126:  // Up
            guard flags == .option else { return false }
            return editLatestQueued()
        default:
            return false
        }
    }

    /// A send from the keyboard. When Return sends, ⇧⌘↩ sends the next queued message into the running turn
    /// (T3 Code's steer-queued shortcut) if there is one.
    private func commandReturn(_ flags: NSEvent.ModifierFlags) {
        if store.settings.sendOnReturn, flags.isSuperset(of: [.command, .shift]), steerNextQueued() { return }
        primaryAction(alternate: isAlternate(flags))
    }

    /// The footer menus the Thread menu opens with ⇧⌘M, ⇧⌘E and ⇧⌘A.
    enum Picker {
        case model
        case effort
        case access
    }

    /// Whether the picker can open now: there is a thread, and the model takes an effort setting.
    func canShowPicker(_ picker: Picker) -> Bool {
        guard thread != nil, view.window != nil else { return false }
        return picker != .effort || !footer.effortButton.isHidden
    }

    func showPicker(_ picker: Picker) {
        guard canShowPicker(picker) else { return }
        let button =
            switch picker {
            case .model: footer.modelButton
            case .effort: footer.effortButton
            case .access: footer.accessButton
            }
        // Open after the menu bar finishes handling the shortcut.
        DispatchQueue.main.async { button.showMenu() }
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
            let commands = ComposerCommand.matching(trigger.query, in: availableCommands).map { ComposerSuggestion.command($0) }
            let items = commands + agentCommands(matching: trigger.query, token: "/")
            if items.isEmpty {
                suggestions.hide()
            } else {
                suggestions.show(items, emptyText: nil, listLabel: String(localized: "Commands"), above: surface)
            }
        case .skill:
            let items = agentCommands(matching: trigger.query, token: "$", skillsOnly: true)
            if items.isEmpty {
                suggestions.hide()
            } else {
                suggestions.show(items, emptyText: nil, listLabel: String(localized: "Skills"), above: surface)
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
        case .pullRequest:
            loadPullRequestSuggestions(trigger.query)
        }
    }

    /// The repository's open pull requests matching `query`: the last list at once, then a fresh one when it is
    /// older than a minute. Outside a GitHub repository, or without `gh`, `#` is just text and nothing shows.
    private func loadPullRequestSuggestions(_ query: String) {
        guard let cwd = threadID.flatMap({ store.workingDirectory(for: $0) }) else {
            suggestions.hide()
            return
        }
        let service = PullRequestService.shared
        let label = String(localized: "Pull requests")
        if let cached = service.cachedPullRequests(.open, in: cwd) { showPullRequests(cached, matching: query, label: label) }
        suggestionSearch = Task { [weak self] in
            let ready = await service.availability(cwd) == .ready
            guard let self, !Task.isCancelled, self.trigger?.kind == .pullRequest, self.trigger?.query == query else { return }
            guard ready else {
                suggestions.hide()
                return
            }
            if service.cachedPullRequests(.open, in: cwd) == nil, !suggestions.isVisible {
                suggestions.show([], emptyText: String(localized: "Loading pull requests…"), listLabel: label, above: surface)
            }
            let list = (try? await service.pullRequests(.open, in: cwd, maxAge: 60)) ?? []
            guard !Task.isCancelled, self.trigger?.kind == .pullRequest, self.trigger?.query == query else { return }
            showPullRequests(list, matching: query, label: label)
        }
    }

    /// Like `/` and `$`, the list closes when nothing matches, since `#` also starts headings and hashtags.
    private func showPullRequests(_ pullRequests: [PullRequestSummary], matching query: String, label: String) {
        let items = PullRequestMention.matching(query, in: pullRequests).map { ComposerSuggestion.pullRequest($0) }
        if items.isEmpty {
            suggestions.hide()
        } else {
            suggestions.show(items, emptyText: nil, listLabel: label, above: surface)
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
        case .agentCommand(let command, _, let token):
            replace(trigger.range, with: token + command.name + " ")
        case .pullRequest(let pullRequest):
            guard let mention = PullRequestMention.markdown(pullRequest) else { return }
            replace(trigger.range, with: mention + " ")
        }
    }

    /// The selected agent's own commands (or with `skillsOnly`, its skills) matching `query`, as completions written
    /// with `token`.
    private func agentCommands(matching query: String, token: String, skillsOnly: Bool = false) -> [ComposerSuggestion] {
        guard let threadID, let provider = thread?.selection.provider else { return [] }
        let offered = runner.commands(threadID, provider: provider).filter {
            skillsOnly ? $0.kind == .skill : $0.isSlashCommand
        }
        return ProviderCommand.matching(query, in: offered).prefix(200).map {
            .agentCommand($0, provider: provider, token: token)
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
        let provider = thread?.selection.provider
        let hasLimits = provider.flatMap { runner.usageLimits(for: $0) }.map { !$0.windows.isEmpty } ?? false
        return ComposerCommand.available(agents: registry.readyKinds.filter { $0 != provider }, usageLimits: hasLimits)
    }

    private func perform(_ command: ComposerCommand) {
        switch command {
        case .model:
            DispatchQueue.main.async { [weak self] in self?.footer.modelButton.showMenu() }
        case .plan:
            setInteractionMode(.plan)
        case .build:
            setInteractionMode(.build)
        case .usageLimits:
            DispatchQueue.main.async { [weak self] in self?.footer.usageMeter.showDetails() }
        case .agent(let provider):
            switchAgent(to: provider)
        }
    }

    /// Continues the thread with `provider`, on the model it last used here or else its first model.
    func switchAgent(to provider: ProviderKind) {
        guard let thread else { return }
        let models = registry.models(for: provider)
        let lastUsed = thread.items.last { $0.provider == provider && $0.modelID != nil }?.modelID
        let modelID =
            lastUsed.flatMap { id in models.contains { $0.modelID == id } ? id : nil } ?? models.first?.modelID
            ?? "default"
        select(ModelSelection(provider: provider, modelID: modelID))
    }

    // MARK: Menus and modes

    private func modelPicker() -> ModelPickerViewController? {
        guard let thread else { return nil }
        let picker = ModelPickerViewController(current: thread.selection, registry: registry, store: store)
        picker.onSelect = { [weak self] selection in self?.select(selection) }
        picker.onEffort = { [weak self] effort in self?.setEffort(effort) }
        picker.onSpeed = { [weak self] speed in self?.setSpeed(speed) }
        picker.onRefresh = { [weak self] in self?.refreshProviders() }
        picker.onSettings = { [weak self] in self?.openProviderSettings() }
        return picker
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

    /// Picking a model from another provider switches the thread's agent; that agent's native session
    /// continues and it gets a recap of the turns it missed (see `Handoff`). The effort and speed carry
    /// over when the new model supports them.
    func select(_ selection: ModelSelection) {
        guard let threadID, let thread else { return }
        var selection = selection
        let model = registry.model(for: selection)
        if let effort = thread.selection.effort, model?.efforts.contains(effort) == true {
            selection.effort = effort
        } else {
            selection.effort = model?.defaultEffort
        }
        selection.speed = model?.speed(thread.selection.speed)?.id
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
        guard let effort = sender.representedObject as? String else { return }
        setEffort(effort)
    }

    @objc private func chooseAccess(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? AccessMode else { return }
        setAccessMode(mode)
    }

    func setEffort(_ effort: String) {
        guard let threadID, thread?.selection.effort != effort else { return }
        store.updateThread(threadID) { $0.selection.effort = effort }
    }

    /// Runs the model at a faster speed it offers, or at standard speed for nil.
    func setSpeed(_ speed: String?) {
        guard let threadID, let thread, thread.selection.speed != speed else { return }
        guard speed == nil || registry.model(for: thread.selection)?.speed(speed) != nil else { return }
        store.updateThread(threadID) { $0.selection.speed = speed }
    }

    func setAccessMode(_ mode: AccessMode) {
        guard let threadID, thread?.accessMode != mode else { return }
        store.updateThread(threadID) { $0.accessMode = mode }
    }

    @objc func toggleInteractionMode() {
        guard let thread else { return }
        setInteractionMode(thread.interactionMode == .plan ? .build : .plan)
    }

    func setInteractionMode(_ mode: InteractionMode) {
        guard let threadID, thread?.interactionMode != mode else { return }
        store.updateThread(threadID) { $0.interactionMode = mode }
    }

    @objc private func refreshProviders() {
        Task { await registry.refresh() }
    }

    @objc private func openProviderSettings() {
        AppEvents.showSettings(section: .providers)
    }

    // MARK: Sending

    /// The send button; ⌘-click is the alternate send.
    @objc private func sendClicked() {
        primaryAction(alternate: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }

    /// Sends, runs a typed command, or implements a proposed plan when empty. While a turn runs the message
    /// steers it or is queued as the follow-up behavior says (`ComposerDispatch`); `alternate` does the other.
    private func primaryAction(alternate: Bool = false) {
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
            !WorktreeService.shared.isPreparing(thread.id), missingFolder == nil
        else {
            NSSound.beep()
            return
        }
        // Decided before the approvals are declined, since a shown approval makes it steer.
        let dispatch = ComposerDispatch.resolve(
            running: runner.isRunning(threadID), canSteer: runner.canSteer(threadID), alternate: alternate,
            behavior: followUpBehavior)
        declinePendingRequests(threadID)
        let imagePaths = attachments.map(\.path)
        clearComposer()
        switch dispatch {
        case .steer:
            Task {
                let delivery = await runner.steer(threadID: threadID, text: text, imagePaths: imagePaths)
                announce(delivery)
            }
        case .send, .queue:
            Task {
                // `send` queues the message while a turn runs.
                let queues = runner.isRunning(threadID)
                await runner.send(threadID: threadID, text: text, imagePaths: imagePaths)
                if queues { announce(.queued) }
            }
        }
    }

    /// Tells VoiceOver where a message typed while the agent worked went.
    private func announce(_ delivery: ThreadRunner.FollowUpDelivery?) {
        let message: String
        switch delivery {
        case .steered?: message = String(localized: "Sent into the current turn")
        case .queued?: message = String(localized: "Queued for after the current turn")
        case .sent?, nil: return
        }
        NSAccessibility.post(
            element: textView, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    /// Sends a queued message into the running turn now, or as a new turn when none runs.
    private func steerQueued(_ id: UUID) {
        guard let threadID else { return }
        Task {
            let delivery = await runner.steerQueued(threadID: threadID, id: id)
            announce(delivery)
        }
    }

    /// Sends the oldest queued message into the running turn. False when there is none or the turn can't take it.
    private func steerNextQueued() -> Bool {
        guard let threadID, runner.canSteer(threadID), let next = runner.queuedMessages(threadID).first else { return false }
        steerQueued(next.id)
        return true
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
        surface.tintColor = highlighted ? Theme.dropTint : nil
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

/// The composer's root: transparent to clicks outside its controls, so a transcript beneath stays usable.
private final class ComposerRootView: NSView {
    var passThroughViews: [NSView] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard let hit, hit !== self, !passThroughViews.contains(where: { $0 === hit }) else { return nil }
        return hit
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
