import AppKit
import CoincideKit
import SwiftUI

/// Settings › General › Command Line: whether the `coincide` tool may drive Coincide, and installing it for Terminal.
struct CommandLineSettingsRows: View {
    let model: SettingsModel
    @State private var installed: String?
    @State private var failure: String?

    var body: some View {
        Toggle(isOn: model.binding(\.commandLineControl)) {
            Text("Command-line control")
            Text("The coincide command lists, starts and steers threads, and answers their approvals and questions, through a private connection on this Mac. Agents Coincide starts can run it, so they can start other agents, as you can.")
        }
        LabeledContent {
            Button("Install Command Line Tool…") { install() }
        } label: {
            Text("Use it in Terminal")
            if let installed {
                Text("Installed at \(installed). Run coincide help to see what it does.")
            } else if let failure {
                Text(failure).foregroundStyle(Color(nsColor: Theme.failure))
            } else {
                Text("Links coincide into /usr/local/bin, or ~/.local/bin when that isn’t writable. Agents Coincide starts already have it.")
            }
        }
    }

    private func install() {
        do {
            installed = (try CommandLineControl.installTool().path as NSString).abbreviatingWithTildeInPath
            failure = nil
        } catch {
            failure = error.localizedDescription
            installed = nil
        }
    }
}
