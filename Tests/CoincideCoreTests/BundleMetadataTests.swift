import Foundation
import Testing

private let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Test func bundleInfoTemplateDeclaresVersionIconLinksCategoryAndPrivacyPurposes() throws {
    let version = try String(contentsOf: checkout.appendingPathComponent("VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil)
    let template = try String(contentsOf: checkout.appendingPathComponent("script/Info.plist.template"), encoding: .utf8)
    let rendered = template.replacingOccurrences(of: "@APP_NAME@", with: "Coincide").replacingOccurrences(of: "@BUNDLE_ID@", with: "com.apoorvdarshan.coincide")
        .replacingOccurrences(of: "@VERSION@", with: version).replacingOccurrences(of: "@BUILD@", with: "1")
    #expect(!rendered.contains("@"), "Every placeholder is rendered by the build script.")
    let info = try #require(PropertyListSerialization.propertyList(from: Data(rendered.utf8), format: nil) as? [String: Any])
    #expect(info["CFBundleShortVersionString"] as? String == version && info["CFBundleVersion"] as? String == "1")
    #expect(info["CFBundleIdentifier"] as? String == "com.apoorvdarshan.coincide" && info["CFBundleExecutable"] as? String == "Coincide")
    #expect(info["CFBundleIconFile"] as? String == "AppIcon" && info["LSApplicationCategoryType"] as? String == "public.app-category.developer-tools")
    #expect((info["NSHumanReadableCopyright"] as? String)?.contains("T3 Tools") == true && info["LSMinimumSystemVersion"] as? String == "14.0")
    for key in ["NSDocumentsFolderUsageDescription", "NSDesktopFolderUsageDescription", "NSDownloadsFolderUsageDescription",
                "NSRemovableVolumesUsageDescription", "NSNetworkVolumesUsageDescription", "NSLocalNetworkUsageDescription",
                "NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSAppleEventsUsageDescription"] {
        let purpose = info[key] as? String
        #expect(purpose.map { $0.count > 30 && $0.contains("Coincide") } == true, "\(key) needs a purpose string.")
    }
    let urlTypes = try #require(info["CFBundleURLTypes"] as? [[String: Any]])
    #expect(urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] } == ["coincide"])
    let documents = try #require(info["CFBundleDocumentTypes"] as? [[String: Any]])
    #expect((documents.first?["LSItemContentTypes"] as? [String]) == ["public.folder"])
}

@Test func buildScriptRendersTheTemplateGeneratesTheIconAndCopiesTheNoticeManifest() throws {
    let script = try String(contentsOf: checkout.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)
    #expect(script.contains("script/Info.plist.template") && script.contains("plutil -lint"))
    #expect(script.contains("generate_app_icon.swift") && script.contains("iconutil -c icns") && script.contains("Contents/Resources/AppIcon.icns"))
    #expect(script.contains("docs/third-party-notices.json"))
    #expect(script.contains("--build-only") && script.contains("--verify"))
    let generator = try String(contentsOf: checkout.appendingPathComponent("script/generate_app_icon.swift"), encoding: .utf8)
    for name in ["icon_16x16", "icon_32x32@2x", "icon_128x128", "icon_256x256@2x", "icon_512x512@2x"] { #expect(generator.contains("\"\(name)\"")) }
}
