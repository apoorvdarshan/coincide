import AppKit
import Foundation

// Independent signed helper, launched only after the user chooses Install on Quit.
// No terminate, kill, open, or relaunch operation is performed here.
guard CommandLine.arguments.count == 2 else { exit(2) }
let planURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let job = planURL.deletingLastPathComponent()
var quitGate = AppUpdateQuitGate()
var appBundle: Bundle?
@MainActor func showResult(_ installed: Bool) {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let alert = NSAlert()
    let bundle = appBundle ?? .main
    alert.messageText = installed
        ? String(localized: "Update installed. Reopen Coincide when you are ready.", bundle: bundle)
        : String(localized: "The update could not be installed. The previous app has been kept.", bundle: bundle)
    alert.addButton(withTitle: String(localized: "OK", bundle: bundle))
    application.activate()
    alert.runModal()
}
do {
    let plan = try JSONDecoder().decode(AppUpdatePlan.self, from: Data(contentsOf: planURL))
    appBundle = Bundle(url: plan.target)
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let team = try AppUpdateSecurity.signingTeam(at: executable)
    guard let parent = NSRunningApplication(processIdentifier: plan.processID),
          parent.bundleURL?.resolvingSymlinksInPath() == plan.target.resolvingSymlinksInPath(),
          parent.bundleIdentifier == AppUpdateSecurity.bundleID else { throw AppUpdateError.running }
    try AppUpdateSecurity.validateSignature(at: plan.target, team: team, identifier: AppUpdateSecurity.bundleID)
    try quitGate.waitForConsent(plan: plan, job: job) {
        try AppUpdateInstallation.waitForCleanExit(processID: plan.processID) {
            FileHandle.standardOutput.write(Data("READY\n".utf8))
        }
    }
    let backup = try AppUpdateInstallation.install(plan: plan, job: job, team: team) {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == AppUpdateSecurity.bundleID && !$0.isTerminated
        }
    }
    AppUpdateInstallation.recordSuccess(version: plan.release.version, backup: backup, job: job)
    showResult(true)
    exit(0)
} catch {
    try? JSONEncoder().encode(["state": "failed"]).write(to: job.appendingPathComponent("result.json"), options: .atomic)
    if quitGate.shouldReportFailure { showResult(false) }
    exit(1)
}
