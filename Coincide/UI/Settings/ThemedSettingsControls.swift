import AppKit
import CoincideKit
import SwiftUI

/// A settings picker in the app's theme: a rounded field with the chosen option that opens the themed popup, in place
/// of SwiftUI's menu picker. Options can be grouped under headers and carry an image.
struct ThemedPicker<Value: Hashable, Label: View>: View {
    struct Option {
        var value: Value
        var title: String
        var image: NSImage?
        /// The header this option is listed under; consecutive options with the same group share one.
        var group: String?

        init(_ value: Value, _ title: String, image: NSImage? = nil, group: String? = nil) {
            self.value = value
            self.title = title
            self.image = image
            self.group = group
        }
    }

    @Binding var selection: Value
    let options: [Option]
    @ViewBuilder let label: () -> Label

    var body: some View {
        LabeledContent {
            ThemedPickerField(
                title: options.first { $0.value == selection }?.title ?? "",
                image: options.first { $0.value == selection }?.image,
                menu: makeMenu
            )
            .fixedSize()
            .pointerCursor()
        } label: {
            label()
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        var group: String?
        for option in options {
            if let header = option.group, header != group {
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                menu.addItem(.sectionHeader(title: header))
            }
            group = option.group
            let item = NSMenuItem(title: option.title, action: #selector(PickerChoice.choose(_:)), keyEquivalent: "")
            let choice = PickerChoice { [binding = $selection, value = option.value] in binding.wrappedValue = value }
            item.target = choice
            item.representedObject = choice
            item.image = option.image
            item.state = option.value == selection ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
}

/// Runs one picker choice; the menu item keeps it alive through `representedObject`.
final class PickerChoice: NSObject {
    private let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }

    @objc func choose(_ sender: Any?) { run() }
}

/// The picker's field, an AppKit control so it can anchor the themed popup.
private struct ThemedPickerField: NSViewRepresentable {
    let title: String
    let image: NSImage?
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> ThemedPopupField {
        ThemedPopupField()
    }

    func updateNSView(_ field: ThemedPopupField, context: Context) {
        field.update(title: title, image: image)
        field.menuProvider = menu
    }
}

/// A rounded field showing a choice, with a chevron; clicking it opens `menuProvider`'s menu as a themed popup.
final class ThemedPopupField: NSControl, PointerCursorControl {
    var menuProvider: (() -> NSMenu)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let chevron = NSImageView()
    private var isHovered = false
    private var isOpen = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .labelColor
        chevron.image = Theme.symbol("chevron.up.chevron.down", size: 9, weight: .semibold)
        chevron.contentTintColor = .secondaryLabelColor
        for view in [icon, titleLabel, chevron] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])
        titleLeading = titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        titleLeading.isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
    }

    private var titleLeading: NSLayoutConstraint!

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(title: String, image: NSImage?) {
        titleLabel.stringValue = title
        titleLabel.textColor = Theme.ink
        icon.image = image
        icon.isHidden = image == nil
        titleLeading.constant = image == nil ? 10 : 29
        setAccessibilityValue(title)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        open()
    }

    override func accessibilityPerformPress() -> Bool {
        open()
        return true
    }

    private func open() {
        guard let menu = menuProvider?() else { return }
        let popup = ThemedPopup.show(menu: menu, from: self, preferAbove: false) { [weak self] in
            self?.isOpen = false
            self?.needsDisplay = true
        }
        // Set once it opened, as a popup it replaces clears it on closing.
        isOpen = popup != nil
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = 7
        layer.cornerCurve = .continuous
        let fill = isOpen ? Theme.sidebarSelection : isHovered ? Theme.sidebarHover : Theme.raisedFill
        layer.backgroundColor = fill.cgColor
        layer.borderWidth = 1
        layer.borderColor = Theme.surfaceBorder.cgColor
    }
}

