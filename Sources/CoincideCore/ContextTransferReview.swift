import Foundation

extension ContextTransferReview {
    func validatedDigest() throws -> String { var copy = self; copy.digest = ""; return try ContextTransferProtocol.digest(copy) }
}
