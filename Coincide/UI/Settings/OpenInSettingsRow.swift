import AppKit
import CoincideKit
import SwiftUI

/// Settings › General's "Open project folders in": the app the rail's Open In button, File › Open in Editor and its
/// shortcut use. Automatic (nil) follows the first installed editor; picking an app from any Open In menu sets it too.
struct OpenInSettingsRow: View {
    @Binding var selection: String?
    var targets: [OpenTarget] = OpenTargets.installed

    /// One entry of the picker.
    struct Choice: Equatable {
        var value: String?
        var title: String
        var image: NSImage?
        var group: String?
    }

    var body: some View {
        ThemedPicker(
            selection: $selection,
            options: Self.choices(targets: targets, selection: selection).map { .init($0.value, $0.title, image: $0.image, group: $0.group) }
        ) {
            Text("Open project folders in")
            Text(caption)
        }
    }

    private var caption: String {
        guard selection == nil, let automatic = OpenTargets.automatic(among: targets) else {
            return String(localized: "The Open In button in the rail opens the thread’s folder in this app. Right-click the button to pick another.")
        }
        return String(localized: "Automatic opens \(automatic.name). Right-click the Open In button in the rail to pick another app.")
    }

    /// Automatic, then the installed apps grouped as the Open In menus group them, each with its icon. A chosen app
    /// that is no longer installed stays listed after Automatic, so the picker still shows what is saved.
    static func choices(targets: [OpenTarget], selection: String?) -> [Choice] {
        var choices = [Choice(value: nil, title: String(localized: "Automatic (first installed editor)"))]
        if let selection, !targets.contains(where: { $0.bundleID == selection }) {
            let name = OpenTargets.name(forBundleID: selection) ?? selection
            choices.append(Choice(value: selection, title: String(localized: "\(name) (not installed)")))
        }
        let groups: [(OpenTarget.Kind, String)] = [
            (.editor, String(localized: "Editors")), (.terminal, String(localized: "Terminals")),
            (.fileManager, String(localized: "File Manager")),
        ]
        for (kind, header) in groups {
            for target in targets where target.kind == kind {
                choices.append(Choice(value: target.bundleID, title: target.name, image: target.icon, group: header))
            }
        }
        return choices
    }
}
