import Foundation

/// The browsers Coincide can import from, one line each. Adding a Chromium- or Firefox-based browser is one more
/// entry: its name, bundle identifiers, its folder under `~/Library/Application Support`, and for Chromium the
/// Keychain items ("<Name> Safe Storage") that may hold its cookie key, tried in order.
///
/// Tor Browser is deliberately absent: importing into or out of it would defeat its purpose.
public nonisolated enum BrowserCatalog {
    public enum Engine: Hashable, Sendable {
        case chromium(keychainServices: [String])
        case firefox
        /// Paths relative to the home folder. `probe` is a protected folder whose refusal means Full Disk Access is
        /// missing; nil history or bookmarks mean the browser keeps them where Coincide can't read them.
        case webkit(cookies: [String], history: String?, bookmarks: String?, probe: String?)
        case unsupported(reason: Unsupported)
    }

    public enum Unsupported: String, Hashable, Sendable {
        /// DuckDuckGo encrypts its store with a key held by the app.
        case encryptedStore
        /// Orion's history and bookmarks aren't in a documented format, and its cookies weren't readable.
        case unreadableFormat
    }

    public struct Definition: Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var bundleIDs: [String]
        /// Under `~/Library/Application Support`; empty for WebKit browsers.
        public var supportPath: String
        public var engine: Engine
    }

    static func chromium(_ id: String, _ name: String, _ bundleIDs: [String], _ path: String, _ services: [String]) -> Definition {
        Definition(id: id, name: name, bundleIDs: bundleIDs, supportPath: path, engine: .chromium(keychainServices: services))
    }

    static func firefox(_ id: String, _ name: String, _ bundleIDs: [String], _ path: String) -> Definition {
        Definition(id: id, name: name, bundleIDs: bundleIDs, supportPath: path, engine: .firefox)
    }

    public static let all: [Definition] = [
        // Chromium family.
        chromium("chrome", "Google Chrome", ["com.google.Chrome"], "Google/Chrome", ["Chrome Safe Storage"]),
        chromium("chrome-beta", "Google Chrome Beta", ["com.google.Chrome.beta"], "Google/Chrome Beta", ["Chrome Safe Storage"]),
        chromium("chrome-dev", "Google Chrome Dev", ["com.google.Chrome.dev"], "Google/Chrome Dev", ["Chrome Safe Storage"]),
        chromium("chrome-canary", "Google Chrome Canary", ["com.google.Chrome.canary"], "Google/Chrome Canary", ["Chrome Safe Storage"]),
        // ungoogled-chromium installs as Chromium.app with Chromium's identifier and folder, so this one line covers both.
        chromium("chromium", "Chromium", ["org.chromium.Chromium"], "Chromium", ["Chromium Safe Storage"]),
        chromium("brave", "Brave", ["com.brave.Browser"], "BraveSoftware/Brave-Browser", ["Brave Safe Storage"]),
        chromium("brave-beta", "Brave Beta", ["com.brave.Browser.beta"], "BraveSoftware/Brave-Browser-Beta",
            ["Brave Beta Safe Storage", "Brave Safe Storage"]),
        chromium("brave-nightly", "Brave Nightly", ["com.brave.Browser.nightly"], "BraveSoftware/Brave-Browser-Nightly",
            ["Brave Nightly Safe Storage", "Brave Safe Storage"]),
        chromium("edge", "Microsoft Edge", ["com.microsoft.edgemac"], "Microsoft Edge", ["Microsoft Edge Safe Storage"]),
        chromium("edge-beta", "Microsoft Edge Beta", ["com.microsoft.edgemac.Beta"], "Microsoft Edge Beta",
            ["Microsoft Edge Beta Safe Storage", "Microsoft Edge Safe Storage"]),
        chromium("edge-dev", "Microsoft Edge Dev", ["com.microsoft.edgemac.Dev"], "Microsoft Edge Dev",
            ["Microsoft Edge Dev Safe Storage", "Microsoft Edge Safe Storage"]),
        chromium("edge-canary", "Microsoft Edge Canary", ["com.microsoft.edgemac.Canary"], "Microsoft Edge Canary",
            ["Microsoft Edge Canary Safe Storage", "Microsoft Edge Safe Storage"]),
        chromium("arc", "Arc", ["company.thebrowser.Browser"], "Arc/User Data", ["Arc Safe Storage"]),
        chromium("dia", "Dia", ["company.thebrowser.dia"], "Dia/User Data", ["Dia Safe Storage"]),
        chromium("vivaldi", "Vivaldi", ["com.vivaldi.Vivaldi"], "Vivaldi", ["Vivaldi Safe Storage"]),
        chromium("opera", "Opera", ["com.operasoftware.Opera"], "com.operasoftware.Opera", ["Opera Safe Storage"]),
        chromium("opera-gx", "Opera GX", ["com.operasoftware.OperaGX"], "com.operasoftware.OperaGX",
            ["Opera GX Safe Storage", "Opera Safe Storage"]),
        chromium("yandex", "Yandex Browser", ["ru.yandex.desktop.yandex-browser"], "Yandex/YandexBrowser", ["Yandex Safe Storage"]),
        chromium("comet", "Perplexity Comet", ["ai.perplexity.comet"], "Comet", ["Comet Safe Storage"]),
        chromium("sidekick", "Sidekick", ["com.pushplaylabs.sidekick"], "Sidekick", ["Sidekick Safe Storage"]),
        chromium("thorium", "Thorium", ["org.chromium.Thorium"], "Thorium", ["Thorium Safe Storage", "Chromium Safe Storage"]),
        chromium("helium", "Helium", ["net.imput.helium"], "net.imput.helium", ["Helium Safe Storage", "Chromium Safe Storage"]),
        // Firefox family. Developer Edition and Nightly share Firefox's folder and profiles.ini.
        firefox("firefox", "Firefox", ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"], "Firefox"),
        firefox("librewolf", "LibreWolf", ["org.mozilla.librewolf", "io.gitlab.librewolf-community"], "librewolf"),
        firefox("zen", "Zen", ["app.zen-browser.zen"], "zen"),
        firefox("floorp", "Floorp", ["one.ablaze.floorp"], "Floorp"),
        firefox("waterfox", "Waterfox", ["net.waterfox.waterfox"], "Waterfox"),
        // WebKit.
        Definition(id: "safari", name: "Safari", bundleIDs: ["com.apple.Safari"], supportPath: "",
            engine: .webkit(
                cookies: ["Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
                          "Library/Cookies/Cookies.binarycookies"],
                history: "Library/Safari/History.db", bookmarks: "Library/Safari/Bookmarks.plist", probe: "Library/Safari")),
        Definition(id: "safari-tp", name: "Safari Technology Preview", bundleIDs: ["com.apple.SafariTechnologyPreview"],
            supportPath: "",
            engine: .webkit(
                cookies: ["Library/Containers/com.apple.SafariTechnologyPreview/Data/Library/Cookies/Cookies.binarycookies"],
                history: "Library/SafariTechnologyPreview/History.db", bookmarks: "Library/SafariTechnologyPreview/Bookmarks.plist",
                probe: "Library/SafariTechnologyPreview")),
        Definition(id: "orion", name: "Orion", bundleIDs: ["com.kagi.kagimacOS"], supportPath: "",
            engine: .webkit(
                cookies: ["Library/HTTPStorages/com.kagi.kagimacOS.binarycookies", "Library/Cookies/com.kagi.kagimacOS.binarycookies"],
                history: nil, bookmarks: nil, probe: nil)),
        Definition(id: "duckduckgo", name: "DuckDuckGo", bundleIDs: ["com.duckduckgo.macos.browser"], supportPath: "",
            engine: .unsupported(reason: .encryptedStore)),
    ]

    // MARK: Detection

    public struct Profile: Hashable, Sendable, Identifiable {
        public var id: String { folder.path }
        public var name: String
        public var folder: URL
    }

    public enum Status: Hashable, Sendable {
        case available
        case needsFullDiskAccess
        case unsupported(Unsupported)
    }

    public struct Detected: Hashable, Sendable, Identifiable {
        public var id: String { definition.id }
        public var definition: Definition
        /// The installed app, for its icon. Nil when only its data remains.
        public var appURL: URL?
        public var profiles: [Profile]
        public var status: Status
        public var kinds: Set<BrowserImportKind>
    }

    /// The browsers with an installed app or data on this Mac. `appURL` finds an installed app by bundle identifier
    /// (`NSWorkspace` in the app; a fake in tests). Nothing here opens a browser's data files or another app's
    /// container, so detection never prompts; only scanning does.
    public static func detect(home: URL, appURL: (String) -> URL?) -> [Detected] {
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let manager = FileManager.default
        var result: [Detected] = []
        for definition in all {
            let app = definition.bundleIDs.lazy.compactMap(appURL).first
            switch definition.engine {
            case .chromium:
                let root = support.appendingPathComponent(definition.supportPath, isDirectory: true)
                let profiles = chromiumProfiles(in: root)
                guard app != nil || !profiles.isEmpty else { continue }
                result.append(Detected(definition: definition, appURL: app, profiles: profiles,
                    status: .available, kinds: [.cookies, .history, .bookmarks]))
            case .firefox:
                let root = support.appendingPathComponent(definition.supportPath, isDirectory: true)
                let profiles = FirefoxProfileReader.profiles(in: root).filter { manager.fileExists(atPath: $0.folder.path) }
                    .map { Profile(name: $0.name, folder: $0.folder) }
                guard app != nil || !profiles.isEmpty else { continue }
                result.append(Detected(definition: definition, appURL: app, profiles: profiles,
                    status: .available, kinds: [.cookies, .history, .bookmarks]))
            case .webkit(let cookies, let history, let bookmarks, let probe):
                guard app != nil else { continue }
                var kinds: Set<BrowserImportKind> = [.cookies]
                if history != nil { kinds.insert(.history) }
                if bookmarks != nil { kinds.insert(.bookmarks) }
                var status = Status.available
                if let probe {
                    if isDenied(home.appendingPathComponent(probe)) { status = .needsFullDiskAccess }
                } else if !cookies.contains(where: { isReadable(home.appendingPathComponent($0)) }) {
                    status = .unsupported(.unreadableFormat)
                }
                result.append(Detected(definition: definition, appURL: app, profiles: [Profile(name: definition.name, folder: home)],
                    status: status, kinds: kinds))
            case .unsupported(let reason):
                guard app != nil else { continue }
                result.append(Detected(definition: definition, appURL: app, profiles: [], status: .unsupported(reason), kinds: []))
            }
        }
        return result
    }

    /// `Default`, `Profile 1`… with their names from `Local State`, or the folder itself for browsers (Opera) that
    /// keep one profile at the top level.
    static func chromiumProfiles(in root: URL) -> [Profile] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return [] }
        let names = (try? Data(contentsOf: root.appendingPathComponent("Local State")))
            .flatMap { JSONValue.parse($0)?.at("profile.info_cache")?.object } ?? [:]
        func isProfile(_ folder: URL) -> Bool {
            ["Preferences", "History", "Cookies", "Network/Cookies"].contains {
                manager.fileExists(atPath: folder.appendingPathComponent($0).path)
            }
        }
        var profiles: [Profile] = []
        let entries = (try? manager.contentsOfDirectory(atPath: root.path)) ?? []
        for entry in entries.sorted() where entry == "Default" || entry.hasPrefix("Profile ") {
            let folder = root.appendingPathComponent(entry, isDirectory: true)
            guard isProfile(folder) else { continue }
            profiles.append(Profile(name: names[entry]?["name"]?.string ?? entry, folder: folder))
        }
        if profiles.isEmpty, isProfile(root) { profiles.append(Profile(name: "Default", folder: root)) }
        return profiles.sorted { ($0.folder.lastPathComponent == "Default" ? 0 : 1) < ($1.folder.lastPathComponent == "Default" ? 0 : 1) }
    }

    /// Whether macOS refuses to list `folder` (privacy protection), as opposed to it being missing.
    static func isDenied(_ folder: URL) -> Bool {
        guard let directory = opendir(folder.path) else { return errno == EPERM || errno == EACCES }
        closedir(directory)
        return false
    }

    static func isReadable(_ file: URL) -> Bool {
        let handle = open(file.path, O_RDONLY)
        guard handle >= 0 else { return false }
        close(handle)
        return true
    }
}
