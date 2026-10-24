import CoincideCore
import SwiftUI

/// General settings for the conversation transcript.
struct TranscriptSettings: View {
    @AppStorage(TranscriptPreferences.timestampFormatKey) private var timestampFormat = TranscriptTimestampFormat.system.rawValue
    @AppStorage(TranscriptPreferences.foldCompletedRunsKey) private var foldCompletedRuns = true
    var body: some View {
        SettingsRow(title: "Timestamps", subtitle: "Choose how message times appear in conversations.") {
            SettingsMenu(label: TranscriptTimestampFormat(rawValue: timestampFormat)?.title ?? TranscriptTimestampFormat.system.title) {
                ForEach(TranscriptTimestampFormat.allCases) { format in
                    Button(format.title) { timestampFormat = format.rawValue }
                }
            }.accessibilityLabel("Timestamp format").accessibilityIdentifier("settings-timestamp-format")
        }
        SettingsDivider()
        SettingsRow(title: "Collapse finished work", subtitle: "Group completed tool calls and reasoning under “Worked for …”. Open the row to see them again.") {
            Toggle("Collapse finished work", isOn: $foldCompletedRuns).labelsHidden()
                .accessibilityIdentifier("settings-fold-completed-runs")
        }
    }
}
