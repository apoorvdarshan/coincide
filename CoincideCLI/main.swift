import Foundation

// `coincide`: Coincide's command-line tool. It asks the running app through its control socket; see `CLIHelp`.
let environment = ProcessInfo.processInfo.environment
do {
    let invocation = try CLIParser.parse(Array(CommandLine.arguments.dropFirst())) {
        String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }
    if invocation.command == .help {
        print(CLIHelp.text)
        exit(0)
    }
    let client = try ControlClient(path: ControlPaths.socket(explicit: invocation.socket, environment: environment))
    var runner = CLIRunner(connection: client, environment: environment)
    runner.json = invocation.json
    exit(try runner.run(invocation.command))
} catch let error as CLIUsageError {
    FileHandle.standardError.write(Data("coincide: \(error.message)\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("coincide: \(error)\n".utf8))
    exit(1)
}
