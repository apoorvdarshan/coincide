import Foundation

/// Keeps Coincide's per-thread model choices out of the user's own Cursor CLI settings.
///
/// `cursor-agent` has one model per process and saves every change of it in `cli-config.json`, where it
/// becomes the default of the user's own `cursor-agent` runs: picking a model or a reasoning effort
/// through ACP (`session/set_config_option`), starting with `--model`, and reopening a chat (Cursor then
/// switches to the chat's last model). No flag or environment variable keeps the choice in memory, and a
/// separate `CURSOR_CONFIG_DIR` would also move the chats, permissions and sign-in state. So the session
/// snapshots the model settings before each of those operations and writes them back afterwards; the
/// running process keeps the model it was given, because it never reads the file again for it.
///
/// The write-back only touches the model keys, re-reads the file right before an atomic replace, and is
/// skipped when the file now names a model Coincide did not ask for (the user changed it meanwhile).
/// Overlapping operations of several threads share one snapshot, taken by the first and restored by the last.
@MainActor
final class CursorModelSettings {
    /// The `cli-config.json` keys Cursor's model manager writes.
    nonisolated static let keys = [
        "model", "selectedModel", "modelParameters", "hasChangedDefaultModel", "maxMode", "maxModeAutoEnabled",
        "modelSelectionHistory",
    ]

    private static var instances: [String: CursorModelSettings] = [:]

    let fileURL: URL
    private var depth = 0
    /// Model keys as they were before the outermost running operation; nil when the file could not be read.
    private var snapshot: [String: Any]?
    /// Models Coincide's sessions switched to during the current operations.
    private var touchedModels: Set<String> = []

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The guard for the config file a `cursor-agent` launched with `environment` uses.
    static func shared(environment: [String: String]) -> CursorModelSettings {
        let url = configFileURL(environment: environment)
        if let existing = instances[url.path] { return existing }
        let settings = CursorModelSettings(fileURL: url)
        instances[url.path] = settings
        return settings
    }

    /// Where `cursor-agent` keeps `cli-config.json`: `$CURSOR_CONFIG_DIR`, else `$XDG_CONFIG_HOME/cursor`, else `~/.cursor`.
    nonisolated static func configFileURL(environment: [String: String]) -> URL {
        func value(_ key: String) -> String? {
            guard let text = environment[key], !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return text
        }
        let directory: URL
        if let custom = value("CURSOR_CONFIG_DIR") {
            directory = URL(fileURLWithPath: custom, isDirectory: true)
        } else if let xdg = value("XDG_CONFIG_HOME") {
            directory = URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("cursor", isDirectory: true)
        } else {
            let home = value("HOME") ?? NSHomeDirectory()
            directory = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".cursor", isDirectory: true)
        }
        return directory.appendingPathComponent("cli-config.json")
    }

    // MARK: Operations

    /// Call before an operation that may make Cursor save a model.
    func begin() {
        if depth == 0 {
            snapshot = readModelSettings()
            touchedModels = []
        }
        depth += 1
    }

    /// Call once the operation is over, with the models the session now uses (or asked for).
    func end(touching models: [String]) {
        guard depth > 0 else { return }
        touchedModels.formUnion(models.filter { !$0.isEmpty })
        depth -= 1
        guard depth == 0 else { return }
        if let snapshot { restore(snapshot) }
        snapshot = nil
        touchedModels = []
    }

    /// The model of the user's own Cursor settings, which Coincide's "Default" entry stands for.
    func userModelID() -> String? {
        if depth > 0 { return snapshot.flatMap(Self.modelID(in:)) }
        return readModelSettings().flatMap(Self.modelID(in:))
    }

    // MARK: File

    /// The model keys of the config, or nil when it exists but cannot be read as a JSON object.
    /// A missing file reads as no keys at all.
    private func readModelSettings() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        guard let object = readObject() else { return nil }
        return object.filter { Self.keys.contains($0.key) }
    }

    private func readObject() -> [String: Any]? {
        guard let data = try? Data(contentsOf: fileURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private func restore(_ saved: [String: Any]) {
        guard var object = readObject() else { return }
        let current = object.filter { Self.keys.contains($0.key) }
        guard !Self.same(current, saved) else { return }
        // Someone else picked a model while Coincide's operation ran; leave their choice alone.
        let now = Self.modelID(in: current)
        guard now == Self.modelID(in: saved) || now.map(touchedModels.contains) == true else { return }
        for key in Self.keys {
            object[key] = saved[key]
        }
        guard
            var data = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        data.append(0x0A)
        Self.replace(fileURL.resolvingSymlinksInPath(), with: data)
    }

    /// Writes next to the file and renames over it, so readers never see a partial file.
    private nonisolated static func replace(_ url: URL, with data: Data) {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).coincide-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            if let permissions = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] {
                try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            }
            guard rename(temporary.path, url.path) == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                return
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    /// The model a settings snapshot selects: `selectedModel.modelId`, else the older `model.modelId`.
    nonisolated static func modelID(in settings: [String: Any]) -> String? {
        for key in ["selectedModel", "model"] {
            if let model = settings[key] as? [String: Any], let id = model["modelId"] as? String, !id.isEmpty {
                return id
            }
        }
        return nil
    }

    private nonisolated static func same(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        NSDictionary(dictionary: lhs).isEqual(to: rhs)
    }
}
