import CoincideKit
import SwiftUI

struct AppUpdateSettingsView: View {
    var updates = AppUpdates.shared
    @State private var model = SettingsModel()
    var body: some View {
        Section("App Updates") {
            Toggle("Check for updates daily", isOn: model.binding(\.checksForAppUpdates))
                .onChange(of: model.settings.checksForAppUpdates) { _, _ in updates.automaticCheck() }
            Text(updates.status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if updates.release != nil && !updates.canInstall {
                Text(AppUpdateError.signing.localizedDescription).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Check for Updates…") { updates.check() }.disabled(updates.busy || updates.state == .armed)
                if updates.state == .available, updates.canInstall {
                    Button("Download Update") { updates.download() }
                }
                if updates.state == .ready {
                    Button("Install on Quit") { updates.installOnQuit() }
                }
                if updates.state == .armed {
                    Button("Cancel Installation") { updates.cancelInstallation() }
                }
            }
            if updates.state == .ready || updates.state == .armed {
                Text("Coincide never quits or reopens automatically. The previous app is kept as a backup.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Show Update Folder") { updates.revealStagedUpdate() }
            }
        }
    }
}
