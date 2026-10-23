import CoincideCore
import CoincideTerminal
import Darwin

exit(await RemoteEnvironmentStdio.run(arguments: CommandLine.arguments, driverFactory: { launch in
    try NativePTYSession.defaultShell(launch)
}))