/// A switch in the app's theme: a capsule that fills with the conversation's text color when on. Without its label it
/// is just the switch, for rows that lay out their own text.
struct ThemedSwitchToggleStyle: ToggleStyle {
    var showsLabel = true

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if showsLabel {
                // LabeledContent gives a second text in the label the form's caption style, as Toggle does.
                LabeledContent {
                    ThemedSwitch(isOn: configuration.$isOn)
                } label: {
                    configuration.label
                }
            } else {
                ThemedSwitch(isOn: configuration.$isOn)
            }
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

private struct ThemedSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        let ink = Color(nsColor: Theme.ink)
        Capsule(style: .continuous)
            .fill(isOn ? ink : Color(nsColor: Theme.raisedFill))
            .overlay(Capsule(style: .continuous).strokeBorder(Color(nsColor: Theme.surfaceBorder), lineWidth: 1))
            .frame(width: 34, height: 20)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? Color(nsColor: Theme.contentBackground) : ink.opacity(0.75))
                    .frame(width: 14, height: 14)
                    .padding(3)
            }
            .animation(.easeOut(duration: 0.15), value: isOn)
            .contentShape(Capsule())
            .onTapGesture { isOn.toggle() }
            .pointerCursor()
    }
}

/// Buttons in the app's theme: a rounded raised fill with a border, red text for destructive ones.
struct ThemedButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(configuration.role == .destructive ? Color.red : Color(nsColor: Theme.ink))
            .padding(.horizontal, 12)
            .frame(minHeight: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: configuration.isPressed ? Theme.sidebarSelection : Theme.raisedFill)))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color(nsColor: Theme.surfaceBorder), lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
            .pointerCursor()
    }
}

/// A checkbox in the app's theme: a rounded square that fills with the text color and shows a check when on.
struct ThemedCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(Color(nsColor: configuration.isOn ? Theme.ink : Theme.raisedFill))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .strokeBorder(Color(nsColor: Theme.surfaceBorder), lineWidth: configuration.isOn ? 0 : 1)
                    )
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color(nsColor: Theme.contentBackground))
                        }
                    }
                    .frame(width: 16, height: 16)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// A slider in the app's theme: a thin track that fills with the text color up to a round knob, in place of the
/// system slider. It snaps to `step`, and the arrow keys and VoiceOver adjust it a step at a time.
struct ThemedSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1

    private let knob: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let span = max(geometry.size.width - knob, 1)
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let ink = Color(nsColor: Theme.ink)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color(nsColor: Theme.sidebarSelection))
                    .frame(width: span, height: 4)
                    .offset(x: knob / 2)
                Capsule(style: .continuous)
                    .fill(ink)
                    .frame(width: span * fraction, height: 4)
                    .offset(x: knob / 2)
                Circle()
                    .fill(Color(nsColor: Theme.contentBackground))
                    .overlay(Circle().strokeBorder(ink, lineWidth: 1.5))
                    .frame(width: knob, height: knob)
                    .offset(x: span * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    let position = min(max((drag.location.x - knob / 2) / span, 0), 1)
                    set(range.lowerBound + position * (range.upperBound - range.lowerBound))
                })
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.08), value: value)
        .accessibilityElement()
        .accessibilityAddTraits(.allowsDirectInteraction)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(value + step)
            case .decrement: set(value - step)
            @unknown default: break
            }
        }
    }

    private func set(_ newValue: Double) {
        let snapped = (newValue / step).rounded() * step
        let clamped = min(max(snapped, range.lowerBound), range.upperBound)
        if clamped != value { value = clamped }
    }
}

/// Text fields in the app's theme: a rounded raised fill with a border, like the theme's buttons and pickers.
struct ThemedTextFieldStyle: TextFieldStyle {
    // swiftlint:disable:next identifier_name
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .frame(minHeight: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: Theme.raisedFill)))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color(nsColor: Theme.surfaceBorder), lineWidth: 1))
    }
}
