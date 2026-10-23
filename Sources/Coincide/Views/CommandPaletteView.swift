import CoincideCore
import SwiftUI

/// The ⌘K launcher: actions, recent threads and project/thread search in one
/// keyboard-first panel. It keeps focus while open; closing returns it to the composer.
struct CommandPaletteView: View {
    @Bindable var model: CommandPaletteModel
    let label: (KeybindingCommand) -> String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let groups = model.groups
        let selectable = groups.flatMap(\.items).filter { !$0.isDisabled }
        let highlighted = selectable.first { $0.id == model.highlightedID } ?? selectable.first
        let numbered = model.breadcrumb != nil ? Dictionary(uniqueKeysWithValues: selectable.prefix(9).enumerated().map { ($0.element.id, $0.offset + 1) }) : [:]
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let breadcrumb = model.breadcrumb {
                    Button { model.back() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                        .help("Back").accessibilityLabel("Back")
                    Text(breadcrumb).font(.callout.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                }
                TextField(model.placeholder, text: $model.query).textFieldStyle(.plain).font(.system(size: 16))
                    .focused($fieldFocused)
                    .accessibilityLabel("Command palette search").accessibilityIdentifier("command-palette-search")
                    .onSubmit { model.activateHighlighted() }
                    .onKeyPress(.upArrow) { model.move(-1); return .handled }
                    .onKeyPress(.downArrow) { model.move(1); return .handled }
                    .onKeyPress(.escape) { if !model.back() { model.close() }; return .handled }
                    .onKeyPress(.delete) { model.query.isEmpty && model.back() ? .handled : .ignored }
            }.padding(.horizontal, 16).padding(.vertical, 13)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if groups.isEmpty {
                            Text(model.query.isEmpty ? "No commands are available." : "No matching commands, projects or threads.")
                                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 28)
                        }
                        ForEach(groups) { group in
                            if !group.title.isEmpty {
                                Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 3).accessibilityAddTraits(.isHeader)
                            }
                            ForEach(group.items) { item in
                                row(item, highlighted: item.id == highlighted?.id, number: numbered[item.id]).id(item.id)
                            }
                        }
                    }.padding(6)
                }
                .frame(maxHeight: 400)
                .onChange(of: model.highlightedID) { _, value in if let value { proxy.scrollTo(value) } }
            }
            Divider()
            HStack(spacing: 14) {
                hint("↑↓", "Navigate"); hint("↩", "Open"); hint("⌘1–9", "Choose"); hint("⎋", model.breadcrumb == nil ? "Close" : "Back")
                Spacer(minLength: 0)
                if model.breadcrumb == nil { Text("Type > for actions only").font(.caption2).foregroundStyle(.tertiary) }
            }.padding(.horizontal, 14).padding(.vertical, 7)
        }
        .frame(width: 620)
        .coincideSurface(cornerRadius: 16)
        .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
        .accessibilityIdentifier("command-palette")
        .onAppear { fieldFocused = true }
        .onChange(of: model.focusGeneration) { fieldFocused = true }
    }

    private func row(_ item: PaletteItem, highlighted: Bool, number: Int?) -> some View {
        Button { model.activate(item) } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol).frame(width: 18).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.title).lineLimit(1)
                    if let snippet = item.snippet {
                        Text(verbatim: snippet).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if item.isChecked { Image(systemName: "checkmark").foregroundStyle(.secondary).accessibilityLabel("Current") }
                if let detail = item.detail { Text(verbatim: detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                if let number { shortcutText("⌘\(number)") }
                else if let command = item.shortcut, let label = label(command) { shortcutText(label) }
                if item.isSubmenu { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.isDisabled)
        .opacity(item.isDisabled ? 0.5 : 1)
        .onHover { if $0, !item.isDisabled { model.highlightedID = item.id } }
        .accessibilityLabel(Text(verbatim: item.title))
        .accessibilityValue(Text(verbatim: [item.subtitle, item.detail].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(highlighted ? .isSelected : [])
        .accessibilityIdentifier("command-palette-" + item.id)
    }

    private func shortcutText(_ value: String) -> some View {
        Text(verbatim: value).font(.caption.monospaced()).foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
    }
    private func hint(_ keys: String, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 4) { Text(verbatim: keys).font(.caption2.monospaced()); Text(title).font(.caption2) }.foregroundStyle(.secondary)
    }
}

/// Dimmed backdrop and placement for the palette over the main window.
struct CommandPaletteOverlay: View {
    let controller: MainWindowController
    var body: some View {
        if let palette = controller.palette {
            ZStack(alignment: .top) {
                Color.black.opacity(0.12).ignoresSafeArea().contentShape(Rectangle())
                    .onTapGesture { controller.closePalette() }
                    .accessibilityHidden(true)
                CommandPaletteView(model: palette, label: controller.label(for:)).padding(.top, 64).padding(.horizontal, 24)
            }
            .transition(.opacity)
        }
    }
}
