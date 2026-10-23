import Foundation

/// Existing verified native fork primitives only. Portable inline delivery is
/// separate; this helper never claims a provider history-injection capability.
public enum ContextTransferNativeDelivery {
    public static func apply(review: ConversationHistoryReview, configuration: ProviderConfiguration,
                             session: any ProviderSession,
                             reserveClaude: @escaping @Sendable (ClaudeTranscriptPublication) async throws -> Void) async throws -> ProviderConversationSnapshot {
        try Task.checkCancellation()
        guard review.kind == .forkAfterRun, configuration.provider == review.sourceConfiguration.provider,
              configuration.workspacePath.utf8.elementsEqual(review.sourceConfiguration.workspacePath.utf8) else {
            throw ProviderHistoryError(.unsupported)
        }
        let result: ProviderConversationSnapshot
        switch configuration.provider {
        case .codex:
            guard configuration.codexRuntimeConfiguration == review.sourceConfiguration.codexRuntimeConfiguration else {
                throw ProviderHistoryError(.unsupported)
            }
            result = try await session.forkConversation(source: review.sourceReference, boundary: review.boundary, configuration: configuration)
        case .claude:
            guard let evidence = review.claude, let runtime = configuration.claudeRuntimeConfiguration,
                  runtime == review.sourceConfiguration.claudeRuntimeConfiguration else { throw ProviderHistoryError(.unsupported) }
            let service = try ClaudeHistoryService(configuration: runtime)
            let plan = try service.prepareFork(review: evidence, targetSessionID: UUID().uuidString.lowercased())
            let fork = try await service.publishFork(plan, reservation: reserveClaude)
            result = try .init(reference: fork.reference, workspacePath: fork.workspacePath, historyMode: .nativeTranscript, claude: fork)
        default: throw ProviderHistoryError(.unsupported)
        }
        try Task.checkCancellation()
        try review.validateResult(result)
        return result
    }
}
