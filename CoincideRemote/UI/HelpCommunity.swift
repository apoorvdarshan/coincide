import CoincideRemoteKit
import SwiftUI
import UIKit

/// Help & Community on the phone, as in the Mac's Settings › About: each `CommunityLink` with its title and tile,
/// opening its GitHub form with the versions of both apps and both systems filled in.
extension CommunityLink {
    var title: String {
        switch self {
        case .reportIssue: String(localized: "Report an Issue")
        case .requestFeature: String(localized: "Request a Feature")
        }
    }

    var symbol: String {
        switch self {
        case .reportIssue: "ladybug.fill"
        case .requestFeature: "lightbulb.fill"
        }
    }

    /// The tile's color, by `MacSettingsLabel.color` name.
    var color: String {
        switch self {
        case .reportIssue: "red"
        case .requestFeature: "orange"
        }
    }

    /// Words Settings search also finds the link by.
    var keywords: [String] {
        switch self {
        case .reportIssue: [String(localized: "Bug"), String(localized: "Feedback"), "GitHub", "bug", "issue"]
        case .requestFeature: [String(localized: "Idea"), String(localized: "Feedback"), "GitHub", "feature"]
        }
    }

    /// The form with versions filled in: the Mac's Coincide and macOS from its About pane when the phone has read it,
    /// and this app's and this device's own.
    func remoteURL(_ client: RemoteClient) -> URL {
        let about = client.macSettings?.page("about")?.sections.flatMap(\.rows) ?? []
        let mac = about.first { $0.id == "about.version" }?.detail ?? client.server?.appVersion
        let macOS = about.first { $0.id == "about.macos" }?.detail.map { "macOS \($0)" }
        let info = Bundle.main.infoDictionary ?? [:]
        let remote = Self.appVersion(info["CFBundleShortVersionString"] as? String, build: info["CFBundleVersion"] as? String)
            ?? RemoteClient.appVersion
        let system = Self.systemVersion(ProcessInfo.processInfo.operatingSystemVersion)
        let systemName = UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        return url(
            coincideVersion: Self.remoteCoincideVersion(mac: mac, remote: remote, system: system, systemName: systemName),
            macOSVersion: macOS)
    }
}

/// Settings' Help & Community rows, under their heading at the foot of the sidebar: each opens its GitHub form in the
/// browser.
struct HelpCommunityRows: View {
    var body: some View {
        SidebarHeader(Text("Help & Community")).sidebarRow()
        ForEach(CommunityLink.allCases) { link in CommunityLinkRow(link: link) }
    }
}

/// One Help & Community link in the sidebar's look, with the arrow of a row that leaves the app.
struct CommunityLinkRow: View {
    let link: CommunityLink
    @Environment(RemoteClient.self) private var client
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(link.remoteURL(client)) } label: {
            SettingsTileLabel(title: link.title, symbol: link.symbol, color: link.color, opensLink: true)
        }
        .buttonStyle(SidebarRowButtonStyle())
        .accessibilityHint(Text("Opens GitHub in your browser"))
        .sidebarRow()
    }
}
