import AppKit

// Coincide's agent host: a LaunchAgent that launchd starts when the app first messages its Mach service. It owns
// the provider sessions, so agents keep working while Coincide quits, crashes or updates (`AgentHostCore`).
// An app bundle without a Dock icon (LSUIElement), so it can post notifications while Coincide is closed.
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let service = AgentHostService()
service.start()
application.run()
