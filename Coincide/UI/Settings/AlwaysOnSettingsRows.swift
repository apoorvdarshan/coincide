import AppKit
import CoincideKit
import SwiftUI

/// Settings › General › Keep Awake: the 24/7 switch, its options, the Mac's live sleep settings and the caveats.
struct AlwaysOnSettingsRows: View {
    let model: SettingsModel
    var controller = AlwaysOnController.shared

    private var options: AlwaysOnSettings { model.settings.alwaysOn }

    var body: some View {
        Group {
            if let install = controller.standalone {
                LabeledContent {
                    Button("Switch to Coincide") { Task { await controller.switchFromStandalone() } }
                        .disabled(controller.isWorking)
                } label: {
                    Text("macbook-24x7-agents is installed")
                    Text(standaloneDetail(install))
                }
            }
            Toggle(isOn: enabledBinding) {
                Text("Keep this Mac awake 24/7")
                Text("Agents keep working with the lid closed: the Mac never sleeps, and the display turns off when the lid closes. Turning it on or off asks for your password.")
            }
            .disabled(controller.isWorking || (controller.standalone != nil && !options.enabled))
            if controller.isWorking {
                ProgressView().controlSize(.small)
            }
            if let problem = controller.problem {
                Text(problem)
                    .foregroundStyle(Color(nsColor: Theme.failure))
                    .textSelection(.enabled)
            }
            if options.enabled || controller.standalone == nil {
                optionRows
            }
            statusRow
            Group {
                if !options.sleepsOnBattery {
                    Text("Keep it plugged in: on battery the Mac runs until the battery is empty.")
                }
                Text("With the lid closed, give it airflow. While sleep is disabled, Apple menu › Sleep does nothing. Turn Keep Awake off here before you delete Coincide.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .task { await controller.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await controller.refresh() }
        }
    }

    @ViewBuilder private var optionRows: some View {
        if controller.hasBattery {
            Toggle(isOn: batteryBinding) {
                Text("Sleep normally on battery")
                Text("On battery the Mac sleeps as usual, closing the lid included; on the charger it stays awake. macOS can only switch this as administrator, so Coincide adds a small battery helper that runs as root only while this and Keep Awake are on. It takes no input and only switches sleep when you plug in or unplug. You allow it once in Login Items. Off, the Mac stays awake on battery too, without the helper.")
            }
            .disabled(controller.isWorking)
            if options.enabled, options.sleepsOnBattery {
                batteryHelperRow
            }
        }
        if controller.hasLid {
            Toggle(isOn: optionBinding(\.displayOffOnLidClose)) {
                Text("Turn the display off when the lid closes")
            }
            Toggle(isOn: optionBinding(\.keepDisplaysOff)) {
                Text("Keep displays off while the lid is closed")
                Text("Keyboard or mouse input can’t keep an external display awake: it goes dark again within two seconds.")
            }
            Toggle(isOn: optionBinding(\.muteWhileClosed)) {
                Text("Mute sound while the lid is closed")
                Text("Your mute setting comes back when you open the lid.")
            }
        }
    }

    private var batteryHelperRow: some View {
        LabeledContent {
            switch controller.batteryHelper {
            case .needsApproval:
                Button("Open Login Items…") { controller.openLoginItems() }
            case .notRegistered:
                Button("Apply Again") { Task { await controller.applyAgain() } }
                    .disabled(controller.isWorking)
            case .running, .missing:
                EmptyView()
            }
        } label: {
            HStack(spacing: 6) {
                SettingsStatusDot(color: controller.batteryHelper == .running ? .green : .orange)
                Text(batteryHelperHeadline)
            }
        }
    }

    private var batteryHelperHeadline: String {
        switch controller.batteryHelper {
        case .running: String(localized: "The battery helper is running")
        case .needsApproval: String(localized: "Allow the battery helper in Login Items. Until then the Mac stays awake on battery.")
        case .notRegistered: String(localized: "The battery helper isn’t running")
        case .missing: String(localized: "This copy of Coincide doesn’t include the battery helper.")
        }
    }

    private var statusRow: some View {
        LabeledContent {
            if options.enabled, controller.service == .needsApproval {
                Button("Open Login Items…") { controller.openLoginItems() }
            } else if controller.isOutOfStep || (options.enabled && controller.hasLid && controller.service == .notRegistered) {
                Button("Apply Again") { Task { await controller.applyAgain() } }
                    .disabled(controller.isWorking)
            }
        } label: {
            HStack(spacing: 6) {
                SettingsStatusDot(color: statusColor)
                Text(statusHeadline)
            }
            Text(powerDetail)
        }
    }

    private var statusColor: Color {
        guard let power = controller.power else { return Color(nsColor: Theme.surfaceBorder) }
        if controller.isOutOfStep || (options.enabled && controller.service != .running && controller.hasLid) { return .orange }
        let sleepingOnBattery = options.enabled && options.sleepsOnBattery && power.onBattery
        return power.sleepDisabled || sleepingOnBattery ? .green : Color(nsColor: Theme.surfaceBorder)
    }

    private var statusHeadline: String {
        guard let power = controller.power else { return String(localized: "Sleep settings unavailable") }
        if !power.sleepDisabled {
            return options.enabled && options.sleepsOnBattery && power.onBattery
                ? String(localized: "On battery this Mac sleeps as usual; plugged in, it stays awake")
                : String(localized: "This Mac sleeps as usual")
        }
        guard options.enabled || controller.standalone != nil else { return String(localized: "Sleep is disabled outside Coincide") }
        guard controller.hasLid, options.enabled else { return String(localized: "This Mac stays awake") }
        switch controller.service {
        case .running: return String(localized: "This Mac stays awake, lid closed too")
        case .needsApproval: return String(localized: "Allow Coincide in Login Items to watch the lid")
        case .notRegistered, .missing: return String(localized: "The lid watcher isn’t running")
        }
    }

    private var powerDetail: String {
        guard let power = controller.power else { return String(localized: "pmset didn’t answer.") }
        let charger = sleepDescription(power.chargerSleep)
        let sleep = power.sleepDisabled ? String(localized: "Sleep disabled: yes") : String(localized: "Sleep disabled: no")
        guard let battery = power.batterySleep else {
            return String(localized: "\(sleep). Idle sleep: \(charger).")
        }
        return String(localized: "\(sleep). Idle sleep on the charger: \(charger); on battery: \(sleepDescription(battery)).")
    }

    private func sleepDescription(_ minutes: Int) -> String {
        minutes == 0 ? String(localized: "never") : SettingsFormat.minutes(minutes)
    }

    private func standaloneDetail(_ install: StandaloneAlwaysOn) -> String {
        String(
            localized: "Its lid watcher runs from \((install.plist.path as NSString).abbreviatingWithTildeInPath). Switching stops it and removes its LaunchAgent and script, keeps its options, and leaves the sleep settings as they are.")
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { options.enabled }, set: { value in Task { await controller.setEnabled(value) } })
    }

    private var batteryBinding: Binding<Bool> {
        Binding(get: { options.sleepsOnBattery }, set: { value in Task { await controller.setSleepsOnBattery(value) } })
    }

    private func optionBinding(_ option: WritableKeyPath<AlwaysOnSettings, Bool>) -> Binding<Bool> {
        Binding(get: { options[keyPath: option] }, set: { controller.set(option, $0) })
    }
}
