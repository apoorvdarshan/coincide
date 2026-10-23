import CoincideCore
import CoincideTerminal
import Darwin
import Foundation

if CommandLine.arguments.dropFirst().first == "--run-id" {
    exit(ProjectScriptHelper.run(arguments: CommandLine.arguments))
}

let scriptFactory = try? RemoteEnvironmentScriptHelper.factory(executableURL: Bundle.main.executableURL)
exit(await RemoteEnvironmentStdio.run(arguments: CommandLine.arguments, driverFactory: { launch in
    try NativePTYSession.defaultShell(launch)
}, projectScriptFactory: scriptFactory))
