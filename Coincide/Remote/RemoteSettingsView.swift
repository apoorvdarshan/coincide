import AppKit
import CoincideRemoteKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Settings › General › Remote: lets Coincide Remote on iPhone and iPad connect, pairs devices, and lists them.
struct RemoteSettingsRows: View {
    @State private var server = RemoteServer.shared
    @State private var showsPairing = false
    @State private var confirmingReset = false
    @State private var revoking: RemoteDevice?

    var body: some View {
        Group {
            Toggle(isOn: Binding(get: { server.isEnabled }, set: { server.setEnabled($0) })) {
                Text("Allow Coincide Remote")
                Text(
                    "Drive Coincide from your iPhone or iPad on this network or your Tailscale network. Paired devices connect over an encrypted connection; nothing goes through the internet."
                )
            }
            if server.isEnabled {
                LabeledContent {
                    Button("Pair iPhone or iPad…") {
                        server.beginPairing()
                        showsPairing = true
                    }
                    .disabled(!isRunning)
                } label: {
                    HStack(spacing: 6) {
                        SettingsStatusDot(color: statusColor)
                        Text(statusTitle)
                    }
                    Text(statusDetail)
                }
                if !server.candidates.isEmpty {
                    LabeledContent("Reachable at") {
                        VStack(alignment: .trailing, spacing: 2) {
                            ForEach(server.candidates) { candidate in
                                HStack(spacing: 6) {
                                    Text(candidate.host).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                    Text(label(for: candidate.kind)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if server.devices.isEmpty {
                    LabeledContent("Paired devices") {
                        Text("None yet").foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(server.devices) { device in
                        LabeledContent {
                            Button("Revoke…") { revoking = device }
                        } label: {
                            HStack(spacing: 6) {
                                SettingsStatusDot(color: server.connectedDeviceIDs.contains(device.id) ? .green : Color(nsColor: Theme.surfaceBorder))
                                Text(device.name)
                            }
                            Text(deviceDetail(device))
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                LabeledContent {
                    Button("Reset…") { confirmingReset = true }
                } label: {
                    Text("Certificate")
                    Text(server.fingerprint.map { "SHA-256 " + RemoteCrypto.displayFingerprint($0, groups: 8) } ?? "–")
                        .font(.system(.caption, design: .monospaced))
                }
            }
        }
        .sheet(isPresented: $showsPairing, onDismiss: { server.cancelPairing() }) {
            RemotePairingSheet(server: server) { showsPairing = false }
        }
        .confirmationDialog(
            "Revoke “\(revoking?.name ?? "")”?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })
        ) {
            Button("Revoke", role: .destructive) {
                if let revoking { server.revoke(revoking.id) }
                revoking = nil
            }
        } message: {
            Text("It disconnects now and has to pair again to connect.")
        }
        .confirmationDialog("Reset the remote certificate?", isPresented: $confirmingReset) {
            Button("Reset Certificate", role: .destructive) { server.resetIdentity() }
        } message: {
            Text("Coincide makes a new certificate and forgets every paired device. Each one has to pair again.")
        }
    }

    private var isRunning: Bool {
        if case .running = server.status { return true }
        return false
    }

    private var statusColor: Color {
        switch server.status {
        case .running: .green
        case .starting: .yellow
        case .failed: .orange
        case .off: Color(nsColor: Theme.surfaceBorder)
        }
    }

    private var statusTitle: String {
        switch server.status {
        case .running: String(localized: "Listening for Coincide Remote")
        case .starting: String(localized: "Starting…")
        case .failed: String(localized: "Coincide Remote can’t start")
        case .off: String(localized: "Off")
        }
    }

    private var statusDetail: String {
        switch server.status {
        case .running(let port):
            let connected = server.connectedDeviceIDs.count
            return connected == 0
                ? String(localized: "On port \(String(port)). Scan the pairing code with Coincide Remote to add a device.")
                : String(localized: "On port \(String(port)). \(connected) connected now.")
        case .starting: return String(localized: "Preparing the encrypted connection.")
        case .failed(let message): return message
        case .off: return ""
        }
    }

    private func label(for kind: RemoteHostCandidate.Kind) -> String {
        switch kind {
        case .lan: String(localized: "Local network")
        case .localName: String(localized: "Bonjour name")
        case .tailscale: String(localized: "Tailscale")
        case .tailscaleName: String(localized: "MagicDNS")
        case .manual, .unknown: ""
        }
    }

    private func deviceDetail(_ device: RemoteDevice) -> String {
        if server.connectedDeviceIDs.contains(device.id) { return String(localized: "Connected now") }
        guard let seen = device.lastSeenAt else {
            return String(localized: "Paired \(device.pairedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        return String(localized: "Last connected \(seen.formatted(.relative(presentation: .named)))")
    }
}

/// The pairing QR code, with what it holds spelled out for a device that can't scan it.
struct RemotePairingSheet: View {
    let server: RemoteServer
    let done: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair Coincide Remote").font(.title2.weight(.semibold))
            if let device = server.lastPairedDevice {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("“\(device.name)” is paired.").font(.headline)
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            } else if let payload = server.pairingPayload {
                Text("Open Coincide Remote on your iPhone or iPad, tap Scan Pairing Code, and point the camera here.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let image = Self.qrImage(payload.encoded()) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 240, height: 240)
                        .padding(12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel(Text("Pairing code"))
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(payload.expiresAt.timeIntervalSince(context.date)))
                    Text(
                        remaining > 0
                            ? String(localized: "Works once, for \(remaining / 60):\(String(format: "%02d", remaining % 60)) more.")
                            : String(localized: "This code has expired.")
                    )
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(remaining > 0 ? Color.secondary : Color.orange)
                }
                Text("Certificate \(RemoteCrypto.displayFingerprint(payload.fingerprint, groups: 8))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Button("New Code") { server.beginPairing() }
                    // Universal Clipboard carries it to a device whose camera can't scan.
                    SettingsCopyButton(text: payload.encoded(), label: "Copy Code")
                    Spacer()
                    Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                }
            } else {
                Text("Coincide Remote isn’t running.").foregroundStyle(.secondary)
                Button("Close", action: done).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    static func qrImage(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let context = CIContext()
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
