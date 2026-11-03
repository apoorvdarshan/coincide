import AppKit
import AVKit
import CoincideKit
import ImageIO
import WebKit

/// Provider-independent rich output. The Markdown remains selectable/copyable; these cards add previews below it.
nonisolated struct TranscriptMedia: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case image, video, audio, interactive }
    var kind: Kind
    var label: String
    var url: URL?
    var html: String?

    static func extract(text: String, attachments: [String] = [], directory: URL?) -> [Self] {
        var result: [Self] = []
        var seen: Set<Self> = []
        func add(_ media: Self) {
            guard result.count < 8, seen.insert(media).inserted else { return }
            // The same image can be both an attachment and a Markdown image.
            guard media.url == nil || !result.contains(where: { $0.url == media.url }) else { return }
            result.append(media)
        }
        func file(_ source: String, label: String, image: Bool = false) {
            guard let url = resolve(source, directory: directory) else { return }
            let ext = url.pathExtension.lowercased()
            let kind: Kind
            if ["mp4", "m4v", "mov", "webm"].contains(ext) { kind = .video }
            else if ["mp3", "m4a", "wav", "aac", "aiff", "flac", "ogg"].contains(ext) { kind = .audio }
            else if ["html", "htm", "svg"].contains(ext), url.isFileURL { kind = .interactive }
            else if image || ["png", "jpg", "jpeg", "gif", "webp", "heic", "avif", "bmp", "tiff"].contains(ext) { kind = .image }
            else { return }
            add(Self(kind: kind, label: label.isEmpty ? url.lastPathComponent : label, url: url))
        }
        func inlines(_ values: [ChatMarkdown.Inline]) {
            for value in values {
                switch value {
                case .image(let alt, let source): file(source, label: alt, image: true)
                case .link(let destination, let children):
                    file(destination, label: ChatMarkdown.plainText(children)); inlines(children)
                case .emphasis(let children), .strong(let children), .strikethrough(let children): inlines(children)
                default: break
                }
            }
        }
        func blocks(_ values: [ChatMarkdown.Block]) {
            for value in values where result.count < 8 {
                switch value {
                case .paragraph(let children), .heading(_, let children): inlines(children)
                case .quote(let children): blocks(children)
                case .list(let list): for item in list.items { blocks(item.blocks) }
                case .table(let table):
                    for cell in table.header { inlines(cell) }
                    for row in table.rows { for cell in row { inlines(cell) } }
                case .code(let language, let code):
                    // A dedicated fence opts into executable previews. Ordinary HTML examples stay code.
                    if ["coincide-html", "coincide-svg"].contains(language?.lowercased() ?? ""), code.utf8.count <= 262_144 {
                        add(Self(kind: .interactive, label: language ?? "HTML", html: code))
                    }
                default: break
                }
            }
        }
        for path in attachments { file(path, label: "", image: true) }
        if text.utf8.count <= 524_288 { blocks(ChatMarkdown.parse(text)) }
        return result
    }

    static func resolve(_ source: String, directory: URL?) -> URL? {
        if source.hasPrefix("data:image/"), source.utf8.count <= 12 * 1024 * 1024 { return URL(string: source) }
        if let url = URL(string: source), let scheme = url.scheme?.lowercased() {
            guard ["file", "http", "https"].contains(scheme), url.user == nil, url.password == nil else { return nil }
            return url
        }
        let path = (source as NSString).expandingTildeInPath
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        guard let directory else { return nil }
        return directory.appendingPathComponent(source.removingPercentEncoding ?? source).standardizedFileURL
    }

    /// The file name line above the picture.
    static let labelHeight: CGFloat = 24
    /// The card of a file that can't be shown: its name and why.
    static let unavailableHeight: CGFloat = labelHeight + 36

    /// The card's size in a column `width` wide. A picture or video fits its own shape, no taller than its limit and
    /// never wider than the column, so no bars or empty space sit beside it; until its shape is known (a moment after
    /// it first shows) it takes a placeholder about the shape of a screenshot, and a file that isn't there takes a
    /// line. The row measures again once the shape is known (`TranscriptMediaShapes.didLearn`).
    @MainActor func size(width: CGFloat) -> CGSize {
        let width = max(1, width)
        switch kind {
        case .audio: return CGSize(width: width, height: 90)
        case .interactive: return CGSize(width: width, height: 424)
        case .image, .video:
            let maxHeight: CGFloat = kind == .image ? 380 : 360
            switch TranscriptMediaShapes.shape(of: self) {
            case .unavailable:
                return CGSize(width: width, height: Self.unavailableHeight)
            case .unknown:
                return CGSize(width: width, height: Self.labelHeight + min(maxHeight, max(140, (width * 9 / 16).rounded())))
            case .size(let pixels):
                let fitted = Self.fit(pixels, maxWidth: width, maxHeight: maxHeight, upscales: kind == .video)
                return CGSize(width: fitted.width, height: Self.labelHeight + fitted.height)
            }
        }
    }

    @MainActor func height(width: CGFloat) -> CGFloat { size(width: width).height }

    /// `pixels` scaled to fit within `maxWidth` by `maxHeight`, keeping its shape. Pictures aren't enlarged past their
    /// own size; videos fill the width up to the height limit. Never thinner than a line, however long and thin.
    nonisolated static func fit(_ pixels: CGSize, maxWidth: CGFloat, maxHeight: CGFloat, upscales: Bool) -> CGSize {
        guard pixels.width > 0, pixels.height > 0, maxWidth > 0, maxHeight > 0 else { return CGSize(width: maxWidth, height: maxHeight) }
        var scale = min(maxWidth / pixels.width, maxHeight / pixels.height)
        if !upscales { scale = min(scale, 1) }
        let width = max(1, min(maxWidth, (pixels.width * scale).rounded()))
        let height = max(min(24, maxHeight), (pixels.height * scale).rounded())
        return CGSize(width: width, height: min(maxHeight, height))
    }
}

