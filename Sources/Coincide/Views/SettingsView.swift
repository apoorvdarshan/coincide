import CoincideCore
import SwiftUI

struct SettingsView: View {
    @Bindable var store: WorkspaceStore
    @AppStorage("appearance") private var appearance = "system"
    var body: some View {
        TabView {
            Form {
                LabeledContent("Codex CLI", value: ProcessChannel.findExecutable("codex")?.path ?? "Not installed")
                Text("Coincide uses Codex CLI’s existing sign-in and settings. Run codex login in Terminal if sign-in is required.").foregroundStyle(.secondary)
                Button(store.isRefreshingModels ? "Refreshing…" : "Refresh Available Models") { Task { await store.refreshModels() } }.disabled(store.isRefreshingModels)
                LabeledContent("Available models", value: "\(store.models.count)")
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
