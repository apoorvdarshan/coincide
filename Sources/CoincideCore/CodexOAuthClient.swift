import CryptoKit
import Foundation
import Security

public struct CodexOAuthError: Error, Sendable, Equatable, LocalizedError {
    public enum Kind: String, Sendable {
        case invalidConfiguration, discoveryFailed, invalidCallback, declined, expired, codeExpired, invalidClient
        case identityInvalid, accountMismatch, credentialsExpired, revoked, refreshTooEarly, transportFailed
        case outcomeUncertain, protocolViolation, cancelled
    }
    public let kind: Kind
    /// A lost response to a credential mutation is not proof that the server kept its previous token.
    public let mayHaveChangedCredentials: Bool
    public let issuedClientID: String?
    public init(_ kind: Kind, mayHaveChangedCredentials: Bool = false, issuedClientID: String? = nil) {
        self.kind = kind; self.mayHaveChangedCredentials = mayHaveChangedCredentials
        self.issuedClientID = issuedClientID
    }
    public var errorDescription: String? {
        switch kind {
        case .invalidConfiguration: "The ChatGPT connection configuration is invalid."
        case .discoveryFailed: "ChatGPT sign-in configuration could not be verified. Try again."
        case .invalidCallback: "This redirect does not belong to the active ChatGPT sign-in."
        case .declined: "ChatGPT sign-in was declined. Start again when you are ready."
        case .expired, .codeExpired: "This ChatGPT sign-in expired. Reconnect to start again."
        case .invalidClient: "OpenAI rejected this app's saved sign-in registration. Reconnect the account."
        case .identityInvalid: "The ChatGPT identity could not be verified. Start sign-in again."
        case .accountMismatch: "This sign-in returned a different ChatGPT account. The saved connection was kept."
        case .credentialsExpired, .revoked: "The ChatGPT connection expired or was disconnected. Sign in again."
        case .refreshTooEarly: "ChatGPT cannot renew this connection yet. Try again shortly."
        case .transportFailed: "ChatGPT could not be reached safely. Try again."
        case .outcomeUncertain: "The ChatGPT connection change could not be confirmed. Reconnect before retrying."
        case .protocolViolation: "The ChatGPT response could not be read safely."
        case .cancelled: "The ChatGPT connection operation was cancelled."
        }
    }
}

/// Transport-only values never have persistence conformance or revealing debug output.
public struct CodexOAuthHTTPResponse: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let statusCode: Int
    public let url: URL
    public let body: Data
    public init(statusCode: Int, url: URL, body: Data) { self.statusCode = statusCode; self.url = url; self.body = body }
    public var description: String { "CodexOAuthHTTPResponse(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public protocol CodexOAuthTransport: Sendable {
    func response(for request: URLRequest, maximumBytes: Int) async throws -> CodexOAuthHTTPResponse
}

private final class CodexOAuthNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
public struct CodexOAuthURLSessionTransport: CodexOAuthTransport {
    public init() { }
    public func response(for request: URLRequest, maximumBytes: Int) async throws -> CodexOAuthHTTPResponse {
        guard maximumBytes > 0, maximumBytes <= 1_048_576, let url = request.url,
              CodexOAuthParsing.endpoint(url) else { throw CodexOAuthError(.invalidConfiguration) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request, delegate: CodexOAuthNoRedirect())
        guard let http = response as? HTTPURLResponse, http.url == url,
              http.expectedContentLength <= Int64(maximumBytes) else { throw CodexOAuthError(.protocolViolation) }
        var body = Data(); body.reserveCapacity(min(maximumBytes, 16_384))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard body.count < maximumBytes else { throw CodexOAuthError(.protocolViolation) }
            body.append(byte)
        }
        return .init(statusCode: http.statusCode, url: url, body: body)
    }
}

