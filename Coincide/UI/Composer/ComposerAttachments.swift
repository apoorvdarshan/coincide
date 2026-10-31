import AppKit
import CoincideKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// An image waiting to be sent, already copied into the attachments folder.
struct ComposerAttachment: Hashable {
    var id = UUID()
    var path: String
    var name: String

    var url: URL { URL(fileURLWithPath: path) }
}

/// An image pasted or dropped into the composer, before it is copied.
nonisolated enum ComposerImageSource: Sendable {
    case file(URL)
    case data(Data)
}

/// Copies images into the attachments folder in a form every provider accepts: PNG, JPEG, GIF or WebP,
/// at most 2000 pixels on the long edge.
nonisolated enum ComposerAttachmentImporter {
    static let maxEdge = 2000
    static let maxBytes = 10 * 1024 * 1024
    private static let passthroughTypes: [UTType] = [.png, .jpeg, .gif, .webP]

    /// Image types the composer accepts from the pasteboard, in order of preference.
    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier), NSPasteboard.PasteboardType(UTType.gif.identifier),
        NSPasteboard.PasteboardType(UTType.webP.identifier),
    ]

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    @concurrent
    static func importImage(_ source: ComposerImageSource, into directory: URL) async -> (path: String, name: String)? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let imageSource: CGImageSource?
        let name: String
        switch source {
        case .file(let url):
            imageSource = CGImageSourceCreateWithURL(url as CFURL, nil)
            name = url.lastPathComponent
        case .data(let data):
            imageSource = CGImageSourceCreateWithData(data as CFData, nil)
            name = String(localized: "Pasted image")
        }
        guard let imageSource, CGImageSourceGetCount(imageSource) > 0,
            let typeIdentifier = CGImageSourceGetType(imageSource) as String?
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        let type = UTType(typeIdentifier)
        let byteCount: Int =
            switch source {
            case .file(let url): (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
            case .data(let data): data.count
            }
        let base = directory.appendingPathComponent(UUID().uuidString)

        if let type, passthroughTypes.contains(type), max(width, height) <= maxEdge, byteCount <= maxBytes {
            let destination = base.appendingPathExtension(type.preferredFilenameExtension ?? "png")
            do {
                switch source {
                case .file(let url): try FileManager.default.copyItem(at: url, to: destination)
                case .data(let data): try data.write(to: destination)
                }
                return (destination.path, name)
            } catch {
                return nil
            }
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxEdge, max(width, height, 1)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else { return nil }
        let outputType: UTType = hasAlpha ? .png : .jpeg
        let destination = base.appendingPathExtension(outputType.preferredFilenameExtension ?? "png")
        guard
            let writer = CGImageDestinationCreateWithURL(
                destination as CFURL, outputType.identifier as CFString, 1, nil)
        else { return nil }
        let writeOptions: [CFString: Any] = hasAlpha ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(writer, image, writeOptions as CFDictionary)
        return CGImageDestinationFinalize(writer) ? (destination.path, name) : nil
    }
}

/// A removable thumbnail of an attached image. Clicking it opens Quick Look.
final class ComposerAttachmentChip: NSView {
    static let side: CGFloat = 56

    let attachment: ComposerAttachment
    var onRemove: (() -> Void)?
    var onOpen: (() -> Void)?

    private let thumbnail = CALayer()
    private let openButton = NSButton()
    private let removeButton = NSButton()

