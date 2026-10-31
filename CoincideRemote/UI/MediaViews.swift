import CoincideRemoteKit
import SwiftUI
import UIKit

/// Previews the Mac sent, kept in memory within a budget: thumbnails first, full pictures once one is opened.
@MainActor
final class MediaCache {
    enum Outcome {
        case image(UIImage)
        /// The Mac couldn't or wouldn't send it, with why ("Open it on your Mac to play it.").
        case unavailable(String)
    }

    private let thumbnails = NSCache<NSString, UIImage>()
    private let full = NSCache<NSString, UIImage>()
    private var failures: [String: String] = [:]
    private var loading: [String: Task<Outcome, Never>] = [:]

    init() {
        thumbnails.totalCostLimit = 24 * 1024 * 1024
        full.totalCostLimit = 96 * 1024 * 1024
        full.countLimit = 12
    }

    func cached(_ key: Key) -> UIImage? {
        (key.full ? full : thumbnails).object(forKey: key.id as NSString)
            ?? (key.full ? nil : full.object(forKey: Key(key.thread, key.item, key.index, full: true).id as NSString))
    }

    /// The preview, from memory or asked of the Mac once however many views want it at the same time.
    func load(_ key: Key, client: RemoteClient) async -> Outcome {
        if let image = cached(key) { return .image(image) }
        if let reason = failures[key.id] { return .unavailable(reason) }
        #if DEBUG
        if DemoData.isEnabled { return .image(DemoData.picture(key.index, full: key.full)) }
        #endif
        if let task = loading[key.id] { return await task.value }
        let task = Task<Outcome, Never> {
            do {
                guard case .media(let data) = try await client.request(
                    .media(threadID: key.thread, itemID: key.item, index: key.index, full: key.full), timeout: .seconds(60)),
                    let image = UIImage(data: data.data)
                else { return .unavailable(String(localized: "The preview couldn’t be loaded.")) }
                return .image(image)
            } catch let error as RemoteError {
                return .unavailable(error.code == .unsupported ? String(localized: "Update Coincide on your Mac to see previews here.") : error.message)
            } catch {
                return .unavailable(String(localized: "The preview couldn’t be loaded."))
            }
        }
        loading[key.id] = task
        let outcome = await task.value
        loading[key.id] = nil
        switch outcome {
        case .image(let image):
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            (key.full ? full : thumbnails).setObject(image, forKey: key.id as NSString, cost: cost)
        case .unavailable(let reason):
            // A dropped connection may come back; the Mac refusing won't change.
            if client.isConnected { failures[key.id] = reason }
        }
        return outcome
    }

    func clear() {
        thumbnails.removeAllObjects()
        full.removeAllObjects()
        failures = [:]
    }

    struct Key: Hashable {
        var thread: UUID
        var item: UUID
        var index: Int
        var full: Bool

        init(_ thread: UUID, _ item: UUID, _ index: Int, full: Bool) {
            self.thread = thread
            self.item = item
            self.index = index
            self.full = full
        }

        var id: String { "\(thread)/\(item)/\(index)/\(full ? "full" : "thumb")" }
    }
}

/// An item's previews under its text, as the Mac shows them: images as thumbnails (tap for full screen), video with
/// its first frame, and audio or interactive pages as a card that says to open them on the Mac.
struct MediaStrip: View {
    let item: RemoteItem
    let threadID: UUID
    var alignment: HorizontalAlignment = .leading
    @Environment(RemoteClient.self) private var client
    @State private var viewing: RemoteMedia?

    var body: some View {
        let media = item.media ?? []
        let pictures = media.filter { $0.kind == .image || $0.kind == .video }
        let others = media.filter { $0.kind != .image && $0.kind != .video }
        VStack(alignment: alignment, spacing: 8) {
            if !pictures.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pictures) { media in
                            MediaThumbnail(media: media, key: .init(threadID, item.id, media.index, full: false), count: pictures.count) {
                                if media.kind == .image {
                                    viewing = media
                                } else {
                                    client.notice = String(localized: "Open it on your Mac to play it.")
                                }
                            }
                        }
                    }
                }
                .scrollClipDisabled()
                .defaultScrollAnchor(alignment == .trailing ? .trailing : .leading)
            }
            ForEach(others) { media in OpenOnMacCard(media: media) }
        }
        .fullScreenCover(item: $viewing) { media in
            MediaViewer(media: media, threadID: threadID, itemID: item.id)
        }
        #if DEBUG
        // Screenshots of the viewer without taps.
        .task {
            if DemoData.isEnabled, item.kind == .assistant, ProcessInfo.processInfo.arguments.contains("-CoincideRemoteDemoViewer") {
                try? await Task.sleep(for: .seconds(1))
                viewing = pictures.first { $0.kind == .image }
            }
        }
        #endif
    }
}