public struct CodexOAuthDiscovery: Sendable, Equatable {
    public let issuer: URL
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let jwksURI: URL
    public let revocationEndpoint: URL?
}
public final class CodexOAuthAuthorization: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let id: UUID
    public let authorizationURL: URL
    public let redirectURI: URL
    public let clientID: String?
    public let expectedSubject: String?
    public let expiresAt: Date
    public var url: URL { authorizationURL }
    public var deadline: Date { expiresAt }
    fileprivate let ownerID: UUID
    fileprivate let state: String
    fileprivate let nonce: String
    fileprivate let verifier: String
    fileprivate init(id: UUID, authorizationURL: URL, redirectURI: URL, clientID: String?, expectedSubject: String?,
                     expiresAt: Date, ownerID: UUID, state: String, nonce: String, verifier: String) {
        self.id = id; self.authorizationURL = authorizationURL; self.redirectURI = redirectURI; self.clientID = clientID
        self.expectedSubject = expectedSubject; self.expiresAt = expiresAt; self.ownerID = ownerID
        self.state = state; self.nonce = nonce; self.verifier = verifier
    }
    public var description: String { "CodexOAuthAuthorization(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public final class CodexOAuthCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let clientID: String
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?
    public let issuer: URL
    public let expiresAt: Date
    public let earliestRefreshAt: Date?
    public let scopes: [String]
    public let identity: CodexOAuthIdentity
    public var permitsDirectUse: Bool { scopes.contains(CodexOAuthClient.requiredScope) }
    public init(clientID: String, accessToken: String, refreshToken: String?, idToken: String?, issuer: URL,
                expiresAt: Date, earliestRefreshAt: Date?, scopes: [String], identity: CodexOAuthIdentity) {
        self.clientID = clientID; self.accessToken = accessToken; self.refreshToken = refreshToken; self.idToken = idToken
        self.issuer = issuer; self.expiresAt = expiresAt; self.earliestRefreshAt = earliestRefreshAt
        self.scopes = scopes; self.identity = identity
    }
    public var description: String { "CodexOAuthCredential(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct CodexOAuthCallback: Sendable, Equatable {
    public let clientID: String?
    public let declined: Bool
}
public enum CodexOAuthRevocation: Sendable, Equatable { case confirmed, unconfirmed }

/// Network/JWT primitives only. The coordinator owns browser consent, callback listeners,
/// credential publication, cross-process rotation locking, and native-session drain.
public actor CodexOAuthClient {
    public static let requiredScope = "chatgpt.tokens.use.direct"
    public static let resource = "https://api.openai.com/v1"
    private let transport: any CodexOAuthTransport
    private let now: @Sendable () -> Date
    private let ownerID = UUID()
    private var cachedDiscovery: CodexOAuthDiscovery?
    private var authorizations: [UUID: CodexOAuthAuthorization] = [:]
    public init(transport: any CodexOAuthTransport = CodexOAuthURLSessionTransport(),
                now: @escaping @Sendable () -> Date = { Date() }) { self.transport = transport; self.now = now }

    public func discovery() async throws -> CodexOAuthDiscovery {
        try checkCancellation()
        if let cachedDiscovery { return cachedDiscovery }
        let url = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
        do {
            let response = try await fetch(url, method: "GET")
            guard response.statusCode == 200 else { throw CodexOAuthError(.discoveryFailed) }
            let object = try CodexOAuthParsing.object(response.body)
            guard object["issuer"]?.string == "https://auth.openai.com" else { throw CodexOAuthError(.discoveryFailed) }
            func endpoint(_ key: String) throws -> URL {
                guard let raw = object[key]?.string, let value = URL(string: raw), CodexOAuthParsing.endpoint(value) else {
                    throw CodexOAuthError(.discoveryFailed)
                }
                return value
            }
            let authorization = try endpoint("authorization_endpoint")
            guard authorization.path == "/api/accounts/authorize" else { throw CodexOAuthError(.discoveryFailed) }
            let result = CodexOAuthDiscovery(issuer: URL(string: "https://auth.openai.com")!, authorizationEndpoint: authorization,
                tokenEndpoint: try endpoint("token_endpoint"), jwksURI: try endpoint("jwks_uri"),
                revocationEndpoint: object["revocation_endpoint"] == nil ? nil : try endpoint("revocation_endpoint"))
            cachedDiscovery = result; return result
        } catch let error as CodexOAuthError where error.kind == .cancelled { throw error }
        catch is CancellationError { throw CodexOAuthError(.cancelled) }
        catch { throw CodexOAuthError(.discoveryFailed) }
    }

    public func authorization(redirectURI: URL, hostID: UUID, clientID: String? = nil, expectedSubject: String? = nil,
                              loginHint: String? = nil, requiresConsent: Bool = false) async throws -> CodexOAuthAuthorization {
        guard CodexOAuthParsing.redirect(redirectURI), clientID.map(CodexOAuthParsing.clientID) ?? true,
              expectedSubject.map({ CodexOAuthParsing.text($0, maximum: 4_096) }) ?? true,
              loginHint.map({ CodexOAuthParsing.text($0, maximum: 4_096) }) ?? true else { throw CodexOAuthError(.invalidConfiguration) }
        let metadata = try await discovery()
        let state = try Self.random(32), nonce = try Self.random(32), verifier = try Self.random(64)
        let challenge = CodexOAuthParsing.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var values = ["client_id": clientID ?? "dynamic_agent_client", "ext_agent_host_id": "urn:uuid:\(hostID.uuidString.lowercased())",
            "response_type": "code", "redirect_uri": redirectURI.absoluteString,
            "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct", "resource": Self.resource,
            "state": state, "nonce": nonce, "code_challenge_method": "S256", "code_challenge": challenge]
        if clientID == nil { values["agent_name_hint"] = "Coincide" }
        if let loginHint { values["login_hint"] = loginHint }
        if requiresConsent { values["prompt"] = "consent" }
        components.queryItems = values.keys.sorted().map { .init(name: $0, value: values[$0]) }
        guard let url = components.url, url.absoluteString.utf8.count <= 16_384 else { throw CodexOAuthError(.invalidConfiguration) }
        let instant = now()
        guard instant.timeIntervalSince1970.isFinite else { throw CodexOAuthError(.invalidConfiguration) }
        authorizations = authorizations.filter { $0.value.expiresAt > instant }
        guard authorizations.count < 32 else { throw CodexOAuthError(.invalidConfiguration) }
        let result = CodexOAuthAuthorization(id: UUID(), authorizationURL: url, redirectURI: redirectURI, clientID: clientID,
            expectedSubject: expectedSubject, expiresAt: instant.addingTimeInterval(300), ownerID: ownerID,
            state: state, nonce: nonce, verifier: verifier)
        authorizations[result.id] = result
        return result
    }

    /// Read-only flow validation for the loopback admission closure. It neither
    /// consumes the one-use code nor initiates network or credential work.
    public func callback(authorization: CodexOAuthAuthorization, callbackURL: String) throws -> CodexOAuthCallback {
        guard authorization.ownerID == ownerID, authorizations[authorization.id] === authorization else { throw CodexOAuthError(.invalidCallback) }
        guard authorization.expiresAt > now() else { throw CodexOAuthError(.expired) }
        let value = try Self.callback(callbackURL, authorization: authorization)
        return .init(clientID: value.clientID, declined: value.declined)
    }
    public func validates(callbackURL: String, authorization: CodexOAuthAuthorization) -> Bool {
        (try? callback(authorization: authorization, callbackURL: callbackURL)) != nil
    }

    public func exchange(authorization: CodexOAuthAuthorization, callbackURL: String) async throws -> CodexOAuthCredential {
        try checkCancellation()
        guard authorization.ownerID == ownerID, authorizations[authorization.id] === authorization else { throw CodexOAuthError(.invalidCallback) }
        guard authorization.expiresAt > now() else { authorizations.removeValue(forKey: authorization.id); throw CodexOAuthError(.expired) }
        let callback = try Self.callback(callbackURL, authorization: authorization)
        // Invalid callbacks do not consume a flow. A valid callback can exchange its one-use code only once.
        authorizations.removeValue(forKey: authorization.id)
        if callback.declined { throw CodexOAuthError(.declined) }
        guard let clientID = callback.clientID, let code = callback.code else { throw CodexOAuthError(.invalidCallback) }
        let metadata = try await discovery()
        let raw = try await tokenRequest(metadata: metadata, values: ["grant_type": "authorization_code", "client_id": clientID,
            "code": code, "code_verifier": authorization.verifier, "redirect_uri": authorization.redirectURI.absoluteString,
            "resource": Self.resource], clientID: clientID, refresh: false)
        guard let idToken = raw.idToken else { throw CodexOAuthError(.identityInvalid, mayHaveChangedCredentials: true) }
        let identity: CodexOAuthIdentity
        do {
            let jwks = try await fetch(metadata.jwksURI, method: "GET")
            guard jwks.statusCode == 200 else { throw CodexOAuthError(.identityInvalid) }
            identity = try CodexOAuthIdentityVerifier.verify(idToken: idToken, jwks: jwks.body, issuer: metadata.issuer,
                audience: clientID, nonce: authorization.nonce, expectedSubject: authorization.expectedSubject, now: now())
        } catch let error as CodexOAuthError {
            throw CodexOAuthError(error.kind, mayHaveChangedCredentials: true, issuedClientID: clientID)
        } catch { throw CodexOAuthError(.identityInvalid, mayHaveChangedCredentials: true, issuedClientID: clientID) }
        return raw.credential(clientID: clientID, identity: identity, issuer: metadata.issuer)
    }

    /// No implicit retry or Keychain mutation. Call under the coordinator's exact-profile rotation lock.
    public func refresh(_ credential: CodexOAuthCredential) async throws -> CodexOAuthCredential {
        try validate(credential)
        try checkCancellation()
        let instant = now()
        if credential.expiresAt.timeIntervalSince(instant) > 60 { return credential }
        if let earliest = credential.earliestRefreshAt, earliest > instant {
            guard credential.expiresAt > instant else { throw CodexOAuthError(.refreshTooEarly) }
            return credential
        }
        guard let refresh = credential.refreshToken else { throw CodexOAuthError(.credentialsExpired) }
        let metadata = try await discovery()
        let raw = try await tokenRequest(metadata: metadata, values: ["grant_type": "refresh_token", "client_id": credential.clientID,
            "refresh_token": refresh, "resource": Self.resource], clientID: credential.clientID, refresh: true)
        guard raw.refreshToken != nil else { throw CodexOAuthError(.outcomeUncertain, mayHaveChangedCredentials: true) }
        // The pinned renewal protocol preserves the verified identity; optional refreshed ID tokens must match it.
        if let idToken = raw.idToken {
            do {
                let jwks = try await fetch(metadata.jwksURI, method: "GET")
                guard jwks.statusCode == 200 else { throw CodexOAuthError(.identityInvalid) }
                _ = try CodexOAuthIdentityVerifier.verify(idToken: idToken, jwks: jwks.body, issuer: metadata.issuer,
                    audience: credential.clientID, nonce: nil, expectedSubject: credential.identity.subject, now: now())
            } catch { throw CodexOAuthError(.outcomeUncertain, mayHaveChangedCredentials: true) }
        }
        return raw.credential(clientID: credential.clientID, identity: credential.identity, issuer: metadata.issuer,
                              previousIDToken: credential.idToken)
    }

    public func revoke(_ credential: CodexOAuthCredential) async throws -> CodexOAuthRevocation {
        try validate(credential); try checkCancellation()
        guard let refresh = credential.refreshToken else { return .confirmed }
        let metadata: CodexOAuthDiscovery
        do { metadata = try await discovery() }
        catch let error as CodexOAuthError where error.kind == .cancelled { throw error }
        catch { return .unconfirmed }
        guard let endpoint = metadata.revocationEndpoint else { return .unconfirmed }
        for attempt in 0..<3 {
            do {
                let response = try await fetch(endpoint, method: "POST", body: Self.form(["token": refresh,
                    "token_type_hint": "refresh_token", "client_id": credential.clientID]), timeout: 10)
                if response.statusCode == 200 { return .confirmed }
                if response.statusCode < 500 { return .unconfirmed }
            } catch is CancellationError { throw CodexOAuthError(.cancelled, mayHaveChangedCredentials: true) }
            catch let error as CodexOAuthError where error.kind == .cancelled { throw error }
            catch { }
            if attempt < 2 {
                do { try await Task.sleep(for: attempt == 0 ? .milliseconds(250) : .seconds(1)) }
                catch { throw CodexOAuthError(.cancelled, mayHaveChangedCredentials: true) }
            }
        }
        return .unconfirmed
    }

    /// Removes only an unused in-memory attempt; browser/listener cleanup belongs to its owner.
    public func cancel(_ authorization: CodexOAuthAuthorization) {
        if authorization.ownerID == ownerID { authorizations.removeValue(forKey: authorization.id) }
    }

    private struct Tokens {
        let access: String, refreshToken: String?, idToken: String?, expiresIn: Double, earliest: Date?, scopes: [String], receivedAt: Date
        func credential(clientID: String, identity: CodexOAuthIdentity, issuer: URL, previousIDToken: String? = nil) -> CodexOAuthCredential {
            .init(clientID: clientID, accessToken: access, refreshToken: refreshToken, idToken: idToken ?? previousIDToken,
                issuer: issuer, expiresAt: receivedAt.addingTimeInterval(expiresIn), earliestRefreshAt: earliest, scopes: scopes, identity: identity)
        }
    }
    private func tokenRequest(metadata: CodexOAuthDiscovery, values: [String: String], clientID: String, refresh: Bool) async throws -> Tokens {
        let response: CodexOAuthHTTPResponse
        do { response = try await fetch(metadata.tokenEndpoint, method: "POST", body: Self.form(values)) }
        catch is CancellationError { throw CodexOAuthError(.cancelled, mayHaveChangedCredentials: true) }
        catch let error as CodexOAuthError where error.kind == .cancelled { throw CodexOAuthError(.cancelled, mayHaveChangedCredentials: true) }
        catch { throw CodexOAuthError(.outcomeUncertain, mayHaveChangedCredentials: true) }
        let object: [String: JSONValue]
        do { object = try CodexOAuthParsing.object(response.body) }
        catch { throw CodexOAuthError(.outcomeUncertain, mayHaveChangedCredentials: true, issuedClientID: clientID) }
        guard (200..<300).contains(response.statusCode) else {
            let code = object["error"]?.string
            if code == "invalid_client" { throw CodexOAuthError(.invalidClient, issuedClientID: clientID) }
            if refresh, ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"].contains(code ?? "") {
                throw CodexOAuthError(.revoked, issuedClientID: clientID)
            }
            if !refresh, code == "invalid_grant" { throw CodexOAuthError(.codeExpired, issuedClientID: clientID) }
            if code == "access_denied" { throw CodexOAuthError(.declined, issuedClientID: clientID) }
            throw CodexOAuthError(.outcomeUncertain, mayHaveChangedCredentials: true, issuedClientID: clientID)
        }
        do {
            guard let access = object["access_token"]?.string, CodexOAuthParsing.text(access, maximum: 65_536),
                  object["token_type"]?.string?.lowercased() == "bearer", let rawExpiry = object["expires_in"], case .number(let expiry) = rawExpiry,
                  expiry.isFinite, expiry > 0, expiry.rounded() == expiry, expiry <= 31_536_000,
                  let scope = object["scope"]?.string, scope.utf8.count <= 16_384 else { throw CodexOAuthError(.protocolViolation) }
            func optional(_ key: String) throws -> String? {
                guard let value = object[key] else { return nil }
                guard let text = value.string, CodexOAuthParsing.text(text, maximum: 65_536) else { throw CodexOAuthError(.protocolViolation) }
                return text
            }
            var earliest: Date?
            if let raw = object["earliest_refresh_at"] {
                switch raw {
                case .number(let seconds) where seconds.isFinite: earliest = Date(timeIntervalSince1970: seconds)
                case .string(let text):
                    earliest = ISO8601DateFormatter().date(from: text)
                    if earliest == nil { let parser = ISO8601DateFormatter(); parser.formatOptions.insert(.withFractionalSeconds); earliest = parser.date(from: text) }
                    guard earliest != nil else { throw CodexOAuthError(.protocolViolation) }
                default: throw CodexOAuthError(.protocolViolation)
                }
            }
            let scopes = scope.split(whereSeparator: \.isWhitespace).map(String.init)
            guard scopes.count <= 128, scopes.allSatisfy({ CodexOAuthParsing.text($0, maximum: 256) }) else { throw CodexOAuthError(.protocolViolation) }
            return Tokens(access: access, refreshToken: try optional("refresh_token"), idToken: try optional("id_token"),
                          expiresIn: expiry, earliest: earliest, scopes: Array(Set(scopes)).sorted(), receivedAt: now())
        } catch { throw CodexOAuthError(.outcomeUncertain, mayHaveChangedCredentials: true, issuedClientID: clientID) }
    }
    private func fetch(_ url: URL, method: String, body: Data? = nil, timeout: TimeInterval = 20) async throws -> CodexOAuthHTTPResponse {
        try checkCancellation()
        guard CodexOAuthParsing.endpoint(url) else { throw CodexOAuthError(.invalidConfiguration) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
        do {
            let result = try await transport.response(for: request, maximumBytes: 1_048_576)
            try checkCancellation()
            guard result.url == url, result.body.count <= 1_048_576, (100...599).contains(result.statusCode) else { throw CodexOAuthError(.protocolViolation) }
            return result
        } catch is CancellationError { throw CodexOAuthError(.cancelled) }
        catch let error as CodexOAuthError { throw error }
        catch { throw CodexOAuthError(Task.isCancelled ? .cancelled : .transportFailed) }
    }
    private func validate(_ credential: CodexOAuthCredential) throws {
        guard CodexOAuthParsing.clientID(credential.clientID), CodexOAuthParsing.text(credential.accessToken, maximum: 65_536),
              credential.refreshToken.map({ CodexOAuthParsing.text($0, maximum: 65_536) }) ?? true,
              credential.idToken.map({ CodexOAuthParsing.text($0, maximum: 65_536) }) ?? true,
              credential.scopes.count <= 128, credential.scopes.allSatisfy({ CodexOAuthParsing.text($0, maximum: 256) }),
              credential.issuer.absoluteString == "https://auth.openai.com", credential.expiresAt.timeIntervalSince1970.isFinite,
              credential.earliestRefreshAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              CodexOAuthParsing.text(credential.identity.subject, maximum: 4_096) else { throw CodexOAuthError(.invalidConfiguration) }
    }
    private func checkCancellation() throws { if Task.isCancelled { throw CodexOAuthError(.cancelled) } }
    private static func random(_ bytes: Int) throws -> String {
        var data = Data(count: bytes)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        guard status == errSecSuccess else { throw CodexOAuthError(.invalidConfiguration) }
        return CodexOAuthParsing.base64url(data)
    }
    private static func form(_ values: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed)! }
        return Data(values.keys.sorted().map { "\(encode($0))=\(encode(values[$0]!))" }.joined(separator: "&").utf8)
    }
    private static func callback(_ value: String, authorization: CodexOAuthAuthorization) throws -> (clientID: String?, code: String?, declined: Bool) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let literal = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard value.utf8.count <= 16_384, let parts = URLComponents(string: literal), let actual = parts.url,
              parts.scheme == "http", parts.host == "127.0.0.1", parts.port == authorization.redirectURI.port,
              parts.percentEncodedPath == "/auth/callback", parts.user == nil, parts.password == nil, parts.fragment == nil,
              actual.path == authorization.redirectURI.path else { throw CodexOAuthError(.invalidCallback) }
        let items = parts.queryItems ?? []
        func values(_ key: String) -> [String?] { items.filter { $0.name == key }.map(\.value) }
        let states = values("state"), codes = values("code"), errors = values("error"), clients = values("client_id")
        guard states.count == 1, states[0] == authorization.state, clients.count <= 1,
              (codes.count == 1 && codes[0]?.isEmpty == false && errors.isEmpty) || (errors.count == 1 && errors[0]?.isEmpty == false && codes.isEmpty) else {
            throw CodexOAuthError(.invalidCallback)
        }
        if !errors.isEmpty {
            guard errors[0] == "access_denied" else { throw CodexOAuthError(.invalidCallback) }
            return (nil, nil, true)
        }
        let returned = clients.first.flatMap { $0 }
        guard returned.map(CodexOAuthParsing.clientID) ?? true,
              authorization.clientID == nil || returned == nil || returned == authorization.clientID,
              let clientID = authorization.clientID ?? returned, CodexOAuthParsing.clientID(clientID) else { throw CodexOAuthError(.invalidCallback) }
        return (clientID, codes.first.flatMap { $0 }, !errors.isEmpty)
    }
}

