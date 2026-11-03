import AppKit
import AVKit
import CoincideKit
import Testing
import WebKit
@testable import Coincide

@MainActor @Suite(.serialized)
struct TranscriptMediaTests {
    @Test func imagesMediaLinksAndInteractiveFencesAreProviderIndependent() {
        let content = """
            ![Dog](/tmp/dog.png)
            [Demo](clips/demo.mp4)
            [Audio](https://example.com/audio.m4a)
            ```html
            <button>Example, not a preview</button>
            ```
            ```coincide-html
            <button onclick="this.textContent++">0</button>
            ```
            """
        let outputs = TranscriptMedia.extract(text: content, directory: URL(fileURLWithPath: "/project"))
        #expect(outputs.map(\.kind) == [.image, .video, .audio, .interactive])
        #expect(outputs[1].url?.path == "/project/clips/demo.mp4")
        #expect(outputs.last?.html?.contains("onclick") == true)
        let rendered = ChatMarkdownRenderer.render(content, style: TranscriptText.style(.assistant))
        #expect(rendered.codeBlocks.count == 1) // ordinary HTML stays code; the interactive source stays out of the reading flow
        #expect(rendered.codeBlocks.first?.code.contains("not a preview") == true)
        #expect(ChatMarkdownRenderer.render(content, style: TranscriptText.style(.user)).codeBlocks.count == 2)
        #expect(!outputs.contains { $0.html?.contains("not a preview") == true })
        #expect(TranscriptMedia.resolve("javascript:alert(1)", directory: nil) == nil)
        #expect(TranscriptMedia.resolve("https://user:secret@example.com/a.png", directory: nil) == nil)
        #expect(TranscriptMedia.resolve("relative.png", directory: nil) == nil)
        #expect(TranscriptMedia.resolve("/tmp/my image.png", directory: nil)?.path == "/tmp/my image.png")
    }

