import Foundation

/// T3's stacked Git actions. Each later step only runs after the earlier one succeeded.
public enum GitStackedAction: String, Codable, Sendable, CaseIterable {
    case commit, push, createPullRequest, commitPush, commitPushPullRequest
    public var includesCommit: Bool { [.commit, .commitPush, .commitPushPullRequest].contains(self) }
    public var includesPush: Bool { self != .commit }
    public var includesPullRequest: Bool { [.createPullRequest, .commitPushPullRequest].contains(self) }
}

/// Inputs mirror T3's VCS status fields so its quick-action table ports one to one.
public struct GitQuickActionStatus: Sendable, Equatable {
    public var hasBranch: Bool
    public var hasChanges: Bool
    public var hasOpenPullRequest: Bool
    public var aheadCount: Int
    public var behindCount: Int
    /// Commits on this branch that are not on the default branch; falls back to `aheadCount`.
    public var aheadOfDefaultCount: Int?
    public var hasUpstream: Bool
    public init(hasBranch: Bool = true, hasChanges: Bool = false, hasOpenPullRequest: Bool = false, aheadCount: Int = 0, behindCount: Int = 0,
                aheadOfDefaultCount: Int? = nil, hasUpstream: Bool = true) {
        self.hasBranch = hasBranch; self.hasChanges = hasChanges; self.hasOpenPullRequest = hasOpenPullRequest; self.aheadCount = aheadCount
        self.behindCount = behindCount; self.aheadOfDefaultCount = aheadOfDefaultCount; self.hasUpstream = hasUpstream
    }
}

public struct GitQuickAction: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case run(GitStackedAction), pull, publish, hint(String) }
    public let label: String
    public let disabled: Bool
    public let kind: Kind
    public var action: GitStackedAction? { if case .run(let action) = kind { return action }; return nil }
    public var hint: String? { if case .hint(let text) = kind { return text }; return nil }
}

public struct GitActionMenuItem: Sendable, Equatable, Identifiable {
    public enum ID: String, Sendable { case commit, push, pullRequest }
    public let id: ID
    public let label: String
    public let disabled: Bool
}

public struct GitDefaultBranchDialogCopy: Sendable, Equatable {
    public let title: String
    public let description: String
    public let continueLabel: String
}

public enum GitActionResolver {
    public static func menuItems(_ status: GitQuickActionStatus?, isBusy: Bool, hasPrimaryRemote: Bool = true) -> [GitActionMenuItem] {
        guard let status else { return [] }
        let hasDefaultDelta = (status.aheadOfDefaultCount ?? status.aheadCount) > 0, isBehind = status.behindCount > 0
        let canPushWithoutUpstream = hasPrimaryRemote && !status.hasUpstream
        let canCommit = !isBusy && status.hasChanges
        let canPush = !isBusy && status.hasBranch && !isBehind && status.aheadCount > 0 && (status.hasUpstream || canPushWithoutUpstream)
        let canCreate = !isBusy && status.hasBranch && !status.hasOpenPullRequest && hasDefaultDelta && !isBehind && (status.hasUpstream || canPushWithoutUpstream)
        let commit = GitActionMenuItem(id: .commit, label: String(localized: "Commit"), disabled: !canCommit)
        guard hasPrimaryRemote else { return [commit] }
        let push = GitActionMenuItem(id: .push, label: String(localized: "Push"), disabled: !canPush)
        if status.hasOpenPullRequest { return [commit, push] }
        return [commit, push, .init(id: .pullRequest, label: String(localized: "Create PR"), disabled: !canCreate)]
    }

    public static func quickAction(_ status: GitQuickActionStatus?, isBusy: Bool, isDefaultBranch: Bool = false, hasPrimaryRemote: Bool = true) -> GitQuickAction {
        if isBusy { return .init(label: String(localized: "Commit"), disabled: true, kind: .hint(String(localized: "Git action in progress."))) }
        guard let status else { return .init(label: String(localized: "Commit"), disabled: true, kind: .hint(String(localized: "Git status is unavailable."))) }
        let isAhead = status.aheadCount > 0, isBehind = status.behindCount > 0
        let hasDefaultDelta = (status.aheadOfDefaultCount ?? status.aheadCount) > 0
        guard status.hasBranch else {
            return .init(label: String(localized: "Commit"), disabled: true, kind: .hint(String(localized: "Create and check out a branch before pushing or opening a pull request.")))
        }
        if status.hasChanges {
            if !status.hasUpstream && !hasPrimaryRemote { return .init(label: String(localized: "Commit"), disabled: false, kind: .run(.commit)) }
            if status.hasOpenPullRequest || isDefaultBranch { return .init(label: String(localized: "Commit & Push"), disabled: false, kind: .run(.commitPush)) }
            return .init(label: String(localized: "Commit, Push & PR"), disabled: false, kind: .run(.commitPushPullRequest))
        }
        if !status.hasUpstream {
            if !hasPrimaryRemote { return .init(label: String(localized: "Publish Repository"), disabled: false, kind: .publish) }
            if !isAhead {
                if status.hasOpenPullRequest { return upToDate }
                return .init(label: String(localized: "Push"), disabled: true, kind: .hint(String(localized: "No local commits to push.")))
            }
            if status.hasOpenPullRequest || isDefaultBranch { return .init(label: String(localized: "Push"), disabled: false, kind: .run(.push)) }
            return .init(label: String(localized: "Push & Create PR"), disabled: false, kind: .run(.createPullRequest))
        }
        if isAhead && isBehind {
            return .init(label: String(localized: "Sync Branch"), disabled: true, kind: .hint(String(localized: "Branch has diverged from upstream. Rebase or merge first.")))
        }
        if isBehind { return .init(label: String(localized: "Pull"), disabled: false, kind: .pull) }
        if isAhead {
            if status.hasOpenPullRequest || isDefaultBranch { return .init(label: String(localized: "Push"), disabled: false, kind: .run(.push)) }
            return .init(label: String(localized: "Push & Create PR"), disabled: false, kind: .run(.createPullRequest))
        }
        if status.hasOpenPullRequest && status.hasUpstream { return upToDate }
        if hasDefaultDelta && !isDefaultBranch { return .init(label: String(localized: "Create PR"), disabled: false, kind: .run(.createPullRequest)) }
        return upToDate
    }
    private static var upToDate: GitQuickAction {
        .init(label: String(localized: "Commit"), disabled: true, kind: .hint(String(localized: "Branch is up to date. No action needed.")))
    }

