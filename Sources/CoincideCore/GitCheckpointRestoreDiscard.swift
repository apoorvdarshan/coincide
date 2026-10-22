import Darwin
import Foundation

extension GitCheckpointService {
    /// Discards only a proven unused review's temporary copies. Applied/interrupted
    /// restores and their recovery preimages are always retained.
    public func discardRestoreReview(_ review: GitCheckpointRestoreReview) async throws -> GitCheckpointScratchResult {
        try review.validate(); try Task.checkCancellation()
        return try await GitOperationGate.shared.perform(key: review.currentPlan.commonDirectoryPath) {
            do {
                try validateSession(review.currentPlan)
                let common = try GitWorktreeDirectory(path: review.currentPlan.commonDirectoryPath)
                try common.validate(expected: review.currentPlan.commonDirectoryIdentity)
                let metadata = try GitWorktreeDirectory(child: CheckpointRestoreFiles.name(review.id), parent: common)
                let marker = Data((review.manifestDigest + "\n").utf8)
                guard let bytes = try metadata.read("manifest.json", maximum: CheckpointRestoreFiles.maximumManifest),
                      CheckpointFiles.digest(bytes) == review.manifestDigest,
                      let manifest = try? JSONDecoder().decode(CheckpointRestoreManifest.self, from: bytes),
                      manifest.current == review.currentPlan, manifest.target == review.targetReceipt, manifest.id == review.id,
                      let record = try metadata.read("review.json", maximum: CheckpointRestoreFiles.maximumManifest),
                      try JSONDecoder().decode(GitCheckpointRestoreReview.self, from: record) == review else { return .preserved }
                guard try !metadata.exists("started.json"), try !metadata.exists("complete.json") else { return .preserved }
                if let complete = try metadata.read("discard-complete.json") {
                    guard complete == marker,
                          try metadata.read("discard-started.json") == marker else { return .preserved }
                    let parent = try GitWorktreeDirectory(path: manifest.parentPath)
                    try parent.validate(expected: manifest.parentIdentity)
                    guard try !parent.exists(CheckpointRestoreFiles.name(review.id)),
                          try CheckpointRestoreFiles.names(metadata) == ["discard-complete.json", "discard-started.json", "execution.lock", "manifest.json", "review.json"] else { return .preserved }
                    return .alreadyRemoved
                }
                // Partial cleanup is preserved, never interpreted as a fresh review.
                guard try !metadata.exists("discard-started.json") else { return .preserved }
                let deadline = ContinuousClock.now.advanced(by: timeout), context = try await discover(deadline: deadline)
                try validate(review.currentPlan, context)
                let owned = try restoreOwned(review, context)
                guard let lock = try restoreExecutionLock(owned) else { return .preserved }
                defer { withExtendedLifetime(lock) {} }
                let retained: Set<String> = ["manifest.json", "review.json"]
                let actual = try CheckpointRestoreFiles.scan(metadata, protectRepositories: false).filter { !retained.contains($0.path) }
                guard actual == manifest.metadataScratch,
                      try CheckpointRestoreFiles.scan(owned.data, protectRepositories: false) == manifest.dataScratch,
                      try CheckpointRestoreFiles.names(owned.recovery).isEmpty else { return .preserved }
                try metadata.writeExclusive(marker, name: "discard-started.json")
                try CheckpointRestoreFiles.removeOwned(manifest.dataScratch, from: owned.data)
                guard try CheckpointRestoreFiles.names(owned.data).isEmpty else { return .preserved }
                try owned.data.validate(expected: manifest.dataIdentity); try owned.parent.validate(expected: manifest.parentIdentity)
                guard unlinkat(owned.parent.fd, CheckpointRestoreFiles.name(review.id), AT_REMOVEDIR) == 0, fsync(owned.parent.fd) == 0 else { return .preserved }
                try CheckpointRestoreFiles.removeOwned(manifest.metadataScratch.filter { $0.path != "execution.lock" }, from: metadata)
                guard try CheckpointRestoreFiles.names(metadata) == ["discard-started.json", "execution.lock", "manifest.json", "review.json"],
                      try metadata.read("manifest.json", maximum: CheckpointRestoreFiles.maximumManifest) == bytes,
                      try metadata.read("review.json", maximum: CheckpointRestoreFiles.maximumManifest) == record else { return .preserved }
                try metadata.writeExclusive(marker, name: "discard-complete.json")
                return .removed
            } catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation(); return .preserved }
        }
    }
}
