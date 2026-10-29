import CoincideRemoteKit
import SwiftUI
import VisionKit

/// Pairing with a Mac: scan its code (or paste it), see the Macs on this network, and connect to ones already paired.
struct ConnectView: View {
    let isOnboarding: Bool
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var scanning = false
    @State private var pairing = false
    @State private var error: String?
    @State private var payload: RemotePairingPayload?
    @State private var manualHost = ""

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "macbook.and.iphone")
                        .font(.system(size: 48))
                        .foregroundStyle(theme.accent)
                        .accessibilityHidden(true)
                    Text("Connect to Coincide")
                        .font(.title2.bold())
                    Text("On your Mac, open Coincide’s Settings › General › Remote, turn on Allow Coincide Remote, and click Pair iPhone or iPad.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(theme.secondaryInk)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                Button {
                    error = nil
                    scanning = true
                } label: {
                    Label("Scan Pairing Code", systemImage: "qrcode.viewfinder")
                }
                Button {
                    pasteCode()
                } label: {
                    Label("Paste Pairing Code", systemImage: "doc.on.clipboard")
                }
                if pairing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Pairing with \(payload?.name ?? "the Mac")…")
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            } footer: {
                Text("The code works once, for a few minutes. Copy Code on the Mac puts it on your clipboard with Universal Clipboard.")
            }

            if let payload, error != nil {
                Section {
                    TextField("Address, such as 192.168.1.20 or mac.tailnet.ts.net", text: $manualHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Try This Address") {
                        var edited = payload
                        edited.hosts.insert(RemoteHostCandidate(host: manualHost.trimmingCharacters(in: .whitespaces), kind: .manual), at: 0)
                        pair(edited)
                    }
                    .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty || pairing)
                } header: {
                    Text("Enter an Address")
                } footer: {
                    Text("If the Mac’s addresses can’t be reached from here, enter one that can, such as its Tailscale address.")
                }
            }

            if !client.bonjour.macs.isEmpty {
                Section("On This Network") {
                    ForEach(client.bonjour.macs) { mac in
                        let saved = client.savedMacs.first { $0.serverID == mac.serverID }
                        Button {
                            if let saved {
                                client.connect(to: saved)
                                close()
                            } else {
                                error = String(localized: "Scan the pairing code \(mac.name) shows to pair with it.")
                            }
                        } label: {
                            HStack {
                                Label(mac.name, systemImage: "desktopcomputer")
                                Spacer()
                                Text(saved == nil ? "Not paired" : "Paired").font(.caption).foregroundStyle(theme.secondaryInk)
                            }
                        }
                    }
                }
            } else if client.bonjour.isDenied {
                Section("On This Network") {
                    Text("Allow Local Network access for Coincide Remote in Settings › Privacy & Security › Local Network to find Macs nearby.")
                        .font(.callout)
                        .foregroundStyle(theme.secondaryInk)
                }
            }

            let saved = client.savedMacs
            if !saved.isEmpty {
                Section("Paired Macs") {
                    ForEach(saved) { mac in
                        Button {
                            client.connect(to: mac)
                            close()
                        } label: {
                            VStack(alignment: .leading) {
                                Text(mac.name)
                                Text(mac.hosts.map(\.host).joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(theme.secondaryInk)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.content)
        .navigationTitle(isOnboarding ? "" : String(localized: "Pair a Mac"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isOnboarding {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .sheet(isPresented: $scanning) {
            PairingScanner { code in
                scanning = false
                handle(code)
            }
        }
    }

    private func close() {
        if !isOnboarding { dismiss() }
    }

    private func pasteCode() {
        guard let text = UIPasteboard.general.string else {
            error = String(localized: "The clipboard has no pairing code.")
            return
        }
        handle(text)
    }

    private func handle(_ code: String) {
        guard let decoded = RemotePairingPayload.decode(code) else {
            error = String(localized: "That isn’t a Coincide pairing code.")
            return
        }
        pair(decoded)
    }

    private func pair(_ decoded: RemotePairingPayload) {
        payload = decoded
        error = nil
        pairing = true
        Task {
            do {
                try await client.pair(decoded)
                pairing = false
                navigator.selection = nil
                close()
            } catch {
                pairing = false
                self.error = (error as? RemoteError)?.message ?? error.localizedDescription
            }
        }
    }
}

/// The camera, looking for a QR code. Devices without a camera scanner (the simulator, say) get a note instead.
struct PairingScanner: View {
    let found: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                    QRScannerView(found: found)
                        .ignoresSafeArea()
                        .overlay(alignment: .bottom) {
                            Text("Point the camera at the code on your Mac.")
                                .padding(12)
                                .glassEffect(.regular, in: .capsule)
                                .padding(.bottom, 40)
                        }
                } else {
                    ContentUnavailableView(
                        "Camera Unavailable", systemImage: "camera",
                        description: Text("Allow camera access in Settings, or copy the code on the Mac and use Paste Pairing Code."))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false

        init(found: @escaping (String) -> Void) {
            self.found = found
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in items {
                guard !done, case .barcode(let barcode) = item, let value = barcode.payloadStringValue,
                    RemotePairingPayload.decode(value) != nil
                else { continue }
                done = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                found(value)
            }
        }
    }
}
