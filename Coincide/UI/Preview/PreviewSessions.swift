import Foundation
import CoincideKit

final class PreviewSessions {
    static let shared = PreviewSessions()
    let bridge = PreviewBridge()
    private var sessions: [UUID: PreviewSession] = [:]
    private var observation: ObservationToken?

    func start() {
        ThreadRunner.shared.ephemeralRuntimeContext = { [weak self] id in self?.bridge.access(for: id)?.instructions }
        observation = AppStore.shared.observe { [weak self] change in
            guard change == .threadList, let self else { return }
            for id in self.sessions.keys where AppStore.shared.summary(id) == nil {
                self.bridge.disable(threadID: id)
                self.sessions.removeValue(forKey: id)?.webView.stopLoading()
                UIState.shared.update { $0.previewAddresses.removeValue(forKey: id.uuidString) }
            }
        }
    }

    func session(for id: UUID) -> PreviewSession {
        if let session = sessions[id] { return session }
        // Retain controlled pages; ordinary old previews can be restored from their address when revisited.
        if sessions.count >= 8, let old = sessions.keys.first(where: { bridge.access(for: $0) == nil }) {
            sessions.removeValue(forKey: old)?.webView.stopLoading()
        }
        let session = PreviewSession()
        session.onNavigate = { url in UIState.shared.update { $0.previewAddresses[id.uuidString] = url.absoluteString } }
        sessions[id] = session
        if let address = UIState.shared.values.previewAddresses[id.uuidString] { try? session.navigate(address) }
        return session
    }

    func stop() {
        bridge.stop()
        for session in sessions.values { session.webView.stopLoading() }
        sessions.removeAll()
        ThreadRunner.shared.ephemeralRuntimeContext = nil
        observation = nil
    }
}
