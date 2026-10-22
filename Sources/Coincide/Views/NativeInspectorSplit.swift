import AppKit
import SwiftUI

/// The outer SwiftUI scene owns navigation and commands. This native split owns
/// pane geometry without forwarding dynamic editor/Git minimum sizes to the window.
struct NativeInspectorSplit<Detail: View, Inspector: View>: NSViewControllerRepresentable {
    let isPresented: Bool
    @ViewBuilder let detail: () -> Detail
    @ViewBuilder let inspector: () -> Inspector

    func makeNSViewController(context: Context) -> NativeInspectorSplitController {
        let controller = NativeInspectorSplitController(detail: root(detail(), environment: context.environment),
                                                        inspector: root(inspector(), environment: context.environment))
        controller.setInspectorPresented(isPresented)
        return controller
    }

    func updateNSViewController(_ controller: NativeInspectorSplitController, context: Context) {
        controller.update(detail: root(detail(), environment: context.environment),
                          inspector: root(inspector(), environment: context.environment))
        controller.setInspectorPresented(isPresented)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: NativeInspectorSplitController,
                     context: Context) -> CGSize? {
        NativeInspectorSizing.size(fitting: proposal)
    }

    private func root<Content: View>(_ content: Content, environment: EnvironmentValues) -> AnyView {
        AnyView(content.environment(\.self, environment)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity))
    }
}

enum NativeInspectorSizing {
    static func size(fitting proposal: ProposedViewSize) -> CGSize {
        func finite(_ value: CGFloat?) -> CGFloat {
            guard let value, value.isFinite else { return 0 }
            return max(0, value)
        }
        return CGSize(width: finite(proposal.width), height: finite(proposal.height))
    }
}

@MainActor final class NativeInspectorSplitController: NSViewController, NSSplitViewDelegate {
    let splitView = NSSplitView()
    let detailHost: NSHostingController<AnyView>
    let inspectorHost: NSHostingController<AnyView>
    private(set) var inspectorPresented = false
    private(set) var preferredInspectorWidth: CGFloat = 360
    private var layingOut = false

    init(detail: AnyView, inspector: AnyView) {
        detailHost = Self.host(detail); inspectorHost = Self.host(inspector)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(detail:inspector:)") }

    private static func host(_ root: AnyView) -> NSHostingController<AnyView> {
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        controller.sceneBridgingOptions = []
        if let view = controller.view as? NSHostingView<AnyView> {
            view.sizingOptions = []
            view.sceneBridgingOptions = []
        }
        controller.view.translatesAutoresizingMaskIntoConstraints = true
        return controller
    }

    override func loadView() {
        splitView.isVertical = true; splitView.dividerStyle = .thin
        splitView.arrangesAllSubviews = false; splitView.delegate = self
        splitView.setAccessibilityIdentifier("workspace-inspector-split")
        view = splitView
        addChild(detailHost); addChild(inspectorHost)
        splitView.addArrangedSubview(detailHost.view)
    }

    func update(detail: AnyView, inspector: AnyView) {
        detailHost.rootView = detail
        inspectorHost.rootView = inspector
    }

    func setInspectorPresented(_ presented: Bool) {
        _ = view
        guard inspectorPresented != presented else { return }
        inspectorPresented = presented
        if presented {
            splitView.addArrangedSubview(inspectorHost.view)
        } else {
            if let responder = view.window?.firstResponder as? NSView,
               responder.isDescendant(of: inspectorHost.view) {
                view.window?.makeFirstResponder(detailHost.view)
            }
            splitView.removeArrangedSubview(inspectorHost.view)
            inspectorHost.view.removeFromSuperview()
        }
        layoutPanes()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutPanes()
    }

    /// Preserve a 240pt conversation beside the inspector when the available detail
    /// shrinks. Standard window sizes retain the requested 280...600pt inspector range.
    private var inspectorLimits: ClosedRange<CGFloat> {
        let maximum = min(600, max(0, splitView.bounds.width - splitView.dividerThickness - 240))
        return min(280, maximum)...maximum
    }

    private func boundedWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, inspectorLimits.lowerBound), inspectorLimits.upperBound)
    }

    private func layoutPanes() {
        guard !layingOut, isViewLoaded else { return }
        layingOut = true
        defer { layingOut = false }
        let bounds = splitView.bounds
        if inspectorPresented {
            let width = boundedWidth(preferredInspectorWidth)
            let detailWidth = max(0, bounds.width - splitView.dividerThickness - width)
            detailHost.view.frame = CGRect(x: bounds.minX, y: bounds.minY, width: detailWidth, height: bounds.height)
            inspectorHost.view.frame = CGRect(x: bounds.minX + detailWidth + splitView.dividerThickness,
                                              y: bounds.minY, width: width, height: bounds.height)
        } else {
            detailHost.view.frame = bounds
        }
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) { layoutPanes() }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, splitView.bounds.width - splitView.dividerThickness - inspectorLimits.upperBound)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - splitView.dividerThickness - inspectorLimits.lowerBound)
    }

    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView.bounds.width - splitView.dividerThickness - boundedWidth(splitView.bounds.width - splitView.dividerThickness - proposedPosition)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard inspectorPresented, !layingOut, inspectorHost.view.frame.width > 0 else { return }
        preferredInspectorWidth = boundedWidth(inspectorHost.view.frame.width)
    }
}
