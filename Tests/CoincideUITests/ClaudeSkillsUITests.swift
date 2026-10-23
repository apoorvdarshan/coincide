import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private actor ClaudeSkillsUIReader {
    var calls = 0
    func commands(_ cwd: String) throws -> ProviderCommandInventory { calls += 1; throw ProviderCommandError(.unsupported) }
}

@Test func claudeSkillPickerRejectsCanonicallyEquivalentByteChangedManualSelection() throws {
    let original = "e\u{301}\u{323} literal 工作", changed = "e\u{323}\u{301} literal 工作"
    #expect(original == changed && !original.utf8.elementsEqual(changed.utf8))
    let selection = NSRange(location: 0, length: 3)
    let anchor = try #require(ComposerSkillMention.selection(in: original, range: selection))
    #expect(anchor.inserting(token: "$review", into: changed, selection: selection) == nil)
    #expect(anchor.inserting(token: "$review", into: original, selection: selection)?.text.utf8.elementsEqual("$review literal 工作".utf8) == true)
}
@Test(.timeLimit(.minutes(1))) @MainActor
func claudeFilesystemPickerKeepsAvailableSkillsWhenNativeCommandsAreUnavailableAndPreservesLiteralNames() async throws {
    var thread = CodingThread(project: .init(path: "/owned/claude-ui")); thread.provider = .claude
    let scope = ProviderSkillsStore.Scope(thread), peer = ClaudeSkillsUIReader(), cwd = thread.workspacePath
    let rows = [ProviderSkill(name: "Review", path: "/owned/upper/SKILL.md"), ProviderSkill(name: "review", path: "/owned/lower/SKILL.md", userInvocationOnly: true),
        ProviderSkill(name: "hidden", path: "/owned/hidden/SKILL.md", userInvocable: false), ProviderSkill(name: "off", path: "/owned/off/SKILL.md", enabled: false)]
    let model = ProviderSkillsStore(scope: scope, skillRead: { _ in .init(cwd: cwd, skills: rows) },
        commandRead: { _ in try await peer.commands(cwd) })
    await model.refresh()
    #expect(model.supportsSkills && model.supportsCommands && model.skills.map(\.name) == ["Review", "review"])
    #expect(model.errorMessage == nil && model.inventory?.isPartial == false && model.commandInventory?.isPartial == true && model.commands.isEmpty)
    #expect(SkillPicker.matching(model.skills, query: "rev").map(\.promptToken).contains("$review"))
    await model.refresh(); #expect(await peer.calls == 1)
    await model.shutdown(); #expect(model.skills.isEmpty && model.isClosed)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func claudeFilesystemSkillPickerOffscreenFitsLightDarkBoundsWithoutReadingOrInvoking() async throws {
    _ = NSApplication.shared
    var thread = CodingThread(project: .init(path: "/owned/claude-ui")); thread.provider = .claude
    let rows = [ProviderSkill(name: "engineering:review", path: "/owned/plugin/skills/review/SKILL.md", description: "Review changes from captured plugin metadata", scope: "project", userInvocationOnly: true)]
    let cwd = thread.workspacePath
    let model = ProviderSkillsStore(scope: .init(thread), read: { _ in .init(cwd: cwd, skills: rows) })
    await model.refresh()
    for scheme in [ColorScheme.light, .dark] {
        let view = SkillPicker(model: model, query: .constant(""), searchField: true, selectedID: rows[0].id,
            choose: { _ in Issue.record("Layout cannot insert a skill") }, move: { _ in }, confirm: { Issue.record("Layout cannot submit") }, dismiss: {})
            .environment(\.colorScheme, scheme)
        let host = NSHostingController(rootView: view), bounds = CGSize(width: 480, height: 560), fitted = host.sizeThatFits(in: CGSize(width: 480, height: 560))
        #expect(fitted.width.isFinite && fitted.height.isFinite && fitted.width > 0 && fitted.height > 0 && fitted.width <= bounds.width + 1 && fitted.height <= bounds.height + 1)
        host.view.frame = CGRect(origin: .zero, size: fitted); host.view.layoutSubtreeIfNeeded(); #expect(host.view.window == nil)
    }
    #expect(model.skills.map(\.promptToken) == ["$engineering:review"] && !model.isLoading)
    await model.shutdown()
}