/// What the transcript knows of a picture's or video's shape.
nonisolated enum TranscriptMediaShape: Hashable, Sendable {
    /// Not read yet (or a web picture not downloaded yet).
    case unknown
    /// Its size in pixels, upright.
    case size(CGSize)
    /// The file isn't there, or can't be read or played.
    case unavailable
}

/// The shapes of the pictures and videos replies show, read once per file in the background: an image's header, a
/// video's track. A card measures by its shape, so the row it sits in measures again when one is learned; this posts
/// `didLearn` with the file's URL then.
@MainActor
enum TranscriptMediaShapes {
    static let didLearn = Notification.Name("TranscriptMediaShapes.didLearn")
    static let urlKey = "url"

    private static var shapes: [URL: TranscriptMediaShape] = [:]
    private static var reading: Set<URL> = []
    /// Files found missing, and when: one written later (an agent still rendering it) is looked for again.
    private static var missing: [URL: Date] = [:]
    private static let missingRecheck: TimeInterval = 5

    /// The shape of `media` as far as it is known now. A local file is looked for at once (a missing one is
    /// unavailable straight away) and read in the background the first time it is asked for.
    static func shape(of media: TranscriptMedia) -> TranscriptMediaShape {
        guard media.kind == .image || media.kind == .video, let url = media.url else { return .unknown }
        if let checked = missing[url] {
            if Date().timeIntervalSince(checked) < missingRecheck { return .unavailable }
            guard FileManager.default.fileExists(atPath: url.path) else {
                missing[url] = Date()
                return .unavailable
            }
            // It's there now: read it, and the rows showing it measure again once its shape is known.
            missing[url] = nil
        }
        if let shape = shapes[url] { return shape }
        guard url.isFileURL else {
            // Web and inline pictures: the card says what it got once it has loaded the picture.
            return .unknown
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            missing[url] = Date()
            return .unavailable
        }
        read(url, isVideo: media.kind == .video)
        return .unknown
    }

    /// Records a shape learned another way, such as a web picture's once it downloaded.
    static func learn(_ shape: TranscriptMediaShape, for url: URL) {
        guard shape != .unknown, shapes[url] != shape else { return }
        shapes[url] = shape
        NotificationCenter.default.post(name: didLearn, object: nil, userInfo: [urlKey: url])
    }

    private static func read(_ url: URL, isVideo: Bool) {
        guard reading.insert(url).inserted else { return }
        Task {
            let shape = isVideo ? await TranscriptMediaShapeReader.video(url) : await TranscriptMediaShapeReader.image(url)
            reading.remove(url)
            learn(shape, for: url)
        }
    }
}

/// Reads shapes off the main thread.
nonisolated enum TranscriptMediaShapeReader {
    @concurrent static func image(_ url: URL) async -> TranscriptMediaShape {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, width > 0, height > 0
        else { return .unavailable }
        // Orientations 5 to 8 turn the picture on its side.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return .size(orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height))
    }

    @concurrent static func video(_ url: URL) async -> TranscriptMediaShape {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
            let loaded = try? await track.load(.naturalSize, .preferredTransform)
        else { return .unavailable }
        let upright = loaded.0.applying(loaded.1)
        let shape = CGSize(width: abs(upright.width), height: abs(upright.height))
        return shape.width > 0 && shape.height > 0 ? .size(shape) : .unavailable
    }
}

