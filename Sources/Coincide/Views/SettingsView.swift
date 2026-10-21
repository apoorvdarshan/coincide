import CoincideCore
import SwiftUI

struct SettingsView: View {
    @Bindable var store: WorkspaceStore
    @AppStorage("appearance") private var appearance = "system"
    @State private var provider = ProviderKind.codex
    var body: some View {
        TabView {
            Form {
                Picker("Provider", selection: $provider) { ForEach(ProviderKind.allCases) { Text($0.name).tag($0) } }
                LabeledContent("CLI", value: ProcessChannel.findExecutable(provider.executable)?.path ?? "Not installed")
                Text("Coincide uses each provider’s existing CLI sign-in and settings on this Mac.").foregroundStyle(.secondary)
                Button(store.isRefreshingModels ? "Refreshing…" : "Refresh Available Models") { Task { await store.refreshModels(provider: provider) } }.disabled(store.isRefreshingModels)
                LabeledContent("Available models", value: "\(store.models(for: provider).count)")
                Divider()
                Text("Additional T3 Code providers are being ported. See the feature parity document for current implementation status.").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped).tabItem { Label("Providers", systemImage: "cpu") }
            Form {
                Picker("Appearance", selection: $appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
                LabeledContent("Version", value: "0.1.0 (development)")
                Link("Source Code", destination: URL(string: "https://github.com/apoorvdarshan/coincide")!)
                Link("T3 Code", destination: URL(string: "https://github.com/pingdotgg/t3code")!)
                Text("Coincide is an independent Swift port. T3 Code source is copyright © 2026 T3 Tools Inc., distributed under the MIT license.").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "gear") }
        }.padding().frame(width: 550, height: 350)
    }
}
