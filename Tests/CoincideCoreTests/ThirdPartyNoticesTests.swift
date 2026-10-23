import Foundation
import Testing
@testable import CoincideCore

private let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private var docs: URL { checkout.appendingPathComponent("docs", isDirectory: true) }

@Test func thirdPartyNoticesCoverEveryResolvedPackageWithItsPinnedVersion() throws {
    let manifest = try ThirdPartyNotices.load(directory: docs)
    struct Resolved: Decodable { struct Pin: Decodable { struct State: Decodable { let version: String? }; let identity: String; let state: State }; let pins: [Pin] }
    let resolved = try JSONDecoder().decode(Resolved.self, from: Data(contentsOf: checkout.appendingPathComponent("Package.resolved")))
    let excluded = Set(manifest.excludedPins.map(\.identity))
    #expect(manifest.excludedPins.allSatisfy { !$0.reason.isEmpty })
    for pin in resolved.pins {
        if excluded.contains(pin.identity) { continue }
        let package = manifest.packages.first { $0.resolvedIdentity == pin.identity }
        #expect(package != nil, "Package.resolved pin \(pin.identity) has no notice entry.")
        #expect(package?.version == pin.state.version, "\(pin.identity) notice version differs from Package.resolved.")
    }
    let identities = Set(resolved.pins.map(\.identity))
    #expect(manifest.packages.compactMap(\.resolvedIdentity).allSatisfy(identities.contains), "Manifest names a package that is not resolved.")
    #expect(excluded.isSubset(of: identities))
}

@Test func thirdPartyNoticeFilesExistAndEveryBundledNoticeIsReferenced() throws {
    let manifest = try ThirdPartyNotices.load(directory: docs)
    let referenced = Set(manifest.packages.flatMap(\.noticeFiles))
    for name in referenced {
        let text = try ThirdPartyNotices.noticeText(name, directory: docs)
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(name) is empty.")
    }
    let shipped = try FileManager.default.contentsOfDirectory(atPath: docs.path).filter { $0.hasSuffix("-LICENSE.txt") || $0.hasSuffix("-NOTICE.txt") }
    #expect(Set(shipped) == referenced, "Every bundled notice text must belong to a manifest entry.")
    for package in manifest.packages {
        #expect(!package.license.isEmpty && !package.components.isEmpty && package.sourceURL.scheme == "https", "\(package.id)")
        if package.distribution == .bundled { #expect(!package.noticeFiles.isEmpty, "\(package.id) ships without a notice.") }
    }
}

@Test func thirdPartyNoticeSearchAndValidationAreBounded() throws {
    let manifest = try ThirdPartyNotices.load(directory: docs)
    #expect(manifest.filtered("").count == manifest.packages.count)
    #expect(manifest.filtered("swiftterm").map(\.id) == ["swiftterm"])
    #expect(manifest.filtered("apache markdown").map(\.id) == ["swift-markdown"])
    #expect(manifest.filtered("installed on demand").map(\.id).sorted() == ["antigravity-managed-runtime", "codex-managed-runtime"])
    #expect(manifest.filtered("no such component").isEmpty)
    #expect(manifest.filtered("1.99.1").map(\.id) == ["swiftterm"])
    #expect(throws: CoincideError.self) { try ThirdPartyNotices.noticeText("../Package.swift", directory: docs) }
    let invalid = Data(#"{"version":1,"packages":[{"id":"x","name":"x","version":"1","license":"MIT","components":["App"],"distribution":"bundled","noticeFiles":["../secret"],"sourceURL":"https://example.com"}],"excludedPins":[]}"#.utf8)
    #expect(throws: CoincideError.self) { try ThirdPartyNotices.decode(invalid) }
}
