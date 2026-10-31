import CoincideKit
import CoincideRemoteKit
import CryptoKit
import Foundation

/// The global instruction files, for Settings › Instructions on Coincide Remote: listed as document rows, read and saved
/// whole. The phone names a file only by a key the Mac listed; the Mac looks it up in the files it found itself and
/// never opens a path the phone sends. A save carries the version the phone read, and is refused when the file changed
/// since, as the Mac's own editor refuses to overwrite changes made outside it.
@MainActor
final class RemoteInstructions {
    /// A file as listed: its key, the path the agents read, and what the row says about it.
    struct Listed: Equatable {
        var key: String
        var url: URL
        var title: String
        var detail: String
        var isMaster: Bool
    }

    static let keyPrefix = "instructions.file."

    /// Finds the files, as the Mac's Instructions pane lists them; replaced in tests.
    private let discover: () async -> [Listed]
    /// Runs after a save, such as copying a saved master to iCloud or a repository.
    private let didSave: (Listed) -> Void
    private(set) var files: [Listed] = []

    init(discover: @escaping () async -> [Listed], didSave: @escaping (Listed) -> Void = { _ in }) {
        self.discover = discover
        self.didSave = didSave
    }

    /// The Mac's global instruction files, with the master first in master mode.
    static var live: RemoteInstructions {
        let model = InstructionsModel(scope: .global)
        return RemoteInstructions(
            discover: {
                await model.reload()
                let master = model.isMasterMode ? model.files.first { $0.url.standardizedFileURL == model.masterURL.standardizedFileURL } : nil
                let readers = model.masterReaders
                var listed: [Listed] = []
                if let master {
                    listed.append(Self.listed(master, readers: readers, isMaster: true))
                }
                for file in model.listedFiles where file.id != master?.id {
                    listed.append(Self.listed(file, readers: model.usedBy(file), isMaster: false))
                }
                return listed
            },
            didSave: { file in
                guard file.isMaster, model.config.iCloud != nil || model.config.git != nil else { return }
                model.syncer.sync()
            })
    }

    private static func listed(_ file: InstructionFile, readers: [ProviderKind], isMaster: Bool) -> Listed {
        var parts: [String] = []
        if isMaster { parts.append(String(localized: "Master")) }
        if !readers.isEmpty { parts.append(readers.map(\.displayName).formatted(.list(type: .and))) }
        if let note = file.note { parts.append(note) }
        if !file.exists { parts.append(String(localized: "Not created yet")) }
        return Listed(
            key: keyPrefix + file.id, url: file.url, title: file.displayName,
            detail: parts.joined(separator: " · "), isMaster: isMaster)
    }

    /// Finds the files again, for the next Settings snapshot.
    func refresh() async {
        files = await discover()
    }

    func document(_ key: String) throws -> RemoteSettingsDocument {
        let file = try listed(key)
        let snapshot = try InstructionFileStore.read(file.url)
        guard snapshot.text.count <= RemoteSettingsDocument.maxLength else {
            throw RemoteError(.notAllowed, String(localized: "This file is too long to edit here. Edit it on your Mac."))
        }
        return RemoteSettingsDocument(key: key, title: file.title, text: snapshot.text, version: Self.version(snapshot))
    }

    func save(_ document: RemoteSettingsDocument) throws -> RemoteSettingsDocument {
        let file = try listed(document.key)
        guard document.text.count <= RemoteSettingsDocument.maxLength else {
            throw RemoteError(.badRequest, "Text too long.")
        }
        let current = try InstructionFileStore.read(file.url)
        guard Self.version(current) == document.version else {
            throw RemoteError(.conflict, String(localized: "\(file.title) changed on your Mac. Reload it to see the change, then edit again."))
        }
        let saved = try InstructionFileStore.write(document.text, to: file.url, expecting: current)
        didSave(file)
        return RemoteSettingsDocument(key: document.key, title: file.title, text: saved.text, version: Self.version(saved))
    }

    private func listed(_ key: String) throws -> Listed {
        guard let file = files.first(where: { $0.key == key }) else {
            throw RemoteError(.notFound, String(localized: "That file isn’t one of the instruction files any more."))
        }
        return file
    }

    /// The text's fingerprint, and whether the file exists: a version the phone hands back unchanged.
    nonisolated static func version(_ snapshot: InstructionSnapshot) -> String {
        let digest = SHA256.hash(data: Data(snapshot.text.utf8)).map { String(format: "%02x", $0) }.joined()
        return (snapshot.fingerprint == nil ? "new-" : "") + digest
    }
}
