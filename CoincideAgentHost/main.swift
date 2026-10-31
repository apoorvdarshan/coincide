import AppKit
import CoincideKit

// Coincide's agent host: a LaunchAgent that launchd starts when the app first messages its Mach service. It owns
// the provider sessions, so agents keep working while Coincide quits, crashes or updates (`AgentHostCore`).
// An app bundle without a Dock icon (LSUIElement), so it can post notifications while Coincide is closed.
//
// First it moves to its own copy of this build (`AgentHostRuntime`), so an update that replaces Coincide.app never
// changes the files of a host that still runs agents. `exec` returns only if it fails; the host then runs from here.
AgentHostRelocation.execCopyIfNeeded()
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let service = AgentHostService()
service.start()
application.run()
