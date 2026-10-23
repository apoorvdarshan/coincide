import AppKit
import Observation
import SwiftUI

/// A top-trailing stack of glass banners. Banners for the conversation already on
/// screen are hidden, and only the key window shows the stack.
struct InAppBannerOverlay: View {
    @Bindable var center: InAppBannerCenter
    var hiddenThreadID: UUID?
    var keyWindowOverride: Bool? = nil
    @State private var windowState = BannerWindowState()
    @State private var presentationID = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var visible: [InAppBannerCenter.Banner] {
        center.banners.filter { $0.threadID == nil || $0.threadID != hiddenThreadID }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if keyWindowOverride ?? windowState.isKey {
                ForEach(visible) { banner in
                    InAppBannerRow(banner: banner, perform: { center.performAction(banner.id) }, dismiss: { center.dismiss(banner.id) })
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .coincideGlassGroup()
        .padding(.top, 12).padding(.trailing, 16).padding(.leading, 16)
        .frame(maxWidth: 380, alignment: .trailing)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: visible.map(\.id))
        .background { BannerWindowProbe(state: windowState, center: center, presentationID: presentationID) }
        .onHover { center.setHovering($0, owner: presentationID) }
        .onDisappear { center.setHovering(false, owner: presentationID) }
        .onChange(of: windowState.isKey) { _, key in if !key { center.setHovering(false, owner: presentationID) } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("in-app-banners")
    }
}

@MainActor @Observable private final class BannerWindowState { var isKey = false }

/// The overlay belongs to its hosting native window; another local, remote or
/// auxiliary key window cannot make this window's banners interactive.
private struct BannerWindowProbe: NSViewRepresentable {
    let state: BannerWindowState
    let center: InAppBannerCenter
    let presentationID: UUID
    func makeNSView(context: Context) -> Probe { Probe(state: state, center: center, id: presentationID) }
    func updateNSView(_ view: Probe, context: Context) { view.refresh() }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.detach() }
    final class Probe: NSView {
        let state: BannerWindowState
        weak var center: InAppBannerCenter?
        let id: UUID
        private var observations: [any NSObjectProtocol] = []
        init(state: BannerWindowState, center: InAppBannerCenter, id: UUID) {
            self.state = state; self.center = center; self.id = id; super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); detach()
            guard let window else { return }
            center?.registerPresentation(id, window: window)
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
            }
            refresh()
        }
        func refresh() { state.isKey = window?.isKeyWindow == true && window?.attachedSheet == nil && NSApp?.modalWindow == nil }
        func detach() {
            for token in observations { NotificationCenter.default.removeObserver(token) }; observations.removeAll()
            center?.registerPresentation(id, window: nil); state.isKey = false
        }
    }
}

struct InAppBannerRow: View {
    let banner: InAppBannerCenter.Banner
    let perform: () -> Void
    let dismiss: () -> Void

    private var symbol: (name: String, color: Color) {
        switch banner.kind {
        case .success: ("checkmark.circle.fill", .green)
        case .info: ("info.circle.fill", .accentColor)
        case .warning: ("exclamationmark.bubble.fill", .orange)
        case .error: ("exclamationmark.triangle.fill", .red)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol.name).foregroundStyle(symbol.color).font(.title3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                if let detail = banner.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if let actionTitle = banner.actionTitle {
                Button(actionTitle, action: perform).controlSize(.small).accessibilityIdentifier("in-app-banner-action")
            }
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel(Text("Dismiss"))
                .accessibilityIdentifier("in-app-banner-dismiss")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(minWidth: 240, maxWidth: 360, alignment: .leading)
        .coincideSurface(cornerRadius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("in-app-banner")
    }
}
