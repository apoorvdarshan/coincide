import AppKit
import SwiftMath
import SwiftUI

@MainActor public enum NativeMath {
    private static let cache: NSCache<NSString, NSImage> = {
        let value = NSCache<NSString, NSImage>(); value.countLimit = 128; value.totalCostLimit = 8_388_608; return value
    }()
    public static func image(_ latex: String, dark: Bool, display: Bool = true) -> NSImage? {
        guard !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              latex.utf8.count <= 4_096, latex.filter({ $0 == "\\" }).count <= 128 else { return nil }
        let key = "\(dark)|\(display)|\(latex)" as NSString
        if let image = cache.object(forKey: key) { return image }
        var depth = 0
        for character in latex {
            if character == "{" { depth += 1; if depth > 48 { return nil } }
            if character == "}" { depth = max(0, depth - 1) }
        }
        var renderer = MathImage(latex: latex, fontSize: display ? 22 : 15,
                                 textColor: dark ? NSColor(calibratedWhite: 0.9, alpha: 1) : NSColor(calibratedWhite: 0.12, alpha: 1),
                                 labelMode: display ? .display : .text, textAlignment: .left)
        let (error, image, _) = renderer.asImage()
        guard error == nil, let image, image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0, image.size.width <= 16_384, image.size.height <= 4_096 else { return nil }
        let cost = Int(image.size.width * image.size.height * 4)
        if cost <= 4_194_304 { cache.setObject(image, forKey: key, cost: cost) }
        return image
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
