import Foundation
import Testing
@testable import CoincideCore

private func link(_ value: String) -> Result<PromptLink.Link, PromptLink.ParseError> { PromptLink.parse(URL(string: value)!) }

@Test func promptLinkSanitizingRemovesHiddenCharactersAndKeepsEmojiJoiners() {
    let raw = "Fix\u{200B} the\u{202E} build\u{E0041}\r\nnow\u{2028}please\u{0007} 👩\u{200D}💻 a\u{200D}b \u{FEFF}"
    let prompt = PromptLink.sanitize(raw)
    #expect(prompt.text == "Fix the build\nnow\nplease 👩\u{200D}💻 ab")
    #expect(prompt.hiddenCharacters == 6)
    #expect(PromptLink.sanitize("  plain\ttext \n").text == "plain\ttext" && PromptLink.sanitize("plain").hiddenCharacters == 0)
}

@Test func promptLinksEnforceTheLengthLimitAndRejectHiddenOnlyPrompts() {
    let exact = String(repeating: "a", count: 8_000)
    #expect((try? link("coincide://new?prompt=\(exact)").get()) == .newThread(prompt: .init(text: exact, hiddenCharacters: 0), repository: nil, provider: nil, model: nil))
    #expect(link("coincide://new?prompt=\(exact)a") == .failure(.tooLong))
    #expect(link("coincide://new?prompt=%E2%80%8B%E2%80%8B") == .failure(.hiddenOnly))
    #expect(link("coincide://new?repo=acme/widget") == .failure(.missingPrompt))
    #expect(link("coincide://new?prompt=%20%20") == .failure(.missingPrompt))
}

@Test func promptLinksParseRepositoriesProvidersModelsAndPullRequests() throws {
    let parsed = try link("coincide://new?prompt=Fix+the%20build&repo=https://github.com/Acme/widget.git&provider=Codex&model=gpt-5.5&prompt=ignored").get()
    #expect(parsed == .newThread(prompt: .init(text: "Fix the build", hiddenCharacters: 0), repository: .init(owner: "Acme", name: "widget"), provider: "codex", model: "gpt-5.5"))
    #expect(PromptLink.repository("acme/widget")?.canonicalKey == "github.com/acme/widget")
    for invalid in ["-acme/widget", "acme/..", "https://gitlab.com/acme/widget", "acme", "acme/widget/extra"] { #expect(PromptLink.repository(invalid) == nil, "\(invalid)") }
    #expect(link("coincide://new?prompt=x&repo=not%20a%20repo") == .failure(.invalidRepository))
    #expect(PromptLink.pullRequest("acme/widget/42") == .init(repository: .init(owner: "acme", name: "widget"), number: 42))
    #expect(PromptLink.pullRequest("acme/widget#7")?.number == 7)
    #expect(PromptLink.pullRequest("https://github.com/acme/widget/pull/9/files")?.number == 9)
    #expect(PromptLink.pullRequest("acme/widget/0") == nil)
    #expect(try link("coincide://new?pr=acme/widget/42").get() == .pullRequest(.init(repository: .init(owner: "acme", name: "widget"), number: 42), prompt: nil))
    #expect(link("coincide://new?pr=nope&prompt=x") == .failure(.invalidPullRequest))
}

@Test func promptLinksParseThreadAndFolderLinksAndRejectOtherSchemesAndHosts() throws {
    let id = UUID()
    #expect(try link("coincide://threads/\(id.uuidString)?prompt=Hello").get() == .thread(id: id, prompt: .init(text: "Hello", hiddenCharacters: 0)))
    #expect(try link("coincide://threads/\(id.uuidString.lowercased())").get() == .thread(id: id, prompt: nil))
    #expect(link("coincide://threads/not-a-uuid") == .failure(.invalidThread))
    #expect(link("coincide://threads/env/\(id.uuidString)") == .failure(.invalidThread))
    #expect(try link("coincide://open?path=%2FUsers%2Fme%2FMy%20Project%2F..%2FApp").get() == .openFolder(path: "/Users/me/App"))
    #expect(link("coincide://open?path=relative/path") == .failure(.invalidPath))
    #expect(link("t3code://new?prompt=x") == .failure(.unsupported))
    #expect(link("https://example.com/new?prompt=x") == .failure(.unsupported))
    #expect(link("coincide://settings") == .failure(.unsupported))
    #expect(link("coincide://new/extra?prompt=x") == .failure(.unsupported))
}

@Test func promptLinksRoundTripThroughTheirBuilders() throws {
    let text = "Review café & résumé + 100% coverage?\nThen #ship"
    let url = try #require(PromptLink.newThreadURL(prompt: text, repository: .init(owner: "acme", name: "widget"), provider: "claude", model: "opus"))
    #expect(url.absoluteString.hasPrefix("coincide://new?prompt=") && !url.absoluteString.contains("+"))
    #expect(try PromptLink.parse(url).get() == .newThread(prompt: .init(text: text, hiddenCharacters: 0), repository: .init(owner: "acme", name: "widget"), provider: "claude", model: "opus"))
    #expect(PromptLink.newThreadURL(prompt: "x", model: "ignored without provider")?.absoluteString == "coincide://new?prompt=x")
    let id = UUID()
    #expect(try PromptLink.parse(#require(PromptLink.threadURL(id: id, prompt: "Next step"))).get() == .thread(id: id, prompt: .init(text: "Next step", hiddenCharacters: 0)))
    let folder = "/Users/me/Code/it's \"quoted\" & spaced"
    #expect(try PromptLink.parse(#require(PromptLink.openFolderURL(path: folder))).get() == .openFolder(path: folder))
}
