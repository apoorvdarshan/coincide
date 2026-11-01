import Foundation

/// Extra details read with the user's sign-in in Coincide's browser (`BrowserUsageSource`), each site only while the
/// user has it turned on in Settings › Usage. Reads run when a usage view opens (at most every
/// `browserUsageInterval`, or every minute while the last one failed) and when the user refreshes. A read that fails
/// keeps what the agents report and adds a note saying why; a sign-in that is gone drops the site's figures.
extension UsageInsights {
    /// Whether the user turned on reading `source` with their browser sign-in.
    public func isBrowserSignInEnabled(_ source: BrowserUsageSource) -> Bool {
        store.settings.usageBrowserSignIn.contains(source)
    }

    /// Turns reading `source` on (and reads it now) or off (and forgets what it read).
    public func setBrowserSignIn(_ source: BrowserUsageSource, enabled: Bool) {
        store.updateSettings { settings in
            settings.usageBrowserSignIn.removeAll { $0 == source }
            if enabled { settings.usageBrowserSignIn.append(source) }
        }
        if enabled {
            Task { await readBrowserUsage(source, force: true) }
        } else {
            forgetBrowserUsage(source)
        }
    }

    /// Reads every site the user turned on, each when its last read is stale (or always, with `force`).
    public func readBrowserUsage(force: Bool = false) async {
        let sources = BrowserUsageSource.allCases.filter(isBrowserSignInEnabled)
        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask { await self.readBrowserUsage(source, force: force) }
            }
        }
    }

    /// Reads one site with the profile's cookies for it.
    public func readBrowserUsage(_ source: BrowserUsageSource, force: Bool = false) async {
        guard isBrowserSignInEnabled(source), let cookies = browserCookies else { return }
        var state = browserStates[source] ?? BrowserUsageState(source: source)
        guard !state.isReading else { return }
        if !force, let checked = state.checkedAt {
            let wait = state.problem == nil ? browserUsageInterval : 60
            if Date().timeIntervalSince(checked) < wait { return }
        }
        state.isReading = true
        browserStates[source] = state
        changed()

        let cookie = await cookies(source)
        let fetch = browserFetch
        let outcome: BrowserUsageOutcome =
            switch source {
            case .chatGPT: await ChatGPTCodexBilling.read(cookie: cookie, fetch: fetch)
            case .claudeConsole: await ClaudeConsoleBilling.read(cookie: cookie, fetch: fetch)
            case .openCodeConsole: await OpenCodeConsoleBilling.read(cookie: cookie, fetch: fetch)
            }
        // Turned off while the read ran: keep nothing.
        guard isBrowserSignInEnabled(source) else { return forgetBrowserUsage(source) }
        state = browserStates[source] ?? BrowserUsageState(source: source)
        state.isReading = false
        state.checkedAt = Date()
        switch outcome {
        case .reading(let reading):
            state.reading = reading
            state.problem = nil
        case .problem(let problem):
            state.problem = problem
            // Without a sign-in (or access), the last figures are no longer the user's to see; a passing failure
            // (offline, a server error) keeps them, noted as not current.
            if problem.needsSignIn || problem == .forbidden || problem == .noAPIOrganization || problem == .noBilling {
                state.reading = nil
            }
        }
        browserStates[source] = state
        changed()
        if source == .chatGPT {
            if case .reading = outcome, let reader = creditHistoryReader {
                await readCreditHistory(reader)
            } else if state.reading == nil {
                creditHistory = nil
                creditHistoryProblem = nil
            }
        }
    }

    private func readCreditHistory(_ reader: @MainActor () async -> ChatGPTCodexBilling.HistoryOutcome) async {
        let outcome = await reader()
        guard isBrowserSignInEnabled(.chatGPT) else { return forgetBrowserUsage(.chatGPT) }
        switch outcome {
        case .rows(let rows):
            creditHistory = ChatGPTCodexBilling.history(rows: rows)
            creditHistoryProblem = nil
        case .problem(let problem):
            creditHistoryProblem = problem
            if problem.needsSignIn { creditHistory = nil }
        }
        changed()
    }

    private func forgetBrowserUsage(_ source: BrowserUsageSource) {
        browserStates[source] = nil
        if source == .chatGPT {
            creditHistory = nil
            creditHistoryProblem = nil
        }
        changed()
    }

    /// The accounts the site's details go to (see `browserTargets`).
    public func browserAccounts(for source: BrowserUsageSource) -> [ProviderAccount] {
        let accounts = registry.accounts(for: source.provider)
        let targets = Self.browserTargets(
            source, accounts: accounts.map { ($0, registry.status(source.provider, account: $0.id).account) },
            email: browserStates[source]?.reading?.email)
        return accounts.filter { targets.contains($0.id) }
    }

    /// Which of a provider's accounts a site's details belong to, by account ID.
    /// - chatgpt.com: the Codex accounts signed in to ChatGPT with the browser's email (the account label Codex reports
    ///   names it). When no label names any email, a single ChatGPT account is taken to be it. A sign-in with another
    ///   email goes to no account rather than to the wrong one.
    /// - The Claude Console: Anthropic API-key accounts, whose credit it is; with none, the default Claude account
    ///   (a subscription's API credit shows in the Console too).
    /// - The OpenCode Console: the default OpenCode account, which signs in to the Console or holds a Zen key, and
    ///   accounts with an OpenCode Zen key. Accounts with another provider's key spend nothing from Zen.
    nonisolated static func browserTargets(
        _ source: BrowserUsageSource, accounts: [(account: ProviderAccount, label: String?)], email: String?
    ) -> Set<String> {
        switch source {
        case .chatGPT:
            let logins = accounts.filter { $0.account.auth == .login }
            if let email = email?.lowercased(), !email.isEmpty {
                let matched = logins.filter { $0.label?.lowercased().contains(email) == true }
                if !matched.isEmpty { return Set(matched.map(\.account.id)) }
            }
            let unnamed = logins.allSatisfy { !($0.label ?? "").contains("@") }
            return unnamed && logins.count == 1 ? [logins[0].account.id] : []
        case .claudeConsole:
            let keys = accounts.filter {
                $0.account.auth == .apiKey && APIKeyUsage.service(forVariable: $0.account.keyVariable) == .anthropic
            }
            if !keys.isEmpty { return Set(keys.map(\.account.id)) }
            return accounts.contains { $0.account.isDefault } ? [ProviderAccount.defaultID] : []
        case .openCodeConsole:
            return Set(
                accounts.filter {
                    $0.account.isDefault
                        || ($0.account.auth == .apiKey && APIKeyUsage.service(forVariable: $0.account.keyVariable) == .openCodeZen)
                }.map(\.account.id))
        }
    }

    /// `limits` with what the account's site read added: figures the agent didn't report itself, credits (or a
    /// balance) it left out, and a note when the read failed.
    func addingBrowserDetails(
        to limits: UsageLimits?, provider: ProviderKind, account: ProviderAccount, accounts: [ProviderAccount], now: Date = Date()
    ) -> UsageLimits? {
        guard let source = BrowserUsageSource.allCases.first(where: { $0.provider == provider }), isBrowserSignInEnabled(source),
            let state = browserStates[source]
        else { return limits }
        let targets = Self.browserTargets(
            source, accounts: accounts.map { ($0, registry.status(provider, account: $0.id).account) }, email: state.reading?.email)
        guard targets.contains(account.id) else { return limits }
        return Self.adding(state, history: source == .chatGPT ? (creditHistory, creditHistoryProblem) : (nil, nil), to: limits, now: now)
    }

    /// The merge itself, apart from the store so tests can call it.
    nonisolated static func adding(
        _ state: BrowserUsageState, history: (uses: [ChatGPTCodexBilling.CreditUse]?, problem: BrowserUsageProblem?),
        to limits: UsageLimits?, now: Date
    ) -> UsageLimits? {
        let source = state.source
        var figures = state.reading?.figures ?? []
        var notes: [String] = []
        if let problem = state.problem { notes.append(problem.note(source)) }
        if state.reading != nil, source == .chatGPT {
            if let uses = history.uses {
                figures.append(ChatGPTCodexBilling.historyFigure(uses, now: now))
            } else if let problem = history.problem {
                notes.append(String(localized: "Couldn’t read the credit history on chatgpt.com. \(problem.reason)"))
            }
        }
        let credits = state.reading?.credits
        guard !figures.isEmpty || !notes.isEmpty || credits != nil else { return limits }
        var merged = limits ?? UsageLimits(windows: [], checkedAt: state.reading?.checkedAt ?? state.checkedAt ?? now)
        let own = Set(merged.figures.map(\.id))
        merged.figures += figures.filter { !own.contains($0.id) }
        if let credits {
            if merged.credits == nil {
                merged.credits = credits
            } else if merged.credits?.balance == nil, !(merged.credits?.unlimited ?? false), let balance = credits.balance {
                merged.credits?.balance = balance
            }
        }
        for note in notes where !merged.notes.contains(note) { merged.notes.append(note) }
        if source == .claudeConsole, state.reading != nil {
            // The Console's balance answers the note that the API can't show it.
            merged.notes.removeAll { $0 == AnthropicAdminUsage.balanceNote }
        }
        if source == .openCodeConsole, state.reading != nil {
            // So does the OpenCode Console's, for a Zen key.
            let unanswered = Set(APIKeyUsage.notes(for: .openCodeZen))
            merged.notes.removeAll { unanswered.contains($0) }
        }
        return merged
    }
}