// Bounded common validation; no native response/body is embedded into any error.
enum CodexOAuthParsing {
    static func text(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
    static func clientID(_ value: String) -> Bool {
        value.hasPrefix("oaiapp_") && value.utf8.count <= 512 && value.dropFirst(7).count > 0 &&
            value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
    static func endpoint(_ value: URL) -> Bool {
        guard let c = URLComponents(url: value, resolvingAgainstBaseURL: false) else { return false }
        return value.absoluteString.utf8.count <= 4_096 && c.scheme == "https" && c.host == "auth.openai.com" &&
            (c.port == nil || c.port == 443) && c.user == nil && c.password == nil && c.query == nil && c.fragment == nil &&
            !c.percentEncodedPath.isEmpty && !c.percentEncodedPath.contains("%")
    }
    static func redirect(_ value: URL) -> Bool {
        guard let c = URLComponents(url: value, resolvingAgainstBaseURL: false) else { return false }
        return c.scheme == "http" && c.host == "127.0.0.1" && (c.port.map { (1...65_535).contains($0) } ?? false) &&
            c.percentEncodedPath == "/auth/callback" && c.user == nil && c.password == nil && c.query == nil && c.fragment == nil
    }
    static func base64url(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func object(_ data: Data) throws -> [String: JSONValue] {
        guard !data.isEmpty, data.count <= 1_048_576 else { throw CodexOAuthError(.protocolViolation) }
        var scanner = CodexOAuthJSONScanner(bytes: Array(data))
        try scanner.validate()
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else { throw CodexOAuthError(.protocolViolation) }
        return object
    }
}

/// Reject duplicate decoded member names before Foundation can silently choose
/// one security claim. Bounds apply before recursive Codable decoding.
private struct CodexOAuthJSONScanner {
    let bytes: [UInt8]
    var index = 0
    var items = 0
    mutating func validate() throws {
        try value(depth: 0); whitespace()
        guard index == bytes.count else { throw invalid() }
    }
    mutating func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    mutating func value(depth: Int) throws {
        whitespace(); items += 1
        guard depth <= 32, items <= 16_384, index < bytes.count else { throw invalid() }
        switch bytes[index] {
        case 123:
            index += 1; whitespace(); var keys: Set<String> = []
            if take(125) { return }
            while true {
                whitespace(); let key = try string()
                guard keys.insert(key).inserted, keys.count <= 1_024 else { throw invalid() }
                whitespace(); guard take(58) else { throw invalid() }
                try value(depth: depth + 1); whitespace()
                if take(125) { return }; guard take(44) else { throw invalid() }
            }
        case 91:
            index += 1; whitespace(); if take(93) { return }
            while true {
                try value(depth: depth + 1); whitespace()
                if take(93) { return }; guard take(44) else { throw invalid() }
            }
        case 34: _ = try string()
        default:
            let start = index
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw invalid() }
        }
    }
    mutating func string() throws -> String {
        guard index < bytes.count, bytes[index] == 34 else { throw invalid() }
        let start = index; index += 1; var escaped = false
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if escaped { escaped = false }
            else if byte == 92 { escaped = true }
            else if byte == 34 {
                guard index - start <= 131_072 else { throw invalid() }
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
            }
        }
        throw invalid()
    }
    mutating func take(_ value: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == value else { return false }; index += 1; return true
    }
    func invalid() -> CodexOAuthError { .init(.protocolViolation) }
}
