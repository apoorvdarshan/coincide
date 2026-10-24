# Native UI coverage migration

The app now uses one native window, embedded Settings, a combined model popover,
and Codex/Claude conversations. This migration does not reintroduce the removed
remote workspace, Git inspector, project script, worktree preparation, Pi, or
run-history launch surfaces. Existing Core and SwiftUI contract suites remain in
the full Swift test job. The desktop suite discovers every test and requires each
one to pass exactly once across the four isolated runners; there are no skips.

The desktop suite has **31 cases**: ten retained workflows adapted to current
controls, twenty new Settings/integration/configuration/session/sidebar cases,
and one replacement file-reference workflow. This describes coverage, not a
claim that a hosted run has already passed.

The SwiftUI keyboard suites retain focus classification, type-to-focus, window
ownership, attached-sheet isolation, navigation, search, copy, pin, shortcut
overrides and duplicate-event suppression. Inspector/reopen/terminal/remote
commands now assert refusal without changing the chat. The former terminal
dispatcher integration case exercises override routing and single delivery on
the current sidebar/find actions; terminal library contracts remain under
`Tests/CoincideTerminalTests`. The sidebar assertion follows the native shell's
visibility state instead of requiring the removed split controller.

## Retained desktop workflows

These original tests still run, with native button-list, popover and embedded
Settings selectors updated where necessary:

- `testNativeMainWindowCloseNewWindowAndReopenPreserveUnsentWorkspace`
- `testLightCodexSkillsKeyboardInsertionRefreshAndUnsentDraftRestoration`
- `testDarkCodexSkillsKeyboardInsertionRefreshAndUnsentDraftRestoration`
- `testLightCodexOwnedAuthenticationSettingsPreserveUnsentConversation`
- `testDarkCodexOwnedAuthenticationSettingsPreserveUnsentConversation`
- `testNativeModelReasoningMenusResolveAdvertisedAndCLIDefaultsWithoutSending`
- `testNativeSteeringTargetsRunningTurnAndPreservesReceiptAcrossRestart`
- `testNativeClaudeQuestionSingleMultiCustomNotesAndCancellationPersistExactAnswers`
- `testLightAppearanceFileMenuProjectWorkflow`
- `testDarkAppearanceKeyboardProjectWorkflow`

They retain their assertions about immutable offline CLI peers, exact approval
answers, literal steering, draft and file preservation, provider RPC boundaries,
model defaults, account privacy, project removal and native window restoration.
Steering completion no longer requires an optional checkpoint to be enabled.

## Replaced desktop surfaces

Every old test not listed above is mapped below. Paths in this table are under
`Tests/`; the referenced suites continue to execute in the full Swift test job.

