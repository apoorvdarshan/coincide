import Foundation

/// Runs saved inputs through a fuzzer's check without libFuzzer, so the seed corpus and crash
/// reproducers work with any Swift toolchain (Apple's has no libFuzzer runtime).
public enum Replay {
    /// Runs every file named on the command line (directories are searched) through `check`. With no
    /// arguments it replays `Corpus/<name>` next to Package.swift, found from `mainFile`.
    public static func main(name: String, mainFile: String = #filePath, _ check: ([UInt8]) -> Void) {
        var paths = Array(CommandLine.arguments.dropFirst())
        if paths.isEmpty {
            let package = URL(fileURLWithPath: mainFile).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            paths = [package.appendingPathComponent("Corpus").appendingPathComponent(name).path]
        }
        var files: [String] = []
        for path in paths { collect(path, into: &files) }
        guard !files.isEmpty else {
            FileHandle.standardError.write(Data("\(name): no inputs found in \(paths.joined(separator: ", "))\n".utf8))
            exit(1)
        }
        for file in files {
            guard let data = FileManager.default.contents(atPath: file) else {
                FileHandle.standardError.write(Data("\(name): cannot read \(file)\n".utf8))
                exit(1)
            }
            // Printed first so a failing check can be traced to its input.
            print("\(name): \(file)")
            check([UInt8](data))
        }
        print("\(name): \(files.count) input(s) passed")
    }

    private static func collect(_ path: String, into files: inout [String]) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            FileHandle.standardError.write(Data("missing: \(path)\n".utf8))
            exit(1)
        }
        guard isDirectory.boolValue else {
            files.append(path)
            return
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        for name in names.sorted() where !name.hasPrefix(".") {
            collect((path as NSString).appendingPathComponent(name), into: &files)
        }
    }
}
