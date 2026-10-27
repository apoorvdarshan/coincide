import AppKit
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
        thumbnail.contentsGravity = .resizeAspectFill
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
        thumbnail.frame = bounds
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
            self?.thumbnail.contents = representation?.cgImage
        }
    }

    @objc private func open() { onOpen?() }
    @objc private func remove() { onRemove?() }
}

/// The row of attachment thumbnails above the text, scrolling sideways when it overflows.
final class ComposerAttachmentStrip: NSStackView {
    var onRemove: ((ComposerAttachment) -> Void)?
    var onOpen: ((ComposerAttachment) -> Void)?

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

    /// Shows `attachments`, reusing the chips already on screen.
    func show(_ attachments: [ComposerAttachment], warning text: String?) {
        let existing = Dictionary(
            uniqueKeysWithValues: chips.arrangedSubviews.compactMap { $0 as? ComposerAttachmentChip }.map {
                ($0.attachment.id, $0)
            })
        for view in chips.arrangedSubviews where !attachments.contains(where: { $0.id == (view as? ComposerAttachmentChip)?.attachment.id }) {
            chips.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, attachment) in attachments.enumerated() {
            let chip = existing[attachment.id] ?? makeChip(attachment)
            guard let current = chips.arrangedSubviews.firstIndex(of: chip) else {
                chips.insertArrangedSubview(chip, at: index)
                continue
            }
            if current != index {
                chips.removeArrangedSubview(chip)
                chips.insertArrangedSubview(chip, at: index)
            }
        }
        warning.stringValue = text ?? ""
        warning.isHidden = text == nil
        isHidden = attachments.isEmpty
    }

    private func makeChip(_ attachment: ComposerAttachment) -> ComposerAttachmentChip {
        let chip = ComposerAttachmentChip(attachment: attachment)
        chip.onRemove = { [weak self] in self?.onRemove?(attachment) }
        chip.onOpen = { [weak self] in self?.onOpen?(attachment) }
        return chip
    }
}

/// Lays out scrolled content from the top-left.
private final class TopAlignedView: NSView {
    override var isFlipped: Bool { true }
}
