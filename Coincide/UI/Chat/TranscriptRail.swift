import AppKit
import CoincideKit
import QuartzCore

/// The agent rail: a line down the transcript's left gutter in the color of the agent that did the work, so a thread
/// several agents worked on shows who did what at a glance. The agent's logo marks where it starts answering; a ring
/// marks each message of the user's while the messages sit on the rail (Settings › General › Your messages: Left), and
/// with them across on the right the line runs on through them. Where the next turn goes to another agent, the line
/// blends from one color to the other through the user's message.
struct TranscriptRail: Equatable {
    enum Node: Equatable {
        case none
        /// A message of the user's.
        case message
        /// Where an agent starts answering.
        case agent(ProviderKind)
        /// The agent is still working, at the end of the rail.
        case live(ProviderKind)
    }

    /// The agent whose color the line has at the row's top and bottom.
    var top: ProviderKind
    var bottom: ProviderKind
    var node: Node = .none
    /// Whether the line runs into the rows above and below.
    var continuesUp = true
    var continuesDown = true

    /// The rails of `rows`, by row. Spacers get none. `provider` says which agent an item belongs to; rows without
    /// one follow the row before them.
    static func rails(
        for rows: [TranscriptRow], provider: (UUID) -> ProviderKind?, runningProvider: ProviderKind?
    ) -> [TranscriptRowID: TranscriptRail] {
        let railed = rows.filter { if case .spacer = $0.kind { false } else { true } }
        var rails: [TranscriptRowID: TranscriptRail] = [:]
        var previous: ProviderKind?
        var awaitingAgent = true
        // Rows before the first that names an agent (a fork divider at the top) take that agent's color.
        var first: ProviderKind?
        for row in railed {
            first = Self.provider(of: row, provider: provider, runningProvider: runningProvider)
            if first != nil { break }
        }
        for (index, row) in railed.enumerated() {
            guard let agent = Self.provider(of: row, provider: provider, runningProvider: runningProvider) ?? previous ?? first
            else { continue }
            var rail = TranscriptRail(top: agent, bottom: agent)
            switch row.kind {
            case .user:
                // The line blends from the agent that answered last into the one this message goes to.
                rail.top = previous ?? agent
                rail.node = .message
                awaitingAgent = true
            case .live:
                rail.node = .live(agent)
                rail.continuesDown = false
            case .fork, .notice:
                break
            default:
                if awaitingAgent || (previous != nil && previous != agent) {
                    rail.node = .agent(agent)
                }
                awaitingAgent = false
            }
            if index == 0 { rail.continuesUp = false }
            if index == railed.count - 1 { rail.continuesDown = false }
            rails[row.id] = rail
            previous = agent
        }
        return rails
    }

    private static func provider(
        of row: TranscriptRow, provider: (UUID) -> ProviderKind?, runningProvider: ProviderKind?
    ) -> ProviderKind? {
        switch row.id {
        case .item(let id), .turnHeader(let id), .group(let id), .changedFiles(let id): provider(id)
        case .live: runningProvider
        case .fork, .header, .footer: nil
        }
    }
}

/// Draws a row's piece of the rail. It sits behind the cell's content and lets clicks through.
final class TranscriptRailView: NSView {
    static let lineWidth: CGFloat = 1.5
    static let logoSize: CGFloat = 18

    var rail: TranscriptRail? {
        didSet {
            guard rail != oldValue else { return }
            needsDisplay = true
            needsLayout = true
            updateNode()
        }
    }

    /// Whether a message of the user's is marked with a ring. With the message across the transcript from the rail,
    /// the line runs on through it instead.
    var showsMessageNode = true {
        didSet {
            guard showsMessageNode != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Where the node's center sits, from the top of the row.
    var nodeY: CGFloat = 10 {
        didSet {
            guard nodeY != oldValue else { return }
            needsLayout = true
            needsDisplay = true
        }
    }

    private let logo = NSImageView()
    private let liveDot = NSView()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        logo.imageScaling = .scaleProportionallyUpOrDown
        addSubview(logo)
        liveDot.wantsLayer = true
        liveDot.layer?.cornerRadius = 3
        addSubview(liveDot)
        setAccessibilityElement(false)
        logo.setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func updateNode() {
        if case .agent(let provider) = rail?.node {
            logo.isHidden = false
            logo.image = Theme.logo(for: provider)
            logo.contentTintColor = .labelColor
        } else {
            logo.isHidden = true
            logo.image = nil
        }
        liveDot.isHidden = liveProvider == nil
        updateLiveDot()
    }

    private var liveProvider: ProviderKind? {
        if case .live(let provider) = rail?.node { return provider }
        return nil
    }

    /// Half the gap the line leaves around the node.
    private var gap: CGFloat {
        switch rail?.node {
        case .agent: Self.logoSize / 2 + 4
        case .message: showsMessageNode ? 7 : 0
        case .live: 6
        default: 0
        }
    }

    override func layout() {
        super.layout()
        let x = bounds.midX
        logo.frame = NSRect(x: x - Self.logoSize / 2, y: nodeY - Self.logoSize / 2, width: Self.logoSize, height: Self.logoSize)
        liveDot.frame = NSRect(x: x - 3, y: nodeY - 3, width: 6, height: 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let rail else { return }
        let x = bounds.midX
        let top: CGFloat = rail.continuesUp ? 0 : nodeY
        // The rail ends at the last row's node, or fades out down a last row without one.
        let fades = !rail.continuesDown && rail.node == .none
        let bottom: CGFloat = rail.continuesDown || fades ? bounds.height : nodeY
        let alpha: CGFloat = 0.55
        let gradient = NSGradient(
            starting: Theme.color(for: rail.top).withAlphaComponent(alpha),
            ending: Theme.color(for: rail.bottom).withAlphaComponent(fades ? 0 : alpha))
        // The blend between two agents spans the whole row, whatever part of it the line shows.
        let full = NSRect(x: x - Self.lineWidth / 2, y: 0, width: Self.lineWidth, height: bounds.height)
        for segment in [(top, nodeY - gap), (nodeY + gap, bottom)] where segment.1 > segment.0 {
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: full.minX, y: segment.0, width: Self.lineWidth, height: segment.1 - segment.0).clip()
            gradient?.draw(in: full, angle: 90)
            NSGraphicsContext.restoreGraphicsState()
        }
        if rail.node == .message, showsMessageNode {
            let ring = NSBezierPath(ovalIn: NSRect(x: x - 3.5, y: nodeY - 3.5, width: 7, height: 7))
            ring.lineWidth = 1.5
            NSColor.secondaryLabelColor.setStroke()
            ring.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLiveDot()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLiveDot()
    }

    /// The live dot breathes while the agent works, unless the user asked for less motion.
    private func updateLiveDot() {
        guard let layer = liveDot.layer else { return }
        let key = "breathe"
        guard let provider = liveProvider else {
            layer.removeAnimation(forKey: key)
            return
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = Theme.color(for: provider).cgColor
        }
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            layer.removeAnimation(forKey: key)
            return
        }
        guard layer.animation(forKey: key) == nil else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0.3
        animation.duration = 0.9
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: key)
    }
}
