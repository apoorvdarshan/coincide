import AppKit
import SwiftUI

/// Shared treatment for app-specific chrome. Native sidebars, toolbars, sheets
/// and document/editor backgrounds continue to use their system components.
private struct CoincideGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.modifier(CoincideSurfaceTreatment(cornerRadius: cornerRadius,
            reduceTransparency: reduceTransparency, contrast: contrast))
    }
}

/// Explicit rendering inputs also allow accessibility variants to be checked
/// without changing the user's system accessibility preferences.
struct CoincideSurfaceTreatment: ViewModifier {
    let cornerRadius: CGFloat
    let reduceTransparency: Bool
    let contrast: ColorSchemeContrast

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay { border(shape) }
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
                .overlay { if contrast == .increased { border(shape) } }
        } else {
            content.background(.regularMaterial, in: shape)
                .overlay { border(shape) }
        }
    }
    private func border(_ shape: RoundedRectangle) -> some View {
        shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.45 : 0.12), lineWidth: 1)
            .allowsHitTesting(false)
    }
}

struct CoincideGlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content
    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing; self.content = content()
    }
    @ViewBuilder var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else { content }
    }
}

private struct CoincidePrimaryAction: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.buttonStyle(.glassProminent) }
        else { content.buttonStyle(.borderedProminent) }
    }
}

extension View {
    func coincideGlassGroup(spacing: CGFloat = 8) -> some View {
        CoincideGlassGroup(spacing: spacing) { self }
    }
    func coincideSurface(cornerRadius: CGFloat = 12) -> some View {
        modifier(CoincideGlassSurface(cornerRadius: cornerRadius))
    }
    func coincidePrimaryAction() -> some View { modifier(CoincidePrimaryAction()) }
}