    init(attachment: ComposerAttachment) {
        self.attachment = attachment
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        // The whole picture, letterboxed, the way it will be sent: a wide window's appshot isn't cut to its middle.
        thumbnail.contentsGravity = .resize
        thumbnail.masksToBounds = true
        layer?.addSublayer(thumbnail)

        openButton.isBordered = false
        openButton.title = ""
        openButton.target = self
        openButton.action = #selector(open)
        openButton.setAccessibilityLabel(String(localized: "Preview \(attachment.name)"))
        openButton.toolTip = attachment.name

        removeButton.isBordered = false
        removeButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill", accessibilityDescription: String(localized: "Remove \(attachment.name)"))
        removeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, NSColor.black.withAlphaComponent(0.55)]))
        removeButton.target = self
        removeButton.action = #selector(remove)
        removeButton.toolTip = String(localized: "Remove")

        for subview in [openButton, removeButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
            openButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            openButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            openButton.topAnchor.constraint(equalTo: topAnchor),
            openButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            removeButton.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
        ])
        loadThumbnail()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumbnail.frame = thumbnailFrame
        CATransaction.commit()
    }

    /// Where the thumbnail is drawn: the picture fitted inside the chip, keeping its shape.
    var thumbnailFrame: CGRect { Self.fittedFrame(for: thumbnailSize, in: bounds) }

    private var thumbnailSize: CGSize?

    /// `size` scaled to fit inside `bounds` and centred, keeping its aspect; all of `bounds` while it isn't known.
    static func fittedFrame(for size: CGSize?, in bounds: CGRect) -> CGRect {
        guard let size, size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height).integral
            .intersection(bounds)
    }

    /// Shows `image` as the thumbnail; tests call it with a picture of their own.
    func show(_ image: CGImage?) {
        thumbnailSize = image.map { CGSize(width: $0.width, height: $0.height) }
        thumbnail.contents = image
        needsLayout = true
    }

    override func updateLayer() {
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    private func loadThumbnail() {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: attachment.url, size: CGSize(width: Self.side * 2, height: Self.side * 2), scale: scale,
            representationTypes: .thumbnail)
        Task { [weak self] in
            let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            self?.show(representation?.cgImage)
        }
    }

    @objc private func open() { onOpen?() }
    @objc private func remove() { onRemove?() }
}

/// A removable card for context attached to the message: a quote, terminal output, a diff comment or a file. It
/// sits among the image thumbnails at their height; clicking it shows the whole of it (Quick Look for a file).
final class ComposerContextCard: NSView {
    private static let minWidth: CGFloat = 150
    private static let maxWidth: CGFloat = 240
    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    let context: MessageContext
    var onRemove: (() -> Void)?
    var onOpen: ((NSView) -> Void)?

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton()
    private let removeButton = NSButton()
    private var isHovered = false

