import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted once Coincide has Full Disk Access after `FullDiskAccess.request()`.
    static let coincideFullDiskAccessGranted = Notification.Name("coincide.fullDiskAccessGranted")
}

/// Full Disk Access with as little hunting as macOS allows. No app can turn it on for itself, so this opens the list
/// in System Settings, floats a card with Coincide's icon to drag into it, and notices the moment it's on.
enum FullDiskAccess {
    /// Whether Coincide has it now: only Full Disk Access opens the system's privacy database.
    static var isGranted: Bool {
        let handle = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard handle >= 0 else { return false }
        close(handle)
        return true
    }

    private static let resumeKey = "browserImport.resumeAfterFullDiskAccess"

    /// Opens Full Disk Access in System Settings with the drag card, and remembers to bring the browser import back
    /// should the user let macOS quit and reopen Coincide for the change.
    static func request() {
        UserDefaults.standard.set(Date(), forKey: resumeKey)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
        FullDiskAccessCard.show()
    }

    /// At launch: true once when access was asked for in the last ten minutes and is on now, so the import reopens.
    static func takeResumeRequest(now: Date = Date(), isGranted: Bool = FullDiskAccess.isGranted) -> Bool {
        guard let asked = UserDefaults.standard.object(forKey: resumeKey) as? Date else { return false }
        UserDefaults.standard.removeObject(forKey: resumeKey)
        return now.timeIntervalSince(asked) < 600 && isGranted
    }

    /// Called after `request()` once access is on without a relaunch.
    fileprivate static func granted() {
        UserDefaults.standard.removeObject(forKey: resumeKey)
        NotificationCenter.default.post(name: .coincideFullDiskAccessGranted, object: nil)
    }
}

/// A small floating card near the bottom of the screen while System Settings is open: Coincide's icon to drag into
/// the Full Disk Access list. It checks every second and closes itself once access is on.
final class FullDiskAccessCard: NSPanel {
    private static var shown: FullDiskAccessCard?
    private var timer: Timer?

    static func show() {
        if let shown {
            shown.orderFrontRegardless()
            return
        }
        let card = FullDiskAccessCard()
        shown = card
        card.orderFrontRegardless()
        card.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak card] _ in
            MainActor.assumeIsolated {
                guard FullDiskAccess.isGranted else { return }
                card?.dismiss()
                FullDiskAccess.granted()
            }
        }
    }

    private init() {
        let size = NSSize(width: 420, height: 92)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        let hosting = NSHostingView(rootView: FullDiskAccessCardView { [weak self] in self?.dismiss() })
        hosting.frame = NSRect(origin: .zero, size: size)
        contentView = hosting
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 40))
        }
    }

    private func dismiss() {
        timer?.invalidate()
        timer = nil
        orderOut(nil)
        Self.shown = nil
    }
}

struct FullDiskAccessCardView: View {
    let close: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
                .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
                .help(String(localized: "Drag into the Full Disk Access list"))
            VStack(alignment: .leading, spacing: 3) {
                Text("Drag Coincide into the list").font(.headline)
                Text("Then switch it on. This card closes when it’s on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Close"))
        }
        .padding(16)
        .frame(width: 420, height: 92)
        .background(Color(nsColor: Theme.contentBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(nsColor: Theme.separator)))
    }
}
