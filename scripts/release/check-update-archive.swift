// Runs the in-app updater's own checks (CoincideKit/Updates) on a release's ZIP before it is published, so a release
// the updater would refuse never ships. scripts/release/verify.sh compiles it with those files:
//
//   check-update-archive <Coincide-macos-universal.zip> <version> <team ID>
//
// It reads release metadata shaped like GitHub's for the asset, as an older Coincide would, then checks the archive's
// size and SHA-256, extracts it with the updater's ZIP reader and verifies the bundle: identifier, version, Developer ID
// team, nested code, this Mac's architecture and Gatekeeper.
import Foundation

@main
struct CheckUpdateArchive {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            FileHandle.standardError.write(Data("usage: check-update-archive <zip> <version> <team ID>\n".utf8))
            exit(2)
        }
        let zip = URL(fileURLWithPath: arguments[1])
        let version = arguments[2], team = arguments[3]
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("check-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            let size = try zip.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let name = zip.lastPathComponent
            let metadata: [String: Any] = [
                "tag_name": "v\(version)", "draft": false, "prerelease": false,
                "assets": [[
                    "name": name, "size": size, "digest": "sha256:\(try AppUpdateSecurity.digest(zip))",
                    "browser_download_url": "\(AppUpdateRelease.repository)/releases/download/v\(version)/\(name)",
                ]],
            ]
            let data = try JSONSerialization.data(withJSONObject: metadata)
            for architecture in ["arm64", "x86_64"] {
                guard try AppUpdateRelease.parse(data, newerThan: "0.0.0", architecture: architecture) != nil else {
                    throw AppUpdateError.metadata
                }
            }
            guard let release = try AppUpdateRelease.parse(data, newerThan: "0.0.0") else { throw AppUpdateError.metadata }
            try AppUpdateStaging.checkArchive(zip, release: release)
            try UpdateArchive.extract(zip, to: scratch)
            try AppUpdateSecurity.verifyBundle(scratch.appendingPathComponent("Coincide.app"), release: release, team: team,
                                               currentVersion: "0.0.0")
            print("The in-app updater accepts \(name) as Coincide \(version).")
        } catch {
            FileHandle.standardError.write(Data("error: the in-app updater would refuse \(zip.lastPathComponent): \(error)\n".utf8))
            exit(1)
        }
    }
}