    init(context: MessageContext) {
        self.context = context
        super.init(frame: NSRect(x: 0, y: 0, width: Self.minWidth, height: ComposerAttachmentChip.side))
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        icon.image = Theme.symbol(context.symbolName, size: 12, weight: .medium)
        icon.contentTintColor = Theme.accent
        titleLabel.stringValue = context.title
        titleLabel.font = Self.titleFont
        titleLabel.textColor = Theme.ink
        titleLabel.lineBreakMode = .byTruncatingMiddle
        previewLabel.stringValue = context.preview
        previewLabel.font = context.previewIsCode ? .monospacedSystemFont(ofSize: 10.5, weight: .regular) : .systemFont(ofSize: 11)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.lineBreakMode = .byTruncatingTail
        for label in [titleLabel, previewLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setAccessibilityElement(false)
        }

        // The whole card opens the details; the remove button sits above it.
        openButton.isBordered = false
        openButton.title = ""
        openButton.target = self
        openButton.action = #selector(open)
        openButton.setAccessibilityLabel(context.accessibilityDescription)
        openButton.toolTip = context.detailText.map { MessageContext.clamp($0, to: 600) } ?? context.filePath

        removeButton.isBordered = false
        removeButton.image = NSImage(
            systemSymbolName: "xmark", accessibilityDescription: String(localized: "Remove \(context.title)"))
        removeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        removeButton.contentTintColor = .secondaryLabelColor
        removeButton.target = self
        removeButton.action = #selector(remove)
        removeButton.toolTip = String(localized: "Remove")

        let text = NSStackView(views: [titleLabel, previewLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        for subview in [icon, text, openButton, removeButton] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        let titleWidth = (context.title as NSString).size(withAttributes: [.font: Self.titleFont]).width
        let width = min(Self.maxWidth, max(Self.minWidth, ceil(titleWidth) + 64))
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: ComposerAttachmentChip.side),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            icon.widthAnchor.constraint(equalToConstant: 14),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            text.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            openButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            openButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            openButton.topAnchor.constraint(equalTo: topAnchor),
            openButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            removeButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            removeButton.widthAnchor.constraint(equalToConstant: 16),
            removeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(context.accessibilityDescription)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (isHovered ? Theme.sidebarHover : Theme.raisedFill).cgColor
        layer?.borderColor = Theme.surfaceBorder.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    @objc private func open() { onOpen?(self) }
    @objc private func remove() { onRemove?() }
}

/// The row of attachment thumbnails and context cards above the text, scrolling sideways when it overflows.
final class ComposerAttachmentStrip: NSStackView {
    var onRemove: ((ComposerAttachment) -> Void)?
    var onOpen: ((ComposerAttachment) -> Void)?
    var onRemoveContext: ((MessageContext) -> Void)?
    var onOpenContext: ((MessageContext, NSView) -> Void)?

    private let scrollView = NSScrollView()
    private let chips = NSStackView()
    private let warning = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .vertical
        alignment = .leading
        spacing = 6

        chips.orientation = .horizontal
        chips.spacing = 8
        chips.translatesAutoresizingMaskIntoConstraints = false
        let document = TopAlignedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(chips)
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none

        warning.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        warning.textColor = .secondaryLabelColor
        warning.lineBreakMode = .byTruncatingTail
        warning.isHidden = true

        addArrangedSubview(scrollView)
        addArrangedSubview(warning)
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalTo: widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: ComposerAttachmentChip.side),
            chips.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            chips.topAnchor.constraint(equalTo: document.topAnchor),
            chips.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.trailingAnchor.constraint(equalTo: chips.trailingAnchor),
            document.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `attachments`, then the `context` cards, reusing the views already on screen.
    func show(_ attachments: [ComposerAttachment], context: [MessageContext] = [], warning text: String?) {
        var existing: [UUID: NSView] = [:]
        for view in chips.arrangedSubviews {
            if let chip = view as? ComposerAttachmentChip { existing[chip.attachment.id] = chip }
            if let card = view as? ComposerContextCard { existing[card.context.id] = card }
        }
        let wanted = attachments.map { attachment in existing[attachment.id] ?? makeChip(attachment) }
            + context.map { item in existing[item.id] ?? makeCard(item) }
        for view in chips.arrangedSubviews where !wanted.contains(view) {
            chips.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, view) in wanted.enumerated() {
            guard let current = chips.arrangedSubviews.firstIndex(of: view) else {
                chips.insertArrangedSubview(view, at: index)
                continue
            }
            if current != index {
                chips.removeArrangedSubview(view)
                chips.insertArrangedSubview(view, at: index)
            }
        }
        warning.stringValue = text ?? ""
        warning.isHidden = text == nil
        isHidden = attachments.isEmpty && context.isEmpty
    }

    /// Scrolls a newly added card into view.
    func reveal(_ context: MessageContext) {
        reveal { ($0 as? ComposerContextCard)?.context.id == context.id }
    }

    /// Scrolls a newly added image's thumbnail into view, such as an appshot added from another app.
    func reveal(_ attachment: ComposerAttachment) {
        reveal { ($0 as? ComposerAttachmentChip)?.attachment.path == attachment.path }
    }

    private func reveal(where matches: (NSView) -> Bool) {
        guard let view = chips.arrangedSubviews.first(where: matches) else { return }
        layoutSubtreeIfNeeded()
        view.scrollToVisible(view.bounds)
    }

    private func makeChip(_ attachment: ComposerAttachment) -> ComposerAttachmentChip {
        let chip = ComposerAttachmentChip(attachment: attachment)
        chip.onRemove = { [weak self] in self?.onRemove?(attachment) }
        chip.onOpen = { [weak self] in self?.onOpen?(attachment) }
        return chip
    }

    private func makeCard(_ context: MessageContext) -> ComposerContextCard {
        let card = ComposerContextCard(context: context)
        card.onRemove = { [weak self] in self?.onRemoveContext?(context) }
        card.onOpen = { [weak self] anchor in self?.onOpenContext?(context, anchor) }
        return card
    }
}

/// Lays out scrolled content from the top-left.
private final class TopAlignedView: NSView {
    override var isFlipped: Bool { true }
}