/// One thumbnail: a placeholder while it loads, then the picture, rounded, at a size that keeps a single picture large
/// and several in a row.
struct MediaThumbnail: View {
    let media: RemoteMedia
    let key: MediaCache.Key
    let count: Int
    let open: () -> Void
    @Environment(RemoteClient.self) private var client
    @Environment(\.theme) private var theme
    @State private var outcome: MediaCache.Outcome?

    var body: some View {
        let height: CGFloat = count == 1 ? 200 : 128
        Button(action: open) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card)
                switch outcome {
                case .image(let image):
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width(image, height: height), height: height)
                        .clipped()
                    if media.kind == .video {
                        Image(systemName: "play.circle.fill")
                            .font(.largeTitle)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.45))
                    }
                case .unavailable(let reason):
                    VStack(spacing: 4) {
                        Image(systemName: "photo.badge.exclamationmark").font(.title3)
                        Text(reason).font(.caption2).multilineTextAlignment(.center).lineLimit(3)
                    }
                    .foregroundStyle(theme.secondaryInk)
                    .padding(8)
                case nil:
                    ProgressView().tint(theme.secondaryInk)
                }
            }
            .frame(width: outcome.flatMap(image).map { width($0, height: height) } ?? height * 1.3, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.border, lineWidth: theme.borderWidth * 0.5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(outcome.flatMap(image) != nil)
        .task(id: key.id) { outcome = await client.media.load(key, client: client) }
        .accessibilityLabel(Text(media.label.isEmpty ? String(localized: "Image") : media.label))
        .accessibilityHint(media.kind == .image ? Text("Opens it full screen") : Text("Open it on your Mac to play it."))
        .accessibilityAddTraits(.isImage)
    }

    private func image(_ outcome: MediaCache.Outcome) -> UIImage? {
        if case .image(let image) = outcome { return image }
        return nil
    }

    /// The width that keeps the picture's shape at this height, within reason for very wide or tall ones.
    private func width(_ image: UIImage, height: CGFloat) -> CGFloat {
        guard image.size.height > 0 else { return height }
        return min(max(height * image.size.width / image.size.height, height * 0.6), height * 2.2)
    }
}

/// Audio and interactive pages: the Mac plays and runs them; the phone says so.
struct OpenOnMacCard: View {
    let media: RemoteMedia
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: media.kind == .audio ? "waveform" : media.kind == .interactive ? "safari" : "doc")
                .font(.body)
                .foregroundStyle(theme.secondaryInk)
                .frame(width: 32, height: 32)
                .background(theme.selection, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(media.label).font(.footnote.weight(.medium)).foregroundStyle(theme.ink).lineLimit(1)
                Text(media.kind == .audio ? "Open it on your Mac to play it." : "Open it on your Mac to see it.")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryInk)
            }
            Spacer(minLength: 0)
            Image(systemName: "macbook").foregroundStyle(theme.tertiaryInk)
        }
        .padding(10)
        .frame(minHeight: 44)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A picture full screen: the thumbnail at once, the full picture as soon as the Mac sends it; pinch or double-tap to
/// zoom, and share or save it.
struct MediaViewer: View {
    let media: RemoteMedia
    let threadID: UUID
    let itemID: UUID
    @Environment(RemoteClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    ZoomableImage(image: image).ignoresSafeArea()
                } else {
                    ProgressView().tint(.white)
                }
                if let problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(10)
                        .background(.black.opacity(0.5), in: .capsule)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 24)
                }
            }
            .navigationTitle(media.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Label("Close", systemImage: "xmark") }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let image {
                        ShareLink(
                            item: Image(uiImage: image), preview: SharePreview(media.label, image: Image(uiImage: image))
                        ) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .task {
            image = client.media.cached(.init(threadID, itemID, media.index, full: false))
            switch await client.media.load(.init(threadID, itemID, media.index, full: true), client: client) {
            case .image(let full): image = full
            case .unavailable(let reason): if image == nil { problem = reason }
            }
        }
    }
}

/// Pinch and double-tap zoom over a picture, the way Photos does it.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    /// Keeps the picture filling the screen as it lays out (rotating, a Duo unfolding) while not zoomed in.
    final class ZoomScrollView: UIScrollView {
        weak var imageView: UIImageView?

        override func layoutSubviews() {
            super.layoutSubviews()
            guard zoomScale == 1, let imageView, imageView.frame.size != bounds.size else { return }
            imageView.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = ZoomScrollView()
        scroll.delegate = context.coordinator
        scroll.maximumZoomScale = 6
        scroll.minimumZoomScale = 1
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.isAccessibilityElement = true
        view.accessibilityTraits = .image
        scroll.addSubview(view)
        scroll.imageView = view
        context.coordinator.imageView = view
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        // The full picture replaces the thumbnail in place.
        context.coordinator.imageView?.image = image
        scroll.setNeedsLayout()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}
