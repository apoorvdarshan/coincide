import AppKit

/// A rounded, solid surface: the composer, the banners over it, the find bar and the floating panels. Opaque fills
/// keep the window calm and readable where glass would pick up whatever scrolls underneath.
final class FlatSurfaceView: NSView {
    enum Style {
        /// The composer: lifted a step off the conversation.
        case composer
        /// Bars and banners that sit over the conversation.
        case raised
        /// Panels in their own windows, such as the command palette.
        case floating
        /// No fill or border, for notes that should read as plain text.
        case clear
    }

    var style: Style {
        didSet { needsDisplay = true }
    }

    var cornerRadius: CGFloat = 12 {
        didSet { needsDisplay = true }
    }

    /// A color laid over the fill, such as the highlight while files are dragged over the composer.
    var tintColor: NSColor? {
        didSet { needsDisplay = true }
    }

    /// The view filling the surface.
    var contentView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let contentView else { return }
            contentView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
                contentView.topAnchor.constraint(equalTo: topAnchor),
                contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }

    init(style: Style = .raised) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = cornerRadius
        let fill: NSColor =
            switch style {
            case .composer: Theme.composerFill
            case .raised: Theme.raisedFill
            case .floating: Theme.floatingFill
            case .clear: .clear
            }
        guard style != .clear else {
            layer.backgroundColor = nil
            layer.borderWidth = 0
            return
        }
        var color = fill
        if let tint = tintColor?.usingColorSpace(.sRGB), let base = fill.usingColorSpace(.sRGB) {
            color = base.blended(withFraction: tint.alphaComponent, of: tint.withAlphaComponent(1)) ?? fill
        }
        layer.backgroundColor = color.cgColor
        layer.borderWidth = Theme.borderWidth(for: effectiveAppearance)
        layer.borderColor = Theme.surfaceBorder.cgColor
    }
}

/// A view painted in one solid color that follows the appearance, for the sidebar and the conversation.
final class SolidBackgroundView: NSView {
    var color: NSColor {
        didSet { needsDisplay = true }
    }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = color.cgColor
    }
}