    @Test func deduplicatesAndBoundsCardsAndKeepsImageOnlyResponsesVisible() throws {
        let text = (0..<20).map { "![\($0)](/tmp/\($0).png)" }.joined(separator: "\n")
        let outputs = TranscriptMedia.extract(text: text, attachments: ["/tmp/0.png"], directory: nil)
        #expect(outputs.count == 8)
        #expect(outputs.filter { $0.url?.path == "/tmp/0.png" }.count == 1)
        let folder = TemporaryDirectory("generated-image")
        let generated = folder.url.appendingPathComponent("generated.png")
        try TestMedia.writePNG(to: generated, width: 1200, height: 800)
        var image = TranscriptItem(kind: .assistant, provider: .codex)
        image.attachments = [generated.path]
        let user = TranscriptItem(kind: .user, text: "Make an image")
        let final = TranscriptItem(kind: .assistant, text: "Here it is.", provider: .codex)
        let rows = TranscriptBuilder(items: [user, image, final]).build()
        #expect(rows.contains { row in
            guard row.itemID == image.id else { return false }
            if case .assistant = row.kind { return true }
            return false
        })
        #expect(TranscriptMediaCache.height(image, width: 600, directory: nil) > 300)
    }

    @Test func imageDecodeAndPlaybackControlsUseActualFiles() async throws {
        let folder = TemporaryDirectory("rich-media")
        let file = folder.url.appendingPathComponent("pixel.png")
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNQmFDwHwAEFAIglHcfOQAAAABJRU5ErkJggg=="))
        try png.write(to: file)
        #expect(await MediaImageLoader.load(file) != nil)
        let image = TranscriptMediaView(media: .init(kind: .image, label: "Pixel", url: file))
        for _ in 0..<100 {
            if image.subviews.compactMap({ $0 as? NSImageView }).first?.image != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(image.subviews.compactMap { $0 as? NSImageView }.first?.image != nil)
        let movie = folder.url.appendingPathComponent("demo.mov")
        try await TestMedia.writeMovie(to: movie, width: 320, height: 180)
        let video = TranscriptMediaView(media: .init(kind: .video, label: "Demo", url: movie))
        let player = try #require(video.subviews.compactMap { $0 as? AVPlayerView }.first)
        #expect(player.player != nil)
        #expect(player.player?.rate == 0) // no autoplay
        #expect(player.controlsStyle == .floating)
        let audioURL = folder.url.appendingPathComponent("audio.wav")
        do {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410))
            buffer.frameLength = 4410
            buffer.floatChannelData?[0].initialize(repeating: 0, count: 4410)
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            try file.write(from: buffer)
        }
        #expect(try await AVURLAsset(url: audioURL).load(.isPlayable))
        let audio = TranscriptMediaView(media: .init(kind: .audio, label: "Audio", url: audioURL))
        #expect(audio.subviews.compactMap { $0 as? AVPlayerView }.first?.controlsStyle == .inline)
    }

    /// A reply that links a video that is no longer there shows its name and that it wasn't found, on one line,
    /// rather than a full-size black player.
    @Test func aMissingVideoTakesALineNotABlackPlayer() {
        let folder = TemporaryDirectory("missing-media")
        let gone = folder.url.appendingPathComponent("gone-\(UUID().uuidString).mp4")
        let reply = TranscriptItem(kind: .assistant, text: "The render is here: [take 1](\(gone.path))", provider: .claude)
        #expect(TranscriptMediaCache.media(reply, directory: nil).map(\.kind) == [.video])
        #expect(TranscriptMediaCache.height(reply, width: 640, directory: nil) < 100)
        let card = TranscriptMediaView(media: .init(kind: .video, label: "take 1", url: gone))
        card.frame = NSRect(x: 0, y: 0, width: 640, height: 60)
        card.layoutSubtreeIfNeeded()
        #expect(!card.subviews.contains { $0 is AVPlayerView })
        let status = card.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }.map(\.stringValue)
        #expect(status.contains("take 1"))
        #expect(status.count == 2, "the card says why it shows nothing: \(status)")
        // A picture that's gone, too.
        let picture = TranscriptItem(kind: .assistant, text: "![Chart](\(folder.url.appendingPathComponent("gone.png").path))", provider: .claude)
        #expect(TranscriptMediaCache.height(picture, width: 640, directory: nil) < 100)
    }

    @Test func interactiveChartRunsButCannotReadParentOrFetchNetwork() async throws {
        let html = """
            <h2>Interactive chart</h2><p>Native inline output · self-contained SVG and JavaScript</p>
            <svg width="500" height="220" viewBox="0 0 500 220">
              <path d="M30 10V190H480" fill="none" stroke="gray"/>
              <rect x="70" y="50" width="80" height="140" fill="#26a786"/>
              <rect x="210" y="90" width="80" height="100" fill="#6d91ef"/>
              <rect id="bar" x="350" y="130" width="80" height="60" fill="#dd9460"/>
              <g fill="currentColor"><text x="90" y="212">A</text><text x="230" y="212">B</text><text x="370" y="212">C</text></g>
            </svg><br>
            <button id="add" onclick="this.textContent=Number(this.textContent)+1;document.getElementById('bar').setAttribute('height',70);document.getElementById('bar').setAttribute('y',120)">0</button>
            <script>
            addEventListener('message', async () => {
              document.getElementById('add').click();
              let isolated = false, blocked = false;
              try { parent.document.body.innerHTML; } catch(e) { isolated = true; }
              try { await fetch('data:text/plain,forbidden'); } catch(e) { blocked = true; }
              parent.postMessage({count:document.getElementById('add').textContent,height:document.getElementById('bar').getAttribute('height'),isolated,blocked}, '*');
            });
            </script>
            """
        let output = TranscriptMediaView(media: .init(kind: .interactive, label: "Chart", html: html))
        let web = try #require(output.subviews.compactMap { $0 as? WKWebView }.first)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 600, height: 424),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0; window.contentView = output; window.orderBack(nil)
        defer { web.stopLoading(); window.orderOut(nil) }
        #expect(!web.configuration.websiteDataStore.isPersistent)
        var proof: [String: Any]?
        for _ in 0..<200 {
            if !web.isLoading, (try? await web.evaluateJavaScript("document.querySelector('iframe') !== null")) as? Bool == true {
                _ = try? await web.evaluateJavaScript("window.proof=null;addEventListener('message',e=>window.proof=e.data);document.querySelector('iframe').contentWindow.postMessage('increment','*')")
                for _ in 0..<100 {
                    proof = (try? await web.evaluateJavaScript("window.proof")) as? [String: Any]
                    if proof != nil { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = try #require(proof)
        #expect(result["count"] as? String == "1")
        #expect(result["isolated"] as? Bool == true)
        #expect(result["blocked"] as? Bool == true)
        #expect(result["height"] as? String == "70")
        if let path = ProcessInfo.processInfo.environment["COINCIDE_MEDIA_SNAPSHOT"] {
            let image = try await web.takeSnapshot(configuration: nil)
            let data = try #require(image.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// Pictures and movies written for tests, so cards load real files as they do in the app.
enum TestMedia {
    /// A PNG `width` by `height` pixels.
    static func writePNG(to url: URL, width: Int, height: Int) throws {
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    /// A short H.264 movie `width` by `height`, an MP4 or, by its extension, a QuickTime movie.
    static func writeMovie(to url: URL, width: Int, height: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension.lowercased() == "mov" ? .mov : .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, Int32(20 * frame), CVPixelBufferGetDataSize(buffer)) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed, "writing \(url.lastPathComponent): \(String(describing: writer.error))")
    }
}
