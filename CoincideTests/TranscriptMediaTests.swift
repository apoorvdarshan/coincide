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

    @Test func deduplicatesAndBoundsCardsAndKeepsImageOnlyResponsesVisible() {
        let text = (0..<20).map { "![\($0)](/tmp/\($0).png)" }.joined(separator: "\n")
        let outputs = TranscriptMedia.extract(text: text, attachments: ["/tmp/0.png"], directory: nil)
        #expect(outputs.count == 8)
        #expect(outputs.filter { $0.url?.path == "/tmp/0.png" }.count == 1)
        var image = TranscriptItem(kind: .assistant, provider: .codex)
        image.attachments = ["/tmp/generated.png"]
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
        let video = TranscriptMediaView(media: .init(kind: .video, label: "Demo", url: folder.url.appendingPathComponent("demo.mov")))
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
