import Foundation

/// Where a thread works and on which branch, as the strip under the Mac's composer shows it, with what the phone may
/// change there (`checkout`, `changeCheckout`).
public struct RemoteCheckout: Codable, Hashable, Sendable {
    public enum Workspace: String, Codable, Sendable {
        /// The project's own folder.
        case local
        /// A worktree of its own.
        case worktree
        /// A new worktree, made when the first message is sent, from `baseBranch`.
        case newWorktree
        case unknown

        public init(from decoder: Decoder) throws {
            self = Workspace(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var workspace: Workspace
    /// Before the first message, the thread can still move between the project's folder and a new worktree.
    public var canChangeWorkspace: Bool
    /// A worktree the thread used before and can go back to before its first message, and its branch.
    public var hasPreviousWorktree: Bool
    public var previousWorktreeBranch: String?
    /// The branch the folder is on.
    public var branch: String?
    /// The branch a new worktree starts from.
    public var baseBranch: String?
    /// Whether `branches` can be picked: to switch the project's folder, or as a new worktree's base.
    public var canPickBranch: Bool
    /// Whether a new branch can be made: in the project's folder only.
    public var canCreateBranch: Bool
    /// Local branches first, then remote ones; at most `maxBranches`.
    public var branches: [RemoteBranch]
    /// A turn runs or a worktree is being made: nothing can change now.
    public var isBusy: Bool

    public static let maxBranches = 80

    public init(
        workspace: Workspace, canChangeWorkspace: Bool = false, hasPreviousWorktree: Bool = false,
        previousWorktreeBranch: String? = nil, branch: String? = nil, baseBranch: String? = nil, canPickBranch: Bool = false,
        canCreateBranch: Bool = false, branches: [RemoteBranch] = [], isBusy: Bool = false
    ) {
        self.workspace = workspace
        self.canChangeWorkspace = canChangeWorkspace
        self.hasPreviousWorktree = hasPreviousWorktree
        self.previousWorktreeBranch = previousWorktreeBranch
        self.branch = branch
        self.baseBranch = baseBranch
        self.canPickBranch = canPickBranch
        self.canCreateBranch = canCreateBranch
        self.branches = branches
        self.isBusy = isBusy
    }
}

public struct RemoteBranch: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var isCurrent: Bool
    public var isRemote: Bool
    /// Checked out in another folder, where git won't check it out a second time.
    public var isCheckedOutElsewhere: Bool

    public var id: String { name }

    public init(name: String, isCurrent: Bool = false, isRemote: Bool = false, isCheckedOutElsewhere: Bool = false) {
        self.name = name
        self.isCurrent = isCurrent
        self.isRemote = isRemote
        self.isCheckedOutElsewhere = isCheckedOutElsewhere
    }
}

/// A change to where a thread works, as the Mac's checkout menus offer it.
public enum RemoteCheckoutAction: Codable, Hashable, Sendable {
    /// The project's own folder (before the first message).
    case useLocal
    /// A new worktree, made from the folder's branch (before the first message).
    case useNewWorktree
    /// The worktree it used before (before the first message).
    case usePreviousWorktree
    /// In the project's folder, switch to a branch; for a new worktree, start it from that branch.
    case pickBranch(String)
    /// In the project's folder, make a branch and switch to it.
    case createBranch(String)

    private enum CodingKeys: String, CodingKey { case type, branch }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "useLocal": self = .useLocal
        case "useNewWorktree": self = .useNewWorktree
        case "usePreviousWorktree": self = .usePreviousWorktree
        case "pickBranch": self = .pickBranch(try container.decode(String.self, forKey: .branch))
        case "createBranch": self = .createBranch(try container.decode(String.self, forKey: .branch))
        case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown action \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .useLocal: try container.encode("useLocal", forKey: .type)
        case .useNewWorktree: try container.encode("useNewWorktree", forKey: .type)
        case .usePreviousWorktree: try container.encode("usePreviousWorktree", forKey: .type)
        case .pickBranch(let branch):
            try container.encode("pickBranch", forKey: .type)
            try container.encode(branch, forKey: .branch)
        case .createBranch(let branch):
            try container.encode("createBranch", forKey: .type)
            try container.encode(branch, forKey: .branch)
        }
    }
}
