import AppKit
import CoincideKit
import UniformTypeIdentifiers

/// A native, read-only browser until the user presses Import. All scanning/parsing happens off the main actor.
final class CLISessionImportController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onImport: ((UUID) -> Void)?
    private let store: AppStore
    private let roots: [ProviderKind: [URL]]
    private let search = NSSearchField()
    private let table = NSTableView()
    private let transcript = NSTextView()
    private let details = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let importButton = NSButton(title: String(localized: "Import"), target: nil, action: nil)
    private let refreshButton = NSButton(title: String(localized: "Refresh"), target: nil, action: nil)
    private var candidates: [CLISessionCandidate] = []
    private var filtered: [CLISessionCandidate] = []
    private(set) var preview: CLISessionPreview?
    private var scanTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var generation = UUID()
    private var started = false

    init(store: AppStore = .shared, roots: [ProviderKind: [URL]] = CLISessionScanner.defaultRoots()) {
        self.store = store
        self.roots = roots
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit { scanTask?.cancel(); previewTask?.cancel() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let heading = NSTextField(labelWithString: String(localized: "Import CLI Session"))
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString: String(localized:
            "Preview a Claude Code or Codex conversation before importing. The original file stays unchanged; Coincide keeps a private copy and starts imported threads in approval mode."))
        explanation.textColor = .secondaryLabelColor
        search.placeholderString = String(localized: "Search sessions")
        search.delegate = self
        search.setAccessibilityLabel(String(localized: "Search sessions"))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.rowHeight = 52
        table.usesAlternatingRowBackgroundColors = true
        table.delegate = self
        table.dataSource = self
        table.setAccessibilityLabel(String(localized: "CLI sessions"))
        let list = NSScrollView()
        list.hasVerticalScroller = true
        list.documentView = table
        list.borderType = .bezelBorder
        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.isRichText = false
        transcript.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        transcript.textContainerInset = NSSize(width: 10, height: 10)
        transcript.autoresizingMask = [.width]
        transcript.isVerticallyResizable = true
        transcript.textContainer?.widthTracksTextView = true
        transcript.setAccessibilityLabel(String(localized: "Session preview"))
        let reading = NSScrollView()
        reading.hasVerticalScroller = true
        reading.documentView = transcript
        reading.borderType = .bezelBorder
        details.font = .systemFont(ofSize: 12)
        details.textColor = .secondaryLabelColor
        details.maximumNumberOfLines = 4
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        status.maximumNumberOfLines = 3
        let choose = NSButton(title: String(localized: "Choose File…"), target: self, action: #selector(chooseFile))
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(close))
        cancel.keyEquivalent = "\u{1b}"
        importButton.target = self
        importButton.action = #selector(importSelected)
        importButton.keyEquivalent = "\r"
        importButton.isEnabled = false
        let buttons = NSStackView(views: [choose, refreshButton, NSView(), cancel, importButton])
        buttons.spacing = 8
        let body = NSStackView(views: [list, reading])
        body.spacing = 12
        body.distribution = .fill
        let stack = NSStackView(views: [heading, explanation, search, body, details, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            list.widthAnchor.constraint(equalToConstant: 290),
            list.heightAnchor.constraint(equalTo: body.heightAnchor),
            reading.heightAnchor.constraint(equalTo: body.heightAnchor),
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ] + [explanation, search, body, details, status, buttons].map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if !started { started = true; refresh() }
    }

    @objc private func refresh() {
        scanTask?.cancel()
        resetPreview()
        status.stringValue = String(localized: "Scanning local sessions…")
        refreshButton.isEnabled = false
        let roots = roots
        scanTask = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) { try CLISessionScanner.scan(roots: roots) }
            do {
                let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard let self, !Task.isCancelled else { return }
                candidates = result.candidates
                filter()
                status.stringValue = result.incomplete
                    ? String(localized: "Some sessions could not be listed. Use Choose File to open a specific JSONL file.")
                    : String(localized: "Select a session to preview it.")
                refreshButton.isEnabled = true
            } catch {
                guard let self, !Task.isCancelled else { return }
                status.stringValue = error.localizedDescription
                refreshButton.isEnabled = true
            }
        }
    }

    func controlTextDidChange(_ obj: Notification) { filter() }
    private func filter() {
        resetPreview()
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = candidates.filter { query.isEmpty || "\($0.title) \($0.directory) \($0.provider.displayName)".localizedCaseInsensitiveContains(query) }
        table.deselectAll(nil)
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let candidate = filtered[row]
        let title = NSTextField(labelWithString: candidate.title)
        title.lineBreakMode = .byTruncatingTail
        let subtitle = NSTextField(labelWithString: "\(candidate.provider.displayName) · \(candidate.directory)")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.toolTip = candidate.url.path
        stack.clipsToBounds = true
        NSLayoutConstraint.activate([
            title.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12),
        ])
        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard filtered.indices.contains(table.selectedRow) else { return }
        select(filtered[table.selectedRow].url)
    }

    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.select(url) }
        }
    }

    func select(_ url: URL) {
        resetPreview()
        let request = generation
        status.stringValue = String(localized: "Loading preview…")
        previewTask = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) { try CLISessionImport.preview(url) }
            do {
                let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard let self, generation == request, !Task.isCancelled else { return }
                show(value)
            } catch {
                guard let self, generation == request, !Task.isCancelled else { return }
                status.stringValue = error.localizedDescription
            }
        }
    }

    func show(_ value: CLISessionPreview) {
        preview = value
        details.stringValue = "\(value.provider.displayName) · \(value.modelID) · \(value.sessionID)\n\(value.directory.path)\n\(value.createdAt.formatted()) – \(value.updatedAt.formatted())"
        var body = ""
        for item in value.items {
            let label = item.kind == .user ? String(localized: "You") : item.title ?? value.provider.displayName
            body += "\(label)\n\(item.detail ?? "")\(item.detail == nil ? "" : "\n")\(item.text)\n\n"
            if body.count > 200_000 { body = String(body.prefix(200_000)); break }
        }
        transcript.string = body
        transcript.scrollToBeginningOfDocument(nil)
        status.stringValue = String(localized: "The preview shows up to 200,000 characters. Unsupported records and longer text remain in the saved original source.")
        if value.omittedRecords > 0 || value.shortenedText {
            status.stringValue += " " + String(localized: "This session includes content that is preserved only in the original source.")
        }
        importButton.title = store.threadForSession(provider: value.provider, sessionID: value.sessionID) == nil
            ? String(localized: "Import") : String(localized: "Open Existing Thread")
        importButton.isEnabled = true
    }

    private func resetPreview() {
        previewTask?.cancel()
        generation = UUID()
        preview = nil
        transcript.string = ""
        details.stringValue = ""
        importButton.isEnabled = false
        importButton.title = String(localized: "Import")
    }

    @objc private func importSelected() {
        guard let preview else { return }
        if let id = store.threadForSession(provider: preview.provider, sessionID: preview.sessionID) {
            finish(id)
            return
        }
        importButton.isEnabled = false
        let request = generation
        previewTask = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) { try CLISessionImport.read(preview.sourceURL) == preview.sourceData }
            do {
                let unchanged = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard let self, generation == request, !Task.isCancelled else { return }
                guard unchanged else { throw CLISessionImportError.changed }
                finish(try store.importSession(preview))
            } catch {
                guard let self, generation == request, !Task.isCancelled else { return }
                status.stringValue = error.localizedDescription
                importButton.isEnabled = !(error is CLISessionImportError)
            }
        }
    }

    private func finish(_ id: UUID) { onImport?(id); close() }
    @objc private func close() { scanTask?.cancel(); resetPreview(); dismiss(nil) }
}
