import Foundation

public enum CodexAccountError: Error, Sendable, Equatable, LocalizedError {
    case busy, storageUnavailable, invalidRecord, staleAccount, signInRequired, sharingRequired, reconnectRequired, profileLimit
    public var errorDescription: String? {
        switch self {
        case .busy: String(localized: "Another Codex account operation is running. Try again when it finishes.")
        case .storageUnavailable: String(localized: "Codex account storage is unavailable. Check Keychain access before continuing.")
        case .invalidRecord: String(localized: "The saved Codex account could not be read safely. Its data was preserved.")
        case .staleAccount: String(localized: "The Codex account changed. Review the selected account before continuing.")
        case .signInRequired: String(localized: "Sign in to ChatGPT in Settings before using this Codex connection.")
        case .sharingRequired: String(localized: "Reconnect to ChatGPT and enable token sharing to use this Codex connection.")
        case .reconnectRequired: String(localized: "This ChatGPT connection could not be renewed safely. Reconnect before continuing.")
        case .profileLimit: String(localized: "This Codex instance has reached its limit of 30 saved accounts.")
        }
    }
}

/// The only account identity suitable for captured workspace configuration.
/// It contains no provider registration ID, email, subject, or credential.
public struct CodexAccountBinding: Codable, Sendable, Equatable, Hashable {
    public let profileID: UUID
    public let generation: UUID
    public init(profileID: UUID, generation: UUID) { self.profileID = profileID; self.generation = generation }
}

/// Transient Settings presentation. Identity labels stay outside SQLite and the
/// workspace journal, including when a connection is disconnected or uncertain.
public struct CodexAccountProfile: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let email: String?
    public let sharingEnabled: Bool
    public let isActive: Bool
    public let hasCredential: Bool
    public let requiresReconnect: Bool
}
public struct CodexAccountOverview: Sendable, Equatable {
    public let binding: CodexAccountBinding?
    public let profiles: [CodexAccountProfile]
}

