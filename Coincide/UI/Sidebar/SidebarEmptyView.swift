import AppKit
import CoincideKit

/// "No Projects" and "No Results" placeholders. With no projects it also accepts dropped folders.
final class SidebarEmptyView: NSView {
    private let icon = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let messageField = NSTextField(wrappingLabelWithString: "")
    private let button = ThemedButton(title: String(localized: "Add Project…"), style: .primary, target: nil, action: nil)
    private var acceptsFolders = false
    private var isDropTarget = false {
        didSet { needsDisplay = true }
    }
    var onAddProject: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.contentTintColor = .tertiaryLabelColor
        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        titleField.textColor = .secondaryLabelColor
        titleField.alignment = .center
        messageField.font = .systemFont(ofSize: 12)
        messageField.textColor = .secondaryLabelColor
        messageField.alignment = .center
        messageField.preferredMaxLayoutWidth = 200
        button.bezelStyle = .push
        button.controlSize = .regular
        button.target = self
        button.action = #selector(addClicked)
        let stack = NSStackView(views: [icon, titleField, messageField, button])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(14, after: messageField)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func showNoProjects() {
        icon.image = Theme.symbol("folder.badge.plus", size: 30, weight: .light)
        titleField.stringValue = String(localized: "No Projects")
        messageField.stringValue = String(localized: "Add a folder to start a thread with your coding agents, or drop one here.")
        button.isHidden = false
        acceptsFolders = true
        setAccessibilityLabel(titleField.stringValue)
    }

    func showNoResults(for query: String) {
        icon.image = Theme.symbol("magnifyingglass", size: 26, weight: .light)
        titleField.stringValue = String(localized: "No Results")
        messageField.stringValue = String(localized: "No threads or projects match “\(query)”.")
        button.isHidden = true
        acceptsFolders = false
        setAccessibilityLabel(titleField.stringValue)
    }

    @objc private func addClicked() {
        onAddProject?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isDropTarget else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 8), xRadius: Theme.cornerRadius, yRadius: Theme.cornerRadius)
        Theme.sidebarHover.setFill()
        path.fill()
        Theme.ink.withAlphaComponent(0.5).setStroke()
        path.lineWidth = 1.5
        path.setLineDash([5, 4], count: 2, phase: 0)
        path.stroke()
    }

    // MARK: Folder drops

    static func folders(on pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsFolders, !Self.folders(on: sender.draggingPasteboard).isEmpty else { return [] }
        isDropTarget = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        let folders = Self.folders(on: sender.draggingPasteboard)
        guard acceptsFolders, !folders.isEmpty else { return false }
        ThreadActions.addProjects(folders)
        return true
    }
}
