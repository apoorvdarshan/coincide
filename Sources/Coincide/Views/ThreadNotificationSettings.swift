import CoincideCore
import SwiftUI

struct ThreadNotificationSettings: View {
    @Bindable var notifications: NativeThreadNotifications
    var body: some View {
        SettingsCard(title: "Conversation activity") {
            SettingsRow(title: "Notifications", subtitle: "Get notified when a chat finishes or needs input while Coincide is in the background. Sounds also play while the app is active.") {
                SettingsMenu(label: notifications.mode.title) {
                    ForEach(ThreadNotificationMode.allCases) { mode in
                        Button(mode.title) { Task { await notifications.setMode(mode) } }
                    }
                }.accessibilityLabel("When a thread finishes or needs input").disabled(notifications.isRequesting)
            }
            if notifications.mode.showsNotifications {
                SettingsDivider()
                SettingsRow(title: "Permission", subtitle: LocalizedStringKey(notifications.permission)) {
                    Button("Check permission") { Task { await notifications.refreshPermission() } }
                        .buttonStyle(SettingsActionButtonStyle()).disabled(notifications.isRequesting)
                }
            }
            if let error = notifications.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).padding(.bottom, 14)
            }
        }.task { await notifications.refreshPermission() }
    }
}
