import CoincideRemoteKit
import StoreKit
import SwiftUI
import UIKit

/// Help & Community on the phone, as in the Mac's Settings › About: each `CommunityLink` with its title and tile. A bug
/// report's GitHub form has the versions of both apps and both systems filled in.
extension CommunityLink {
    var title: String {
        switch self {
        case .getHelp: String(localized: "Get Help")
        case .reportIssue: String(localized: "Report an Issue")
        case .requestFeature: String(localized: "Request a Feature")
        case .joinDiscord: String(localized: "Join the Discord")
        case .starOnGitHub: String(localized: "Star on GitHub")
        case .x: "X"
        case .instagram: "Instagram"
        case .linkedIn: "LinkedIn"
        case .contact: String(localized: "Contact")
        case .privacyPolicy: String(localized: "Privacy Policy")
        case .termsOfService: String(localized: "Terms of Service")
        }
    }

    /// The account or address shown at the row's end.
    var detail: String? {
        switch self {
        case .x: CoincideLinks.xHandle
        case .instagram: CoincideLinks.instagramHandle
        case .contact: CoincideLinks.contactEmail
        default: nil
        }
    }

    var symbol: String {
        switch self {
        case .getHelp: "questionmark.bubble.fill"
        case .reportIssue: "ladybug.fill"
        case .requestFeature: "lightbulb.fill"
        case .joinDiscord: "bubble.left.and.bubble.right.fill"
        case .starOnGitHub: "star.fill"
        case .x: "at"
        case .instagram: "camera.fill"
        case .linkedIn: "person.2.fill"
        case .contact: "envelope.fill"
        case .privacyPolicy: "hand.raised.fill"
        case .termsOfService: "doc.text.fill"
        }
    }

    /// The tile's color, by `MacSettingsLabel.color` name.
    var color: String {
        switch self {
        case .getHelp: "teal"
        case .reportIssue: "red"
        case .requestFeature: "orange"
        case .joinDiscord: "indigo"
        case .starOnGitHub: "gray"
        case .x: "black"
        case .instagram: "pink"
        case .linkedIn: "blue"
        case .contact: "cyan"
        case .privacyPolicy: "blue"
        case .termsOfService: "gray"
        }
    }

    /// Words Settings search also finds the link by.
    var keywords: [String] {
        switch self {
        case .getHelp: [String(localized: "Help"), "discord", "support", "question"]
        case .reportIssue: [String(localized: "Bug"), String(localized: "Feedback"), "GitHub", "Discord", "bug", "issue"]
        case .requestFeature: [String(localized: "Idea"), String(localized: "Feedback"), "GitHub", "Discord", "feature"]
        case .joinDiscord: ["Discord", "community", "server"]
        case .starOnGitHub: ["GitHub", "source", "open source", "MIT"]
        case .x: ["twitter", "follow", CoincideLinks.xHandle]
        case .instagram: ["follow", CoincideLinks.instagramHandle]
        case .linkedIn: ["follow"]
        case .contact: ["email", "mail", CoincideLinks.contactEmail]
        case .privacyPolicy: ["privacy", "legal"]
        case .termsOfService: ["terms", "legal"]
        }
    }

    /// The heading the links of `group` are under.
    static func title(of group: Group) -> String {
        switch group {
        case .community: String(localized: "Help & Community")
        case .follow: String(localized: "Follow")
        case .contact: String(localized: "Contact & Legal")
        }
    }

    /// What the GitHub or Discord question explains.
    var choiceMessage: String {
        switch self {
        case .reportIssue:
            String(localized: "Fill in the bug report form on GitHub, or use /bug in the bug reports channel on Discord. Channel links work once you’ve joined the server. Reports sent on Discord become public GitHub issues and need no GitHub account.")
        case .requestFeature:
            String(localized: "Fill in the feature request form on GitHub, or use /feature in the feature requests channel on Discord. Channel links work once you’ve joined the server. Requests sent on Discord become public GitHub issues and need no GitHub account.")
        default: ""
        }
    }

    /// Where the link goes from the phone. A bug report's form names the Mac's Coincide and macOS from its About pane
    /// when the phone has read it, and this app's and this device's own versions.
    func remoteURL(_ client: RemoteClient) -> URL {
        guard self == .reportIssue else { return url() }
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

/// Settings' Help & Community, Follow, and Contact & Legal rows at the foot of the sidebar, with Rate Coincide Remote
/// among the first.
struct HelpCommunityRows: View {
    var body: some View {
        ForEach(CommunityLink.Group.allCases, id: \.self) { group in
            SidebarHeader(Text(CommunityLink.title(of: group))).sidebarRow()
            ForEach(CommunityLink.links(in: group)) { link in CommunityLinkRow(link: link) }
            if group == .community { RateRemoteRow() }
        }
    }
}

/// One link in the sidebar's look, with the arrow of a row that leaves the app. Report an Issue and Request a Feature
/// ask GitHub or Discord first.
struct CommunityLinkRow: View {
    let link: CommunityLink
    @Environment(RemoteClient.self) private var client
    @Environment(\.openURL) private var openURL
    @State private var isChoosing = false

    var body: some View {
        Button {
            if link.discordChannel == nil { openURL(link.remoteURL(client)) } else { isChoosing = true }
        } label: {
            SettingsTileLabel(title: link.title, symbol: link.symbol, color: link.color, detail: link.detail, opensLink: true)
        }
        .buttonStyle(SidebarRowButtonStyle())
        .accessibilityHint(hint)
        .confirmationDialog(link.title, isPresented: $isChoosing, titleVisibility: .visible) {
            Button("GitHub") { openURL(link.remoteURL(client)) }
            if let discord = link.discordChannel {
                Button("Discord") { openURL(discord) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(link.choiceMessage)
        }
        .sidebarRow()
    }

    private var hint: Text {
        switch link {
        case .reportIssue, .requestFeature: Text("Asks whether to use GitHub or Discord")
        case .contact: Text("Writes an email to \(CoincideLinks.contactEmail)")
        default: Text("Opens in your browser")
        }
    }
}

/// Rate Coincide Remote: iOS's review prompt, or the App Store's review page when the prompt was asked for recently
/// and the app has one (`RemoteReview`). Only on a tap; the app never asks by itself.
struct RateRemoteRow: View {
    @Environment(\.requestReview) private var requestReview
    @Environment(\.openURL) private var openURL
    @AppStorage("review.lastPrompt") private var lastPrompt: Double = 0

    var body: some View {
        Button {
            let last = lastPrompt > 0 ? Date(timeIntervalSince1970: lastPrompt) : nil
            if let page = RemoteReview.storePage(lastPrompt: last) {
                openURL(page)
            } else {
                lastPrompt = Date().timeIntervalSince1970
                requestReview()
            }
        } label: {
            SettingsTileLabel(title: String(localized: "Rate Coincide Remote"), symbol: "star.bubble.fill", color: "yellow")
        }
        .buttonStyle(SidebarRowButtonStyle())
        .accessibilityHint(Text("Asks iOS to show its review prompt"))
        .sidebarRow()
    }
}
