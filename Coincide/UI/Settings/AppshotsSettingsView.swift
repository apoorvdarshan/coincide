import AppKit
import CoincideKit
import SwiftUI

/// Settings › Appshots: both ⌘ keys capture the frontmost window of another app into a chat, as in ChatGPT.
struct AppshotsSettingsView: View {
    @Bindable var controller: AppshotController
    @State private var isRecording = false

    init(controller: AppshotController = .shared) {
        self.controller = controller
    }

    var body: some View {
        Form {
            Section {
                SettingsPaneHeader(title: SettingsSection.appshots.title) {
                    SettingsIconTile(symbol: SettingsSection.appshots.symbolName, color: SettingsSection.appshots.tint, size: 44)
                } subtitle: {
                    Text("Capture the window you’re working in and ask an agent about it.")
                }
            }

            Section {
                Toggle(isOn: $controller.enabled) {
                    Text("Turn on Appshots")
                    Text("Capture the frontmost window of the app you’re using and attach it to a chat in Coincide, ready for your question.")
                }
                ThemedPicker(
                    selection: $controller.trigger,
                    options: [
                        .init(.bothCommandKeys, String(localized: "Both ⌘ keys")),
                        .init(.shortcut, String(localized: "Custom shortcut")),
                    ]
                ) {
                    Text("Take an appshot with")
                    Text(triggerCaption)
                }
                if controller.trigger == .shortcut {
                    shortcutRow
                }
                Toggle(isOn: $controller.includesWindowText) {
                    Text("Include the window’s text")
                    Text("Adds the text the app makes available in that window, read through Accessibility, as a card beside the picture.")
                }
                Toggle(isOn: $controller.playsSound) {
                    Text("Play a sound")
                    Text("Plays the screenshot sound when an appshot is taken, at your alert volume.")
                }
                LabeledContent("Status") {
                    Text(controller.stateDescription)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section {
                PrivacyPermissionRow(
                    title: "Screen Recording",
                    detail: "Lets Coincide capture the frontmost window. Appshots never capture the whole screen.",
                    granted: controller.screenRecordingGranted,
                    grantLabel: "Grant Screen Recording access",
                    settingsLabel: "Open Screen Recording settings",
                    request: controller.requestScreenRecording,
                    openSettings: controller.openScreenRecordingSettings)
                PrivacyPermissionRow(
                    title: "Accessibility",
                    detail: accessibilityDetail,
                    granted: controller.accessibilityGranted,
                    grantLabel: "Grant Accessibility access",
                    settingsLabel: "Open Accessibility settings",
                    request: controller.requestAccessibility,
                    openSettings: controller.openAccessibilitySettings)
                Text("Grant these permissions to Coincide in System Settings. Return here to refresh their status.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Permissions")
            }

            Section {
                Text("Appshots never send anything on their own: the picture waits in the composer until you send your message. If you used a thread in the last minute, the appshot goes there; otherwise it starts a new chat.")
                Text("Coincide captures only the frontmost window, never the whole screen or other windows. It skips its own windows, windows that ask not to be captured, and apps where you’re typing a password. Captures are kept with Coincide’s other attachments on this Mac, and agents see them only when you send them.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Privacy")
            }

            if let outcome = controller.lastOutcome, !outcome.isAdded {
                Section {
                    Text(outcome.message)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } header: {
                    Text("Last appshot")
                }
            }
        }
        .formStyle(.grouped)
        .task { controller.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refresh()
        }
    }

    private var triggerCaption: String {
        switch controller.trigger {
        case .bothCommandKeys:
            String(localized: "Press the left and right ⌘ keys together, without other keys.")
        case .shortcut:
            String(localized: "A shortcut works in every app, and needs no Accessibility access.")
        }
    }

    private var accessibilityDetail: LocalizedStringKey {
        switch (controller.trigger, controller.includesWindowText) {
        case (.bothCommandKeys, true):
            "Lets Coincide notice both ⌘ keys while you use other apps, and read the window’s text."
        case (.bothCommandKeys, false):
            "Lets Coincide notice both ⌘ keys while you use other apps."
        case (.shortcut, true):
            "Lets Coincide read the window’s text."
        case (.shortcut, false):
            "Not needed with a custom shortcut and without the window’s text."
        }
    }

    private var shortcutRow: some View {
        let fieldHeight = ShortcutRecorderView.height
        let fieldBaseline = ShortcutRecorderView.baselineOffset
        return LabeledContent {
            ShortcutRecorder(
                shortcut: controller.shortcut, commandTitle: String(localized: "Take an appshot"),
                onRecordingChange: { recording in
                    isRecording = recording
                    controller.isRecordingShortcut = recording
                },
                onRecordKeyCode: { shortcut, keyCode in controller.setShortcut(shortcut, keyCode: keyCode) },
                onChange: { shortcut in if shortcut == nil { controller.setShortcut(nil, keyCode: nil) } }
            )
            .frame(width: ShortcutRecorderView.width, height: fieldHeight)
            .alignmentGuide(.firstTextBaseline) { d in (d.height - fieldHeight) / 2 + fieldBaseline }
        } label: {
            Text("Shortcut")
            Text(
                isRecording
                    ? String(localized: "Press the new shortcut. Delete removes it; Escape cancels.")
                    : String(localized: "Use ⌘ or ⌃ with a key, such as ⌃⌥⌘S."))
        }
    }
}
