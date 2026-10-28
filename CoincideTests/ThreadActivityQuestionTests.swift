import AppKit
import Testing

@testable import Coincide
@testable import CoincideKit

@MainActor
@Suite(.serialized)
struct ThreadActivityQuestionTests {
    @Test func questionsNotifyWithoutChangingApprovalCounts() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let changes = ThreadIDRecorder(.coincideThreadActivityChanged)
        let approval = fixture.append(.approval, status: .waiting)
        let question = fixture.append(.question, status: .waiting)
        fixture.append(.question, status: .completed)

        #expect(fixture.activity.pendingQuestionCount(fixture.id) == 1)
        #expect(fixture.activity.pendingApprovalCount(fixture.id) == 1)
        #expect(fixture.activity.totalPendingApprovals == 1)
        #expect(changes.ids == [fixture.id, fixture.id])

        fixture.store.updateItem(question, in: fixture.id) { $0.status = .completed }
        #expect(fixture.activity.pendingQuestionCount(fixture.id) == 0)
        #expect(fixture.activity.totalPendingApprovals == 1)
        #expect(changes.ids == [fixture.id, fixture.id, fixture.id])

        fixture.store.updateItem(approval, in: fixture.id) { $0.status = .declined }
        #expect(fixture.activity.totalPendingApprovals == 0)
    }

    @Test func editedQuestionsTrackWaitingStateAndKindChanges() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let question = fixture.append(.question, status: .completed)
        let changes = ThreadIDRecorder(.coincideThreadActivityChanged)

        fixture.store.updateItem(question, in: fixture.id) { $0.status = .waiting }
        #expect(fixture.activity.pendingQuestionCount(fixture.id) == 1)
        fixture.store.updateItem(question, in: fixture.id) { $0.title = "Clarified question" }
        #expect(changes.ids == [fixture.id])

        fixture.store.updateItem(question, in: fixture.id) { $0.kind = .approval }
        #expect(fixture.activity.pendingQuestionCount(fixture.id) == 0)
        #expect(fixture.activity.pendingApprovalCount(fixture.id) == 1)
        #expect(changes.ids == [fixture.id, fixture.id])

        fixture.store.updateItem(question, in: fixture.id) { $0.kind = .notice }
        #expect(fixture.activity.pendingApprovalCount(fixture.id) == 0)
        #expect(changes.ids.count == 3)
    }

    @Test func truncationAndDeletionRemoveWaitingQuestions() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.append(.approval, status: .waiting)
        fixture.append(.question, status: .waiting)
        let second = fixture.append(.question, status: .waiting)
        let changes = ThreadIDRecorder(.coincideThreadActivityChanged)

        fixture.store.truncate(fixture.id, from: second)
        #expect(fixture.activity.pendingQuestionCount(fixture.id) == 1)
        #expect(fixture.activity.pendingApprovalCount(fixture.id) == 1)
        #expect(changes.ids == [fixture.id])

        fixture.store.deleteThread(fixture.id)
        #expect(fixture.activity.pendingQuestionCount(fixture.id) == 0)
        #expect(fixture.activity.totalPendingApprovals == 0)
        #expect(changes.ids == [fixture.id, fixture.id])
    }

    @Test func questionCountsDoNotReloadAnEvictedTranscript() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.append(.question, status: .waiting)
        fixture.store.flush()
        fixture.store.transcriptCacheLimit = 0
        let deadline = Date().addingTimeInterval(10)
        while fixture.store.isTranscriptLoaded(fixture.id), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!fixture.store.isTranscriptLoaded(fixture.id))
        let reads = fixture.store.transcriptReads
        #expect(fixture.activity.pendingQuestionCount(fixture.id) == 1)
        #expect(fixture.activity.pendingApprovalCount(fixture.id) == 0)
        #expect(fixture.activity.totalPendingApprovals == 0)
        #expect(fixture.store.transcriptReads == reads)
        #expect(!fixture.store.isTranscriptLoaded(fixture.id))
    }

    private struct Fixture {
        let folder = TemporaryDirectory("question-activity")
        let store: AppStore
        let activity: ThreadActivity
        let project: Project
        let id: UUID

        init() {
            store = AppStore(directory: folder.url)
            activity = ThreadActivity(store: store)
            activity.start()
            project = store.addProject(at: folder.url)
            id = store.createThread(in: project.id).id
        }

        @discardableResult
        func append(_ kind: TranscriptItem.Kind, status: ItemStatus) -> UUID {
            store.append(TranscriptItem(kind: kind, status: status), to: id)
        }

        func cleanUp() {
            store.removeProject(project.id)
            NSApp.dockTile.badgeLabel = nil
        }
    }
}