| Previous desktop test | Current UI coverage and retained behavioral coverage |
| --- | --- |
| `testRemoteWindowValidatesConnectionBeforeSSHAndPreservesLocalWorkspace` | `testNativeMenusExposeTheCurrentLocalChatSurface` verifies the retired Remote menu is absent. Remote validation remains in `CoincideCoreTests/RemoteWorkspaceCoreTests.swift`, `RemoteWorkspaceClientTests.swift`, and `CoincideUITests/RemoteWorkspaceStoreTests.swift`. |
| `testRemoteReviewedSettleScriptRequiresFullCommandApprovalAndStopDrainsOwnedJobs` | Remote affordance absence above; exact command review, restart, stop and process drain remain in `CoincideCoreTests/RemoteSettleScriptIntegrationTests.swift` and `CoincideUITests/RemoteProjectScriptStoreTests.swift`. |
| `testFilesEditorSearchReferencesAndQuitPreserveDisk` | File referencing is exercised by `testNativeFileReferencePickerSearchPreservesDraftAndDisk`; removed editor behavior remains in `CoincideCoreTests/WorkspaceFileServiceTests.swift` and the retained file-browser store tests. |
| `testProjectScriptsRequireReviewedLaunchAndPreserveDrafts` | Retired script launch surface; `CoincideCoreTests/ProjectScriptExecutionTests.swift` and `CoincideUITests/ProjectScriptUITests.swift` retain reviewed execution, file/draft ownership and cancellation checks. |
| `testRepositoryGroupingKeepsCheckoutDrafts` | Current sort selectors, project files and selected draft are exercised by `testNativeThreadSortModesPreserveTheSelectedDraft` and `testNativeProjectSortModesPersistWithoutRewritingProjectFiles`; grouping persistence remains in `CoincideCoreTests/ProjectOrganizationTests.swift` and `CoincideUITests/ProjectOrganizationUITests.swift`. |
| `testReviewedBlockingSetupKeepsDraftUntilExplicitContinue` | Retired setup launch surface; `CoincideCoreTests/ProjectScriptSetupEngineTests.swift` and `CoincideUITests/WorktreePreparationUITests.swift` retain blocked setup, explicit continuation and draft ownership contracts. |
| `testSettleScriptReviewAndExplicitResumeKeepDraftAndCheckout` | Retired settle action; `CoincideCoreTests/ThreadSettlementEngineTests.swift`, `ProjectScriptExecutionTests.swift` and `CoincideUITests/ThreadSettlementUITests.swift` retain settlement/review/resume contracts. |
| `testWorktreePreparationKeepsExplicitBaseDraftAndSourceFiles` | Retired preparation controls; `CoincideCoreTests/WorktreeEngineTests.swift`, `GitWorktreeTests.swift` and `CoincideUITests/WorktreePreparationUITests.swift` retain base choice, worktree and file/draft preservation checks. |
| `testNativePiHistoryQuestionsUseExactWorkerAndCancellationNeverSendsDraft` | Pi is no longer offered in current UI; `CoincideCoreTests/PiHistoryEngineTests.swift`, `PiHistoryNativeEngineTests.swift` and `CoincideUITests/PiHistoryUITests.swift` retain original-worker and cancellation behavior for saved legacy data. |
| `testNativePiUnknownHistoryKeepsOriginalAcrossRestartWithoutRepeatingNativeFork` | `CoincideCoreTests/PiHistoryEngineIntegrationTests.swift`, `PiHistoryOriginalSourceOracleTests.swift` and `CoincideUITests/PiHistoryCaptureUITests.swift` retain unknown outcomes, original source and no-replay behavior. |
| `testNativePiEmptyContextRecoveryRequiresExplicitAcknowledgementAndNeverReplaysUnknownInput` | `CoincideCoreTests/PiFreshSessionReducerTests.swift`, `PiHistoryEngineIntegrationTests.swift` and `CoincideUITests/PiHistoryUITests.swift` retain explicit acknowledgement and empty-context recovery. |
| `testNativeClaudeForkAndDeferredRewindPreserveSourceWithoutSendingAcrossRestart` | Run-history creation is no longer offered; `CoincideCoreTests/ClaudeHistoryEngineTests.swift`, `ClaudeHistoryReducerTests.swift` and `CoincideUITests/ClaudeHistoryUITests.swift` retain deferred rewind, exact reserved forks and source bytes. |
| `testNativeClaudeSelectedContextIsConsumedOnceBeforeQueuedSuccessor` | `CoincideCoreTests/ClaudeRuntimeHistoryTests.swift`, `ClaudeHistoryEngineTests.swift` and `CoincideUITests/ClaudeHistoryUITests.swift` retain once-only selected-context consumption and queue ordering. |
| `testNativeClaudeContextInspectionIsReadOnlyAndNeverReplaysConsumedOrUnwrittenInput` | `CoincideCoreTests/ClaudeHistoryReducerTests.swift`, `ClaudeRuntimeHistoryTests.swift` and `CoincideUITests/ClaudeHistoryUITests.swift` retain read-only reconciliation and consumed/unwritten input behavior. |
| `testNativeRunHistoryForkRewindAndRecallPreserveSourceDraftAndFiles` | `CoincideCoreTests/ConversationHistoryEngineTests.swift`, `ConversationHistoryFilesIntegrationTests.swift` and `CoincideUITests/ConversationHistoryUITests.swift` retain native fork/rewind, latest draft and exactly-once recall checks. |
| `testNativeCheckpointRestoreReviewsRealGitLossAndPreservesConversationAndSource` | Git inspector is retired; `CoincideCoreTests/CheckpointRestoreIntegrationTests.swift`, `GitCheckpointRestoreTests.swift` and `CoincideUITests/CheckpointRestoreUITests.swift` retain loss review, dirty editor protection and recoverable unknown results. |
| `testNativePullRequestReviewLostReplyAndReadOnlyInspectionPreserveDraftAndPublishedGit` | Git/PR launch surface is retired; `CoincideCoreTests/PullRequestCreationEngineTests.swift`, `PullRequestActionEngineTests.swift` and `CoincideUITests/PullRequestActionStoreTests.swift` retain lost-reply reconciliation and immutable Git/draft checks. |
| `testNativePullRequestCheckoutCreatesBlankWorktreeConversationAndPreservesSourceAcrossRestart` | `CoincideCoreTests/PullRequestCheckoutIntegrationTests.swift`, `PullRequestCheckoutConcurrencyTests.swift` and `CoincideUITests/PullRequestCheckoutStoreTests.swift` retain blank-worktree ownership, source preservation and restart recovery. |

## New coverage

- Embedded Settings in light/dark appearance, every integration page, searchable
  navigation, and a single owning window with the same unsent chat.
- Actual private config-file writes from native controls: explicit Save,
  external-edit conflicts, invalid values, pending edit cancellation, named
  plugin enablement and preserved unknown credentials/hooks.
- Skills library import, command metadata/search, MCP credential redaction and
  hook discovery without execution. Discovery uses disposable provider homes.
- Session search/filtering, unavailable runtime behavior, and an import sheet
  that explains copied ownership and waits for an explicit scan.
- Thread/project sort controls, archive/unarchive, rename, selected drafts and
  physical project files across restart.
- `ProviderConfigurationEditorTests.swift` adds fixture-only source safety,
  symlink, duplicate JSON key, TOML multiline/quoted-key, value validation,
  sensitive permission rule, scope and inheritance regressions.

SwiftUI host-layout tests now exercise embedded Settings instead of the deleted
inspector and source-control Settings view. Source-control token-store tests
remain unchanged. Full native desktop verification runs on GitHub Actions.
