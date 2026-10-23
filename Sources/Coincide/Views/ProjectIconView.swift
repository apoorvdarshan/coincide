import AppKit
import CoincideCore
import SwiftUI

extension ProjectIconColor {
    var color: Color {
        switch self {
        case .gray: .gray
        case .red: .red
        case .orange: .orange
        case .amber: Color(red: 0.96, green: 0.62, blue: 0.04)
        case .yellow: .yellow
        case .lime: Color(red: 0.52, green: 0.80, blue: 0.09)
        case .green: .green
        case .emerald: Color(red: 0.06, green: 0.73, blue: 0.51)
        case .teal: .teal
        case .cyan: .cyan
        case .sky: Color(red: 0.05, green: 0.65, blue: 0.91)
        case .blue: .blue
        case .indigo: .indigo
        case .violet: Color(red: 0.55, green: 0.36, blue: 0.96)
        case .purple: .purple
        case .fuchsia: Color(red: 0.85, green: 0.27, blue: 0.94)
        case .pink: .pink
        case .rose: Color(red: 0.96, green: 0.25, blue: 0.37)
        }
    }
    var title: String { rawValue.capitalized }
}

/// A project's icon at sidebar size: an override, a detected checkout image, or the name's monogram.
struct ProjectIconView: View {
    let settings: ProjectSettingsStore
    let project: WorkspaceProject
    let name: String
    var size: CGFloat = 16
    private struct LoadKey: Hashable {
        let projectID: UUID
        let createdAt: Date?
        let path: Data
        let settingsKeys: [Data]
        let iconEpoch: Int
        let cloneReady: Bool
    }
    private var loadKey: LoadKey {
        .init(projectID: project.id, createdAt: project.createdAt, path: Data(project.path.utf8),
              settingsKeys: ProjectSettingsKey.candidates(for: project).map { Data($0.utf8) },
              iconEpoch: settings.iconEpoch, cloneReady: project.clone?.isReady ?? true)
    }
    var body: some View {
        ProjectIconGlyph(presentation: settings.icon(for: project) ?? Self.monogram(name), size: size)
            .task(id: loadKey) { await settings.resolveIcon(for: project) }
            .accessibilityHidden(true)
    }
    static func monogram(_ name: String) -> ProjectIconPresentation {
        let value = ProjectMonogram(name: name); return .monogram(text: value.text, color: value.color)
    }
}

struct ProjectIconGlyph: View {
    let presentation: ProjectIconPresentation
    var size: CGFloat = 16
    var body: some View {
        Group {
            switch presentation {
            case .image(let image): Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            case .symbol(let name, let color):
                Image(systemName: NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? "folder" : name)
                    .resizable().scaledToFit().padding(size * 0.12).foregroundStyle(color.color)
            case .emoji(let value): Text(value).font(.system(size: size * 0.8)).minimumScaleFactor(0.5).lineLimit(1)
            case .monogram(let text, let color):
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).fill(color.color.opacity(0.16))
                    Text(text).font(.system(size: size * (text.count == 1 ? 0.62 : 0.5), weight: .bold, design: .monospaced))
                        .foregroundStyle(color.color).minimumScaleFactor(0.5).lineLimit(1)
                }
            }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}
