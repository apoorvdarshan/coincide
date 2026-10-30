import AppKit
import CoincideKit
import SwiftUI

/// Settings › General › Command Line: whether the `coincide` tool may drive Coincide, and installing it for Terminal.
struct CommandLineSettingsRows: View {
    let model: SettingsModel
    var control = CommandLineControl.shared

    var body: some View {
        Toggle(isOn: model.binding(\.commandLineControl)) {
            Text("Command-line control")
            Text("The coincide command lists, starts and steers threads, and answers their approvals and questions, through a private connection on this Mac. Agents Coincide starts can run it, so they can start other agents, as you can.")
        }
        LabeledContent {
            if control.terminalInstallation?.isOnPath == true {
                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
            } else if control.terminalError != nil || control.terminalInstallation != nil {
                Label("Unavailable", systemImage: "exclamationmark.circle").foregroundStyle(Color(nsColor: Theme.failure))
            } else {
                ProgressView().controlSize(.small)
            }
        } label: {
            Text("Use it in Terminal")
            if let installation = control.terminalInstallation {
                let installed = (installation.url.path as NSString).abbreviatingWithTildeInPath
                Text("Installed at \(installed). Run coincide help to see what it does.")
                if !installation.isOnPath {
                    let folder = (installation.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
                    Text("Add \(folder) to your shell’s PATH to use coincide in Terminal.")
                }
            } else if let failure = control.terminalError {
                Text(failure).foregroundStyle(Color(nsColor: Theme.failure))
            } else {
                Text("Coincide sets up the Terminal command automatically. Agents already have it.")
            }
        }
        .onAppear { control.refreshTerminalInstallation() }
    }

}