/// A bounded cache avoids reparsing a long response on every table height/layout pass. Entries are kept per folder
/// links resolve against: the row builder asks without one, the cells with the thread's, and neither evicts the other.
@MainActor
enum TranscriptMediaCache {
    private struct Key: Hashable { var id: UUID; var directory: URL? }
    private struct Entry { var text: String; var attachments: [String]; var running: Bool; var media: [TranscriptMedia] }
    private static var entries: [Key: Entry] = [:]
    /// Enough for every reply of a long thread, and the threads opened around it.
    private static let limit = 4096
    static func media(_ item: TranscriptItem, directory: URL?) -> [TranscriptMedia] {
        let attachments = item.attachments ?? []
        let key = Key(id: item.id, directory: directory)
        if let entry = entries[key], entry.text == item.text, entry.attachments == attachments, entry.running == (item.status == .running) { return entry.media }
        let media = TranscriptMedia.extract(text: item.text, attachments: attachments, directory: directory).filter { item.status != .running || $0.kind != .interactive }
        if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
        entries[key] = Entry(text: item.text, attachments: attachments, running: item.status == .running, media: media)
        return media
    }
    static func height(_ item: TranscriptItem, width: CGFloat, directory: URL?) -> CGFloat {
        media(item, directory: directory).reduce(0) { $0 + $1.size(width: width).height + 12 }
    }
}

final class TranscriptMediaView: NSView, WKNavigationDelegate {
    let media: TranscriptMedia
    private let label = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: String(localized: "Loading…"))
    /// Where the picture or video goes, shaded until it shows, so a card still loading reads as a card.
    private let placeholder = TranscriptMediaPlaceholder()
    private var imageView: NSImageView?
    private var playerView: AVPlayerView?
    private var webView: WKWebView?
    private var load: Task<Void, Never>?
    var onOpen: ((URL) -> Void)?
    override var isFlipped: Bool { true }

    init(media: TranscriptMedia) {
        self.media = media
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        label.stringValue = media.label
        label.font = .systemFont(ofSize: Theme.fontSize - 2)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        addSubview(placeholder); addSubview(label); addSubview(status)
        setAccessibilityElement(false)
        if (media.kind == .image || media.kind == .video) && TranscriptMediaShapes.shape(of: media) == .unavailable {
            failed()
        } else {
            showContent()
        }
    }

    /// Puts in the picture, player or page, loading what it needs.
    private func showContent() {
        let media = media
        switch media.kind {
        case .image:
            let view = NSImageView()
            view.imageScaling = .scaleProportionallyUpOrDown
            view.setAccessibilityLabel(media.label)
            imageView = view; addSubview(view)
            load = Task { [weak self] in
                guard let image = await MediaImageLoader.load(media.url), !Task.isCancelled, let self else {
                    if let url = media.url, !url.isFileURL { TranscriptMediaShapes.learn(.unavailable, for: url) }
                    self?.failed(); return
                }
                self.imageView?.image = NSImage(cgImage: image, size: .zero)
                self.status.isHidden = true
                self.placeholder.isHidden = true
                // A web picture's shape is known only now. A file's is read from the file itself, at full size.
                if let url = media.url, !url.isFileURL {
                    TranscriptMediaShapes.learn(.size(CGSize(width: image.width, height: image.height)), for: url)
                }
            }
        case .video, .audio:
            if let url = media.url {
                let view = AVPlayerView()
                view.controlsStyle = media.kind == .audio ? .inline : .floating
                view.player = AVPlayer(url: url)
                view.setAccessibilityLabel(media.label)
                playerView = view; addSubview(view)
                status.isHidden = true
                placeholder.isHidden = media.kind == .audio
                needsLayout = true
            }
        case .interactive:
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.mediaTypesRequiringUserActionForPlayback = .all
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.navigationDelegate = self
            webView = view; addSubview(view)
            load = Task { [weak self] in
                var html = media.html
                if html == nil, let url = media.url, url.isFileURL {
                    html = await Task.detached {
                        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), size.isRegularFile == true,
                            (size.fileSize ?? .max) <= 262_144 else { return nil as String? }
                        return try? String(contentsOf: url, encoding: .utf8)
                    }.value
                }
                guard !Task.isCancelled, let self else { return }
                guard let html else { self.failed(); return }
                self.webView?.loadHTMLString(InteractiveOutput.document(html), baseURL: nil)
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit {
        load?.cancel()
        playerView?.player?.pause()
        NotificationCenter.default.removeObserver(self)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { playerView?.player?.pause() }
        if window != nil, media.kind == .image || media.kind == .video {
            NotificationCenter.default.removeObserver(self, name: TranscriptMediaShapes.didLearn, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(shapeLearned(_:)), name: TranscriptMediaShapes.didLearn, object: nil)
        }
    }
    @objc private func shapeLearned(_ notification: Notification) {
        guard let url = notification.userInfo?[TranscriptMediaShapes.urlKey] as? URL, url == media.url else { return }
        switch TranscriptMediaShapes.shape(of: media) {
        case .unavailable:
            // A video that turned out unplayable: say so in a line rather than leave a black box.
            playerView?.player?.pause()
            playerView?.removeFromSuperview()
            playerView = nil
            failed()
        case .size:
            // A file that wasn't there when the card first showed has been written since.
            if imageView == nil, playerView == nil {
                status.stringValue = String(localized: "Loading…")
                showContent()
            }
        case .unknown:
            break
        }
        needsLayout = true
    }
    private func failed() {
        let missing = media.url.map { $0.isFileURL && !FileManager.default.fileExists(atPath: $0.path) } ?? false
        status.stringValue = missing ? String(localized: "Not found") : String(localized: "Preview unavailable")
        status.isHidden = false
        imageView?.isHidden = true
    }
    /// The picture's or video's frame: the card under its name, as wide as the card, which is sized to its shape.
    var contentFrame: NSRect {
        NSRect(x: 0, y: TranscriptMedia.labelHeight, width: bounds.width, height: max(0, bounds.height - TranscriptMedia.labelHeight))
    }
    override func layout() {
        super.layout()
        // The name lines up with the reply's text, as the picture under it does.
        label.frame = NSRect(x: 0, y: 2, width: max(0, bounds.width), height: 18)
        let content = contentFrame
        imageView?.frame = content; playerView?.frame = content; webView?.frame = content
        placeholder.frame = content
        placeholder.isHidden = placeholder.isHidden || media.kind == .audio || media.kind == .interactive
        status.sizeToFit()
        status.frame = NSRect(x: 12, y: (content.midY - status.frame.height / 2).rounded(), width: max(0, bounds.width - 24), height: status.frame.height)
    }
    override func mouseDown(with event: NSEvent) {
        if media.kind == .image, let url = media.url { onOpen?(url) }
        else { super.mouseDown(with: event) }
    }
    /// An image opens on a click; a video and a web page handle the pointer themselves.
    override func resetCursorRects() { addPointerCursorRect(clickable: media.kind == .image && media.url != nil) }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = action.request.url?.scheme
        decisionHandler(scheme == "about" || scheme == "data" || scheme == "blob" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { status.isHidden = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { failed() }
}

/// The shaded box a picture or video loads into.
final class TranscriptMediaPlaceholder: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.06).cgColor
        layer?.cornerRadius = 8
    }
}

