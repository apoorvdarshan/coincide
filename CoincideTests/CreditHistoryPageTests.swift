import CoincideKit
import Testing
import WebKit

@testable import Coincide

/// The hidden page that reads chatgpt.com's credits usage history, run against synthetic pages loaded from strings
/// into temporary storage. The browser stays in a window that is never ordered in; nothing reaches the network.
@MainActor @Suite(.serialized) struct CreditHistoryPageTests {
    private let analytics = URL(string: "https://chatgpt.com/codex/cloud/settings/analytics")!

    private func read(_ html: String, at url: URL? = nil) async -> ChatGPTCodexBilling.HistoryOutcome {
        let page = CreditHistoryPage(dataStore: .nonPersistent())
        defer { page.close() }
        #expect(page.webView.window?.isVisible == false)
        return await page.read(html: html, baseURL: url ?? analytics)
    }

    @Test func readsTheRowsOfTheCreditsUsageHistoryTableOnly() async {
        let html = """
            <html><body>
            <section><h2>Usage breakdown</h2><table><tbody><tr><td>Oct 12, 2026</td><td>Other</td><td>1 credits</td></tr></tbody></table></section>
            <section><h2>Credits usage history</h2>
              <table><thead><tr><th>Date</th><th>Service</th><th>Credits</th></tr></thead>
              <tbody><tr><td>Oct 12, 2026</td><td>CLI</td><td>397.205 credits</td></tr>
                     <tr><td>Oct 11, 2026</td><td>GitHub  Code Review</td><td>1,250 credits</td></tr></tbody></table>
            </section></body></html>
            """
        let outcome = await read(html)
        #expect(outcome == .rows([["Oct 12, 2026", "CLI", "397.205 credits"], ["Oct 11, 2026", "GitHub Code Review", "1,250 credits"]]))
        if case .rows(let rows) = outcome {
            #expect(ChatGPTCodexBilling.history(rows: rows).map(\.credits) == [397.205, 1250])
        }
    }

    @Test func anEmptyTableIsAnEmptyHistoryAndASignInPageIsNotSignedIn() async {
        let empty = "<html><body><section><h3>Credits usage history</h3><table><tbody></tbody></table></section></body></html>"
        #expect(await read(empty) == .rows([]))
        let login = "<html><body><button data-testid=\"login-button\">Log in</button></body></html>"
        #expect(await read(login, at: URL(string: "https://chatgpt.com/auth/login")!) == .problem(.notSignedIn))
    }
}
