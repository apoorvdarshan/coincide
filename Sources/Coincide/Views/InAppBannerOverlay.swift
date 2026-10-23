import SwiftUI

/// A top-trailing stack of glass banners. Banners for the conversation already on
/// screen are hidden, and only the key window shows the stack.
struct InAppBannerOverlay: View {
    @Bindable var center: InAppBannerCenter
    var hiddenThreadID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    private var visible: [InAppBannerCenter.Banner] {
        center.banners.filter { $0.threadID == nil || $0.threadID != hiddenThreadID }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if activeState != .inactive {
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
        .onHover { center.setHovering($0) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("in-app-banners")
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
