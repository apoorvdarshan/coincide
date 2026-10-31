import CoincideRemoteKit
import SwiftUI

/// The bot editor's Personality section, as on the Mac: a chip for no personality, one for each preset the Mac offers
/// and one for Custom; under them the chosen preset's description and a sample greeting in its voice (written, not
/// generated), or for Custom the user's own description, which can start from a preset's text. Chips flow in rows
/// that fit the width, so they follow an iPhone, a folded or unfolded Duo and an iPad.
struct BotPersonalitySection: View {
    @Binding var personality: BotEditorPersonality
    /// The presets the Mac offers, by id (`RemoteWorkspace.botPersonalityPresets`).
    let offered: [String]
    @Environment(\.theme) private var theme

    private var presets: [BotPersonalityPreset] { BotPersonalityPreset.all.filter { offered.contains($0.id) } }

    var body: some View {
        Section {
            ChipFlowLayout(spacing: 8) {
                chip(.none, symbol: "circle.slash", name: String(localized: "None", comment: "No bot personality"))
                ForEach(presets) { preset in chip(.preset(preset.id), symbol: preset.symbol, name: preset.name) }
                chip(.custom, symbol: "pencil.line", name: String(localized: "Custom", comment: "A bot personality the user wrote"))
            }
            .padding(.vertical, 6)
            switch personality.choice {
            case .none:
                Text("No personality of its own: it talks as its instructions say.")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryInk)
            case .preset(let id):
                if let preset = BotPersonalityPreset.preset(id: id) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(preset.summary)
                            .font(.footnote)
                            .foregroundStyle(theme.secondaryInk)
                        // The greeting in the replies' typeface, as the Mac sets it in New York.
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("Preview")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(theme.secondaryInk)
                            Text(preset.greeting)
                                .font(theme.serifReplies ? .system(.callout, design: .serif) : .callout)
                                .foregroundStyle(theme.ink)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("Preview: \(preset.greeting)"))
                    }
                }
            case .custom:
                TextField("Describe the personality…", text: $personality.custom, axis: .vertical)
                    .lineLimit(3...10)
                    .accessibilityLabel(Text("Custom personality"))
                HStack {
                    Menu {
                        ForEach(presets) { preset in
                            Button { personality.start(from: preset.prompt) } label: {
                                Label(preset.name, systemImage: preset.symbol)
                            }
                        }
                    } label: {
                        Label("Start from Preset", systemImage: "text.badge.plus")
                            .font(.callout.weight(.medium))
                    }
                    .foregroundStyle(theme.ink)
                    Spacer(minLength: 8)
                    Text("Up to \(BotEditorPersonality.customLimit.formatted()) characters.")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryInk)
                }
            }
        } header: {
            Text("Personality")
        } footer: {
            Text("How the bot talks and behaves, apart from its job. A change reaches its conversations with their next message.")
        }
    }

    /// A chip drawn as the Mac draws them: outlined at rest, the chosen one on the raised color and ringed in the
    /// theme's accent.
    private func chip(_ choice: BotEditorPersonality.Choice, symbol: String, name: String) -> some View {
        let isChosen = personality.choice == choice
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button {
            personality.pick(choice)
        } label: {
            Label {
                Text(name).lineLimit(1)
            } icon: {
                Image(systemName: symbol).imageScale(.small)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(isChosen ? theme.ink : theme.secondaryInk)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(shape.fill(isChosen ? theme.raised : .clear))
            .overlay(shape.strokeBorder(isChosen ? theme.accent : theme.border, lineWidth: isChosen ? 2 : max(1, theme.borderWidth)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .accessibilityHint(Text(hint(for: choice)))
    }

    private func hint(for choice: BotEditorPersonality.Choice) -> String {
        switch choice {
        case .none: String(localized: "No personality of its own: it talks as its instructions say.")
        case .preset(let id): BotPersonalityPreset.preset(id: id)?.summary ?? ""
        case .custom: String(localized: "Describe a personality in your own words.")
        }
    }
}

/// Lays out chips in rows, left to right, starting a new row when the next one doesn't fit; a chip wider than the
/// whole row gets one to itself, cut to its width.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (index, size) in zip(row.indices, row.sizes) {
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(width: CGFloat?, subviews: Subviews) -> [Row] {
        let limit = width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? .infinity
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, limit)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, needed > limit {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            row.sizes.append(size)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
