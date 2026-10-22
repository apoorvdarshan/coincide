import CoincideCore
import SwiftUI

enum ReasoningEffortPresentation {
    static func title(_ id: String) -> String {
        switch id {
        case "none": String(localized: "None")
        case "minimal": String(localized: "Minimal")
        case "low": String(localized: "Low")
        case "medium": String(localized: "Medium")
        case "high": String(localized: "High")
        case "xhigh": String(localized: "Extra High")
        case "max": String(localized: "Maximum")
        case "ultra": String(localized: "Ultra")
        default: id
        }
    }
    static func isModelDefault(thread: CodingThread, model: ProviderModel) -> Bool {
        guard let value = model.codexDefaultReasoningEffort else { return false }
        return thread.codexReasoningPreference(for: model) == nil && thread.reasoningEffort == value
    }
}

struct ProviderModelLabel: View {
    let provider: String
    let model: String?
    let effort: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(provider).font(.system(size: 17, weight: .semibold)).lineLimit(1)
            if model != nil || effort != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let model { Text(model).font(.caption).lineLimit(1) }
                    if let effort {
                        Text("Reasoning: \(ReasoningEffortPresentation.title(effort))")
                            .font(.caption2).lineLimit(1)
                    }
                }.foregroundStyle(.secondary)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}