/// A sign-in preparation is tied to one vault and account generation. OAuth
/// registration/identity hints are transient and deliberately not Codable.
public final class CodexAccountPreparation: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let profileID: UUID?
    public let clientID: String?
    public let expectedSubject: String?
    public let loginHint: String?
    fileprivate let ownerID: UUID
    fileprivate let generation: UUID
    fileprivate init(profileID: UUID?, clientID: String?, subject: String?, email: String?, ownerID: UUID, generation: UUID) {
        self.profileID = profileID; self.clientID = clientID; expectedSubject = subject; loginHint = email
        self.ownerID = ownerID; self.generation = generation
    }
    public var description: String { "CodexAccountPreparation(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

struct CodexAccountOAuthOperations: Sendable {
    let callback: @Sendable (CodexOAuthAuthorization, String) async throws -> CodexOAuthCallback
    let exchange: @Sendable (CodexOAuthAuthorization, String) async throws -> CodexOAuthCredential
    let refresh: @Sendable (CodexOAuthCredential) async throws -> CodexOAuthCredential
    let revoke: @Sendable (CodexOAuthCredential) async throws -> CodexOAuthRevocation
    init(client: CodexOAuthClient) {
        callback = { try await client.callback(authorization: $0, callbackURL: $1) }
        exchange = { try await client.exchange(authorization: $0, callbackURL: $1) }
        refresh = { try await client.refresh($0) }; revoke = { try await client.revoke($0) }
    }
    init(callback: @escaping @Sendable (CodexOAuthAuthorization, String) async throws -> CodexOAuthCallback,
         exchange: @escaping @Sendable (CodexOAuthAuthorization, String) async throws -> CodexOAuthCredential,
         refresh: @escaping @Sendable (CodexOAuthCredential) async throws -> CodexOAuthCredential,
         revoke: @escaping @Sendable (CodexOAuthCredential) async throws -> CodexOAuthRevocation) {
        self.callback = callback; self.exchange = exchange; self.refresh = refresh; self.revoke = revoke
    }
}

/// Serializes every credential read/mutation across actors and processes. This
/// is the secret-store layer, not the workspace admission gate: callers must
/// first drain all account-bound runtimes before exchange/activate/logout.
/// Runtime access does not open a browser or initiate sign-in.
public actor CodexAccountVault {
    public static var defaultLockRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Coincide/CodexAccountLocks", isDirectory: true)
    }
    private let instanceID: UUID
    private let storage: any CodexCredentialStorage
    private let root: URL
    private let operations: CodexAccountOAuthOperations
    private let now: @Sendable () -> Date
    private let ownerID = UUID()
    private let lockTimeout: Duration
    public init(instanceID: UUID, storage: any CodexCredentialStorage = KeychainCodexCredentialStorage(),
                lockRoot: URL = CodexAccountVault.defaultLockRoot, client: CodexOAuthClient,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.instanceID = instanceID; self.storage = storage; root = lockRoot
        operations = .init(client: client); self.now = now; lockTimeout = .seconds(40)
    }
    init(instanceID: UUID, storage: any CodexCredentialStorage, lockRoot: URL,
         operations: CodexAccountOAuthOperations, lockTimeout: Duration = .seconds(2), now: @escaping @Sendable () -> Date) {
        self.instanceID = instanceID; self.storage = storage; root = lockRoot
        self.operations = operations; self.now = now; self.lockTimeout = lockTimeout
    }
    public func overview() async throws -> CodexAccountOverview {
        let lease = try await acquire(); return try overview(read(lease), lease)
    }
    public func prepare(profileID: UUID? = nil) async throws -> CodexAccountPreparation {
        let lease = try await acquire(), document = try read(lease)
        let profile: StoredProfile?
        if let profileID {
            guard let saved = document.profiles.first(where: { $0.id == profileID }) else { throw CodexAccountError.staleAccount }
            profile = saved
        } else {
            guard document.profiles.count < 30 else { throw CodexAccountError.profileLimit }; profile = nil
        }
        return .init(profileID: profile?.id, clientID: profile?.clientID, subject: profile?.subject, email: profile?.email,
                     ownerID: ownerID, generation: document.generation)
    }
    public func exchange(preparation: CodexAccountPreparation, authorization: CodexOAuthAuthorization,
                         callbackURL: String) async throws -> CodexAccountOverview {
        let lease = try await acquire()
        var document = try read(lease)
        guard preparation.ownerID == ownerID, document.generation == preparation.generation,
              authorization.clientID == preparation.clientID, authorization.expectedSubject == preparation.expectedSubject else { throw CodexAccountError.staleAccount }
        let callback = try await operations.callback(authorization, callbackURL)
        try Task.checkCancellation(); try lease.validate()
        if callback.declined { throw CodexOAuthError(.declined) }
        guard let clientID = callback.clientID else { throw CodexOAuthError(.invalidCallback) }
        let existing = document.profiles.first(where: { $0.clientID == clientID })
        guard existing?.id == preparation.profileID else { throw CodexAccountError.staleAccount }
        guard existing != nil || document.profiles.count < 30 else { throw CodexAccountError.profileLimit }
        if let existing {
            guard existing.subject == preparation.expectedSubject,
                  Self.sameRedirect(existing.redirectURI, authorization.redirectURI) else { throw CodexAccountError.staleAccount }
        }
        let profileID = existing?.id ?? UUID(), wasUncertain = try lease.isUncertain(profileID)
        // A new dynamic registration cannot rotate any previously saved token;
        // an existing registration needs a crash-durable receipt before POST.
        if existing != nil { try lease.markUncertain(profileID) }
        let credential: CodexOAuthCredential
        do {
            credential = try await operations.exchange(authorization, callbackURL)
            try lease.validate()
            guard credential.clientID == clientID, credential.expiresAt > now(),
                  existing?.subject == nil || existing?.subject == credential.identity.subject else { throw CodexAccountError.staleAccount }
            try Self.validate(credential)
        } catch {
            if existing != nil, !wasUncertain, let oauth = error as? CodexOAuthError, !oauth.mayHaveChangedCredentials {
                try lease.clearUncertainty(profileID)
            }
            if existing == nil, let oauth = error as? CodexOAuthError, oauth.kind == .codeExpired,
               !oauth.mayHaveChangedCredentials, oauth.issuedClientID == clientID {
                // OpenAI can issue a registration before its one-use code
                // expires. Keep only that unverified reconnect registration;
                // it cannot grant execution or replace the active account.
                document.profiles.append(.init(id: profileID, clientID: clientID, subject: nil, email: nil,
                    redirectURI: authorization.redirectURI, sharingEnabled: false, credential: nil))
                try save(document, lease)
            }
            throw error
        }
        let stored = StoredProfile(id: profileID, clientID: credential.clientID, subject: credential.identity.subject,
            email: credential.identity.email, redirectURI: authorization.redirectURI,
            sharingEnabled: credential.permitsDirectUse, credential: StoredCredential(credential))
        if let index = document.profiles.firstIndex(where: { $0.id == profileID }) { document.profiles[index] = stored }
        else { guard document.profiles.count < 30 else { throw CodexAccountError.profileLimit }; document.profiles.append(stored) }
        if document.activeProfileID == profileID || (!Task.isCancelled && (credential.permitsDirectUse || document.activeProfileID == nil)) {
            document.activeProfileID = profileID; document.generation = UUID()
        }
        try save(document, lease)
        // Publication is committed. Do not reinterpret a late cancellation as
        // failure or roll back rotated credentials to the previous token.
        try lease.clearUncertainty(profileID)
        return try overview(document, lease)
    }
    public func activate(profileID: UUID) async throws -> CodexAccountOverview {
        let lease = try await acquire()
        var document = try read(lease)
        guard let profile = document.profiles.first(where: { $0.id == profileID }), profile.credential != nil else { throw CodexAccountError.signInRequired }
        guard !((try lease.isUncertain(profileID))) else { throw CodexAccountError.reconnectRequired }
        guard profile.sharingEnabled else { throw CodexAccountError.sharingRequired }
        document.activeProfileID = profileID; document.generation = UUID()
        try save(document, lease); return try overview(document, lease)
    }
    /// Ordinary refresh preserves the opaque account generation. A queued turn
    /// cannot silently move to a different account, and token revisions never
    /// become command fingerprints or persisted workspace state.
    public func access(binding: CodexAccountBinding) async throws -> CodexOAuthCredential {
        let lease = try await acquire()
        var document = try read(lease)
        guard document.generation == binding.generation, document.activeProfileID == binding.profileID,
              let index = document.profiles.firstIndex(where: { $0.id == binding.profileID }) else { throw CodexAccountError.staleAccount }
        guard !(try lease.isUncertain(binding.profileID)) else { throw CodexAccountError.reconnectRequired }
        guard let stored = document.profiles[index].credential else { throw CodexAccountError.signInRequired }
        let credential = try stored.value(profile: document.profiles[index])
        guard credential.permitsDirectUse else { throw CodexAccountError.sharingRequired }
        let instant = now()
        guard instant.timeIntervalSince1970.isFinite else { throw CodexAccountError.invalidRecord }
        if credential.expiresAt.timeIntervalSince(instant) > 60 { return credential }
        if let earliest = credential.earliestRefreshAt, earliest > instant {
            guard credential.expiresAt > instant else { throw CodexOAuthError(.refreshTooEarly) }; return credential
        }
        if credential.refreshToken == nil {
            document.profiles[index].credential = nil; document.generation = UUID()
            try save(document, lease); throw CodexAccountError.signInRequired
        }
        try lease.markUncertain(binding.profileID)
        do {
            let renewed = try await operations.refresh(credential)
            // The remote rotation may be committed even when cancellation was
            // requested. Publish the exact verified result before observing it.
            try lease.validate(); try Self.validate(renewed)
            guard renewed.clientID == credential.clientID, renewed.identity.subject == credential.identity.subject,
                  renewed.refreshToken != nil, renewed.expiresAt > now() else { throw CodexAccountError.reconnectRequired }
            document.profiles[index].credential = StoredCredential(renewed)
            document.profiles[index].sharingEnabled = renewed.permitsDirectUse
            try save(document, lease); try lease.clearUncertainty(binding.profileID)
            try Task.checkCancellation()
            guard renewed.permitsDirectUse else { throw CodexAccountError.sharingRequired }
            return renewed
        } catch let error as CodexOAuthError where [.revoked, .invalidClient, .credentialsExpired].contains(error.kind) && !error.mayHaveChangedCredentials {
            document.profiles[index].credential = nil; document.generation = UUID()
            try save(document, lease); try lease.clearUncertainty(binding.profileID)
            throw CodexAccountError.signInRequired
        } catch let error as CodexOAuthError where !error.mayHaveChangedCredentials {
            // Discovery/pre-dispatch failures did not rotate the remote token.
            // Keep the credential available for a later explicit access attempt.
            try lease.clearUncertainty(binding.profileID); throw error
        } catch is CancellationError { throw CancellationError() }
        catch let error as CodexAccountError where error == .sharingRequired { throw error }
        catch { throw CodexAccountError.reconnectRequired }
    }
    /// Local sign-out is committed even when remote revocation is unavailable.
    /// Other profiles, saved registrations, CLI credentials and history survive.
    public func logout(profileID: UUID) async throws -> CodexOAuthRevocation {
        let lease = try await acquire()
        var document = try read(lease)
        guard let index = document.profiles.firstIndex(where: { $0.id == profileID }) else { throw CodexAccountError.staleAccount }
        let uncertain = try lease.isUncertain(profileID), credential = document.profiles[index].credential
        var outcome: CodexOAuthRevocation = uncertain ? .unconfirmed : .confirmed
        if let credential, !uncertain {
            try lease.markUncertain(profileID)
            do { outcome = try await operations.revoke(credential.value(profile: document.profiles[index])) }
            catch { outcome = .unconfirmed }
        }
        try lease.validate()
        document.profiles[index].credential = nil
        if document.activeProfileID == profileID { document.activeProfileID = nil; document.generation = UUID() }
        try save(document, lease); try lease.clearUncertainty(profileID)
        return outcome
    }

    private func acquire() async throws -> CodexCredentialLock {
        try await CodexCredentialLock.acquire(root: root, instanceID: instanceID, timeout: lockTimeout)
    }
    private func read(_ lease: CodexCredentialLock) throws -> Document {
        try lease.validate()
        var data: Data?
        do {
            data = try storage.read(instanceID: instanceID)
            if data == nil {
                var initial = Document(); initial.lockRootIdentity = lease.rootIdentity
                let claim = try JSONEncoder().encode(initial)
                if try storage.createIfAbsent(claim, instanceID: instanceID) { data = claim }
                else { data = try storage.read(instanceID: instanceID) }
            }
        } catch { throw CodexAccountError.storageUnavailable }
        guard let data else { throw CodexAccountError.storageUnavailable }
        do {
            guard !data.isEmpty, data.count <= KeychainCodexCredentialStorage.maximumBytes else { throw CodexAccountError.invalidRecord }
            _ = try CodexOAuthParsing.object(data) // Reject duplicate decoded keys and unbounded nesting.
            let document = try JSONDecoder().decode(Document.self, from: data)
            try Self.validate(document)
            guard document.lockRootIdentity == lease.rootIdentity else { throw CodexAccountError.storageUnavailable }
            try lease.validate(); return document
        } catch { throw CodexAccountError.invalidRecord }
    }
    private func save(_ document: Document, _ lease: CodexCredentialLock) throws {
        var stored = document; stored.lockRootIdentity = lease.rootIdentity
        try Self.validate(stored); try lease.validate()
        let data = try JSONEncoder().encode(stored)
        guard data.count <= KeychainCodexCredentialStorage.maximumBytes else { throw CodexAccountError.invalidRecord }
        do { try storage.write(data, instanceID: instanceID) } catch { throw CodexAccountError.storageUnavailable }
        try lease.validate()
    }
    private func overview(_ document: Document, _ lease: CodexCredentialLock) throws -> CodexAccountOverview {
        var binding: CodexAccountBinding?
        let profiles = try document.profiles.map { profile in
            let uncertain = try lease.isUncertain(profile.id), active = profile.id == document.activeProfileID
            if active, !uncertain, profile.sharingEnabled, profile.credential != nil {
                binding = .init(profileID: profile.id, generation: document.generation)
            }
            return CodexAccountProfile(id: profile.id, email: profile.email, sharingEnabled: profile.sharingEnabled,
                isActive: active, hasCredential: profile.credential != nil, requiresReconnect: uncertain || profile.credential == nil)
        }
        return .init(binding: binding, profiles: profiles)
    }
    private static func sameRedirect(_ saved: URL, _ current: URL) -> Bool {
        CodexOAuthParsing.redirect(saved) && CodexOAuthParsing.redirect(current) && saved.scheme == current.scheme && saved.host == current.host && saved.path == current.path
    }
    private static func validate(_ credential: CodexOAuthCredential) throws {
        guard CodexOAuthParsing.clientID(credential.clientID), credential.issuer.absoluteString == "https://auth.openai.com",
              CodexOAuthParsing.text(credential.accessToken, maximum: 65_536),
              credential.refreshToken.map({ CodexOAuthParsing.text($0, maximum: 65_536) }) ?? true,
              credential.idToken.map({ CodexOAuthParsing.text($0, maximum: 65_536) }) ?? true,
              CodexOAuthParsing.text(credential.identity.subject, maximum: 4_096),
              credential.identity.email.map({ CodexOAuthParsing.text($0, maximum: 4_096) }) ?? true,
              credential.expiresAt.timeIntervalSince1970.isFinite,
              credential.earliestRefreshAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              credential.scopes.count <= 128, Set(credential.scopes).count == credential.scopes.count,
              credential.scopes.allSatisfy({ CodexOAuthParsing.text($0, maximum: 256) }) else { throw CodexAccountError.invalidRecord }
    }
    private static func validate(_ document: Document) throws {
        guard document.version == 1, document.profiles.count <= 30,
              Set(document.profiles.map(\.id)).count == document.profiles.count,
              Set(document.profiles.map(\.clientID)).count == document.profiles.count,
              document.activeProfileID == nil || document.profiles.contains(where: { $0.id == document.activeProfileID }) else { throw CodexAccountError.invalidRecord }
        for profile in document.profiles {
            guard CodexOAuthParsing.clientID(profile.clientID), profile.subject.map({ CodexOAuthParsing.text($0, maximum: 4_096) }) ?? true,
                  profile.email.map({ CodexOAuthParsing.text($0, maximum: 4_096) }) ?? true,
                  CodexOAuthParsing.redirect(profile.redirectURI) else { throw CodexAccountError.invalidRecord }
            if profile.subject == nil {
                guard profile.email == nil, profile.credential == nil, !profile.sharingEnabled,
                      document.activeProfileID != profile.id else { throw CodexAccountError.invalidRecord }
            }
            if let credential = profile.credential {
                let value = try credential.value(profile: profile); try validate(value)
                guard profile.sharingEnabled == value.permitsDirectUse else { throw CodexAccountError.invalidRecord }
            }
        }
    }
    // Only these private storage DTOs encode secrets, directly into bounded
    // Keychain Data. Public OAuth/runtime values never gain Codable conformance.
    private struct Document: Codable {
        var version = 1
        var lockRootIdentity: GitWorktreeNodeIdentity?
        var generation = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        var activeProfileID: UUID?
        var profiles: [StoredProfile] = []
    }
    private struct StoredProfile: Codable {
        let id: UUID
        let clientID: String
        let subject: String?
        let email: String?
        let redirectURI: URL
        var sharingEnabled: Bool
        var credential: StoredCredential?
    }
    private struct StoredCredential: Codable {
        let accessToken: String
        let refreshToken: String?
        let idToken: String?
        let issuer: URL
        let expiresAt: Date
        let earliestRefreshAt: Date?
        let scopes: [String]
        init(_ credential: CodexOAuthCredential) {
            accessToken = credential.accessToken; refreshToken = credential.refreshToken; idToken = credential.idToken
            issuer = credential.issuer; expiresAt = credential.expiresAt; earliestRefreshAt = credential.earliestRefreshAt; scopes = credential.scopes
        }
        func value(profile: StoredProfile) throws -> CodexOAuthCredential {
            guard let subject = profile.subject else { throw CodexAccountError.invalidRecord }
            return .init(clientID: profile.clientID, accessToken: accessToken, refreshToken: refreshToken, idToken: idToken,
                issuer: issuer, expiresAt: expiresAt, earliestRefreshAt: earliestRefreshAt, scopes: scopes,
                identity: .init(subject: subject, email: profile.email))
        }
    }
}
