import CoincideCore
import SwiftUI

/// General settings for the conversation transcript.
struct TranscriptSettings: View {
    @AppStorage(TranscriptPreferences.timestampFormatKey) private var timestampFormat = TranscriptTimestampFormat.system.rawValue
    @AppStorage(TranscriptPreferences.foldCompletedRunsKey) private var foldCompletedRuns = true
    var body: some View {
        Picker("Timestamp format", selection: $timestampFormat) {
            ForEach(TranscriptTimestampFormat.allCases) { Text($0.title).tag($0.rawValue) }
        }.accessibilityIdentifier("settings-timestamp-format")
        Toggle("Collapse finished work", isOn: $foldCompletedRuns)
            .accessibilityIdentifier("settings-fold-completed-runs")
        Text("A finished turn's tool calls and reasoning fold under “Worked for …”. Select the row to show them again.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
