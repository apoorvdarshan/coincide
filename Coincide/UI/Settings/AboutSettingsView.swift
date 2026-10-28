import AppKit
import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 112, height: 112)
                        .accessibilityHidden(true)
                    Text(verbatim: "Coincide")
                        .font(.system(size: 26, weight: .semibold))
                    Text("Version \(Self.version) (\(Self.build))")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("One window for the coding agents you already use. Switch agents mid-thread while each keeps its own session.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 400)
                        .padding(.top, 4)
                    SettingsCopyButton(text: Self.versionReport, label: "Copy Version Info")
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section {
                AboutLink(
                    symbol: "chevron.left.forwardslash.chevron.right", color: .gray, title: String(localized: "Source Code"),
                    detail: "github.com/apoorvdarshan/coincide", url: "https://github.com/apoorvdarshan/coincide")
                AboutLink(
                    symbol: "ladybug.fill", color: .red, title: String(localized: "Report an Issue"),
                    detail: String(localized: "Bugs and feature requests on GitHub"),
                    url: "https://github.com/apoorvdarshan/coincide/issues")
            }

            Section("Follow") {
                AboutLink(
                    symbol: "at", color: .black, title: "X", detail: "@apoorvdarshan", url: "https://x.com/apoorvdarshan")
                AboutLink(
                    symbol: "camera.fill", color: .pink, title: "Instagram", detail: "@apoorvcodes",
                    url: "https://www.instagram.com/apoorvcodes")
            }

            Section("Acknowledgements") {
                Text("Coincide is a native macOS port of T3 Code, the open-source agent app by T3 Tools Inc., and is used under the MIT License.")
                AboutLink(
                    symbol: "arrow.triangle.branch", color: .indigo, title: "T3 Code", detail: "github.com/pingdotgg/t3code",
                    url: "https://github.com/pingdotgg/t3code")
                DisclosureGroup("T3 Code License") {
                    Text(verbatim: Self.t3CodeLicense)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
            }

            if let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String {
                Section {
                    Text(copyright)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .formStyle(.grouped)
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    private static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    }

    /// "Coincide 0.1.0 (1), macOS 27.0.1", for bug reports.
    private static var versionReport: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "Coincide \(version) (\(build)), macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    private static let t3CodeLicense = """
        MIT License

        Copyright (c) 2026 T3 Tools Inc.

        Permission is hereby granted, free of charge, to any person obtaining a copy of this software and \
        associated documentation files (the "Software"), to deal in the Software without restriction, including \
        without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
        copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the \
        following conditions:

        The above copyright notice and this permission notice shall be included in all copies or substantial \
        portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT \
        LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO \
        EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER \
        IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE \
        USE OR OTHER DEALINGS IN THE SOFTWARE.
        """
}

/// A row that opens a web page.
private struct AboutLink: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    let url: String
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let destination = URL(string: url) { openURL(destination) }
        } label: {
            HStack(spacing: 10) {
                SettingsIconTile(symbol: symbol, color: color, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url)
        .accessibilityHint(Text("Opens \(url) in your browser"))
    }
}
