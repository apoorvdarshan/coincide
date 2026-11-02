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
    @Environment(ProStore.self) private var store
    @State private var scanning = false
    @State private var pairing = false
    @State private var error: String?
    @State private var payload: RemotePairingPayload?
    @State private var manualHost = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                hero
                actions
                if let payload, error != nil { manualAddress(payload) }
                macs
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .background(theme.sidebar.ignoresSafeArea())
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
        #if DEBUG
        // The plans with the App Store's own prices, without a tap: `-CoincideRemoteShowPlans`.
        .task {
            guard isOnboarding, ProcessInfo.processInfo.arguments.contains("-CoincideRemoteShowPlans") else { return }
            try? await Task.sleep(for: .seconds(1))
            PaywallPresenter.shared.present()
        }
        #endif
    }

    /// Coincide's mark and what to do on the Mac.
    private var hero: some View {
        VStack(spacing: 14) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(theme.border, lineWidth: theme.borderWidth))
                .shadow(color: .black.opacity(theme.isDark ? 0.5 : 0.15), radius: 18, y: 8)
                .accessibilityHidden(true)
            Text("Connect to Coincide")
                .font(.title2.bold())
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
            Text("On your Mac, open Coincide’s Settings › General › Remote, turn on Allow Coincide Remote, and click Pair iPhone or iPad.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.secondaryInk)
        }
        .padding(.top, isOnboarding ? 36 : 8)
    }

    /// Scan or paste the code, and how pairing is going.
    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                error = nil
                scanning = true
            } label: {
                Label("Scan Pairing Code", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .prominentButton()
            Button {
                pasteCode()
            } label: {
                Label("Paste Pairing Code", systemImage: "doc.on.clipboard")
                    .foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glass)
            if pairing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Pairing with \(payload?.name ?? "the Mac")…")
                }
                .font(.callout)
                .foregroundStyle(theme.secondaryInk)
                .padding(.top, 4)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Text("The code works once, for a few minutes. Copy Code on the Mac puts it on your clipboard with Universal Clipboard.")
                .font(.footnote)
                .foregroundStyle(theme.tertiaryInk)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            // Coincide Pro's plans, and Restore Purchases, before any Mac is paired.
            if isOnboarding, !store.isPro {
                Button { PaywallPresenter.shared.present() } label: {
                    Label("Coincide Pro Plans", systemImage: "sparkles")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(theme.secondaryInk)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// An address to try when the Mac's own can't be reached from here.
    private func manualAddress(_ payload: RemotePairingPayload) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SidebarHeader(Text("Enter an Address"))
            TextField("Address, such as 192.168.1.20 or mac.tailnet.ts.net", text: $manualHost)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(12)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.border, lineWidth: theme.borderWidth))
            Text("If the Mac’s addresses can’t be reached from here, enter one that can, such as its Tailscale address.")
                .font(.footnote)
                .foregroundStyle(theme.secondaryInk)
            Button("Try This Address") {
                var edited = payload
                edited.hosts.insert(RemoteHostCandidate(host: manualHost.trimmingCharacters(in: .whitespaces), kind: .manual), at: 0)
                pair(edited)
            }
            .buttonStyle(.glass)
            .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty || pairing)
        }
    }

    /// Macs found on this network, and ones paired before, as the sidebar lists things.
    @ViewBuilder private var macs: some View {
        let saved = client.savedMacs
        VStack(alignment: .leading, spacing: 0) {
            if !client.bonjour.macs.isEmpty {
                SidebarHeader(Text("On This Network"))
                ForEach(client.bonjour.macs) { mac in
                    let pairedMac = saved.first { $0.serverID == mac.serverID }
                    Button {
                        if let pairedMac {
                            client.connect(to: pairedMac)
                            close()
                        } else {
                            error = String(localized: "Scan the pairing code \(mac.name) shows to pair with it.")
                        }
                    } label: {
                        macRow(name: mac.name, detail: pairedMac == nil ? String(localized: "Not paired") : String(localized: "Paired"))
                    }
                    .buttonStyle(SidebarRowButtonStyle())
                }
            } else if client.bonjour.isDenied {
                SidebarHeader(Text("On This Network"))
                Text("Allow Local Network access for Coincide in Settings › Privacy & Security › Local Network to find Macs nearby.")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryInk)
                    .padding(.horizontal, 10)
            }
            if !saved.isEmpty {
                SidebarHeader(Text("Paired Macs"))
                ForEach(saved) { mac in
                    Button {
                        client.connect(to: mac)
                        close()
                    } label: {
                        macRow(name: mac.name, detail: mac.hosts.map(\.host).joined(separator: ", "))
                    }
                    .buttonStyle(SidebarRowButtonStyle())
                }
            }
        }
    }

    private func macRow(name: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "laptopcomputer")
                .font(.callout)
                .foregroundStyle(theme.secondaryInk)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout).foregroundStyle(theme.ink).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(theme.secondaryInk).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
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
                navigator.reset()
                close()
                PaywallPresenter.shared.offerAfterFirstPairing()
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
