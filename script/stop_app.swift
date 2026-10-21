import AppKit

let target = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
for app in NSWorkspace.shared.runningApplications where app.bundleURL?.standardizedFileURL == target {
    guard app.terminate() else {
        fputs("Coincide could not quit. Close this development app before rebuilding.\n", stderr)
        exit(1)
    }
    let deadline = Date().addingTimeInterval(8)
    while !app.isTerminated && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    guard app.isTerminated else {
        fputs("Coincide is still closing. The build stopped without forcing it to quit.\n", stderr)
        exit(1)
    }
}
