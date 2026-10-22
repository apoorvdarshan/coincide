import SwiftUI

/// Keep the split host's size constraints independent of asynchronously loaded
/// file/Git content. Let that content lay out inside the allocated inspector.
struct InspectorContentBounds<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        GeometryReader { geometry in
            content.frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
