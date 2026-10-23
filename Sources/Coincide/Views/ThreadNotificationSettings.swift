import CoincideCore
import SwiftUI

struct ThreadNotificationSettings: View {
    @Bindable var notifications: NativeThreadNotifications
    var body: some View {
        Section("Thread notifications") {
            Picker("When a thread finishes or needs input", selection: Binding(
                get: { notifications.mode }, set: { mode in Task { await notifications.setMode(mode) } })) {
                ForEach(ThreadNotificationMode.allCases) { Text($0.title).tag($0) }
            }.disabled(notifications.isRequesting)
            if notifications.mode.showsNotifications {
                LabeledContent("Permission", value: notifications.permission)
                Button("Check Notification Permission") { Task { await notifications.refreshPermission() } }
                    .disabled(notifications.isRequesting)
            }
            Text("Notifications appear while Coincide is in the background and include the thread name. Open one to return to its conversation. Sounds also play while Coincide is active.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = notifications.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.task { await notifications.refreshPermission() }
    }
}
