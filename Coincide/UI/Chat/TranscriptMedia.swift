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

    func height(width: CGFloat) -> CGFloat {
        switch kind {
        case .image: min(380, max(140, width * 0.7)) + 24
        case .video: min(360, max(140, width * 9 / 16)) + 24
        case .audio: 90
        case .interactive: 424
        }
    }
}

/// A bounded cache avoids reparsing a long response on every table height/layout pass.
@MainActor
enum TranscriptMediaCache {
    private struct Entry { var text: String; var attachments: [String]; var directory: URL?; var running: Bool; var media: [TranscriptMedia] }
    private static var entries: [UUID: Entry] = [:]
    private static var order: [UUID] = []
    static func media(_ item: TranscriptItem, directory: URL?) -> [TranscriptMedia] {
        let attachments = item.attachments ?? []
        if let entry = entries[item.id], entry.text == item.text, entry.attachments == attachments, entry.directory == directory, entry.running == (item.status == .running) { return entry.media }
        let media = TranscriptMedia.extract(text: item.text, attachments: attachments, directory: directory).filter { item.status != .running || $0.kind != .interactive }
        entries[item.id] = Entry(text: item.text, attachments: attachments, directory: directory, running: item.status == .running, media: media)
        order.removeAll { $0 == item.id }; order.append(item.id)
        while order.count > 64 { entries.removeValue(forKey: order.removeFirst()) }
        return media
    }
    static func height(_ item: TranscriptItem, width: CGFloat, directory: URL?) -> CGFloat {
        media(item, directory: directory).reduce(0) { $0 + $1.height(width: width) + 12 }
    }
}

final class TranscriptMediaView: NSView, WKNavigationDelegate {
    let media: TranscriptMedia
    private let label = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: String(localized: "Loading…"))
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
        addSubview(label); addSubview(status)
        setAccessibilityElement(false)
        switch media.kind {
        case .image:
            let view = NSImageView()
            view.imageScaling = .scaleProportionallyUpOrDown
            view.setAccessibilityLabel(media.label)
            imageView = view; addSubview(view)
            load = Task { [weak self] in
                guard let image = await MediaImageLoader.load(media.url), !Task.isCancelled, let self else {
                    self?.failed(); return
                }
                self.imageView?.image = NSImage(cgImage: image, size: .zero)
                self.status.isHidden = true
            }
        case .video, .audio:
            if let url = media.url {
                let view = AVPlayerView()
                view.controlsStyle = media.kind == .audio ? .inline : .floating
                view.player = AVPlayer(url: url)
                view.setAccessibilityLabel(media.label)
                playerView = view; addSubview(view)
                status.isHidden = true
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
    isolated deinit { load?.cancel(); playerView?.player?.pause() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { playerView?.player?.pause() }
    }
    private func failed() { status.stringValue = String(localized: "Preview unavailable"); status.isHidden = false }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 4, y: 2, width: max(0, bounds.width - 8), height: 18)
        let content = NSRect(x: 0, y: 24, width: bounds.width, height: max(0, bounds.height - 24))
        imageView?.frame = content; playerView?.frame = content; webView?.frame = content
        status.frame = NSRect(x: 12, y: content.midY - 10, width: max(0, bounds.width - 24), height: 20)
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
