import CoincideKit
import Foundation
import WebKit

/// WebKit performs downloads with the browser's authenticated session. Files get a fresh directory each time;
/// a server-supplied filename cannot overwrite an existing file or escape the download directory.
final class PreviewDownloads: NSObject, WKDownloadDelegate {
    private struct Entry {
        let id = UUID()
        let download: WKDownload
        var destination: URL?
        var state = "downloading"
        var error: String?
    }
    private var entries: [Entry] = []
    let directory: URL

    init(directory: URL) { self.directory = directory }

    func receive(_ download: WKDownload) {
        guard entries.filter({ $0.state == "downloading" }).count < 8 else { download.cancel(); return }
        if entries.count >= 50, let index = entries.firstIndex(where: { $0.state != "downloading" }) { entries.remove(at: index) }
        entries.append(Entry(download: download))
        download.delegate = self
    }

    var json: JSONValue {
        .array(entries.map { entry in
            var value: [String: JSONValue] = ["id": .string(entry.id.uuidString), "state": .string(entry.state)]
            if let url = entry.destination {
                value["name"] = .string(url.lastPathComponent)
                if entry.state == "finished" { value["path"] = .string(url.path) }
            }
            if let error = entry.error { value["error"] = .string(String(error.prefix(2000))) }
            return .object(value)
        })
    }

    func stop() {
        for index in entries.indices where entries[index].state == "downloading" {
            entries[index].download.cancel()
            entries[index].state = "cancelled"
        }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        guard let index = entries.firstIndex(where: { $0.download === download }) else { completionHandler(nil); return }
        let component = (suggestedFilename as NSString).lastPathComponent
            .components(separatedBy: .controlCharacters).joined()
        let filename = component.isEmpty || component == "." || component == ".." ? "download" : String(component.prefix(180))
        let folder = directory.appendingPathComponent(entries[index].id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let destination = folder.appendingPathComponent(filename)
            entries[index].destination = destination
            completionHandler(destination)
        } catch {
            entries[index].state = "failed"
            entries[index].error = error.localizedDescription
            completionHandler(nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let index = entries.firstIndex(where: { $0.download === download }) else { return }
        entries[index].state = "finished"
        if let url = entries[index].destination {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let index = entries.firstIndex(where: { $0.download === download }) else { return }
        entries[index].state = "failed"
        entries[index].error = error.localizedDescription
    }
}