    public static func requiresDefaultBranchConfirmation(_ action: GitStackedAction, isDefaultBranch: Bool) -> Bool {
        isDefaultBranch && action != .commit
    }

    public static func defaultBranchDialogCopy(_ action: GitStackedAction, branch: String, includesCommit: Bool) -> GitDefaultBranchDialogCopy {
        let suffix = String(localized: " on “\(branch)”. You can continue on this branch or create a feature branch and run the same action there.")
        if action == .push || action == .commitPush {
            return includesCommit
                ? .init(title: String(localized: "Commit & push to the default branch?"), description: String(localized: "This action will commit and push changes") + suffix,
                        continueLabel: String(localized: "Commit & Push to \(branch)"))
                : .init(title: String(localized: "Push to the default branch?"), description: String(localized: "This action will push local commits") + suffix,
                        continueLabel: String(localized: "Push to \(branch)"))
        }
        return includesCommit
            ? .init(title: String(localized: "Commit, push & create PR from the default branch?"),
                    description: String(localized: "This action will commit, push, and create a pull request") + suffix, continueLabel: String(localized: "Commit, Push & Create PR"))
            : .init(title: String(localized: "Push & create PR from the default branch?"),
                    description: String(localized: "This action will push local commits and create a pull request") + suffix, continueLabel: String(localized: "Push & Create PR"))
    }

    /// A feature branch carries uncommitted changes with it; a clean tree has nothing to move.
    public static func featureBranchUnavailableReason(branch: String, hasChanges: Bool) -> String? {
        hasChanges ? nil : String(localized: "There are no changes to commit, so no feature branch is needed. Create a branch yourself or continue on \(branch).")
    }

    public static func sanitizeBranchFragment(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "['\"`]", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "^[./\\s_-]+|[./\\s_-]+$", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "[^a-z0-9/_-]+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "/+", with: "/", options: .regularExpression)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "^[./_-]+|[./_-]+$", with: "", options: .regularExpression)
        value = String(value.prefix(64)).replacingOccurrences(of: "[./_-]+$", with: "", options: .regularExpression)
        return value.isEmpty ? "update" : value
    }
    public static func sanitizeFeatureBranchName(_ raw: String) -> String {
        let value = sanitizeBranchFragment(raw); return value.contains("/") ? value : "feature/" + value
    }
    /// Suffixes each path segment that collides (case-insensitively) with an existing branch.
    public static func autoFeatureBranchName(existing: [String], preferred: String? = nil) -> String {
        let trimmed = preferred?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = sanitizeFeatureBranchName(trimmed.isEmpty ? "feature/update" : trimmed)
        let names = existing.map { $0.lowercased() }, set = Set(names)
        let parts = base.split(separator: "/").map(String.init)
        var resolved = ""
        for (index, part) in parts.enumerated() {
            let prefix = resolved.isEmpty ? part : resolved + "/" + part
            var candidate = prefix, suffix = 2
            while set.contains(candidate) || (index == parts.count - 1 && names.contains { $0.hasPrefix(candidate + "/") }) {
                candidate = prefix + "-" + String(suffix); suffix += 1
            }
            resolved = candidate
        }
        return resolved
    }
    /// The first line of a commit message is a reasonable feature-branch seed.
    public static func featureBranchSeed(commitMessage: String) -> String? {
        let subject = commitMessage.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !subject.isEmpty else { return nil }
        // Conventional-commit types are noise in a branch name.
        return subject.replacingOccurrences(of: "^[a-z]+(\\([^)]*\\))?!?:\\s*", with: "", options: [.regularExpression, .caseInsensitive])
    }

    public static func formatElapsed(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        return value < 60 ? "\(value)s" : "\(value / 60)m \(value % 60)s"
    }
}

/// The seam for AI-written commit messages. No provider-backed generator exists yet; callers
/// only fill an editable field with the result and never commit automatically.
public protocol GitCommitMessageGenerating: Sendable {
    func commitMessage(for context: GitCommitMessageContext) async throws -> String
}

public struct GitCommitMessageContext: Sendable, Equatable {
    public let repositoryPath: String
    public let branch: String
    public let paths: [String]
    public init(repositoryPath: String, branch: String, paths: [String]) { self.repositoryPath = repositoryPath; self.branch = branch; self.paths = paths }
}