/// Untrusted interactive content runs in an opaque sandboxed frame, with no app bridge, saved logins,
/// network, forms, downloads, popups or top-level navigation. Inline JS can drive self-contained charts.
nonisolated enum InteractiveOutput {
    static func document(_ html: String) -> String {
        let policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; media-src data: blob:; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
        let child = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><style>html{color-scheme:light dark}body{font:14px system-ui;margin:12px}svg,canvas,img{max-width:100%}</style>" + html
        let escaped = child.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; media-src data: blob:; font-src data:; frame-src about: data: blob:; base-uri 'none'\"><style>html,body,iframe{margin:0;width:100%;height:100%;border:0;color-scheme:light dark}</style><iframe sandbox=\"allow-scripts\" srcdoc=\"\(escaped)\"></iframe>"
    }
}

nonisolated enum MediaImageLoader {
    /// `maxPixelSize` caps the longest edge; Coincide Remote asks for its own thumbnail and full sizes.
    @concurrent static func load(_ url: URL?, maxPixelSize: Int = 1600) async -> CGImage? {
        guard let url else { return nil }
        let source: CGImageSource?
        if url.isFileURL {
            guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), info.isRegularFile == true,
                (info.fileSize ?? .max) <= 64 * 1024 * 1024 else { return nil }
            source = CGImageSourceCreateWithURL(url as CFURL, nil)
        } else {
            let data: Data
            if url.scheme == "data" {
                let raw = url.absoluteString
                guard let comma = raw.firstIndex(of: ","), raw[..<comma].hasSuffix(";base64"),
                    let decoded = Data(base64Encoded: String(raw[raw.index(after: comma)...])), decoded.count <= 8 * 1024 * 1024 else { return nil }
                data = decoded
            } else {
                let config = URLSessionConfiguration.ephemeral
                config.httpShouldSetCookies = false
                config.timeoutIntervalForRequest = 20
                let session = URLSession(configuration: config)
                defer { session.invalidateAndCancel() }
                do {
                    let (bytes, response) = try await session.bytes(from: url)
                    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                        response.expectedContentLength <= 8 * 1024 * 1024 else { return nil }
                    var downloaded = Data()
                    for try await byte in bytes {
                        if downloaded.count >= 8 * 1024 * 1024 || Task.isCancelled { return nil }
                        downloaded.append(byte)
                    }
                    data = downloaded
                } catch { return nil }
            }
            source = CGImageSourceCreateWithData(data as CFData, nil)
        }
        guard let source else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixelSize] as CFDictionary)
    }
}
