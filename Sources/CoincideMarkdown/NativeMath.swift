import AppKit
import SwiftMath
import SwiftUI

@MainActor public enum NativeMath {
    final class Rendered {
        let image: NSImage, descent: CGFloat
        /// Rasterized once; drawing-handler images otherwise redraw on every request.
        private(set) lazy var cgImage: CGImage? = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        init(image: NSImage, descent: CGFloat) { self.image = image; self.descent = descent }
    }
    private static let cache: NSCache<NSString, Rendered> = {
        let value = NSCache<NSString, Rendered>(); value.countLimit = 256; value.totalCostLimit = 8_388_608; return value
    }()
    public static func image(_ latex: String, dark: Bool, display: Bool = true) -> NSImage? {
        rendered(latex, dark: dark, display: display, fontSize: display ? 22 : 15)?.image
    }
    /// A formula image plus its descent, so inline formulas sit on the text baseline.
    static func rendered(_ latex: String, dark: Bool, display: Bool, fontSize: CGFloat) -> Rendered? {
        guard !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              latex.utf8.count <= 4_096, latex.filter({ $0 == "\\" }).count <= 128 else { return nil }
        let key = "\(dark)|\(display)|\(fontSize)|\(latex)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        var depth = 0
        for character in latex {
            if character == "{" { depth += 1; if depth > 48 { return nil } }
            if character == "}" { depth = max(0, depth - 1) }
        }
        var renderer = MathImage(latex: latex, fontSize: fontSize,
                                 textColor: dark ? NSColor(calibratedWhite: 0.9, alpha: 1) : NSColor(calibratedWhite: 0.12, alpha: 1),
                                 labelMode: display ? .display : .text, textAlignment: .left)
        let (error, image, layout) = renderer.asImage()
        guard error == nil, let image, image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0, image.size.width <= 16_384, image.size.height <= 4_096 else { return nil }
        let result = Rendered(image: image, descent: max(0, layout?.descent ?? 0))
        let cost = Int(image.size.width * image.size.height * 4)
        if cost <= 4_194_304 { cache.setObject(result, forKey: key, cost: cost) }
        return result
    }
}

struct NativeMathView: View {
    let latex: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = NativeMath.image(latex, dark: scheme == .dark) {
                ScrollView(.horizontal) { Image(nsImage: image).accessibilityLabel("Formula: \(latex)").padding(.vertical, 8) }
            } else {
                Text(latex).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Text("Formula shown as source").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(latex, forType: .string)
            } label: { Label("Copy LaTeX", systemImage: "doc.on.doc").font(.caption).foregroundStyle(.secondary) }
            .buttonStyle(.plain)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
