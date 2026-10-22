import Foundation

extension CodingThread {
    /// Adds a capture to the same selected runtime. Existing queued and active
    /// configurations retain their original values until their own dispatch.
    mutating func capturePiRuntime(_ runtime: PiRuntimeConfiguration) throws {
        do { try runtime.validate() }
        catch { throw WorkspaceCommandError("Choose a valid Pi runtime and storage namespace.") }
        guard provider == .pi, let selected = piConfiguration,
              selected.instanceID == runtime.instanceID, selected.executable == runtime.requestedExecutable,
              runtime.registeredWorkspacePath == workspacePath,
              selected.runtime == nil || selected.runtime == runtime else { throw WorkspaceCommandError("The Pi runtime capture belongs to another conversation configuration.") }
        piConfiguration = .init(instanceID: selected.instanceID, executable: selected.executable,
            model: selected.model, thinkingLevel: selected.thinkingLevel, runtime: runtime)
    }

    mutating func preparePiRunHistory(_ preparation: PiRunHistoryPreparation) throws {
        try preparation.validate()
        guard provider == .pi, let run = activeRun, !run.stopRequested, run.id == preparation.runID,
              run.configuration.provider == .pi,
              run.configuration.piConfiguration?.runtimeIdentity == preparation.runtimeIdentity,
              let index = runHistory?.firstIndex(where: { $0.id == run.id }),
              runHistory?[index].origin == .user, runHistory?[index].status.isTerminal == false,
              runHistory?[index].configuration == run.configuration,
              runHistory?[index].userMessageID == preparation.openingInput.clientMessageID,
              providerThreadID == nil || providerThreadID == preparation.nativeSessionFile,
              runHistory?[index].providerThreadID == nil || runHistory?[index].providerThreadID == preparation.nativeSessionFile else {
            throw PiHistoryGraphError(.invalidWindow)
        }
        let evidence = try PiRunHistoryEvidence(preparation: preparation)
        guard runHistory?[index].pi == nil || runHistory?[index].pi == evidence else { throw PiHistoryGraphError(.invalidWindow) }
        providerThreadID = preparation.nativeSessionFile
        runHistory?[index].providerThreadID = preparation.nativeSessionFile
        runHistory?[index].pi = evidence
    }

    mutating func registerPiSteeringInput(runID: UUID, input: PiHistoryInputEvidence) throws {
        guard let index = runHistory?.firstIndex(where: { $0.id == runID }), var evidence = runHistory?[index].pi,
              activeRun?.id == runID, activeRun?.stopRequested == false,
              runHistory?[index].status.isTerminal == false else { throw PiHistoryGraphError(.invalidWindow) }
        try evidence.registerSteering(input)
        runHistory?[index].pi = evidence
    }

    mutating func mergePiHistoryEvidence(_ observed: PiRunHistoryEvidence) throws {
        guard let index = runHistory?.firstIndex(where: { $0.id == observed.runID }),
              let previous = runHistory?[index].pi,
              runHistory?[index].configuration.piConfiguration?.runtimeIdentity == observed.runtimeIdentity,
              runHistory?[index].providerThreadID == observed.nativeSessionFile else { throw PiHistoryGraphError(.invalidWindow) }
        runHistory?[index].pi = try previous.merging(observed)
    }
}
