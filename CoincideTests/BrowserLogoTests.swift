import AppKit
import SwiftUI
import Testing

@testable import Coincide
@testable import CoincideKit

/// The browser and password manager logos in Settings: every one has a bundled full-colour logo for when its app isn't
/// installed, and the import list says when a browser's app is gone. Nothing here shows a window.
@MainActor
struct BrowserLogoTests {
    private static let nothingInstalled: (String) -> URL? = { _ in nil }

    @Test func everyCatalogBrowserHasABundledLogo() throws {
        for definition in BrowserCatalog.all {
            let logo = try #require(BrowserLogo.bundled(definition), "\(definition.name) has no \(BrowserLogo.assetName(definition))")
            #expect(!logo.isTemplate, "\(definition.name)'s logo would be tinted")
        }
    }

    @Test func everyPasswordManagerHasABundledLogo() throws {
        for kind in PasswordManagerKind.allCases where kind != .coincide {
            let name = try #require(PasswordManagerLogo.assetName(kind), "\(kind.displayName) has no bundled logo")
            let logo = try #require(NSImage(named: name))
            #expect(!logo.isTemplate)
            let shown = PasswordManagerLogo.image(bundleIDs: kind.appBundleIDs, asset: name, size: 20, appURL: Self.nothingInstalled)
            #expect(!shown.isTemplate, "\(kind.displayName) fell back to a symbol")
            #expect(shown.size == NSSize(width: 20, height: 20))
        }
        let apple = try #require(NSImage(named: PasswordManagerLogo.applePasswordsAsset))
        #expect(!apple.isTemplate)
        // Coincide's own logins show Coincide's icon, which is always there.
        #expect(!PasswordManagerLogo.image(for: .coincide, size: 20).isTemplate)
    }

    @Test func resizingALogoLeavesTheSharedImageAlone() throws {
        let asset = try #require(PasswordManagerLogo.assetName(.onePassword))
        let before = try #require(NSImage(named: asset)).size
        _ = PasswordManagerLogo.image(bundleIDs: [], asset: asset, size: 13, appURL: Self.nothingInstalled)
        #expect(NSImage(named: asset)?.size == before)
    }

    @Test func aBrowserWithoutItsAppSaysSo() throws {
        let chrome = try #require(BrowserCatalog.all.first { $0.id == "chrome" })
        let duck = try #require(BrowserCatalog.all.first { $0.id == "duckduckgo" })
        let app = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        let profile = BrowserCatalog.Profile(name: "Default", folder: URL(fileURLWithPath: "/tmp/Default"))
        func caption(_ definition: BrowserCatalog.Definition, _ appURL: URL?, _ status: BrowserCatalog.Status,
                     profiles: [BrowserCatalog.Profile] = [profile]) -> String? {
            BrowserSourceLabel.caption(BrowserCatalog.Detected(definition: definition, appURL: appURL, profiles: profiles,
                status: status, kinds: [.cookies]))
        }
        #expect(caption(chrome, app, .available) == nil)
        #expect(caption(chrome, nil, .available) == "Not installed")
        #expect(caption(chrome, app, .needsFullDiskAccess, profiles: []) == "Needs Full Disk Access")
        #expect(caption(chrome, nil, .needsFullDiskAccess, profiles: []) == "Not installed · Needs Full Disk Access")
        #expect(caption(chrome, nil, .available, profiles: [profile, profile]) == "Not installed · Profiles: 2")
        #expect(caption(duck, nil, .unsupported(.encryptedStore))
            == "Not installed · \(BrowserImportSheet.reason(.encryptedStore))")
    }

    /// Renders the import list with every catalog browser and the password manager rows, installed and not, in light
    /// and dark, when `COINCIDE_LOGOS_PNG_DIR` names a folder (`TEST_RUNNER_COINCIDE_LOGOS_PNG_DIR` through xcodebuild).
    @Test func rendersTheRows() throws {
        guard let folder = ProcessInfo.processInfo.environment["COINCIDE_LOGOS_PNG_DIR"], !folder.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let profile = BrowserCatalog.Profile(name: "Default", folder: URL(fileURLWithPath: "/tmp/Default"))
        var browsers = BrowserCatalog.all.map { definition -> BrowserCatalog.Detected in
            let status: BrowserCatalog.Status =
                if case .unsupported(let reason) = definition.engine { .unsupported(reason) } else { .available }
            return BrowserCatalog.Detected(definition: definition, appURL: nil, profiles: [profile], status: status, kinds: [.cookies])
        }
        // Installed apps keep their own icons; Safari is on every Mac.
        if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
            browsers.insert(BrowserCatalog.Detected(definition: BrowserCatalog.all.first { $0.id == "safari" }!, appURL: safari,
                profiles: [], status: .needsFullDiskAccess, kinds: [.cookies]), at: 0)
        }
        let half = (browsers.count + 1) / 2
        let columns = [Array(browsers[..<half]), Array(browsers[half...])]
        let list = HStack(alignment: .top, spacing: 16) {
            ForEach(columns.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(columns[index]) { BrowserSourceLabel(source: $0).padding(.horizontal, 10).padding(.vertical, 4) }
                }
                .frame(width: 330, alignment: .leading)
            }
        }
        try render(list, size: NSSize(width: 700, height: CGFloat(half) * 40 + 20), name: "browsers", folder: folder)

        let installed = { (id: String) in NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }
        var managers: [(NSImage, String, String)] = []
        for kind in PasswordManagerKind.allCases {
            if kind == .coincide {
                managers.append((PasswordManagerLogo.image(for: kind, size: 20), kind.displayName, "Coincide’s icon"))
                continue
            }
            let asset = PasswordManagerLogo.assetName(kind)
            managers.append((PasswordManagerLogo.image(bundleIDs: kind.appBundleIDs, asset: asset, size: 20, appURL: Self.nothingInstalled),
                kind.displayName, "Bundled logo"))
            if kind.appBundleIDs.contains(where: { installed($0) != nil }) {
                managers.append((PasswordManagerLogo.image(for: kind, size: 20), kind.displayName, "Installed app’s icon"))
            }
        }
        managers.append((PasswordManagerLogo.image(bundleIDs: [], asset: PasswordManagerLogo.applePasswordsAsset, size: 20,
            appURL: Self.nothingInstalled), "Apple Passwords", "Bundled logo"))
        managers.append((PasswordManagerLogo.applePasswords(size: 20), "Apple Passwords", "Installed app’s icon"))
        let rows = VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(managers.enumerated()), id: \.offset) { _, row in
                PasswordManagerLabel(logo: row.0, name: row.1, caption: row.2)
            }
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
        try render(rows, size: NSSize(width: 360, height: CGFloat(managers.count) * 42 + 24), name: "passwords", folder: folder)
    }

    private func render(_ content: some View, size: NSSize, name: String, folder: String) throws {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = NSHostingView(rootView: content.frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color(nsColor: Theme.contentBackground)))
            view.frame = NSRect(origin: .zero, size: size)
            view.appearance = NSAppearance(named: appearance)
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(suffix).png"))
        }
    }
}
