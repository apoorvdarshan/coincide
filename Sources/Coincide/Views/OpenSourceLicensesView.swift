import AppKit
import CoincideCore
import SwiftUI

/// Searchable notices for bundled, system and on-demand components (T3 OpenSourceLicenses).
struct OpenSourceLicensesView: View {
    private let manifest: ThirdPartyNotices?
    private let directory: URL?
    private let loadError: String?
    @State private var query = ""
    @State private var selection: String?

    init(directory: URL?) {
        self.directory = directory
        do {
            guard let directory else { throw CoincideError("Notices are bundled with the packaged app.") }
            manifest = try ThirdPartyNotices.load(directory: directory); loadError = nil
        } catch { manifest = nil; loadError = error.localizedDescription }
    }

    init(manifest: ThirdPartyNotices, directory: URL?) {
        self.manifest = manifest; self.directory = directory; loadError = nil
    }

    private var packages: [ThirdPartyNotices.Package] { manifest?.filtered(query) ?? [] }

    var body: some View {
        if let manifest {
            NavigationSplitView {
                List(packages, selection: $selection) { package in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(package.name).fontWeight(.medium)
                        Text("\(package.version) · \(package.license)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.tag(package.id).accessibilityIdentifier("license-row-\(package.id)")
                }
                .searchable(text: $query, placement: .sidebar, prompt: Text("Name, version, license or part"))
                .overlay { if packages.isEmpty { ContentUnavailableView.search(text: query) } }
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
            } detail: {
                if let package = manifest.packages.first(where: { $0.id == selection }) ?? packages.first {
                    LicenseDetailView(package: package, directory: directory).id(package.id)
                } else {
                    ContentUnavailableView("Select a Component", systemImage: "doc.text")
                }
            }
            .accessibilityIdentifier("open-source-licenses")
        } else {
            ContentUnavailableView("Licenses Unavailable", systemImage: "doc.text.magnifyingglass", description: Text(loadError ?? ""))
                .padding()
        }
    }
}

struct LicenseDetailView: View {
    let package: ThirdPartyNotices.Package
    let directory: URL?
    @State private var texts: [(name: String, text: String)] = []
    @State private var failure: String?

    private var distribution: String {
        switch package.distribution {
        case .bundled: String(localized: "Included in Coincide")
        case .system: String(localized: "Provided by macOS")
        case .onDemand: String(localized: "Installed on demand")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(package.name).font(.title2.bold()).textSelection(.enabled)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text("Version").foregroundStyle(.secondary); Text(package.version).textSelection(.enabled) }
                    GridRow { Text("License").foregroundStyle(.secondary); Text(package.license).textSelection(.enabled) }
                    GridRow { Text("Used by").foregroundStyle(.secondary); Text(package.components.joined(separator: ", ")) }
                    GridRow { Text("Distribution").foregroundStyle(.secondary); Text(distribution) }
                }.font(.callout)
                if let detail = package.detail { Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Link("Source", destination: package.sourceURL)
                if let failure { Text(failure).font(.callout).foregroundStyle(.secondary) }
                ForEach(texts, id: \.name) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.name).font(.headline)
                            Spacer()
                            Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.text, forType: .string) }
                                .accessibilityLabel(Text("Copy \(item.name)"))
                        }
                        Text(item.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: package.id) {
            guard let directory else { texts = []; return }
            let names = package.noticeFiles
            let task = Task.detached(priority: .utility) { () -> ([(name: String, text: String)], String?) in
                var loaded: [(name: String, text: String)] = [], failure: String?
                for name in names {
                    guard !Task.isCancelled else { break }
                    do { loaded.append((name, try ThirdPartyNotices.noticeText(name, directory: directory))) }
                    catch { failure = String(localized: "\(name) is missing from this build.") }
                }
                return (loaded, failure)
            }
            let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled else { return }
            texts = result.0; failure = result.1
        }
    }
}
